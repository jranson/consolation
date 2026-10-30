//
//  RemotePressBridge.swift
//  Consolation
//
//  tvOS: remote buttons SwiftUI has no modifier for. Channel up/down on TV remotes arrive as Page Up/Page Down
//  presses and the 123 button (tvOS 18.1+) as its own press type, all UIKit-only, so a recognizer on the window
//  catches them while the player is on screen. Elsewhere this does nothing.
//

import SwiftUI
#if os(tvOS)
import UIKit
#endif

/// The extra remote buttons the player handles.
enum RemoteButton {
    case pageUp
    case pageDown
    case oneTwoThree
}

extension View {
    /// Calls `action` for Page Up, Page Down and the 123 button while this view is on screen (tvOS only).
    func remoteButtons(_ action: @escaping (RemoteButton) -> Void) -> some View {
        #if os(tvOS)
        background(RemotePressHost(action: action).allowsHitTesting(false))
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct RemotePressHost: UIViewRepresentable {
    let action: (RemoteButton) -> Void

    func makeUIView(context: Context) -> RemotePressView {
        RemotePressView()
    }

    func updateUIView(_ view: RemotePressView, context: Context) {
        view.action = action
    }
}

private final class RemotePressView: UIView {
    var action: ((RemoteButton) -> Void)?
    private var recognizers: [UIGestureRecognizer] = []

    private static let buttons: [(UIPress.PressType, RemoteButton)] = [
        (.pageUp, .pageUp), (.pageDown, .pageDown), (.tvRemoteOneTwoThree, .oneTwoThree)
    ]

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizers.forEach { $0.view?.removeGestureRecognizer($0) }
        recognizers.removeAll()
        guard let window else { return }
        // Press recognizers on an ancestor of the focused view see its presses; the window is everyone's ancestor.
        for (type, button) in Self.buttons {
            let recognizer = PressRecognizer(button: button, target: self, action: #selector(pressed(_:)))
            recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
            recognizer.cancelsTouchesInView = false
            window.addGestureRecognizer(recognizer)
            recognizers.append(recognizer)
        }
    }

    @objc private func pressed(_ recognizer: PressRecognizer) {
        action?(recognizer.button)
    }
}

private final class PressRecognizer: UITapGestureRecognizer {
    let button: RemoteButton

    init(button: RemoteButton, target: Any?, action: Selector?) {
        self.button = button
        super.init(target: target, action: action)
    }
}
#endif
