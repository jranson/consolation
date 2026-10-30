//
//  MPEG2FramerState.swift
//  MPEGTS
//
//  The pieces of `MPEG2Framer` state: the access unit under construction, pending PES timestamps and the
//  decode-timestamp interpolator.
//

/// A PES's timestamps, waiting for the first picture that starts at or after `offset` in the framer's buffer.
nonisolated struct PendingStamp: Equatable {
    var offset: Int
    var pts: Int64?
    var dts: Int64?
    var discontinuity: Bool
}

/// The access unit being assembled: its byte range starts at `start` and ends at the next AU boundary.
nonisolated struct UnitBuilder {
    var start: Int
    var hasSequenceHeader = false
    var hasGOPHeader = false
    var closedGOP = false
    var brokenLink = false
    /// Picture start codes seen: 1 for a frame picture or a lone field, 2 for a field pair.
    var pictureCount = 0
    /// The first picture's parameters; nil if its header was invalid.
    var picture: MPEG2PictureInfo?
    /// The first picture is a field and its partner has not started yet.
    var awaitingSecondField = false
    var stamp: PendingStamp?
    var captions: [UInt8] = []

    init(start: Int) {
        self.start = start
    }

    /// Nothing worth keeping yet: no picture, sequence header or GOP header.
    var isEmpty: Bool { pictureCount == 0 && !hasSequenceHeader && !hasGOPHeader }
}

/// The timestamps the framer assigns to one picture, in 90 kHz ticks.
nonisolated struct PictureTiming: Equatable {
    var pts: Int64
    var dts: Int64
    var duration: Int64
}

/// Assigns PTS/DTS to pictures. Explicit PES timestamps re-anchor it; pictures without them get the anchor's DTS
/// plus the duration of every picture since, computed from field counts so 59.94 Hz (1501.5 ticks) never drifts.
nonisolated struct MPEG2Timing {
    private var anchorDTS: Int64?
    private var fieldsSinceAnchor: Int64 = 0
    /// PTS − DTS of the last I or P picture with explicit timestamps (the reorder delay).
    private var referenceDelay: Int64 = 0

    /// Display duration of `fields` field periods at `rate` frames per second, in 90 kHz ticks.
    static func ticks(fields: Int64, rate: MPEG2Rational) -> Int64 {
        guard rate.numerator > 0, rate.denominator > 0 else { return 0 }
        return fields * 90_000 * Int64(rate.denominator) / (2 * Int64(rate.numerator))
    }

    /// Field periods a picture occupies on display (13818-2 §6.3.10, Table 6-18).
    static func fieldCount(picture: MPEG2PictureInfo, sequence: MPEG2SequenceInfo, pictureCount: Int) -> Int64 {
        if picture.pictureStructure != .frame {
            return pictureCount >= 2 ? 2 : 1
        }
        if sequence.progressiveSequence {
            guard picture.repeatFirstField else { return 2 }
            return picture.topFieldFirst ? 6 : 4
        }
        return picture.repeatFirstField ? 3 : 2
    }

    /// The picture's timestamps and duration, or nil while no timestamp has ever been seen.
    mutating func stamp(
        explicit: PendingStamp?,
        picture: MPEG2PictureInfo,
        sequence: MPEG2SequenceInfo,
        fields: Int64
    ) -> PictureTiming? {
        let pts: Int64
        let dts: Int64
        if let explicitPTS = explicit?.pts {
            pts = explicitPTS
            dts = explicit?.dts ?? explicitPTS
            anchorDTS = dts
            fieldsSinceAnchor = 0
            if picture.pictureType != .bidirectional {
                referenceDelay = max(0, pts - dts)
            }
        } else if let anchor = anchorDTS {
            dts = anchor + Self.ticks(fields: fieldsSinceAnchor, rate: sequence.frameRate)
            let reorders = picture.pictureType != .bidirectional && !sequence.lowDelay
            pts = reorders ? dts + referenceDelay : dts
        } else {
            return nil
        }
        fieldsSinceAnchor += fields
        return PictureTiming(pts: pts, dts: dts, duration: Self.ticks(fields: fields, rate: sequence.frameRate))
    }
}
