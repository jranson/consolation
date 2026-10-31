//
//  MatroskaEngine.swift
//  PlaybackKit
//
//  Plays a Matroska file (MKV, and WebM with codecs Apple decodes) from a local file or an HTTP(S) resource with our
//  own demuxer and the transport stream engine's decoders and renderers: H.264 and HEVC through VideoToolbox in
//  hardware, MPEG-2 through libavcodec, AAC, AC-3 and E-AC-3 through AVSampleBufferAudioRenderer. Plays to the end
//  and stops there, still seekable; seeks use the file's Cues. A file with only audio Apple can't decode (DTS,
//  TrueHD) plays its video with `PlaybackStreamInfo.unsupportedAudioCodec` set.
//

import AVFoundation
import Foundation
import Observation
import QuartzCore

@Observable
public final class MatroskaEngine: PlaybackEngine, LivePlaybackControlling, AudioTrackSelecting {
    public private(set) var state: PlaybackState = .idle
    public private(set) var streamInfo = PlaybackStreamInfo(isLive: false)
    public private(set) var diagnostics = PlaybackDiagnostics()
    public private(set) var audioTracks: [AudioTrackOption] = []
    public private(set) var selectedAudioTrackID: Int?
    public let displayLayer: CALayer
    public let displayView: PlatformView

    public var isMuted = false {
        didSet { pipeline?.renderer.isMuted = isMuted }
    }

    public private(set) var decodeTier = DecodeTier.single

    public var playsAudio = true {
        didSet {
            guard playsAudio != oldValue else { return }
            pipeline?.setPlaysAudio(playsAudio)
        }
    }

    public var volume: Float = 1 {
        didSet { pipeline?.renderer.volume = volume }
    }

    @ObservationIgnored private let makeSource: @Sendable () -> any ByteSource
    @ObservationIgnored private let bufferBytes: Int
    @ObservationIgnored private let preferredLanguage: String
    @ObservationIgnored private var pipeline: MatroskaPipeline?
    @ObservationIgnored private let frameTapHub = FrameTapHub()

    /// `makeSource` is called once, when playback starts: a `FileByteSource` or an `HTTPByteSource`, which can both
    /// be reopened at an offset to seek. `bufferBytes` is the read-ahead held in memory.
    public init(makeSource: @escaping @Sendable () -> any ByteSource,
                bufferBytes: Int = 48 << 20, preferredLanguage: String = "eng") {
        self.makeSource = makeSource
        self.bufferBytes = bufferBytes
        self.preferredLanguage = preferredLanguage
        let display = DisplayView.sampleBuffer()
        display.layer.videoGravity = .resizeAspect
        displayLayer = display.layer
        displayView = display.view
    }

    public func start() {
        guard state == .idle else { return }
        guard let layer = displayLayer as? AVSampleBufferDisplayLayer else {
            state = .failed(PlaybackError(kind: .renderer, title: "The video couldn't be shown."))
            return
        }
        state = .connecting
        let renderer = SampleRenderer(videoRenderer: layer.sampleBufferRenderer, frameTap: frameTapHub)
        renderer.isMuted = isMuted
        renderer.volume = volume
        let pipeline = MatroskaPipeline(source: makeSource(), ring: MemoryByteRing(capacity: bufferBytes),
                                        renderer: renderer, preferredLanguage: preferredLanguage, tier: decodeTier,
                                        playsAudio: playsAudio) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.pipeline = pipeline
        pipeline.start()
    }

    public func pause() {
        guard state == .playing || state == .buffering else { return }
        pipeline?.setPaused(true)
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        pipeline?.setPaused(false)
        state = .playing
    }

    public func stop() {
        pipeline?.stop()
        pipeline = nil
        frameTapHub.finishAll()
        if state.isActive || state == .idle { state = .ended }
    }

    /// The file's length, from its first picture. Nil until the length and the first picture are known.
    public func timeline() -> PlaybackTimeline? {
        guard state.isActive || state == .ended else { return nil }
        return pipeline?.published.timeline()
    }

    /// Seeks anywhere in the file. A paused stream stays paused and shows the picture at the new point; one that
    /// ended plays on from there.
    public func seek(toPosition position: Double) {
        guard let pipeline, let current = timeline() else { return }
        pipeline.published.pendingSeek = min(max(position, current.range.lowerBound), current.range.upperBound)
        pipeline.seek(toTime: position)
        if state == .ended {
            state = .playing
            pipeline.setPaused(false)
        }
    }

    /// A file has no live edge: this goes to its end.
    public func jumpToLive() {
        guard let end = timeline()?.range.upperBound else { return }
        seek(toPosition: end)
    }

    public func skip(seconds: Double) {
        pipeline?.skip(seconds: seconds)
        if state == .ended, let pipeline {
            state = .playing
            pipeline.setPaused(false)
        }
    }

    public func setDecodeTier(_ tier: DecodeTier) {
        guard tier != decodeTier else { return }
        decodeTier = tier
        pipeline?.setDecodeTier(tier)
    }

    public func selectAudioTrack(id: Int) {
        guard id != selectedAudioTrackID, let number = UInt64(exactly: id) else { return }
        pipeline?.selectAudio(track: number)
    }

    private func handle(_ event: MatroskaPipeline.Event) {
        guard state.isActive else { return }
        switch event {
        case .started(let info):
            streamInfo = info
            if state != .paused { state = .playing }
        case .info(let info):
            streamInfo = info
        case .audioTracks(let tracks, let selected):
            audioTracks = tracks
            selectedAudioTrackID = selected
        case .diagnostics(let latest):
            diagnostics = latest
        case .failed(let error):
            pipeline?.stop()
            state = .failed(error)
        case .finished:
            // Stop at the end with the last picture on screen, keeping the pipeline for a seek back.
            pipeline?.setPaused(true)
            state = .ended
        }
    }
}

extension MatroskaEngine: FrameTapping {
    public func frameTap(_ request: FrameTapRequest) -> AsyncStream<FrameTapSample> {
        frameTapHub.add(request)
    }

    public func latestFrame() async -> CVPixelBuffer? {
        (displayLayer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer.displayedPixelBuffer()
    }
}
