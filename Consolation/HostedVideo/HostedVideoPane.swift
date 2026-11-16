//
//  HostedVideoPane.swift
//  Consolation
//
//  Now Playing for a hosted video (Mac, iPad, iPhone): the service's embedded player with its own controls, under a
//  title bar with Done. Nothing is drawn over the embed (YouTube's terms forbid covering it), so our timeline,
//  multi-view, captions and stats don't apply. Another window's Now Playing says where the video plays.
//

#if !os(tvOS)
import SwiftUI
import YouTubePlayerKit

struct HostedVideoPane: View {
    @Environment(HostedVideoPlayer.self) private var hostedVideos
    @Environment(ShellModel.self) private var shell

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let video = hostedVideos.current {
                if hostedVideos.window == shell.id {
                    VStack(spacing: 0) {
                        titleBar(video)
                        HostedVideoEmbed(video: video)
                            .id(video.id)
                    }
                } else {
                    PlayerMessage(systemImage: "rectangle.on.rectangle", title: "Playing in Another Window")
                }
            }
        }
    }

    private func titleBar(_ video: HostedVideo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
            Text(video.title).font(.headline).lineLimit(1)
            Spacer(minLength: 8)
            Button("Done") {
                hostedVideos.stop()
                shell.selection = shell.lastBrowsePane
            }
            .buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// The embed for one play of one video. A new play (a new `id`) makes a new player.
private struct HostedVideoEmbed: View {
    @Environment(HostedVideoPlayer.self) private var hostedVideos
    let video: HostedVideo
    @State private var player: YouTubePlayer

    init(video: HostedVideo) {
        self.video = video
        _player = State(initialValue: YouTubeEmbedClient.player(for: video.link))
    }

    var body: some View {
        YouTubePlayerView(player) { state in
            switch state {
            case .idle:
                ProgressView().controlSize(.large).tint(.white)
            case .ready:
                Color.clear
                    .allowsHitTesting(false)
                    .onAppear { hostedVideos.didBecomeReady(video) }
            case .error(let error):
                PlayerMessage(systemImage: "exclamationmark.triangle", title: "Couldn't Play This Video",
                              detail: YouTubeEmbedClient.message(for: error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
