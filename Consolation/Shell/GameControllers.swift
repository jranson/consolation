//
//  GameControllers.swift
//  Consolation
//
//  iPhone, iPad and Mac: the app's one owner of GameController's handlers. GameController keeps only the handler
//  set last, so nothing else in the app (and nothing in EtagereKit) sets one. The d-pad, the left stick, A and B go
//  to one app-wide EtagereGamepad, which hands them to the Etagere that takes them (Home's, while its window is
//  active); B that no Etagere took is "back" in the window in front. Apple TV needs none of this: its focus engine
//  turns controllers into remote commands.
//

import EtagereKit
import Observation
import SwiftUI
#if !os(tvOS)
import GameController
#endif

@Observable
final class GameControllers {
    /// Where Home's Etagere takes controller input; nil on Apple TV.
    @ObservationIgnored let gamepad: EtagereGamepad?
    /// The back action of the active window, for B when no Etagere took it.
    @ObservationIgnored private var back: (window: UUID, action: () -> Void)?
    #if !os(tvOS)
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The controllers whose handlers are ours, so a disconnected one can be let go.
    @ObservationIgnored private var attached: [ObjectIdentifier: GCController] = [:]
    #endif

    /// Does no global work: `start()` attaches the controllers.
    init() {
        #if os(tvOS)
        gamepad = nil
        #else
        gamepad = EtagereGamepad()
        #endif
    }

    /// iPhone and iPad without a hardware keyboard never give the Etagere focus, so there it takes the controller
    /// whenever it is on screen in the active window; on the Mac only while it has keyboard focus.
    static var etagereRequiresFocus: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    #if !os(tvOS)
    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    #endif

    /// Attaches every connected controller and follows connections from now on. Later calls do nothing. Call it
    /// from a view's `.task`, never from an initializer.
    func start() {
        #if !os(tvOS)
        guard !isStarted else { return }
        isStarted = true
        attachConnected()
        observe(.GCControllerDidConnect) { $0.attachConnected() }
        observe(.GCControllerDidDisconnect) { $0.detachDisconnected() }
        #endif
    }

    /// Lets go of every held direction and button (the app left the foreground, or a controller went away).
    func releaseAll() {
        gamepad?.releaseAll()
    }

    /// `window` is the active one: B that no Etagere takes runs `action`.
    func setBackAction(for window: UUID, _ action: @escaping () -> Void) {
        back = (window, action)
    }

    /// `window` is no longer active (or closed).
    func clearBackAction(for window: UUID) {
        if back?.window == window { back = nil }
    }

    /// A button from any controller: the Etagere first, then B as the window's back.
    func buttonChanged(_ button: EtagereGamepad.Button, isPressed: Bool) {
        let taken = gamepad?.buttonChanged(button, isPressed: isPressed) ?? false
        if button == .buttonB, isPressed, !taken { back?.action() }
    }

    #if !os(tvOS)
    /// Runs `action` on the main actor for every `name` notification. The notification's object stays on its side:
    /// the controllers are read again here.
    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (GameControllers) -> Void) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        })
    }

    private func attachConnected() {
        GCController.controllers().forEach(attach)
    }

    private func attach(_ controller: GCController) {
        let key = ObjectIdentifier(controller)
        guard attached[key] == nil else { return }
        attached[key] = controller
        controller.handlerQueue = .main
        if let pad = controller.extendedGamepad {
            pad.dpad.valueChangedHandler = direction(.dpad)
            pad.leftThumbstick.valueChangedHandler = direction(.leftStick)
            pad.buttonA.pressedChangedHandler = button(.buttonA)
            pad.buttonB.pressedChangedHandler = button(.buttonB)
        } else if let pad = controller.microGamepad {
            // A micro gamepad: its d-pad, A to play and X as back.
            pad.dpad.valueChangedHandler = direction(.dpad)
            pad.buttonA.pressedChangedHandler = button(.buttonA)
            pad.buttonX.pressedChangedHandler = button(.buttonB)
        }
    }

    private func detachDisconnected() {
        let connected = Set(GCController.controllers().map(ObjectIdentifier.init))
        for (key, controller) in attached where !connected.contains(key) {
            Self.clearHandlers(of: controller)
            attached[key] = nil
        }
        releaseAll()
    }

    private static func clearHandlers(of controller: GCController) {
        if let pad = controller.extendedGamepad {
            pad.dpad.valueChangedHandler = nil
            pad.leftThumbstick.valueChangedHandler = nil
            pad.buttonA.pressedChangedHandler = nil
            pad.buttonB.pressedChangedHandler = nil
        } else if let pad = controller.microGamepad {
            pad.dpad.valueChangedHandler = nil
            pad.buttonA.pressedChangedHandler = nil
            pad.buttonX.pressedChangedHandler = nil
        }
    }

    /// Handlers run on the main queue (`handlerQueue`).
    private func direction(
        _ control: EtagereGamepad.DirectionalControl
    ) -> GCControllerDirectionPadValueChangedHandler {
        { [weak self] _, xValue, yValue in
            MainActor.assumeIsolated {
                _ = self?.gamepad?.directionChanged(control, xValue: xValue, yValue: yValue)
            }
        }
    }

    private func button(_ button: EtagereGamepad.Button) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            MainActor.assumeIsolated { self?.buttonChanged(button, isPressed: pressed) }
        }
    }
    #endif
}
