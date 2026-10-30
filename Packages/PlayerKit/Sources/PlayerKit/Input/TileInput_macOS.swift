//
//  TileInput_macOS.swift
//  PlayerKit
//
//  Mac input for multi-view: arrow keys, Return, Esc and ↑ through `TileKeyboardInput`; a click brings a grid tile
//  forward (or shows the controls in front); right-click offers the arrangement panel and Exit Multi-view.
//

#if os(macOS)
import SwiftUI

extension View {
    func tileInput<Item>(_ input: TileInputContext<Item>, tile: TileID, isActive: Bool,
                         isForeground: Bool) -> some View {
        contentShape(Rectangle())
            .onTapGesture {
                guard isActive else { return }
                input.containerFocused.wrappedValue = true
                if input.session.select(tile) == .showControls { input.handlers.showControls(tile) }
            }
            .contextMenu {
                if isActive {
                    Button("Arrange Multi-view…") { input.handlers.openArrangement(input.session) }
                    Button("Exit Multi-view") { input.session.exitMultiView(keeping: tile) }
                }
            }
    }

    func multiViewInput<Item>(_ input: TileInputContext<Item>, isActive: Bool) -> some View {
        modifier(TileKeyboardInput(input: input, isActive: isActive))
    }
}
#endif
