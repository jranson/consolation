//
//  SyntheticMatroska.swift
//  PlaybackKitTests
//
//  Matroska files around the H.264 pictures SyntheticNALStream encodes in the test (a moving gradient): the Annex-B
//  pictures become length-prefixed samples with an `avcC` CodecPrivate, as mkvmerge and FFmpeg write them.
//

import CoreMedia
import Foundation
import MatroskaTestSupport

#if os(macOS)
nonisolated enum SyntheticMatroska {
    /// An H.264 file of `frames` pictures (a Cluster per keyframe, Cues after the Clusters), with `extraTracks`
    /// listed after the video (their frames, if any, in `extraFrames`). Nil without an H.264 encoder.
    static func h264(frames: Int = 90, keyframeInterval: Int = 30, extraTracks: [MatroskaTestTrack] = [],
                     extraFrames: [MatroskaTestFrame] = []) -> MatroskaTestFile? {
        guard let pictures = SyntheticNALStream.encode(kCMVideoCodecType_H264, frames: frames,
                                                       keyframeInterval: keyframeInterval) else { return nil }
        var parameterSets: [[UInt8]] = []
        var videoFrames: [MatroskaTestFrame] = []
        for picture in pictures {
            var sample: [UInt8] = []
            for unit in nalUnits(picture.annexB) {
                switch unit[0] & 0x1F {
                case 9: continue
                case 7, 8: if parameterSets.count < 2 { parameterSets.append(unit) }
                default:
                    let size = UInt32(unit.count).bigEndian
                    sample += withUnsafeBytes(of: size, Array.init) + unit
                }
            }
            let milliseconds = (picture.pts - SyntheticNALStream.firstPTS) / 90
            videoFrames.append(MatroskaTestFrame(track: 1, timestamp: milliseconds, isKeyframe: picture.isKeyframe,
                                                 data: sample))
        }
        guard parameterSets.count == 2 else { return nil }
        var video = MatroskaTestTrack(number: 1, type: 1, codecID: "V_MPEG4/ISO/AVC",
                                      codecPrivate: avcC(sps: parameterSets[0], pps: parameterSets[1]))
        video.defaultDuration = 33_366_667
        let duration = Double(frames) * 1_001 / 30
        var file = MatroskaTestFile(tracks: [video] + extraTracks, frames: merge(videoFrames, extraFrames),
                                    durationMilliseconds: duration)
        file.write()
        return file
    }

    /// The NAL units of an Annex-B stream with four-byte start codes.
    static func nalUnits(_ bytes: [UInt8]) -> [[UInt8]] {
        var starts: [Int] = []
        var index = 0
        while index + 4 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                starts.append(index + 4)
                index += 4
            } else {
                index += 1
            }
        }
        return starts.enumerated().map { position, start in
            let end = position + 1 < starts.count ? starts[position + 1] - 4 : bytes.count
            return Array(bytes[start..<end])
        }
    }

    static func avcC(sps: [UInt8], pps: [UInt8]) -> [UInt8] {
        [1, sps[1], sps[2], sps[3], 0xFF, 0xE1, UInt8(sps.count >> 8), UInt8(sps.count & 0xFF)] + sps
            + [1, UInt8(pps.count >> 8), UInt8(pps.count & 0xFF)] + pps
    }

    /// Other tracks' frames placed after the video frame they follow in time.
    private static func merge(_ video: [MatroskaTestFrame], _ other: [MatroskaTestFrame]) -> [MatroskaTestFrame] {
        var merged: [MatroskaTestFrame] = []
        var pending = other.sorted { $0.timestamp < $1.timestamp }[...]
        for frame in video {
            merged.append(frame)
            while let next = pending.first, next.timestamp <= frame.timestamp {
                merged.append(next)
                pending = pending.dropFirst()
            }
        }
        return merged + pending
    }
}
#endif
