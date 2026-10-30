//
//  FrameTapHub.swift
//  PlaybackKit
//
//  Fans pictures out to active frame taps at their own rates. `offer` runs on the engine's pipeline queue and
//  returns at once when nothing is tapping; requests come and go from any thread.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

nonisolated final class FrameTapHub: @unchecked Sendable {
    // @unchecked: `taps` is only touched under `lock`.
    private struct Tap {
        let request: FrameTapRequest
        let continuation: AsyncStream<FrameTapSample>.Continuation
        var nextTime: CMTime = .invalid
    }

    private let lock = NSLock()
    private var taps: [UUID: Tap] = [:]

    var isActive: Bool { lock.withLock { !taps.isEmpty } }

    func add(_ request: FrameTapRequest) -> AsyncStream<FrameTapSample> {
        let (stream, continuation) = AsyncStream.makeStream(of: FrameTapSample.self,
                                                            bufferingPolicy: .bufferingNewest(4))
        let id = UUID()
        continuation.onTermination = { [weak self] _ in
            self?.lock.withLock { _ = self?.taps.removeValue(forKey: id) }
        }
        lock.withLock { taps[id] = Tap(request: request, continuation: continuation) }
        return stream
    }

    /// Offers one picture (a video sample buffer about to be shown).
    func offer(_ sample: CMSampleBuffer) {
        guard isActive, let image = CMSampleBufferGetImageBuffer(sample) else { return }
        offer(image, at: CMSampleBufferGetOutputPresentationTimeStamp(sample))
    }

    func offer(_ image: CVPixelBuffer, at time: CMTime) {
        let due: [(UUID, FrameTapRequest)] = lock.withLock {
            var due: [(UUID, FrameTapRequest)] = []
            for (id, tap) in taps where !tap.nextTime.isValid || time >= tap.nextTime
                || time < tap.nextTime - CMTime(seconds: 10, preferredTimescale: 90_000) {
                // (The last test re-arms a tap after the stream's clock jumps backwards.)
                let interval = 1 / max(0.1, tap.request.samplesPerSecond)
                taps[id]?.nextTime = time + CMTime(seconds: interval, preferredTimescale: 90_000)
                due.append((id, tap.request))
            }
            return due
        }
        guard !due.isEmpty else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(image), height: CVPixelBufferGetHeight(image))
        for (id, request) in due {
            let patches = LumaCopier.copyFieldRows(of: image, regions: request.regions, margin: request.margin)
            let sample = FrameTapSample(presentationTime: time, frameSize: size, patches: patches)
            _ = lock.withLock { taps[id]?.continuation }?.yield(sample)
        }
    }

    /// Ends every tap (the engine stopped).
    func finishAll() {
        let continuations = lock.withLock {
            defer { taps.removeAll() }
            return taps.values.map(\.continuation)
        }
        continuations.forEach { $0.finish() }
    }
}
