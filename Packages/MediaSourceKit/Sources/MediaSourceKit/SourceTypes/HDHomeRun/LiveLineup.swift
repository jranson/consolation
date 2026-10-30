import Foundation
import HTTPMPEG2Kit

/// The channels of one lineup Source, merged across every device that carries it: each guide number once, in
/// numeric guide order, with every device's route for the broker's failover.
nonisolated struct LiveLineup: Hashable, Sendable {
    struct Channel: Hashable, Sendable {
        /// The entry from the first device (in configuration order) that lists the channel.
        let entry: LineupChannel
        /// A favorite on any device (`"Favorite":1`, or `favorite` in the legacy `Tags`).
        var isFavorite: Bool
        /// Every device that carries the channel, in configuration order.
        var routes: [DeviceChannelRef]
    }

    let lineupSource: String
    let channels: [Channel]

    /// Merges device lineups. Devices that report another lineup Source belong to another logical source and are
    /// skipped. Channels are kept by the rules the Live TV pane applies: playable (a URL, subscribed, no DRM) and
    /// not ATSC 3.0.
    static func merge(_ lineups: [TunerLineup], lineupSource: String) -> LiveLineup {
        var order: [String] = []
        var merged: [String: Channel] = [:]
        for lineup in lineups where lineup.lineupSource == nil || lineup.lineupSource == lineupSource {
            for entry in lineup.channels where entry.isPlayable && !entry.isATSC3 {
                guard let url = entry.url else { continue }
                let route = DeviceChannelRef(deviceID: lineup.deviceID, url: url, frequency: entry.frequency,
                                             programNumber: entry.programNumber, modelNumber: lineup.modelNumber,
                                             signalQuality: entry.signalQuality, isATSC3: entry.isATSC3)
                if var existing = merged[entry.guideNumber] {
                    existing.isFavorite = existing.isFavorite || entry.isFavorite
                    existing.routes.append(route)
                    merged[entry.guideNumber] = existing
                } else {
                    order.append(entry.guideNumber)
                    merged[entry.guideNumber] = Channel(entry: entry, isFavorite: entry.isFavorite, routes: [route])
                }
            }
        }
        let channels = order.sorted(by: GuideNumberOrder.areInIncreasingOrder).compactMap { merged[$0] }
        return LiveLineup(lineupSource: lineupSource, channels: channels)
    }

    func channel(guideNumber: String) -> Channel? {
        channels.first { $0.entry.guideNumber == guideNumber }
    }

    /// The channels as `.channel` items under `source`, in guide order.
    func items(source: SourceID) -> [MediaItem] {
        channels.map { $0.item(source: source) }
    }
}

nonisolated extension LiveLineup.Channel {
    func item(source: SourceID) -> MediaItem {
        let id = MediaItemID(source: source, key: MediaItemID.channelKeyPrefix + entry.guideNumber)
        let name = entry.guideName.trimmingCharacters(in: .whitespaces)
        return MediaItem(
            id: id,
            kind: .channel(number: entry.guideNumber, callSign: name, isHD: entry.isHD, isFavorite: isFavorite),
            title: name.isEmpty ? entry.guideNumber : name,
            subtitle: entry.guideNumber,
            // Live channel cards always use the generated face, never a tuned or captured frame.
            artwork: Artwork(thumb: .stylized(seed: id.cardID)),
            technical: CodecHints(container: .mpegTS, video: entry.videoCodec.map(VideoCodecHint.init),
                                  audio: entry.audioCodec.map(AudioCodecHint.init))
        )
    }
}

nonisolated extension VideoCodecHint {
    init(_ codec: LineupChannel.VideoCodec) {
        switch codec {
        case .mpeg2: self = .mpeg2
        case .h264: self = .h264
        case .hevc: self = .hevc
        case .other: self = .other
        }
    }
}

nonisolated extension AudioCodecHint {
    init(_ codec: LineupChannel.AudioCodec) {
        switch codec {
        case .ac3: self = .ac3
        case .eac3: self = .eac3
        case .ac4: self = .ac4
        case .aac: self = .aac
        case .mpeg: self = .mpeg
        case .other: self = .other
        }
    }
}
