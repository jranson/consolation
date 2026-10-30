//
//  VideoFill.swift
//  PlaybackKit
//
//  How the video fills its view when their shapes differ: fit (the whole picture, with bars) or fill (no bars, the
//  edges cropped), e.g. 16:9 video on a 1.42:1 display or 4:3 video on a 16:9 one.
//

import AVFoundation

public enum VideoFill: Sendable {
    /// The whole picture, letterboxed or pillarboxed.
    case fit
    /// The view filled, cropping what overhangs.
    case fill

    var gravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        }
    }
}

public extension PlaybackEngine {
    /// Sets how the engine's display layer fits the video to its view. Changes only the layer, never playback.
    func setVideoFill(_ fill: VideoFill) {
        if let layer = displayLayer as? AVSampleBufferDisplayLayer {
            layer.videoGravity = fill.gravity
        } else if let layer = displayLayer as? AVPlayerLayer {
            layer.videoGravity = fill.gravity
        }
    }
}
