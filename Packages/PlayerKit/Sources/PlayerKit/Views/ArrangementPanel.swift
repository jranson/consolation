//
//  ArrangementPanel.swift
//  PlayerKit
//
//  The arrangement panel: a glass panel over the player with a miniature map of the tiles (each tile's title from the
//  host, the audible one marked). Choosing a tile in the map targets the actions: Add Tile (the host shows its picker),
//  Replace (the host's picker for the targeted tile), Move ← →, Remove Tile, "Audio follows focus" and Exit Multi-view
//  (keeps the targeted tile). The focused or front tile is targeted first. Back (Esc on the Mac, Menu on Apple TV)
//  closes it.
//

import SwiftUI

/// The host's actions for the panel.
public struct ArrangementActions {
    /// Add Tile: the host shows its picker (with tuner capacity) and calls `MultiViewSession.add(_:)`.
    public var addTile: () -> Void
    /// Replace: the host shows its picker for this tile and calls `MultiViewSession.replace(_:with:)`.
    public var replace: (TileID) -> Void
    /// Exit Multi-view keeping this tile. Nil calls `MultiViewSession.exitMultiView(keeping:)`.
    public var exitMultiView: ((TileID) -> Void)?

    public init(addTile: @escaping () -> Void, replace: @escaping (TileID) -> Void,
                exitMultiView: ((TileID) -> Void)? = nil) {
        self.addTile = addTile
        self.replace = replace
        self.exitMultiView = exitMultiView
    }
}

public struct ArrangementPanel<Item: Hashable & Sendable>: View {
    private let session: MultiViewSession<Item>
    @Binding private var audioFollowsFocus: Bool
    private let actions: ArrangementActions
    private let title: (PlayerTile<Item>) -> String
    @State private var chosen: TileID?

    public init(session: MultiViewSession<Item>, audioFollowsFocus: Binding<Bool>, actions: ArrangementActions,
                title: @escaping (PlayerTile<Item>) -> String) {
        self.session = session
        _audioFollowsFocus = audioFollowsFocus
        self.actions = actions
        self.title = title
    }

    /// The tile the actions apply to: the one chosen in the map, else the focused or front tile.
    private var target: TileID? {
        if let chosen, session.tile(chosen) != nil { return chosen }
        return session.state?.focusedTile
    }

    private var targetIndex: Int? {
        target.flatMap { session.state?.index(of: $0) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Arrange Multi-view").font(.title3.bold())
            ArrangementMap(session: session, target: target, title: title) { chosen = $0 }
            actionRows
            Toggle("Audio follows focus", isOn: $audioFollowsFocus)
            HStack {
                Button("Exit Multi-view", systemImage: "rectangle") { exitMultiView() }
                    .disabled(!session.isMultiView || target == nil)
                Spacer(minLength: 12)
                Button("Done") { session.dismiss(.arrangement) }
            }
        }
        .padding(28)
        .frame(maxWidth: Self.panelWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        #if !os(iOS)
        .focusSection()
        .onExitCommand { session.dismiss(.arrangement) }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("multiview.arrangement")
    }

    private var actionRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Add Tile", systemImage: "plus.rectangle") { actions.addTile() }
                    .disabled(session.addTileLimitReason != nil)
                Button("Replace", systemImage: "arrow.triangle.2.circlepath") {
                    if let target { actions.replace(target) }
                }
                .disabled(target == nil)
                Button("Remove Tile", systemImage: "minus.rectangle") { removeTarget() }
                    .disabled(!session.isMultiView || target == nil)
            }
            HStack(spacing: 12) {
                Button("Move Left", systemImage: "arrow.left") { move(by: -1) }
                    .disabled((targetIndex ?? 0) == 0)
                Button("Move Right", systemImage: "arrow.right") { move(by: 1) }
                    .disabled((targetIndex ?? session.tiles.count) >= session.tiles.count - 1)
            }
            if let reason = session.addTileLimitReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func move(by offset: Int) {
        guard let target else { return }
        session.moveTile(target, by: offset)
    }

    private func removeTarget() {
        guard let target else { return }
        session.remove(target)
        chosen = nil
    }

    private func exitMultiView() {
        guard let target else { return }
        if let exit = actions.exitMultiView {
            exit(target)
        } else {
            session.exitMultiView(keeping: target)
        }
    }

    private static var panelWidth: CGFloat {
        #if os(tvOS)
        900
        #else
        560
        #endif
    }
}

/// The miniature layout: one button per tile in its grid cell, the targeted one highlighted, the audible one with a
/// speaker.
private struct ArrangementMap<Item: Hashable & Sendable>: View {
    let session: MultiViewSession<Item>
    let target: TileID?
    let title: (PlayerTile<Item>) -> String
    let choose: (TileID) -> Void

    private static var mapSize: CGSize {
        #if os(tvOS)
        CGSize(width: 560, height: 315)
        #else
        CGSize(width: 320, height: 180)
        #endif
    }

    var body: some View {
        let size = Self.mapSize
        let metrics = MultiViewMetrics(spacing: 6, padding: 6)
        let cells = MultiViewGeometry.cellFrames(count: session.tiles.count, in: size, metrics: metrics)
        let audible = session.audibleTile
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.35))
            ForEach(Array(zip(session.tiles, cells)), id: \.0.id) { tile, cell in
                Button { choose(tile.id) } label: {
                    MapCell(title: title(tile), isTarget: tile.id == target, isAudible: tile.id == audible)
                }
                .buttonStyle(.plain)
                .frame(width: cell.width, height: cell.height)
                .position(x: cell.midX, y: cell.midY)
                .accessibilityLabel(title(tile))
                .accessibilityAddTraits(tile.id == target ? .isSelected : [])
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

private struct MapCell: View {
    let title: String
    let isTarget: Bool
    let isAudible: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isTarget ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.14))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isTarget ? Color.white : Color.white.opacity(0.25), lineWidth: isTarget ? 2 : 1)
            Text(title)
                .font(.caption.bold())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if isAudible {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).padding(5)
            }
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }
}
