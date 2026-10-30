//
//  CaptionAppearance.swift
//  PlaybackKit
//
//  The user's caption style from MediaAccessibility (Settings › Accessibility › Subtitles & Captioning): font,
//  size, text and background colors and opacities, and edge style. Where the user leaves a property to the
//  content, the CEA-608 value wins (a caption's own color, the classic black box).
//

import CoreGraphics
import CoreText
import MediaAccessibility
import SwiftUI

nonisolated public struct CaptionAppearance: Equatable, Sendable {
    public enum EdgeStyle: Equatable, Sendable {
        case none
        case raised
        case depressed
        case uniform
        case dropShadow
    }

    /// The text color, or nil to use the caption's own 608 color.
    public var foreground: Color?
    public var foregroundOpacity: Double
    /// The box behind each run of characters.
    public var background: Color
    public var backgroundOpacity: Double
    public var edgeStyle: EdgeStyle
    /// A multiplier for the computed text size (the user's "Text size").
    public var sizeScale: Double
    /// A PostScript font name for the user's monospaced caption font, or nil for the system monospaced font.
    public var fontName: String?

    /// Classic CEA-608: white (or the caption's color) on opaque black, no edge, the system monospaced font.
    public static let classic = CaptionAppearance(foreground: nil, foregroundOpacity: 1, background: .black,
                                                  backgroundOpacity: 1, edgeStyle: .none, sizeScale: 1,
                                                  fontName: nil)

    public init(foreground: Color?, foregroundOpacity: Double, background: Color, backgroundOpacity: Double,
                edgeStyle: EdgeStyle, sizeScale: Double, fontName: String?) {
        self.foreground = foreground
        self.foregroundOpacity = foregroundOpacity
        self.background = background
        self.backgroundOpacity = backgroundOpacity
        self.edgeStyle = edgeStyle
        self.sizeScale = sizeScale
        self.fontName = fontName
    }

    /// The user's current settings.
    public static func current() -> CaptionAppearance {
        let domain = MACaptionAppearanceDomain.user
        var behavior = MACaptionAppearanceBehavior.useContentIfAvailable
        let foregroundColor = MACaptionAppearanceCopyForegroundColor(domain, &behavior).takeRetainedValue()
        let foreground = behavior == .useValue ? Color(cgColor: foregroundColor) : nil
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(domain, nil)
        let background = Color(cgColor: MACaptionAppearanceCopyBackgroundColor(domain, nil).takeRetainedValue())
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(domain, nil)
        let size = MACaptionAppearanceGetRelativeCharacterSize(domain, nil)
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(domain, nil, .monospacedWithoutSerif)
            .takeRetainedValue()
        let fontName = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        return CaptionAppearance(foreground: foreground, foregroundOpacity: foregroundOpacity,
                                 background: background, backgroundOpacity: backgroundOpacity,
                                 edgeStyle: edgeStyle(MACaptionAppearanceGetTextEdgeStyle(domain, nil)),
                                 sizeScale: size > 0 ? size : 1, fontName: fontName)
    }

    /// Posted when the user changes their caption settings.
    public static var didChangeNotification: Notification.Name {
        Notification.Name(kMACaptionAppearanceSettingsChangedNotification as String)
    }

    private static func edgeStyle(_ style: MACaptionAppearanceTextEdgeStyle) -> EdgeStyle {
        switch style {
        case .raised: .raised
        case .depressed: .depressed
        case .uniform: .uniform
        case .dropShadow: .dropShadow
        default: .none
        }
    }
}
