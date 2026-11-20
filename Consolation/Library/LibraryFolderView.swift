//
//  LibraryFolderView.swift
//  Consolation
//
//  One folder of a library source: its subfolders open in place, and its videos and channels play.
//

import MediaSourceKit
import PlaybackKit
import SwiftUI

struct LibraryFolderView: View {
    let location: LibraryLocation
    /// Opens a subfolder.
    let open: (LibraryLocation) -> Void

    @Environment(SourceRegistry.self) private var registry
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell

    /// How many entries a folder lists at most.
    static let pageSize = 200

    @State private var items: [MediaItem]?
    @State private var failure: String?
    @State private var playing: MediaItemID?

    var body: some View {
        Group {
            if let items {
                if items.isEmpty {
                    Text("Nothing here yet.").foregroundStyle(.secondary)
                        .holdsFocusForBack()
                } else {
                    List(items) { item in
                        LibraryItemRow(item: item, isStarting: playing == item.id) { select(item) }
                            .contextMenu { playMenu(for: item) }
                    }
                    .listStyle(.plain)
                }
            } else if failure == nil {
                ProgressView()
                    .holdsFocusForBack()
            }
            if let failure {
                VStack(alignment: .leading, spacing: 12) {
                    Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        failure = nil
        guard let source = registry.librarySource(location.source) else {
            failure = String(localized: "This server was removed.")
            return
        }
        do {
            items = try await source.children(of: location.parent, page: PageRequest(limit: Self.pageSize)).items
        } catch {
            await registry.updateStatuses()
            failure = Self.message(for: error, status: registry.status(of: location.source))
        }
    }

    private func select(_ item: MediaItem) {
        if LibraryItemRow.isFolder(item) {
            open(LibraryLocation(source: location.source, parent: item.id, title: item.title))
        } else {
            play(item)
        }
    }

    /// The long press on a video or channel: while something plays, Add to Multi-view first (Apple TV focuses it),
    /// then Play Solo; otherwise Play. Folders open on Select and have no menu.
    @ViewBuilder private func playMenu(for item: MediaItem) -> some View {
        if !LibraryItemRow.isFolder(item) {
            if session.isActive {
                Button("Add to Multi-view", systemImage: "plus.rectangle.on.rectangle") { addToMultiView(item) }
                Button("Play Solo", systemImage: "play") { play(item) }
            } else {
                Button("Play", systemImage: "play") { play(item) }
            }
        }
    }

    private func play(_ item: MediaItem) {
        start(item) { media in session.play(media) }
    }

    /// Adds the item as a multi-view tile (or plays it, if playback stopped meanwhile).
    private func addToMultiView(_ item: MediaItem) {
        start(item, asTile: true) { media in await session.addToMultiView(.media(media)) }
    }

    /// Resolves the item through its server, hands it to `begin`, and opens the player. A bookmark to a YouTube
    /// video plays in YouTube's embed instead, and never as a multi-view tile.
    private func start(_ item: MediaItem, asTile: Bool = false, begin: @escaping (SourceMedia) async -> Void) {
        playing = item.id
        Task {
            defer { playing = nil }
            do {
                guard let playback = try await registry.libraryPlayback(for: item.id) else { return }
                failure = nil
                switch playback {
                case .media(let media):
                    await begin(media)
                case .hostedVideo where asTile && session.isActive:
                    failure = PlayerSession.hostedVideoTileMessage
                    return
                case .hostedVideo:
                    session.play(playback.target)
                }
                shell.selection = .nowPlaying
            } catch {
                failure = Self.message(for: error, status: registry.status(of: location.source))
            }
        }
    }

    static func message(for error: any Error, status: SourceStatus) -> String {
        if let mapping = error as? PlaybackMappingError { return mapping.message }
        switch status {
        case .unreachable(let reason) where !reason.isEmpty: return reason
        case .authRequired: return String(localized: "This server requires sign-in.")
        case .localNetworkDenied: return String(localized: "Local Network access is off.")
        default: break
        }
        if case MediaSourceError.notFound = error { return String(localized: "This isn't on the server any more.") }
        return String(localized: "Couldn't read this from the server.")
    }
}

private extension View {
    /// Apple TV: a folder with nothing to select (empty, or still loading) keeps focus here, so Back reaches the
    /// Library pane and closes the folder. With nothing focused, Back would go to the system and leave the app.
    @ViewBuilder
    func holdsFocusForBack() -> some View {
        #if os(tvOS)
        focusable().accessibilityIdentifier("library.placeholder")
        #else
        self
        #endif
    }
}

private struct LibraryItemRow: View {
    let item: MediaItem
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                if isStarting {
                    ProgressView()
                } else if isRecordingNow {
                    Label("Recording", systemImage: "record.circle").labelStyle(.titleAndIcon)
                        .font(.caption).foregroundStyle(.red)
                } else if isFolder {
                    Image(systemName: "chevron.forward").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isFolder: Bool { Self.isFolder(item) }

    /// Folders, series and seasons open in place; everything else plays.
    static func isFolder(_ item: MediaItem) -> Bool {
        switch item.kind {
        case .folder, .series, .season: true
        default: false
        }
    }

    private var isRecordingNow: Bool {
        if case .recording(_, _, true, _) = item.kind { return true }
        return false
    }

    private var symbol: String {
        switch item.kind {
        case .channel: "antenna.radiowaves.left.and.right"
        case .recording: "record.circle"
        case .movie: "film"
        case .episode: "tv"
        case .folder, .series, .season: "folder"
        case .file, .clip: "play.rectangle"
        }
    }

    private var detail: String? {
        switch item.kind {
        case let .channel(number, _, _, _): number
        case let .recording(_, recordedAt, _, channel):
            // The episode's own title first ("Grand Prix de France - Women's Free Skate"), then where and when.
            [item.subtitle, channel, recordedAt?.formatted(date: .abbreviated, time: .shortened)]
                .compactMap(\.self).joined(separator: " · ")
        default: item.subtitle
        }
    }
}
