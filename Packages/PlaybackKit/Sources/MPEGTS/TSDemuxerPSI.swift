//
//  TSDemuxerPSI.swift
//  MPEGTS
//
//  PAT/PMT tracking for `TSDemuxer`: section assembly per PSI PID, CRC and version checks, the program list and the
//  PID-to-assembler map. PIDs are never hard-coded; everything follows the PAT.
//

/// PAT and PMT state. Sections whose CRC matches the last accepted one for the same table are skipped cheaply.
nonisolated struct PSIState {
    var patAssembler = SectionAssembler()
    var pmtAssemblers: [UInt16: SectionAssembler] = [:]
    var patVersion: UInt8?
    /// PAT entries per section_number, so multi-section PATs are merged.
    var patSections: [UInt8: [PATEntry]] = [:]
    var patCRCs: [UInt8: UInt32] = [:]
    /// The merged PAT, in section order.
    var entries: [PATEntry] = []
    /// PMT content and CRC per program_number.
    var maps: [UInt16: ProgramMap] = [:]
    var pmtCRCs: [UInt16: UInt32] = [:]
}

extension TSDemuxer {
    mutating func handlePSI(
        pid: UInt16,
        payload: UnsafeBufferPointer<UInt8>,
        unitStart: Bool,
        gap: Bool,
        emit: (TSDemuxBorrowedEvent) -> Void
    ) {
        var malformed = 0
        if pid == 0 {
            if gap { psi.patAssembler.reset() }
            let sections = psi.patAssembler.push(payload, unitStart: unitStart, malformed: &malformed)
            statistics.malformed += malformed
            for section in sections {
                handlePAT(section, emit: emit)
            }
        } else if psi.pmtAssemblers[pid] != nil {
            if gap { psi.pmtAssemblers[pid]?.reset() }
            let sections = psi.pmtAssemblers[pid]?.push(payload, unitStart: unitStart, malformed: &malformed) ?? []
            statistics.malformed += malformed
            for section in sections {
                handlePMT(section, pid: pid, emit: emit)
            }
        }
    }

    private mutating func checkSection(_ bytes: UnsafeBufferPointer<UInt8>) -> PSIHeader? {
        switch PSIParser.check(bytes) {
        case .valid(let header):
            return header.isCurrent ? header : nil
        case .badCRC:
            statistics.crcErrors += 1
        case .malformed:
            statistics.malformed += 1
        }
        return nil
    }

    private mutating func handlePAT(_ section: [UInt8], emit: (TSDemuxBorrowedEvent) -> Void) {
        let parsed: PATSection? = section.withUnsafeBufferPointer { bytes in
            guard let header = checkSection(bytes), header.tableID == PSIParser.patTableID else { return nil }
            if psi.patVersion != header.version {
                psi.patVersion = header.version
                psi.patSections = [:]
                psi.patCRCs = [:]
            }
            guard psi.patCRCs[header.sectionNumber] != header.crc else { return nil }
            return PSIParser.parsePAT(bytes, header: header)
        }
        guard let parsed else { return }
        let header = parsed.header
        psi.patCRCs[header.sectionNumber] = header.crc
        psi.patSections[header.sectionNumber] = parsed.entries
        psi.patSections = psi.patSections.filter { $0.key <= header.lastSectionNumber }
        var merged: [PATEntry] = []
        for key in psi.patSections.keys.sorted() {
            for entry in psi.patSections[key] ?? [] where !merged.contains(entry) {
                merged.append(entry)
            }
        }
        psi.entries = merged
        let pmtPIDs = Set(merged.map(\.pmtPID)).filter { $0 != 0 && $0 != Self.nullPID }
        psi.pmtAssemblers = psi.pmtAssemblers.filter { pmtPIDs.contains($0.key) }
        for pid in pmtPIDs where psi.pmtAssemblers[pid] == nil {
            psi.pmtAssemblers[pid] = SectionAssembler()
        }
        let listed = Set(merged.map(\.programNumber))
        psi.maps = psi.maps.filter { key, map in
            listed.contains(key) && merged.contains(PATEntry(programNumber: key, pmtPID: map.pmtPID))
        }
        psi.pmtCRCs = psi.pmtCRCs.filter { psi.maps[$0.key] != nil }
        publishPrograms(emit: emit)
    }

    private mutating func handlePMT(_ section: [UInt8], pid: UInt16, emit: (TSDemuxBorrowedEvent) -> Void) {
        let parsed: (map: ProgramMap, crc: UInt32)? = section.withUnsafeBufferPointer { bytes in
            guard let header = checkSection(bytes), header.tableID == PSIParser.pmtTableID else { return nil }
            let entry = PATEntry(programNumber: header.tableIDExtension, pmtPID: pid)
            guard psi.entries.contains(entry), psi.pmtCRCs[entry.programNumber] != header.crc else { return nil }
            guard let map = PSIParser.parsePMT(bytes, header: header, pmtPID: pid) else {
                statistics.malformed += 1
                return nil
            }
            return (map, header.crc)
        }
        guard let parsed else { return }
        psi.maps[parsed.map.programNumber] = parsed.map
        psi.pmtCRCs[parsed.map.programNumber] = parsed.crc
        publishPrograms(emit: emit)
    }

    /// Emits `.programs` if the list of programs with a received PMT changed, and updates the PES assemblers.
    private mutating func publishPrograms(emit: (TSDemuxBorrowedEvent) -> Void) {
        let current = psi.entries.compactMap { entry -> ProgramMap? in
            guard let map = psi.maps[entry.programNumber], map.pmtPID == entry.pmtPID else { return nil }
            return map
        }
        guard current != programs else { return }
        programs = current
        emit(.programs(current, listedProgramNumbers: listedProgramNumbers))
        rebuildSlots()
    }

    /// Points `pesSlot` at an assembler for every elementary PID of every program, keeping the state of PIDs that
    /// stay and dropping the rest.
    mutating func rebuildSlots() {
        let pmtPIDs = Set(psi.entries.map(\.pmtPID))
        var wanted: [(pid: UInt16, program: UInt16)] = []
        for program in programs {
            for stream in program.streams {
                let pid = stream.pid
                guard pid != 0, pid != Self.nullPID, !pmtPIDs.contains(pid),
                      pesFilter?.contains(pid) ?? true,
                      !wanted.contains(where: { $0.pid == pid }) else { continue }
                wanted.append((pid, program.programNumber))
            }
        }
        var rebuilt: [PESAssembler] = []
        rebuilt.reserveCapacity(wanted.count)
        for item in wanted {
            let slot = Int(pesSlot[Int(item.pid)])
            if slot >= 0 {
                var kept = assemblers[slot]
                kept.programNumber = item.program
                rebuilt.append(kept)
            } else {
                rebuilt.append(PESAssembler(pid: item.pid, programNumber: item.program))
            }
        }
        for assembler in assemblers {
            pesSlot[Int(assembler.pid)] = -1
        }
        assemblers = rebuilt
        for (index, assembler) in assemblers.enumerated() {
            pesSlot[Int(assembler.pid)] = Int16(index)
        }
    }
}
