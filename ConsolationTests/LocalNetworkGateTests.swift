//
//  LocalNetworkGateTests.swift
//  ConsolationTests
//
//  The Local Network explanation shows once, before the first action that reaches the local network, and never
//  for an internet URL. No views, no network.
//

import Foundation
import Testing
@testable import Consolation

@MainActor
struct LocalNetworkGateTests {
    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ConsolationTests.\(UUID().uuidString)") ?? .standard
    }

    @Test func theFirstLocalActionWaitsForContinue() {
        let defaults = Self.defaults()
        let gate = LocalNetworkGate(defaults: defaults)
        var ran = 0
        gate.perform { ran += 1 }
        #expect(gate.isExplaining)
        #expect(ran == 0)

        gate.proceed()
        #expect(!gate.isExplaining)
        #expect(ran == 1)
        gate.perform { ran += 1 }
        #expect(ran == 2)
        #expect(LocalNetworkGate(defaults: defaults).hasExplained)
    }

    @Test func notNowDropsTheActionAndAsksAgainNextTime() {
        let gate = LocalNetworkGate(defaults: Self.defaults())
        var ran = false
        gate.perform { ran = true }
        gate.dismiss()
        #expect(!ran)
        #expect(!gate.hasExplained)
        gate.perform {}
        #expect(gate.isExplaining)
    }

    @Test func internetURLsNeverWait() throws {
        let gate = LocalNetworkGate(defaults: Self.defaults())
        var ran = false
        gate.perform(for: try #require(URL(string: "https://example.com/stream.m3u8"))) { ran = true }
        #expect(ran)
        #expect(!gate.isExplaining)
    }

    @Test(arguments: [
        "http://hdhomerun.local:5004/auto/v9.1", "http://hdhomerun/lineup.json", "http://192.168.1.20/a.ts",
        "http://10.0.0.5/a.ts", "http://172.20.1.1/a.ts", "http://169.254.3.4/a.ts", "http://127.0.0.1:8080/a",
        "http://[fe80::1]/a.ts", "http://[fd12:3456::1]/a.ts"
    ])
    func localAddressesAreLocal(_ text: String) throws {
        #expect(LocalNetworkGate.isLocal(try #require(URL(string: text))))
    }

    @Test(arguments: [
        "https://example.com/a.m3u8", "http://172.32.0.1/a.ts", "http://8.8.8.8/a", "http://[2001:db8::1]/a",
        "file:///tmp/a.ts"
    ])
    func otherAddressesAreNot(_ text: String) throws {
        #expect(!LocalNetworkGate.isLocal(try #require(URL(string: text))))
    }
}
