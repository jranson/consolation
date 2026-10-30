//
//  TileInput_iOS.swift
//  PlayerKit
//
//  Touch input for multi-view on iPhone and iPad: a tap brings a grid tile forward (or shows the controls in front); a
//  swipe down or a pinch in on the front tile returns to the grid; a long press opens the arrangement panel. A hardware
//  keyboard works as on the Mac (`TileKeyboardInput`).
//

#if os(iOS)
import SwiftUI

extension View {
    func tileInput<Item>(_ input: TileInputContext<Item>, tile: TileID, isActive: Bool,
                         isForeground: Bool) -> some View {
        modifier(TouchTileInput(session: input.session, tile: tile, isActive: isActive, isForeground: isForeground,
                                handlers: input.handlers))
    }

    func multiViewInput<Item>(_ input: TileInputContext<Item>, isActive: Bool) -> some View {
        modifier(TileKeyboardInput(input: input, isActive: isActive))
    }
}

private struct TouchTileInput<Item: Hashable & Sendable>: ViewModifier {
    let session: MultiViewSession<Item>
    let tile: TileID
    let isActive: Bool
    let isForeground: Bool
    let handlers: MultiViewInputHandlers

    /// A swipe down this far (points) on the front tile returns to the grid.
    private static var swipeDistance: CGFloat { 60 }
    /// A pinch to this scale or smaller on the front tile returns to the grid.
    private static var pinchScale: CGFloat { 0.85 }

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture {
                guard isActive else { return }
                if session.select(tile) == .showControls { handlers.showControls(tile) }
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                guard isActive else { return }
                handlers.openArrangement(session)
            }
            .gesture(
                DragGesture(minimumDistance: 24).onEnded { value in
                    let drop = value.translation.height
                    guard isActive, isForeground, drop > Self.swipeDistance,
                          drop > abs(value.translation.width) else { return }
                    _ = session.back()
                },
                including: isActive && isForeground ? .all : .subviews
            )
            .simultaneousGesture(
                MagnifyGesture().onEnded { value in
                    guard isActive, isForeground, value.magnification < Self.pinchScale else { return }
                    _ = session.back()
                },
                including: isActive && isForeground ? .all : .subviews
            )
    }
}
#endif
