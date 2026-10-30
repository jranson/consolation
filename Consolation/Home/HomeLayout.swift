//
//  HomeLayout.swift
//  Consolation
//
//  Settings › Home's layout choices as the Etagere's configuration, applied live to every window's Home.
//

import EtagereKit
import Foundation

/// Settings › Home › Card size. Medium is EtagereKit's starting metrics for the Home pane's width class
/// (`EtagereMetrics.automatic`). Small and Large take those same metrics and scale only the idle card width, by 0.8 and
/// 1.2 (so the enlarged Active ShelfCard scales with it); spacing, the active scale and the title style stay as they
/// are. They are `.fixed` metrics recomputed whenever the pane's width changes, so a window resize still moves between
/// width classes.
nonisolated enum HomeCardSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    /// The idle card width relative to the width class's starting width.
    var scale: CGFloat {
        switch self {
        case .small: 0.8
        case .medium: 1
        case .large: 1.2
        }
    }

    /// The metrics for a container width. Until the width is known, every size uses the starting metrics.
    func metrics(containerWidth: CGFloat?,
                 isTelevision: Bool = EtagereWidthClass.platformIsTelevision) -> EtagereMetrics {
        guard self != .medium, let containerWidth, containerWidth > 0 else { return .automatic }
        var resolved = EtagereMetrics.automatic.resolved(containerWidth: containerWidth, isTelevision: isTelevision)
        resolved.cardWidth = (resolved.cardWidth * scale).rounded()
        return .fixed(resolved)
    }
}

extension HomeSettings {
    /// The Etagere configuration these settings describe, for a Home pane of `containerWidth` points. "Show the
    /// cycle seam" covers both seams: between each ring's last and first card, and between the last and first
    /// shelf in mode 1.
    func etagereConfiguration(containerWidth: CGFloat?) -> EtagereConfiguration {
        var configuration = EtagereConfiguration(
            horizontalAlignment: shelfAlignment, verticalAlignment: verticalAlignment, verticalMode: verticalMode
        )
        configuration.metrics = cardSize.metrics(containerWidth: containerWidth)
        configuration.showsSeam = showsSeam
        configuration.showsShelfSeam = showsSeam
        return configuration
    }
}
