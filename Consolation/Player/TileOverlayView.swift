//
//  TileOverlayView.swift
//  Consolation
//
//  What a multi-view tile shows over its video: its channel or title, a spinner while it starts, and "Tuner
//  Unavailable" or the failure with Retry inside its cell. A single stream shows none of it; the player's own overlays
//  cover that.
//

import PlaybackKit
import PlayerKit
import SwiftUI

struct TileOverlayView: View {
    @Environment(PlayerSession.self) private var session
    let tile: PlayerTile<PlayingItem>
    let context: TileOverlayContext

    /// The item's title, noting a stream whose audio can't play (ATSC 3.0's AC-4).
    private var title: String {
        guard let codec = tile.engine.streamInfo.unsupportedAudioCodec else { return tile.item.title }
        return "\(tile.item.title) · no audio (\(codec))"
    }

    private var isShown: Bool {
        !context.mode.isSingle && context.presentation == .full && context.placement.isVisible
    }

    var body: some View {
        if isShown {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                status
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                label
                    .padding(10)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("multiview.tileOverlay")
        }
    }

    private var label: some View {
        // PlayerKit marks the audible tile itself.
        Text(title).lineLimit(1)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.black.opacity(0.55), in: .capsule)
        .allowsHitTesting(false)
    }

    @ViewBuilder private var status: some View {
        switch tile.status {
        case .starting, .buffering:
            ProgressView().tint(.white).allowsHitTesting(false)
        case .unavailable:
            problem("Tuner Unavailable", symbol: "antenna.radiowaves.left.and.right.slash")
        case .failed(let error):
            problem(error.title, symbol: "exclamationmark.triangle")
        case .ended:
            // A file that played to its end, or a live stream that stopped for good.
            if tile.engine.streamInfo.isLive {
                problem("Signal Lost", symbol: "exclamationmark.triangle")
            } else {
                problem("Ended", symbol: "stop.circle")
            }
        case .playing, .paused:
            EmptyView()
        }
    }

    private func problem(_ title: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.callout.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
            #if os(tvOS)
            // A button here would compete with the tiles for focus; bring the tile forward and use the controls'
            // Retry instead.
            Text("Select, then Retry").font(.caption).foregroundStyle(.secondary)
            #else
            Button("Retry") {
                let id = tile.id
                Task { try? await session.multiView.retry(id) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            #endif
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
        #if os(tvOS)
        .allowsHitTesting(false)
        #endif
    }
}
