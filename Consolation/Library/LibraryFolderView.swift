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
                } else {
                    List(items) { item in
                        LibraryItemRow(item: item, isStarting: playing == item.id) { select(item) }
                    }
                    .listStyle(.plain)
                }
            } else if failure == nil {
                ProgressView()
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
        switch item.kind {
        case .folder, .series, .season:
            open(LibraryLocation(source: location.source, parent: item.id, title: item.title))
        default:
            play(item)
        }
    }

    private func play(_ item: MediaItem) {
        playing = item.id
        Task {
            defer { playing = nil }
            do {
                guard let media = try await registry.libraryMedia(for: item.id) else { return }
                failure = nil
                session.play(media)
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

    private var isFolder: Bool {
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
