import Foundation

/// One device's tuners split by the verified free-tuner rule (`TunerStatus.isInUse`): free, ours and others.
///
/// `status.json` cannot reserve a tuner, so this is a hint: another client can take a free tuner at any moment.
public nonisolated struct TunerCapacity: Sendable, Hashable {
    /// Every tuner the device reported.
    public let total: Int
    /// Tuners reporting none of `VctNumber`, `Frequency` or `TargetIP`.
    public let free: [TunerStatus]
    /// Busy tuners carrying our own streams.
    public let ours: [TunerStatus]
    /// Busy tuners held by other clients (another TV, a DVR), shown as "tuner2 · 7.1 KMGH · 192.0.2.44".
    public let others: [TunerStatus]

    /// - Parameters:
    ///   - ourResources: the tuners named by `X-HDHomeRun-Resource` on our open streams, such as `tuner2`.
    ///   - ourAddresses: this device's interface addresses, the fallback when the resource is unknown: a busy tuner
    ///     whose `TargetIP` is one of them is ours.
    public init(statuses: [TunerStatus], ourResources: Set<String> = [], ourAddresses: Set<String> = []) {
        let resources = Set(ourResources.map { $0.lowercased() })
        var free: [TunerStatus] = []
        var ours: [TunerStatus] = []
        var others: [TunerStatus] = []
        for tuner in statuses {
            if !tuner.isInUse {
                free.append(tuner)
            } else if resources.contains(tuner.resource.lowercased())
                        || tuner.targetIP.map(ourAddresses.contains) == true {
                ours.append(tuner)
            } else {
                others.append(tuner)
            }
        }
        total = statuses.count
        self.free = free
        self.ours = ours
        self.others = others
    }

    /// Free tuners plus `releasing` of ours that are about to close (for example the stream a new one replaces).
    public func available(releasing: Int = 0) -> Int {
        free.count + min(max(releasing, 0), ours.count)
    }
}
