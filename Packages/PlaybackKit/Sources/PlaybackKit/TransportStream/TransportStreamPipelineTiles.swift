//
//  TransportStreamPipelineTiles.swift
//  PlaybackKit
//
//  The pipeline as one multi-view tile: its decode tier, whether its audio plays, and which program of a multiplex it
//  plays.
//

import Foundation
import MPEGTS
import os

nonisolated extension TransportStreamPipeline {
    /// Changes the decode tier from the next picture on. Cheap, safe at any moment, and the timeline carries on.
    func setDecodeTier(_ tier: DecodeTier) {
        queue.async { [self] in
            guard tier != tierGate.tier else { return }
            tierGate.set(tier)
            videoStage.apply(tier)
            if tier == .suspended {
                // Nothing is decoded until a higher tier resumes at an I picture: free the decoder and the pictures
                // held for reordering and look-ahead now, rather than show stale ones then.
                videoStage.reset()
            }
            wakeSoon()
        }
    }

    /// Turns audio on (enqueuing the recent audio the clock hasn't reached) or off (flushing the audio renderer).
    /// The audio timeline, the clock and the reader's pacing are the same either way.
    func setPlaysAudio(_ plays: Bool) {
        queue.async { [self] in renderer.setPlaysAudio(plays) }
    }

    /// What a pipeline applies at one moment (tests).
    struct TileState {
        let tier: DecodeTier
        let playsAudio: Bool
        /// The program it chose, once a PMT arrived.
        let program: UInt16?
        /// The PIDs the demuxer reassembles.
        let pesFilter: Set<UInt16>?
    }

    func tileState() -> TileState {
        queue.sync {
            TileState(tier: tierGate.tier, playsAudio: renderer.playsAudio, program: currentProgram?.programNumber,
                      pesFilter: demuxer.pesFilter)
        }
    }

    /// How far the reader has got in the ring, for tests.
    func readPosition() -> Int64 {
        queue.sync { readOffset }
    }

    /// Selects the program to play from the PAT's programs (`ByteSource.programNumber`, else the first) and has the
    /// demuxer reassemble only its video and audio once it finishes the chunk it is feeding (`pendingPESFilter`).
    func selectProgram(from programs: [ProgramMap], listed: [UInt16]) {
        guard let program = TrackSelection.program(in: programs, listed: listed,
                                                   requested: requestedProgram) else { return }
        if let requestedProgram, Int(program.programNumber) != requestedProgram {
            Self.log.notice("Program \(requestedProgram) isn't in the PAT; playing \(program.programNumber)")
        }
        let video = TrackSelection.video(in: program)
        currentProgram = program
        let chosen = chosenAudioPID.flatMap { pid in program.streams.first { $0.pid == pid } }
        let audio = chosen ?? TrackSelection.audio(in: program, preferredLanguage: preferredLanguage)
        onEvent(.audioTracks(TrackSelection.audioOptions(in: program), selected: audio.map { Int($0.pid) }))
        let language = audio?.language ?? "-"
        Self.log.info(
            "Program \(program.programNumber): video \(video?.pid ?? 0), audio \(audio?.pid ?? 0) \(language)")
        processor.select(video: video, audio: audio)
        pendingPESFilter = Set([video?.pid, audio?.pid].compactMap { $0 })
        if let video { index.selectVideo(pid: video.pid, kind: video.kind, ring: ring) }
        // No audio we can play (ATSC 3.0's AC-4): the clock runs on video alone.
        renderer.setHasAudio(audio != nil)
        unsupportedAudioCodec = audio == nil ? TrackSelection.unsupportedAudioCodec(in: program) : nil
        if video == nil {
            onEvent(.failed(PlaybackError(kind: .unsupportedFormat,
                                          title: "This channel's video format isn't supported yet.")))
        }
    }
}
