import Foundation
import Testing
@testable import PlaybackKit

struct PlaybackErrorTests {
    @Test func wrapsUnderlyingDomainAndCode() {
        let underlying = NSError(domain: "AVFoundationErrorDomain", code: -11_850)
        let error = PlaybackError(kind: .source, title: "Can't open the stream", underlying: underlying)
        #expect(error.domain == "AVFoundationErrorDomain")
        #expect(error.code == -11_850)
        #expect(error.kind == .source)
    }

    @Test func activeStates() {
        #expect(PlaybackState.playing.isActive)
        #expect(PlaybackState.paused.isActive)
        #expect(!PlaybackState.idle.isActive)
        #expect(!PlaybackState.failed(PlaybackError(kind: .network, title: "x")).isActive)
    }
}
