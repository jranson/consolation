import Foundation

/// A tuner that answered a local-network discovery broadcast.
///
/// It carries what the reply said and where it came from, and never the device's auth token. Confirm the
/// device with `HDHomeRunClient.discover()` (at `baseURL`, or `ipv4` when the reply had no base URL) before
/// persisting it as a `TunerDeviceRecord`.
public nonisolated struct DiscoveredTuner: Sendable, Hashable, Identifiable {
    public let deviceID: TunerDeviceID
    public let tunerCount: Int?
    /// The device's HTTP base URL as it announced it, for example `http://192.0.2.10:80`.
    public let baseURL: URL?
    public let lineupURL: URL?
    /// The IPv4 address the reply came from.
    public let ipv4: String
    /// The local interface the reply arrived on (`en0`), or nil when it came in on the unbound fallback socket.
    public let interfaceName: String?

    public var id: TunerDeviceID { deviceID }

    public init(
        deviceID: TunerDeviceID,
        tunerCount: Int? = nil,
        baseURL: URL? = nil,
        lineupURL: URL? = nil,
        ipv4: String,
        interfaceName: String? = nil
    ) {
        self.deviceID = deviceID
        self.tunerCount = tunerCount
        self.baseURL = baseURL
        self.lineupURL = lineupURL
        self.ipv4 = ipv4
        self.interfaceName = interfaceName
    }
}
