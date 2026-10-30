//
//  AVPlayerEngineFrameTap.swift
//  PlaybackKit
//
//  Frame taps for AVPlayer content: an AVPlayerItemVideoOutput is attached only while something reads frames, and
//  polled on a short timer (the hub applies each tap's own rate). Interlaced content arrives woven, which is fine:
//  taps read one field.
//

import AVFoundation
import CoreVideo

extension AVPlayerEngine: FrameTapping {
    static let tapPollInterval: Duration = .milliseconds(100)

    public func frameTap(_ request: FrameTapRequest) -> AsyncStream<FrameTapSample> {
        let stream = frameTapHub.add(request)
        startTapPolling()
        return stream
    }

    public func latestFrame() async -> CVPixelBuffer? {
        let keepsOutput = tapTask != nil
        defer { if !keepsOutput { detachVideoOutput() } }
        // A newly attached output needs a frame or two before it has anything.
        for _ in 0..<10 {
            if let (buffer, _) = currentPixelBuffer(requireNew: false) { return buffer }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    private func startTapPolling() {
        guard tapTask == nil else { return }
        tapTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.frameTapHub.isActive {
                // The regions are small (a few kilobytes at 2 Hz), so they are copied right here.
                if let (buffer, time) = self.currentPixelBuffer(requireNew: true) {
                    self.frameTapHub.offer(buffer, at: time)
                }
                try? await Task.sleep(for: Self.tapPollInterval)
            }
            self?.detachVideoOutput()
            self?.tapTask = nil
        }
    }

    /// The picture for the current host time, attaching the output to the current item first if needed.
    private func currentPixelBuffer(requireNew: Bool) -> (CVPixelBuffer, CMTime)? {
        guard let item = player.currentItem else { return nil }
        let output: AVPlayerItemVideoOutput
        if let videoOutput, item.outputs.contains(videoOutput) {
            output = videoOutput
        } else {
            detachVideoOutput()
            output = AVPlayerItemVideoOutput(outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ])
            item.add(output)
            videoOutput = output
        }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if requireNew, !output.hasNewPixelBuffer(forItemTime: time) { return nil }
        if #available(macOS 27, iOS 27, tvOS 27, *) {
            let (readOnly, displayTime) = output.pixelBufferAndDisplayTime(forItemTime: time)
            // Taps only read the buffer, so leaving the read-only wrapper is safe.
            var unwrapped: CVPixelBuffer?
            readOnly?.withUnsafeBuffer { unwrapped = $0 }
            guard let buffer = unwrapped else { return nil }
            return (buffer, displayTime.isValid ? displayTime : time)
        } else {
            var displayTime = CMTime.invalid
            guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) else {
                return nil
            }
            return (buffer, displayTime.isValid ? displayTime : time)
        }
    }

    func detachVideoOutput() {
        if let videoOutput { player.currentItem?.remove(videoOutput) }
        videoOutput = nil
    }
}
