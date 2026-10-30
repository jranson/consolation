//
//  TransportStreamPipelineHealth.swift
//  PlaybackKit
//
//  The pipeline's wake-ups: when to pump next, and the once-a-second health report (stall detection, the live-edge
//  buffer guard, the stats overlay's diagnostics and the optional trace).
//

import AVFoundation
import Foundation
import os

nonisolated extension TransportStreamPipeline {
    /// One wake-up of the pump timer: feed the renderers, show due captions, publish the timeline, report health
    /// when due, re-arm. A finished stream that is paused sleeps until a seek wakes it.
    func tick() {
        guard !stopped else { return }
        if PipelineTrace.isEnabled { trace.noteTick() }
        pump()
        deliverDueCaptions()
        publishTimeline()
        let now = DispatchTime.now()
        if now >= nextHealthReport {
            nextHealthReport = now + Self.healthInterval
            reportHealth()
        }
        if now >= nextPerformanceLog {
            nextPerformanceLog = now + Self.performanceLogInterval
            logPerformance()
        }
        guard !stopped, !(ending.finished && paused) else { return }
        pumpTimer?.schedule(deadline: .now() + nextPumpDelay(), repeating: .never, leeway: Self.pumpLeeway)
    }

    /// Brings the next wake-up forward, after a seek, a resume or a restarted timeline (start-up paces itself).
    func wakeSoon() {
        pumpTimer?.schedule(deadline: .now() + Self.busyPumpDelay, repeating: .never, leeway: Self.pumpLeeway)
    }

    /// How long the renderers can go without the pump: until queued video or audio falls to its low-water mark,
    /// the next caption is due or the next health report, within `shortestPumpDelay...longestPumpDelay`. A 1080i
    /// stream wakes about five times a second this way instead of forty, decoding a few pictures each time.
    func nextPumpDelay() -> Double {
        var delay = Self.longestPumpDelay
        if isReading {
            if renderer.rate == 0 {
                // Starting or rebuffering: check back soon.
                delay = Self.busyPumpDelay
            } else {
                delay = min(delay, renderer.videoSecondsAhead - Self.videoLowWater)
                if renderer.hasAudioTrack { delay = min(delay, renderer.audioSecondsAhead - Self.audioLowWater) }
            }
            if let caption = pendingCaptions.first {
                let now = CMTimeConvertScale(renderer.currentTime, timescale: 90_000, method: .default).value
                delay = min(delay, Double(caption.pts - now) / 90_000)
            }
        }
        let untilHealth = Double(Int64(nextHealthReport.uptimeNanoseconds)
            - Int64(DispatchTime.now().uptimeNanoseconds)) / 1e9
        return max(min(delay, untilHealth), Self.shortestPumpDelay)
    }

    /// About once a second: stall detection and the diagnostics the stats overlay shows.
    func reportHealth() {
        guard !stopped else { return }
        // A finite source that ended, or an ingest holding back for the reader, delivers nothing and isn't stalled.
        let lastActivity = max(lastDataArrival, progress.lastBacklogChange)
        if !paused, !stallReported, !ending.ingestEnded, !progress.isBacklogged,
           Date().timeIntervalSince(lastActivity) > Self.stallTimeout {
            stallReported = true
            Self.log.notice("Stalled: no data for \(Self.stallTimeout) s")
            onEvent(.stalled)
        }
        let elapsed = max(Date().timeIntervalSince(ingestStart), 1)
        let rate = Double(ring.writeHead) / elapsed
        var diagnostics = PlaybackDiagnostics()
        diagnostics.bytesPerSecond = rate
        let backlog = rate > 0 ? Double(ring.writeHead - readOffset) / rate : 0
        if let window = timelineWindow, let position = seek.lastPosition, !isFiniteSource {
            diagnostics.secondsBehindLive = max(0, window.upperBound - position)
        } else {
            diagnostics.secondsBehindLive = max(0, backlog - 1)
        }
        if !paused, pendingPictures.count >= Self.maxPendingPictures, renderer.rate == 0 {
            // A backstop: reading has stopped behind a full picture queue and the clock can't move. Whatever led
            // here, a new timeline gets playback going again.
            Self.log.notice("Stuck: \(self.pendingPictures.count) pictures waiting and the clock stopped")
            timelineGuard.reset()
            restartTimeline()
        }
        if !paused, renderer.guardLiveBuffer() {
            Self.log.notice("Rebuffering: audio ran low (\(self.renderer.audioSecondsAhead) s ahead)")
        }
        diagnostics.audioSecondsBuffered = renderer.audioSecondsAhead
        diagnostics.videoSecondsBuffered = renderer.videoSecondsAhead
        diagnostics.framesShown = lastMetrics.shown
        diagnostics.framesDropped = lastMetrics.dropped
        onEvent(.diagnostics(diagnostics))
        if PipelineTrace.isEnabled {
            trace.report(diagnostics, behindSeconds: backlog, pending: pendingPictures.count, rate: renderer.rate,
                         video: videoStage.takeTimings())
        }
        renderer.videoRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let metrics, let self else { return }
            queue.async { self.lastMetrics = (metrics.totalNumberOfFrames, metrics.numberOfDroppedFrames) }
        }
    }

    /// Logs the renderer's frame counts every 10 s, for diagnosing smoothness.
    func logPerformance() {
        let audioAhead = renderer.audioSecondsAhead
        let videoAhead = renderer.videoSecondsAhead
        let pending = pendingPictures.count
        renderer.videoRenderer.loadVideoPerformanceMetrics { metrics in
            guard let metrics else { return }
            Self.log.notice("""
                Video frames \(metrics.totalNumberOfFrames), dropped \(metrics.numberOfDroppedFrames), \
                corrupted \(metrics.numberOfCorruptedFrames); ahead audio \(audioAhead) s, video \(videoAhead) s, \
                pending pictures \(pending)
                """)
        }
    }
}
