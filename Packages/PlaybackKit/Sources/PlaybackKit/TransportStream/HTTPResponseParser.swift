//
//  HTTPResponseParser.swift
//  PlaybackKit
//
//  A minimal, bounds-checked HTTP/1.1 response reader for streaming bodies: status line and headers, then either
//  chunked or close-delimited/length-delimited body bytes. Input is untrusted, so every size is capped.
//

import Foundation

nonisolated struct HTTPResponseParser {
    enum Output: Equatable {
        case head(status: Int, headers: [String: String])
        case body(Data)
        case end
    }

    enum ParseError: Error, Equatable {
        case headerTooLarge
        case malformedStatusLine
        case malformedChunk
    }

    static let maxHeaderBytes = 32 * 1_024

    private enum Phase {
        case head
        case body(remaining: Int64?)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkTrailer
        case done
    }

    private var phase = Phase.head
    private var buffer = Data()
    private var chunked = false

    /// Feeds received bytes; returns what became available.
    mutating func feed(_ data: Data) throws -> [Output] {
        buffer.append(data)
        var output: [Output] = []
        while let next = try step() { output.append(next) }
        return output
    }

    private mutating func step() throws -> Output? {
        switch phase {
        case .head:
            return try parseHead()
        case .body(let remaining):
            return bodyStep(remaining: remaining)
        case .chunkSize:
            return try chunkSizeStep()
        case .chunkData(let remaining):
            return try chunkDataStep(remaining: remaining)
        case .chunkTrailer:
            guard let line = takeLine() else { return nil }
            if line.isEmpty {
                phase = .done
                return .end
            }
            return try step()
        case .done:
            return nil
        }
    }

    private mutating func parseHead() throws -> Output? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > Self.maxHeaderBytes { throw ParseError.headerTooLarge }
            return nil
        }
        guard let headText = String(bytes: buffer[buffer.startIndex..<range.lowerBound], encoding: .isoLatin1) else {
            throw ParseError.malformedStatusLine
        }
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        var lines = headText.components(separatedBy: "\r\n")
        let statusParts = lines.removeFirst().split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw ParseError.malformedStatusLine
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        if chunked {
            phase = .chunkSize
        } else {
            phase = .body(remaining: headers["content-length"].flatMap { Int64($0) })
        }
        return .head(status: status, headers: headers)
    }

    private mutating func bodyStep(remaining: Int64?) -> Output? {
        if remaining == 0 {
            phase = .done
            return .end
        }
        guard !buffer.isEmpty else { return nil }
        let take = remaining.map { Int(min(Int64(buffer.count), $0)) } ?? buffer.count
        let piece = buffer.prefix(take)
        buffer.removeFirst(take)
        phase = .body(remaining: remaining.map { $0 - Int64(take) })
        return .body(Data(piece))
    }

    private mutating func chunkSizeStep() throws -> Output? {
        guard let line = takeLine() else {
            if buffer.count > 1_024 { throw ParseError.malformedChunk }
            return nil
        }
        let hex = line.split(separator: ";").first.map(String.init) ?? ""
        guard let size = Int(hex.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0,
              size <= 64 << 20 else { throw ParseError.malformedChunk }
        phase = size == 0 ? .chunkTrailer : .chunkData(remaining: size)
        return try step()
    }

    private mutating func chunkDataStep(remaining: Int) throws -> Output? {
        if remaining == 0 {
            guard buffer.count >= 2 else { return nil }
            buffer.removeFirst(2)
            phase = .chunkSize
            return try step()
        }
        guard !buffer.isEmpty else { return nil }
        let take = min(buffer.count, remaining)
        let piece = buffer.prefix(take)
        buffer.removeFirst(take)
        phase = .chunkData(remaining: remaining - take)
        return .body(Data(piece))
    }

    private mutating func takeLine() -> String? {
        guard let range = buffer.range(of: Data("\r\n".utf8)) else { return nil }
        let line = String(bytes: buffer[buffer.startIndex..<range.lowerBound], encoding: .isoLatin1) ?? ""
        buffer.removeSubrange(buffer.startIndex..<range.upperBound)
        return line
    }
}
