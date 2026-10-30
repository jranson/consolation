import CoreVideo
import Foundation
import Metal
import Testing
@testable import PlaybackKit

/// The v2 deinterlacer on synthetic pictures: still pictures weave back exactly, moving ones don't comb, and the
/// field timing and progressive passthrough are kept.
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
struct MetalDeinterlacerTests {
    private static let width = 256
    private static let height = 128
    private static let duration: Int64 = 3_003

    /// Detail at several scales: 4-line bands, a vertical gradient, soft diagonals, and two-line stripes.
    private static let still = SyntheticPicture(
        luma: { column, row in
            let bands = (row / 4) % 2 == 0 ? 40 : 0
            let stripes = column >= 192 ? ((row / 2) % 2 == 0 ? 120 : 0) : 0
            let diagonal = Int(40 * (1 + sin(Double(column + row) / 9)))
            return UInt8(clamping: 30 + bands + row / 2 + diagonal + stripes)
        },
        chroma: { column, row in (UInt8(clamping: 90 + column / 2), UInt8(clamping: 160 - row)) })

    /// A bright bar on a vertical gradient, moving right 6 pixels per field; field `time` counts fields.
    private static func moving(at time: Int) -> SyntheticPicture {
        let left = 40 + 6 * time
        return SyntheticPicture(
            luma: { column, row in (left..<(left + 48)).contains(column) ? 210 : UInt8(30 + row / 4) },
            chroma: { column, _ in (left / 2..<(left + 48) / 2).contains(column) ? (80, 180) : (128, 128) })
    }

    /// How the test pictures reach the deinterlacer: NV12 buffers (VideoToolbox, the CPU copy) or libavcodec's planar
    /// memory read in place.
    enum Input: CaseIterable {
        case nv12
        case planar
    }

    private func frame(_ picture: SyntheticPicture, index: Int, interlaced: Bool = true,
                       input: Input = .nv12) throws -> DecodedFrame {
        let pts = Int64(index) * Self.duration
        switch input {
        case .nv12:
            let buffer = try #require(picture.pixelBuffer(width: Self.width, height: Self.height))
            return DecodedFrame(pixelBuffer: buffer, pts: pts, duration: Self.duration, isInterlaced: interlaced,
                                topFieldFirst: true)
        case .planar:
            let device = try #require(MTLCreateSystemDefaultDevice())
            let planar = try #require(picture.planar(width: Self.width, height: Self.height, device: device,
                                                     interlaced: interlaced))
            return DecodedFrame(planar: planar, pts: pts, duration: Self.duration, isInterlaced: interlaced,
                                topFieldFirst: true)
        }
    }

    private func run(_ frames: [DecodedFrame]) throws -> [DecodedFrame] {
        let deinterlacer = try #require(MetalDeinterlacer())
        return (frames.flatMap { deinterlacer.push($0) } + deinterlacer.drain()).map { $0.finished() }
    }

    private func expectIdentical(_ output: DecodedFrame, _ source: CVPixelBuffer, _ comment: Comment? = nil) {
        for plane in 0..<2 {
            let difference = SyntheticPicture.maxDifference(SyntheticPicture.plane(output.pixelBuffer, plane),
                                                            SyntheticPicture.plane(source, plane))
            #expect(difference == 0, "plane \(plane) differs by \(difference)")
        }
    }

    @Test(arguments: Input.allCases)
    func stillPictureWeavesBackExactly(input: Input) throws {
        let frames = try (0..<4).map { try frame(Self.still, index: $0, input: input) }
        let outputs = try run(frames)
        #expect(outputs.count == 8)
        let source = try #require(Self.still.pixelBuffer(width: Self.width, height: Self.height))
        for output in outputs { expectIdentical(output, source) }
    }

    /// A window mixing planar and NV12 pictures (a picture the decoder had to copy) converts and still weaves.
    @Test func mixedWindowWeavesBackExactly() throws {
        let frames = try (0..<4).map { try frame(Self.still, index: $0, input: $0 == 1 ? .nv12 : .planar) }
        let outputs = try run(frames)
        #expect(outputs.count == 8)
        let source = try #require(Self.still.pixelBuffer(width: Self.width, height: Self.height))
        for output in outputs { expectIdentical(output, source) }
    }

    private static func movingFrame(_ index: Int) -> SyntheticPicture {
        .woven(moving(at: 2 * index), moving(at: 2 * index + 1), firstParity: 0)
    }

    @Test(arguments: Input.allCases)
    func movingBarDoesNotComb(input: Input) throws {
        let frames = try (0..<6).map { try frame(Self.movingFrame($0), index: $0, input: input) }
        // Weaving the two fields would comb every line along both edges of the bar.
        let woven = SyntheticPicture.plane(Self.movingFrame(1).pixelBuffer(width: Self.width, height: Self.height), 0)
        #expect(SyntheticPicture.combTeeth(in: woven) > Self.height * 6)
        let outputs = try run(frames)
        #expect(outputs.count == 12)
        for (time, output) in outputs.enumerated() {
            let truth = try #require(Self.moving(at: time).pixelBuffer(width: Self.width, height: Self.height))
            let luma = SyntheticPicture.plane(output.pixelBuffer, 0)
            let chroma = SyntheticPicture.plane(output.pixelBuffer, 1)
            #expect(SyntheticPicture.combTeeth(in: luma) == 0, "field \(time) combs")
            #expect(SyntheticPicture.combTeeth(in: chroma, step: 2) == 0, "field \(time) combs in chroma")
            let error = SyntheticPicture.meanDifference(luma, SyntheticPicture.plane(truth, 0))
            #expect(error < 1, "field \(time) is \(error) from the true picture")
        }
    }

    /// Reading libavcodec's planes in place gives exactly what deinterlacing their NV12 conversion gave.
    @Test func planarInputMatchesNV12Exactly() throws {
        let nv12 = try run((0..<4).map { try frame(Self.movingFrame($0), index: $0, input: .nv12) })
        let planar = try run((0..<4).map { try frame(Self.movingFrame($0), index: $0, input: .planar) })
        #expect(nv12.count == planar.count)
        for (lhs, rhs) in zip(nv12, planar) {
            for plane in 0..<2 {
                let expected = SyntheticPicture.plane(lhs.pixelBuffer, plane)
                #expect(SyntheticPicture.plane(rhs.pixelBuffer, plane) == expected)
            }
        }
    }

    @Test func fieldsAreTimedAtFieldRateAndOrderedByParity() throws {
        let frames = try (0..<3).map { try frame(Self.still, index: $0) }
        let outputs = try run(frames)
        #expect(outputs.map(\.pts) == [0, 1_501, 3_003, 4_504, 6_006, 7_507])
        #expect(outputs.map(\.duration) == [1_501, 1_502, 1_501, 1_502, 1_501, 1_502])
        #expect(outputs.allSatisfy { !$0.isInterlaced })
    }

    @Test func progressivePicturesPassThrough() throws {
        let frames = try (0..<3).map { try frame(Self.still, index: $0, interlaced: false) }
        let outputs = try run(frames)
        #expect(outputs.count == 3)
        #expect(zip(outputs, frames).allSatisfy { $0.pixelBuffer === $1.pixelBuffer })
    }

    /// Planar progressive pictures come out as NV12 buffers with the same pixels, one conversion each.
    @Test func planarProgressivePicturesAreConverted() throws {
        let frames = try (0..<3).map { try frame(Self.still, index: $0, interlaced: false, input: .planar) }
        let outputs = try run(frames)
        #expect(outputs.map(\.pts) == frames.map(\.pts))
        let source = try #require(Self.still.pixelBuffer(width: Self.width, height: Self.height))
        for output in outputs { expectIdentical(output, source) }
    }

    // MARK: Bob (multi-view grid tiles)

    private func runBob(_ frames: [DecodedFrame]) throws -> [DecodedFrame] {
        let deinterlacer = try #require(MetalDeinterlacer())
        deinterlacer.mode = .bob
        return (frames.flatMap { deinterlacer.push($0) } + deinterlacer.drain()).map { $0.finished() }
    }

    /// Rows `parity`, `parity + 2`, ... of a plane.
    private static func rows(_ plane: SyntheticPicture.Plane, parity: Int) -> [[UInt8]] {
        stride(from: parity, to: plane.rows.count, by: 2).map { plane.rows[$0] }
    }

    /// One full-size progressive picture per frame, at the frame's time, each out as soon as its frame went in; the
    /// first field's lines are kept exactly.
    @Test(arguments: Input.allCases)
    func bobShowsOneFullSizePicturePerFrame(input: Input) throws {
        let deinterlacer = try #require(MetalDeinterlacer())
        deinterlacer.mode = .bob
        let frames = try (0..<4).map { try frame(Self.still, index: $0, input: input) }
        var outputs: [DecodedFrame] = []
        for frame in frames {
            let ready = deinterlacer.push(frame).map { $0.finished() }
            #expect(ready.map(\.pts) == [frame.pts])
            outputs += ready
        }
        #expect(deinterlacer.drain().isEmpty)
        #expect(outputs.map(\.duration) == frames.map(\.duration))
        let source = try #require(Self.still.pixelBuffer(width: Self.width, height: Self.height))
        for output in outputs {
            let buffer = try #require(output.pixelBuffer)
            #expect(CVPixelBufferGetWidth(buffer) == Self.width && CVPixelBufferGetHeight(buffer) == Self.height)
            #expect(!output.isInterlaced)
            for plane in 0..<2 {
                #expect(Self.rows(SyntheticPicture.plane(buffer, plane), parity: 0)
                        == Self.rows(SyntheticPicture.plane(source, plane), parity: 0), "plane \(plane)")
            }
        }
    }

    /// The moving bar bobbed from its first field: no comb teeth, close to the first field's true picture.
    @Test(arguments: Input.allCases)
    func bobOfMovingBarDoesNotComb(input: Input) throws {
        let frames = try (0..<4).map { try frame(Self.movingFrame($0), index: $0, input: input) }
        let outputs = try runBob(frames)
        #expect(outputs.count == frames.count)
        for (index, output) in outputs.enumerated() {
            let truth = try #require(Self.moving(at: 2 * index).pixelBuffer(width: Self.width, height: Self.height))
            let luma = SyntheticPicture.plane(output.pixelBuffer, 0)
            #expect(SyntheticPicture.combTeeth(in: luma) == 0)
            #expect(SyntheticPicture.combTeeth(in: SyntheticPicture.plane(output.pixelBuffer, 1), step: 2) == 0)
            #expect(SyntheticPicture.meanDifference(luma, SyntheticPicture.plane(truth, 0)) < 1)
        }
    }

    /// Switching between field rate and bob mid-stream neither repeats nor skips a picture.
    @Test func switchingModesKeepsEveryPictureOnce() throws {
        let deinterlacer = try #require(MetalDeinterlacer())
        let frames = try (0..<8).map { try frame(Self.still, index: $0, input: .planar) }
        var outputs: [DecodedFrame] = []
        for (index, frame) in frames.enumerated() {
            if index == 3 { deinterlacer.mode = .bob }
            if index == 6 { deinterlacer.mode = .fieldRate }
            outputs += deinterlacer.push(frame)
        }
        outputs += deinterlacer.drain()
        let times = outputs.map(\.pts)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
        #expect(Set(frames.map(\.pts)).isSubset(of: Set(times)))
        // Frames 0, 1 and 6, 7 at field rate (two each); 2 was waiting for its look-ahead when bob began, so it is
        // bobbed with 3, 4 and 5.
        #expect(times.count == 2 * 4 + 4)
    }
}
