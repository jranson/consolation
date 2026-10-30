//
//  PlaybackPreferences.swift
//  Consolation
//
//  Playback settings the user can change in Settings › Playback.
//

import Foundation
import Observation

@Observable
final class PlaybackPreferences {
    static let tunerReleaseRange = 1...60
    static let defaultTunerReleaseMinutes = 10

    /// How the live time-shift buffer is limited.
    enum BufferLimit: String, CaseIterable, Identifiable, Codable {
        case time
        case size

        var id: String { rawValue }
    }

    /// Where the live time-shift buffer lives.
    enum BufferStorage: String, CaseIterable, Identifiable, Codable {
        case disk
        case memory

        var id: String { rawValue }
    }

    /// When multi-view may carry several channels of one RF multiplex on a single tuner.
    enum MultiplexSharing: String, CaseIterable, Identifiable, Codable {
        /// Never: one tuner per channel.
        case never
        /// Only when the channels wanted outnumber the free tuners (the default).
        case whenTunersAreShort
        /// Whenever channels share a multiplex.
        case always

        var id: String { rawValue }
    }

    static let tunerReserveRange = 0...3
    static let defaultTunerReserve = 1

    private let defaults: UserDefaults

    /// Minutes a paused live channel keeps its tuner before releasing it (1–60, default 10).
    var tunerReleaseMinutes: Int {
        didSet { save(Self.clampedRelease(tunerReleaseMinutes), key: "tunerReleaseMinutes") }
    }

    var bufferLimit: BufferLimit {
        didSet { save(bufferLimit.rawValue, key: "bufferLimit") }
    }

    var bufferStorage: BufferStorage {
        didSet { save(bufferStorage.rawValue, key: "bufferStorage") }
    }

    /// Time-shift buffer length when limited by time.
    var bufferMinutes: Int {
        didSet { save(bufferMinutes, key: "bufferMinutes") }
    }

    /// Show closed captions when the stream has them (C key).
    var captionsEnabled: Bool {
        didSet { save(captionsEnabled, key: "captionsEnabled") }
    }

    /// Time-shift buffer size when limited by size.
    var bufferMegabytes: Int {
        didSet { save(bufferMegabytes, key: "bufferMegabytes") }
    }

    /// "Keep N tuners free for others": multi-view tiles never take the last N free tuners (default 1, so the
    /// household's other TVs and DVR recordings keep one). Never limits the stream the user starts.
    var tunerReserve: Int {
        didSet { save(Self.clampedReserve(tunerReserve), key: "tunerReserve") }
    }

    /// Multi-view: in the grid, sound follows the focused tile after a short pause (on by default); off keeps it on
    /// the last tile brought forward.
    var audioFollowsFocus: Bool {
        didSet { save(audioFollowsFocus, key: "audioFollowsFocus") }
    }

    var multiplexSharing: MultiplexSharing {
        didSet { save(multiplexSharing.rawValue, key: "multiplexSharing") }
    }

    /// Live TV lists ATSC 3.0 channels (video only: their AC-4 audio has no decoder here; DRM ones never play).
    /// Off by default.
    var showsATSC3Channels: Bool {
        didSet { save(showsATSC3Channels, key: "showsATSC3Channels") }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let release = defaults.object(forKey: Self.key("tunerReleaseMinutes")) as? Int
        tunerReleaseMinutes = Self.clampedRelease(release ?? Self.defaultTunerReleaseMinutes)
        bufferLimit = defaults.string(forKey: Self.key("bufferLimit")).flatMap(BufferLimit.init) ?? .time
        bufferStorage = defaults.string(forKey: Self.key("bufferStorage")).flatMap(BufferStorage.init) ?? .disk
        bufferMinutes = defaults.object(forKey: Self.key("bufferMinutes")) as? Int ?? 30
        bufferMegabytes = defaults.object(forKey: Self.key("bufferMegabytes")) as? Int ?? 2048
        captionsEnabled = defaults.bool(forKey: Self.key("captionsEnabled"))
        let reserve = defaults.object(forKey: Self.key("tunerReserve")) as? Int
        tunerReserve = Self.clampedReserve(reserve ?? Self.defaultTunerReserve)
        audioFollowsFocus = defaults.object(forKey: Self.key("audioFollowsFocus")) as? Bool ?? true
        showsATSC3Channels = defaults.bool(forKey: Self.key("showsATSC3Channels"))
        multiplexSharing = defaults.string(forKey: Self.key("multiplexSharing")).flatMap(MultiplexSharing.init)
            ?? .whenTunersAreShort
    }

    static func clampedReserve(_ count: Int) -> Int {
        min(max(count, tunerReserveRange.lowerBound), tunerReserveRange.upperBound)
    }

    static func clampedRelease(_ minutes: Int) -> Int {
        min(max(minutes, tunerReleaseRange.lowerBound), tunerReleaseRange.upperBound)
    }

    private static func key(_ name: String) -> String {
        AppIdentifier.scoped("playback.\(name)")
    }

    private func save(_ value: Any, key name: String) {
        defaults.set(value, forKey: Self.key(name))
    }
}
