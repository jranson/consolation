//
//  TrackSelection.swift
//  PlaybackKit
//

import MPEGTS

/// Picks the video and audio elementary streams to play from a program map.
nonisolated enum TrackSelection {
    /// The program to play from the programs whose PMT has arrived: `requested` when the PAT (`listed`) has it,
    /// else the first. Nil while the requested program's PMT is still on its way, rather than start another.
    static func program(in programs: [ProgramMap], listed: [UInt16], requested: Int?) -> ProgramMap? {
        guard let requested, let number = UInt16(exactly: requested) else { return programs.first }
        if let match = programs.first(where: { $0.programNumber == number }) { return match }
        return listed.contains(number) ? nil : programs.first
    }

    /// The video stream to show: MPEG-2 when a program somehow has several kinds (every ATSC 1.0 channel is
    /// MPEG-2), else H.264, else HEVC (ATSC 3.0 and some cable channels).
    static func video(in program: ProgramMap) -> ElementaryStream? {
        for kind in [StreamKind.mpeg2Video, .h264, .hevc] {
            if let stream = program.streams.first(where: { $0.kind == kind }) { return stream }
        }
        return nil
    }

    /// When the program has audio but none we can play, the codec of its first audio stream ("AC-4" for ATSC 3.0),
    /// so the app can say why there is no sound. Nil when there is playable audio, or no audio we recognize.
    static func unsupportedAudioCodec(in program: ProgramMap) -> String? {
        guard audioOptions(in: program).isEmpty else { return nil }
        for stream in program.streams {
            switch stream.kind {
            case .ac4: return "AC-4"
            case .aac: return "AAC"
            case .mpegAudio: return "MPEG audio"
            default: continue
            }
        }
        return nil
    }

    /// The program's playable audio tracks, in PMT order.
    static func audioOptions(in program: ProgramMap) -> [AudioTrackOption] {
        program.streams.compactMap { stream in
            switch stream.kind {
            case .ac3: AudioTrackOption(id: Int(stream.pid), language: stream.language, codec: "AC-3")
            case .eac3: AudioTrackOption(id: Int(stream.pid), language: stream.language, codec: "E-AC-3")
            default: nil
            }
        }
    }

    /// Dolby audio in the preferred language first (English 5.1 on US broadcasts), never "the last AC-3 PID".
    static func audio(in program: ProgramMap, preferredLanguage: String) -> ElementaryStream? {
        let dolby = program.streams.filter { stream in
            switch stream.kind {
            case .ac3, .eac3: true
            default: false
            }
        }
        let preferred = preferredLanguage.lowercased()
        let matching = dolby.filter { $0.language?.lowercased() == preferred }
        // The PMT's channel hints are unreliable on air, so keep PMT order (the main track comes first).
        return matching.first ?? dolby.first
    }
}
