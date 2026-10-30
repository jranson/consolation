//
//  AVPlayerEngineTiles.swift
//  PlaybackKit
//
//  AVPlayerEngine as one multi-view tile. AVPlayer decodes in hardware and can't skip pictures, so a tier below
//  `.single` caps the HLS variant instead (smaller pictures, fewer bits), and `.suspended` asks for the lowest variant
//  rather than pausing, so a live stream stays at its live edge. Files have one variant and ignore tiers. A silent tile
//  plays at volume 0: AVPlayer has no cheap way to stop decoding one item's audio (an HLS audio group usually can't be
//  deselected, and disabling item tracks also hides their facts from the stats overlay), and its audio decode is a
//  small cost next to the video.
//

import AVFoundation
import Foundation

extension AVPlayerEngine {
    /// The resolution cap for a grid or reduced tile: a 2x2 tile on a 1080p screen is at most 960x540.
    static let tileResolution = CGSize(width: 960, height: 540)
    /// A peak bit rate below every real variant, so AVPlayer picks the lowest.
    static let lowestVariantBitRate = 1.0

    public func setDecodeTier(_ tier: DecodeTier) {
        guard tier != decodeTier else { return }
        decodeTier = tier
        if let item = player.currentItem { applyTier(to: item) }
    }

    /// The variant limits for `tier`: no limit for `.single`, 960x540 for the other visible tiers, the lowest
    /// variant for `.suspended`.
    static func variantLimits(for tier: DecodeTier) -> (resolution: CGSize, peakBitRate: Double) {
        switch tier {
        case .full(fieldRate: true): (.zero, 0)
        case .full(fieldRate: false), .reduced, .keyframesOnly: (tileResolution, 0)
        case .suspended: (tileResolution, lowestVariantBitRate)
        }
    }

    func applyTier(to item: AVPlayerItem) {
        let limits = Self.variantLimits(for: decodeTier)
        item.preferredMaximumResolution = limits.resolution
        item.preferredPeakBitRate = limits.peakBitRate
    }

    /// `volume` while the tile plays audio, else 0. `isMuted` (the user's mute) stays separate. A tone-mapped split's
    /// sound comes from its audio player.
    func applyVolume() {
        let level = playsAudio ? min(max(volume, 0), 1) : 0
        player.volume = level
        follower?.audioPlayer.volume = level
    }

    func applyMute() {
        player.isMuted = isMuted
        follower?.audioPlayer.isMuted = isMuted
    }
}
