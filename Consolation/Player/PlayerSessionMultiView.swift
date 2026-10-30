//
//  PlayerSessionMultiView.swift
//  Consolation
//
//  Multi-view on the player session: adding, replacing and removing tiles through PlayerKit, Exit Multi-view,
//  how big the player is (full, mini player, hidden while the Mac's floating window shows the video), Picture in
//  Picture following the audible tile, and the captions key.
//

import CoreGraphics
import Foundation
import PlaybackKit
import PlayerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// What the tile picker is choosing for.
enum TilePickerRequest: Identifiable, Equatable {
    /// A new tile (the first one if nothing plays).
    case add
    /// Another item for an existing tile.
    case replace(TileID)

    var id: String {
        switch self {
        case .add: "add"
        case .replace(let tile): "replace-\(tile.rawValue)"
        }
    }
}

extension PlayerSession {
    static let noticeDuration: Duration = .seconds(4)
    static let protectedMessage = String(localized: "This channel is protected (DRM) and can't play on Apple devices.")

    /// "All tuners in use" (805): the tile shows Tuner Unavailable with Retry instead of a failure.
    nonisolated static func isTunerUnavailable(_ error: PlaybackError) -> Bool {
        error.domain == "HDHomeRun" && error.code == 805
    }

    /// Whether two or more tiles play.
    var isMultiView: Bool { multiView.isMultiView }

    /// Full in Now Playing, the mini player elsewhere, hidden while the Mac's floating window has the video (it
    /// hosts the view itself). The mini and hidden player decode only the audible tile.
    func updatePresentation() {
        let presentation: PlayerPresentation = isFloating ? .hidden : (isFullScreen ? .full : .mini)
        multiView.presentation = presentation
    }

    /// Adds `item` as a tile, or plays it when nothing plays. Returns why it couldn't be added, or nil.
    @discardableResult
    func addToMultiView(_ item: PlayingItem, channels: [LiveChannel] = []) async -> String? {
        guard isActive else {
            switch item {
            case .channel(let channel): play(channel, within: channels)
            case .url(let url): play(url)
            case .media(let media): play(media)
            }
            return nil
        }
        if case .channel(let channel) = item {
            guard !channel.isProtected else {
                showNotice(Self.protectedMessage)
                return Self.protectedMessage
            }
            setChannelList(channels)
        }
        do throws(MultiViewError) {
            try await multiView.add(item)
            pictureInPicture?.startsAutomatically = false
            return nil
        } catch {
            showNotice(error.message)
            return error.message
        }
    }

    /// Plays `item` in `tile` instead (the arrangement panel's Replace). Returns why it couldn't, or nil.
    @discardableResult
    func replaceTile(_ tile: TileID, with item: PlayingItem) async -> String? {
        do throws(MultiViewError) {
            try await multiView.replace(tile, with: item)
            return nil
        } catch {
            showNotice(error.message)
            return error.message
        }
    }

    /// Exit Multi-view: keeps the front or focused tile (or `keeping`), which fills the player, and stops the others,
    /// freeing their tuners.
    func exitMultiView(keeping tile: TileID? = nil) {
        multiView.exitMultiView(keeping: tile)
        multiViewSnapshot = nil
        pictureInPicture?.startsAutomatically = isFullScreen
    }

    /// After Picture in Picture closed the other tiles: brings them back around the one still playing.
    func restoreMultiView() {
        guard let snapshot = multiViewSnapshot else { return }
        multiViewSnapshot = nil
        if pictureInPicture?.isActive == true { pictureInPicture?.stop() }
        isFloating = false
        Task {
            let failures = await multiView.restore(snapshot)
            if let first = failures.first { showNotice(first.error.message) }
        }
    }

    /// Shows `message` over the player for a few seconds.
    func showNotice(_ message: String) {
        multiViewNotice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.multiViewNotice = nil
        }
    }

    // MARK: - Picture in Picture

    /// The engine Picture in Picture shows: the audible tile's.
    var pictureInPictureEngine: (any PlaybackEngine)? {
        multiView.audibleEngine ?? engine
    }

    /// A tile's video is on screen with a real size: system Picture in Picture can be set up for it if it is the
    /// audible one (AVKit takes the video's size when its controller is created; at zero size it crops or crashes).
    func displayReady(_ view: PlatformView) {
        guard let engine = pictureInPictureEngine, engine.displayView === view, pictureInPicture == nil,
              !Self.usesFloatingWindow(for: engine) else { return }
        pictureInPicture = PictureInPicture(engine: engine)
        pictureInPicture?.startsAutomatically = isFullScreen && !isMultiView
    }

    /// The audible tile changed: Picture in Picture follows it once its video is on screen.
    func audibleTileChanged() {
        guard pictureInPicture?.isActive != true else { return }
        pictureInPicture = nil
        guard let view = pictureInPictureEngine?.displayView, view.bounds.width > 0, view.window != nil else { return }
        displayReady(view)
    }

    // MARK: - Captions

    /// The C key: live MPEG-TS captions follow the saved preference; AVPlayer content toggles its rendition
    /// (closed captions first).
    func toggleCaptions() {
        if let subtitles = engine as? any SubtitleSelecting, !subtitles.subtitleOptions.isEmpty {
            if subtitles.selectedSubtitleID != nil {
                subtitles.selectSubtitle(id: nil)
            } else {
                let options = subtitles.subtitleOptions
                subtitles.selectSubtitle(id: (options.first(where: \.isClosedCaptions) ?? options.first)?.id)
            }
        } else {
            preferences.captionsEnabled.toggle()
        }
        showControlsBriefly()
    }}
