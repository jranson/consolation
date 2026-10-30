//
//  PlayerStatsOverlay.swift
//  Consolation
//
//  Technical stats for the playing stream (I key). Everything here is computed on this device; nothing is sent.
//

import PlaybackKit
import SwiftUI

struct PlayerStatsOverlay: View {
    let engine: any PlaybackEngine
    let diagnostics: PlaybackDiagnostics?
    @Environment(PlayerSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(lines, id: \.self) { line in
                Text(line)
            }
        }
        .font(.caption.monospaced())
        .foregroundStyle(.white)
        .padding(10)
        .background(.black.opacity(0.65), in: .rect(cornerRadius: 8))
        .allowsHitTesting(false)
    }

    private var lines: [String] {
        let info = engine.streamInfo
        var result: [String] = []
        let size = info.width.map { "\($0)x\(info.height ?? 0)" } ?? "—"
        let rate = info.frameRate.map { String(format: "%.3f fps", $0) } ?? "—"
        let scan = info.isInterlaced == true ? "interlaced → deinterlaced to field rate" : "progressive"
        result.append("Video: \(info.videoCodec ?? "—") \(size) \(rate), \(scan)")
        let channels = info.audioChannels.map { "\($0) ch" } ?? ""
        result.append("Audio: \(info.audioCodec ?? "—") \(channels) \(info.audioLanguage ?? "")")
        if session.currentChannel != nil {
            result.append("Source: tuner")
        }
        if let diagnostics {
            result.append(String(format: "Bitrate: %.1f Mbps", diagnostics.bytesPerSecond * 8 / 1_000_000))
            result.append(String(format: "Buffered: audio %.2f s, video %.2f s",
                                 diagnostics.audioSecondsBuffered, diagnostics.videoSecondsBuffered))
            result.append("Frames: \(diagnostics.framesShown) shown, \(diagnostics.framesDropped) dropped")
            result.append(String(format: "Behind live: %.1f s, reconnects: %d",
                                 diagnostics.secondsBehindLive, diagnostics.reconnects))
        }
        return result
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
