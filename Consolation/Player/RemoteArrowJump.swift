//
//  RemoteArrowJump.swift
//  Consolation
//
//  tvOS: left and right on the remote's clickpad or a keyboard's arrow keys, with Shift on a keyboard. SwiftUI's move
//  commands carry no modifiers, so a press recognizer on the window reads them while `isEnabled` (the video has
//  focus) and swallows them. Elsewhere this does nothing.
//

import SwiftUI
#if os(tvOS)
import UIKit
#endif

extension View {
    /// Calls `onJump` with ±`PlaybackJump.step` for left and right, ±`PlaybackJump.largeStep` with Shift held on a
    /// keyboard, while `isEnabled` (tvOS only).
    func remoteArrowJumps(isEnabled: Bool, onJump: @escaping (Double) -> Void) -> some View {
        #if os(tvOS)
        background(RemoteArrowHost(isEnabled: isEnabled, onJump: onJump).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct RemoteArrowHost: UIViewRepresentable {
    let isEnabled: Bool
    let onJump: (Double) -> Void

    func makeUIView(context: Context) -> RemoteArrowView {
        RemoteArrowView()
    }

    func updateUIView(_ view: RemoteArrowView, context: Context) {
        view.onJump = onJump
        view.isBridgeEnabled = isEnabled
    }
}

private final class RemoteArrowView: UIView {
    var onJump: ((Double) -> Void)?
    var isBridgeEnabled = false {
        didSet { recognizer?.isEnabled = isBridgeEnabled }
    }
    private var recognizer: ArrowPressRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let recognizer { recognizer.view?.removeGestureRecognizer(recognizer) }
        recognizer = nil
        guard let window else { return }
        // Press recognizers on an ancestor of the focused view see its presses; the window is everyone's ancestor.
        let arrows = ArrowPressRecognizer(target: self, action: #selector(pressed(_:)))
        arrows.allowedPressTypes = [UIPress.PressType.leftArrow, .rightArrow].map { NSNumber(value: $0.rawValue) }
        arrows.isEnabled = isBridgeEnabled
        window.addGestureRecognizer(arrows)
        recognizer = arrows
    }

    @objc private func pressed(_ recognizer: ArrowPressRecognizer) {
        onJump?(recognizer.seconds)
    }
}

/// Recognizes as soon as left or right goes down, noting the jump: its direction, and 30 s with Shift.
private final class ArrowPressRecognizer: UIGestureRecognizer {
    private(set) var seconds = 0.0

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard let press = presses.first(where: { $0.type == .leftArrow || $0.type == .rightArrow }) else {
            state = .failed
            return
        }
        let step = press.key?.modifierFlags.contains(.shift) == true ? PlaybackJump.largeStep : PlaybackJump.step
        seconds = press.type == .leftArrow ? -step : step
        state = .recognized
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .failed
    }
}
#endif
