//
//  DASHManifestBuilder.swift
//  PlaybackKit
//
//  Turns the raw MPD element tree into a DASHManifest: attribute and SegmentTemplate inheritance
//  (Period > AdaptationSet > Representation), BaseURL resolution at every level, and descriptor decoding.
//

import Foundation

nonisolated enum DASHManifestBuilder {
    /// Representation attributes that may be written on the AdaptationSet instead.
    private static let inheritedAttributes = ["mimeType", "codecs", "width", "height", "frameRate", "audioSamplingRate"]

    static func build(root: DASHRawElement, manifestURL: URL) throws(DASHManifestError) -> DASHManifest {
        let type: DASHManifest.PresentationType = root.attributes["type"] == "dynamic" ? .dynamic : .staticPresentation
        let base = resolve(root.baseURLs.first, against: manifestURL)
        let periods = root.children.map { period($0, base: base) }
        guard !periods.isEmpty else { throw .noPeriods }
        let duration = DASHAttributes.seconds(root.attributes["mediaPresentationDuration"])
        return DASHManifest(presentationType: type, mediaPresentationDuration: duration,
                            minBufferTime: DASHAttributes.seconds(root.attributes["minBufferTime"]), periods: periods)
    }

    private static func period(_ element: DASHRawElement, base parentBase: URL) -> DASHPeriod {
        let base = resolve(element.baseURLs.first, against: parentBase)
        let sets = element.children.map { adaptationSet($0, period: element, base: base) }
        return DASHPeriod(id: element.attributes["id"], start: DASHAttributes.seconds(element.attributes["start"]),
                          duration: DASHAttributes.seconds(element.attributes["duration"]), adaptationSets: sets)
    }

    private static func adaptationSet(_ element: DASHRawElement, period: DASHRawElement,
                                      base parentBase: URL) -> DASHAdaptationSet {
        let base = resolve(element.baseURLs.first, against: parentBase)
        let context = InheritedContext(period: period, adaptationSet: element)
        let representations = element.children.enumerated().map { index, child in
            representation(child, index: index, context: context, base: base)
        }
        let isMain = element.roles.contains { $0.value == "main" }
        let language = element.attributes["lang"] ?? element.children.first?.attributes["lang"]
        return DASHAdaptationSet(id: element.attributes["id"], contentType: contentType(of: element),
                                 language: language, isMain: isMain, representations: representations)
    }

    /// What a Representation inherits from its AdaptationSet and Period.
    private nonisolated struct InheritedContext {
        let period: DASHRawElement
        let adaptationSet: DASHRawElement
    }

    private static func representation(_ element: DASHRawElement, index: Int, context: InheritedContext,
                                       base parentBase: URL) -> DASHRepresentation {
        let set = context.adaptationSet
        var attributes = element.attributes
        for key in inheritedAttributes where attributes[key] == nil {
            attributes[key] = set.attributes[key]
        }
        var rep = DASHRepresentation(id: attributes["id"] ?? String(index),
                                     bandwidth: DASHAttributes.int(attributes["bandwidth"]) ?? 0,
                                     baseURL: resolve(element.baseURLs.first, against: parentBase))
        rep.mimeType = attributes["mimeType"]
        rep.codecs = attributes["codecs"]
        rep.width = DASHAttributes.int(attributes["width"]).flatMap { $0 > 0 ? $0 : nil }
        rep.height = DASHAttributes.int(attributes["height"]).flatMap { $0 > 0 ? $0 : nil }
        rep.frameRate = DASHAttributes.frameRate(attributes["frameRate"])
        rep.audioSamplingRate = DASHAttributes.int(attributes["audioSamplingRate"])
        let channelConfiguration = element.channelConfigurations.first ?? set.channelConfigurations.first
        rep.audioChannels = channelConfiguration.flatMap(DASHAttributes.channelCount)
        rep.transferCharacteristics = (element.properties + set.properties).lazy
            .filter { $0.scheme == "urn:mpeg:mpegB:cicp:TransferCharacteristics" }
            .compactMap { DASHAttributes.int($0.value) }.first
        let setTemplate = set.template?.merged(over: context.period.template) ?? context.period.template
        let template = element.template?.merged(over: setTemplate) ?? setTemplate
        if let template, template.attributes["media"] != nil {
            rep.segmentTemplate = segmentTemplate(template)
        } else {
            rep.unsupportedAddressing = element.unsupportedAddressing ?? set.unsupportedAddressing
                ?? context.period.unsupportedAddressing
        }
        return rep
    }

    private static func segmentTemplate(_ raw: DASHRawTemplate) -> DASHSegmentTemplate {
        let attributes = raw.attributes
        return DASHSegmentTemplate(
            timescale: DASHAttributes.int64(attributes["timescale"]).flatMap { $0 > 0 ? $0 : nil } ?? 1,
            media: attributes["media"],
            initialization: attributes["initialization"],
            startNumber: DASHAttributes.int(attributes["startNumber"]).flatMap { $0 >= 0 ? $0 : nil } ?? 1,
            duration: DASHAttributes.int64(attributes["duration"]).flatMap { $0 > 0 ? $0 : nil },
            presentationTimeOffset: DASHAttributes.int64(attributes["presentationTimeOffset"]) ?? 0,
            timeline: raw.timeline)
    }

    private static func contentType(of element: DASHRawElement) -> DASHAdaptationSet.ContentType {
        let declared = element.attributes["contentType"]
            ?? element.attributes["mimeType"]?.split(separator: "/").first.map(String.init)
            ?? element.children.first?.attributes["mimeType"]?.split(separator: "/").first.map(String.init)
        switch declared?.lowercased() {
        case "video": return .video
        case "audio": return .audio
        case "text": return .text
        case "application" where element.children.first?.attributes["codecs"].map(isTextCodec) == true:
            return .text
        default: break
        }
        let codecs = (element.attributes["codecs"] ?? element.children.first?.attributes["codecs"] ?? "").lowercased()
        if ["avc", "hvc", "hev", "dvh", "av01", "vp09"].contains(where: codecs.hasPrefix) { return .video }
        if ["mp4a", "ac-3", "ec-3", "ac-4", "opus"].contains(where: codecs.hasPrefix) { return .audio }
        return .other
    }

    private static func isTextCodec(_ codecs: String) -> Bool {
        ["wvtt", "stpp"].contains { codecs.lowercased().hasPrefix($0) }
    }

    /// Resolves a BaseURL against its parent level. An absent or unusable BaseURL means "same as the parent".
    static func resolve(_ text: String?, against base: URL) -> URL {
        guard let text, !text.isEmpty, let url = URL(string: text, relativeTo: base)?.absoluteURL,
              url.scheme != nil else { return base }
        return url
    }
}

/// Attribute value parsing for MPDs.
nonisolated enum DASHAttributes {
    private static let dateUnits: [Character: Double] = ["Y": 31_536_000, "M": 2_592_000, "W": 604_800, "D": 86_400]
    private static let timeUnits: [Character: Double] = ["H": 3_600, "M": 60, "S": 1]

    static func int(_ text: String?) -> Int? {
        text.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func int64(_ text: String?) -> Int64? {
        text.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// An xs:duration such as `PT2H25M0.6S` or `P1DT2H`, in seconds. Years and months use 365 and 30 days.
    static func seconds(_ text: String?) -> Double? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), text.first == "P" else { return nil }
        var total = 0.0
        var number = ""
        var inTime = false
        var sawComponent = false
        for character in text.dropFirst() {
            if character == "T" {
                inTime = true
            } else if character.isASCII, character.isNumber || character == "." {
                number.append(character)
            } else {
                let units = inTime ? timeUnits : dateUnits
                guard let unit = units[character], let value = Double(number) else { return nil }
                total += value * unit
                number = ""
                sawComponent = true
            }
        }
        guard number.isEmpty, sawComponent, total.isFinite else { return nil }
        return total
    }

    /// `@frameRate`: `25`, `29.97` or `30000/1001`.
    static func frameRate(_ text: String?) -> Double? {
        guard let parts = text?.split(separator: "/"), !parts.isEmpty, parts.count <= 2,
              let numerator = Double(parts[0]) else { return nil }
        let denominator = parts.count == 2 ? Double(parts[1]) ?? 0 : 1
        guard denominator > 0 else { return nil }
        let rate = numerator / denominator
        return rate.isFinite && rate > 0 && rate <= 1_000 ? rate : nil
    }

    /// Channel count from an `AudioChannelConfiguration` in any of the common schemes.
    static func channelCount(_ descriptor: DASHRawDescriptor) -> Int? {
        let value = descriptor.value.trimmingCharacters(in: .whitespaces)
        switch descriptor.scheme {
        case "urn:mpeg:mpegB:cicp:ChannelConfiguration":
            let counts = [1: 1, 2: 2, 3: 3, 4: 4, 5: 5, 6: 6, 7: 8, 9: 3, 10: 4, 11: 7, 12: 8, 13: 24, 14: 8,
                          15: 12, 16: 10, 17: 12, 18: 14, 19: 12, 20: 14]
            return Int(value).flatMap { counts[$0] }
        case "tag:dolby.com,2014:dash:audio_channel_configuration:2011",
             "urn:dolby:dash:audio_channel_configuration:2011":
            guard let mask = UInt16(value, radix: 16), mask != 0 else { return nil }
            let pairBits: [UInt16] = [1 << 10, 1 << 9, 1 << 6, 1 << 5, 1 << 4, 1 << 2]
            return mask.nonzeroBitCount + pairBits.filter { mask & $0 != 0 }.count
        default:
            return Int(value).flatMap { $0 > 0 && $0 <= 64 ? $0 : nil }
        }
    }
}
