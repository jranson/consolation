//
//  LiveChannel.swift
//  Consolation
//
//  The app's view of a live channel, independent of the source that provides it.
//

import Foundation
import HTTPMPEG2Kit

/// Where a channel's favorite mark comes from.
nonisolated enum FavoriteMark: Equatable, Sendable {
    case none
    /// Marked on the device (HDHomeRun). Read-only in the app; shown with `lock.heart.fill`.
    case device
    /// Marked in the app and saved in app storage; shown with `heart.fill`.
    case app

    var systemImage: String? {
        switch self {
        case .none: nil
        case .device: "lock.heart.fill"
        case .app: "heart.fill"
        }
    }

    var isFavorite: Bool { self != .none }
}

nonisolated struct LiveChannel: Identifiable, Hashable, Sendable {
    /// Stable identity used for favorites and the last channel, e.g. "hdhrch:Antenna:9.1".
    let key: String
    let guideNumber: String
    let name: String
    /// The first device's stream URL. Only the tuner broker opens it, through `routes`.
    let streamURL: URL
    let isHD: Bool
    var favorite: FavoriteMark
    /// ATSC 3.0 (shown only when Settings asks): its video plays, its AC-4 audio can't.
    var isATSC3 = false
    /// DRM-protected (A3SA): listed with a badge, never tuned.
    var isProtected = false
    /// For an ATSC 3.0 channel, the guide number of its ATSC 1.0 simulcast, which has sound.
    var simulcast: String?
    /// Every device of the lineup Source that carries the channel, in configuration order, with where it sits on
    /// the air (`lineup.json?tuning`): the broker's candidates for failover and multiplex sharing.
    var routes: [DeviceChannelRef] = []

    var id: String { key }

    var displayName: String { "\(guideNumber) \(name)" }

    /// Numeric major/minor order: 2.1 < 4.1 < 20.1 < 20.4 < 31.1.
    static func guideOrder(_ lhs: LiveChannel, _ rhs: LiveChannel) -> Bool {
        lhs.guideNumber.localizedStandardCompare(rhs.guideNumber) == .orderedAscending
    }

    /// The channels of one tuner's lineup that can play (a URL, subscribed, no DRM, not ATSC 3.0), keyed under
    /// `lineupSource`, in lineup order.
    /// - Parameters:
    ///   - deviceID: the tuner the lineup came from, for routing.
    ///   - mark: the favorite mark for a channel key, given whether the device marks it.
    ///   - modelNumber: the tuner's model, for its ATSC 3.0-capable tuners.
    ///   - includesATSC3: list ATSC 3.0 channels too (DRM ones as protected), with their simulcasts.
    static func channels(from lineup: [LineupChannel], lineupSource: String, deviceID: TunerDeviceID? = nil,
                         modelNumber: String? = nil, includesATSC3: Bool = false,
                         mark: (String, Bool) -> FavoriteMark) -> [LiveChannel] {
        let simulcasts = includesATSC3 ? SimulcastMatcher.simulcasts(in: lineup) : [:]
        return lineup.compactMap { entry in
            guard entry.isATSC3 ? includesATSC3 : entry.isPlayable, entry.isSubscribed,
                  let url = entry.url else { return nil }
            let key = entry.channelKey(source: lineupSource).stringValue
            let route = DeviceChannelRef(deviceID: deviceID, url: url, frequency: entry.frequency,
                                         programNumber: entry.programNumber, modelNumber: modelNumber,
                                         signalQuality: entry.signalQuality, isATSC3: entry.isATSC3)
            return LiveChannel(key: key, guideNumber: entry.guideNumber, name: entry.guideName, streamURL: url,
                               isHD: entry.isHD, favorite: mark(key, entry.isFavorite), isATSC3: entry.isATSC3,
                               isProtected: entry.isDRM, simulcast: simulcasts[entry.guideNumber], routes: [route])
        }
    }

    /// Several tuners' channel lists as one, each guide number once, in guide order: the first list that has a
    /// channel names it, and every list that has it adds its device as another route.
    static func merging(_ lists: [[LiveChannel]]) -> [LiveChannel] {
        var merged: [LiveChannel] = []
        var index: [String: Int] = [:]
        for channel in lists.joined() {
            if let existing = index[channel.key] {
                merged[existing].routes.append(contentsOf: channel.routes)
            } else {
                index[channel.key] = merged.count
                merged.append(channel)
            }
        }
        return merged.sorted(by: guideOrder)
    }
}
