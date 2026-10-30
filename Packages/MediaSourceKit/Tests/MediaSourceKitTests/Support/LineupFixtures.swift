import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import Synchronization

/// Synthetic lineups in `Fixtures/`: documentation addresses (192.0.2.x), synthetic DeviceIDs and call signs.
enum LineupFixture {
    struct Missing: Error {
        let name: String
    }

    static let deviceA = TunerDeviceID(numericValue: 0x1A2B_3C4D)
    static let deviceB = TunerDeviceID(numericValue: 0x5E6F_7A8B)
    static let deviceCable = TunerDeviceID(numericValue: 0x0C0F_FEE0)

    static func channels(_ name: String) throws -> [LineupChannel] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw Missing(name: name)
        }
        return try JSONDecoder().decode([LineupChannel].self, from: Data(contentsOf: url))
    }

    static func antennaA() throws -> TunerLineup {
        TunerLineup(deviceID: deviceA, lineupSource: "Antenna", channels: try channels("lineup-antenna-a"))
    }

    static func antennaB() throws -> TunerLineup {
        TunerLineup(deviceID: deviceB, lineupSource: "Antenna", channels: try channels("lineup-antenna-b"))
    }

    static func cable() throws -> TunerLineup {
        TunerLineup(deviceID: deviceCable, lineupSource: "Cable", channels: try channels("lineup-cable"))
    }
}

/// A device that answers from a fixture and counts how often it was asked. Nothing leaves the process.
nonisolated final class FixtureLineupProvider: TunerLineupProviding {
    private struct State {
        var answers: [Result<TunerLineup, HDHomeRunClientError>]
        var fetchCount = 0
    }

    private let state: Mutex<State>

    /// Answers each fetch with the next scripted result; the last one repeats.
    init(_ answers: [Result<TunerLineup, HDHomeRunClientError>]) {
        state = Mutex(State(answers: answers))
    }

    convenience init(_ lineup: TunerLineup) {
        self.init([.success(lineup)])
    }

    var fetchCount: Int { state.withLock { $0.fetchCount } }

    func fetchLineup() async throws(HDHomeRunClientError) -> TunerLineup {
        let answer = state.withLock { state in
            state.fetchCount += 1
            return state.answers.count > 1 ? state.answers.removeFirst() : state.answers.first
        }
        switch answer {
        case .success(let lineup): return lineup
        case .failure(let error): throw error
        case nil: throw .invalidResponse
        }
    }

    /// Replaces the scripted answers (a changed lineup, for example).
    func script(_ answers: [Result<TunerLineup, HDHomeRunClientError>]) {
        state.withLock { $0.answers = answers }
    }
}
