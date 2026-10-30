//
//  MetalPlanarConverter.swift
//  PlaybackKit
//
//  Turns a `PlanarPicture` (libavcodec's planar Y'CbCr, read in place) into an IOSurface NV12 pixel buffer with one
//  Metal compute pass, so no CPU copy is made. Progressive pictures need only this pass; interlaced ones skip it,
//  because the deinterlacer reads the planes directly. The pass is encoded into the caller's command buffer (the GPU
//  stage does one command buffer per picture), or `convert` commits its own.
//

import CoreVideo
import Foundation
import Metal

nonisolated final class MetalPlanarConverter {
    /// Mirrors `ConvertParams` in the shader (all 32-bit).
    private struct Params {
        var lumaOffset: UInt32
        var blueOffset: UInt32
        var redOffset: UInt32
        var lumaStride: UInt32
        var chromaStride: UInt32
        var chromaRowStep: UInt32
    }

    let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private lazy var queue = device.makeCommandQueue()

    /// Pictures converted, and the GPU time of the passes `convert` committed, for tests and measurements.
    private(set) var conversions = 0
    private let meter = GPUTimeMeter()
    private let retired = RetiredTextures()
    var gpuSeconds: Double { meter.seconds }

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "planarToNV12"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else {
            return nil
        }
        self.device = device
        self.pipeline = pipeline
        textureCache = cache
    }

    /// Encodes the conversion of `picture` into `output` (an NV12 IOSurface buffer of the picture's size) and sets
    /// the picture's attachments on it. The caller commits `commands` and keeps `picture` and `output` alive until it
    /// completes. False if Metal failed; nothing was encoded.
    func encode(_ picture: PlanarPicture, into output: CVPixelBuffer, commands: any MTLCommandBuffer) -> Bool {
        retired.prune()
        guard let luma = texture(output, plane: 0, format: .r8Unorm),
              let chroma = texture(output, plane: 1, format: .rg8Unorm),
              let encoder = commands.makeComputeCommandEncoder() else { return false }
        let layout = picture.layout
        var params = Params(lumaOffset: UInt32(layout.lumaOffset), blueOffset: UInt32(layout.blueOffset),
                            redOffset: UInt32(layout.redOffset), lumaStride: UInt32(layout.lumaStride),
                            chromaStride: UInt32(layout.chromaStride), chromaRowStep: UInt32(layout.chromaRowStep))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(picture.buffer, offset: 0, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.size, index: 1)
        encoder.setTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setTexture(CVMetalTextureGetTexture(chroma), index: 1)
        let grid = MTLSize(width: CVPixelBufferGetWidthOfPlane(output, 1),
                           height: CVPixelBufferGetHeightOfPlane(output, 1), depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: MTLSize(width: 32, height: 8, depth: 1))
        encoder.endEncoding()
        retired.keep([luma, chroma], until: commands)
        PixelBufferAttachments.set(picture.attachments, on: output)
        conversions += 1
        return true
    }

    /// Converts `picture` into `output` in a command buffer of its own and returns it committed, without waiting;
    /// the picture and the output stay alive until it completes. Nil if Metal failed.
    func convert(_ picture: PlanarPicture, into output: CVPixelBuffer) -> (any MTLCommandBuffer)? {
        guard let commands = queue?.makeCommandBufferWithUnretainedReferences(),
              encode(picture, into: output, commands: commands) else { return nil }
        PassResources([picture, output]).keep(until: commands)
        meter.track(commands)
        commands.commit()
        return commands
    }

    private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format, CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane), plane, &texture)
        return status == kCVReturnSuccess ? texture : nil
    }

    /// One thread per chroma sample: copies its 2x2 luma block and interleaves its Cb and Cr into one CbCr pair.
    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct ConvertParams {
        uint lumaOffset;
        uint blueOffset;
        uint redOffset;
        uint lumaStride;
        uint chromaStride;
        uint chromaRowStep;
    };

    kernel void planarToNV12(device const uchar *planes [[buffer(0)]],
                             constant ConvertParams &params [[buffer(1)]],
                             texture2d<half, access::write> luma [[texture(0)]],
                             texture2d<half, access::write> chroma [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= chroma.get_width() || gid.y >= chroma.get_height()) { return; }
        uint lumaWidth = luma.get_width();
        uint lumaHeight = luma.get_height();
        for (uint row = 0; row < 2; row++) {
            uint y = gid.y * 2 + row;
            if (y >= lumaHeight) { break; }
            device const uchar *line = planes + params.lumaOffset + y * params.lumaStride;
            for (uint column = 0; column < 2; column++) {
                uint x = gid.x * 2 + column;
                if (x < lumaWidth) { luma.write(half4(half(line[x]) / 255.0h), uint2(x, y)); }
            }
        }
        uint chromaRow = gid.y * params.chromaRowStep * params.chromaStride + gid.x;
        half blue = half(planes[params.blueOffset + chromaRow]) / 255.0h;
        half red = half(planes[params.redOffset + chromaRow]) / 255.0h;
        chroma.write(half4(blue, red, 0.0h, 1.0h), gid);
    }
    """
}
