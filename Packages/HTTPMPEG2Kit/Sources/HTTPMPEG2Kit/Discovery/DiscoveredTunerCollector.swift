/// Collects discovery replies into one `DiscoveredTuner` per device ID, in first-seen order.
///
/// A device answers each request twice (a legacy and a multi-type reply), once per interface it is reachable
/// on, and again for the resend. The first reply fixes the address and interface; later replies only fill
/// in fields the earlier ones lacked. Replies from non-tuner devices or without a device ID are ignored.
nonisolated struct DiscoveredTunerCollector {
    private(set) var tuners: [DiscoveredTuner] = []
    private var indexByID: [TunerDeviceID: Int] = [:]

    /// Adds a reply. Returns true when it named a device not seen before.
    @discardableResult
    mutating func add(_ reply: TunerDiscoveryReply, from ipv4: String, interfaceName: String?) -> Bool {
        guard reply.isTuner, let deviceID = reply.deviceID else { return false }
        guard let index = indexByID[deviceID] else {
            indexByID[deviceID] = tuners.count
            tuners.append(DiscoveredTuner(
                deviceID: deviceID,
                tunerCount: reply.tunerCount,
                baseURL: reply.baseURL,
                lineupURL: reply.lineupURL,
                ipv4: ipv4,
                interfaceName: interfaceName
            ))
            return true
        }
        let known = tuners[index]
        tuners[index] = DiscoveredTuner(
            deviceID: deviceID,
            tunerCount: known.tunerCount ?? reply.tunerCount,
            baseURL: known.baseURL ?? reply.baseURL,
            lineupURL: known.lineupURL ?? reply.lineupURL,
            ipv4: known.ipv4,
            interfaceName: known.interfaceName
        )
        return false
    }
}
