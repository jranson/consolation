//
//  TileCapacity.swift
//  PlayerKit
//
//  Whether a source can feed one more tile (tuners, for live channels). The host implements
//  `TileCapacityProviding` (the app adapts its tuner broker), so PlayerKit never knows about tuners or devices.
//

import Foundation

/// What a tile costs beyond CPU.
nonisolated public enum TileCost: Hashable, Sendable {
    /// Shares a stream that is already open (the same channel again, or a channel on an open multiplex).
    case sharedStream
    /// Takes a tuner.
    case tuner
    /// Needs no shared resource (HLS, files, capture), only CPU.
    case cpuOnly
}

/// The answer for one item.
nonisolated public enum TileAdmission: Hashable, Sendable {
    /// It can play. `warning` is user-facing text to show first, for example "Taking the last free tuner may make
    /// recordings on other devices fail."
    case allowed(cost: TileCost, warning: String?)
    /// It can't, with a user-facing reason ("All tuners are in use").
    case denied(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { true } else { false }
    }
}

/// The host's capacity check. A hint: another client can take a tuner at any moment, so an engine may still fail
/// with "all tuners in use" after `.allowed`.
public protocol TileCapacityProviding<Item>: AnyObject {
    associatedtype Item: Hashable & Sendable

    /// Whether `item` can play as one more tile next to `playing` (the items of the other tiles, in grid order).
    func admission(for item: Item, alongside playing: [Item]) async -> TileAdmission
}

/// Why a tile could not be added, replaced or restored.
nonisolated public enum MultiViewError: Error, Hashable, Sendable {
    /// The CPU or layout cap is reached.
    case tileLimit(Int)
    /// The capacity provider said no.
    case unavailable(reason: String)
    /// The tile is not in the session (it was removed meanwhile).
    case unknownTile

    /// User-facing text.
    public var message: String {
        switch self {
        case .tileLimit(let limit): "Multi-view can show up to \(limit) tiles here."
        case .unavailable(let reason): reason
        case .unknownTile: "That tile is no longer playing."
        }
    }
}
