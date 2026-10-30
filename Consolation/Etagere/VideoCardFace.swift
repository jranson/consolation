//
//  VideoCardFace.swift
//  Consolation
//
//  How a VideoCard looks on a shelf: a generated face on a deterministic gradient from the card's ID, so a card always
//  looks the same and showing Home never needs I/O or a tuner. Live channels show their call sign, number, HD and Live
//  badges and the favorite mark, and never a captured frame. Recordings and library items may show server artwork, with
//  the generated face behind it; Continue Watching shows a progress bar. Sizes follow the face size the Etagere's
//  metrics give, so the same face reads from a Mac window or across a room.
//

import EtagereKit
import SwiftUI

// The conformance is `nonisolated`: a plain extension would be main-actor-isolated in this target and could not satisfy
// `Sendable`.
nonisolated extension VideoCard: ShelfCardContent {
    /// A full phrase for VoiceOver, for example "KUSA 9.1, HD, live now, favorite".
    var accessibilityTitle: String {
        var parts: [String] = []
        if kind == .liveChannel {
            parts.append([title, subtitle].compactMap(\.self).joined(separator: " "))
            if isHD { parts.append(String(localized: "HD")) }
        } else {
            parts.append(title)
            if let subtitle, !subtitle.isEmpty { parts.append(subtitle) }
        }
        switch badge {
        case .live: parts.append(String(localized: "live now"))
        case .recordingNow: parts.append(String(localized: "recording now"))
        case nil: break
        }
        if let percent = progressPercent { parts.append(String(localized: "\(percent)% watched")) }
        if favorite != .none { parts.append(String(localized: "favorite")) }
        return parts.joined(separator: ", ")
    }

    @MainActor
    func makeFace(context: ShelfCardContext) -> some View {
        VideoCardFace(card: self, size: context.faceSize)
    }

    /// The resume position in whole percent, when there is one.
    var progressPercent: Int? {
        progress.map { Int(($0 * 100).rounded()) }
    }

    /// The generated face's hue (0..<1), from a stable hash of the ID (FNV-1a, never `hashValue`, which changes
    /// every launch), so a card keeps its colors across launches and devices.
    var generatedHue: Double {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Double(hash % 360) / 360
    }

    /// The SF Symbol of the favorite mark: `lock.heart.fill` on the tuner, `heart.fill` in the app.
    var favoriteSymbol: String? {
        switch favorite {
        case .none: nil
        case .device: "lock.heart.fill"
        case .app: "heart.fill"
        }
    }
}

/// The face itself. `Equatable`, so the ring renders it once per content change.
struct VideoCardFace: View, Equatable {
    let card: VideoCard
    let size: CGSize

    private var height: CGFloat { max(size.height, 1) }
    private var padding: CGFloat { (size.width * 0.06).rounded() }

    var body: some View {
        ZStack {
            // The Capture Card card wears the app's fuchsia; every other card its own hue.
            GeneratedBackground(hue: card.kind == .captureCard ? 0.84 : card.generatedHue)
            if let url = card.artworkURL {
                ArtworkImage(url: url)
            }
            switch card.kind {
            case .liveChannel: liveContent
            case .captureCard: captureCardContent
            default: itemContent
            }
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
    }

    /// Number and favorite mark on top; call sign and the HD and Live badges below.
    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Text(card.subtitle ?? "")
                    .font(.system(size: height * 0.26, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Spacer(minLength: padding / 2)
                favoriteMark
            }
            Spacer(minLength: 0)
            Text(card.title)
                .font(.system(size: height * 0.13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            HStack(spacing: height * 0.04) {
                if card.isHD { CardBadge(text: "HD", style: .outlined, height: height) }
                if card.badge == .live { CardBadge(text: "LIVE", style: .filled(.red), height: height) }
            }
            .padding(.top, height * 0.03)
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// The Capture Card card: its symbol, then the title and the attached device's name.
    private var captureCardContent: some View {
        VStack(alignment: .leading, spacing: height * 0.02) {
            Image(systemName: CaptureCardSupport.systemImage)
                .font(.system(size: height * 0.24, weight: .semibold))
            Spacer(minLength: 0)
            Text(card.title)
                .font(.system(size: height * 0.13, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: height * 0.085))
                    .lineLimit(1)
                    .opacity(0.85)
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// Title and subtitle at the bottom over a scrim (so they read over artwork), badges and favorite on top, and
    /// the resume position along the bottom edge.
    private var itemContent: some View {
        VStack(alignment: .leading, spacing: height * 0.02) {
            HStack(alignment: .top) {
                if card.badge == .recordingNow { CardBadge(text: "REC", style: .filled(.red), height: height) }
                Spacer(minLength: 0)
                favoriteMark
            }
            Spacer(minLength: 0)
            Text(card.title)
                .font(.system(size: height * 0.12, weight: .semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            if let subtitle = card.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: height * 0.085))
                    .lineLimit(1)
                    .opacity(0.85)
            }
            if let progress = card.progress {
                ProgressTrack(fraction: progress, height: max(3, (height * 0.03).rounded()))
                    .padding(.top, height * 0.02)
            }
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            if card.artworkURL != nil {
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                    .frame(height: height * 0.6)
            }
        }
    }

    @ViewBuilder private var favoriteMark: some View {
        if let symbol = card.favoriteSymbol {
            Image(systemName: symbol)
                .font(.system(size: height * 0.12, weight: .semibold))
                .shadow(color: .black.opacity(0.3), radius: 2)
        }
    }
}

/// Two hues from the card's ID, top-leading to bottom-trailing.
private struct GeneratedBackground: View {
    let hue: Double

    var body: some View {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.62, brightness: 0.58),
                Color(hue: (hue + 0.08).truncatingRemainder(dividingBy: 1), saturation: 0.75, brightness: 0.28)
            ],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }
}

/// Server artwork over the generated face, which shows while it loads and when it fails.
private struct ArtworkImage: View {
    let url: URL

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            }
        }
    }
}

private struct CardBadge: View {
    enum Style {
        case filled(Color)
        case outlined
    }

    let text: String
    let style: Style
    let height: CGFloat

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: max(9, height * 0.075), weight: .bold))
            .padding(.horizontal, max(4, height * 0.035))
            .padding(.vertical, max(1, height * 0.012))
            .background {
                switch style {
                case .filled(let color): Capsule().fill(color)
                case .outlined: Capsule().strokeBorder(.white.opacity(0.85), lineWidth: max(1, height * 0.008))
                }
            }
    }
}

private struct ProgressTrack: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        Capsule()
            .fill(.white.opacity(0.3))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(.white)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
    }
}
