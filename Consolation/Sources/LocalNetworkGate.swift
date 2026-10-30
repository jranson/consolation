//
//  LocalNetworkGate.swift
//  Consolation
//
//  Explains Local Network access before the system first asks for it, so its prompt never arrives unexplained. The
//  first action that reaches the local network (searching for or adding a tuner, playing a local-network URL) shows
//  the explanation; Continue runs the action, and the explanation never shows again. Consolation reaches the network
//  only for actions like these: nothing connects until the user adds a source or plays a URL.
//

import Foundation
import Observation

@Observable
final class LocalNetworkGate {
    private static let explainedKey = AppIdentifier.scoped("network.localNetworkExplained")

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pending: (() -> Void)?

    /// The explanation was shown and accepted once.
    private(set) var hasExplained: Bool
    /// The explanation is on screen, waiting for Continue or Not Now.
    private(set) var isExplaining = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasExplained = defaults.bool(forKey: Self.explainedKey)
    }

    /// Runs `action` now, or after the explanation the first time. A second action while the explanation shows
    /// replaces the first.
    func perform(_ action: @escaping () -> Void) {
        guard !hasExplained else {
            action()
            return
        }
        pending = action
        isExplaining = true
    }

    /// Runs `action` for `url`: through the explanation when the URL is on the local network, at once otherwise.
    func perform(for url: URL, _ action: @escaping () -> Void) {
        if Self.isLocal(url) { perform(action) } else { action() }
    }

    /// Continue: the waiting action runs, and later ones run at once.
    func proceed() {
        hasExplained = true
        defaults.set(true, forKey: Self.explainedKey)
        isExplaining = false
        let action = pending
        pending = nil
        action?()
    }

    /// Not Now: the waiting action is dropped; the next one explains again.
    func dismiss() {
        isExplaining = false
        pending = nil
    }

    /// Whether `url` points at this network: a `.local` or dot-less host name, or a private, link-local or
    /// loopback address.
    nonisolated static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return false }
        if host.hasSuffix(".local") || !host.contains(".") && !host.contains(":") { return true }
        if host.contains(":") { return isLocalIPv6(host) }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, host.split(separator: ".").count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168), (169, 254): return true
        case (172, let second): return (16...31).contains(second)
        default: return false
        }
    }

    private nonisolated static func isLocalIPv6(_ host: String) -> Bool {
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return address == "::1" || address.hasPrefix("fe80:") || address.hasPrefix("fc") || address.hasPrefix("fd")
    }
}
