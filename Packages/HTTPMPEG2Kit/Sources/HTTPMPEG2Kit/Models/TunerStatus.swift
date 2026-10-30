import Foundation

/// One entry of `status.json`.
///
/// An idle tuner reports only `Resource`. A tuner is in use when it reports `VctNumber`, `Frequency` or
/// `TargetIP`: a full-multiplex tune (`/auto/ch<freq>`) shows `Frequency` and `TargetIP` but no
/// `VctNumber`, so checking `VctNumber` alone undercounts busy tuners.
public nonisolated struct TunerStatus: Codable, Sendable, Hashable {
    /// `tuner0`, `tuner1`, ...
    public let resource: String
    public let vctNumber: String?
    public let vctName: String?
    public let frequency: Int?
    public let signalStrengthPercent: Int?
    public let signalQualityPercent: Int?
    public let symbolQualityPercent: Int?
    /// The client receiving the stream: IPv4 (`192.0.2.44`) or bracketed IPv6 (`[fe80::1]`).
    public let targetIP: String?
    /// Informational; reads lower than the measured throughput.
    public let networkRate: Int?

    public init(
        resource: String,
        vctNumber: String? = nil,
        vctName: String? = nil,
        frequency: Int? = nil,
        signalStrengthPercent: Int? = nil,
        signalQualityPercent: Int? = nil,
        symbolQualityPercent: Int? = nil,
        targetIP: String? = nil,
        networkRate: Int? = nil
    ) {
        self.resource = resource
        self.vctNumber = vctNumber
        self.vctName = vctName
        self.frequency = frequency
        self.signalStrengthPercent = signalStrengthPercent
        self.signalQualityPercent = signalQualityPercent
        self.symbolQualityPercent = symbolQualityPercent
        self.targetIP = targetIP
        self.networkRate = networkRate
    }

    /// The verified free-tuner rule: in use when any of `VctNumber`, `Frequency` or `TargetIP` is present.
    public var isInUse: Bool { vctNumber != nil || frequency != nil || targetIP != nil }

    /// `3` for `tuner3`; nil when `Resource` is not of the form `tuner<N>`.
    public var tunerIndex: Int? {
        let prefix = "tuner"
        guard resource.lowercased().hasPrefix(prefix) else { return nil }
        return Int(resource.dropFirst(prefix.count))
    }

    private enum CodingKeys: String, CodingKey {
        case resource = "Resource"
        case vctNumber = "VctNumber"
        case vctName = "VctName"
        case frequency = "Frequency"
        case signalStrengthPercent = "SignalStrengthPercent"
        case signalQualityPercent = "SignalQualityPercent"
        case symbolQualityPercent = "SymbolQualityPercent"
        case targetIP = "TargetIP"
        case networkRate = "NetworkRate"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let resource = container.lenientString(.resource) else {
            throw DecodingError.dataCorruptedError(
                forKey: .resource, in: container, debugDescription: "Missing Resource")
        }
        self.resource = resource
        vctNumber = container.lenientString(.vctNumber)
        vctName = container.lenientString(.vctName)
        frequency = container.lenientInt(.frequency)
        signalStrengthPercent = container.lenientInt(.signalStrengthPercent)
        signalQualityPercent = container.lenientInt(.signalQualityPercent)
        symbolQualityPercent = container.lenientInt(.symbolQualityPercent)
        targetIP = container.lenientString(.targetIP)
        networkRate = container.lenientInt(.networkRate)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resource, forKey: .resource)
        try container.encodeIfPresent(vctNumber, forKey: .vctNumber)
        try container.encodeIfPresent(vctName, forKey: .vctName)
        try container.encodeIfPresent(frequency, forKey: .frequency)
        try container.encodeIfPresent(signalStrengthPercent, forKey: .signalStrengthPercent)
        try container.encodeIfPresent(signalQualityPercent, forKey: .signalQualityPercent)
        try container.encodeIfPresent(symbolQualityPercent, forKey: .symbolQualityPercent)
        try container.encodeIfPresent(targetIP, forKey: .targetIP)
        try container.encodeIfPresent(networkRate, forKey: .networkRate)
    }
}
