import Foundation
import HTTPMPEG2Kit

/// One device's lineup, as `HDHomeRunSource` reads it. Tests supply fixtures; the app uses
/// `HDHomeRunLineupProvider`.
public nonisolated protocol TunerLineupProviding: Sendable {
    /// Reads the device's lineup. Called only from a source method, never at construction.
    func fetchLineup() async throws(HDHomeRunClientError) -> TunerLineup
}

/// One device's channels and the lineup Source they belong to.
public nonisolated struct TunerLineup: Hashable, Sendable {
    /// The device, for broker routing only. Never part of an item ID.
    public var deviceID: TunerDeviceID?
    /// `lineup_status.json` `Source` (`Antenna`, `Cable`); nil when the device didn't say.
    public var lineupSource: String?
    public var channels: [LineupChannel]
    /// `discover.json` `ModelNumber`: which tuners can receive ATSC 3.0 (the broker's tuner choice).
    public var modelNumber: String?

    public init(deviceID: TunerDeviceID? = nil, lineupSource: String? = nil, channels: [LineupChannel],
                modelNumber: String? = nil) {
        self.deviceID = deviceID
        self.lineupSource = lineupSource
        self.channels = channels
        self.modelNumber = modelNumber
    }
}

/// Reads a device through `HDHomeRunClient`: `discover.json` (the DeviceID), `lineup_status.json` (the Source) and
/// `lineup.json?tuning`. GETs only, never a POST or a scan. Creating it makes no connection.
public nonisolated struct HDHomeRunLineupProvider: TunerLineupProviding {
    private let client: HDHomeRunClient
    private let expectedDeviceID: TunerDeviceID?

    /// - Parameter expectedDeviceID: the device on record, if any; a different device answering at a recycled
    ///   address fails with `.deviceMismatch` instead of lending its channels.
    public init(client: HDHomeRunClient, expectedDeviceID: TunerDeviceID? = nil) {
        self.client = client
        self.expectedDeviceID = expectedDeviceID
    }

    /// A provider for a host as the user entered it. Throws `.invalidHost` for anything that isn't a host.
    public init(host: String, expectedDeviceID: TunerDeviceID? = nil,
                configuration: TunerClientConfiguration = TunerClientConfiguration()) throws(HDHomeRunClientError) {
        self.init(client: try HDHomeRunClient(host: host, configuration: configuration),
                  expectedDeviceID: expectedDeviceID)
    }

    public func fetchLineup() async throws(HDHomeRunClientError) -> TunerLineup {
        let discovery: TunerDiscovery
        if let expectedDeviceID {
            discovery = try await client.discover(expecting: expectedDeviceID)
        } else {
            discovery = try await client.discover()
        }
        let status = try? await client.lineupStatus()
        // `tuning` adds each channel's frequency and program number, for multiplex sharing; still one GET.
        let channels = try await client.lineup(tuning: true)
        return TunerLineup(deviceID: discovery.deviceID, lineupSource: status?.source, channels: channels,
                           modelNumber: discovery.modelNumber)
    }
}
