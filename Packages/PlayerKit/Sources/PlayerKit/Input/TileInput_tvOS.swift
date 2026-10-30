//
//  TileInput_tvOS.swift
//  PlayerKit
//
//  Siri Remote input for multi-view. Each tile is a focusable button that draws nothing: on a real Siri Remote a
//  focusable view with a tap gesture misses Select clicks, while a button's primary action always gets them. In the
//  grid the focus engine moves between the tile buttons and the session follows; while a tile is in front the others
//  are disabled, so focus can't wander behind it, and ← → cycle the front tile and ↑ returns to the grid. Back pops the
//  innermost layer, then leaves.
//
//  A long press of Select (0.6 s) opens the arrangement panel through a UIKit press recognizer on the window rather
//  than a SwiftUI gesture on the button: when it recognizes, UIKit cancels the press, so the button's action does not
//  also fire, and the gate swallows a stray release. Risk: unverified on hardware with tvOS 27; if the button still
//  fires on release, the gate's 400 ms window covers it. The host can always open the panel from a button in its
//  controls instead.
//

#if os(tvOS)
import SwiftUI
import UIKit

extension View {
    func tileInput<Item>(_ input: TileInputContext<Item>, tile: TileID, isActive: Bool,
                         isForeground: Bool) -> some View {
        Button {
            guard isActive, !input.gate.swallowsSelect() else { return }
            if input.session.select(tile) == .showControls { input.handlers.showControls(tile) }
        } label: {
            self
        }
        .buttonStyle(TileButtonStyle())
        .focusEffectDisabled()
        .disabled(!isActive)
        .focused(input.focusedTile, equals: tile)
        .accessibilityIdentifier("multiview.tile")
    }

    func multiViewInput<Item>(_ input: TileInputContext<Item>, isActive: Bool) -> some View {
        modifier(RemoteMultiViewInput(session: input.session, isActive: isActive, handlers: input.handlers,
                                      focusedTile: input.focusedTile, gate: input.gate))
    }
}

private struct RemoteMultiViewInput<Item: Hashable & Sendable>: ViewModifier {
    let session: MultiViewSession<Item>
    let isActive: Bool
    let handlers: MultiViewInputHandlers
    let focusedTile: FocusState<TileID?>.Binding
    let gate: RemoteSelectGate

    func body(content: Content) -> some View {
        content
            // In the grid the focus engine moves between tiles: a move handler there (even one that ignores the
            // move) would swallow every d-pad press, so there is none. Only the front tile handles directions.
            .onMoveCommand(perform: frontMoveHandler)
            .onExitCommand {
                guard isActive else { return }
                if !session.back() { handlers.leavePlayer() }
            }
            .onPlayPauseCommand {
                guard isActive else { return }
                handlers.playPause?()
            }
            .background {
                SelectLongPressBridge(isEnabled: isActive && focusedTile.wrappedValue != nil, gate: gate) {
                    handlers.openArrangement(session)
                }
                .allowsHitTesting(false)
            }
            .onChange(of: focusedTile.wrappedValue) { _, tile in
                if let tile, isActive { session.focus(tile: tile) }
            }
            .onChange(of: session.state?.focusedTile) { _, tile in
                // Keep remote focus on the session's tile (a cycle in front, a removal), once the player has focus.
                if isActive, focusedTile.wrappedValue != nil, let tile { focusedTile.wrappedValue = tile }
            }
            .onChange(of: session.focusRequest) {
                if isActive, let tile = session.state?.focusedTile { focusedTile.wrappedValue = tile }
            }
            .onChange(of: isActive, initial: true) { _, active in
                // Multi-view began (or a panel closed): focus the session's tile.
                if active, let tile = session.state?.focusedTile { focusedTile.wrappedValue = tile }
            }
    }
}

extension RemoteMultiViewInput {
    /// The move handler while a tile is in front, else none (the focus engine moves between grid tiles).
    private var frontMoveHandler: ((MoveCommandDirection) -> Void)? {
        guard isActive, session.mode?.foregroundTile != nil else { return nil }
        return { moveInFront($0) }
    }

    private func moveInFront(_ direction: MoveCommandDirection) {
        guard let direction = TileDirection(direction) else { return }
        session.focus(direction)
    }
}

extension TileDirection {
    init?(_ direction: MoveCommandDirection) {
        switch direction {
        case .up: self = .upward
        case .down: self = .downward
        case .left: self = .leftward
        case .right: self = .rightward
        @unknown default: return nil
        }
    }
}

/// A button that draws only its label; the tile draws its own focus ring.
private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// A long press of Select anywhere in the window, while enabled.
private struct SelectLongPressBridge: UIViewRepresentable {
    let isEnabled: Bool
    let gate: RemoteSelectGate
    let action: () -> Void

    func makeUIView(context: Context) -> SelectLongPressView {
        SelectLongPressView()
    }

    func updateUIView(_ view: SelectLongPressView, context: Context) {
        view.gate = gate
        view.action = action
        view.isBridgeEnabled = isEnabled
    }
}

private final class SelectLongPressView: UIView {
    var gate: RemoteSelectGate?
    var action: (() -> Void)?
    var isBridgeEnabled = false {
        didSet { recognizer.isEnabled = isBridgeEnabled }
    }

    private lazy var recognizer: UILongPressGestureRecognizer = {
        let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        recognizer.minimumPressDuration = 0.6
        recognizer.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        recognizer.allowedTouchTypes = []
        // On recognition the press is cancelled for the focused button (and recognizers that can't recognize
        // simultaneously fail), so its action doesn't fire too.
        recognizer.cancelsTouchesInView = true
        return recognizer
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizer.view?.removeGestureRecognizer(recognizer)
        // Press recognizers on an ancestor of the focused view see its presses; the window is everyone's ancestor.
        window?.addGestureRecognizer(recognizer)
        recognizer.isEnabled = isBridgeEnabled
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            gate?.longPressBegan()
            action?()
        case .ended, .cancelled, .failed:
            gate?.longPressEnded()
        default:
            break
        }
    }
}
#endif
