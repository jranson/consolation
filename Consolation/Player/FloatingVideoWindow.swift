//
//  FloatingVideoWindow.swift
//  Consolation
//
//  macOS: the app's own Picture in Picture window for live TV. A borderless-looking panel that floats above other
//  apps on every Space, keeps the video's aspect ratio when resized, remembers where it was, and shows play/pause
//  and "back to the app" on hover. Closing it brings the video back into the main window and keeps it playing. The
//  engine's display view moves between the two surfaces, so playback never restarts.
//

#if os(macOS)
import AppKit
import PlaybackKit
import SwiftUI

extension View {
    /// Shows the floating video window while `session.isFloating` is on and the video belongs to `window`.
    func floatingVideoWindow(session: PlayerSession, window: UUID) -> some View {
        modifier(FloatingVideoWindowModifier(session: session, window: window))
    }
}

private struct FloatingVideoWindowModifier: ViewModifier {
    let session: PlayerSession
    let window: UUID
    @State private var controller = FloatingVideoWindowController()

    func body(content: Content) -> some View {
        content
            .onChange(of: session.isFloating && session.videoWindow == window, initial: true) { _, floating in
                if floating { controller.show(session: session) } else { controller.hide() }
            }
            .onDisappear { controller.hide() }
    }
}

@MainActor
private final class FloatingVideoWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 480, height: 270)
    static let minimumWidth: CGFloat = 240
    static let screenInset: CGFloat = 20

    private var panel: NSPanel?
    private weak var session: PlayerSession?

    func show(session: PlayerSession) {
        self.session = session
        let panel = panel ?? makePanel(session: session)
        self.panel = panel
        panel.contentAspectRatio = Self.aspectRatio(of: session)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        panel.delegate = nil
        panel.orderOut(nil)
        // Releasing the content hands the display view back to the main window's surface.
        panel.contentView = nil
    }

    func windowWillClose(_ notification: Notification) {
        // The close button means "back into the app", not stop; `hide()` then releases the content.
        session?.isFloating = false
    }

    private func makePanel(session: PlayerSession) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.title = String(localized: "\(AppIdentifier.name) Picture in Picture")
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .black
        panel.minSize = NSSize(width: Self.minimumWidth, height: Self.minimumWidth * 9 / 16)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FloatingVideoContent().environment(session))
        if !panel.setFrameUsingName(Self.frameName) {
            panel.setFrame(Self.defaultFrame(), display: false)
        }
        panel.setFrameAutosaveName(Self.frameName)
        return panel
    }

    private static let frameName = AppIdentifier.scoped("floatingVideo")

    /// The lower-right corner of the main screen.
    private static func defaultFrame() -> NSRect {
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        return NSRect(x: visible.maxX - defaultSize.width - screenInset, y: visible.minY + screenInset,
                      width: defaultSize.width, height: defaultSize.height)
    }

    private static func aspectRatio(of session: PlayerSession) -> NSSize {
        guard let info = session.engine?.streamInfo, let width = info.width, let height = info.height,
              width > 0, height > 0 else { return NSSize(width: 16, height: 9) }
        // MPEG-2 SD is stored 720 or 704 wide for a 4:3 or 16:9 picture; HD pixels are square.
        return width >= 1_280 ? NSSize(width: width, height: height) : NSSize(width: 16, height: 9)
    }
}

/// The video, with play/pause and "back to the app" on hover.
private struct FloatingVideoContent: View {
    @Environment(PlayerSession.self) private var session
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.black
            if let engine = session.engine {
                PlaybackSurface(view: engine.displayView)
            }
        }
        .overlay(alignment: .bottom) {
            if isHovering {
                HStack(spacing: 18) {
                    button(isPaused ? "play.fill" : "pause.fill", label: isPaused ? "Play" : "Pause") {
                        session.togglePause()
                    }
                    button("pip.exit", label: "Back to \(AppIdentifier.name)") {
                        session.isFloating = false
                        NSApp.activate()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.2), value: isHovering)
        .onHover { isHovering = $0 }
        .ignoresSafeArea()
    }

    private var isPaused: Bool {
        session.tunerReleased || session.engine?.state == .paused
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
#endif
