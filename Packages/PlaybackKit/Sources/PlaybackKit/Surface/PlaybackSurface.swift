//
//  PlaybackSurface.swift
//  PlaybackKit
//
//  A SwiftUI view that shows an engine's display view (whose backing layer is the engine's display layer). The view
//  belongs to the engine, so moving the surface between the full-screen player and the mini player (or resizing the
//  window) never restarts playback. Whichever surface is on screen adopts the view and sizes it to its bounds.
//
//  System Picture in Picture borrows the display view while PiP is active and hands it back when PiP ends. A surface
//  only adopts a view that is free or held by another surface, never one that PiP holds; taking it back froze or
//  cropped the PiP picture and could crash AVKit's layout.
//
//  Rounded corners (multi-view tiles) round the host's own layer, which already clips the hosted view: no SwiftUI
//  clip shape, mask or shadow on live video, which would cost an offscreen pass every frame.
//

import SwiftUI

#if os(macOS)
import AppKit

/// Hosts an engine's display view and keeps it sized to this view.
public final class DisplayHostView: NSView {
    /// Called once per hosted view, the first time it is on screen with a non-empty size. System Picture in
    /// Picture must be set up only then: AVKit takes the layer's size when its controller is created.
    public var onReady: ((NSView) -> Void)?
    private weak var reportedView: NSView?

    /// Continuous corner radius of the shown video (0: square).
    public var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            layer?.cornerRadius = cornerRadius
            layer?.cornerCurve = .continuous
        }
    }

    public var hostedView: NSView? {
        didSet {
            if oldValue !== hostedView, oldValue?.superview === self { oldValue?.removeFromSuperview() }
            adoptHostedView()
        }
    }

    override public init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("DisplayHostView is created in code only")
    }

    /// Moves a free display view (or one shown by another surface) into this view and sizes it.
    public func adoptHostedView() {
        // Only an on-screen surface adopts the view, so a surface being removed can't take it back.
        guard let hostedView, window != nil else { return }
        if let parent = hostedView.superview, parent !== self, !(parent is DisplayHostView) { return }
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }
        hostedView.autoresizingMask = [.width, .height]
        hostedView.frame = bounds
        reportReadyIfNeeded(hostedView)
    }

    private func reportReadyIfNeeded(_ hostedView: NSView) {
        guard reportedView !== hostedView, !bounds.isEmpty, let onReady else { return }
        reportedView = hostedView
        // Not during layout: the callback may change SwiftUI state.
        Task { @MainActor in onReady(hostedView) }
    }

    override public func layout() {
        super.layout()
        adoptHostedView()
    }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        adoptHostedView()
    }
}

/// Shows an engine's display view, filling the available space.
public struct PlaybackSurface: NSViewRepresentable {
    private let view: NSView
    private let cornerRadius: CGFloat
    private let onReady: ((NSView) -> Void)?

    /// `onReady` is called once the view is on screen and sized (see `DisplayHostView.onReady`). `cornerRadius`
    /// rounds the video's layer (continuous corners), for multi-view tiles.
    public init(view: NSView, cornerRadius: CGFloat = 0, onReady: ((NSView) -> Void)? = nil) {
        self.view = view
        self.cornerRadius = cornerRadius
        self.onReady = onReady
    }

    public func makeNSView(context: Context) -> DisplayHostView {
        let host = DisplayHostView(frame: .zero)
        host.onReady = onReady
        host.cornerRadius = cornerRadius
        host.hostedView = view
        return host
    }

    public static func dismantleNSView(_ nsView: DisplayHostView, coordinator: ()) {
        nsView.hostedView = nil
    }

    public func updateNSView(_ nsView: DisplayHostView, context: Context) {
        nsView.onReady = onReady
        nsView.cornerRadius = cornerRadius
        if nsView.hostedView !== view {
            nsView.hostedView = view
        } else {
            nsView.adoptHostedView()
        }
    }
}
#else
import UIKit

/// Hosts an engine's display view and keeps it sized to this view.
public final class DisplayHostView: UIView {
    /// Called once per hosted view, the first time it is on screen with a non-empty size. System Picture in
    /// Picture must be set up only then: AVKit takes the layer's size when its controller is created.
    public var onReady: ((UIView) -> Void)?
    private weak var reportedView: UIView?

    /// Continuous corner radius of the shown video (0: square).
    public var cornerRadius: CGFloat = 0 {
        didSet {
            guard cornerRadius != oldValue else { return }
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
        }
    }

    public var hostedView: UIView? {
        didSet {
            if oldValue !== hostedView, oldValue?.superview === self { oldValue?.removeFromSuperview() }
            adoptHostedView()
        }
    }

    override public init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("DisplayHostView is created in code only")
    }

    /// Moves a free display view (or one shown by another surface) into this view and sizes it.
    public func adoptHostedView() {
        // Only an on-screen surface adopts the view, so a surface being removed can't take it back.
        guard let hostedView, window != nil else { return }
        if let parent = hostedView.superview, parent !== self, !(parent is DisplayHostView) { return }
        if hostedView.superview !== self {
            hostedView.removeFromSuperview()
            addSubview(hostedView)
        }
        hostedView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostedView.frame = bounds
        reportReadyIfNeeded(hostedView)
    }

    private func reportReadyIfNeeded(_ hostedView: UIView) {
        guard reportedView !== hostedView, !bounds.isEmpty, let onReady else { return }
        reportedView = hostedView
        // Not during layout: the callback may change SwiftUI state.
        Task { @MainActor in onReady(hostedView) }
    }

    override public func layoutSubviews() {
        super.layoutSubviews()
        adoptHostedView()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        adoptHostedView()
    }
}

/// Shows an engine's display view, filling the available space.
public struct PlaybackSurface: UIViewRepresentable {
    private let view: UIView
    private let cornerRadius: CGFloat
    private let onReady: ((UIView) -> Void)?

    /// `onReady` is called once the view is on screen and sized (see `DisplayHostView.onReady`). `cornerRadius`
    /// rounds the video's layer (continuous corners), for multi-view tiles.
    public init(view: UIView, cornerRadius: CGFloat = 0, onReady: ((UIView) -> Void)? = nil) {
        self.view = view
        self.cornerRadius = cornerRadius
        self.onReady = onReady
    }

    public func makeUIView(context: Context) -> DisplayHostView {
        let host = DisplayHostView(frame: .zero)
        host.onReady = onReady
        host.cornerRadius = cornerRadius
        host.hostedView = view
        return host
    }

    public static func dismantleUIView(_ uiView: DisplayHostView, coordinator: ()) {
        uiView.hostedView = nil
    }

    public func updateUIView(_ uiView: DisplayHostView, context: Context) {
        uiView.onReady = onReady
        uiView.cornerRadius = cornerRadius
        if uiView.hostedView !== view {
            uiView.hostedView = view
        } else {
            uiView.adoptHostedView()
        }
    }
}
#endif
