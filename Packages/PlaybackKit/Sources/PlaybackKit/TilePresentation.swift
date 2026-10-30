//
//  TilePresentation.swift
//  PlaybackKit
//
//  How an engine plays as one tile of multi-view: how much of the stream it decodes (its decode tier), whether its
//  audio plays, and its volume for crossfades between tiles. A single stream is the default: every picture at field
//  rate, audio on, full volume. Engines that can't do better ignore a tier.
//

import Foundation

/// How much of a stream a tile decodes and shows. Tier changes take effect in the engine's framer, before the
/// decoder, so they work the same for every decoder.
nonisolated public enum DecodeTier: Sendable, Hashable {
    /// Every picture. `fieldRate` true deinterlaces interlaced video to field rate with the motion-adaptive pass
    /// (the single or foreground tile); false shows one cheap bob picture per frame (visible grid tiles).
    case full(fieldRate: Bool)
    /// I and P pictures only (B pictures are dropped before the decoder): about 12 fps for 29.97 broadcast. For a
    /// tile mostly hidden behind the foreground video.
    case reduced
    /// I pictures only, about 1-2 fps.
    case keyframesOnly
    /// Nothing decoded or shown. The stream keeps being read and discarded so the connection (and its tuner) stays
    /// healthy; a higher tier resumes at the next I picture.
    case suspended

    /// The single-stream default.
    public static let single = DecodeTier.full(fieldRate: true)

    /// Whether pictures are decoded at all.
    public var decodesVideo: Bool { self != .suspended }
}

public extension PlaybackEngine {
    // Defaults for engines without multi-view support: they always play everything with sound.
    var decodeTier: DecodeTier { .single }
    func setDecodeTier(_ tier: DecodeTier) {}
    var playsAudio: Bool {
        get { true }
        set {} // swiftlint:disable:this unused_setter_value
    }
    var volume: Float {
        get { 1 }
        set {} // swiftlint:disable:this unused_setter_value
    }
}

nonisolated public extension ByteSource {
    /// Default: a single-program stream (or the first program of the PAT).
    var programNumber: Int? { nil }
}
