import Foundation
import Testing
@testable import MediaSourceKit

/// Ad breaks: Bullpen's recording resource, and which break a position is in.
@Suite("AdBreaks", .timeLimit(.minutes(1)))
struct AdBreakTests {
    @Test func aRecordingsBreaksComeFromItsRecordingResource() async throws {
        let fetcher = try BullpenFixture.server()
        let source = BullpenFixture.source(fetcher)
        let feed = MediaItemID(source: source.id, key: "feed:/opds/recordings.json")
        let pilot = try #require(try await source.children(of: feed, page: PageRequest(limit: 50)).items.first)
        let list = try await source.adBreaks(for: pilot.id)
        #expect(list.breaks == [AdBreak(start: 612.48, end: 792.52), AdBreak(start: 1500.016, end: 1650.149)])
        #expect(!list.isPending)
        #expect(fetcher.requests.contains("/api/v1/recordings/01a16250-1111-7000-8000-000000000042"))
    }

    @Test func pendingDetectionKeepsWhatItFoundAndDropsEmptyBreaks() throws {
        let json = #"{"adBreaks":{"status":"pending","breaks":[{"start":10,"end":70},{"start":90,"end":90}]}}"#
        let recording = try JSONDecoder().decode(BullpenRecording.self, from: Data(json.utf8))
        #expect(recording.adBreaks == AdBreakList(breaks: [AdBreak(start: 10, end: 70)], isPending: true))
        let none = try JSONDecoder().decode(BullpenRecording.self, from: Data(#"{"id":"x"}"#.utf8))
        #expect(none.adBreaks == nil)
    }

    @Test func theBreakPlayingIsOfferedUntilItsLastSecond() {
        let breaks = [AdBreak(start: 60, end: 120), AdBreak(start: 300, end: 360)]
        #expect(AdBreak.playing(at: 59.9, in: breaks) == nil)
        #expect(AdBreak.playing(at: 60, in: breaks) == breaks[0])
        #expect(AdBreak.playing(at: 118.9, in: breaks) == breaks[0])
        #expect(AdBreak.playing(at: 119.5, in: breaks) == nil)
        #expect(AdBreak.playing(at: 330, in: breaks) == breaks[1])
    }
}
