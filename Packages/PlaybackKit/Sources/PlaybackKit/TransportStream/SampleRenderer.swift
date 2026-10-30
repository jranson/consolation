//
//  SampleRenderer.swift
//  PlaybackKit
//
//  The video layer, the audio renderer and the clock that ties them together for one stream. Enqueueing is done
//  from the pipeline's serial queue; the renderers buffer internally and present on the synchronizer's timeline.
//
//  Multi-view: a silent tile (`playsAudio` false) frames its audio but never enqueues it, so nothing decodes it.
//  The audio timeline is still tracked ("virtual" audio): the clock starts, the reader paces itself and the live
//  buffer guard acts exactly as if the audio were playing. Recent compressed audio is kept in a short window, so
//  turning audio on enqueues what the clock hasn't reached yet and plays without a gap or a rebuffer. Video a tile's
//  decode tier skips is tracked the same way (`noteSkippedVideo`).
//

import AVFoundation
import CoreMedia

// tvOS (whose minimum is 27) uses the OS 27 receiver API; macOS and iOS (minimum 26) use enqueue, which only
// becomes deprecated at 27.
nonisolated final class SampleRenderer: @unchecked Sendable {
    // @unchecked: the AVFoundation renderers are documented as safe to enqueue to from any one queue; our own state
    // (`clockStarted`, `firstVideoTime`) is only touched on the owning pipeline's serial queue.
    /// The display layer's renderer: thread-safe, unlike the layer itself (which is main-actor only).
    let videoRenderer: AVSampleBufferVideoRenderer
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    /// Frame taps see each picture as it is queued (it carries its presentation time).
    private let frameTap: FrameTapHub?
    #if os(tvOS)
    private let videoReceiver: AVSampleBufferVideoRenderer.Receiver
    private let audioReceiver: AVSampleBufferAudioRenderer.Receiver
    private var videoError: (any Error)?
    private var audioError: (any Error)?
    #endif

    /// Presentation starts this far behind the first decodable picture, so audio and video have a cushion.
    static let startCushion = CMTime(value: 45_000, timescale: 90_000)
    /// The clock waits until this much audio is queued. Broadcast multiplexes carry audio about 1.6 s after the video
    /// it belongs to, so starting with less (at the live edge) let audio run dry every few seconds: a hiccup and a
    /// dropped frame each time, until enough latency had built up. Together with `startCushion` this keeps live
    /// playback about 1.5 s of audio ahead of the clock, about 2 s behind the stream's live edge.
    static let startAudioBuffer = 1.0

    private var clockStarted = false
    /// Whether the timeline has started (tests).
    var hasStartedClock: Bool { clockStarted }
    /// When the clock last started. The synchronizer applies a new start time a moment later (about 0.2 s on macOS)
    /// and reports the old time until then.
    private var clockStartedAt = DispatchTime(uptimeNanoseconds: 0)
    static let clockSettleNanoseconds: UInt64 = 1_000_000_000
    /// The time the clock last started at.
    private var clockStartTime = CMTime.zero
    private var isPaused = false
    /// The clock is stopped to rebuild the audio buffer (see `guardLiveBuffer`).
    private(set) var isRebuffering = false
    private var lastVideoTime: CMTime?
    private var firstVideoTime: CMTime?
    private var firstAudioTime: CMTime?
    private var lastAudioEnd: CMTime?
    private(set) var hasAudioTrack = true
    /// A finite stream's last data is queued: start the clock with whatever there is, and never stop it to rebuffer.
    private var endOfStream = false
    /// Whether audio is enqueued (and so decoded and heard). Independent of `isMuted`, the user's mute.
    private(set) var playsAudio = true
    /// Compressed audio kept for promotion to audible, oldest first (`RecentAudio`).
    private var recentAudio = RecentAudio()
    /// Audio sample buffers handed to the audio renderer, for tests and diagnostics.
    private(set) var submittedAudioSamples = 0

    /// Call on the main actor with the layer's renderer (`displayLayer.sampleBufferRenderer`).
    init(videoRenderer: AVSampleBufferVideoRenderer, frameTap: FrameTapHub? = nil) {
        self.videoRenderer = videoRenderer
        self.frameTap = frameTap
        #if os(tvOS)
        videoReceiver = synchronizer.sampleBufferReceiver(adding: videoRenderer)
        audioReceiver = synchronizer.sampleBufferReceiver(adding: audioRenderer)
        #else
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        #endif
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    var isMuted: Bool {
        get { audioRenderer.isMuted }
        set { audioRenderer.isMuted = newValue }
    }

    /// The audio renderer's volume, 0...1, for crossfades between tiles.
    var volume: Float {
        get { audioRenderer.volume }
        set { audioRenderer.volume = min(max(newValue, 0), 1) }
    }

    /// The stream has no audio we can play; start the clock on video alone.
    func setHasAudio(_ hasAudio: Bool) {
        hasAudioTrack = hasAudio
    }

    var failure: (any Error)? {
        #if os(tvOS)
        videoError
        #else
        videoRenderer.error
        #endif
    }

    var currentTime: CMTime { synchronizer.currentTime() }
    /// The clock's rate (1 while playing; 0 paused or rebuffering).
    var rate: Float { synchronizer.rate }

    /// The clock in 90 kHz ticks once it runs on the current timeline (nil before). Right after a start the
    /// synchronizer can still report the time before it (`clockStartedAt`); such readings are nil too.
    var clockTicks: Int64? {
        guard clockStarted else { return nil }
        let now = synchronizer.currentTime()
        let sinceStart = Double(DispatchTime.now().uptimeNanoseconds - clockStartedAt.uptimeNanoseconds) / 1e9
        let offset = CMTimeSubtract(now, clockStartTime).seconds
        guard offset >= -0.05, offset <= sinceStart + 0.25 else { return nil }
        return CMTimeConvertScale(now, timescale: SampleFormats.timescale, method: .default).value
    }

    /// The first picture queued on the current timeline (tests).
    var firstQueuedVideoTime: CMTime? { firstVideoTime }

    func enqueueVideo(_ sample: CMSampleBuffer) {
        let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
        frameTap?.offer(sample)
        #if os(tvOS)
        // The buffer is complete and never mutated after this point, so handing it over is safe.
        nonisolated(unsafe) let handoff = sample
        switch videoReceiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: handoff)) {
        case .cancelledDueToError(let error): videoError = error
        case .cancelledDueToFlushRequiredToResume: videoReceiver.flush()
        default: break
        }
        #else
        if videoRenderer.status == .failed { videoRenderer.flush() }
        videoRenderer.enqueue(sample)
        #endif
        noteVideo(at: time)
    }

    /// A picture the decode tier left out: the video timeline moves on as if it had been shown, so the clock starts
    /// and the reader paces itself the same at every tier.
    func noteSkippedVideo(at time: CMTime) {
        noteVideo(at: time)
    }

    private func noteVideo(at time: CMTime) {
        if firstVideoTime == nil { firstVideoTime = time }
        // Skipped pictures are noted in decode order and shown ones after the decoder: keep the latest.
        lastVideoTime = lastVideoTime.map { CMTimeMaximum($0, time) } ?? time
        startClockIfReady()
    }

    /// Queues one audio sample buffer, or for a silent tile only tracks its timeline.
    func enqueueAudio(_ sample: CMSampleBuffer) {
        let start = CMSampleBufferGetPresentationTimeStamp(sample)
        let end = CMTimeAdd(start, CMSampleBufferGetDuration(sample))
        recentAudio.append(sample, start: start, end: end, now: clockStarted ? synchronizer.currentTime() : nil)
        if playsAudio { submitAudio(sample) }
        if firstAudioTime == nil { firstAudioTime = start }
        lastAudioEnd = end
        startClockIfReady()
        resumeAfterRebufferIfReady()
    }

    /// Turns audio on or off. Off flushes the audio renderer (nothing more is decoded); on enqueues the kept audio
    /// the clock hasn't reached yet, so it plays from (about) now on without a gap.
    func setPlaysAudio(_ plays: Bool) {
        guard plays != playsAudio else { return }
        playsAudio = plays
        guard plays else {
            flushAudioRenderer()
            return
        }
        let now: CMTime? = clockStarted ? synchronizer.currentTime() : nil
        for sample in recentAudio.samples(startingAtOrAfter: now) { submitAudio(sample) }
    }

    private func submitAudio(_ sample: CMSampleBuffer) {
        submittedAudioSamples += 1
        #if os(tvOS)
        nonisolated(unsafe) let handoff = sample
        switch audioReceiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: handoff)) {
        case .cancelledDueToError(let error): audioError = error
        case .enqueuedWithSuggestedFlush: audioReceiver.flush()
        default: break
        }
        #else
        if audioRenderer.status == .failed { audioRenderer.flush() }
        audioRenderer.enqueue(sample)
        #endif
    }

    /// How far the queued video runs ahead of what's on screen, in seconds.
    var videoSecondsAhead: Double {
        guard let last = lastVideoTime else { return 0 }
        guard clockStarted else { return CMTimeSubtract(last, firstVideoTime ?? last).seconds }
        return CMTimeSubtract(last, synchronizer.currentTime()).seconds
    }

    /// How far the queued audio runs ahead of the clock, in seconds.
    var audioSecondsAhead: Double {
        guard let last = lastAudioEnd else { return 0 }
        guard clockStarted else { return CMTimeSubtract(last, firstAudioTime ?? last).seconds }
        return CMTimeSubtract(last, synchronizer.currentTime()).seconds
    }

    /// Set when the audio renderer reported an error (it is flushed and keeps going).
    var audioFailure: (any Error)? {
        #if os(tvOS)
        audioError
        #else
        audioRenderer.error
        #endif
    }

    /// Starts the timeline once there is a picture (and audio, if the stream has it), a little behind the earliest.
    /// At the end of a finite stream, whatever is queued is enough.
    private func startClockIfReady() {
        guard !clockStarted else { return }
        var start: CMTime
        if let video = firstVideoTime, video.isValid {
            start = video
        } else if endOfStream, let audio = firstAudioTime {
            start = audio
        } else {
            return
        }
        if hasAudioTrack {
            if let audio = firstAudioTime, let audioEnd = lastAudioEnd {
                guard endOfStream || CMTimeSubtract(audioEnd, audio).seconds >= Self.startAudioBuffer else { return }
                start = CMTimeMinimum(start, audio)
            } else if !endOfStream {
                return
            }
        }
        clockStarted = true
        clockStartedAt = .now()
        // Paused (a seek while paused), the clock waits at the first picture, so it is on screen.
        clockStartTime = isPaused ? (firstVideoTime ?? start) : CMTimeSubtract(start, Self.startCushion)
        synchronizer.setRate(isPaused ? 0 : 1, time: clockStartTime)
    }

    /// Audio this short of the clock means the clock is about to outrun the stream.
    static let lowWaterAudio = 0.3

    /// About once a second while playing. The broadcaster's clock and ours differ by tens of ppm, so over hours
    /// live playback can slowly use up its audio cushion. Trimming the playback rate to follow the broadcaster
    /// stalled the synchronizer on iOS at every change (a hiccup every second or two), so instead, when audio runs
    /// this low the clock stops once until `startAudioBuffer` is queued again: one short freeze, perhaps once in a
    /// few hours, rather than audio running dry. A network stall is handled the same way. Returns true when it
    /// started rebuffering.
    @discardableResult
    func guardLiveBuffer() -> Bool {
        // Right after a start the clock may still report the time before it, which looks like no audio at all.
        let settled = DispatchTime.now().uptimeNanoseconds - clockStartedAt.uptimeNanoseconds
            >= Self.clockSettleNanoseconds
        guard clockStarted, settled, !isPaused, !isRebuffering, !endOfStream, hasAudioTrack, lastAudioEnd != nil,
              audioSecondsAhead < Self.lowWaterAudio else { return false }
        isRebuffering = true
        synchronizer.rate = 0
        return true
    }

    private func resumeAfterRebufferIfReady() {
        guard isRebuffering, audioSecondsAhead >= Self.startAudioBuffer else { return }
        isRebuffering = false
        if !isPaused { synchronizer.rate = 1 }
    }

    /// Everything a finite stream holds is queued: start the clock if it hasn't, and stop rebuffering.
    func markEndOfStream() {
        endOfStream = true
        if isRebuffering {
            isRebuffering = false
            if !isPaused { synchronizer.rate = 1 }
        }
        startClockIfReady()
    }

    /// The clock has passed the last queued picture and audio (or nothing was ever queued).
    var hasPlayedOut: Bool {
        guard clockStarted else { return lastVideoTime == nil && lastAudioEnd == nil }
        let now = synchronizer.currentTime()
        if let last = lastVideoTime, CMTimeCompare(now, last) < 0 { return false }
        if hasAudioTrack, let end = lastAudioEnd, CMTimeCompare(now, end) < 0 { return false }
        return true
    }

    /// Drops queued audio (switching tracks); the clock keeps running on video.
    func flushAudio() {
        flushAudioRenderer()
        recentAudio.removeAll()
        lastAudioEnd = nil
    }

    /// Restarts presentation after a discontinuity (a new timeline in the stream).
    func flushForDiscontinuity() {
        // Nothing is queued any more, so the clock stops until the new timeline starts it.
        synchronizer.rate = 0
        flushVideoRenderer()
        flushAudioRenderer()
        clockStarted = false
        isRebuffering = false
        endOfStream = false
        firstVideoTime = nil
        lastVideoTime = nil
        firstAudioTime = nil
        lastAudioEnd = nil
        recentAudio.removeAll()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        isRebuffering = false
        guard clockStarted else { return }
        synchronizer.rate = paused ? 0 : 1
    }

    /// Stops the clock and drops what is queued; `keepingVideo` leaves the picture on screen.
    func stop(keepingVideo: Bool = false) {
        synchronizer.rate = 0
        if !keepingVideo { flushVideoRenderer() }
        flushAudioRenderer()
    }

    private func flushVideoRenderer() {
        #if os(tvOS)
        videoReceiver.flush()
        videoError = nil
        #else
        videoRenderer.flush()
        #endif
    }

    private func flushAudioRenderer() {
        #if os(tvOS)
        audioReceiver.flush()
        audioError = nil
        #else
        audioRenderer.flush()
        #endif
    }
}
