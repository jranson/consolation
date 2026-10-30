//
//  MetalDeinterlacer.swift
//  PlaybackKit
//
//  The GPU stage after decoding. Turns interlaced pictures into progressive pictures at field rate (59.94 per second
//  for 1080i) with the motion-adaptive kernel in DeinterlaceShader (v2), and turns libavcodec's planar progressive
//  pictures into NV12 pixel buffers (MetalPlanarConverter). One command buffer per picture: both fields of an
//  interlaced picture (per field a luma pass, which also writes a motion map, and a chroma pass, which reads it), or
//  the one conversion pass.
//
//  Planar pictures are deinterlaced straight from libavcodec's memory, so interlaced streams have no conversion pass
//  at all. A window that mixes planar and NV12 pictures (a picture the decoder copied on the CPU), or a device whose
//  linear-texture alignment the decoder's planes don't meet, converts its planar pictures first in the same command
//  buffer and uses the NV12 kernels.
//
//  Keeps one picture of history and one of look-ahead, so output trails input by one picture.
//
//  Bob mode (multi-view grid and reduced-tier tiles, `mode = .bob`): one picture per frame instead of two, made from
//  the first field alone in one cheap pass per plane, and output at once (it needs no look-ahead). The window keeps
//  rolling in both modes, so switching mid-stream neither repeats nor skips a picture: a picture still waiting for
//  its look-ahead when bob starts is bobbed on the next push, and after bob ends the next picture waits as usual.
//

import CoreMedia
import CoreVideo
import Foundation
import Metal

nonisolated final class MetalDeinterlacer {
    /// How interlaced pictures become progressive ones.
    enum Mode: Sendable {
        /// Two pictures per frame (field rate) with the motion-adaptive kernel: the single or foreground tile.
        case fieldRate
        /// One picture per frame from the first field, line-interpolated to full height: grid tiles.
        case bob
    }

    let device: MTLDevice
    /// Takes effect from the next picture output; safe to change between any two pushes.
    var mode = Mode.fieldRate
    private let queue: MTLCommandQueue
    private let pipelines: Pipelines
    private let textureCache: CVMetalTextureCache
    private let converter: MetalPlanarConverter
    private var outputPool = NV12BufferPool()
    /// One motion map per field of a picture (luma width x field lines, 16-bit float).
    private var motionMaps: [MTLTexture] = []

    private var previous: DecodedFrame?
    private var current: DecodedFrame?
    /// `current` already went out (bob outputs a picture when it arrives).
    private var currentEmitted = false

    /// GPU time spent in this stage's passes that completed, for measurements.
    private let meter = GPUTimeMeter()
    private let retired = RetiredTextures()
    var gpuSeconds: Double { meter.seconds }
    /// Stage timings, when the owning `VideoFrameStage` collects them.
    var clock: VideoStageClock?

    /// The compute pipelines, from the shader source compiled twice (NV12 chroma, and planar Cb/Cr chroma).
    private struct Pipelines {
        let luma: MTLComputePipelineState
        let chroma: MTLComputePipelineState
        let planarChroma: MTLComputePipelineState
        let bobLuma: MTLComputePipelineState
        let bobChroma: MTLComputePipelineState
        let planarBobChroma: MTLComputePipelineState

        init?(device: MTLDevice) {
            let planarOptions = MTLCompileOptions()
            planarOptions.preprocessorMacros = ["PLANAR_CHROMA": NSNumber(value: 1)]
            guard let library = try? device.makeLibrary(source: DeinterlaceShader.source, options: nil),
                  let planar = try? device.makeLibrary(source: DeinterlaceShader.source, options: planarOptions)
            else { return nil }
            let make = { (library: MTLLibrary, name: String) -> MTLComputePipelineState? in
                library.makeFunction(name: name).flatMap { try? device.makeComputePipelineState(function: $0) }
            }
            guard let luma = make(library, "deinterlaceLuma"), let chroma = make(library, "deinterlaceChroma"),
                  let planarChroma = make(planar, "deinterlaceChroma"), let bobLuma = make(library, "bobLuma"),
                  let bobChroma = make(library, "bobChroma"), let planarBobChroma = make(planar, "bobChroma")
            else { return nil }
            let all = [luma, chroma, planarChroma, bobLuma, bobChroma, planarBobChroma]
            let tile = DeinterlaceShader.tileWidth * DeinterlaceShader.tileHeight
            guard all.allSatisfy({ $0.maxTotalThreadsPerThreadgroup >= tile }) else { return nil }
            (self.luma, self.chroma, self.planarChroma) = (luma, chroma, planarChroma)
            (self.bobLuma, self.bobChroma, self.planarBobChroma) = (bobLuma, bobChroma, planarBobChroma)
        }
    }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue(),
              let converter = MetalPlanarConverter(device: device),
              let pipelines = Pipelines(device: device) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            return nil
        }
        self.device = device
        self.queue = queue
        self.converter = converter
        self.pipelines = pipelines
        textureCache = cache
    }

    func reset() {
        previous = nil
        current = nil
        currentEmitted = false
    }

    /// Accepts the next picture in display order; returns the progressive pictures now ready, in order.
    func push(_ frame: DecodedFrame) -> [DecodedFrame] {
        var ready: [DecodedFrame] = []
        if let current, !currentEmitted {
            ready += output(for: current, previous: previous ?? current, next: frame)
        }
        previous = current
        current = frame
        currentEmitted = mode == .bob
        if currentEmitted { ready += output(for: frame, previous: previous ?? frame, next: frame) }
        return ready
    }

    /// Emits the held picture at the end of a stream.
    func drain() -> [DecodedFrame] {
        defer { reset() }
        guard let current, !currentEmitted else { return [] }
        return output(for: current, previous: previous ?? current, next: current)
    }

    private func output(for frame: DecodedFrame, previous: DecodedFrame, next: DecodedFrame) -> [DecodedFrame] {
        guard frame.isInterlaced else { return [converted(frame)] }
        if mode == .bob { return [bob(frame)] }
        let firstParity = frame.topFieldFirst ? 0 : 1
        // NV12 inputs may still be converting on another queue; that work was committed pictures ago, so this
        // normally returns at once.
        for input in [previous, frame, next] { waitForGPU(input.gpuWork, clock: clock) }
        let rendered = measure(\.deinterlaceSubmit, "Deinterlace") {
            render(previous: previous, current: frame, next: next, firstParity: firstParity)
        }
        guard let (buffers, commands) = rendered else { return [converted(frame)] }
        let half = frame.duration / 2
        return buffers.enumerated().map { field, buffer in
            DecodedFrame(pixelBuffer: buffer, pts: frame.pts + Int64(field) * half,
                         duration: field == 0 ? half : frame.duration - half,
                         isInterlaced: false, topFieldFirst: frame.topFieldFirst, gpuWork: commands)
        }
    }

    /// A planar picture as an NV12 pixel buffer, in a command buffer of its own; other pictures as they are.
    private func converted(_ frame: DecodedFrame) -> DecodedFrame {
        guard let planar = frame.planar else { return frame }
        return measure(\.conversionSubmit, "Convert") {
            retired.prune()
            guard let output = outputPool.make(width: planar.layout.width, height: planar.layout.height),
                  let commands = queue.makeCommandBufferWithUnretainedReferences(),
                  converter.encode(planar, into: output, commands: commands) else { return frame }
            PassResources([planar, output]).keep(until: commands)
            meter.track(commands)
            commands.commit()
            return DecodedFrame(pixelBuffer: output, pts: frame.pts, duration: frame.duration,
                                isInterlaced: frame.isInterlaced, topFieldFirst: frame.topFieldFirst,
                                gpuWork: commands)
        }
    }

    private func measure<Result>(_ stage: WritableKeyPath<VideoStageTimings, Double>, _ name: StaticString,
                                 _ body: () -> Result) -> Result {
        clock.map { $0.measure(stage, name, body) } ?? body()
    }

    /// One picture's planes as the kernels bind them: luma, and CbCr (NV12) or Cb then Cr (planar).
    private struct Source {
        let luma: MTLTexture
        let chroma: [MTLTexture]
    }

    /// Starts rendering both fields of `current` (the first with `firstParity`'s lines kept) into two new buffers;
    /// returns them with the committed command buffer, which the reader waits for.
    private func render(previous: DecodedFrame, current: DecodedFrame, next: DecodedFrame,
                        firstParity: Int) -> ([CVPixelBuffer], any MTLCommandBuffer)? {
        retired.prune()
        let (width, height) = current.size
        let window = [previous, current, next]
        guard window.allSatisfy({ $0.size == (width, height) }),
              let firstOutput = outputPool.make(width: width, height: height),
              let secondOutput = outputPool.make(width: width, height: height),
              let maps = motionMaps(width: width, height: height),
              let commands = queue.makeCommandBufferWithUnretainedReferences() else { return nil }
        var held: [AnyObject] = window.map(\.storage) + [firstOutput, secondOutput]
        var textures: [CVMetalTexture] = []
        let planar = planarSources(window)
        guard let sources = planar ?? nv12Sources(window, commands: commands, held: &held, textures: &textures),
              let firstTarget = nv12Source(firstOutput, textures: &textures),
              let secondTarget = nv12Source(secondOutput, textures: &textures),
              let encoder = commands.makeComputeCommandEncoder() else { return nil }
        let outputs = [firstTarget, secondTarget]
        let (earlier, present, later) = (sources[0], sources[1], sources[2])
        for field in 0..<2 {
            // Opposite field one field before and after: the first field sits between the previous picture's
            // second field and this picture's second; the second between this picture's first and the next's first.
            let inputs = field == 0 ? [earlier, present, present, earlier, later] : [present, present, later,
                                                                                       earlier, later]
            let parity = UInt32(field == 0 ? firstParity : 1 - firstParity)
            encode(encoder, FieldPass(pipeline: pipelines.luma, inputs: inputs.map { [$0.luma] },
                                      output: outputs[field].luma, map: maps[field], parity: parity))
            encode(encoder, FieldPass(pipeline: planar == nil ? pipelines.chroma : pipelines.planarChroma,
                                      inputs: inputs.map(\.chroma), output: outputs[field].chroma[0],
                                      map: maps[field], parity: parity))
        }
        encoder.endEncoding()
        // Unretained references: keep every picture, buffer and texture the pass touches until it completes.
        PassResources(held).keep(until: commands)
        meter.track(commands)
        commands.commit()
        retired.keep(textures, until: commands)
        let attachments = PixelBufferAttachments.progressive(Self.attachments(of: current))
        for output in [firstOutput, secondOutput] { PixelBufferAttachments.set(attachments, on: output) }
        return ([firstOutput, secondOutput], commands)
    }

    /// One picture from its first field (`Mode.bob`), in a command buffer of its own; the woven picture if Metal
    /// failed.
    private func bob(_ frame: DecodedFrame) -> DecodedFrame {
        waitForGPU(frame.gpuWork, clock: clock)
        let rendered: DecodedFrame? = measure(\.deinterlaceSubmit, "Bob") {
            retired.prune()
            let (width, height) = frame.size
            guard let output = outputPool.make(width: width, height: height),
                  let commands = queue.makeCommandBufferWithUnretainedReferences() else { return nil }
            var held: [AnyObject] = [frame.storage, output]
            var textures: [CVMetalTexture] = []
            let planar = planarSources([frame])
            guard let source = (planar ?? nv12Sources([frame], commands: commands, held: &held,
                                                      textures: &textures))?.first,
                  let target = nv12Source(output, textures: &textures),
                  let encoder = commands.makeComputeCommandEncoder() else { return nil }
            let parity = UInt32(frame.topFieldFirst ? 0 : 1)
            encodeBob(encoder, pipelines.bobLuma, inputs: [source.luma], output: target.luma, parity: parity)
            encodeBob(encoder, planar == nil ? pipelines.bobChroma : pipelines.planarBobChroma,
                      inputs: source.chroma, output: target.chroma[0], parity: parity)
            encoder.endEncoding()
            PassResources(held).keep(until: commands)
            meter.track(commands)
            commands.commit()
            retired.keep(textures, until: commands)
            PixelBufferAttachments.set(PixelBufferAttachments.progressive(Self.attachments(of: frame)), on: output)
            return DecodedFrame(pixelBuffer: output, pts: frame.pts, duration: frame.duration, isInterlaced: false,
                                topFieldFirst: frame.topFieldFirst, gpuWork: commands)
        }
        return rendered ?? converted(frame)
    }

    /// Binds one bob pass: the source plane (or Cb) at 0, the output at 1, Cr at 2 for planar chroma; one thread per
    /// output sample.
    private func encodeBob(_ encoder: any MTLComputeCommandEncoder, _ pipeline: MTLComputePipelineState,
                           inputs: [MTLTexture], output: MTLTexture, parity: UInt32) {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(inputs[0], index: 0)
        encoder.setTexture(output, index: 1)
        if inputs.count == 2 { encoder.setTexture(inputs[1], index: 2) }
        var parity = parity
        encoder.setBytes(&parity, length: MemoryLayout<UInt32>.size, index: 0)
        encoder.dispatchThreads(MTLSize(width: output.width, height: output.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: DeinterlaceShader.tileWidth,
                                                               height: DeinterlaceShader.tileHeight, depth: 1))
    }

    /// One field's luma or chroma pass.
    private struct FieldPass {
        let pipeline: MTLComputePipelineState
        /// Per input picture (before, current, after, earlier, later): its plane, or its Cb and Cr planes.
        let inputs: [[MTLTexture]]
        let output: MTLTexture
        let map: MTLTexture
        /// The lines kept from the current picture.
        let parity: UInt32
    }

    /// Binds one field's pass: the five inputs' first planes at 0-4, the output at 5, the motion map at 6 and, for
    /// planar chroma, the inputs' Cr planes at 7-11; one thread per field-line pair of the output plane.
    private func encode(_ encoder: any MTLComputeCommandEncoder, _ pass: FieldPass) {
        encoder.setComputePipelineState(pass.pipeline)
        encoder.setTextures(pass.inputs.map { $0[0] } + [pass.output, pass.map], range: 0..<7)
        if pass.inputs.allSatisfy({ $0.count == 2 }) { encoder.setTextures(pass.inputs.map { $0[1] }, range: 7..<12) }
        var parity = pass.parity
        encoder.setBytes(&parity, length: MemoryLayout<UInt32>.size, index: 0)
        let pairs = (pass.output.height + 1) / 2
        let tile = MTLSize(width: DeinterlaceShader.tileWidth, height: DeinterlaceShader.tileHeight, depth: 1)
        let groups = MTLSize(width: (pass.output.width + tile.width - 1) / tile.width,
                             height: (pairs + tile.height - 1) / tile.height, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: tile)
    }

    /// The window read in place, when every picture is planar and the device can map its planes.
    private func planarSources(_ window: [DecodedFrame]) -> [Source]? {
        let planes = window.compactMap { $0.planar?.textures() }
        guard planes.count == window.count else { return nil }
        return planes.map { Source(luma: $0.luma, chroma: [$0.blue, $0.red]) }
    }

    /// The window as NV12 textures, converting planar pictures into new buffers first (in `commands`).
    private func nv12Sources(_ window: [DecodedFrame], commands: any MTLCommandBuffer, held: inout [AnyObject],
                             textures: inout [CVMetalTexture]) -> [Source]? {
        var sources: [Source] = []
        for frame in window {
            var buffer = frame.pixelBuffer
            if let planar = frame.planar, let converted = outputPool.make(width: planar.layout.width,
                                                                          height: planar.layout.height),
               converter.encode(planar, into: converted, commands: commands) {
                buffer = converted
                held.append(converted)
            }
            guard let buffer, let source = nv12Source(buffer, textures: &textures) else { return nil }
            sources.append(source)
        }
        return sources
    }

    private func nv12Source(_ buffer: CVPixelBuffer, textures: inout [CVMetalTexture]) -> Source? {
        guard let luma = texture(buffer, plane: 0, format: .r8Unorm),
              let chroma = texture(buffer, plane: 1, format: .rg8Unorm),
              let lumaTexture = CVMetalTextureGetTexture(luma),
              let chromaTexture = CVMetalTextureGetTexture(chroma) else { return nil }
        textures += [luma, chroma]
        return Source(luma: lumaTexture, chroma: [chromaTexture])
    }

    /// The colour and aspect attachments the outputs of `frame` get.
    private static func attachments(of frame: DecodedFrame) -> [CFString: Any] {
        switch frame.image {
        case .planar(let picture): picture.attachments
        case .pixelBuffer(let buffer): CVBufferCopyAttachments(buffer, .shouldPropagate) as? [CFString: Any] ?? [:]
        }
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    private func motionMaps(width: Int, height: Int) -> [MTLTexture]? {
        let pairs = (height + 1) / 2
        if let first = motionMaps.first, first.width == width, first.height == pairs { return motionMaps }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Float, width: width,
                                                                  height: pairs, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        let maps = (0..<2).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        guard maps.count == 2 else { return nil }
        motionMaps = maps
        return maps
    }
}
