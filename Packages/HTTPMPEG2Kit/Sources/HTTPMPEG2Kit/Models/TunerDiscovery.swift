import Foundation

/// A device's `discover.json`.
///
/// `DeviceAuth` is deliberately not decoded, stored or encoded: it is a rotating, credential-like token
/// that must never reach storage or logs. `BaseURL` and `LineupURL` follow the Host header the request
/// used (an IP address or `hdhr-<id>.local`), so use them as given.
public nonisolated struct TunerDiscovery: Codable, Sendable, Hashable {
    public let deviceID: TunerDeviceID
    public let friendlyName: String?
    public let modelNumber: String?
    public let firmwareName: String?
    public let firmwareVersion: String?
    public let baseURL: URL?
    public let lineupURL: URL?
    public let tunerCount: Int?
    /// Present on models with built-in storage or a record engine (not on the FLEX 4K).
    public let storageID: String?
    public let storageURL: URL?

    public init(
        deviceID: TunerDeviceID,
        friendlyName: String? = nil,
        modelNumber: String? = nil,
        firmwareName: String? = nil,
        firmwareVersion: String? = nil,
        baseURL: URL? = nil,
        lineupURL: URL? = nil,
        tunerCount: Int? = nil,
        storageID: String? = nil,
        storageURL: URL? = nil
    ) {
        self.deviceID = deviceID
        self.friendlyName = friendlyName
        self.modelNumber = modelNumber
        self.firmwareName = firmwareName
        self.firmwareVersion = firmwareVersion
        self.baseURL = baseURL
        self.lineupURL = lineupURL
        self.tunerCount = tunerCount
        self.storageID = storageID
        self.storageURL = storageURL
    }

    /// The IPv4 address in `BaseURL`, when the device was reached by IPv4 address.
    public var baseIPv4: String? {
        guard let host = baseURL?.host(), TunerHost.isIPv4Literal(host) else { return nil }
        return host
    }

    // `DeviceAuth` is intentionally absent from the coding keys.
    private enum CodingKeys: String, CodingKey {
        case deviceID = "DeviceID"
        case friendlyName = "FriendlyName"
        case modelNumber = "ModelNumber"
        case firmwareName = "FirmwareName"
        case firmwareVersion = "FirmwareVersion"
        case baseURL = "BaseURL"
        case lineupURL = "LineupURL"
        case tunerCount = "TunerCount"
        case storageID = "StorageID"
        case storageURL = "StorageURL"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let rawID = container.lenientString(.deviceID),
              let deviceID = TunerDeviceID(rawValue: rawID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .deviceID, in: container, debugDescription: "Missing or malformed DeviceID")
        }
        self.deviceID = deviceID
        friendlyName = container.lenientString(.friendlyName)
        modelNumber = container.lenientString(.modelNumber)
        firmwareName = container.lenientString(.firmwareName)
        firmwareVersion = container.lenientString(.firmwareVersion)
        baseURL = container.lenientURL(.baseURL)
        lineupURL = container.lenientURL(.lineupURL)
        tunerCount = container.lenientInt(.tunerCount)
        storageID = container.lenientString(.storageID)
        storageURL = container.lenientURL(.storageURL)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceID.rawValue, forKey: .deviceID)
        try container.encodeIfPresent(friendlyName, forKey: .friendlyName)
        try container.encodeIfPresent(modelNumber, forKey: .modelNumber)
        try container.encodeIfPresent(firmwareName, forKey: .firmwareName)
        try container.encodeIfPresent(firmwareVersion, forKey: .firmwareVersion)
        try container.encodeIfPresent(baseURL?.absoluteString, forKey: .baseURL)
        try container.encodeIfPresent(lineupURL?.absoluteString, forKey: .lineupURL)
        try container.encodeIfPresent(tunerCount, forKey: .tunerCount)
        try container.encodeIfPresent(storageID, forKey: .storageID)
        try container.encodeIfPresent(storageURL?.absoluteString, forKey: .storageURL)
    }
}
