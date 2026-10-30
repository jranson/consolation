//
//  TransportStreamEngine.swift
//  PlaybackKit
//
//  Plays a raw MPEG-TS stream (HDHomeRun live TV, MPEG-TS URLs and files) with our own demuxer and the system's
//  sample-buffer renderers: MPEG-2 video through libavcodec, H.264 and HEVC through VideoToolbox in hardware, and
//  AC-3/E-AC-3 audio through AVSampleBufferAudioRenderer. Live sources reconnect when they drop; finite ones (files)
//  play to their end and stop there, still seekable. The timeline is the time-shift buffer of a live stream, or a
//  file's whole length (TransportStreamPipelineSeek.swift).
//

import AVFoundation
import Foundation
import Observation
import QuartzCore

/// Time-shift buffer settings for live streams.
nonisolated public struct TimeShiftConfiguration: Sendable, Equatable {
    public enum Storage: Sendable, Equatable {
        case memory
        case temporaryFile
    }

    public var storage: Storage
    public var capacityBytes: Int

    public init(storage: Storage = .temporaryFile, capacityBytes: Int = 2_048 << 20) {
        self.storage = storage
        self.capacityBytes = capacityBytes
    }
}

@Observable
public final class TransportStreamEngine: PlaybackEngine, LivePlaybackControlling, AudioTrackSelecting,
    CaptionProviding {
    /// The smallest disk time-shift buffer, whatever the free space says (about 30 s of HD).
    static let minimumFileRing = 64 << 20

    /// Deletes time-shift files left behind by earlier runs that were killed while playing. Call once at launch.
    public static func removeLeftoverTimeShiftFiles() {
        FileByteRing.removeLeftovers()
    }

    /// Waits before each reconnect attempt after a stall or a dropped connection; then playback fails.
    static let reconnectDelays: [Duration] = [.seconds(1), .seconds(3)]

    public private(set) var state: PlaybackState = .idle
    public private(set) var streamInfo = PlaybackStreamInfo(isLive: true)
    public private(set) var diagnostics = PlaybackDiagnostics()
    public private(set) var audioTracks: [AudioTrackOption] = []
    public private(set) var selectedAudioTrackID: Int?
    public private(set) var captionScreen = CaptionScreen.empty
    public private(set) var availableCaptionServices: [CaptionService] = []
    public private(set) var captionService = CaptionService.cc1
    public let displayLayer: CALayer
    public let displayView: PlatformView

    public var isMuted = false {
        didSet {
            pipeline?.renderer.isMuted = isMuted
        }
    }

    // Multi-view. All three outlive reconnects: each new pipeline starts with them.
    public private(set) var decodeTier = DecodeTier.single

    /// A silent tile frames its audio but never decodes it; the clock and the reader's pacing don't change, so
    /// turning it back on plays from the clock's current time without a rebuffer.
    public var playsAudio = true {
        didSet {
            guard playsAudio != oldValue else { return }
            pipeline?.setPlaysAudio(playsAudio)
        }
    }

    public var volume: Float = 1 {
        didSet {
            pipeline?.renderer.volume = volume
        }
    }

    @ObservationIgnored private let makeSource: @Sendable () -> any ByteSource
    @ObservationIgnored private let timeShift: TimeShiftConfiguration
    @ObservationIgnored private let preferredLanguage: String
    @ObservationIgnored private var reconnectAttempt = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnects = 0
    @ObservationIgnored private var pipeline: TransportStreamPipeline?
    /// Outlives reconnects, so a tap keeps running across them.
    @ObservationIgnored private let frameTapHub = FrameTapHub()

    /// `makeSource` is called once per connection attempt; each source owns exactly one connection (one tuner).
    public init(makeSource: @escaping @Sendable () -> any ByteSource,
                timeShift: TimeShiftConfiguration = TimeShiftConfiguration(), preferredLanguage: String = "eng") {
        self.makeSource = makeSource
        self.timeShift = timeShift
        self.preferredLanguage = preferredLanguage
        let display = DisplayView.sampleBuffer()
        display.layer.videoGravity = .resizeAspect
        displayLayer = display.layer
        displayView = display.view
    }

    public func start() {
        guard state == .idle else { return }
        state = .connecting
        startPipeline()
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
        reconnectTask?.cancel()
        pipeline?.stop()
        pipeline = nil
        frameTapHub.finishAll()
        if state.isActive || state == .idle { state = .ended }
    }

    public func jumpToLive() {
        pipeline?.jumpToLive()
        if state == .paused { resume() }
    }

    /// The time-shift buffer (live) or the file's length, on the stream's own clock: seconds from the first
    /// picture received (live) or the file's first picture. Nil until the first pictures are indexed.
    public func timeline() -> PlaybackTimeline? {
        guard state.isActive || state == .ended else { return nil }
        return pipeline?.published.timeline()
    }

    /// Seeks within the buffer, or anywhere in a file. A live stream asked for its live edge goes to live. A paused
    /// stream stays paused and shows the picture at the new point; one that ended plays on from there.
    public func seek(toPosition position: Double) {
        guard let pipeline, let current = timeline() else { return }
        pipeline.published.pendingSeek = min(max(position, current.range.lowerBound), current.range.upperBound)
        pipeline.seek(toTime: position)
        if state == .ended {
            state = .playing
            pipeline.setPaused(false)
        }
    }

    public func setDecodeTier(_ tier: DecodeTier) {
        guard tier != decodeTier else { return }
        decodeTier = tier
        pipeline?.setDecodeTier(tier)
    }

    /// The running pipeline's tier and audio (nil between connections), for tests.
    var pipelineTileState: (tier: DecodeTier, playsAudio: Bool)? {
        pipeline.map { pipeline in
            let state = pipeline.tileState()
            return (state.tier, state.playsAudio)
        }
    }

    public func selectAudioTrack(id: Int) {
        guard id != selectedAudioTrackID, let pid = UInt16(exactly: id) else { return }
        pipeline?.selectAudio(pid: pid)
    }

    public func selectCaptionService(_ service: CaptionService) {
        captionService = service
        pipeline?.selectCaptions(service)
    }

    /// Moves by `seconds` on the timeline (the same as `skip(by:)`).
    public func skip(seconds: Double) {
        pipeline?.skip(seconds: seconds)
    }

    private func startPipeline() {
        guard let layer = displayLayer as? AVSampleBufferDisplayLayer, let ring = makeRing() else {
            state = .failed(PlaybackError(kind: .renderer, title: "Couldn't create the time-shift buffer."))
            return
        }
        let renderer = SampleRenderer(videoRenderer: layer.sampleBufferRenderer, frameTap: frameTapHub)
        renderer.isMuted = isMuted
        renderer.volume = volume
        let pipeline = TransportStreamPipeline(source: makeSource(), ring: ring, renderer: renderer,
                                               preferredLanguage: preferredLanguage, tier: decodeTier,
                                               playsAudio: playsAudio) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        self.pipeline = pipeline
        pipeline.start()
    }

    private func makeRing() -> (any ByteRing)? {
        switch timeShift.storage {
        case .memory:
            return MemoryByteRing(capacity: timeShift.capacityBytes)
        case .temporaryFile:
            // Never more than half the free space: an Apple TV has little, and several tiles each keep a buffer.
            let free = FileByteRing.availableBytes().map { $0 / 2 } ?? timeShift.capacityBytes
            let capacity = max(min(timeShift.capacityBytes, free), Self.minimumFileRing)
            return FileByteRing(capacity: capacity)
                ?? MemoryByteRing(capacity: min(timeShift.capacityBytes, 512 << 20))
        }
    }

    private func handle(_ event: TransportStreamPipeline.Event) {
        guard state.isActive else { return }
        switch event {
        case .started(let info):
            streamInfo = info
            reconnectAttempt = 0
            if state != .paused { state = .playing }
        case .info(let info):
            streamInfo = info
        case .captions(let screen):
            captionScreen = screen
        case .captionServices(let services):
            availableCaptionServices = services
        case .audioTracks(let tracks, let selected):
            audioTracks = tracks
            selectedAudioTrackID = selected
        case .diagnostics(var latest):
            latest.reconnects = reconnects
            diagnostics = latest
        case .failed(let error):
            pipeline?.stop()
            if error.kind == .network { reconnect(after: error) } else { state = .failed(error) }
        case .finished:
            // A file or other finite stream played to its end: stop there with its last picture on screen, keeping
            // the buffer (and the source, if it can be reopened) for a seek back. `stop()` releases them.
            pipeline?.setPaused(true)
            state = .ended
        case .ended, .stalled:
            // A live source that ended or went quiet: reconnect.
            reconnect(after: PlaybackError(kind: .network, title: "Signal lost.",
                                           detail: "The stream stopped and couldn't be restarted."))
        }
    }

    /// Restarts the connection after a stall or drop, a couple of times, before giving up.
    private func reconnect(after error: PlaybackError) {
        guard reconnectAttempt < Self.reconnectDelays.count else {
            pipeline?.stop()
            pipeline = nil
            state = .failed(error)
            return
        }
        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        reconnects += 1
        pipeline?.stop()
        pipeline = nil
        if state != .paused { state = .buffering }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.state.isActive else { return }
            self.startPipeline()
        }
    }
}

extension TransportStreamEngine: FrameTapping {
    public func frameTap(_ request: FrameTapRequest) -> AsyncStream<FrameTapSample> {
        frameTapHub.add(request)
    }

    public func latestFrame() async -> CVPixelBuffer? {
        (displayLayer as? AVSampleBufferDisplayLayer)?.sampleBufferRenderer.displayedPixelBuffer()
    }
}
