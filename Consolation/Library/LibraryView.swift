//
//  LibraryView.swift
//  Consolation
//
//  The Library pane: the library servers (Bullpen) to browse, and the other sources added. Folders open in place,
//  with their own path; Back (Apple TV's Menu, Esc, the Back button) closes the innermost folder before it reaches
//  the shell, which moves focus to the pill.
//

import MediaSourceKit
import SwiftUI

/// A folder open in the Library pane: a source, and an item in it (nil for its top level).
struct LibraryLocation: Hashable {
    let source: SourceID
    let parent: MediaItemID?
    let title: String
}

struct LibraryView: View {
    @Environment(SourceStore.self) private var sources
    @Environment(SourceRegistry.self) private var registry
    @Environment(ShellModel.self) private var shell
    @Environment(\.shellLayout) private var layout
    @FocusState private var focusedRow: String?

    @State private var path: [LibraryLocation] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let location = path.last {
                LibraryFolderView(location: location) { path.append($0) }
                    .id(location)
            } else {
                serverList
            }
            Spacer(minLength: 0)
        }
        .padding(layout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        #if os(tvOS)
        .onExitCommand(perform: path.isEmpty ? nil : { path.removeLast() })
        #endif
        // The pill handing focus back (Back or Select in it on Apple TV).
        .onChange(of: shell.contentFocusRequest) { focusedRow = path.isEmpty ? firstRowID : nil }
        // A server removed in Settings closes its folders.
        .onChange(of: registry.librarySources.map(\.id)) { _, ids in
            path.removeAll { !ids.contains($0.source) }
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            #if !os(tvOS)
            if !path.isEmpty {
                Button("Back", systemImage: "chevron.backward") { path.removeLast() }
                    .labelStyle(.iconOnly)
            }
            #endif
            Text(path.last?.title ?? String(localized: "Library")).font(.largeTitle.bold()).lineLimit(1)
        }
    }

    private var firstRowID: String {
        registry.librarySources.first?.id.raw ?? "add-source"
    }

    private var serverList: some View {
        VStack(alignment: .leading, spacing: 16) {
            if registry.librarySources.isEmpty && sources.hdHomeRuns.isEmpty {
                Text("No sources yet.").foregroundStyle(.secondary)
            }
            ForEach(registry.librarySources, id: \.id) { source in
                Button {
                    path.append(LibraryLocation(source: source.id, parent: nil, title: source.name))
                } label: {
                    Label(source.name, systemImage: "server.rack")
                }
                .focused($focusedRow, equals: source.id.raw)
            }
            ForEach(sources.hdHomeRuns) { config in
                Label(config.displayName, systemImage: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            }
            Button("Add Source…") { shell.selection = .settings }
                .focused($focusedRow, equals: "add-source")
            if registry.librarySources.isEmpty {
                Text("Add a Bullpen server in Settings to browse its recordings and library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
