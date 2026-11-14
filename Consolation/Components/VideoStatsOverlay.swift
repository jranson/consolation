//
//  VideoStatsOverlay.swift
//  Consolation
//
//  The Video Stats overlay shared by the capture card viewer and the player, with its settings (shown or not, and
//  the corner). A host only supplies the items, which are shown on one line ("Res: … | FPS: … | Drops: …"): wide
//  rather than tall, so it covers little of the picture.
//
//  The overlay reads its own settings and calls `lines` inside its own body, so the once-a-second numbers
//  invalidate this view alone: a host must not read them in its own body (that would re-evaluate everything drawn
//  around the video each second).
//

import SwiftUI

enum VideoStatsOverlayLocation: String, CaseIterable {
    case bottomLeft
    case bottomRight
    case bottomCenter
    case topLeft
    case topRight
    case topCenter

    static var menuLocations: [VideoStatsOverlayLocation] {
        #if os(iOS)
        [.bottomLeft, .bottomRight]
        #else
        allCases
        #endif
    }

    var menuTitle: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .bottomCenter: "Bottom Center"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .topCenter: "Top Center"
        }
    }

    var alignment: Alignment {
        switch self {
        case .bottomLeft: .bottomLeading
        case .bottomRight: .bottomTrailing
        case .bottomCenter: .bottom
        case .topLeft: .topLeading
        case .topRight: .topTrailing
        case .topCenter: .top
        }
    }

    var isTop: Bool {
        switch self {
        case .topLeft, .topRight, .topCenter: true
        case .bottomLeft, .bottomRight, .bottomCenter: false
        }
    }
}

enum VideoStatsUserDefaults {
    nonisolated static let showStatsKey = AppIdentifier.scoped("showVideoStatsOverlay")
    nonisolated static let statsLocationKey = AppIdentifier.scoped("videoStatsOverlayLocation")
    nonisolated static let disableLowFPSWarningKey = AppIdentifier.scoped("disableLowFPSWarningOverlay")
    nonisolated static let defaultLocation = VideoStatsOverlayLocation.bottomLeft.rawValue

    /// Shows or hides the overlay from code that holds no `@AppStorage` (key commands).
    static func toggleShown(in defaults: UserDefaults = .standard) {
        defaults.set(!defaults.bool(forKey: showStatsKey), forKey: showStatsKey)
    }
}

/// The stats panel in the corner the user chose, when Video Stats is on and the host has lines to show.
struct VideoStatsOverlay: View {
    /// The items to show now, joined on one line, or none to hide the panel. Called in this view's body: read
    /// observable state here.
    let items: () -> [String]
    /// The panel's distance from the edges for a corner. Also called in this view's body.
    var insets: (VideoStatsOverlayLocation) -> EdgeInsets = { _ in
        EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
    }

    @AppStorage(VideoStatsUserDefaults.showStatsKey) private var isShown = false
    @AppStorage(VideoStatsUserDefaults.statsLocationKey)
    private var locationRawValue = VideoStatsUserDefaults.defaultLocation

    #if os(tvOS)
    private static let fontSize: CGFloat = 22
    #else
    private static let fontSize: CGFloat = 13
    #endif

    var body: some View {
        if isShown {
            let items = items()
            if !items.isEmpty {
                let location = VideoStatsOverlayLocation(rawValue: locationRawValue) ?? .bottomLeft
                panel(items.joined(separator: " | "))
                    .padding(insets(location))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: location.alignment)
                    .allowsHitTesting(false)
            }
        }
    }

    /// One line while it fits the width; a window too narrow for it wraps the text instead of cutting it off.
    private func panel(_ text: String) -> some View {
        ViewThatFits(in: .horizontal) {
            pill(Text(text).lineLimit(1).fixedSize())
                .frame(maxHeight: Self.fontSize + 8)
            pill(Text(text).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true))
        }
    }

    private func pill(_ text: some View) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return text
            .font(.system(size: Self.fontSize, weight: .medium, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(white: 0.2).opacity(0.9), in: shape)
            .overlay { shape.stroke(Color.white.opacity(0.3), lineWidth: 1) }
    }
}
