//
//  MatroskaPipeline.swift
//  PlaybackKit
//
//  One Matroska (MKV, WebM) file or HTTP resource: bytes go from the source into a read-ahead ring, and a reader
//  pulls from the ring at the renderers' pace, demuxes (`MatroskaDemuxer`), turns the chosen tracks' blocks into
//  framer input (`MatroskaTrackFeed`), and decodes and renders exactly as the transport stream pipeline does, with
//  the same decode stage, renderer, decode tiers and pacing. Ingest and the end of the stream are in
//  MatroskaPipelineIngest.swift, seeking and the timeline in MatroskaPipelineSeek.swift, wake-ups and health in
//  MatroskaPipelineHealth.swift.
//
//  The transport stream pipeline is left alone (it plays live TV): this one shares its parts, not its code paths.
//

import AVFoundation
import Foundation
import Matroska
import MPEGTS
import os

nonisolated final class MatroskaPipeline: @unchecked Sendable {
    // @unchecked: every mutable property below is only touched on `queue` (the ingest task hops onto it).

    enum Event: Sendable {
        case started(PlaybackStreamInfo)
        /// The stream info changed after the start: the audio's channel count (read from its first frame, which
        /// can come after the first picture) or another audio track.
        case info(PlaybackStreamInfo)
        case failed(PlaybackError)
        /// The file was read to its end and everything in it has played.
        case finished
        case diagnostics(PlaybackDiagnostics)
        case audioTracks([AudioTrackOption], selected: Int?)
    }

    /// Bytes read from the ring per step.
    static let readChunk = 256 << 10
    /// The read-ahead ring: about 20 s of a 20 Mbps file. Seeks beyond it reopen the source.
    static let defaultBufferBytes = 48 << 20
    static let log = Logger(subsystem: "PlaybackKit", category: "Matroska")

    let queue = DispatchQueue(label: "PlaybackKit.Matroska", qos: .default)
    let renderer: SampleRenderer
    /// The source playback started with, and the one delivering now (reopened for a seek).
    let source: any ByteSource
    var activeSource: any ByteSource
    let ring: any ByteRing
    let progress = IngestProgress()
    let published = TimelineBox()
    let preferredLanguage: String
    let onEvent: @Sendable (Event) -> Void

    var demuxer = MatroskaDemuxer()
    var segment: MatroskaSegment?
    var cues: MatroskaCues?
    var feed: MatroskaTrackFeed?
    var unsupportedAudioCodec: String?
    var tierGate = DecodeTierGate()
    let videoStage = VideoFrameStage()
    var pendingPictures = PictureQueue()
    private var readBuffer = [UInt8](repeating: 0, count: MatroskaPipeline.readChunk)
    private var framedPictures: [CompressedPicture] = []
    var seek = MatroskaSeekState()

    var pumpTimer: DispatchSourceTimer?
    var readOffset: Int64 = 0 {
        didSet { progress.readOffset = readOffset }
    }
    var paused = false
    var stopped = false
    var announced = false
    /// What `.started` (or the latest `.info`) said.
    var announcedInfo: PlaybackStreamInfo?
    var sourceOpened = false
    /// The source can be reopened at an offset (`ByteSource.reopened(at:)`), and its length.
    var canReopen = false
    var contentLength: Int64?
    var ending = EndOfStream()
    var ingestTask: Task<Void, Never>?
    /// Reads the Cues where the SeekHead says, or the end of a file whose Info has no duration.
    var probeTask: Task<Void, Never>?
    /// Bumped by every reopen; chunks and endings of an older ingest are ignored.
    var ingestGeneration = 0
    /// Network failures the ingest recovered from by reopening where its data stopped.
    var ingestRetries = 0
    var ingestStart = Date()
    /// Bytes delivered by every connection, for the stats overlay's bit rate.
    var bytesIngested: Int64 = 0
    var lastMetrics: (shown: Int, dropped: Int) = (0, 0)
    var nextHealthReport = DispatchTime.now()

    init(source: any ByteSource, ring: any ByteRing, renderer: SampleRenderer, preferredLanguage: String,
         tier: DecodeTier = .single, playsAudio: Bool = true, onEvent: @escaping @Sendable (Event) -> Void) {
        self.source = source
        activeSource = source
        self.ring = ring
        self.renderer = renderer
        self.preferredLanguage = preferredLanguage
        self.onEvent = onEvent
        tierGate.set(tier)
        videoStage.apply(tier)
        renderer.setPlaysAudio(playsAudio)
    }

    // MARK: - Lifecycle

    func start() {
        ingestStart = Date()
        ingestTask = ingest(from: source, generation: 0)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .now(), repeating: .never, leeway: TransportStreamPipeline.pumpLeeway)
        nextHealthReport = .now() + TransportStreamPipeline.healthInterval
        pumpTimer = timer
        timer.resume()
    }

    /// Stops everything. `keepingLastFrame` leaves the last picture on screen.
    func stop(keepingLastFrame: Bool = false) {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            ingestTask?.cancel()
            probeTask?.cancel()
            activeSource.cancel()
            pumpTimer?.cancel()
            pumpTimer = nil
            videoStage.reset()
            renderer.stop(keepingVideo: keepingLastFrame)
            ring.close()
        }
    }

    func setPaused(_ newValue: Bool) {
        queue.async { [self] in
            paused = newValue
            seek.previewing = false
            renderer.setPaused(newValue)
            if !newValue {
                ending.restartDeadline(renderer: renderer)
                pump()
                wakeSoon()
            }
        }
    }

    /// Switches to another audio track (by track number); the audio renderer restarts on it.
    func selectAudio(track number: UInt64) {
        queue.async { [self] in
            guard let segment, let track = segment.track(number),
                  MatroskaTrackSelection.audioCodec(for: track) != nil else { return }
            feed?.selectAudio(track)
            renderer.flushAudio()
            renderer.setHasAudio(true)
            unsupportedAudioCodec = nil
            refreshAudioFacts()
            onEvent(.audioTracks(MatroskaTrackSelection.audioOptions(in: segment.tracks),
                                 selected: Int(exactly: number)))
        }
    }

    func setDecodeTier(_ tier: DecodeTier) {
        queue.async { [self] in
            guard tier != tierGate.tier else { return }
            tierGate.set(tier)
            videoStage.apply(tier)
            if tier == .suspended { videoStage.reset() }
            wakeSoon()
        }
    }

    func setPlaysAudio(_ plays: Bool) {
        queue.async { [self] in renderer.setPlaysAudio(plays) }
    }

    // MARK: - Reading

    var isReading: Bool { !paused || seek.previewing }

    /// Drops everything queued or in flight; presentation starts afresh with the next blocks (after a seek).
    func restartTimeline() {
        feed?.reset()
        videoStage.reset()
        tierGate.restart()
        pendingPictures.removeAll()
        renderer.flushForDiscontinuity()
        wakeSoon()
    }

    /// Feeds the renderers while they want data and the ring has it.
    func pump() {
        guard !stopped, isReading, sourceOpened else { return }
        decodePendingPictures()
        while isReading, !stopped, needsMoreInput, readOffset < ring.writeHead {
            guard readOffset >= ring.oldestOffset else {
                // Never happens while the ingest waits for room; a reopen moved the ring past the reader.
                readOffset = ring.oldestOffset
                continue
            }
            let count = readBuffer.withUnsafeMutableBytes { ring.read(from: readOffset, into: $0) }
            guard count > 0 else { break }
            readOffset += Int64(count)
            readBuffer.withUnsafeBytes { raw in
                demuxer.feed(UnsafeRawBufferPointer(rebasing: raw[..<count])) { handle($0) }
            }
            if let failure = demuxer.failure { return fail(failure) }
            jumpOverLargeSkip()
            decodePendingPictures()
        }
        if ending.ingestEnded { advanceEnd() }
        if seek.previewing, renderer.hasStartedClock { seek.previewing = false }
        if let audioFailure = renderer.audioFailure {
            Self.log.error("Audio renderer error: \(String(describing: audioFailure), privacy: .public)")
        }
        if let failure = renderer.failure {
            Self.log.error("Renderer failed: \(String(describing: failure), privacy: .public)")
            onEvent(.failed(PlaybackError(kind: .renderer, title: "The video couldn't be shown.",
                                          underlying: failure)))
            stopped = true
        }
    }

    /// Reading on past a large element the demuxer skips (Attachments: fonts, cover art) would waste a network
    /// read: reopen after it instead, or move the reader when the ring already holds that far.
    private func jumpOverLargeSkip() {
        guard let target = demuxer.pendingSkip(atLeast: 4 << 20) else { return }
        if target <= ring.writeHead {
            readOffset = target
            demuxer.skipInput(to: target)
        } else if canReopen {
            Self.log.info("Skipping \(target - self.readOffset) bytes the player doesn't need")
            reopen(at: target)
            demuxer.skipInput(to: target)
        }
    }

    private func handle(_ event: MatroskaEvent) {
        switch event {
        case .segment(let segment):
            configure(segment)
        case .cues(let found):
            noteCues(found)
        case .block(let block, let payload):
            handle(block, payload: payload)
        }
    }

    /// The feed is taken out while it works, so its buffers are never shared (and copied on write).
    private func handle(_ block: MatroskaBlock, payload: UnsafeBufferPointer<UInt8>) {
        guard var current = feed.take() else { return }
        if block.track == current.video.number {
            current.appendVideo(block, payload: payload, to: &framedPictures)
            feed = current
            for picture in framedPictures { noteVideoTimestamp(picture.info.pts) }
            pendingPictures.append(contentsOf: framedPictures)
            framedPictures.removeAll(keepingCapacity: true)
            announceIfNeeded()
        } else if block.track == current.audio?.number {
            let samples = current.audioSamples(block, payload: payload)
            feed = current
            for sample in samples where isPresentable(audio: sample) { renderer.enqueueAudio(sample) }
            refreshAudioFacts()
        } else {
            feed = current
        }
    }

    /// Chooses the tracks once the Segment's header is read.
    private func configure(_ segment: MatroskaSegment) {
        self.segment = segment
        guard let (video, codec) = MatroskaTrackSelection.video(in: segment.tracks) else {
            let names = segment.tracks.filter { $0.kind == .video }
                .map { MatroskaTrackSelection.displayName(codecID: $0.codecID) }
            Self.log.notice("No playable video track: \(names.joined(separator: ", "), privacy: .public)")
            let title = names.first.map { "This video's format (\($0)) isn't supported." }
                ?? "This file has no video to play."
            return fail(PlaybackError(kind: .unsupportedFormat, title: title, domain: "Matroska"))
        }
        var configured = MatroskaTrackFeed(segment: segment, video: video, codec: codec)
        let audio = MatroskaTrackSelection.audio(in: segment.tracks, preferredLanguage: preferredLanguage)
        configured.selectAudio(audio)
        feed = configured
        renderer.setHasAudio(audio != nil)
        unsupportedAudioCodec = audio == nil ? MatroskaTrackSelection.unsupportedAudioCodec(in: segment.tracks) : nil
        onEvent(.audioTracks(MatroskaTrackSelection.audioOptions(in: segment.tracks),
                             selected: audio.flatMap { Int(exactly: $0.number) }))
        seek.duration = segment.info.durationSeconds
        let audioName = audio.map { "\($0.codecID) \(MatroskaTrackSelection.languageCode($0))" } ?? "none"
        Self.log.info("Matroska: video \(video.codecID, privacy: .public), audio \(audioName, privacy: .public)")
        probeCuesIfNeeded()
    }

    /// Keep reading while audio is short, or while video is short and no compressed pictures are waiting.
    private var needsMoreInput: Bool {
        guard pendingPictures.count < TransportStreamPipeline.maxPendingPictures else { return false }
        let audioShort = renderer.hasAudioTrack
            && renderer.audioSecondsAhead < TransportStreamPipeline.audioSecondsAhead
        let videoShort = pendingPictures.isEmpty
            && renderer.videoSecondsAhead < TransportStreamPipeline.targetSecondsAhead
        return audioShort || videoShort
    }

    /// Decodes queued pictures only as far as the screen needs (as the transport stream pipeline does).
    func decodePendingPictures() {
        while !stopped, !pendingPictures.isEmpty,
              renderer.videoSecondsAhead < TransportStreamPipeline.targetSecondsAhead,
              let picture = pendingPictures.popFirst() {
            // Before a seek's target only references are decoded (the target's picture may need them).
            let early = seek.presentFrom.map { picture.info.pts < $0 } ?? false
            if early, picture.info.role == .nonReference { continue }
            if tierGate.admit(picture.info.role, pts: picture.info.pts) {
                decode(picture)
            } else if !early {
                renderer.noteSkippedVideo(at: SampleFormats.time(picture.info.pts))
            }
        }
        guard !stopped else { return }
        for sample in videoStage.collectReady() { present(sample) }
    }

    private func decode(_ picture: CompressedPicture) {
        do {
            videoStage.prepare(codec: picture.codec, reorderDepth: picture.reorderDepth)
            for sample in try videoStage.process(picture.sample, info: picture.info) { present(sample) }
        } catch {
            Self.log.error("Video decode failed: \(String(describing: error), privacy: .public)")
            fail(PlaybackError(kind: .decoder, title: "This video can't be decoded here.",
                               detail: String(describing: error)))
        }
    }

    func fail(_ error: MatroskaError) {
        let title = switch error {
        case .notMatroska: "This file isn't a Matroska video."
        case .missingTracks: "This Matroska file has no tracks."
        }
        fail(PlaybackError(kind: .unsupportedFormat, title: title, domain: "Matroska"))
    }

    func fail(_ error: PlaybackError) {
        guard !stopped else { return }
        stopped = true
        onEvent(.failed(error))
    }
}
