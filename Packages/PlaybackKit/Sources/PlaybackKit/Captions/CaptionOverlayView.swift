//
//  CaptionOverlayView.swift
//  PlaybackKit
//
//  Draws a `CaptionScreen` over the video: the CEA-608 grid of 15 rows × 32 columns inside the caption safe area
//  of a centered 4:3 region, monospaced text with a box behind each run of characters, styled by the user's
//  caption settings (`CaptionAppearance`, from MediaAccessibility). Unset settings keep the classic 608 look.
//

import SwiftUI

public struct CaptionOverlayView: View {
    public let screen: CaptionScreen
    /// The video's display aspect ratio (width / height); captions sit in the centered 4:3 region of the picture.
    public let videoAspectRatio: CGFloat
    @State private var appearance = CaptionAppearance.current()

    public init(screen: CaptionScreen, videoAspectRatio: CGFloat = 16.0 / 9.0) {
        self.screen = screen
        self.videoAspectRatio = videoAspectRatio
    }

    public var body: some View {
        GeometryReader { proxy in
            let grid = CaptionGridLayout(container: proxy.size, videoAspectRatio: videoAspectRatio)
            ZStack(alignment: .topLeading) {
                ForEach(screen.rows) { row in
                    ForEach(row.runs, id: \.column) { run in
                        runView(run, grid: grid)
                            .offset(x: grid.origin.x + CGFloat(run.column) * grid.cellWidth,
                                    y: grid.origin.y + CGFloat(row.row) * grid.rowHeight)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
        .onReceive(NotificationCenter.default.publisher(for: CaptionAppearance.didChangeNotification)) { _ in
            appearance = .current()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(screen.lines.joined(separator: "\n")))
    }

    private func runView(_ run: CaptionRun, grid: CaptionGridLayout) -> some View {
        let size = grid.fontSize * appearance.sizeScale
        let font = appearance.fontName.map { Font.custom($0, fixedSize: size) }
            ?? .system(size: size, design: .monospaced)
        let color = appearance.foreground ?? Self.color(run.style.color)
        return Text(run.text)
            .font(font)
            .italic(run.style.italic)
            .underline(run.style.underline)
            .foregroundStyle(color.opacity(appearance.foregroundOpacity))
            .captionEdge(appearance.edgeStyle, size: size)
            .lineLimit(1)
            .fixedSize()
            .frame(minWidth: CGFloat(run.length) * grid.cellWidth, minHeight: grid.rowHeight, alignment: .leading)
            .background(appearance.background.opacity(appearance.backgroundOpacity))
    }

    static func color(_ color: CaptionColor) -> Color {
        switch color {
        case .white: .white
        case .green: Color(red: 0, green: 1, blue: 0)
        case .blue: Color(red: 0, green: 0, blue: 1)
        case .cyan: Color(red: 0, green: 1, blue: 1)
        case .red: Color(red: 1, green: 0, blue: 0)
        case .yellow: Color(red: 1, green: 1, blue: 0)
        case .magenta: Color(red: 1, green: 0, blue: 1)
        }
    }
}

private extension View {
    /// The user's text edge style: an outline, a drop shadow, or a raised or depressed bevel.
    @ViewBuilder
    func captionEdge(_ style: CaptionAppearance.EdgeStyle, size: CGFloat) -> some View {
        let offset = max(1, size / 18)
        switch style {
        case .none:
            self
        case .dropShadow:
            shadow(color: .black, radius: 0, x: offset, y: offset)
        case .uniform:
            shadow(color: .black, radius: 0, x: offset, y: 0)
                .shadow(color: .black, radius: 0, x: -offset, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: offset)
                .shadow(color: .black, radius: 0, x: 0, y: -offset)
        case .raised:
            shadow(color: .white.opacity(0.6), radius: 0, x: -offset, y: -offset)
                .shadow(color: .black, radius: 0, x: offset, y: offset)
        case .depressed:
            shadow(color: .black, radius: 0, x: -offset, y: -offset)
                .shadow(color: .white.opacity(0.6), radius: 0, x: offset, y: offset)
        }
    }
}

/// Where the caption grid's cells fall inside a container showing the video aspect-fit.
nonisolated struct CaptionGridLayout: Equatable {
    /// Fraction of the 4:3 region's width and height the 608 safe caption area uses (32 columns plus margins).
    static let safeFraction: CGFloat = 0.8

    var origin: CGPoint
    var cellWidth: CGFloat
    var rowHeight: CGFloat

    init(container: CGSize, videoAspectRatio: CGFloat) {
        let aspect = videoAspectRatio > 0 ? videoAspectRatio : 16.0 / 9.0
        // The video rectangle, aspect-fit and centered in the container.
        var video = CGSize(width: container.width, height: container.width / aspect)
        if video.height > container.height {
            video = CGSize(width: container.height * aspect, height: container.height)
        }
        // CEA-608 captions address a 4:3 picture; on wider video they use its centered 4:3 region.
        let region = CGSize(width: min(video.width, video.height * 4 / 3), height: video.height)
        let safe = CGSize(width: region.width * Self.safeFraction, height: region.height * Self.safeFraction)
        origin = CGPoint(x: (container.width - safe.width) / 2, y: (container.height - safe.height) / 2)
        cellWidth = safe.width / CGFloat(CaptionScreen.columnCount)
        rowHeight = safe.height / CGFloat(CaptionScreen.rowCount)
    }

    /// A monospaced font whose advance (about 0.6 em) fits one cell and whose line fits one row.
    var fontSize: CGFloat {
        max(1, min(rowHeight * 0.8, cellWidth / 0.6))
    }
}

#Preview {
    let screen = CaptionScreen(rows: [
        CaptionRow(row: 12, runs: [CaptionRun(column: 4, text: "[MUSIC PLAYING]", style: CaptionStyle(italic: true))]),
        CaptionRow(row: 14, runs: [
            CaptionRun(column: 4, text: "HELLO, "),
            CaptionRun(column: 11, text: "WORLD", style: CaptionStyle(color: .yellow, underline: true))
        ])
    ])
    CaptionOverlayView(screen: screen)
        .background(Color.gray)
        .frame(width: 640, height: 360)
}
