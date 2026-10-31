//
//  EBMLTests.swift
//  MatroskaTests
//
//  Variable-length integers, element headers and values (RFC 8794), including what a damaged stream throws at them.
//

import Foundation
@testable import Matroska
import Testing

struct EBMLTests {
    private func read<T>(_ bytes: [UInt8], _ body: (UnsafeBufferPointer<UInt8>) -> T) -> T {
        bytes.withUnsafeBufferPointer(body)
    }

    @Test func variableIntegersOfEveryLength() {
        let cases: [([UInt8], EBML.VariableInteger)] = [
            ([0x81], EBML.VariableInteger(value: 1, length: 1, isAllOnes: false)),
            ([0x40, 0x02], EBML.VariableInteger(value: 2, length: 2, isAllOnes: false)),
            ([0x20, 0x01, 0x00], EBML.VariableInteger(value: 256, length: 3, isAllOnes: false)),
            ([0x01, 0, 0, 0, 0, 0, 0, 0x05], EBML.VariableInteger(value: 5, length: 8, isAllOnes: false))
        ]
        for (bytes, expected) in cases {
            #expect(read(bytes) { EBML.variableInteger($0, at: 0) } == expected)
        }
        #expect(read([0xFF]) { EBML.variableInteger($0, at: 0) }?.isAllOnes == true)
        #expect(read(EBMLAll.unknown) { EBML.variableInteger($0, at: 0) }?.isAllOnes == true)
        // A zero first byte would mean more than eight bytes; a short buffer is incomplete.
        #expect(read([0x00, 0x81]) { EBML.variableInteger($0, at: 0) } == nil)
        #expect(read([0x40]) { EBML.variableInteger($0, at: 0) } == nil)
        #expect(read([0x81]) { EBML.variableInteger($0, at: 1) } == nil)
    }

    @Test func signedVariableIntegersAreBiased() {
        #expect(read([0xBF]) { EBML.signedVariableInteger($0, at: 0) }?.value == 0)
        #expect(read([0xC0]) { EBML.signedVariableInteger($0, at: 0) }?.value == 1)
        #expect(read([0x80]) { EBML.signedVariableInteger($0, at: 0) }?.value == -63)
        #expect(read([0x5F, 0xFF]) { EBML.signedVariableInteger($0, at: 0) }?.value == 0)
    }

    @Test func headersKnownUnknownIncompleteAndInvalid() {
        let segment: [UInt8] = [0x18, 0x53, 0x80, 0x67] + EBMLAll.unknown
        #expect(read(segment) { EBML.header($0, at: 0) }
            == .header(EBMLElementHeader(id: 0x18538067, size: nil, headerLength: 12)))
        #expect(read([0xA3, 0x84]) { EBML.header($0, at: 0) }
            == .header(EBMLElementHeader(id: 0xA3, size: 4, headerLength: 2)))
        #expect(read([0x18, 0x53]) { EBML.header($0, at: 0) } == .incomplete)
        #expect(read([0xA3]) { EBML.header($0, at: 0) } == .incomplete)
        #expect(read([0xA3, 0x40]) { EBML.header($0, at: 0) } == .incomplete)
        // IDs are at most four bytes, and a size's first byte is never zero.
        #expect(read([0x08, 1, 2, 3, 4, 0x81]) { EBML.header($0, at: 0) } == .invalid)
        #expect(read([0x00, 0x81]) { EBML.header($0, at: 0) } == .invalid)
        #expect(read([0xA3, 0x00, 0x81]) { EBML.header($0, at: 0) } == .invalid)
    }

    @Test func values() {
        #expect(read([]) { EBML.unsigned($0) } == 0)
        #expect(read([0x01, 0x00]) { EBML.unsigned($0) } == 256)
        #expect(read([UInt8](repeating: 0, count: 9)) { EBML.unsigned($0) } == nil)
        #expect(read([0xFF]) { EBML.signed($0) } == -1)
        #expect(read([0xFF, 0xFE]) { EBML.signed($0) } == -2)
        #expect(read([0x7F]) { EBML.signed($0) } == 127)
        #expect(read(withUnsafeBytes(of: Float(2.5).bitPattern.bigEndian, Array.init)) { EBML.float($0) } == 2.5)
        #expect(read(withUnsafeBytes(of: 1234.5.bitPattern.bigEndian, Array.init)) { EBML.float($0) } == 1234.5)
        #expect(read([1, 2, 3]) { EBML.float($0) } == nil)
        #expect(read(Array("eng".utf8) + [0, 0]) { EBML.string($0) } == "eng")
    }

    @Test func childrenStopAtDamage() {
        let bytes: [UInt8] = [0xD7, 0x81, 0x01, 0x83, 0x81, 0x02, 0x86, 0x85, 0x41]
        let ids = read(bytes) { pointer in EBMLChildren(pointer).map(\.id) }
        #expect(ids == [0xD7, 0x83])
    }
}

private enum EBMLAll {
    static let unknown: [UInt8] = [0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
}
