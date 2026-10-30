//
//  NALVideoFramerUnits.swift
//  MPEGTS
//
//  NAL unit handling for `NALVideoFramer` (what each H.264 and HEVC NAL unit type does to the access unit being
//  built) and turning a finished unit into an `NALAccessUnit`: parameter sets, fields and interlace, timestamps,
//  H.264 field pairing and the start-up rules.
//

import Foundation

/// The access unit being assembled.
nonisolated struct NALUnitBuilder: Sendable {
    var stamp: PendingStamp?
    /// Length-prefixed NAL units.
    var sample: [UInt8] = []
    var hasVCL = false
    /// Too large, or part of it was lost to the size cap: never emitted.
    var isBroken = false
    /// The first slice's PPS.
    var ppsID: Int?
    var isIDR = false
    /// HEVC IRAP, or an H.264 recovery point SEI.
    var isRandomAccessHint = false
    var isReference = false
    var h264Slice: H264Slice?
    var hevcType: Int?
    var temporalID = 0
    var picTimingPayload: [UInt8]?
    var captions: [UInt8] = []

    /// Appends one NAL unit with its 4-byte length.
    mutating func append(_ nal: UnsafeBufferPointer<UInt8>) {
        guard !isBroken else { return }
        guard sample.count + nal.count + 4 <= NALVideoFramer.maximumAccessUnitSize else {
            isBroken = true
            return
        }
        withUnsafeBytes(of: UInt32(nal.count).bigEndian) { sample.append(contentsOf: $0) }
        sample.append(contentsOf: nal)
    }
}

/// A coded picture before field pairing and the start-up rules.
nonisolated struct FramedPicture: Sendable {
    /// The picture's facts; its `data` stays empty, since the bytes are in `sample` until delivered.
    var unit: NALAccessUnit
    /// The length-prefixed NAL units (moved out of the builder, not copied).
    var sample: [UInt8]
    var hasExplicitPTS: Bool
    /// H.264 field pictures: parity and frame_num, for pairing.
    var field: (bottom: Bool, frameNum: Int)?
    /// One frame's duration, so a joined field pair lasts exactly that (two halves can round short).
    var frameTicks: Int64
}

extension NALVideoFramer {
    // MARK: - NAL units

    mutating func handleH264(_ nal: UnsafeBufferPointer<UInt8>, at position: Int, deliver: NALUnitHandler) {
        let type = Int(nal[0] & 0x1F)
        switch type {
        case 1...5:
            let rbsp = NALSyntax.rbsp(nal, from: 1, limit: 32)
            let firstMB = rbsp.withUnsafeBufferPointer { pointer -> Int in
                var reader = BitReader(pointer)
                return reader.golomb()
            }
            beginUnitIfNeeded(newPicture: firstMB == 0, at: position, deliver: deliver)
            addH264Slice(nal, rbsp: rbsp, type: type)
        case 7:
            beginUnitIfNeeded(newPicture: true, at: position, deliver: deliver)
            parameters.storeH264SPS(nal)
        case 8:
            beginUnitIfNeeded(newPicture: true, at: position, deliver: deliver)
            parameters.storePPS(nal, codec: .h264)
        case 9, 12:
            // Access unit delimiter (it starts a unit but isn't kept), filler data.
            if type == 9 { beginUnitIfNeeded(newPicture: true, at: position, deliver: deliver) }
        case 6:
            beginUnitIfNeeded(newPicture: true, at: position, deliver: deliver)
            readSEI(nal, headerBytes: 1)
            unit?.append(nal)
        case 13...18:
            beginUnitIfNeeded(newPicture: type >= 14, at: position, deliver: deliver)
            unit?.append(nal)
        default:
            unit?.append(nal)
        }
    }

    private mutating func addH264Slice(_ nal: UnsafeBufferPointer<UInt8>, rbsp: [UInt8], type: Int) {
        // Taken out, not copied: a copy would share the sample with `unit` and appending would copy all of it.
        guard var builder = unit.take() else { return }
        builder.isReference = builder.isReference || (nal[0] & 0x60) != 0
        if !builder.hasVCL {
            builder.hasVCL = true
            builder.isIDR = type == 5
            rbsp.withUnsafeBufferPointer { pointer in
                guard let ppsID = H264Headers.slicePPSID(pointer),
                      let sps = parameters.h264SPS(forPPS: ppsID) else { return }
                builder.ppsID = ppsID
                builder.h264Slice = H264Headers.slice(pointer, sps: sps)
            }
        }
        builder.append(nal)
        unit = builder
    }

    mutating func handleHEVC(_ nal: UnsafeBufferPointer<UInt8>, at position: Int, deliver: NALUnitHandler) {
        let type = Int((nal[0] >> 1) & 0x3F)
        let layer = (Int(nal[0] & 0x01) << 5) | Int(nal[1] >> 3)
        // Only the base layer is decoded; enhancement layers (scalable or multiview HEVC) are left out.
        guard layer == 0 else { return }
        if HEVCNALType.isVCL(type) {
            let rbsp = NALSyntax.rbsp(nal, from: 2, limit: 16)
            let start = rbsp.withUnsafeBufferPointer { HEVCHeaders.sliceStart($0, nalType: type) }
            beginUnitIfNeeded(newPicture: start?.first ?? false, at: position, deliver: deliver)
            addHEVCSlice(nal, type: type, ppsID: start?.ppsID)
            return
        }
        if HEVCNALType.startsAccessUnit(type) {
            beginUnitIfNeeded(newPicture: true, at: position, deliver: deliver)
        }
        switch type {
        case HEVCNALType.vps: parameters.storeVPS(nal)
        case HEVCNALType.sps: parameters.storeHEVCSPS(nal)
        case HEVCNALType.pps: parameters.storePPS(nal, codec: .hevc)
        case HEVCNALType.accessUnitDelimiter, HEVCNALType.fillerData: break
        case HEVCNALType.prefixSEI:
            readSEI(nal, headerBytes: 2)
            unit?.append(nal)
        default:
            unit?.append(nal)
        }
    }

    private mutating func addHEVCSlice(_ nal: UnsafeBufferPointer<UInt8>, type: Int, ppsID: Int?) {
        // Taken out, not copied: a copy would share the sample with `unit` and appending would copy all of it.
        guard var builder = unit.take() else { return }
        if !builder.hasVCL {
            builder.hasVCL = true
            builder.hevcType = type
            builder.temporalID = max(0, Int(nal[1] & 0x07) - 1)
            builder.ppsID = ppsID
            builder.isIDR = HEVCNALType.idr.contains(type)
            builder.isRandomAccessHint = HEVCNALType.irap.contains(type)
        }
        builder.append(nal)
        unit = builder
    }

    /// Captions, H.264 picture timing and recovery points from an SEI NAL unit.
    private mutating func readSEI(_ nal: UnsafeBufferPointer<UInt8>, headerBytes: Int) {
        guard var builder = unit else { return }
        let rbsp = NALSyntax.rbsp(nal, from: headerBytes)
        rbsp.withUnsafeBufferPointer { pointer in
            for message in NALSyntax.seiMessages(rbsp) {
                let payload = UnsafeBufferPointer(rebasing: pointer[message.payload])
                switch message.payloadType {
                case NALSyntax.userDataRegisteredT35:
                    NALSyntax.appendCaptions(t35: payload, to: &builder.captions)
                case 1 where codec == .h264:
                    builder.picTimingPayload = Array(payload)
                case 6:
                    builder.isRandomAccessHint = true
                default:
                    break
                }
            }
        }
        unit = builder
    }

    // MARK: - Finishing a unit

    /// Turns a finished unit into a picture and passes it on (through field pairing for H.264).
    mutating func complete(_ builder: consuming NALUnitBuilder, deliver: NALUnitHandler) {
        guard builder.hasVCL, !builder.isBroken, let ppsID = builder.ppsID,
              let active = parameters.active(forPPS: ppsID, codec: codec) else { return }
        var structure = PictureStructure.progressive
        var randomAccess = builder.isRandomAccessHint || builder.isIDR
        var reference = builder.isReference
        if let sps = active.h264 {
            guard let slice = builder.h264Slice else { return }
            let picStruct = builder.picTimingPayload.flatMap { payload in
                payload.withUnsafeBufferPointer { H264Headers.picStruct($0, sps: sps) }
            }
            structure = PictureStructure(slice: slice, sps: sps, picStruct: picStruct)
            randomAccess = randomAccess || slice.isIntra
        } else if let sps = active.hevc, let type = builder.hevcType {
            reference = !(HEVCNALType.isSubLayerNonReference(type) && builder.temporalID >= sps.maxSubLayersMinus1)
        }
        guard let times = timing.stamp(explicit: builder.stamp, fields: structure.fields, isReference: reference,
                                       frameRate: active.format.frameRate) else { return }
        let unit = NALAccessUnit(
            codec: codec, data: Data(), parameterSets: active.parameterSets, pts: times.pts,
            dts: times.dts, duration: times.duration, format: active.format, isRandomAccess: randomAccess,
            isReference: reference, isInterlaced: structure.isInterlaced, topFieldFirst: structure.topFieldFirst,
            captionData: builder.captions.isEmpty ? nil : Data(builder.captions),
            isDiscontinuity: builder.stamp?.discontinuity ?? false)
        let field = builder.h264Slice.flatMap { $0.fieldPic ? (bottom: $0.bottomField, frameNum: $0.frameNum) : nil }
        var framed = FramedPicture(unit: unit, sample: [], hasExplicitPTS: builder.stamp?.pts != nil, field: field,
                                   frameTicks: timing.lastFrameTicks)
        // Swapped rather than copied, so the sample is never shared and its storage can be reused once delivered.
        swap(&framed.sample, &builder.sample)
        pair(&framed, deliver: deliver)
    }

    /// Joins an H.264 first field with its complementary second field into one sample.
    private mutating func pair(_ picture: inout FramedPicture, deliver: NALUnitHandler) {
        if let first = heldField?.field, var held = heldField.take() {
            if let second = picture.field, second.bottom != first.bottom, second.frameNum == first.frameNum {
                held.sample.append(contentsOf: picture.sample)
                held.unit.duration = held.frameTicks
                held.unit.isReference = held.unit.isReference || picture.unit.isReference
                held.unit.isDiscontinuity = held.unit.isDiscontinuity || picture.unit.isDiscontinuity
                if let captions = picture.unit.captionData {
                    held.unit.captionData = (held.unit.captionData ?? Data()) + captions
                }
                emit(&held, deliver: deliver)
                recycle(&picture.sample)
                return
            }
            emit(&held, deliver: deliver)
        }
        if picture.field != nil {
            heldField = picture
            picture.sample = []
        } else {
            emit(&picture, deliver: deliver)
        }
    }

    /// The start-up rules: begin at a random-access picture with its own PTS, then drop its leading pictures.
    /// Delivers the picture's sample lent, then keeps its storage for the next access unit.
    mutating func emit(_ picture: inout FramedPicture, deliver: NALUnitHandler) {
        defer { recycle(&picture.sample) }
        let unit = picture.unit
        if !hasStarted {
            guard unit.isRandomAccess, picture.hasExplicitPTS else { return }
            hasStarted = true
            leadingCutoff = unit.pts
        } else if let cutoff = leadingCutoff {
            if !unit.isRandomAccess, unit.pts < cutoff { return }
            leadingCutoff = nil
        }
        format = unit.format
        picture.sample.withUnsafeBufferPointer { deliver(unit, $0) }
    }

    /// Keeps a delivered sample's storage for the next access unit's builder (`beginUnitIfNeeded`). `sample` must not
    /// be shared, or emptying it would allocate a new buffer of the same capacity.
    mutating func recycle(_ sample: inout [UInt8]) {
        guard sample.capacity > spareSample.capacity else { return }
        sample.removeAll(keepingCapacity: true)
        swap(&sample, &spareSample)
    }
}

/// How a picture's fields are coded and shown.
nonisolated struct PictureStructure: Equatable, Sendable {
    var isInterlaced = false
    var topFieldFirst = true
    /// Field periods on display: 1 for a single field, 2 for a frame, 3 or more with pic_struct repeats.
    var fields = 2

    static let progressive = PictureStructure()

    init(isInterlaced: Bool = false, topFieldFirst: Bool = true, fields: Int = 2) {
        self.isInterlaced = isInterlaced
        self.topFieldFirst = topFieldFirst
        self.fields = fields
    }

    /// From the slice header and, for frames that may be interlaced, pic_struct (Table D-1). Without pic_struct a
    /// frame in a stream that allows fields is taken as interlaced, top field first (US broadcast 1080i).
    init(slice: H264Slice, sps: H264SPS, picStruct: Int?) {
        if slice.fieldPic {
            self.init(isInterlaced: true, topFieldFirst: !slice.bottomField, fields: 1)
            return
        }
        let fields = switch picStruct {
        case 5, 6: 3
        case 7: 4
        case 8: 6
        default: 2
        }
        if sps.frameMBsOnly {
            self.init(fields: fields)
            return
        }
        switch picStruct {
        case 0, 7, 8: self.init(fields: fields)
        case 4, 6: self.init(isInterlaced: true, topFieldFirst: false, fields: fields)
        default: self.init(isInterlaced: true, topFieldFirst: true, fields: fields)
        }
    }
}

/// Assigns PTS/DTS like `MPEG2Timing`. Durations come from the VUI frame rate (H.264), else from the spacing of
/// explicit decode timestamps, else 29.97 Hz.
nonisolated struct NALTiming: Sendable {
    private var anchorDTS: Int64?
    private var ticksSinceAnchor: Int64 = 0
    private var referenceDelay: Int64 = 0
    private var lastExplicitDTS: Int64?
    private var fieldsSinceExplicit = 0
    private var recentFrameTicks: [Int64] = []
    /// The frame duration the last picture was timed with.
    private(set) var lastFrameTicks = NALTiming.defaultFrameTicks

    static let defaultFrameTicks: Int64 = 3_003
    /// Plausible frame durations: 10 to 300 frames per second.
    static let plausibleFrameTicks: ClosedRange<Int64> = 300...9_000

    mutating func stamp(explicit: PendingStamp?, fields: Int, isReference: Bool,
                        frameRate: MPEG2Rational?) -> PictureTiming? {
        if let explicitPTS = explicit?.pts {
            let dts = explicit?.dts ?? explicitPTS
            if let last = lastExplicitDTS, fieldsSinceExplicit > 0 {
                let estimate = 2 * (dts - last) / Int64(fieldsSinceExplicit)
                if Self.plausibleFrameTicks.contains(estimate) {
                    recentFrameTicks.append(estimate)
                    if recentFrameTicks.count > 8 { recentFrameTicks.removeFirst() }
                }
            }
            lastExplicitDTS = dts
            fieldsSinceExplicit = 0
        }
        let frame = Self.frameTicks(frameRate) ?? recentFrameTicks.min() ?? Self.defaultFrameTicks
        lastFrameTicks = frame
        let duration = frame * Int64(fields) / 2
        let pts: Int64
        let dts: Int64
        if let explicitPTS = explicit?.pts {
            pts = explicitPTS
            dts = explicit?.dts ?? explicitPTS
            anchorDTS = dts
            ticksSinceAnchor = 0
            if isReference { referenceDelay = max(0, pts - dts) }
        } else if let anchor = anchorDTS {
            dts = anchor + ticksSinceAnchor
            pts = isReference ? dts + referenceDelay : dts
        } else {
            return nil
        }
        fieldsSinceExplicit += fields
        ticksSinceAnchor += duration
        return PictureTiming(pts: pts, dts: dts, duration: duration)
    }

    static func frameTicks(_ rate: MPEG2Rational?) -> Int64? {
        guard let rate, rate.numerator > 0, rate.denominator > 0 else { return nil }
        let ticks = 90_000 * Int64(rate.denominator) / Int64(rate.numerator)
        return plausibleFrameTicks.contains(ticks) ? ticks : nil
    }
}
