import Foundation
import Testing
@testable import HTTPMPEG2Kit

@Suite("lineup.json decoding")
struct LineupDecodingTests {
    private let favorites = ["2.1", "4.1", "6.1", "7.1", "9.1", "20.1", "31.1"]

    @Test func defaultLineupHasSevenFavorites() throws {
        let channels = try Fixture.lineup("lineup")
        #expect(channels.count == 8)
        #expect(channels.filter(\.isFavorite).map(\.guideNumber) == favorites)
        #expect(try !Fixture.channel("20.4", in: channels).isFavorite)
        #expect(channels.allSatisfy { $0.isEnabled && $0.isSubscribed && $0.isPlayable && !$0.isDRM })
        #expect(channels.allSatisfy { $0.videoCodec == .mpeg2 && $0.audioCodec == .ac3 && !$0.isATSC3 })
        #expect(channels.filter(\.isHD).count == 7)
        #expect(channels.allSatisfy { $0.frequency == nil && $0.programNumber == nil })
    }

    @Test func keepsTheURLsTheDeviceReturned() throws {
        let channel = try Fixture.channel("2.1", in: Fixture.lineup("lineup"))
        #expect(channel.guideName == "KWGN-DT")
        #expect(channel.url?.absoluteString == "http://\(Fixture.hostname):5004/auto/v2.1")
        #expect(channel.signalStrength == 59)
        #expect(channel.signalQuality == 99)
        #expect(channel.channelKey(source: "Antenna").stringValue == "tvch:Antenna:2.1")
    }

    @Test func showFoundIncludesHiddenAndDRMChannels() throws {
        let channels = try Fixture.lineup("lineup_show-found")
        #expect(channels.count == 117)
        #expect(channels.filter { !$0.isEnabled }.count == 109)
        #expect(channels.filter(\.isHD).count == 36)
        #expect(Set(channels.filter(\.isDRM).map(\.guideNumber)) == ["107.1", "109.1"])
        #expect(channels.filter(\.isDRM).allSatisfy { !$0.isPlayable })
        #expect(channels.filter(\.isFavorite).map(\.guideNumber) == favorites)
    }

    @Test func showAllTuningDecodesUnsubscribedEntries() throws {
        let channels = try Fixture.lineup("lineup_show-all_tuning")
        #expect(channels.count == 122)
        let unsubscribed = channels.filter { !$0.isSubscribed }
        #expect(unsubscribed.map(\.guideNumber) == ["11.2", "16.5", "26.5", "50.3", "50.5"])
        #expect(unsubscribed.allSatisfy { $0.url == nil && $0.videoCodec == nil && $0.audioCodec == nil })
        #expect(unsubscribed.allSatisfy { !$0.isPlayable })
        #expect(channels.allSatisfy { $0.frequency != nil && $0.modulation != nil && $0.programNumber != nil })
        let withoutTSID = channels.filter { $0.transportStreamID == nil }.map(\.guideNumber)
        #expect(withoutTSID == ["16.1", "16.2", "16.3", "16.4", "26.1", "26.2", "26.3", "26.4"])
    }

    @Test func showAllTuningMarksATSC3Channels() throws {
        let channels = try Fixture.lineup("lineup_show-all_tuning")
        let atsc3 = ["102.1", "107.1", "109.1", "117.1", "131.1"]
        #expect(channels.filter(\.isATSC3).map(\.guideNumber) == atsc3)
        #expect(channels.filter { $0.modulation == "atsc3" }.map(\.guideNumber) == atsc3)
        #expect(channels.filter { $0.plpConfig != nil }.map(\.guideNumber) == atsc3)
        #expect(try Fixture.channel("117.1", in: channels).plpConfig == "0")
        #expect(channels.filter { $0.videoCodec == .mpeg2 }.count == 108)
        #expect(channels.filter { $0.videoCodec == .h264 }.count == 4)
        #expect(channels.filter { $0.videoCodec == .hevc }.count == 5)
        #expect(channels.filter { $0.audioCodec == .ac4 }.count == 5)
        #expect(channels.filter { $0.audioCodec == .mpeg }.count == 2)
    }

    @Test func showAllTuningGroupsFavoritesByMultiplex() throws {
        let channels = try Fixture.lineup("lineup_show-all_tuning")
        let channel = try Fixture.channel("2.1", in: channels)
        #expect(channel.frequency == 605_000_000)
        #expect(channel.programNumber == 6)
        #expect(channel.transportStreamID == 467)
        #expect(channel.modulation == "8vsb")
        let byFrequency = Dictionary(grouping: channels.filter(\.isFavorite)) { $0.frequency ?? 0 }
        #expect(byFrequency.count == 6)
        #expect(byFrequency[605_000_000]?.map(\.guideNumber) == ["2.1", "31.1"])
    }

    @Test func legacyTagsMarkFavoritesAndDRM() throws {
        let channels = try Fixture.lineup("lineup_legacy-tags")
        #expect(channels.count == 5)
        #expect(channels.filter(\.isFavorite).map(\.guideNumber) == ["5.1", "5.2"])
        #expect(channels.filter(\.isDRM).map(\.guideNumber) == ["5.2", "5.3"])
        #expect(try Fixture.channel("5.2", in: channels).tags == ["favorite", "drm"])
        #expect(try Fixture.channel("5.3", in: channels).tags == ["drm"])
        #expect(try Fixture.channel("5.4", in: channels).tags.isEmpty)
        #expect(channels.allSatisfy { !$0.favoriteFlag && !$0.drmFlag })
    }

    @Test func toleratesMissingKeysWrongTypesAndBadEntries() throws {
        let channels = try Fixture.lineup("lineup_quirks")
        // The entry without GuideNumber, the string, the number and the null are dropped.
        #expect(channels.map(\.guideNumber) == ["8.1", "702", "8.3", "8.4"])

        let bare = try Fixture.channel("8.1", in: channels)
        #expect(bare.guideName.isEmpty)
        #expect(bare.isEnabled && bare.isSubscribed && !bare.isHD && !bare.isFavorite && bare.isPlayable)
        #expect(bare.videoCodec == nil && bare.signalStrength == nil)

        let numeric = try Fixture.channel("702", in: channels)
        #expect(numeric.isHD && numeric.isFavorite)
        #expect(numeric.signalStrength == 71)

        let wrongTypes = try Fixture.channel("8.3", in: channels)
        #expect(!wrongTypes.isHD && !wrongTypes.isFavorite)
        #expect(wrongTypes.frequency == nil && wrongTypes.signalQuality == nil && wrongTypes.url == nil)
        #expect(wrongTypes.videoCodec == .other("VP9"))
        #expect(wrongTypes.audioCodec == .eac3)

        let flags = try Fixture.channel("8.4", in: channels)
        #expect(!flags.isEnabled && !flags.isSubscribed && flags.isDRM && !flags.isPlayable)
    }

    @Test func atsc3DetectionWorksFromCodecsAlone() {
        #expect(LineupChannel(guideNumber: "1.1", videoCodec: .hevc, audioCodec: .ac3).isATSC3)
        #expect(LineupChannel(guideNumber: "1.2", videoCodec: .mpeg2, audioCodec: .ac4).isATSC3)
        #expect(LineupChannel(guideNumber: "1.3", modulation: "ATSC3").isATSC3)
        #expect(!LineupChannel(guideNumber: "1.4", videoCodec: .h264, audioCodec: .aac).isATSC3)
    }

    @Test(arguments: ["lineup", "lineup_show-found", "lineup_show-all_tuning", "lineup_legacy-tags", "lineup_quirks"])
    func encodingRoundTrips(fixture: String) throws {
        let channels = try Fixture.lineup(fixture)
        let decoded = try TunerJSON.lineup(from: JSONEncoder().encode(channels))
        #expect(decoded == channels)
    }

    @Test func sortsByGuideNumber() throws {
        let channels = try Fixture.lineup("lineup").reversed().sortedByGuideNumber()
        #expect(channels.map(\.guideNumber) == ["2.1", "4.1", "6.1", "7.1", "9.1", "20.1", "20.4", "31.1"])
    }
}
