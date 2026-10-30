//
//  RecentAudio.swift
//  PlaybackKit
//
//  The compressed audio a tile framed recently, kept so a silent tile can become audible at once: turning audio on
//  enqueues the samples the clock hasn't reached yet, so playback continues from about now without a gap and the
//  clock never has to wait for audio to build up again (seamless promotion when audio follows focus).
//

import CoreMedia

nonisolated struct RecentAudio {
    /// Seconds of audio kept. The reader keeps about 1.5 s of audio ahead of the clock (`startAudioBuffer` plus the
    /// start cushion), so this covers the whole read-ahead with room to spare. AC-3 at 448 kbit/s is about 220 KB.
    static let span = 4.0

    private struct Entry {
        let sample: CMSampleBuffer
        let start: CMTime
        let end: CMTime
    }

    private var entries: [Entry] = []

    var count: Int { entries.count }

    /// Adds a sample; drops what the clock (`now`, nil before it starts) has played and whatever is older than
    /// `span` before the newest.
    mutating func append(_ sample: CMSampleBuffer, start: CMTime, end: CMTime, now: CMTime?) {
        entries.append(Entry(sample: sample, start: start, end: end))
        var expired = 0
        for entry in entries.dropLast() {
            let played = now.map { CMTimeCompare(entry.end, $0) <= 0 } ?? false
            guard played || CMTimeSubtract(end, entry.start).seconds > Self.span else { break }
            expired += 1
        }
        if expired > 0 { entries.removeFirst(expired) }
    }

    /// The samples starting at or after `time`, in order (all of them before the clock starts).
    func samples(startingAtOrAfter time: CMTime?) -> [CMSampleBuffer] {
        guard let time else { return entries.map(\.sample) }
        return entries.filter { CMTimeCompare($0.start, time) >= 0 }.map(\.sample)
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}
