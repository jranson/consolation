//
//  DASHSegments.swift
//  PlaybackKit
//
//  SegmentTemplate identifier substitution ($RepresentationID$, $Number$, $Time$, $Bandwidth$ with %0Nd widths,
//  and $$) and expansion of a Representation into absolute segment URLs, from a SegmentTimeline or @duration.
//

import Foundation

/// Template identifier substitution (ISO/IEC 23009-1 §5.3.9.4.4).
public nonisolated enum DASHTemplate {
    /// Largest `%0Nd` width honoured; wider formats are clamped.
    static let maxWidth = 32

    /// Replaces identifiers in `template`. Identifiers with no value (for example `$Time$` when only a number is
    /// known) and unknown identifiers are left as written.
    public static func expand(_ template: String, representationID: String, bandwidth: Int, number: Int? = nil,
                              time: Int64? = nil) -> String {
        var output = ""
        var rest = Substring(template)
        while let start = rest.firstIndex(of: "$") {
            output += rest[..<start]
            let afterStart = rest.index(after: start)
            guard let end = rest[afterStart...].firstIndex(of: "$") else {
                output += rest[start...]
                return output
            }
            let token = rest[afterStart..<end]
            let values = TemplateValues(representationID: representationID, bandwidth: bandwidth, number: number,
                                        time: time)
            output += substitute(token, values: values) ?? "$\(token)$"
            rest = rest[rest.index(after: end)...]
        }
        output += rest
        return output
    }

    private nonisolated struct TemplateValues {
        let representationID: String
        let bandwidth: Int
        let number: Int?
        let time: Int64?
    }

    private static func substitute(_ token: Substring, values: TemplateValues) -> String? {
        if token.isEmpty { return "$" }
        let parts = token.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        let name = parts[0]
        let format = parts.count == 2 ? parts[1] : nil
        let value: Int64?
        switch name {
        case "RepresentationID":
            return format == nil ? values.representationID : nil
        case "Number":
            value = values.number.map(Int64.init)
        case "Time":
            value = values.time
        case "Bandwidth":
            value = Int64(values.bandwidth)
        default:
            return nil
        }
        guard let value else { return nil }
        guard let format else { return String(value) }
        guard let width = formatWidth(format) else { return nil }
        return padded(value, width: width)
    }

    /// The width in a `%0Nd` (or `%Nd`, `%d`) format tag.
    private static func formatWidth(_ format: Substring) -> Int? {
        guard format.last == "d" else { return nil }
        let digits = format.dropLast()
        if digits.isEmpty { return 0 }
        guard digits.allSatisfy(\.isASCII), let width = Int(digits), width >= 0 else { return nil }
        return min(width, maxWidth)
    }

    private static func padded(_ value: Int64, width: Int) -> String {
        let digits = String(value.magnitude)
        let sign = value < 0 ? "-" : ""
        let padding = max(0, width - digits.count - sign.count)
        return sign + String(repeating: "0", count: padding) + digits
    }
}

public nonisolated extension DASHRepresentation {
    /// Upper bound on segments per Representation (a 24-hour VOD with 1 s segments is 86,400).
    static var maxSegments: Int { 200_000 }

    /// The absolute URL of the initialization segment, or nil when the template has none.
    func initializationURL() throws(DASHManifestError) -> URL? {
        guard let template = segmentTemplate?.initialization else { return nil }
        let expanded = DASHTemplate.expand(template, representationID: id, bandwidth: bandwidth)
        guard let url = URL(string: expanded, relativeTo: baseURL)?.absoluteURL else {
            throw .invalidURL(representationID: id)
        }
        return url
    }

    /// Every media segment with an absolute URL. `periodDuration` (seconds) bounds `@r="-1"` and `@duration`
    /// templates.
    func segments(periodDuration: Double?) throws(DASHManifestError) -> [DASHSegment] {
        if let unsupportedAddressing { throw .unsupported(unsupportedAddressing) }
        guard let template = segmentTemplate, let media = template.media else {
            throw .missingSegmentInformation(representationID: id)
        }
        guard template.startNumber <= Int.max - Self.maxSegments else { throw .tooLarge }
        let slots: [SegmentSlot]
        if let timeline = template.timeline {
            slots = try timelineSlots(timeline, template: template, periodDuration: periodDuration)
        } else {
            slots = try durationSlots(template: template, periodDuration: periodDuration)
        }
        let timescale = Double(template.timescale)
        return try slots.map { slot throws(DASHManifestError) in
            let expanded = DASHTemplate.expand(media, representationID: id, bandwidth: bandwidth, number: slot.number,
                                               time: slot.time)
            guard let url = URL(string: expanded, relativeTo: baseURL)?.absoluteURL else {
                throw .invalidURL(representationID: id)
            }
            return DASHSegment(number: slot.number, time: slot.time, duration: Double(slot.ticks) / timescale, url: url)
        }
    }

    private func timelineSlots(_ timeline: [DASHTimelineEntry], template: DASHSegmentTemplate,
                               periodDuration: Double?) throws(DASHManifestError) -> [SegmentSlot] {
        var slots: [SegmentSlot] = []
        var time: Int64 = 0
        var number = template.startNumber
        for (index, entry) in timeline.enumerated() {
            if let start = entry.time {
                time = start
            }
            var repeats = entry.repeatCount
            if repeats < 0 {
                var end = index + 1 < timeline.count ? timeline[index + 1].time : nil
                if end == nil {
                    end = try periodEnd(template: template, periodDuration: periodDuration)
                }
                guard let end else { throw .missingSegmentInformation(representationID: id) }
                let remaining = Double(end - time) / Double(entry.duration)
                repeats = remaining > 0 ? Int(min(remaining.rounded(.up), Double(Self.maxSegments))) - 1 : -1
            }
            guard repeats >= 0 else { continue }
            guard repeats < Self.maxSegments - slots.count else { throw .tooLarge }
            for _ in 0...repeats {
                slots.append(SegmentSlot(number: number, time: time, ticks: entry.duration))
                let (nextTime, overflow) = time.addingReportingOverflow(entry.duration)
                guard !overflow else { throw .tooLarge }
                time = nextTime
                number += 1
            }
        }
        return slots
    }

    private func durationSlots(template: DASHSegmentTemplate,
                               periodDuration: Double?) throws(DASHManifestError) -> [SegmentSlot] {
        guard let duration = template.duration, let periodDuration, periodDuration > 0 else {
            throw .missingSegmentInformation(representationID: id)
        }
        let totalTicks = (periodDuration * Double(template.timescale)).rounded()
        let count = (totalTicks / Double(duration)).rounded(.up)
        guard count.isFinite, count < Double(Self.maxSegments), totalTicks < Double(Int64.max / 4),
              abs(template.presentationTimeOffset) < Int64.max / 4 else { throw .tooLarge }
        let total = Int64(totalTicks)
        var slots: [SegmentSlot] = []
        var consumed: Int64 = 0
        for index in 0..<Int(count) {
            let ticks = min(duration, max(total - consumed, 1))
            slots.append(SegmentSlot(number: template.startNumber + index,
                                     time: template.presentationTimeOffset + consumed, ticks: ticks))
            consumed += ticks
        }
        return slots
    }

    /// The Period's end in timescale units, or nil when its duration is unknown.
    private func periodEnd(template: DASHSegmentTemplate,
                           periodDuration: Double?) throws(DASHManifestError) -> Int64? {
        guard let periodDuration, periodDuration > 0 else { return nil }
        let ticks = periodDuration * Double(template.timescale) + Double(template.presentationTimeOffset)
        guard ticks.isFinite, abs(ticks) < Double(Int64.max / 2) else { throw .tooLarge }
        return Int64(ticks.rounded())
    }
}

/// A segment before URL expansion.
private nonisolated struct SegmentSlot {
    let number: Int
    let time: Int64
    let ticks: Int64
}
