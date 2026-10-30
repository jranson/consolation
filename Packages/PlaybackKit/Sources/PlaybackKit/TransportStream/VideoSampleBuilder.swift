//
//  VideoSampleBuilder.swift
//  PlaybackKit
//
//  Turns framed access units into `CompressedPicture`s: the format description, the facts it was made from and the
//  sample buffers. Kept apart from the framers' state so a framer's callback can build each picture while the framer
//  is still running (`ElementaryProcessor`).
//

import CoreMedia
import Foundation
import MPEGTS
import os

/// What an MPEG-2 format description is made from; a new description is made only when this changes.
nonisolated struct MPEG2FormatKey: Equatable {
    var width: Int
    var height: Int
    var interlaced: Bool
    var topFieldFirst: Bool
    var aspectRatioCode: UInt8
}

nonisolated struct VideoSampleBuilder {
    /// Where pictures' sample memory comes from.
    let pool: SampleMemoryPool
    /// What the stream info reports, from the latest format.
    private(set) var facts: VideoStreamFacts?
    private var format: CMVideoFormatDescription?
    private var mpeg2Key: MPEG2FormatKey?
    /// The parameter sets `format` was built from (H.264 and HEVC).
    private var parameterSets: [Data] = []

    /// An MPEG-2 picture whose bytes are lent (the unit's own `data` is empty), copied once into a sample buffer
    /// padded for libavcodec, which then decodes it in place (`LibavVideoDecoder`).
    mutating func picture(for unit: MPEG2AccessUnit, bytes: UnsafeBufferPointer<UInt8>) -> CompressedPicture? {
        updateFormat(unit.sequence, unit: unit)
        guard let format,
              let block = SampleFormats.blockBuffer(copying: UnsafeRawBufferPointer(bytes),
                                                    padding: LibavVideoDecoder.inputPadding,
                                                    pool: pool) else { return nil }
        let timing = SampleFormats.Timing(pts: unit.pts, dts: unit.dts, duration: unit.duration)
        guard let sample = SampleFormats.videoSample(block: block, size: bytes.count, format: format, timing: timing,
                                                     isKeyframe: unit.isKeyframe) else { return nil }
        let interlaced = !unit.sequence.progressiveSequence && !unit.progressiveFrame
        let info = PictureInfo(pts: unit.pts, duration: unit.duration, isInterlaced: interlaced,
                               topFieldFirst: unit.topFieldFirst, role: PictureRole(unit.pictureType))
        return CompressedPicture(sample: sample, info: info, captionData: unit.captionData)
    }

    /// An H.264 or HEVC access unit whose length-prefixed sample is lent (the unit's own `data` is empty), copied
    /// once into a sample buffer. The format description is rebuilt whenever the parameter sets change.
    mutating func picture(for unit: NALAccessUnit, sample bytes: UnsafeBufferPointer<UInt8>) -> CompressedPicture? {
        if format == nil || unit.parameterSets != parameterSets {
            parameterSets = unit.parameterSets
            format = SampleFormats.parameterSetVideo(codec: unit.codec, parameterSets: unit.parameterSets)
            if format == nil {
                let codec = unit.codec.displayName
                ElementaryProcessor.log.error("No format description from the \(codec) parameter sets")
            }
        }
        guard let format else { return nil }
        let timing = SampleFormats.Timing(pts: unit.pts, dts: unit.dts, duration: unit.duration)
        guard let block = SampleFormats.blockBuffer(copying: UnsafeRawBufferPointer(bytes), pool: pool),
              let sample = SampleFormats.videoSample(block: block, size: bytes.count, format: format, timing: timing,
                                                     isKeyframe: unit.isRandomAccess) else { return nil }
        let role: PictureRole = unit.isRandomAccess ? .keyframe : (unit.isReference ? .reference : .nonReference)
        let info = PictureInfo(pts: unit.pts, duration: unit.duration, isInterlaced: unit.isInterlaced,
                               topFieldFirst: unit.topFieldFirst, role: role)
        let rate = unit.format.frameRate?.doubleValue ?? (unit.duration > 0 ? 90_000 / Double(unit.duration) : nil)
        let latest = VideoStreamFacts(codec: unit.codec.displayName, width: unit.format.width,
                                      height: unit.format.height, frameRate: facts?.frameRate ?? rate,
                                      isInterlaced: unit.isInterlaced)
        if latest != facts { facts = latest }
        return CompressedPicture(sample: sample, info: info, captionData: unit.captionData,
                                 codec: unit.codec == .h264 ? .h264 : .hevc,
                                 reorderDepth: unit.format.reorderDepth)
    }

    private mutating func updateFormat(_ info: MPEG2SequenceInfo, unit: MPEG2AccessUnit) {
        let interlaced = !info.progressiveSequence
        let key = MPEG2FormatKey(width: info.width, height: info.height, interlaced: interlaced,
                                 topFieldFirst: unit.topFieldFirst, aspectRatioCode: info.aspectRatioCode)
        guard key != mpeg2Key else { return }
        mpeg2Key = key
        let rate = info.frameRate.denominator > 0
            ? Double(info.frameRate.numerator) / Double(info.frameRate.denominator) : nil
        facts = VideoStreamFacts(codec: "MPEG-2", width: info.width, height: info.height, frameRate: rate,
                                 isInterlaced: interlaced)
        format = SampleFormats.mpeg2Video(width: info.width, height: info.height, interlaced: interlaced,
                                          topFieldFirst: unit.topFieldFirst, pixelAspect: Self.pixelAspect(info))
    }

    /// MPEG-2 aspect_ratio_information is a display aspect; convert to a pixel aspect for the format description.
    static func pixelAspect(_ info: MPEG2SequenceInfo) -> (Int, Int)? {
        let display: (Int, Int)
        switch info.aspectRatioCode {
        case 2: display = (4, 3)
        case 3: display = (16, 9)
        case 4: display = (221, 100)
        default: return nil
        }
        let horizontal = display.0 * info.height
        let vertical = display.1 * info.width
        guard horizontal != vertical else { return nil }
        let divisor = gcd(horizontal, vertical)
        return (horizontal / divisor, vertical / divisor)
    }

    private static func gcd(_ lhs: Int, _ rhs: Int) -> Int {
        rhs == 0 ? max(lhs, 1) : gcd(rhs, lhs % rhs)
    }
}
