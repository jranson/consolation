import Foundation
import Testing
@testable import HTTPMPEG2Kit

/// The discovery client without the network: nothing here opens a socket or sends a datagram, except the
/// opt-in live test, which runs only with `HTTPMPEG2KIT_LIVE_DISCOVERY=1` in the environment.
@Suite("HDHomeRunDiscoveryClient")
struct DiscoveryClientTests {
    private static let liveDiscoveryEnabled = ProcessInfo.processInfo.environment["HTTPMPEG2KIT_LIVE_DISCOVERY"] == "1"

    @Test func defaultsMatchTheDesign() {
        let configuration = HDHomeRunDiscoveryClient().configuration
        #expect(configuration.window == .milliseconds(1_500))
        #expect(configuration.resendAfter == .milliseconds(500))
        #expect(configuration.includesLimitedBroadcast)
        #expect(TunerDiscoveryPacket.port == 65_001)
    }

    @Test func aCancelledTaskSendsNothing() async {
        let client = HDHomeRunDiscoveryClient()
        // A Result-returning closure: a typed-throws Task closure crashes the Swift 6.4 compiler.
        let task = Task { () async -> Result<[DiscoveredTuner], HDHomeRunClientError> in
            withUnsafeCurrentTask { $0?.cancel() }
            do throws(HDHomeRunClientError) {
                return .success(try await client.discover())
            } catch {
                return .failure(error)
            }
        }
        let result = await task.value
        #expect(throws: HDHomeRunClientError.cancelled) { try result.get() }
    }

    @Test func noTargetsMeansTheLocalNetworkIsUnavailable() async {
        let configuration = HDHomeRunDiscoveryClient.Configuration(includesLimitedBroadcast: false)
        let run = DiscoveryRun(configuration: configuration, interfaces: [])
        await #expect(throws: HDHomeRunClientError.localNetworkUnavailable(errno: 0)) { try await run.execute() }
    }

    /// Sends real discovery broadcasts on the LAN. Opt in with `HTTPMPEG2KIT_LIVE_DISCOVERY=1 swift test`.
    @Test(.enabled(if: liveDiscoveryEnabled, "set HTTPMPEG2KIT_LIVE_DISCOVERY=1 to broadcast on the LAN"))
    func liveDiscoveryFindsTuners() async throws {
        let tuners = try await HDHomeRunDiscoveryClient().discover()
        #expect(!tuners.isEmpty)
        #expect(Set(tuners.map(\.deviceID)).count == tuners.count)
        for tuner in tuners {
            #expect(tuner.deviceID.isValidChecksum)
            #expect((tuner.tunerCount ?? 0) > 0)
            #expect(TunerHost.isIPv4Literal(tuner.ipv4))
        }
    }
}
