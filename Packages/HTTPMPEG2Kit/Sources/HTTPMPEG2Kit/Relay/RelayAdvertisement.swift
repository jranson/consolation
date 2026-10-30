import Foundation

/// What a relay host announces in its Bonjour TXT record: the protocol version, a per-launch instance identifier
/// (so a device can skip its own advertisement) and the channels it can relay right now.
///
/// It never carries an IP address, a tuner's DeviceID or a DeviceAuth: only `ChannelKey` strings such as
/// `tvch:Antenna:9.1`.
///
/// TXT layout: `v=1`, `id=<instance>`, then one entry per channel, `c0=<key>`, `c1=<key>`, ... in order.
public nonisolated struct RelayAdvertisement: Sendable, Hashable {
    public static let currentVersion = 1
    /// TXT records stay small; a host relays at most this many channels at once.
    public static let maxChannels = 16
    /// The longest instance identifier accepted (a UUID string is 36 characters).
    public static let maxInstanceIDLength = 64
    /// A DNS-SD TXT entry is at most 255 bytes, `key=value` included.
    static let maxEntryBytes = 255

    public var version: Int
    public var instanceID: String
    public var channels: [ChannelKey]

    public init(instanceID: String, channels: [ChannelKey], version: Int = Self.currentVersion) {
        self.version = version
        self.instanceID = instanceID
        self.channels = channels
    }

    /// The TXT entries. Channels past `maxChannels`, and keys too long for one entry, are left out.
    public var txtEntries: [String: String] {
        var entries = ["v": String(version), "id": instanceID]
        var index = 0
        for channel in channels where index < Self.maxChannels {
            let key = "c\(index)"
            let value = channel.stringValue
            guard key.utf8.count + 1 + value.utf8.count <= Self.maxEntryBytes else { continue }
            entries[key] = value
            index += 1
        }
        return entries
    }

    /// Reads a TXT record. Nil for another protocol version or a missing or oversized instance identifier;
    /// entries that aren't valid channel keys are skipped, and reading stops at the first missing index.
    public init?(txtEntries entries: [String: String]) {
        guard let versionText = entries["v"], let version = Int(versionText), version == Self.currentVersion,
              let instanceID = entries["id"], !instanceID.isEmpty,
              instanceID.count <= Self.maxInstanceIDLength else { return nil }
        var channels: [ChannelKey] = []
        for index in 0..<Self.maxChannels {
            guard let value = entries["c\(index)"] else { break }
            if let channel = ChannelKey(stringValue: value), !channels.contains(channel) {
                channels.append(channel)
            }
        }
        self.init(instanceID: instanceID, channels: channels, version: version)
    }
}
