//
//  SoftwareDecoderLibrary.swift
//  PlaybackKit
//
//  Facts about the software decoder library PlaybackKit links (FFmpeg's libavcodec and libavutil, LGPL-2.1), for
//  the About credit, the Diagnostics screen and the licence-assertion test.
//

import Foundation
import LibavMPEG2

nonisolated public enum SoftwareDecoderLibrary {
    /// The library's name as credited, for example "FFmpeg 9.0.2".
    public static var name: String {
        "FFmpeg " + String(cString: libav_ffmpeg_version())
    }

    /// libavcodec's version as "major.minor.micro".
    public static var codecVersion: String {
        let version = libav_codec_version()
        return "\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)"
    }

    /// The licence libavcodec and libavutil report, for example "LGPL version 2.1 or later".
    public static var license: String {
        String(cString: libav_codec_license())
    }

    /// libavutil's licence; it must match libavcodec's.
    public static var utilityLicense: String {
        String(cString: libav_util_license())
    }

    /// The configure line libavcodec was built with.
    public static var configuration: String {
        String(cString: libav_codec_configuration())
    }

    /// The configure line libavutil was built with.
    public static var utilityConfiguration: String {
        String(cString: libav_util_configuration())
    }

    /// The upstream source release the frameworks were built from, unmodified (LGPL-2.1 §6).
    public static var sourceURL: URL {
        URL(string: "https://ffmpeg.org/releases/ffmpeg-\(String(cString: libav_ffmpeg_version())).tar.xz")!
    }

    /// The full text of the GNU Lesser General Public License, version 2.1, bundled with PlaybackKit.
    public static var licenseText: String? {
        guard let url = Bundle.module.url(forResource: "LGPL-2.1", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
