import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import MPEGTS
import Testing
import UniformTypeIdentifiers
@testable import PlaybackKit

#if os(macOS)
/// Opt-in, for looking at the deinterlacer's output: writes the woven source picture and both deinterlaced fields
/// of a few pictures of a local (gitignored) capture as PNGs. Never part of the CI gate; never commit the images.
///
///     PLAYBACKKIT_SNAPSHOT_DIR=/tmp/shots PLAYBACKKIT_SNAPSHOT_TS=/path/to/1080i.ts \
///         swift test --filter DeinterlacerSnapshot
struct DeinterlacerSnapshot {
    private nonisolated static let environment = ProcessInfo.processInfo.environment
    private nonisolated static let directory = environment["PLAYBACKKIT_SNAPSHOT_DIR"]
    /// Which pictures (display order) to write.
    private static let pictures: Set<Int> = [60, 150, 300]

    @Test(.enabled(if: directory != nil && environment["PLAYBACKKIT_SNAPSHOT_TS"] != nil))
    func writeFields() throws {
        let output = URL(fileURLWithPath: Self.directory ?? "")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.environment["PLAYBACKKIT_SNAPSHOT_TS"] ?? ""))
        let decoder = VideoDecoders.mpeg2()
        var reorder = FrameReorderBuffer()
        let deinterlacer = try #require(MetalDeinterlacer())
        var index = 0
        for picture in SyntheticVideoFixture.pictures(in: data) {
            for frame in try decoder.decode(picture.sample, info: picture.info).flatMap({ reorder.push($0) }) {
                let fields = deinterlacer.push(frame.finished()).map { $0.finished() }
                // Output trails input by one picture, so these fields belong to the previous picture.
                if Self.pictures.contains(index - 1), fields.count == 2 {
                    for (field, item) in fields.enumerated() {
                        let name = "\(index - 1)-\(field).png"
                        try Self.writePNG(#require(item.pixelBuffer), to: output.appendingPathComponent(name))
                    }
                }
                if Self.pictures.contains(index) {
                    let name = "\(index)-woven.png"
                    try Self.writePNG(#require(frame.pixelBuffer), to: output.appendingPathComponent(name))
                }
                index += 1
            }
        }
    }

    /// NV12 video range, BT.709, to sRGB-ish RGBA for viewing.
    private static func writePNG(_ buffer: CVPixelBuffer, to url: URL) throws {
        let luma = SyntheticPicture.plane(buffer, 0)
        let chroma = SyntheticPicture.plane(buffer, 1)
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for row in 0..<height {
            for column in 0..<width {
                let lumaValue = 1.164 * Double(luma[column, row] - 16)
                let blue = Double(chroma[2 * (column / 2), row / 2] - 128)
                let red = Double(chroma[2 * (column / 2) + 1, row / 2] - 128)
                let rgb = [lumaValue + 1.793 * red, lumaValue - 0.213 * blue - 0.533 * red, lumaValue + 2.112 * blue]
                for channel in 0..<3 {
                    pixels[(row * width + column) * 4 + channel] = UInt8(clamping: Int(rgb[channel].rounded()))
                }
            }
        }
        let context = try #require(CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                              bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                                       1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
#endif
