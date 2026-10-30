//
//  DecodeTierGate.swift
//  PlaybackKit
//
//  Applies a tile's decode tier to the compressed pictures between our framers and the decoder, so it works the same
//  for every codec and decoder. Pictures arrive in decode order with their role: a keyframe (MPEG-2 I; H.264/HEVC
//  random-access pictures), a reference (MPEG-2 P; other H.264/HEVC pictures) or a provable non-reference (MPEG-2 B;
//  H.264 nal_ref_idc 0; HEVC sub-layer non-reference pictures in the highest sub-layer). Dropping non-references is
//  always safe; dropping a reference (or everything) breaks the reference chain until the next keyframe.
//

import MPEGTS

/// What a picture is to the decode tiers.
nonisolated enum PictureRole: Sendable, Hashable {
    case keyframe
    case reference
    case nonReference

    init(_ type: MPEG2PictureType) {
        switch type {
        case .intra: self = .keyframe
        case .predicted: self = .reference
        case .bidirectional: self = .nonReference
        }
    }
}

nonisolated struct DecodeTierGate {
    private(set) var tier = DecodeTier.single
    /// References were dropped (`.keyframesOnly` or `.suspended`) and the tier now wants more: nothing but a keyframe
    /// may pass until one arrives.
    private(set) var awaitingIntra = false
    /// After resuming at a keyframe, the pictures that follow it in decode order but display before it (an open
    /// GOP's leading pictures) may reference the previous GOP, which wasn't decoded: they are dropped.
    private var droppingLeading = false
    /// The keyframe's PTS: leading pictures are those before it. Without timestamps (nil), MPEG-2's rule applies:
    /// non-references until the next reference.
    private var resumePTS: Int64?

    /// Changes the tier for the pictures that follow. Lowering takes effect at once; raising from a tier that
    /// dropped references resumes at the next I picture.
    mutating func set(_ newTier: DecodeTier) {
        guard newTier != tier else { return }
        let chainBroken = !Self.keepsReferences(tier) || awaitingIntra
        tier = newTier
        awaitingIntra = chainBroken && Self.keepsReferences(newTier)
    }

    /// Whether the decoder gets an MPEG-2 picture of this type (no timestamp: leading B pictures by type).
    mutating func admit(_ type: MPEG2PictureType) -> Bool {
        admit(PictureRole(type), pts: nil)
    }

    /// Whether the decoder gets this picture.
    mutating func admit(_ role: PictureRole, pts: Int64?) -> Bool {
        switch tier {
        case .suspended:
            return false
        case .keyframesOnly:
            return role == .keyframe
        case .reduced, .full:
            break
        }
        if awaitingIntra {
            guard role == .keyframe else { return false }
            awaitingIntra = false
            droppingLeading = true
            resumePTS = pts
            return true
        }
        if droppingLeading, !isPastLeading(role, pts: pts) { return false }
        return role != .nonReference || tier != .reduced
    }

    /// Ends the leading-picture drop at the first picture that isn't one.
    private mutating func isPastLeading(_ role: PictureRole, pts: Int64?) -> Bool {
        if role != .keyframe {
            if let pts, let resumePTS {
                if pts < resumePTS { return false }
            } else if role == .nonReference {
                return false
            }
        }
        droppingLeading = false
        return true
    }

    /// The decoder and framer start over (a new timeline): they resume at an I picture on their own.
    mutating func restart() {
        awaitingIntra = false
        droppingLeading = false
    }

    /// Every I and P picture reaches the decoder, so the reference chain is intact.
    private static func keepsReferences(_ tier: DecodeTier) -> Bool {
        switch tier {
        case .full, .reduced: true
        case .keyframesOnly, .suspended: false
        }
    }
}
