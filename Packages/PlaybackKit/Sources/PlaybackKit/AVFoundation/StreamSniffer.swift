//
//  StreamSniffer.swift
//  PlaybackKit
//
//  Names a stream's container from its first bytes, for URLs whose path says nothing (`URLKindDetector` returns
//  `.unknown`), such as IPTV and relay URLs like `/user/token/1234`. Only the bytes count: such servers often send a
//  Content-Type that is wrong (raw MPEG-TS as video/mp4).
//

import Foundation

public nonisolated enum StreamSniffer {
    /// Enough for four transport packets from any start, a manifest's first line or an MP4's first box.
    public static let prefixLength = 2 * 1_024
    /// How long a probe waits for the first bytes.
    public static let probeTimeout: Duration = .seconds(10)

    /// ISO BMFF box types an MP4, MOV or fragmented MP4 starts with.
    private static let isoBoxTypes: Set<String> = ["ftyp", "styp", "moov", "moof", "mdat", "free", "skip", "wide"]

    /// The container these first bytes start, or `.unknown` (which AVPlayer is left to make sense of).
    public static func kind(of prefix: Data) -> URLKind {
        let head = [UInt8](prefix.prefix(prefixLength))
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        if isTransportStream(head) { return .transportStream }
        if head.count >= 8, let type = String(bytes: head[4..<8], encoding: .ascii), isoBoxTypes.contains(type) {
            return .progressive
        }
        guard let text = String(bytes: head, encoding: .utf8) ?? String(bytes: head, encoding: .isoLatin1) else {
            return .unknown
        }
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        if trimmed.hasPrefix("#EXTM3U") { return .hls }
        if trimmed.hasPrefix("<"), trimmed.contains("<MPD") { return .dash }
        return .unknown
    }

    /// Four 188-byte packets in a row, from wherever the first bytes start (a live stream starts mid-packet).
    static func isTransportStream(_ head: [UInt8]) -> Bool {
        let size = 188
        guard head.count >= 4 * size else { return false }
        return (0..<min(size, head.count - 3 * size)).contains { start in
            (0..<4).allSatisfy { head[start + $0 * size] == 0x47 }
        }
    }

    /// The kind of the stream at an http(s) `url`, from one GET closed once its first bytes arrived; nil when none
    /// arrived within `probeTimeout` (the server failed, or nothing answered).
    @concurrent
    public static func probe(_ url: URL) async -> URLKind? {
        await probe(URLByteSource(url: url), timeout: probeTimeout)
    }

    @concurrent
    static func probe(_ source: any ByteSource, timeout: Duration) async -> URLKind? {
        defer { source.cancel() }
        return await withTaskGroup(of: URLKind?.self) { group in
            group.addTask { await read(source) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            // Ends a read still waiting for the server.
            source.cancel()
            return first
        }
    }

    @concurrent
    private static func read(_ source: any ByteSource) async -> URLKind? {
        guard let stream = try? await source.open() else { return nil }
        var head = Data()
        do {
            for try await chunk in stream {
                head.append(chunk.prefix(prefixLength - head.count))
                if head.count >= prefixLength { break }
            }
        } catch {
            guard !head.isEmpty else { return nil }
        }
        return head.isEmpty ? nil : kind(of: head)
    }
}
