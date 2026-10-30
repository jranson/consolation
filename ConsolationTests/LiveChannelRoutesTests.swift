import Foundation
import HTTPMPEG2Kit
import Testing
@testable import Consolation

/// A channel several tuners carry is one channel with a route per tuner, each with where it sits on the air, so
/// the broker can fail over between them and share multiplexes.
struct LiveChannelRoutesTests {
    private static let first = TunerDeviceID(numericValue: 0x1010_ABCD)
    private static let second = TunerDeviceID(numericValue: 0x1020_ABCD)

    private static func lineup(host: String) -> [LineupChannel] {
        [
            LineupChannel(guideNumber: "2.1", guideName: "KAAA", url: URL(string: "http://\(host):5004/auto/v2.1"),
                          frequency: 605_000_000, programNumber: 6),
            LineupChannel(guideNumber: "9.1", guideName: "KCCC", url: URL(string: "http://\(host):5004/auto/v9.1"),
                          frequency: 213_000_000, programNumber: 3)
        ]
    }

    @Test func aLineupChannelCarriesItsTuningAndDevice() throws {
        let channels = LiveChannel.channels(from: Self.lineup(host: "192.0.2.10"), lineupSource: "Antenna",
                                            deviceID: Self.first) { _, _ in .none }
        let channel = try #require(channels.first)
        #expect(channel.routes == [DeviceChannelRef(deviceID: Self.first, url: channel.streamURL,
                                                    frequency: 605_000_000, programNumber: 6)])
    }

    @Test func mergingKeepsOneChannelPerKeyWithEveryDeviceAsARoute() {
        let lists = [("192.0.2.10", Self.first), ("192.0.2.11", Self.second)].map { host, deviceID in
            LiveChannel.channels(from: Self.lineup(host: host), lineupSource: "Antenna", deviceID: deviceID) { _, _ in
                .none
            }
        }
        let merged = LiveChannel.merging(lists)
        #expect(merged.map(\.guideNumber) == ["2.1", "9.1"])
        #expect(merged.map { $0.routes.map(\.deviceID) } == [[Self.first, Self.second], [Self.first, Self.second]])
        #expect(merged.first?.streamURL.host() == "192.0.2.10")
        let request = EngineFactory.tuneRequest(for: merged[1])
        #expect(request.routes.map(\.url.host) == ["192.0.2.10", "192.0.2.11"])
        #expect(request.routes.map(\.programNumber) == [3, 3])
    }

    /// Settings › Live TV › Show ATSC 3.0 channels: off lists none; on lists them with their simulcast, and DRM ones
    /// as protected.
    @Test func atsc3ChannelsShowOnlyWhenAskedWithSimulcastAndDRM() {
        let lineup = [
            LineupChannel(guideNumber: "2.1", guideName: "KAAA-DT", url: URL(string: "http://192.0.2.10:5004/auto/v2.1")),
            LineupChannel(guideNumber: "102.1", guideName: "KAAA", url: URL(string: "http://192.0.2.10:5004/auto/v102.1"),
                          videoCodec: .hevc, audioCodec: .ac4),
            LineupChannel(guideNumber: "107.1", guideName: "KBBB", url: URL(string: "http://192.0.2.10:5004/auto/v107.1"),
                          videoCodec: .hevc, audioCodec: .ac4, drmFlag: true)
        ]
        let hidden = LiveChannel.channels(from: lineup, lineupSource: "Antenna") { _, _ in .none }
        #expect(hidden.map(\.guideNumber) == ["2.1"])
        let shown = LiveChannel.channels(from: lineup, lineupSource: "Antenna", includesATSC3: true) { _, _ in .none }
        #expect(shown.map(\.guideNumber) == ["2.1", "102.1", "107.1"])
        #expect(shown[1].isATSC3 && !shown[1].isProtected && shown[1].simulcast == "2.1")
        #expect(shown[2].isProtected)
        #expect(shown[1].routes.first?.isATSC3 == true)
    }
}
