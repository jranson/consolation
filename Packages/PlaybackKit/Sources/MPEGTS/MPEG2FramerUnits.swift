//
//  MPEG2FramerUnits.swift
//  MPEGTS
//
//  Header parsing into the unit under construction, and turning a finished unit into an `MPEG2AccessUnit`
//  (start-up and leading-B rules, timestamps, captions).
//

import Foundation

extension MPEG2Framer {
    /// Parses the header segment opened by the last start code, which ends at `end`.
    mutating func closeSegment(end: Int, bytes: UnsafeBufferPointer<UInt8>) {
        guard let code = openCode else { return }
        openCode = nil
        let start = openCodePosition + 4
        guard start <= end, end <= bytes.count else { return }
        let segment = UnsafeBufferPointer(rebasing: bytes[start..<end])
        switch code {
        case MPEG2StartCode.sequenceHeader:
            if let info = MPEG2Headers.sequenceHeader(segment) {
                sequence = info
                unit.hasSequenceHeader = true
            }
        case MPEG2StartCode.extensionStart:
            applyExtension(segment)
        case MPEG2StartCode.groupOfPictures:
            if let gop = MPEG2Headers.groupOfPictures(segment) {
                unit.hasGOPHeader = true
                unit.closedGOP = gop.closedGOP
                unit.brokenLink = gop.brokenLink
            }
        case MPEG2StartCode.picture:
            if unit.pictureCount == 0 {
                unit.picture = MPEG2Headers.pictureHeader(segment)
                unit.pictureCount = 1
                isSecondFieldExtension = false
            } else {
                unit.pictureCount += 1
                unit.awaitingSecondField = false
                isSecondFieldExtension = true
            }
        case MPEG2StartCode.userData:
            MPEG2Headers.appendCaptions(segment, to: &unit.captions)
        default:
            break
        }
    }

    private mutating func applyExtension(_ segment: UnsafeBufferPointer<UInt8>) {
        switch MPEG2Headers.extensionIdentifier(segment) {
        case 1 where unit.hasSequenceHeader && unit.pictureCount == 0:
            if var info = sequence, MPEG2Headers.applySequenceExtension(segment, to: &info) {
                sequence = info
            }
        case 8 where unit.pictureCount == 1 && !isSecondFieldExtension:
            guard var picture = unit.picture else { return }
            if MPEG2Headers.applyPictureCodingExtension(segment, to: &picture) {
                unit.picture = picture
                unit.awaitingSecondField = picture.pictureStructure != .frame
            }
        default:
            break
        }
    }

    /// Emits the unit `unit.start ..< end` (its bytes lent, `data` empty) if it is a decodable picture past the
    /// start-up point.
    mutating func finalize(end: Int, bytes: UnsafeBufferPointer<UInt8>,
                           emit: (MPEG2AccessUnit, UnsafeBufferPointer<UInt8>) -> Void) {
        guard unit.pictureCount > 0, let picture = unit.picture, let sequence,
              unit.start >= 0, unit.start < end, end <= bytes.count else { return }
        let fields = MPEG2Timing.fieldCount(picture: picture, sequence: sequence, pictureCount: unit.pictureCount)
        guard let times = timing.stamp(explicit: unit.stamp, picture: picture, sequence: sequence, fields: fields)
        else { return }
        guard shouldEmit(picture) else { return }
        let captions = unit.captions.isEmpty ? nil : Data(unit.captions)
        let accessUnit = MPEG2AccessUnit(
            data: Data(),
            pts: times.pts,
            dts: times.dts,
            duration: times.duration,
            sequence: sequence,
            pictureType: picture.pictureType,
            temporalReference: picture.temporalReference,
            pictureStructure: picture.pictureStructure,
            topFieldFirst: picture.topFieldFirst,
            repeatFirstField: picture.repeatFirstField,
            progressiveFrame: picture.progressiveFrame,
            hasSequenceHeader: unit.hasSequenceHeader,
            captionData: captions,
            isDiscontinuity: unit.stamp?.discontinuity ?? false
        )
        emit(accessUnit, UnsafeBufferPointer(rebasing: bytes[unit.start..<end]))
    }

    /// Start-up and leading-B rules. Before the start, only a sequence header plus an I picture with its own PTS
    /// qualifies. After an open GOP (or a broken link), B pictures are dropped until the next I or P picture.
    private mutating func shouldEmit(_ picture: MPEG2PictureInfo) -> Bool {
        if !hasStarted {
            guard unit.hasSequenceHeader, picture.pictureType == .intra, unit.stamp?.pts != nil else { return false }
            hasStarted = true
            isDroppingLeadingB = !(unit.hasGOPHeader && unit.closedGOP && !unit.brokenLink)
            return true
        }
        if isDroppingLeadingB {
            if picture.pictureType == .bidirectional {
                return false
            }
            isDroppingLeadingB = false
        }
        // A broken link makes the B pictures that follow this GOP's first picture undecodable too.
        if unit.hasGOPHeader, unit.brokenLink {
            isDroppingLeadingB = true
        }
        return true
    }
}
