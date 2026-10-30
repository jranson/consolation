import Foundation

/// What a host app persists about an added HDHomeRun. It never contains `DeviceAuth`.
///
/// Re-validate the identity (`HDHomeRunClient.discover(expecting:)`) whenever the device is reached again:
/// a recycled DHCP address may now belong to another device.
public nonisolated struct TunerDeviceRecord: Codable, Sendable, Hashable, Identifiable {
    public var deviceID: TunerDeviceID
    /// The host exactly as the user entered it: `hdhomerun.local`, `192.0.2.10` or `http://...`.
    public var host: String
    /// The last known IPv4 address, preferred for connections when present.
    public var ipv4: String?
    /// The device's own mDNS name, `hdhr-<id>.local`.
    public var hostname: String
    public var friendlyName: String?
    public var modelNumber: String?
    public var tunerCount: Int?

    public var id: TunerDeviceID { deviceID }

    public init(
        deviceID: TunerDeviceID,
        host: String,
        ipv4: String? = nil,
        hostname: String? = nil,
        friendlyName: String? = nil,
        modelNumber: String? = nil,
        tunerCount: Int? = nil
    ) {
        self.deviceID = deviceID
        self.host = host
        self.ipv4 = ipv4
        self.hostname = hostname ?? deviceID.hostname
        self.friendlyName = friendlyName
        self.modelNumber = modelNumber
        self.tunerCount = tunerCount
    }

    /// A record for a device that answered `discover.json` at `host` (as entered).
    ///
    /// `ipv4` comes from the entered host when it is an IPv4 address, otherwise from `BaseURL`
    /// when the device was reached by IPv4 address.
    public init(discovery: TunerDiscovery, host: String) {
        let enteredHost = TunerHost.baseURL(for: host)?.host()
        let enteredIPv4 = enteredHost.flatMap { TunerHost.isIPv4Literal($0) ? $0 : nil }
        self.init(
            deviceID: discovery.deviceID,
            host: host,
            ipv4: enteredIPv4 ?? discovery.baseIPv4,
            hostname: discovery.deviceID.hostname,
            friendlyName: discovery.friendlyName,
            modelNumber: discovery.modelNumber,
            tunerCount: discovery.tunerCount
        )
    }
}
