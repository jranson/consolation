#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Observation
import PlaybackKit
import QuartzCore
import Synchronization
@testable import Consolation

/// Stands in for every tuner on the network: answers lineup and status reads from fixtures and counts every
/// request, including stream GETs through a broker it made. Nothing leaves the process.
nonisolated final class FakeTuners: Sendable {
    private struct State {
        var lineups: [String: DeviceLineup]
        var lineupRequests: [String] = []
        var expectedDeviceIDs: [TunerDeviceID?] = []
        var statusRequests: [String] = []
        var streamRequests = 0
        var inFlight = 0
        var maxInFlight = 0
    }

    private let state: Mutex<State>
    /// How long every lineup request takes, answered or not.
    private let latency: Duration

    /// - Parameters:
    ///   - lineups: by host; any other host is unreachable. A host answers with its fixture whatever DeviceID the
    ///     app expects, as a different device at a reused address would.
    ///   - latency: how long each lineup request takes.
    init(_ lineups: [String: DeviceLineup] = [:], latency: Duration = .zero) {
        state = Mutex(State(lineups: lineups))
        self.latency = latency
    }

    var lineupRequests: [String] { state.withLock { $0.lineupRequests } }
    /// The DeviceID each lineup request expected, in order.
    var expectedDeviceIDs: [TunerDeviceID?] { state.withLock { $0.expectedDeviceIDs } }
    var statusRequests: [String] { state.withLock { $0.statusRequests } }
    var streamRequests: Int { state.withLock { $0.streamRequests } }
    var networkRequests: Int { lineupRequests.count + statusRequests.count + streamRequests }
    /// The most lineup requests that were waiting at once.
    var maxConcurrentLineupRequests: Int { state.withLock { $0.maxInFlight } }

    /// Another device (or none) answers at `host` from now on.
    func setLineup(_ lineup: DeviceLineup?, for host: String) {
        state.withLock { $0.lineups[host] = lineup }
    }

    var fetch: LineupCache.Fetch {
        { [self] host, expected throws(HDHomeRunClientError) in
            state.withLock { state in
                state.lineupRequests.append(host)
                state.expectedDeviceIDs.append(expected)
                state.inFlight += 1
                state.maxInFlight = max(state.maxInFlight, state.inFlight)
            }
            if latency > .zero { try? await Task.sleep(for: latency) }
            let lineup = state.withLock { state in
                state.inFlight -= 1
                return state.lineups[host]
            }
            guard let lineup else { throw .unreachable(host: host, reason: .cannotConnectToHost) }
            return lineup
        }
    }

    var statusReader: LiveTVModel.StatusReaderFactory {
        { [self] host in
            { [self] () throws(HDHomeRunClientError) -> [TunerStatus] in
                state.withLock { $0.statusRequests.append(host) }
                return [TunerStatus(resource: "tuner0"), TunerStatus(resource: "tuner1", vctNumber: "9.1")]
            }
        }
    }

    /// A broker whose every GET is counted and refused.
    func makeBroker() -> TunerBroker {
        TunerBroker(makeStream: { [self] _ in
            state.withLock { $0.streamRequests += 1 }
            return RefusingStream()
        }, fetchStatus: { [self] _ throws(HDHomeRunClientError) in
            state.withLock { $0.statusRequests.append("broker") }
            return []
        })
    }
}

private nonisolated final class RefusingStream: TunerStream {
    let chunks = AsyncThrowingStream<Data, any Error> { $0.finish() }

    func open() async throws(HDHomeRunClientError) -> StreamOpenInfo {
        throw .allTunersInUse
    }

    func cancel() {}
}

/// Synthetic tuners: documentation addresses (192.0.2.x), synthetic DeviceIDs and call signs.
enum TunerFixture {
    static let antennaHost = "192.0.2.10"
    static let cableHost = "192.0.2.20"

    static func url(_ host: String, _ guideNumber: String) -> URL {
        URL(string: "http://\(host):5004/auto/v\(guideNumber)")!
    }

    /// 2.1 (a device favorite), 4.1, 9.1 and 20.4; 7.1 is DRM and 102.1 is ATSC 3.0, so neither plays.
    static let antenna = DeviceLineup(
        discovery: TunerDiscovery(deviceID: TunerDeviceID(numericValue: 0x1A2B_3C4D), friendlyName: "Test Tuner",
                                  tunerCount: 4),
        lineupStatus: LineupStatus(source: "Antenna"),
        channels: [
            LineupChannel(guideNumber: "9.1", guideName: "KCCC", url: url(antennaHost, "9.1"), isHD: true),
            LineupChannel(guideNumber: "2.1", guideName: "KAAA", url: url(antennaHost, "2.1"), isHD: true,
                          favoriteFlag: true),
            LineupChannel(guideNumber: "20.4", guideName: "KDDD", url: url(antennaHost, "20.4")),
            LineupChannel(guideNumber: "4.1", guideName: "KBBB", url: url(antennaHost, "4.1"), isHD: true),
            LineupChannel(guideNumber: "7.1", guideName: "KDRM", url: url(antennaHost, "7.1"), drmFlag: true),
            LineupChannel(guideNumber: "102.1", guideName: "K3", url: url(antennaHost, "102.1"), videoCodec: .hevc)
        ])

    static let cable = DeviceLineup(
        discovery: TunerDiscovery(deviceID: TunerDeviceID(numericValue: 0x0C0F_FEE0), friendlyName: "Cable Tuner",
                                  tunerCount: 3),
        lineupStatus: LineupStatus(source: "Cable"),
        channels: [LineupChannel(guideNumber: "702", guideName: "CBL", url: url(cableHost, "702"))])
}

/// The app's sources stack over fake tuners and throwaway storage: what `AppModel` builds, minus the views.
@MainActor
struct SourcesWorld {
    let tuners: FakeTuners
    let defaults: UserDefaults
    let sources: SourceStore
    let history: QuickPlayHistory
    let favorites: AppFavorites
    let resumePositions: ResumeStore
    let settings: HomeSettings
    let lineups: LineupCache
    let snapshots = InMemoryHomeSnapshotStore()
    let composer: HomeShelfComposer
    let registry: SourceRegistry
    let home: HomeModel
    let liveTV: LiveTVModel

    init(tuners: FakeTuners = FakeTuners()) {
        self.tuners = tuners
        defaults = TestDefaults.make()
        let documents = DefaultsDocumentStore(defaults: defaults)
        sources = SourceStore(documents: documents, defaults: defaults)
        history = QuickPlayHistory(documents: documents, defaults: defaults)
        favorites = AppFavorites(documents: documents, defaults: defaults)
        resumePositions = ResumeStore(documents: documents)
        settings = HomeSettings(defaults: defaults)
        lineups = LineupCache(fetch: tuners.fetch)
        let broker = tuners.makeBroker()
        // The soft timeout never fires on its own: every fake answers at once.
        composer = HomeShelfComposer(configuration: settings.configuration, snapshotStore: snapshots,
                                     sleep: { _ in try await Task.sleep(for: .seconds(30)) })
        registry = SourceRegistry(store: sources, history: history, lineups: lineups, broker: broker,
                                  composer: composer, favorites: favorites, resumePositions: resumePositions)
        home = HomeModel(composer: composer, registry: registry, favorites: favorites,
                         resumePositions: resumePositions, settings: settings)
        liveTV = LiveTVModel(sources: sources, favorites: favorites, lineups: lineups, broker: broker,
                             makeStatusReader: tuners.statusReader)
    }

    @discardableResult
    func addTuner(_ host: String, lineupSource: String? = nil) -> HDHomeRunSourceConfig? {
        guard var config = sources.addHDHomeRun(host: host) else { return nil }
        if let lineupSource {
            config.lineupSource = lineupSource
            sources.update(config)
        }
        registry.syncSources()
        return config
    }
}

enum TestDefaults {
    /// A throwaway suite, empty.
    static func make() -> UserDefaults {
        let name = "ConsolationTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name) ?? .standard
        store.removePersistentDomain(forName: name)
        return store
    }
}

/// Waits (up to about two seconds) for something the app does on a later main-actor turn.
@MainActor
func waitUntil(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// An engine that plays nothing and connects nowhere: its state and position are whatever the test sets.
@Observable
final class FakeEngine: PlaybackEngine {
    var state: PlaybackState = .idle
    var streamInfo = PlaybackStreamInfo()
    let displayLayer = CALayer()
    let displayView = PlatformView(frame: .zero)
    var isMuted = false
    private(set) var isStopped = false

    init(state: PlaybackState = .idle, isLive: Bool = false) {
        self.state = state
        streamInfo.isLive = isLive
    }

    func start() {}
    func pause() {}
    func resume() {}
    func stop() { isStopped = true }
}

extension PlayerSession {
    /// A session whose engines are `FakeEngine`s.
    static func fake() -> PlayerSession {
        PlayerSession(preferences: PlaybackPreferences(defaults: TestDefaults.make())) { _, _, _ in FakeEngine() }
    }
}

extension HomeShelf {
    /// The items' keys within their sources (`ch:9.1`), for compact expectations.
    var keys: [String] { items.map(\.id.key) }
}
