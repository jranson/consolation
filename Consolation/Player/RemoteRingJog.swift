//
//  RemoteRingJog.swift
//  Consolation
//
//  Apple TV: the ring jog on the focused timeline (RingJog.swift has the rules). UIKit only sees the clickpad's
//  swipes and clicks, so the touch position comes from GameController's view of the Siri Remote: its micro gamepad's
//  d-pad, switched to absolute values (where the finger is on the clickpad, not a window around the first contact)
//  only while the timeline wants it. The previous settings and handler are put back when it doesn't, so nothing
//  else changes. Observing the d-pad takes nothing from UIKit: clicks and swipes still reach the focus engine.
//

#if os(tvOS)
import GameController
import SwiftUI
import UIKit

extension View {
    /// Calls `onJog` with the ring jog's events while `isEnabled`; no jog begins while `canBegin` is false.
    func remoteRingJog(isEnabled: Bool, canBegin: Bool, onJog: @escaping (RingJog.Event) -> Void) -> some View {
        background(RingJogBridge(isEnabled: isEnabled, canBegin: canBegin, onJog: onJog).allowsHitTesting(false))
    }
}

/// `CONSOLATION_FOCUS_TRACE=1` (`make run-device … TRACE=focus`) prints each jog's start and end.
enum RingJogTrace {
    static let isOn = ProcessInfo.processInfo.environment["CONSOLATION_FOCUS_TRACE"] == "1"
}

private struct RingJogBridge: UIViewRepresentable {
    let isEnabled: Bool
    let canBegin: Bool
    let onJog: (RingJog.Event) -> Void

    func makeUIView(context: Context) -> RingJogView {
        RingJogView()
    }

    func updateUIView(_ view: RingJogView, context: Context) {
        view.onJog = onJog
        view.canBegin = canBegin
        view.isBridgeEnabled = isEnabled
    }

    static func dismantleUIView(_ view: RingJogView, coordinator: ()) {
        view.isBridgeEnabled = false
    }
}

private final class RingJogView: UIView {
    var onJog: ((RingJog.Event) -> Void)?
    var canBegin = true
    var isBridgeEnabled = false {
        didSet {
            guard isBridgeEnabled != oldValue else { return }
            if isBridgeEnabled { start() } else { stop() }
        }
    }

    /// A remote this view took over, with what it had before.
    private struct Attachment {
        let controller: GCController
        let reportedAbsolute: Bool
        let allowedRotation: Bool
        let handler: GCControllerDirectionPadValueChangedHandler?
    }

    private var jog = RingJog()
    private var attached: [ObjectIdentifier: Attachment] = [:]
    private var observers: [any NSObjectProtocol] = []
    /// The remote whose finger is down (a second remote is ignored until it lifts).
    private var touching: ObjectIdentifier?
    private var holdTimer: Task<Void, Never>?
    /// Seconds moved in the current jog, for the trace.
    private var travelled = 0.0

    isolated deinit {
        stop()
    }

    private func start() {
        attachConnected()
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controllersChanged() }
            })
        }
    }

    private func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        attached.values.forEach(Self.restore)
        attached = [:]
        endTouch()
    }

    private func controllersChanged() {
        let connected = Set(GCController.controllers().map(ObjectIdentifier.init))
        for (key, attachment) in attached where !connected.contains(key) {
            Self.restore(attachment)
            attached[key] = nil
            if touching == key { endTouch() }
        }
        attachConnected()
    }

    private func attachConnected() {
        GCController.controllers().forEach(attach)
    }

    /// Siri Remotes only: a touch surface (an analog d-pad) and no game controller profile. A game controller's or
    /// an IR remote's d-pad held in one direction would look like a finger resting on the ring.
    private func attach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard attached[key] == nil, controller.extendedGamepad == nil, let pad = controller.microGamepad,
              pad.dpad.isAnalog else { return }
        attached[key] = Attachment(controller: controller, reportedAbsolute: pad.reportsAbsoluteDpadValues,
                                   allowedRotation: pad.allowsRotation, handler: pad.dpad.valueChangedHandler)
        controller.handlerQueue = .main
        pad.reportsAbsoluteDpadValues = true
        pad.allowsRotation = false
        pad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
            MainActor.assumeIsolated { self?.touched(key, xValue: Double(xValue), yValue: Double(yValue)) }
        }
    }

    private static func restore(_ attachment: Attachment) {
        guard let pad = attachment.controller.microGamepad else { return }
        pad.dpad.valueChangedHandler = attachment.handler
        pad.reportsAbsoluteDpadValues = attachment.reportedAbsolute
        pad.allowsRotation = attachment.allowedRotation
    }

    private func touched(_ key: ObjectIdentifier, xValue: Double, yValue: Double) {
        guard let pad = attached[key]?.controller.microGamepad, touching == nil || touching == key else { return }
        let lifted = RingJog.radius(xValue, yValue) < RingJog.liftRadius
        touching = lifted ? nil : key
        if !canBegin { jog.blockHold() }
        emit(jog.touch(xValue: xValue, yValue: yValue, isPressed: pad.buttonA.isPressed))
        scheduleHoldCheck()
    }

    /// A resting finger sends no new positions, so a timer looks again when the hold would be long enough.
    private func scheduleHoldCheck() {
        guard let deadline = jog.holdDeadline else {
            holdTimer?.cancel()
            holdTimer = nil
            return
        }
        guard holdTimer == nil else { return }
        holdTimer = Task { [weak self] in
            try? await Task.sleep(until: deadline + .milliseconds(5), clock: .continuous)
            guard !Task.isCancelled else { return }
            self?.holdTimer = nil
            self?.checkHold()
        }
    }

    private func checkHold() {
        guard let key = touching, let pad = attached[key]?.controller.microGamepad else { return }
        if !canBegin { jog.blockHold() }
        emit(jog.holdElapsed(isPressed: pad.buttonA.isPressed))
        scheduleHoldCheck()
    }

    private func endTouch() {
        holdTimer?.cancel()
        holdTimer = nil
        touching = nil
        emit(jog.reset())
    }

    private func emit(_ event: RingJog.Event?) {
        guard let event else { return }
        switch event {
        case .began:
            travelled = 0
            if RingJogTrace.isOn { print("Timeline jog began") }
        case .moved(let seconds):
            travelled += seconds
        case .ended:
            if RingJogTrace.isOn { print("Timeline jog ended, moved \(String(format: "%+.1f", travelled)) s") }
        }
        onJog?(event)
    }
}
#endif
