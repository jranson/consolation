import Foundation
@testable import HTTPMPEG2Kit

/// Loads the rewritten FLEX 4K captures and synthetic payloads in `Fixtures/`.
///
/// Every fixture uses the synthetic DeviceID `1234ABC2` (`hdhr-1234abc2.local`) and documentation
/// addresses (192.0.2.x, 2001:db8::/32). None contains `DeviceAuth`.
enum Fixture {
    struct Missing: Error {
        let name: String
    }

    static let deviceID = "1234ABC2"
    static let hostname = "hdhr-1234abc2.local"

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            throw Missing(name: name)
        }
        return try Data(contentsOf: url)
    }

    static func lineup(_ name: String) throws -> [LineupChannel] {
        try TunerJSON.lineup(from: data(name))
    }

    static func tunerStatus(_ name: String) throws -> [TunerStatus] {
        try TunerJSON.tunerStatus(from: data(name))
    }

    static func channel(_ guideNumber: String, in channels: [LineupChannel]) throws -> LineupChannel {
        guard let channel = channels.first(where: { $0.guideNumber == guideNumber }) else {
            throw Missing(name: "channel \(guideNumber)")
        }
        return channel
    }
}
