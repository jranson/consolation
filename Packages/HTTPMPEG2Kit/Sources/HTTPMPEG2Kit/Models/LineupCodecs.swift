import Foundation

extension LineupChannel {
    /// The lineup's `VideoCodec`. Unknown values are kept as `.other`.
    public nonisolated enum VideoCodec: RawRepresentable, Codable, Sendable, Hashable {
        case mpeg2
        case h264
        case hevc
        case other(String)

        public init(rawValue: String) {
            switch rawValue.trimmingCharacters(in: .whitespaces).uppercased() {
            case "MPEG2", "MPEG-2": self = .mpeg2
            case "H264", "H.264", "AVC": self = .h264
            case "HEVC", "H265", "H.265": self = .hevc
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .mpeg2: "MPEG2"
            case .h264: "H264"
            case .hevc: "HEVC"
            case .other(let value): value
            }
        }
    }

    /// The lineup's `AudioCodec`. `MPEG` is MPEG-1 Layer II. Unknown values are kept as `.other`.
    public nonisolated enum AudioCodec: RawRepresentable, Codable, Sendable, Hashable {
        case ac3
        case eac3
        case ac4
        case aac
        case mpeg
        case other(String)

        public init(rawValue: String) {
            switch rawValue.trimmingCharacters(in: .whitespaces).uppercased() {
            case "AC3", "AC-3": self = .ac3
            case "EAC3", "E-AC3", "E-AC-3": self = .eac3
            case "AC4", "AC-4": self = .ac4
            case "AAC": self = .aac
            case "MPEG": self = .mpeg
            default: self = .other(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .ac3: "AC3"
            case .eac3: "EAC3"
            case .ac4: "AC4"
            case .aac: "AAC"
            case .mpeg: "MPEG"
            case .other(let value): value
            }
        }
    }
}
