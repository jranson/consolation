//
//  LiveTVSourceStatus.swift
//  Consolation
//

import Foundation

/// What the Live TV banner says about the configured tuners.
enum LiveTVSourceStatus: Equatable {
    case notConfigured
    case loading
    case unavailable(String)
    case noChannels
    case ready(freeTuners: Int?, totalTuners: Int?)

    var bannerMessage: String? {
        switch self {
        case .notConfigured: "No Live TV source configured."
        case .unavailable(let reason): "No Live TV source available. \(reason)"
        case .noChannels: "Your tuner has no channels. Run a channel scan in the HDHomeRun app."
        case .loading, .ready: nil
        }
    }

    var bannerSymbol: String {
        switch self {
        case .notConfigured: "antenna.radiowaves.left.and.right.slash"
        default: "exclamationmark.triangle"
        }
    }

    var offersConfigure: Bool {
        switch self {
        case .notConfigured, .unavailable: true
        default: false
        }
    }

    var readyDetail: String? {
        switch self {
        case .loading:
            return "Loading channels…"
        case .ready(let free, let total):
            guard let free, let total else { return nil }
            return "\(free) of \(total) tuners free"
        default:
            return nil
        }
    }
}
