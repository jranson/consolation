//
//  PlayerStatsOverlay.swift
//  Consolation
//
//  Technical stats for the playing stream (I key). Everything here is computed on this device; nothing is sent.
//

import PlaybackKit
import SwiftUI

/// What the player feeds the shared Video Stats overlay (`VideoStatsOverlay`).
enum PlayerStats {
    /// The items for what the session plays now, or none when nothing plays. Reads observable engine state, so call
    /// it only from the overlay's `items` closure.
    static func items(for session: PlayerSession) -> [String] {
        guard let engine = session.engine, session.isActive else { return [] }
        var result = streamItems(info: engine.streamInfo, delivery: delivery(of: engine, item: session.item))
        if let live = engine as? any LivePlaybackControlling {
            result += diagnosticItems(live.diagnostics, isLive: engine.streamInfo.isLive)
        } else if let player = engine as? AVPlayerEngine {
            result.append("Stalls: \(player.stallCount)")
        }
        return result
    }

    /// Video, audio, container and protocol, each kept short: the overlay shows every item on one line.
    nonisolated static func streamItems(info: PlaybackStreamInfo, delivery: Delivery?) -> [String] {
        let size = info.width.map { "\($0)x\(info.height ?? 0)" } ?? "—"
        // "29.97i" or "59.94p", as broadcast formats are written.
        let scan = info.isInterlaced == true ? "i" : "p"
        let rate = info.frameRate.map { " @ " + String(format: "%.2f", $0) + scan } ?? ""
        var result = ["Video: \(info.videoCodec ?? "—") \(size)\(rate)"]
        if let codec = info.unsupportedAudioCodec {
            result.append("Audio: \(codec) (unsupported)")
        } else {
            let parts = [info.audioCodec ?? "—", info.audioChannels.map(channelLayout), info.audioLanguage]
            result.append("Audio: \(parts.compactMap { $0 }.joined(separator: " "))")
        }
        // HLS that AVPlayer opened directly doesn't say which of its two segment formats it carries.
        if let container = info.container ?? (delivery?.isHLS == true ? "TS or fMP4" : nil) {
            result.append("Container: \(container)")
        }
        if let delivery { result.append("Protocol: \(delivery.text)") }
        return result
    }

    /// "Mono", "Stereo", "5.1", "7.1", or the channel count.
    nonisolated static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) ch"
        }
    }

    nonisolated static func diagnosticItems(_ diagnostics: PlaybackDiagnostics, isLive: Bool) -> [String] {
        var result = [String(format: "Bitrate: %.1f Mbps", diagnostics.bytesPerSecond * 8 / 1_000_000)]
        result.append(String(format: "Buffer: A %.1fs V %.1fs",
                             diagnostics.audioSecondsBuffered, diagnostics.videoSecondsBuffered))
        result.append("Drops: \(diagnostics.framesDropped)")
        if isLive { result.append(String(format: "Behind: %.1fs", diagnostics.secondsBehindLive)) }
        if diagnostics.reconnects > 0 { result.append("Reconnects: \(diagnostics.reconnects)") }
        return result
    }

    /// Keeps the panel clear of the top banner area and, while they are up, of the controls at the bottom.
    static func insets(for location: VideoStatsOverlayLocation, session: PlayerSession) -> EdgeInsets {
        #if os(tvOS)
        // Inside the TV's overscan margins.
        let edge: CGFloat = 60
        let side: CGFloat = 80
        let controlsHeight: CGFloat = 300
        #else
        let edge: CGFloat = 40
        let side: CGFloat = 16
        let controlsHeight: CGFloat = 150
        #endif
        if location.isTop { return EdgeInsets(top: edge, leading: side, bottom: 0, trailing: side) }
        let bottom = session.controlsVisible && session.isActive ? controlsHeight : min(edge, 28)
        return EdgeInsets(top: 0, leading: side, bottom: bottom, trailing: side)
    }
}

/// "LIVE", or how far behind live a time-shifted stream is.
struct LiveIndicator: View {
    let secondsBehind: Double

    var body: some View {
        if secondsBehind < 2 {
            Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.red)
        } else {
            let total = Int(secondsBehind)
            Text(String(format: "−%d:%02d", total / 60, total % 60))
                .monospacedDigit()
        }
    }
}
