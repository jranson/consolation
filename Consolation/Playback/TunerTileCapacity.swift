//
//  TunerTileCapacity.swift
//  Consolation
//
//  Multi-view's capacity check (PlayerKit's `TileCapacityProviding`) answered by the tuner broker: a channel already
//  open (or on an open multiplex) costs nothing, another needs a free tuner after "Keep tuners free for others", and
//  URLs need no tuner. A hint only: another client can take a tuner at any moment.
//

import Foundation
import HTTPMPEG2Kit
import PlayerKit

final class TunerTileCapacity: TileCapacityProviding {
    private let broker: TunerBroker

    init(broker: TunerBroker) {
        self.broker = broker
    }

    func admission(for item: PlayingItem, alongside playing: [PlayingItem]) async -> PlayerKit.TileAdmission {
        guard case .channel(let channel) = item else { return .allowed(cost: .cpuOnly, warning: nil) }
        let request = EngineFactory.tuneRequest(for: channel, purpose: .tile)
        return Self.translate(await broker.admission(for: request))
    }

    static func translate(_ admission: HTTPMPEG2Kit.TileAdmission) -> PlayerKit.TileAdmission {
        switch admission {
        case .free:
            return .allowed(cost: .sharedStream, warning: nil)
        case .needsTuner(_, _, let takesLastFreeTuner):
            let warning = takesLastFreeTuner
                ? String(localized: "Takes the last free tuner; recordings on other devices may fail.") : nil
            return .allowed(cost: .tuner, warning: warning)
        case .retuneOntoMultiplex:
            return .denied(reason: String(localized: """
                No free tuner. It shares a frequency with a tile already playing; stop that tile to free its tuner.
                """))
        case .unavailable(let reason):
            return .denied(reason: message(for: reason))
        }
    }

    private static func message(for reason: TileUnavailableReason) -> String {
        switch reason {
        case .noRoutes: String(localized: "No tuner carries this channel.")
        case .noFreeTuner: String(localized: "No free tuner (some are kept free for others in Settings).")
        case .atsc3TunersBusy: String(localized: "The tuners that receive this channel are busy.")
        case .statusUnavailable: String(localized: "The tuner didn't answer.")
        }
    }
}
