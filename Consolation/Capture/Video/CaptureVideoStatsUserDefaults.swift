//
//  CaptureVideoStatsUserDefaults.swift
//  Consolation
//
//  The capture viewer's edge padding for the shared Video Stats overlay (Components/VideoStatsOverlay.swift, which
//  also holds the overlay's settings).
//

#if !os(tvOS)
import SwiftUI

extension VideoStatsOverlayLocation {
    func edgePadding(isFullscreen: Bool) -> EdgeInsets {
        let topPadding: CGFloat = isFullscreen ? 2 : -30

        return switch self {
        case .topLeft:
            EdgeInsets(top: topPadding, leading: 2, bottom: 2, trailing: 0)
        case .topRight, .topCenter:
            EdgeInsets(top: topPadding, leading: 0, bottom: 2, trailing: 2)
        case .bottomLeft, .bottomRight, .bottomCenter:
            EdgeInsets(top: 0, leading: 2, bottom: 2, trailing: 2)
        }
    }
}
#endif
