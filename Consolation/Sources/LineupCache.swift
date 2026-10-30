//
//  LineupCache.swift
//  Consolation
//
//  One lineup request per tuner, shared by the Live TV pane and Home's HDHomeRun sources: a lineup either of them
//  fetches serves the other for a minute, and a caller that asks while a fetch runs waits for it instead of sending
//  its own. It fetches only when asked, so with no tuner added it never touches the network.
//

import Foundation
import HTTPMPEG2Kit
import MediaSourceKit

/// One device's `discover.json`, `lineup_status.json` and `lineup.json`, read together. Never persisted.
nonisolated struct DeviceLineup: Hashable, Sendable {
    var discovery: TunerDiscovery
    var lineupStatus: LineupStatus?
    var channels: [LineupChannel]

    /// The lineup Source (`Antenna`, `Cable`), or nil when the device didn't say.
    var lineupSource: String? { lineupStatus?.source }
}

/// A lineup that was fetched from a device (not served from the cache), for the registry's device records.
nonisolated struct LineupFetch: Sendable {
    nonisolated enum Origin: Sendable {
        /// The Live TV pane's own refresh.
        case liveTVPane
        /// A Home source, or resolving a card to play.
        case homeSource
    }

    let host: String
    let lineup: DeviceLineup
    let origin: Origin
}

actor LineupCache {
    /// Reads one device: its host, and the DeviceID it must answer with (nil when none is known yet).
    typealias Fetch = @Sendable (String, TunerDeviceID?) async throws(HDHomeRunClientError) -> DeviceLineup

    /// How long a fetched lineup serves every other caller.
    static let sharingWindow: Duration = .seconds(60)

    private struct Entry {
        var lineup: DeviceLineup
        var fetchedAt: ContinuousClock.Instant
    }

    /// Every lineup fetched from a device. The source registry is its one reader.
    nonisolated let fetches: AsyncStream<LineupFetch>
    private let fetchContinuation: AsyncStream<LineupFetch>.Continuation
    private let fetch: Fetch
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<Result<DeviceLineup, HDHomeRunClientError>, Never>] = [:]
    /// How many requests went to a device; tests check it.
    private(set) var fetchCount = 0

    /// - Parameter fetch: reads one device; tests inject fixtures.
    init(fetch: @escaping Fetch = LineupCache.fetchFromDevice) {
        self.fetch = fetch
        (fetches, fetchContinuation) = AsyncStream.makeStream(of: LineupFetch.self,
                                                              bufferingPolicy: .bufferingNewest(16))
    }

    deinit {
        fetchContinuation.finish()
    }

    /// The device's lineup: the cached one when it is at most `maxAge` old (any age when nil), the running fetch
    /// when there is one, otherwise a new fetch. A device must answer with `deviceID` (the one on record), or with
    /// the DeviceID it had last time: another device answering at a reused address fails with `.deviceMismatch`
    /// instead of lending its channels or overwriting the record.
    func lineup(host: String, expecting deviceID: TunerDeviceID? = nil, maxAge: Duration? = sharingWindow,
                origin: LineupFetch.Origin) async throws(HDHomeRunClientError) -> DeviceLineup {
        let key = Self.key(host)
        if let running = inFlight[key] { return try await running.value.get() }
        let cached = entries[key]
        if let cached, maxAge.map({ ContinuousClock.now - cached.fetchedAt <= $0 }) ?? true,
           deviceID.map({ $0 == cached.lineup.discovery.deviceID }) ?? true {
            return cached.lineup
        }
        let fetch = fetch
        let expected = deviceID ?? cached?.lineup.discovery.deviceID
        let task = Task { () -> Result<DeviceLineup, HDHomeRunClientError> in
            do throws(HDHomeRunClientError) {
                let lineup = try await fetch(host, expected)
                if let expected, lineup.discovery.deviceID != expected {
                    return .failure(.deviceMismatch(expected: expected, found: lineup.discovery.deviceID))
                }
                return .success(lineup)
            } catch {
                return .failure(error)
            }
        }
        inFlight[key] = task
        fetchCount += 1
        let result = await task.value
        // A host forgotten meanwhile (the tuner was removed) keeps nothing.
        if inFlight[key] == task {
            inFlight[key] = nil
            if case .success(let lineup) = result {
                entries[key] = Entry(lineup: lineup, fetchedAt: .now)
                fetchContinuation.yield(LineupFetch(host: host, lineup: lineup, origin: origin))
            }
        }
        return try result.get()
    }

    /// The last lineup fetched from the device, of any age; never fetches.
    func cachedLineup(host: String) -> DeviceLineup? {
        entries[Self.key(host)]?.lineup
    }

    /// Drops everything kept for a removed tuner.
    func forget(host: String) {
        let key = Self.key(host)
        entries[key] = nil
        inFlight[key] = nil
    }

    private static func key(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// `discover.json` (checked against the expected DeviceID, so a different device at a reused address is never
    /// asked for its lineup), then `lineup_status.json` (optional), then `lineup.json?tuning`: GETs only, as the
    /// Live TV pane has always read a tuner.
    @concurrent
    static func fetchFromDevice(_ host: String,
                                expecting deviceID: TunerDeviceID?) async throws(HDHomeRunClientError) -> DeviceLineup {
        let client = try HDHomeRunClient(host: host)
        let discovery: TunerDiscovery
        if let deviceID {
            discovery = try await client.discover(expecting: deviceID)
        } else {
            discovery = try await client.discover()
        }
        let status = try? await client.lineupStatus()
        // `tuning` adds each channel's frequency and program number, for multiplex sharing; still one GET.
        let channels = try await client.lineup(tuning: true)
        return DeviceLineup(discovery: discovery, lineupStatus: status, channels: channels)
    }
}

/// A configured tuner as `HDHomeRunSource` reads it: through the shared cache, so Home and the Live TV pane never
/// both ask a tuner for its lineup within a minute. Creating it makes no connection.
nonisolated struct CachedLineupProvider: TunerLineupProviding {
    let host: String
    /// The DeviceID on record now (filled in after the tuner's first answer), read at every fetch.
    let expectedDeviceID: @MainActor @Sendable () -> TunerDeviceID?
    let cache: LineupCache

    func fetchLineup() async throws(HDHomeRunClientError) -> TunerLineup {
        let deviceID = await expectedDeviceID()
        let lineup = try await cache.lineup(host: host, expecting: deviceID, origin: .homeSource)
        return TunerLineup(deviceID: lineup.discovery.deviceID, lineupSource: lineup.lineupSource,
                           channels: lineup.channels)
    }
}

extension HDHomeRunSourceConfig {
    /// The lineup Source the Live TV pane assumes until a tuner reports its own.
    static let defaultLineupSource = "Antenna"

    /// The logical source (`hdhr-live:<name>`) this tuner feeds.
    var lineupSourceName: String { lineupSource ?? Self.defaultLineupSource }

    /// The DeviceID on record, which the tuner at `host` must answer with.
    var tunerDeviceID: TunerDeviceID? { deviceID.flatMap(TunerDeviceID.init(rawValue:)) }

    /// The record with what the tuner just said about itself.
    func recording(_ lineup: DeviceLineup) -> HDHomeRunSourceConfig {
        var updated = self
        updated.deviceID = lineup.discovery.deviceID.rawValue
        updated.friendlyName = lineup.discovery.friendlyName
        updated.lineupSource = lineup.lineupSource ?? lineupSource
        return updated
    }
}

extension SourceStore {
    /// The DeviceID on record for the tuner at `host`, if it answered before.
    func recordedDeviceID(host: String) -> TunerDeviceID? {
        hdHomeRuns.first { $0.host.caseInsensitiveCompare(host) == .orderedSame }?.tunerDeviceID
    }
}
