//
//  MatroskaTrackSelection.swift
//  PlaybackKit
//
//  Which of a Matroska file's tracks play, and how: H.264 and HEVC (from their `avcC`/`hvcC` CodecPrivate) and
//  MPEG-2 video; AAC, AC-3 and E-AC-3 audio. Everything else is named, so the player can say what it can't play.
//

import Foundation
import Matroska
import MPEGTS

/// How a video track is decoded.
nonisolated enum MatroskaVideoCodec: Sendable, Equatable {
    case nal(NALDecoderConfiguration)
    /// MPEG-2 video, with the sequence header CodecPrivate may carry (put in front of keyframes that lack one).
    case mpeg2(sequenceHeader: Data)

    var streamKind: StreamKind {
        switch self {
        case .nal(let config): config.codec == .h264 ? .h264 : .hevc
        case .mpeg2: .mpeg2Video
        }
    }
}

/// How an audio track is decoded.
nonisolated enum MatroskaAudioCodec: Sendable, Equatable {
    /// AC-3 or E-AC-3 syncframes, through the AC-3 framer.
    case dolby(isEAC3: Bool)
    case aac(AudioSpecificConfig)

    var displayName: String {
        switch self {
        case .dolby(let isEAC3): isEAC3 ? "E-AC-3" : "AC-3"
        case .aac(let config): config.profileName
        }
    }
}

nonisolated enum MatroskaTrackSelection {
    static func videoCodec(for track: MatroskaTrack) -> MatroskaVideoCodec? {
        guard track.kind == .video, !track.hasUnsupportedEncoding else { return nil }
        switch track.codecID {
        case "V_MPEG4/ISO/AVC": return NALDecoderConfiguration.avc(track.codecPrivate).map { .nal($0) }
        case "V_MPEGH/ISO/HEVC": return NALDecoderConfiguration.hevc(track.codecPrivate).map { .nal($0) }
        case "V_MPEG2": return .mpeg2(sequenceHeader: track.codecPrivate)
        default: return nil
        }
    }

    static func audioCodec(for track: MatroskaTrack) -> MatroskaAudioCodec? {
        guard track.kind == .audio, !track.hasUnsupportedEncoding else { return nil }
        let codec = track.codecID
        if codec == "A_AC3" || codec.hasPrefix("A_AC3/") { return .dolby(isEAC3: false) }
        if codec == "A_EAC3" { return .dolby(isEAC3: true) }
        guard codec == "A_AAC" || codec.hasPrefix("A_AAC/") else { return nil }
        if let config = AudioSpecificConfig(track.codecPrivate) { return .aac(config) }
        // Old files name the profile in the codec ID (A_AAC/MPEG4/LC, …/SBR) and store no config.
        guard let rate = track.samplingFrequency.map({ Int($0.rounded()) }),
              var config = AudioSpecificConfig(sampleRate: rate, channels: track.channels) else { return nil }
        if codec.hasSuffix("/SBR") {
            let output = track.outputSamplingFrequency.map { Int($0.rounded()) } ?? rate * 2
            if let signalled = config.signallingSBR(outputSampleRate: output) { return .aac(signalled) }
            config.extensionSampleRate = output
            config.extensionObjectType = AudioSpecificConfig.objectTypeSBR
        }
        return .aac(config)
    }

    /// The video track to show: the first enabled one we can decode, a default one first.
    static func video(in tracks: [MatroskaTrack]) -> (track: MatroskaTrack, codec: MatroskaVideoCodec)? {
        let playable = tracks.filter(\.isEnabled).compactMap { track in videoCodec(for: track).map { (track, $0) } }
        return playable.first { $0.0.isDefault } ?? playable.first
    }

    /// The tracks a user can choose between, in file order.
    static func audioOptions(in tracks: [MatroskaTrack]) -> [AudioTrackOption] {
        tracks.filter(\.isEnabled).compactMap { track in
            guard let codec = audioCodec(for: track), let id = Int(exactly: track.number) else { return nil }
            return AudioTrackOption(id: id, language: displayLanguage(track), codec: codec.displayName)
        }
    }

    /// The audio to play: the preferred language (its default track first), else the file's default track, else
    /// the first we can decode.
    static func audio(in tracks: [MatroskaTrack], preferredLanguage: String) -> MatroskaTrack? {
        let playable = tracks.filter { $0.isEnabled && audioCodec(for: $0) != nil }
        let preferred = preferredLanguage.lowercased()
        let matching = playable.filter { languageCode($0) == preferred }
        return matching.first(where: \.isDefault) ?? matching.first ?? playable.first(where: \.isDefault)
            ?? playable.first
    }

    /// When the file has audio but none we can decode, the first audio track's codec ("DTS", "TrueHD"), so the
    /// app can say why there is no sound.
    static func unsupportedAudioCodec(in tracks: [MatroskaTrack]) -> String? {
        let audio = tracks.filter { $0.kind == .audio }
        guard !audio.isEmpty, !audio.contains(where: { audioCodec(for: $0) != nil }) else { return nil }
        return audio.first.map { displayName(codecID: $0.codecID) }
    }

    /// The ISO 639-2 code of a track's language, from LanguageBCP47 when the file has it.
    static func languageCode(_ track: MatroskaTrack) -> String {
        if let tag = track.languageBCP47,
           let code = Locale.Language(identifier: tag).languageCode?.identifier(.alpha3) {
            return code.lowercased()
        }
        return track.language.lowercased()
    }

    /// The language to show for a track; nil for "und" (undetermined).
    static func displayLanguage(_ track: MatroskaTrack) -> String? {
        let code = languageCode(track)
        return code.isEmpty || code == "und" ? nil : code
    }

    private static let codecNames: [String: String] = [
        "A_DTS": "DTS", "A_TRUEHD": "TrueHD", "A_MLP": "MLP", "A_OPUS": "Opus", "A_VORBIS": "Vorbis",
        "A_FLAC": "FLAC", "A_ALAC": "ALAC", "A_MPEG/L3": "MP3", "A_MPEG/L2": "MP2", "A_MPEG/L1": "MP1",
        "A_TTA1": "TTA", "A_WAVPACK4": "WavPack", "A_MS/ACM": "ACM",
        "V_VP8": "VP8", "V_VP9": "VP9", "V_AV1": "AV1", "V_MPEG1": "MPEG-1", "V_MPEG4/ISO/ASP": "MPEG-4 Part 2",
        "V_MPEG4/ISO/SP": "MPEG-4 Part 2", "V_MPEG4/ISO/AP": "MPEG-4 Part 2", "V_MPEG4/MS/V3": "MS MPEG-4",
        "V_MS/VFW/FOURCC": "Video for Windows", "V_THEORA": "Theora", "V_PRORES": "ProRes", "V_FFV1": "FFV1",
        "V_QUICKTIME": "QuickTime"
    ]

    /// A codec ID as people know it: "DTS" for `A_DTS`, "PCM" for any `A_PCM/…`.
    static func displayName(codecID: String) -> String {
        if let name = codecNames[codecID] { return name }
        if codecID.hasPrefix("A_PCM/") { return "PCM" }
        if codecID.hasPrefix("A_REAL/") || codecID.hasPrefix("V_REAL/") { return "RealMedia" }
        if codecID.hasPrefix("A_DTS/") { return "DTS" }
        return codecID.isEmpty ? "unknown" : codecID
    }
}
