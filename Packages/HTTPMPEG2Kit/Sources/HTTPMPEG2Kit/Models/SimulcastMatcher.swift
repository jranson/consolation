import Foundation

/// Maps each ATSC 3.0 channel to the ATSC 1.0 channel that simulcasts it, so the app can offer the one with sound
/// (ATSC 3.0's AC-4 audio has no decoder on Apple platforms). Pure.
///
/// Call signs are normalized by dropping `-DT`, `-HD`, `-TV`, `-LD` and `-CD`. Candidates are 1.0 channels with the
/// same normalized call sign; the one whose major number is the 3.0 major minus 100 wins (a convention in some
/// markets, not universal), then the lowest guide number.
public nonisolated enum SimulcastMatcher {
    static let suffixes = ["-DT", "-HD", "-TV", "-LD", "-CD"]

    /// ATSC 3.0 guide number → its ATSC 1.0 simulcast's guide number, for every 3.0 channel that has one.
    public static func simulcasts(in lineup: [LineupChannel]) -> [String: String] {
        let legacy = lineup.filter { !$0.isATSC3 }
        var matches: [String: String] = [:]
        for channel in lineup where channel.isATSC3 {
            let callSign = normalized(channel.guideName)
            guard !callSign.isEmpty else { continue }
            let candidates = legacy.filter { normalized($0.guideName) == callSign }
            guard !candidates.isEmpty else { continue }
            let expectedMajor = major(channel.guideNumber).map { $0 - 100 }
            let preferred = candidates.filter { major($0.guideNumber) == expectedMajor }
            let pool = preferred.isEmpty ? candidates : preferred
            if let best = pool.min(by: { order($0.guideNumber, $1.guideNumber) }) {
                matches[channel.guideNumber] = best.guideNumber
            }
        }
        return matches
    }

    /// `KUSA-HD` → `KUSA`.
    static func normalized(_ callSign: String) -> String {
        var name = callSign.trimmingCharacters(in: .whitespaces).uppercased()
        for suffix in suffixes where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    private static func major(_ guideNumber: String) -> Int? {
        Int(guideNumber.split(separator: ".").first ?? "")
    }

    private static func order(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}
