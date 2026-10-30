//
//  DecoderProbeTests.swift
//  PlaybackKitTests
//

import Foundation
@testable import PlaybackKit
import Testing

struct DecoderProbeTests {
    @Test func macProbeFindsMPEG2AndAC3() async {
        let results = await DecoderProbe.run()
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
        #if os(macOS)
        #expect(byID["video.mpeg2"]?.status != .unavailable)
        #endif
        #expect(byID["audio.ac3"]?.status != .unavailable)
        #expect(byID["video.mpeg2.libavcodec"]?.detail.contains("LGPL") == true)
    }

    @Test func licenceTextIsBundled() throws {
        let text = try #require(SoftwareDecoderLibrary.licenseText)
        #expect(text.contains("GNU LESSER GENERAL PUBLIC LICENSE"))
        #expect(text.contains("Version 2.1"))
        #expect(SoftwareDecoderLibrary.sourceURL.absoluteString.hasPrefix("https://ffmpeg.org/releases/ffmpeg-"))
    }
}
