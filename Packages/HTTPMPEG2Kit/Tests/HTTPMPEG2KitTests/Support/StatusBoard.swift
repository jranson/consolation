import Foundation
import Synchronization
@testable import HTTPMPEG2Kit

/// Scripted `status.json` per device (by `DeviceChannelRef.deviceKey`) that a test can change while the broker
/// runs. Counts fetches. Nothing leaves the process.
nonisolated final class StatusBoard: Sendable {
    private struct State {
        var statuses: [String: [TunerStatus]] = [:]
        var fetches = 0
    }

    private let state = Mutex(State())

    /// Four tuners: `free` are idle, every other one is held by another client at 192.0.2.44.
    static func tuners(free: Set<Int>, count: Int = 4) -> [TunerStatus] {
        (0..<count).map { index in
            free.contains(index)
                ? TunerStatus(resource: "tuner\(index)")
                : TunerStatus(resource: "tuner\(index)", vctNumber: "7.1", vctName: "KMGH", frequency: 177_000_000,
                              targetIP: "192.0.2.44")
        }
    }

    func set(_ device: String, _ statuses: [TunerStatus]) {
        state.withLock { $0.statuses[device] = statuses }
    }

    func set(_ device: String, free: Set<Int>) {
        set(device, Self.tuners(free: free))
    }

    var fetches: Int { state.withLock { $0.fetches } }

    var fetcher: TunerBroker.StatusFetcher {
        { [self] ref throws(HDHomeRunClientError) in
            let statuses = state.withLock { state in
                state.fetches += 1
                return state.statuses[ref.deviceKey]
            }
            guard let statuses else { throw .unreachable(host: ref.deviceKey, reason: nil) }
            return statuses
        }
    }
}

/// Channels and routes from the rewritten FLEX 4K `?show=all&tuning` lineup: two devices (A is the fixture's
/// synthetic ID, B another synthetic ID at another documentation address) carrying the same channels.
enum MultiView {
    static let deviceA = TunerDeviceID(rawValue: Fixture.deviceID)!
    static let deviceB = TunerDeviceID(numericValue: 0x5E6F_7A8B)
    static let lineup: [LineupChannel] = (try? Fixture.lineup("lineup_show-all_tuning")) ?? []

    static func key(_ guideNumber: String) -> ChannelKey {
        ChannelKey(source: "Antenna", guideNumber: guideNumber)
    }

    /// The channel's route on device A (`192.0.2.10`) or B (`192.0.2.11`), with frequency, program number, model
    /// and signal quality from the fixture.
    static func ref(_ guideNumber: String, on device: TunerDeviceID = deviceA, signalQuality: Int? = nil)
        -> DeviceChannelRef {
        let entry = lineup.first { $0.guideNumber == guideNumber }
        let host = device == deviceA ? "192.0.2.10" : "192.0.2.11"
        return DeviceChannelRef(deviceID: device, url: URL(string: "http://\(host):5004/auto/v\(guideNumber)")!,
                                frequency: entry?.frequency, programNumber: entry?.programNumber,
                                modelNumber: "HDFX-4K", signalQuality: signalQuality ?? entry?.signalQuality,
                                isATSC3: entry?.isATSC3 ?? false)
    }

    static func request(_ guideNumber: String, purpose: TunePurpose = .tile, prefersMultiplex: Bool = false,
                        devices: [TunerDeviceID] = [deviceA]) -> TuneRequest {
        TuneRequest(channel: key(guideNumber), routes: devices.map { ref(guideNumber, on: $0) }, purpose: purpose,
                    prefersMultiplex: prefersMultiplex)
    }

    static func broker(_ device: FakeTunerDevice, status: StatusBoard? = nil, reserve: Int = 0,
                       policy: MultiplexPolicy = .whenTunersAreShort, queueBytes: Int = 5_000_000) -> TunerBroker {
        let configuration = TunerBrokerConfiguration(
            busyRetryDelay: .milliseconds(20), busyRetryWindow: .seconds(5), reserve: reserve,
            multiplexPolicy: policy, statusMaxAge: .zero, subscriberQueueBytes: queueBytes)
        return TunerBroker(configuration: configuration, makeStream: device.factory, fetchStatus: status?.fetcher)
    }

    static func tile() -> SubscriberSlot { .tile(UUID()) }
}
