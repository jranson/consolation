#if !os(tvOS)
import Foundation
import SwiftUI

extension ContentView {
    var maxFPSWarningPollThreshold: Int { 3 }

    var shouldShowStatsOverlay: Bool {
        showVideoStats && capture.state == .running
    }

    var resolvedStatsLocation: VideoStatsOverlayLocation {
        VideoStatsOverlayLocation(rawValue: videoStatsLocationRawValue) ?? .bottomLeft
    }

    var isStatsOverlayFullscreenActive: Bool {
        #if os(macOS)
        isFullscreenActive
        #else
        false
        #endif
    }

    /// The capture viewer's items for the shared Video Stats overlay, or none while capture isn't running.
    static func videoStatsItems(_ capture: CaptureSessionManager) -> [String] {
        guard capture.state == .running, let stats = capture.videoFrameRateStats else { return [] }
        let resolution = capture.videoSize.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" } ?? "—"
        let measured = Int(stats.presentationFPS.rounded())
        let configuredFPS = capture.configuredVideoFrameRate(fallbackMeasured: measured)
        let stutter = String(format: "%.3f", stats.maxPresentationGap)
        return ["Res: \(resolution) @ \(configuredFPS)", "FPS: \(stats.frames)", "Drops: \(stats.droppedFrames)",
                "Stutter: \(stutter)"]
    }

    var statsOverlayInsets: (VideoStatsOverlayLocation) -> EdgeInsets {
        let isFullscreen = isStatsOverlayFullscreenActive
        return { $0.edgePadding(isFullscreen: isFullscreen) }
    }

    var shouldShowMaxFPSWarning: Bool {
        capture.state == .running &&
            !disableLowFPSWarningOverlay &&
            capture.lowFrameRateSampleStreak >= maxFPSWarningPollThreshold
    }

    var maxFPSWarningLabel: String? {
        guard let stats = capture.videoFrameRateStats else { return nil }
        return "FPS: \(stats.frames)"
    }

    var maxFPSWarningLocation: VideoStatsOverlayLocation {
        if shouldShowStatsOverlay && resolvedStatsLocation == .bottomLeft {
            return .bottomRight
        }
        return .bottomLeft
    }

    @ViewBuilder
    func maxFPSWarningOverlay(_ label: String) -> some View {
        Button {
            isShowingMaxFPSInfo = true
        } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Image(systemName: "info.circle")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.vertical, 0)
        .background(Color.red.opacity(0.92), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.35), lineWidth: 1)
        }
        .padding(maxFPSWarningLocation.edgePadding(isFullscreen: isStatsOverlayFullscreenActive))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: maxFPSWarningLocation.alignment)
    }
}

struct MaxFPSWarningInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Low Frame Rate Detected")
                .font(.title2.weight(.semibold))

            Text(
                "The capture device is not delivering the full frame rate requested. This may be due to " +
                "device incompatibilities with iPad or bandwidth limitations."
            )

            Text(
                "If the capture device is connected through a USB hub, try a direct connection for better performance."
            )

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .font(.system(size: 15))
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 340, maxWidth: 520, maxHeight: 360)
    }
}
#endif
