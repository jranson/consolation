import Foundation

/// Chooses what to play from a publication: its acquisition links and their alternates, by media type and size.
public nonisolated enum OPDSPlayback {
    static let acquisitionRelation = "http://opds-spec.org/acquisition"

    /// A playable version of a publication.
    public nonisolated struct Choice: Hashable, Sendable {
        public var link: OPDSLink
        public var url: URL
        public var container: ContainerHint
    }

    /// The version to play: among acquisition links (and their alternates) whose type an engine plays, the
    /// tallest that fits `maxHeight`, then HLS before MP4, MPEG-TS and DASH, then the lower bitrate. Links without
    /// sizes rank by type alone. Nil when nothing is playable.
    public static func choice(for publication: OPDSPublication, base: URL, maxHeight: Int? = nil) -> Choice? {
        let candidates = publication.links
            .filter { link in link.rels.contains { $0.hasPrefix(acquisitionRelation) } }
            .flatMap { [$0] + $0.alternates }
            .compactMap { link -> Choice? in
                guard let container = container(for: link.mediaType), let url = link.url(relativeTo: base) else {
                    return nil
                }
                return Choice(link: link, url: url, container: container)
            }
        let fitting = candidates.filter { choice in
            guard let maxHeight, let height = choice.link.height else { return true }
            return height <= maxHeight
        }
        return (fitting.isEmpty ? candidates : fitting).min(by: ranksBefore)
    }

    /// The descriptor for a choice. A recording in progress grows and starts at its beginning (Go Live is a seek).
    public static func descriptor(for choice: Choice, metadata: OPDSPublicationMetadata) -> PlaybackDescriptor {
        let transport: PlaybackDescriptor.Transport = switch choice.container {
        case .hls: .hls(choice.url, headers: [:])
        case .dash: .dash(choice.url)
        default: .http(choice.url, headers: [:])
        }
        return PlaybackDescriptor(transport: transport, container: choice.container, isGrowing: metadata.inProgress,
                                  start: .beginning)
    }

    static func container(for mediaType: String?) -> ContainerHint? {
        switch mediaType {
        case "application/vnd.apple.mpegurl", "application/x-mpegurl", "audio/mpegurl": .hls
        case "application/dash+xml": .dash
        case "video/mp4", "video/x-m4v": .mp4
        case "video/quicktime": .mov
        case "video/mp2t", "video/mpeg": .mpegTS
        default: nil
        }
    }

    private static func ranksBefore(_ lhs: Choice, _ rhs: Choice) -> Bool {
        let leftHeight = lhs.link.height ?? 0
        let rightHeight = rhs.link.height ?? 0
        if leftHeight != rightHeight { return leftHeight > rightHeight }
        let leftType = typeRank(lhs.container)
        let rightType = typeRank(rhs.container)
        if leftType != rightType { return leftType < rightType }
        return (lhs.link.bitrate ?? .infinity) < (rhs.link.bitrate ?? .infinity)
    }

    private static func typeRank(_ container: ContainerHint) -> Int {
        switch container {
        case .hls: 0
        case .mp4, .mov: 1
        case .mpegTS: 2
        case .dash: 3
        default: 4
        }
    }
}
