//
//  MultiViewPlayer.swift
//  PlayerKit
//
//  The player's one video surface, for one tile or many. Each tile is rendered once, keyed by its TileID, and hosts its
//  engine's display view; changing mode or presentation only changes frames, z-order, corners and dimming, so a display
//  view is never moved to another superview (which leaves video black). In single mode the tile fills the view and
//  takes no input, leaving the host's own player input in charge; tile input starts with the second tile.
//

import PlaybackKit
import SwiftUI

/// The host's side of tile input.
public struct MultiViewInputHandlers {
    /// Select, a click or a tap on the tile in front: show the controls.
    public var showControls: (TileID) -> Void
    /// Back with nothing left to pop: leave the player.
    public var leavePlayer: () -> Void
    /// Long press, right-click: open the arrangement panel. Nil presents `.arrangement` on the session; the host
    /// shows `ArrangementPanel` while it is the top overlay.
    public var showArrangement: (() -> Void)?
    /// The remote's Play/Pause (tvOS), meant for the audible tile.
    public var playPause: (() -> Void)?

    public init(showControls: @escaping (TileID) -> Void = { _ in }, leavePlayer: @escaping () -> Void = {},
                showArrangement: (() -> Void)? = nil, playPause: (() -> Void)? = nil) {
        self.showControls = showControls
        self.leavePlayer = leavePlayer
        self.showArrangement = showArrangement
        self.playPause = playPause
    }
}

extension MultiViewInputHandlers {
    /// Opens the arrangement panel through the host, or on the session.
    func openArrangement<Item>(_ session: MultiViewSession<Item>) {
        if let showArrangement {
            showArrangement()
        } else {
            session.present(.arrangement)
        }
    }
}

/// What a tile's overlay knows about the tile.
public struct TileOverlayContext: Hashable {
    public let placement: TilePlacement
    public let mode: MultiViewMode
    public let presentation: PlayerPresentation
    /// The focused grid tile while the player has focus.
    public let isFocused: Bool
    public let isAudible: Bool
}

public struct MultiViewPlayer<Item: Hashable & Sendable, TileOverlay: View>: View {
    private let session: MultiViewSession<Item>
    private let metrics: MultiViewMetrics
    private let isInputEnabled: Bool
    private let handlers: MultiViewInputHandlers
    private let onDisplayReady: ((TileID, PlatformView) -> Void)?
    private let tileOverlay: (PlayerTile<Item>, TileOverlayContext) -> TileOverlay

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var container: CGSize = .zero
    @State private var remoteGate = RemoteSelectGate()
    @FocusState private var focusedTile: TileID?
    @FocusState private var containerFocused: Bool

    /// - Parameters:
    ///   - isInputEnabled: false while the host's own controls or panels take input.
    ///   - onDisplayReady: a tile's display view is on screen with a real size (set up Picture in Picture then; see
    ///     `PlaybackSurface`).
    ///   - tileOverlay: drawn over each tile (labels, "Tuner unavailable" with Retry, buffering).
    public init(session: MultiViewSession<Item>, metrics: MultiViewMetrics = .standard, isInputEnabled: Bool = true,
                handlers: MultiViewInputHandlers = MultiViewInputHandlers(),
                onDisplayReady: ((TileID, PlatformView) -> Void)? = nil,
                @ViewBuilder tileOverlay: @escaping (PlayerTile<Item>, TileOverlayContext) -> TileOverlay) {
        self.session = session
        self.metrics = metrics
        self.isInputEnabled = isInputEnabled
        self.handlers = handlers
        self.onDisplayReady = onDisplayReady
        self.tileOverlay = tileOverlay
    }

    /// Tile input is on with two or more tiles, in the full player, with no panel over the tiles.
    private var inputActive: Bool {
        guard isInputEnabled, session.isMultiView, session.presentation == .full else { return false }
        return session.overlays.allSatisfy { $0 == .controls }
    }

    private var inputContext: TileInputContext<Item> {
        TileInputContext(session: session, handlers: handlers, focusedTile: $focusedTile,
                         containerFocused: $containerFocused, gate: remoteGate)
    }

    private var hasFocus: Bool {
        #if os(tvOS)
        focusedTile != nil
        #else
        containerFocused
        #endif
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if let state = session.state, session.presentation != .hidden {
                let audible = session.audibleTile
                let placements = MultiViewGeometry.placements(for: state, presentation: session.presentation,
                                                              audibleTile: audible, in: container, metrics: metrics)
                ForEach(session.tiles) { tile in
                    if let placement = placements[tile.id] {
                        tileView(tile, placement: placement, state: state, audible: audible)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self, of: \.size) { size in
            container = size
            session.containerSize = size
        }
        .multiViewInput(inputContext, isActive: inputActive)
        .modifier(ReducedResourceUsageReader { session.prefersReducedResourceUsage = $0 })
    }

    private func tileView(_ tile: PlayerTile<Item>, placement: TilePlacement, state: MultiViewState,
                          audible: TileID?) -> some View {
        let interactive = inputActive && placement.isInteractive
        let context = TileOverlayContext(
            placement: placement, mode: state.mode, presentation: session.presentation,
            isFocused: inputActive && hasFocus && state.mode.isGrid && state.focusedTile == tile.id,
            isAudible: tile.id == audible
        )
        return ZStack {
            if placement.isForeground {
                // The shadow belongs to a static shape behind the video, never to the video itself.
                RoundedRectangle(cornerRadius: placement.cornerRadius, style: .continuous)
                    .fill(.black)
                    .shadow(color: .black.opacity(0.55), radius: 28, y: 10)
            }
            MultiViewTileSurface(tile: tile, placement: placement, metrics: metrics, context: context,
                                 onReady: onDisplayReady.map { ready in { ready(tile.id, $0) } })
                .tileInput(inputContext, tile: tile.id, isActive: interactive, isForeground: placement.isForeground)
            tileOverlay(tile, context)
                .disabled(!placement.isVisible || (session.isMultiView && !placement.isInteractive))
        }
        .frame(width: placement.frame.width, height: placement.frame.height)
        .position(x: placement.frame.midX, y: placement.frame.midY)
        .opacity(placement.isVisible ? 1 : 0)
        .allowsHitTesting(placement.isVisible)
        .accessibilityHidden(!placement.isVisible)
        .zIndex(placement.zIndex)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: placement.frame)
        .animation(.easeInOut(duration: reduceMotion ? 0.2 : 0.35), value: placement.isDimmed)
    }
}

public extension MultiViewPlayer where TileOverlay == EmptyView {
    init(session: MultiViewSession<Item>, metrics: MultiViewMetrics = .standard, isInputEnabled: Bool = true,
         handlers: MultiViewInputHandlers = MultiViewInputHandlers(),
         onDisplayReady: ((TileID, PlatformView) -> Void)? = nil) {
        self.init(session: session, metrics: metrics, isInputEnabled: isInputEnabled, handlers: handlers,
                  onDisplayReady: onDisplayReady) { _, _ in EmptyView() }
    }
}

/// One tile's video with its dimming, focus ring and audible badge (none of which touch the video layer).
private struct MultiViewTileSurface<Item: Hashable & Sendable>: View {
    let tile: PlayerTile<Item>
    let placement: TilePlacement
    let metrics: MultiViewMetrics
    let context: TileOverlayContext
    let onReady: ((PlatformView) -> Void)?

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: placement.cornerRadius, style: .continuous)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlaybackSurface(view: tile.engine.displayView, cornerRadius: placement.cornerRadius, onReady: onReady)
            shape
                .fill(.black)
                .opacity(placement.isDimmed ? metrics.dimming : 0)
                .allowsHitTesting(false)
            if context.isFocused {
                shape
                    .strokeBorder(.white, lineWidth: metrics.focusRingWidth)
                    .allowsHitTesting(false)
            }
            if context.isAudible, context.mode.isGrid, context.presentation == .full {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.55), in: .circle)
                    .padding(8)
                    .accessibilityLabel("Audio")
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Reports the system's request for lower resource use (OS 27) to the session.
private struct ReducedResourceUsageReader: ViewModifier {
    let report: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 27.0, iOS 27.0, tvOS 27.0, *) {
            content.modifier(ReducedResourceUsageReader27(report: report))
        } else {
            content
        }
    }
}

@available(macOS 27.0, iOS 27.0, tvOS 27.0, *)
private struct ReducedResourceUsageReader27: ViewModifier {
    @Environment(\.systemPrefersReducedResourceUsage) private var prefersReduced
    let report: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onChange(of: prefersReduced, initial: true) { _, reduced in report(reduced) }
    }
}

/// What the platform input modifiers need.
struct TileInputContext<Item: Hashable & Sendable> {
    let session: MultiViewSession<Item>
    let handlers: MultiViewInputHandlers
    let focusedTile: FocusState<TileID?>.Binding
    let containerFocused: FocusState<Bool>.Binding
    let gate: RemoteSelectGate
}

/// tvOS: a long press of Select opened the arrangement panel, so the press's release must not also act as Select.
final class RemoteSelectGate {
    private var suppressUntil: ContinuousClock.Instant?
    var isLongPressing = false

    func longPressBegan() {
        isLongPressing = true
    }

    func longPressEnded() {
        isLongPressing = false
        suppressUntil = .now + .milliseconds(400)
    }

    /// True when a Select should be ignored (it ended a long press).
    func swallowsSelect() -> Bool {
        if isLongPressing { return true }
        guard let until = suppressUntil else { return false }
        suppressUntil = nil
        return ContinuousClock.now < until
    }
}
