//
//  MatroskaPipelineHealth.swift
//  PlaybackKit
//
//  The pipeline's wake-ups, paced like the transport stream pipeline's (the renderers' low-water marks), and the
//  once-a-second diagnostics for the stats overlay.
//

import AVFoundation
import Foundation

nonisolated extension MatroskaPipeline {
    /// One wake-up of the pump timer: feed the renderers, publish the timeline, report when due, re-arm. A finished
    /// stream that is paused sleeps until a seek wakes it.
    func tick() {
        guard !stopped else { return }
        pump()
        publishTimeline()
        let now = DispatchTime.now()
        if now >= nextHealthReport {
            nextHealthReport = now + TransportStreamPipeline.healthInterval
            reportHealth()
        }
        guard !stopped, !(ending.finished && paused) else { return }
        pumpTimer?.schedule(deadline: .now() + nextPumpDelay(), repeating: .never,
                            leeway: TransportStreamPipeline.pumpLeeway)
    }

    /// Brings the next wake-up forward, after a seek, a resume or a restarted timeline.
    func wakeSoon() {
        pumpTimer?.schedule(deadline: .now() + TransportStreamPipeline.busyPumpDelay, repeating: .never,
                            leeway: TransportStreamPipeline.pumpLeeway)
    }

    /// How long the renderers can go without the pump: until queued video or audio falls to its low-water mark or
    /// the next report is due.
    func nextPumpDelay() -> Double {
        var delay = TransportStreamPipeline.longestPumpDelay
        if isReading {
            if renderer.rate == 0 {
                delay = TransportStreamPipeline.busyPumpDelay
            } else {
                delay = min(delay, renderer.videoSecondsAhead - TransportStreamPipeline.videoLowWater)
                if renderer.hasAudioTrack {
                    delay = min(delay, renderer.audioSecondsAhead - TransportStreamPipeline.audioLowWater)
                }
            }
        }
        let untilHealth = Double(Int64(nextHealthReport.uptimeNanoseconds)
            - Int64(DispatchTime.now().uptimeNanoseconds)) / 1e9
        return max(min(delay, untilHealth), TransportStreamPipeline.shortestPumpDelay)
    }

    /// About once a second: the numbers the stats overlay shows.
    func reportHealth() {
        guard !stopped else { return }
        var diagnostics = PlaybackDiagnostics()
        let elapsed = max(Date().timeIntervalSince(ingestStart), 1)
        diagnostics.bytesPerSecond = Double(bytesIngested) / elapsed
        diagnostics.audioSecondsBuffered = renderer.audioSecondsAhead
        diagnostics.videoSecondsBuffered = renderer.videoSecondsAhead
        diagnostics.framesShown = lastMetrics.shown
        diagnostics.framesDropped = lastMetrics.dropped
        diagnostics.reconnects = ingestRetries
        onEvent(.diagnostics(diagnostics))
        renderer.videoRenderer.loadVideoPerformanceMetrics { [weak self] metrics in
            guard let metrics, let self else { return }
            queue.async { self.lastMetrics = (metrics.totalNumberOfFrames, metrics.numberOfDroppedFrames) }
        }
    }
}
