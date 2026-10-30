//
//  PlayerSession.swift
//  Consolation
//
//  What plays: one stream, or several tiles in multi-view, all through PlayerKit's `MultiViewSession`, so the player's
//  one video surface never changes. The engine, item, controls, channel up/down and pause act on the target tile (the
//  single, front or focused one). Also the chrome and banner timers and releasing the tuner after a long pause.
//

import CoreGraphics
import Foundation
import Observation
import PlaybackKit
import PlayerKit
import VideoToolbox

@Observable
final class PlayerSession {
    /// Makes an engine for an item in a tile. `isAdded` is true for every tile but the first (a multi-view tile,
    /// which must leave the reserved tuners alone).
    typealias EngineFactory = (PlayingItem, TileID, _ isAdded: Bool) -> any PlaybackEngine

    static let channelFlipDebounce: Duration = .milliseconds(400)

    let preferences: PlaybackPreferences
    /// Every playing stream: one tile, or several in multi-view.
    let multiView: MultiViewSession<PlayingItem>
    /// Saves resume positions of on-demand playback for Continue Watching; nil saves none.
    @ObservationIgnored var resumeRecorder: ResumeRecorder?

    /// System Picture in Picture for the audible engine, where supported.
    var pictureInPicture: PictureInPicture?
    /// macOS: live TV shows in the app's floating video window (`togglePictureInPicture`).
    var isFloating = false {
        didSet { updatePresentation() }
    }
    /// A channel flip waiting out its debounce: the banner shows it before it tunes.
    private(set) var pendingItem: PlayingItem?
    /// The tiles Picture in Picture closed, for "Restore Multi-view".
    var multiViewSnapshot: MultiViewSnapshot<PlayingItem>?
    /// The channels channel up/down moves through (the Live TV pane's current view).
    private(set) var channelList: [LiveChannel] = []
    private(set) var previousChannel: LiveChannel?
    /// Set when a long pause released the tuner; Resume re-tunes.
    private(set) var tunerReleased = false
    /// The last picture before the tuner was released, shown while paused without a stream.
    private(set) var freezeFrame: CGImage?
    /// Set when going to the background closed the stream; returning to the foreground reopens it.
    private(set) var releasedForBackground = false
    /// Whether the player fills the window (Now Playing) rather than the mini player. On iOS, only full-screen
    /// playback starts Picture in Picture on its own when the app goes to the background.
    var isFullScreen = false {
        didSet {
            pictureInPicture?.startsAutomatically = isFullScreen && !multiView.isMultiView
            updatePresentation()
        }
    }

    /// Which window shows the video when the app has several (iPad, iPhone Duo, Mac); the others show "Playing in
    /// another window". Nil until a window shows the player or the mini player.
    private(set) var videoWindow: UUID?
    @ObservationIgnored private var openWindows: Set<UUID> = []
    /// Zoom to Fill on the video layer: the video fills the view, cropping its edges, instead of fitting with bars
    /// (for example 16:9 video on iPhone Duo's 1.42:1 inner display). Follows the window showing the video.
    private(set) var fillsView = false {
        didSet {
            for tile in multiView.tiles { tile.engine.setVideoFill(fillsView ? .fill : .fit) }
        }
    }
    var controlsVisible = false
    var bannerVisible = false
    /// The technical stats overlay (I key).
    var statsVisible = false
    /// The Add Tile or Replace picker on screen, if any.
    var tilePicker: TilePickerRequest?
    /// A short note about multi-view ("Every tuner is in use"), shown over the player for a moment.
    var multiViewNotice: String?
    /// Apple TV: asks the player's chrome to show the controls with focus in them (Select on the front tile).
    var controlsFocusRequest = 0
    /// Apple TV: focus is in the controls bar, so the tiles below take no input.
    var controlsHaveFocus = false
    @ObservationIgnored var noticeTask: Task<Void, Never>?
    /// Digits typed for direct channel entry, committed after a short pause.
    private(set) var enteredDigits = ""
    /// tvOS: the on-screen number pad the remote's 123 button opens.
    var numberPadVisible = false

    @ObservationIgnored var chromeTask: Task<Void, Never>?
    /// Apple TV: Play/Pause asked for the controls with focus on the timeline; the scrubber takes it and clears this.
    var timelineFocusRequested = false
    /// Apple TV: focus is in the controls, so they don't hide on their own, and the video behind them takes no
    /// focus (a left or right press on the timeline otherwise moved focus to it, cancelling the scrub).
    var controlsPinned = false
    @ObservationIgnored var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var flipTask: Task<Void, Never>?
    @ObservationIgnored private var pauseReleaseTask: Task<Void, Never>?
    @ObservationIgnored private var digitTask: Task<Void, Never>?

    static let digitCommitDelay: Duration = .milliseconds(1_500)

    /// - Parameter capacity: whether a source can feed one more tile (the tuner broker); nil allows any within the
    ///   tile budget.
    init(preferences: PlaybackPreferences, capacity: (any TileCapacityProviding<PlayingItem>)? = nil,
         makeEngine: @escaping EngineFactory) {
        self.preferences = preferences
        let owner = SessionReference()
        multiView = MultiViewSession(audioFollowsFocus: preferences.audioFollowsFocus, capacity: capacity,
                                     isUnavailable: Self.isTunerUnavailable) { item, tile in
            let session = owner.session
            let tiles = session?.multiView.tiles ?? []
            let engine = makeEngine(item, tile, !tiles.isEmpty && tiles.first?.id != tile)
            engine.setVideoFill(session?.fillsView == true ? .fill : .fit)
            return engine
        }
        owner.session = self
    }

    /// The tile the controls, channel keys and pause act on: the single tile, the front one, or the focused one.
    var targetTile: PlayerTile<PlayingItem>? {
        multiView.state.flatMap { multiView.tile($0.focusedTile) }
    }

    /// The target tile's engine.
    var engine: (any PlaybackEngine)? { targetTile?.engine }

    /// What the target tile plays (or is about to, during a channel flip).
    var item: PlayingItem? { pendingItem ?? targetTile?.item }

    var isActive: Bool { item != nil }

    /// Time-shift controls when the engine supports them (live MPEG-TS).
    var liveControls: (any LivePlaybackControlling)? { engine as? any LivePlaybackControlling }

    var currentChannel: LiveChannel? {
        if case .channel(let channel) = item { return channel }
        return nil
    }

    // MARK: - Starting and stopping

    func play(_ channel: LiveChannel, within list: [LiveChannel]) {
        guard !channel.isProtected else {
            showNotice(Self.protectedMessage)
            return
        }
        channelList = list
        if let current = currentChannel, current.key != channel.key { previousChannel = current }
        start(.channel(channel))
        flashBanner()
    }

    /// The channels channel up/down moves through, when none are set yet (a channel added as a tile).
    func setChannelList(_ list: [LiveChannel]) {
        if channelList.isEmpty { channelList = list }
    }

    func play(_ url: URL) {
        channelList = []
        start(.url(url))
    }

    /// Plays a library source's item: a recording, a movie, or a server's live channel.
    func play(_ media: SourceMedia) {
        channelList = []
        start(.media(media))
    }

    /// Stops playback and frees every connection (and so the tuner) right away.
    func stop() {
        flipTask?.cancel()
        pauseReleaseTask?.cancel()
        pictureInPicture?.stop()
        pictureInPicture = nil
        isFloating = false
        resumeRecorder?.end()
        multiView.stopAll()
        pendingItem = nil
        multiViewSnapshot = nil
        tunerReleased = false
        releasedForBackground = false
        freezeFrame = nil
        controlsVisible = false
        bannerVisible = false
        PlaybackAudioSession.deactivate()
    }

    /// Plays `newItem` in the target tile (the same tile, and so the same tuner slot: a flip closes the old stream
    /// before opening the new one), or alone when nothing plays.
    private func start(_ newItem: PlayingItem) {
        pauseReleaseTask?.cancel()
        resumeRecorder?.end()
        tunerReleased = false
        releasedForBackground = false
        freezeFrame = nil
        pendingItem = nil
        PlaybackAudioSession.activate()
        let wasAudible = targetTile.map { $0.id == multiView.audibleTile } ?? true
        if wasAudible { pictureInPicture = nil }
        if let target = targetTile {
            multiView.replaceNow(target.id, with: newItem)
        } else {
            multiView.start(newItem)
        }
        // Picture in Picture is set up once the video is on screen (`displayReady`).
        if !multiView.isMultiView, let engine { resumeRecorder?.begin(newItem, engine: engine) }
    }

    // MARK: - Windows

    func windowOpened(_ window: UUID) {
        openWindows.insert(window)
    }

    /// The video moves to whichever window shows the player next; closing the last window stops playback and frees
    /// the tuner (the Mac app keeps running without a window).
    func windowClosed(_ window: UUID) {
        openWindows.remove(window)
        if videoWindow == window { videoWindow = nil }
        if openWindows.isEmpty { stop() }
    }

    /// Shows the video in `window` with that window's Zoom to Fill.
    func showVideo(in window: UUID, fills: Bool) {
        videoWindow = window
        fillsView = fills
    }

    /// The window showing the video changed its Zoom to Fill.
    func setFillsView(_ fills: Bool, in window: UUID) {
        guard videoWindow == window else { return }
        fillsView = fills
    }

    // MARK: - Background (iOS, iPadOS, tvOS)

    /// Closes the stream (and so frees the tuner) when the app leaves the foreground, unless Picture in Picture
    /// keeps it on screen. The item stays, so the player looks the same on return.
    func enterBackground() {
        guard item != nil, engine != nil, pictureInPicture?.isActive != true else { return }
        flipTask?.cancel()
        pendingItem = nil
        pauseReleaseTask?.cancel()
        resumeRecorder?.end()
        multiView.stopEngines()
        releasedForBackground = true
        PlaybackAudioSession.deactivate()
    }

    /// Reopens what was playing before the app went to the background.
    func enterForeground() {
        guard releasedForBackground else { return }
        releasedForBackground = false
        tunerReleased = false
        freezeFrame = nil
        PlaybackAudioSession.activate()
        multiView.restartEngines()
    }

    /// Starts the current item again from scratch (the error card's Retry).
    func retry() {
        guard let item else { return }
        start(item)
    }

    // MARK: - Pause and the tuner release timer

    func togglePause() {
        guard let engine else { return }
        if tunerReleased, let item {
            start(item)
            return
        }
        switch engine.state {
        case .paused:
            pauseReleaseTask?.cancel()
            engine.resume()
        case .playing, .buffering, .connecting:
            engine.pause()
            resumeRecorder?.capture()
            scheduleTunerRelease()
        default:
            break
        }
        showControlsBriefly()
    }

    private func scheduleTunerRelease() {
        guard item?.isLive == true else { return }
        pauseReleaseTask?.cancel()
        let minutes = PlaybackPreferences.clampedRelease(preferences.tunerReleaseMinutes)
        pauseReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled, let self, self.engine?.state == .paused else { return }
            self.freezeFrame = await Self.image(of: self.engine)
            guard !Task.isCancelled, let engine = self.engine, engine.state == .paused else { return }
            engine.stop()
            self.tunerReleased = true
        }
    }

    /// The picture on screen now, as an image.
    private static func image(of engine: (any PlaybackEngine)?) async -> CGImage? {
        guard let tapping = engine as? any FrameTapping, let buffer = await tapping.latestFrame() else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &image)
        return image
    }

    // MARK: - Channels

    func channelUp() { flip(by: 1) }
    func channelDown() { flip(by: -1) }

    func playPreviousChannel() {
        guard let previousChannel else { return }
        play(previousChannel, within: channelList)
    }

    /// Debounced so flipping quickly through channels only tunes the one the user lands on.
    private func flip(by step: Int) {
        guard let current = currentChannel, !channelList.isEmpty else { return }
        let index = channelList.firstIndex { $0.key == current.key } ?? 0
        let next = channelList[(index + step + channelList.count) % channelList.count]
        previousChannel = current
        pendingItem = .channel(next)
        flashBanner()
        flipTask?.cancel()
        let tile = targetTile?.id
        flipTask = Task { [weak self] in
            try? await Task.sleep(for: Self.channelFlipDebounce)
            guard !Task.isCancelled, let self, case .channel(let target) = self.pendingItem else { return }
            // Focus moved to another tile meanwhile: the flip was meant for the one it left.
            guard self.targetTile?.id == tile else {
                self.pendingItem = nil
                return
            }
            self.start(.channel(target))
        }
    }

    /// Direct channel entry: digits and "." build a guide number; it tunes after a short pause.
    func enterDigit(_ character: Character) {
        guard currentChannel != nil || !channelList.isEmpty, character.isNumber || character == "." else { return }
        enteredDigits.append(character)
        digitTask?.cancel()
        // The on-screen number pad waits for its Go key; a remote is slower than a keyboard.
        guard !numberPadVisible else { return }
        digitTask = Task { [weak self] in
            try? await Task.sleep(for: Self.digitCommitDelay)
            guard !Task.isCancelled else { return }
            self?.commitDigits()
        }
    }

    /// Removes the last typed digit (the number pad's delete key).
    func deleteDigit() {
        guard !enteredDigits.isEmpty else { return }
        enteredDigits.removeLast()
        digitTask?.cancel()
    }

    /// Tunes what was typed right away (Return, or the number pad's Go key).
    func commitDigits() {
        digitTask?.cancel()
        let typed = enteredDigits
        enteredDigits = ""
        guard !typed.isEmpty else { return }
        let target = typed.contains(".") ? typed : typed + ".1"
        if let channel = channelList.first(where: { $0.guideNumber == target || $0.guideNumber == typed }) {
            play(channel, within: channelList)
        }
    }
}

/// Lets the engine factory reach the session it belongs to (it is made before the session finishes initializing).
private final class SessionReference {
    weak var session: PlayerSession?
}
