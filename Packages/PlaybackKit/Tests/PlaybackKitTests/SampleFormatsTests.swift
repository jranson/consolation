//
//  SampleFormatsTests.swift
//  PlaybackKitTests
//

import CoreMedia
import Foundation
import Testing
@testable import PlaybackKit

struct SampleFormatsTests {
    /// Audio frames are copied straight into one pooled block, each described by its own packet.
    @Test func audioSampleHoldsEachFrameInPlace() throws {
        let frames = [Data([1, 2, 3]), Data([4, 5, 6, 7, 8]), Data([9])]
        let format = try #require(SampleFormats.dolbyAudio(sampleRate: 48_000, channels: 2, isEAC3: false,
                                                           samplesPerFrame: 1_536))
        let pool = SampleMemoryPool()
        let sample = try #require(SampleFormats.audioSample(frames: frames, format: format, pts: 9_000, pool: pool))
        #expect(CMSampleBufferGetNumSamples(sample) == 3)
        #expect(CMSampleBufferGetPresentationTimeStamp(sample).value == 9_000)
        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes) == noErr)
        #expect(bytes == Array(1...9))
        var descriptions: UnsafePointer<AudioStreamPacketDescription>?
        var count = 0
        #expect(CMSampleBufferGetAudioStreamPacketDescriptionsPtr(
            sample, packetDescriptionsPointerOut: &descriptions, sizeOut: &count) == noErr)
        let stride = MemoryLayout<AudioStreamPacketDescription>.stride
        let packets = UnsafeBufferPointer(start: descriptions, count: count / stride)
        #expect(packets.map(\.mStartOffset) == [0, 3, 8])
        #expect(packets.map(\.mDataByteSize) == [3, 5, 1])
    }

    /// Pooled blocks hold what was copied in; the pool outliving or not outliving them doesn't matter.
    @Test func pooledBlocksOutliveTheirPool() throws {
        var pool: SampleMemoryPool? = SampleMemoryPool()
        let bytes = [UInt8](0..<200)
        let block = try #require(bytes.withUnsafeBytes {
            SampleFormats.blockBuffer(copying: $0, padding: LibavVideoDecoder.inputPadding, pool: pool)
        })
        pool = nil
        var copy = [UInt8](repeating: 0xFF, count: 200 + LibavVideoDecoder.inputPadding)
        #expect(CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: copy.count, destination: &copy) == noErr)
        #expect(Array(copy[..<200]) == bytes)
        #expect(copy[200...].allSatisfy { $0 == 0 })
    }
}
