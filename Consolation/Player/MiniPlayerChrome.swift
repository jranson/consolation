//
//  MiniPlayerChrome.swift
//  Consolation
//
//  Controls drawn over the mini player (the video itself is PlayerSurfaceContainer). It keeps playing until dismissed:
//  the X (shown on pointer movement or a tap, auto-hidden) on Mac/iPad/iPhone, or Play/Pause on Apple TV.
//

import SwiftUI

struct MiniPlayerChrome: View {
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell

    @State private var showsClose = false
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .contentShape(Rectangle())
                #if os(macOS)
                .onTapGesture { openFullScreen() }
                #elseif os(iOS)
                // First tap shows the X; a tap while it shows opens the full player.
                .onTapGesture { showsClose ? openFullScreen() : revealClose() }
                #endif
            #if !os(tvOS)
            if showsClose {
                Button {
                    session.stop()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("Stop playing")
                .accessibilityLabel("Stop playing")
                .transition(.opacity)
            }
            #endif
        }
        .animation(.smooth(duration: 0.2), value: showsClose)
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { revealClose() }
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mini player: \(session.item?.title ?? "")")
        .accessibilityIdentifier("player.mini")
    }

    private func openFullScreen() {
        shell.selection = .nowPlaying
        session.showControlsBriefly()
    }

    private func revealClose() {
        showsClose = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: PlayerSession.chromeAutoHide)
            guard !Task.isCancelled else { return }
            showsClose = false
        }
    }
}
