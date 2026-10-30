//
//  TileKeyboardInput.swift
//  PlayerKit
//
//  Hardware keys for multi-view on macOS and iPadOS: the player is one focus target; the arrows move focus in the grid
//  (no wrap), ← → cycle the front tile and ↑ returns to the grid, Return brings the focused tile forward (or shows the
//  controls in front), Esc pops a layer or leaves. Keys with ⌘, ⌥ or ⌃ are left to the host's menus (⇧⌘A, ⇧⌘M, ⌘↑).
//

#if !os(tvOS)
import SwiftUI

struct TileKeyboardInput<Item: Hashable & Sendable>: ViewModifier {
    let input: TileInputContext<Item>
    let isActive: Bool

    private var session: MultiViewSession<Item> { input.session }
    private var handlers: MultiViewInputHandlers { input.handlers }
    private var containerFocused: FocusState<Bool>.Binding { input.containerFocused }

    func body(content: Content) -> some View {
        content
            .focusable(isActive)
            .focused(containerFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in
                handle(press)
            }
            #if os(macOS)
            .onExitCommand {
                guard isActive else { return }
                back()
            }
            #endif
            .onChange(of: isActive, initial: true) { _, active in
                if active { containerFocused.wrappedValue = true }
            }
            .onChange(of: session.focusRequest) {
                if isActive { containerFocused.wrappedValue = true }
            }
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard isActive, press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
        switch press.key {
        case .upArrow: return move(.upward)
        case .downArrow: return move(.downward)
        case .leftArrow: return move(.leftward)
        case .rightArrow: return move(.rightward)
        case .return:
            guard press.phase == .down, let tile = session.state?.focusedTile else { return .handled }
            if session.select(tile) == .showControls { handlers.showControls(tile) }
            return .handled
        #if os(iOS)
        case .escape:
            back()
            return .handled
        #endif
        default:
            return .ignored
        }
    }

    private func move(_ direction: TileDirection) -> KeyPress.Result {
        session.focus(direction) ? .handled : .ignored
    }

    private func back() {
        if !session.back() { handlers.leavePlayer() }
    }
}
#endif
