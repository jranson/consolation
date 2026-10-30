//
//  RemoteSwipeScrub.swift
//  Consolation
//
//  Apple TV: swiping left or right on the Siri Remote's touch surface while the timeline has focus slides its dot
//  (clicks on the clickpad's edges move it, but swipes alone don't: SwiftUI turns swipes into focus moves, not move
//  commands). A horizontal pan recognizer on the window, enabled only while the timeline has focus, reports the pan's
//  horizontal travel; vertical swipes are left to the focus engine. The swirl of a ring jog (RemoteRingJog.swift) also
//  pans; the scrubber ignores those swipes.
//

#if os(tvOS)
import SwiftUI
import UIKit

/// Where a swipe is: its first report, the ones after it, and its end (lifted, cancelled or failed).
enum RemotePanPhase {
    case began, changed, ended
}

extension View {
    /// Calls `onPan` with the horizontal travel (points) of a horizontal swipe on the remote while `isEnabled`.
    func remoteHorizontalPan(isEnabled: Bool, onPan: @escaping (_ phase: RemotePanPhase, _ travel: CGFloat) -> Void)
        -> some View {
        background(RemotePanBridge(isEnabled: isEnabled, onPan: onPan).allowsHitTesting(false))
    }
}

private struct RemotePanBridge: UIViewRepresentable {
    let isEnabled: Bool
    let onPan: (RemotePanPhase, CGFloat) -> Void

    func makeUIView(context: Context) -> RemotePanView {
        RemotePanView()
    }

    func updateUIView(_ view: RemotePanView, context: Context) {
        view.onPan = onPan
        view.isBridgeEnabled = isEnabled
    }
}

private final class RemotePanView: UIView {
    var onPan: ((RemotePanPhase, CGFloat) -> Void)?
    var isBridgeEnabled = false {
        didSet { recognizer.isEnabled = isBridgeEnabled }
    }

    private lazy var recognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = panDelegate
        return recognizer
    }()

    private let panDelegate = HorizontalPanDelegate()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        recognizer.view?.removeGestureRecognizer(recognizer)
        // The window sees the remote's touches whatever has focus; the recognizer is on only while asked.
        window?.addGestureRecognizer(recognizer)
        recognizer.isEnabled = isBridgeEnabled
    }

    override func removeFromSuperview() {
        recognizer.view?.removeGestureRecognizer(recognizer)
        super.removeFromSuperview()
    }

    /// `CONSOLATION_FOCUS_TRACE=1` (`make run-device … TRACE=focus`) also prints each swipe's start and end.
    private static let traces = ProcessInfo.processInfo.environment["CONSOLATION_FOCUS_TRACE"] == "1"

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        if Self.traces, pan.state == .began || pan.state == .ended {
            print("Timeline swipe \(pan.state == .began ? "began" : "ended") at \(Int(pan.translation(in: window).x))")
        }
        switch pan.state {
        case .began: onPan?(.began, pan.translation(in: window).x)
        case .changed: onPan?(.changed, pan.translation(in: window).x)
        case .ended, .cancelled, .failed: onPan?(.ended, pan.translation(in: window).x)
        default: break
        }
    }
}

/// Horizontal swipes only: a vertical one moves focus between the timeline and the buttons. Alongside the focus
/// engine's own recognizers, never instead of them.
private final class HorizontalPanDelegate: NSObject, UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: pan.view)
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
