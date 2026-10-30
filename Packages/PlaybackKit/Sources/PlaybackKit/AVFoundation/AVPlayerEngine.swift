//
//  AVPlayerEngine.swift
//  PlaybackKit
//
//  The PlaybackEngine for HLS, progressive MP4/MOV and DASH (translated to HLS), built on AVPlayer. Plain HLS and files
//  go straight to AVPlayer, which keeps AirPlay and PiP. DASH and HLS multivariant playlists that AVPlayer rejects are
//  served through PlaylistResourceLoader. Fetching, parsing and probing run off the main actor; the engine itself and
//  every AVFoundation object it owns stay on it. HDR-only playlists on a display that can't show HDR play as a
//  tone-mapped split (AVPlayerEngineSplit.swift).
//

import AVFoundation
import Foundation
import Observation
import QuartzCore

@Observable
public final class AVPlayerEngine: PlaybackEngine {
    public nonisolated enum InputKind: String, Equatable, Sendable {
        case hls
        case dash
        /// Progressive MP4/MOV/M4V, local or remote.
        case file
    }

    /// How the stream reached AVPlayer.
    public nonisolated enum Route: String, Equatable, Sendable {
        /// The URL as given.
        case direct
        /// An HLS multivariant playlist repaired and served through the resource loader.
        case repairedMultivariant
        /// A DASH MPD translated to HLS and served through the resource loader.
        case translatedDASH
        /// An HDR-only presentation on a display that can't show HDR: the video variant's media playlist on the
        /// main player (tone-mapped by AVPlayer) and the audio rendition's on a second, synced player.
        case toneMappedSplit
    }

    public nonisolated struct Configuration: Equatable, Sendable {
        /// The private URL scheme for served playlists; the host injects its own, so the package has no branding.
        public var playlistScheme: String
        /// Caps how far ahead AVPlayer buffers; VOD servers were seen delivering 45–50 Mbps while prebuffering.
        public var preferredForwardBufferDuration: TimeInterval
        /// Fetch HLS multivariant playlists first and repair them before AVPlayer sees them, when they lack
        /// VIDEO-RANGE, FRAME-RATE or complete CODECS. The repair also runs after AVPlayer rejects a playlist.
        public var repairsHLSProactively: Bool
        public var dashVariantPolicy: DASHToHLSTranslator.VariantPolicy
        /// Whether the display can show HDR; `.system` asks AVPlayer when a stream loads. Tests force it.
        public var hdrEligibility: HDRDisplayEligibility
        /// Live content that keeps its start (an HLS EVENT playlist: a recording still being written) opens at
        /// its first segment instead of near the live edge.
        public var startsAtBeginning: Bool

        public init(playlistScheme: String = "playbackkit-hls", preferredForwardBufferDuration: TimeInterval = 20,
                    repairsHLSProactively: Bool = true,
                    dashVariantPolicy: DASHToHLSTranslator.VariantPolicy = .bestPerAdaptationSet,
                    hdrEligibility: HDRDisplayEligibility = .system, startsAtBeginning: Bool = false) {
            self.playlistScheme = playlistScheme
            self.preferredForwardBufferDuration = preferredForwardBufferDuration
            self.repairsHLSProactively = repairsHLSProactively
            self.dashVariantPolicy = dashVariantPolicy
            self.hdrEligibility = hdrEligibility
            self.startsAtBeginning = startsAtBeginning
        }
    }

    public let url: URL
    public let inputKind: InputKind
    public let configuration: Configuration
    /// Sent with every request for the stream (a server's token), never put in a URL.
    public let requestHeaders: [String: String]

    public internal(set) var state: PlaybackState = .idle
    public private(set) var streamInfo = PlaybackStreamInfo()
    /// How the stream reached AVPlayer, once known. Served routes can't AirPlay video.
    public internal(set) var route: Route?
    /// Playback stalls since start.
    public private(set) var stallCount = 0
    /// Subtitle and caption renditions (HLS `SUBTITLES` and `CLOSED-CAPTIONS`, embedded 608 in MP4), once loaded.
    public internal(set) var subtitleOptions: [SubtitleOption] = []
    public internal(set) var selectedSubtitleID: String?

    public var isMuted = false {
        didSet { applyMute() }
    }

    // Multi-view (AVPlayerEngineTiles.swift).
    public internal(set) var decodeTier = DecodeTier.single
    public var playsAudio = true {
        didSet { applyVolume() }
    }
    public var volume: Float = 1 {
        didSet { applyVolume() }
    }

    /// The AVPlayerLayer showing the video (`.resizeAspect`); the same object for the engine's life.
    @ObservationIgnored public let playerLayer: AVPlayerLayer
    public var displayLayer: CALayer { playerLayer }
    @ObservationIgnored public let displayView: PlatformView

    /// The playback position in seconds (not observable; poll it for a clock display).
    public var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored var generation = 0
    @ObservationIgnored var isItemReady = false
    @ObservationIgnored var observations: [NSKeyValueObservation] = []
    @ObservationIgnored var notificationTasks: [Task<Void, Never>] = []
    @ObservationIgnored var timeObserver: Any?
    @ObservationIgnored var hasLoadedTrackFormats = false
    @ObservationIgnored var legibleGroup: AVMediaSelectionGroup?
    @ObservationIgnored let frameTapHub = FrameTapHub()
    /// Attached only while something reads frames back (a tap, or a `latestFrame()` call).
    @ObservationIgnored var videoOutput: AVPlayerItemVideoOutput?
    @ObservationIgnored var tapTask: Task<Void, Never>?
    @ObservationIgnored var loadTask: Task<Void, Never>?
    @ObservationIgnored var loader: PlaylistResourceLoader?
    @ObservationIgnored var session: URLSession?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasStopped = false
    @ObservationIgnored private(set) var isPausedByUser = false
    @ObservationIgnored private var attemptedRepair = false
    /// The audio player of a tone-mapped split, when the split has separate audio.
    @ObservationIgnored var follower: SplitAudioFollower?
    /// The multivariant playlist last given to AVPlayer and the URL its URIs resolve against, for the split fallback.
    @ObservationIgnored var knownMultivariant: (playlist: HLSMultivariantPlaylist, baseURL: URL)?
    @ObservationIgnored var attemptedSplit = false
    /// The timeline's seeks (AVPlayerEngineTimeline.swift).
    @ObservationIgnored var seeks = SeekQueue()

    public init(url: URL, kind: InputKind, configuration: Configuration = Configuration(),
                requestHeaders: [String: String] = [:]) {
        self.url = url
        self.inputKind = kind
        self.configuration = configuration
        self.requestHeaders = requestHeaders
        let player = AVPlayer()
        self.player = player
        let display = DisplayView.player(player)
        display.layer.videoGravity = .resizeAspect
        self.playerLayer = display.layer
        self.displayView = display.view
    }

    /// A host that drops the engine without `stop()` still holds the layer, and the layer holds the player, so
    /// release the item here too.
    isolated deinit {
        loadTask?.cancel()
        notificationTasks.forEach { $0.cancel() }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        follower?.stop()
        player.pause()
        player.replaceCurrentItem(with: nil)
        session?.invalidateAndCancel()
    }

    // MARK: PlaybackEngine

    public func start() {
        guard !hasStarted, !hasStopped else { return }
        hasStarted = true
        state = .connecting
        let token = generation
        loadTask = Task { [weak self] in
            await self?.load(token: token)
        }
    }

    public func pause() {
        guard state.isActive, state != .paused else { return }
        isPausedByUser = true
        player.pause()
        follower?.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        isPausedByUser = false
        if let follower {
            follower.resume()
        } else if player.currentItem != nil {
            player.play()
        }
        state = isItemReady ? .buffering : .connecting
        updateStateFromPlayer()
    }

    public func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        generation += 1
        loadTask?.cancel()
        loadTask = nil
        tearDownItemObservers()
        tapTask?.cancel()
        frameTapHub.finishAll()
        stopFollower()
        player.pause()
        player.replaceCurrentItem(with: nil)
        loader?.removeAll()
        loader = nil
        session?.invalidateAndCancel()
        session = nil
        if state.isActive {
            state = .idle
        }
    }

    // MARK: Loading

    private func load(token: Int) async {
        guard isCurrent(token) else { return }
        switch inputKind {
        case .file:
            play(asset: makeAsset(url), route: .direct, token: token)
        case .dash:
            do {
                let presentation = try await DASHPresentationLoader.load(mpdURL: url, fetcher: makeFetcher(),
                                                                         policy: configuration.dashVariantPolicy)
                serve(presentation, route: .translatedDASH, token: token)
            } catch {
                guard isCurrent(token) else { return }
                fail(error)
            }
        case .hls:
            await loadHLS(token: token)
        }
    }

    /// Fetches the playlist when it may need a repair or a split, repairs it if needed, and otherwise plays the URL
    /// as given (or as a tone-mapped split).
    private func loadHLS(token: Int) async {
        let fetcher = makeFetcher()
        var multivariant: HLSMultivariantPlaylist?
        if configuration.repairsHLSProactively || !isHDREligible {
            multivariant = try? await HLSMultivariantRepair.fetchMultivariant(url: url, fetcher: fetcher)
        }
        guard isCurrent(token) else { return }
        if let multivariant {
            if configuration.repairsHLSProactively,
               let repaired = await HLSMultivariantRepair.prepare(multivariant, url: url, fetcher: fetcher,
                                                                  force: false) {
                attemptedRepair = true
                return serve(repaired, route: .repairedMultivariant, token: token)
            }
            guard isCurrent(token) else { return }
            knownMultivariant = (multivariant, url)
            if splitIfNeeded(multivariant, baseURL: url, token: token) { return }
        }
        play(asset: makeAsset(url), route: .direct, token: token)
    }

    /// After AVPlayer rejected the multivariant playlist: repair it unconditionally and try once more.
    private func repairAfterRejection(_ rejection: any Error, token: Int) async {
        guard isCurrent(token) else { return }
        let repaired = try? await HLSMultivariantRepair.prepare(url: url, fetcher: makeFetcher(), force: true)
        guard isCurrent(token) else { return }
        guard let repaired else { return fail(rejection) }
        serve(repaired, route: .repairedMultivariant, token: token)
    }

    private func serve(_ presentation: HLSPresentation, route: Route, token: Int) {
        guard isCurrent(token) else { return }
        let loader = self.loader ?? PlaylistResourceLoader(scheme: configuration.playlistScheme)
        self.loader = loader
        loader.removeAll()
        loader.publish(presentation)
        guard let entryURL = loader.url(for: HLSPresentation.multivariantName) else {
            return fail(PlaybackError(kind: .source, title: "Can't play this stream",
                                      detail: "The playlist URL scheme is invalid."))
        }
        streamInfo = presentation.streamInfo
        if let playlist = HLSMultivariantPlaylist(text: presentation.multivariantPlaylist) {
            knownMultivariant = (playlist, entryURL)
            if splitIfNeeded(playlist, baseURL: entryURL, token: token) { return }
        }
        play(asset: makeAsset(entryURL), route: route, token: token)
    }

    private func play(asset: AVURLAsset, route: Route, token: Int) {
        guard let item = prepareItem(asset: asset, route: route, token: token) else { return }
        player.replaceCurrentItem(with: item)
        if !isPausedByUser {
            player.play()
        }
    }

    /// Clears the previous item's observers and any split, notes the route, and makes the observed item to play.
    func prepareItem(asset: AVURLAsset, route: Route, token: Int) -> AVPlayerItem? {
        guard isCurrent(token) else { return nil }
        tearDownItemObservers()
        stopFollower()
        noteRoute(route)
        isItemReady = false
        hasLoadedTrackFormats = false
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = configuration.preferredForwardBufferDuration
        observe(item, token: token)
        applyTier(to: item)
        applyMute()
        applyVolume()
        return item
    }

    func isCurrent(_ token: Int) -> Bool {
        token == generation && !hasStopped
    }

    // MARK: State

    func updateStateFromPlayer() {
        guard state.isActive, !isPausedByUser else { return }
        guard isItemReady else {
            state = .connecting
            return
        }
        switch player.timeControlStatus {
        case .playing:
            state = .playing
        case .waitingToPlayAtSpecifiedRate:
            state = .buffering
        case .paused:
            break
        @unknown default:
            break
        }
    }

    func noteStall() {
        stallCount += 1
        if state == .playing {
            state = .buffering
        }
    }

    func noteEnded() {
        guard state.isActive else { return }
        state = .ended
    }

    func setStreamInfo(_ info: PlaybackStreamInfo) {
        if info != streamInfo {
            streamInfo = info
        }
    }

    /// AVPlayer failed. HLS multivariant rejections get one repaired retry; everything else is final.
    func handleFailure(_ error: (any Error)?, token: Int) {
        guard isCurrent(token) else { return }
        if inputKind == .hls, !attemptedRepair, let error, HLSMultivariantRepair.isRepairTrigger(error) {
            attemptedRepair = true
            let next = restartGeneration()
            loadTask = Task { [weak self] in
                await self?.repairAfterRejection(error, token: next)
            }
            return
        }
        if let error, canFallBackToSplit(after: error) {
            return beginSplitFallback(after: error)
        }
        fail(error)
    }

    /// Starts a new load generation after a rejection, keeping the user's pause.
    func restartGeneration() -> Int {
        generation += 1
        tearDownItemObservers()
        stopFollower()
        player.replaceCurrentItem(with: nil)
        state = isPausedByUser ? .paused : .connecting
        return generation
    }

    func fail(_ error: (any Error)?, hdrDisplayRequired: Bool = false) {
        let split = route == .toneMappedSplit
        tearDownItemObservers()
        stopFollower()
        player.pause()
        player.replaceCurrentItem(with: nil)
        // A split already is the tone-mapping route; if it fails too on a display without HDR, say so plainly.
        if hdrDisplayRequired || (split && !isHDREligible && Self.isToneMappingFailure(error)) {
            state = .failed(PlaybackErrorMapping.hdrDisplayRequired(from: error))
        } else {
            state = .failed(PlaybackErrorMapping.playbackError(from: error))
        }
    }
}
