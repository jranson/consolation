//
//  MatroskaTrackTests.swift
//  PlaybackKitTests
//
//  Which Matroska tracks play and how (codecs, the audio language, what can't play), and AAC's format description,
//  whose magic cookie AudioToolbox must read as an ES_Descriptor.
//

import AudioToolbox
import CoreMedia
import Foundation
import Matroska
import MPEGTS
import Testing
@testable import PlaybackKit

struct MatroskaTrackTests {
    static func track(_ number: UInt64, _ kind: MatroskaTrack.Kind, _ codec: String, language: String = "eng",
                      isDefault: Bool = true, codecPrivate: [UInt8] = []) -> MatroskaTrack {
        var track = MatroskaTrack(number: number, kind: kind)
        track.codecID = codec
        track.language = language
        track.isDefault = isDefault
        track.codecPrivate = Data(codecPrivate)
        return track
    }

    static let avcC: [UInt8] = [1, 0x64, 0, 0x1F, 0xFF, 0xE1, 0, 4, 0x67, 0x64, 0, 0x1F, 1, 0, 2, 0x68, 0xEE]

    @Test func videoCodecs() {
        let avc = Self.track(1, .video, "V_MPEG4/ISO/AVC", codecPrivate: Self.avcC)
        #expect(MatroskaTrackSelection.videoCodec(for: avc)?.streamKind == .h264)
        #expect(MatroskaTrackSelection.videoCodec(for: Self.track(1, .video, "V_MPEG4/ISO/AVC")) == nil)
        #expect(MatroskaTrackSelection.videoCodec(for: Self.track(1, .video, "V_MPEG2"))?.streamKind == .mpeg2Video)
        #expect(MatroskaTrackSelection.videoCodec(for: Self.track(1, .video, "V_VP9")) == nil)
        var encrypted = avc
        encrypted.hasUnsupportedEncoding = true
        #expect(MatroskaTrackSelection.videoCodec(for: encrypted) == nil)
        // The default video track wins over an earlier one.
        var second = avc
        second.number = 2
        var first = avc
        first.isDefault = false
        #expect(MatroskaTrackSelection.video(in: [first, second])?.track.number == 2)
    }

    @Test func audioCodecs() {
        func codec(_ track: MatroskaTrack) -> MatroskaAudioCodec? { MatroskaTrackSelection.audioCodec(for: track) }
        #expect(codec(Self.track(2, .audio, "A_AC3")) == .dolby(isEAC3: false))
        #expect(codec(Self.track(2, .audio, "A_AC3/BSID9")) == .dolby(isEAC3: false))
        #expect(codec(Self.track(2, .audio, "A_EAC3")) == .dolby(isEAC3: true))
        #expect(codec(Self.track(2, .audio, "A_AAC", codecPrivate: [0x11, 0x90]))?.displayName == "AAC")
        // Old files name the profile and store no config: one is written from the rate and channels.
        var legacy = Self.track(2, .audio, "A_AAC/MPEG4/LC")
        legacy.samplingFrequency = 44_100
        legacy.channels = 2
        guard case .aac(let config) = codec(legacy) else {
            Issue.record("no AAC config")
            return
        }
        #expect(config.bytes == Data([0x12, 0x10]))
        for unsupported in ["A_DTS", "A_TRUEHD", "A_OPUS", "A_FLAC", "A_MPEG/L3"] {
            #expect(codec(Self.track(2, .audio, unsupported)) == nil)
        }
    }

    @Test func audioPrefersTheLanguageThenTheDefault() {
        let english = Self.track(2, .audio, "A_AC3", language: "eng", isDefault: false)
        let spanish = Self.track(3, .audio, "A_AAC", language: "spa", codecPrivate: [0x11, 0x90])
        let dts = Self.track(4, .audio, "A_DTS", language: "eng")
        let tracks = [Self.track(1, .video, "V_MPEG2"), spanish, english, dts]
        #expect(MatroskaTrackSelection.audio(in: tracks, preferredLanguage: "eng")?.number == 2)
        #expect(MatroskaTrackSelection.audio(in: tracks, preferredLanguage: "fre")?.number == 3)
        let options = MatroskaTrackSelection.audioOptions(in: tracks)
        #expect(options.map(\.id) == [3, 2])
        #expect(options.map(\.codec) == ["AAC", "AC-3"])
        #expect(options.map(\.language) == ["spa", "eng"])
        // A BCP 47 tag is read as its ISO 639-2 code.
        var tagged = Self.track(5, .audio, "A_EAC3", language: "und")
        tagged.languageBCP47 = "es-MX"
        #expect(MatroskaTrackSelection.languageCode(tagged) == "spa")
        #expect(MatroskaTrackSelection.unsupportedAudioCodec(in: tracks) == nil)
        #expect(MatroskaTrackSelection.unsupportedAudioCodec(in: [Self.track(1, .video, "V_MPEG2"), dts]) == "DTS")
        #expect(MatroskaTrackSelection.unsupportedAudioCodec(in: [Self.track(1, .video, "V_MPEG2")]) == nil)
        #expect(MatroskaTrackSelection.displayName(codecID: "A_PCM/INT/LIT") == "PCM")
    }

    @Test func aacCookieIsAnESDescriptorAudioToolboxReads() throws {
        let config = try #require(AudioSpecificConfig(Data([0x11, 0x90])))
        let cookie = AACFormat.esDescriptor(config.bytes)
        #expect(Array(cookie.prefix(5)) == [0x03, 0x80, 0x80, 0x80, UInt8(cookie.count - 5)])
        // DecoderSpecificInfo (the config), then SLConfigDescriptor (predefined 2).
        #expect(Array(cookie.suffix(13)) == [0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90,
                                             0x06, 0x80, 0x80, 0x80, 0x01, 0x02])
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = cookie.withUnsafeBytes { raw in
            AudioFormatGetProperty(kAudioFormatProperty_ASBDFromESDS, UInt32(raw.count), raw.baseAddress, &size,
                                   &asbd)
        }
        #expect(status == noErr)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC)
        #expect(asbd.mSampleRate == 48_000)
        #expect(asbd.mChannelsPerFrame == 2)
    }

    @Test func aacFormatDescriptions() throws {
        let plain = try #require(AudioSpecificConfig(Data([0x11, 0x90])))
        let description = try #require(AACFormat.description(plain, channels: 2))
        let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
        #expect(asbd.mFormatID == kAudioFormatMPEG4AAC && asbd.mFramesPerPacket == 1_024)
        #expect(asbd.mSampleRate == 48_000 && asbd.mChannelsPerFrame == 2)
        var cookieSize = 0
        let cookie = CMAudioFormatDescriptionGetMagicCookie(description, sizeOut: &cookieSize)
        #expect(cookie != nil && cookieSize == AACFormat.esDescriptor(plain.bytes).count)
        let heV2 = try #require(AudioSpecificConfig(Data([0xEB, 0x09, 0x88, 0x00])))
        let stereo = try #require(AACFormat.description(heV2, channels: 1))
        let heASBD = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(stereo)?.pointee)
        #expect(heASBD.mFormatID == kAudioFormatMPEG4AAC_HE_V2 && heASBD.mFramesPerPacket == 2_048)
        #expect(heASBD.mSampleRate == 48_000 && heASBD.mChannelsPerFrame == 2)
    }

    @Test func aacFramesAreBatchedUntilTheTimestampsJump() throws {
        let config = try #require(AudioSpecificConfig(Data([0x11, 0x90])))
        var batcher = try #require(AACSampleBatcher(config: config, channels: 2, pool: SampleMemoryPool()))
        #expect(batcher.frameTicks == 1_920)
        let frame: [UInt8] = [0x21, 0x10, 0x04]
        var samples: [CMSampleBuffer] = []
        for index in 0..<6 {
            // The fifth frame comes a second late: the batch ends before it.
            let pts = Int64(index) * 1_920 + (index >= 4 ? 90_000 : 0)
            samples += frame.withUnsafeBufferPointer { batcher.append($0, pts: pts) }
        }
        if let rest = batcher.flush() { samples.append(rest) }
        #expect(samples.map(CMSampleBufferGetNumSamples) == [4, 2])
        #expect(samples.map { CMSampleBufferGetPresentationTimeStamp($0).value } == [0, 4 * 1_920 + 90_000])
    }
}
