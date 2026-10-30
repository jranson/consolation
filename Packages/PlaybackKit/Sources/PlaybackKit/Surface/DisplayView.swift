//
//  DisplayView.swift
//  PlaybackKit
//
//  The view each engine shows its video in. The engine's display layer is this view's own backing layer, never a
//  loose sublayer: system Picture in Picture for sample-buffer content takes the layer's view into its window and
//  sizes it there, so a layer without a view of its own showed a cropped, unscaled picture in the PiP window.
//  Hosts (`PlaybackSurface`) add the view as a subview and size it; they never touch the layer.
//

import AVFoundation
import QuartzCore

#if os(macOS)
import AppKit

public typealias PlatformView = NSView

/// A layer-hosting view: `layer` is the display layer, and AppKit keeps it the size of the view.
final class DisplayView: NSView {
    init(hosting displayLayer: CALayer) {
        super.init(frame: .zero)
        // Layer-hosting: set the layer before turning on wantsLayer.
        layer = displayLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("DisplayView is created in code only")
    }
}

extension DisplayView {
    static func sampleBuffer() -> (view: PlatformView, layer: AVSampleBufferDisplayLayer) {
        let layer = AVSampleBufferDisplayLayer()
        return (DisplayView(hosting: layer), layer)
    }

    static func player(_ player: AVPlayer) -> (view: PlatformView, layer: AVPlayerLayer) {
        let layer = AVPlayerLayer(player: player)
        return (DisplayView(hosting: layer), layer)
    }
}
#else
import UIKit

public typealias PlatformView = UIView

/// A view backed by an `AVSampleBufferDisplayLayer`.
final class SampleBufferDisplayView: UIView {
    override static var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
}

/// A view backed by an `AVPlayerLayer`.
final class PlayerDisplayView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
}

enum DisplayView {
    static func sampleBuffer() -> (view: PlatformView, layer: AVSampleBufferDisplayLayer) {
        let view = SampleBufferDisplayView()
        // swiftlint:disable:next force_cast
        return (view, view.layer as! AVSampleBufferDisplayLayer)
    }

    static func player(_ player: AVPlayer) -> (view: PlatformView, layer: AVPlayerLayer) {
        let view = PlayerDisplayView()
        // swiftlint:disable:next force_cast
        let layer = view.layer as! AVPlayerLayer
        layer.player = player
        return (view, layer)
    }
}
#endif
