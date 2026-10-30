//
//  TransportStreamPipeline.swift
//  PlaybackKit
//
//  One live MPEG-TS stream: bytes arrive from the source into the time-shift ring; a reader pulls from the ring
//  at the renderers' pace, demuxes, frames and enqueues. Pausing stops the reader while the ring keeps filling.
//  Multi-view controls (decode tier, audio on or off, program selection) are in TransportStreamPipelineTiles.swift,
//  the ingest in TransportStreamPipelineIngest.swift, and seeking and the timeline in
//  TransportStreamPipelineSeek.swift.
//

import AVFoundation
import Foundation
import MPEGTS
import os

nonisolated final class TransportStreamPipeline: @unchecked Sendable {
    // @unchecked: every mutable property below is only touched on `queue` (the ingest task hops onto it).

    enum Event: Sendable {
        case started(PlaybackStreamInfo)
        case info(PlaybackStreamInfo)
        case failed(PlaybackError)
        /// A live source's connection ended (the engine reconnects).
        case ended
        /// A finite source (`ByteSource.isFinite`) was read to its end and everything in it has played.
        case finished
        /// No data has arrived for `stallTimeout` while playing.
        case stalled
        case diagnostics(PlaybackDiagnostics)
        case audioTracks([AudioTrackOption], selected: Int?)
        case captions(CaptionScreen)
        case captionServices([CaptionService])
    }

    /// Bytes read from the ring per step (512 TS packets).
    static let readChunk = 188 * 512
    /// "Jump to Live" lands this far behind the head, so the reader finds a sequence header quickly.
    static let liveEdgeBytes: Int64 = 188 * 6_000
    /// Decoded video is kept about this far ahead of the screen; more would only cost memory. Paced by time alone, on
    /// every platform: the tvOS receiver API has no readiness signal, and on macOS and iOS the renderer's
    /// `isReadyForMoreMediaData` turns false at about 0.1 s queued, which woke the pump every 25-35 ms to top it up
    /// one picture at a time. Queuing past it is allowed (memory is the only cost, and this bounds it), wakes the
    /// pump about five times a second instead, and dropped fewer frames in the harness.
    static let targetSecondsAhead = 0.35
    /// The reader runs ahead until audio is buffered this far. In broadcast multiplexes audio is sent later than
    /// video with the same timestamp, so reading must be paced by audio, not by decoded video.
    static let audioSecondsAhead = 1.0
    /// Upper bound on compressed pictures waiting for the decoder (about 8 s at 29.97).
    static let maxPendingPictures = 240
    /// The pump wakes when queued video or audio falls to these levels (see `nextPumpDelay`).
    static let videoLowWater = 0.15
    static let audioLowWater = 0.5
    /// Bounds on the time between wake-ups; `busyPumpDelay` paces start-up and rebuffering, and the longest is the
    /// cadence while paused or waiting for data.
    static let shortestPumpDelay = 0.01
    static let busyPumpDelay = 0.025
    static let longestPumpDelay = 0.25
    static let pumpLeeway: DispatchTimeInterval = .milliseconds(15)
    /// Seconds between health reports and between performance log lines.
    static let healthInterval = 1.0
    static let performanceLogInterval = 10.0

    static let log = Logger(subsystem: "PlaybackKit", category: "TransportStream")

    /// `.default` QoS: the pump's work is small and runs well ahead of need, so it doesn't need the higher class (and
    /// the CPU clocks it pulls) that `.userInitiated` would give it.
    let queue = DispatchQueue(label: "PlaybackKit.TransportStream", qos: .default)
    let renderer: SampleRenderer
    /// The source the stream started with, and the one delivering now (a finite stream reopened for a seek).
    let source: any ByteSource
    var activeSource: any ByteSource
    let ring: any ByteRing
    /// Time to byte offsets in the ring, built by the ingest; and the timeline the engine reads.
    let index = TimeShiftIndex()
    let published = TimelineBox()
    var seek = SeekState()
    let preferredLanguage: String
    var currentProgram: ProgramMap?
    /// The program's audio codec when none of its audio can play (`PlaybackStreamInfo.unsupportedAudioCodec`).
    var unsupportedAudioCodec: String?
    var chosenAudioPID: UInt16?
    /// The program the source asked for (`ByteSource.programNumber`), read once it opened; the reader waits for it.
    var requestedProgram: Int?
    var sourceOpened = false
    /// Which pictures reach the decoder (`DecodeTier`).
    var tierGate = DecodeTierGate()
    let onEvent: @Sendable (Event) -> Void

    var demuxer = TSDemuxer()
    /// A PES filter chosen while the demuxer was feeding a chunk (it can't change then), applied once it's done.
    var pendingPESFilter: Set<UInt16>?
    var processor = ElementaryProcessor()
    let videoStage = VideoFrameStage()
    var pendingPictures = PictureQueue()
    /// The reader's chunk of the ring, reused for every read.
    private var readBuffer = [UInt8](repeating: 0, count: TransportStreamPipeline.readChunk)
    /// The pictures one PES completed, reused for every PES so framing allocates no array.
    private var framedPictures: [CompressedPicture] = []
    var timelineGuard = TimelineGuard()
    private var captionDecoder = CaptionTrackDecoder()
    var pendingCaptions: [CaptionTrackDecoder.Update] = []
    private var reportedCaptionServices: Set<CaptionService> = []
    var pumpTimer: DispatchSourceTimer?
    var readOffset: Int64 = 0 {
        didSet { progress.readOffset = readOffset }
    }
    var paused = false
    var stopped = false
    var announced = false
    /// The reader's position and the ingest's backlog, shared with the ingest task.
    let progress = IngestProgress()
    /// Finite sources: whether this one is, and how far its end has got (TransportStreamPipelineEnd.swift).
    var isFiniteSource = false
    /// A finite source that can be reopened at an offset, and its length (`ByteSource.reopened(at:)`).
    var canReopen = false
    var contentLength: Int64?
    var ending = EndOfStream()
    var ingestTask: Task<Void, Never>?
    /// Reads a finite stream's tail for its length (TransportStreamPipelineDuration.swift).
    var durationProbe: Task<Void, Never>?
    /// Bumped by every reopen; chunks and endings of an older ingest are ignored.
    var ingestGeneration = 0
    var ingestStart = Date()
    var lastDataArrival = Date()
    var stallReported = false
    var lastMetrics: (shown: Int, dropped: Int) = (0, 0)
    var trace = PipelineTrace()
    var nextHealthReport = DispatchTime.now()
    var nextPerformanceLog = DispatchTime.now()

    /// Silence on the connection this long counts as a stall.
    static let stallTimeout: TimeInterval = 3

    /// `tier` and `playsAudio` are the tile's settings at start (the engine keeps them across reconnects).
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
        // One-shot timer, re-armed after every wake-up for when the renderers will next need topping up: every
        // wake-up costs energy for the whole session, and data arriving also pumps.
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.schedule(deadline: .now(), repeating: .never, leeway: Self.pumpLeeway)
        nextHealthReport = .now() + Self.healthInterval
        nextPerformanceLog = .now() + Self.performanceLogInterval
        pumpTimer = timer
        timer.resume()
    }

    /// Stops everything. `keepingLastFrame` leaves the last picture on screen (a finite stream that finished).
    func stop(keepingLastFrame: Bool = false) {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            ingestTask?.cancel()
            durationProbe?.cancel()
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

    /// Switches to another audio track of the current program; the audio renderer restarts on it.
    func selectAudio(pid: UInt16) {
        queue.async { [self] in
            chosenAudioPID = pid
            guard let program = currentProgram,
                  let stream = program.streams.first(where: { $0.pid == pid }) else { return }
            let video = TrackSelection.video(in: program)
            processor.select(video: video, audio: stream)
            demuxer.setPESFilter(Set([video?.pid, stream.pid].compactMap { $0 }))
            renderer.flushAudio()
            onEvent(.audioTracks(TrackSelection.audioOptions(in: program), selected: Int(pid)))
        }
    }

    // MARK: - Reading

    /// Drops everything queued or in flight and starts presentation afresh with the next packets: after a seek,
    /// or when the stream's timestamps jumped.
    func restartTimeline() {
        processor.reset()
        videoStage.reset()
        tierGate.restart()
        pendingPictures.removeAll()
        captionDecoder.reset()
        pendingCaptions.removeAll()
        seek.restartTimeline()
        onEvent(.captions(.empty))
        renderer.flushForDiscontinuity()
        wakeSoon()
    }

    /// Feeds the renderers while they want data and the ring has it.
    func pump() {
        guard !stopped, isReading, sourceOpened, !awaitsRegion() else { return }
        if readOffset < ring.oldestOffset {
            // The pause outlasted the buffer: continue from the oldest data we still have.
            progress.noteOverrun()
            reposition(to: ring.oldestOffset)
            seek.heldPosition = timelineWindow?.lowerBound
            pump()
            return
        }
        decodePendingPictures()
        while isReading, !stopped, needsMoreInput, readOffset < ring.writeHead {
            let count = readBuffer.withUnsafeMutableBytes { ring.read(from: readOffset, into: $0) }
            guard count > 0 else { break }
            readOffset += Int64(count)
            // PES payloads are lent for the call; the handlers must not touch the demuxer or `readBuffer`.
            readBuffer.withUnsafeBytes { raw in
                demuxer.feed(UnsafeRawBufferPointer(rebasing: raw[..<count])) { handle($0) }
            }
            if let filter = pendingPESFilter {
                pendingPESFilter = nil
                demuxer.setPESFilter(filter)
            }
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

    private func handle(_ event: TSDemuxBorrowedEvent) {
        switch event {
        case .programs(let programs, let listed):
            selectProgram(from: programs, listed: listed)
        case .pes(let pes, let payload):
            handle(pes, payload: payload)
        case .discontinuity:
            break
        }
    }

    /// Lost packets (`isDiscontinuity`) don't restart presentation: the framers skip the damage and timestamps
    /// carry on. Only a jump in the timestamps does, whether or not the stream flagged it.
    private func handle(_ pes: PESPacket, payload: UnsafeBufferPointer<UInt8>) {
        let isVideo = pes.pid == processor.videoPID
        guard isVideo || pes.pid == processor.audioPID else { return }
        switch timelineGuard.admit(pid: pes.pid, pts: pes.pts) {
        case .accept:
            break
        case .drop:
            return
        case .restart:
            Self.log.notice("Timestamps jumped on PID \(pes.pid); starting a new timeline")
            restartTimeline()
        case .rejoin:
            processor.restartFramer(video: isVideo)
        }
        if isVideo {
            noteVideoTimestamp(pes.pts)
            processor.appendVideoSamples(from: pes, payload: payload, to: &framedPictures)
            pendingPictures.append(contentsOf: framedPictures)
            for picture in framedPictures { queueCaptions(from: picture) }
            framedPictures.removeAll(keepingCapacity: true)
            announceIfNeeded()
        } else {
            for sample in processor.audioSamples(from: pes, payload: payload) where isPresentable(audio: sample) {
                renderer.enqueueAudio(sample)
            }
        }
    }

    /// Selects which caption service (CC1–CC4) to show.
    func selectCaptions(_ service: CaptionService) {
        queue.async { [self] in
            pendingCaptions.removeAll()
            onEvent(.captions(captionDecoder.select(service)))
        }
    }

    func queueCaptions(from picture: CompressedPicture) {
        pendingCaptions.append(contentsOf: captionDecoder.feedUpdates(pts: picture.info.pts,
                                                                      captionData: picture.captionData))
        if captionDecoder.servicesWithCaptions != reportedCaptionServices {
            reportedCaptionServices = captionDecoder.servicesWithCaptions
            onEvent(.captionServices(CaptionService.allCases.filter { reportedCaptionServices.contains($0) }))
        }
    }

    /// Shows each caption change when its presentation time comes up on the clock.
    func deliverDueCaptions() {
        guard !pendingCaptions.isEmpty else { return }
        let now = CMTimeConvertScale(renderer.currentTime, timescale: 90_000, method: .default).value
        var latest: CaptionScreen?
        while let first = pendingCaptions.first, first.pts <= now {
            latest = first.screen
            pendingCaptions.removeFirst()
        }
        if let latest { onEvent(.captions(latest)) }
    }

    /// Keep reading while audio is short, or while video is short and no compressed pictures are waiting.
    private var needsMoreInput: Bool {
        guard pendingPictures.count < Self.maxPendingPictures else { return false }
        let audioShort = renderer.hasAudioTrack && renderer.audioSecondsAhead < Self.audioSecondsAhead
        let videoShort = pendingPictures.isEmpty && renderer.videoSecondsAhead < Self.targetSecondsAhead
        return audioShort || videoShort
    }

    /// Decodes queued pictures only as far as the screen needs, keeping decoded-frame memory small. Pictures the
    /// decode tier leaves out still move the video timeline on, so pacing is the same at every tier.
    func decodePendingPictures() {
        while !stopped, !pendingPictures.isEmpty, renderer.videoSecondsAhead < Self.targetSecondsAhead,
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
        // Pictures whose GPU pass finished since the last decode go out now rather than with the next picture.
        guard !stopped else { return }
        for sample in videoStage.collectReady() { present(sample) }
    }

    private func decode(_ picture: CompressedPicture) {
        let started = PipelineTrace.isEnabled ? PipelineTrace.now() : 0
        defer { if PipelineTrace.isEnabled { trace.noteDecode(since: started) } }
        do {
            videoStage.prepare(codec: picture.codec, reorderDepth: picture.reorderDepth)
            for sample in try videoStage.process(picture.sample, info: picture.info) { present(sample) }
        } catch {
            Self.log.error("Video decode failed: \(String(describing: error), privacy: .public)")
            stopped = true
            onEvent(.failed(PlaybackError(kind: .decoder, title: "This channel's video can't be decoded here.",
                                          detail: String(describing: error))))
        }
    }

    static func playbackError(from error: any Error) -> PlaybackError {
        if let playback = error as? PlaybackError { return playback }
        return PlaybackError(kind: .network, title: "The stream stopped.", underlying: error)
    }
}
