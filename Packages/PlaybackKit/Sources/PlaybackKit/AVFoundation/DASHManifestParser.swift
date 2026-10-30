//
//  DASHManifestParser.swift
//  PlaybackKit
//
//  SAX parsing of an MPD (Foundation XMLParser) into a raw element tree. DASHManifestBuilder then applies
//  inheritance and BaseURL resolution. The input is untrusted: element and timeline counts are capped, external
//  entities are never resolved, and unknown elements are ignored.
//

import Foundation

/// An `AudioChannelConfiguration`, `Role`, `EssentialProperty` or `SupplementalProperty` descriptor.
nonisolated struct DASHRawDescriptor: Equatable, Sendable {
    var scheme: String
    var value: String
}

/// A `SegmentTemplate` as written at one level, before inheritance.
nonisolated struct DASHRawTemplate: Equatable, Sendable {
    var attributes: [String: String] = [:]
    var timeline: [DASHTimelineEntry]?

    /// This template with any attribute it lacks taken from `parent` (DASH inheritance).
    func merged(over parent: DASHRawTemplate?) -> DASHRawTemplate {
        guard let parent else { return self }
        var result = parent
        result.attributes.merge(attributes) { _, child in child }
        if let timeline {
            result.timeline = timeline
        }
        return result
    }
}

/// An `MPD`, `Period`, `AdaptationSet` or `Representation` element.
nonisolated struct DASHRawElement: Equatable, Sendable {
    var name: String
    var attributes: [String: String]
    var baseURLs: [String] = []
    var template: DASHRawTemplate?
    var unsupportedAddressing: String?
    var channelConfigurations: [DASHRawDescriptor] = []
    var properties: [DASHRawDescriptor] = []
    var roles: [DASHRawDescriptor] = []
    var children: [DASHRawElement] = []
}

nonisolated final class DASHManifestParser: NSObject, XMLParserDelegate {
    static let maxElements = 1_000_000
    static let maxTimelineEntries = 500_000
    static let maxBaseURLLength = 8_192

    /// Which element each container element must be a direct child of.
    private static let containerParents = [
        "Period": "MPD", "AdaptationSet": "Period", "Representation": "AdaptationSet"
    ]

    private var names: [String] = []
    private var stack: [DASHRawElement] = []
    private var stackDepths: [Int] = []
    private var root: DASHRawElement?
    private var baseURLText: String?
    private var elementCount = 0
    private var timelineEntryCount = 0
    private var failure: DASHManifestError?

    static func parse(data: Data, manifestURL: URL) throws(DASHManifestError) -> DASHManifest {
        let delegate = DASHManifestParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        let succeeded = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard succeeded else { throw .malformedXML(line: parser.lineNumber) }
        guard let root = delegate.root else { throw .notAnMPD }
        return try DASHManifestBuilder.build(root: root, manifestURL: manifestURL)
    }

    // MARK: XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.localName(elementName)
        let parent = names.last
        names.append(name)
        elementCount += 1
        guard elementCount <= Self.maxElements else { return fail(.tooLarge, parser) }
        if parent == nil {
            guard name == "MPD" else { return fail(.notAnMPD, parser) }
            return push(DASHRawElement(name: name, attributes: attributeDict))
        }
        if let required = Self.containerParents[name] {
            if parent == required, stack.last?.name == required, stackDepths.last == names.count - 1 {
                push(DASHRawElement(name: name, attributes: attributeDict))
            }
            return
        }
        if stackDepths.last == names.count - 1 {
            startChild(name, attributes: attributeDict)
        } else {
            startTimelineElement(name, attributes: attributeDict, parser: parser)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if stackDepths.last == names.count, let finished = stack.popLast() {
            stackDepths.removeLast()
            if stack.isEmpty {
                root = finished
            } else {
                stack[stack.count - 1].children.append(finished)
            }
        } else if names.last == "BaseURL", let text = baseURLText, stackDepths.last == names.count - 1 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                stack[stack.count - 1].baseURLs.append(trimmed)
            }
            baseURLText = nil
        }
        _ = names.popLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let text = baseURLText else { return }
        guard text.count + string.count <= Self.maxBaseURLLength else { return fail(.tooLarge, parser) }
        baseURLText = text + string
    }

    // MARK: Elements

    private func push(_ element: DASHRawElement) {
        stack.append(element)
        stackDepths.append(names.count)
    }

    /// A direct child of the innermost MPD, Period, AdaptationSet or Representation.
    private func startChild(_ name: String, attributes: [String: String]) {
        guard !stack.isEmpty else { return }
        let index = stack.count - 1
        let descriptor = DASHRawDescriptor(scheme: attributes["schemeIdUri"] ?? "", value: attributes["value"] ?? "")
        switch name {
        case "BaseURL":
            baseURLText = ""
        case "SegmentTemplate" where stack[index].name != "MPD":
            stack[index].template = DASHRawTemplate(attributes: attributes)
        case "SegmentBase", "SegmentList":
            stack[index].unsupportedAddressing = name
        case "AudioChannelConfiguration":
            stack[index].channelConfigurations.append(descriptor)
        case "EssentialProperty", "SupplementalProperty":
            stack[index].properties.append(descriptor)
        case "Role":
            stack[index].roles.append(descriptor)
        default:
            break
        }
    }

    /// `SegmentTimeline` inside a `SegmentTemplate`, and `S` inside that.
    private func startTimelineElement(_ name: String, attributes: [String: String], parser: XMLParser) {
        guard let ownerDepth = stackDepths.last, !stack.isEmpty, stack[stack.count - 1].template != nil,
              names.count > ownerDepth + 1, names[ownerDepth] == "SegmentTemplate" else { return }
        let index = stack.count - 1
        if name == "SegmentTimeline", names.count == ownerDepth + 2 {
            stack[index].template?.timeline = []
        } else if name == "S", names.count == ownerDepth + 3, names[ownerDepth + 1] == "SegmentTimeline" {
            timelineEntryCount += 1
            guard timelineEntryCount <= Self.maxTimelineEntries else { return fail(.tooLarge, parser) }
            guard let duration = DASHAttributes.int64(attributes["d"]), duration > 0 else { return }
            let time = DASHAttributes.int64(attributes["t"]).flatMap { $0 >= 0 ? $0 : nil }
            let repeatCount = max(-1, DASHAttributes.int(attributes["r"]) ?? 0)
            stack[index].template?.timeline?.append(
                DASHTimelineEntry(time: time, duration: duration, repeatCount: repeatCount))
        }
    }

    private func fail(_ error: DASHManifestError, _ parser: XMLParser) {
        if failure == nil {
            failure = error
        }
        parser.abortParsing()
    }

    /// Drops a namespace prefix (`mpd:Period` → `Period`).
    private static func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: colon)...])
    }
}
