import Foundation

/// Everything the HDHomeRun clients (`HDHomeRunClient`, `HDHomeRunStreamClient`, `HDHomeRunDiscoveryClient`)
/// can fail with.
///
/// Failed stream requests carry an `X-HDHomeRun-Error: <code> <text>` header, for example
/// `805 All Tuners In Use`; `init(status:errorHeader:)` maps its leading digits. A bare HTTP error with
/// no header (such as a 404 for a nonexistent tuner) becomes `.http`.
public nonisolated enum HDHomeRunClientError: Error, Sendable, Hashable {
    /// 801: the channel is not in the lineup (it changed). Refresh the lineup.
    case unknownChannel
    /// 802: unknown transcode profile (EXTEND models). The clients never send `transcode`.
    case unknownTranscodeProfile
    /// 803: system busy, usually a channel scan. Poll `lineup_status.json`.
    case systemBusy
    /// 804: the specific tuner requested is in use.
    case tunerInUse
    /// 805: every tuner is in use.
    case allTunersInUse
    /// 806: hardware or CableCARD tuning error.
    case tuneFailed
    /// 807: no video data, usually weak signal or the station is off the air.
    case noVideoData
    /// 808: DVR failure.
    case dvrFailure
    /// 809: DVR playback connection limit reached.
    case playbackConnectionLimit
    /// 810: DVR full.
    case dvrFull
    /// 811: content protection required (ATSC 3.0 DRM). Cannot be played on Apple platforms.
    case contentProtectionRequired
    /// Any other HTTP failure. `code` and `message` come from `X-HDHomeRun-Error` when it is present.
    case http(status: Int, code: Int?, message: String?)
    /// The text entered is not a host name, IP address or http URL.
    case invalidHost(String)
    /// The device could not be reached: name lookup failed, connection refused, timed out or offline.
    case unreachable(host: String, reason: URLError.Code?)
    /// An open stream's connection broke.
    case connectionLost
    /// `discover.json` answered with a different DeviceID than the one on record.
    case deviceMismatch(expected: TunerDeviceID, found: TunerDeviceID)
    /// The request or stream was cancelled.
    case cancelled
    /// The response was not an HTTP response the device would send.
    case invalidResponse
    /// The body could not be decoded. The string says which endpoint and why, for logs.
    case decoding(String)
    /// Local-network discovery could not send a single request: there is no usable IPv4 network, or the
    /// system refused (for example Local Network access denied, or a missing entitlement). `errno` is the
    /// last socket error, for logs.
    case localNetworkUnavailable(errno: Int32)

    /// The `X-HDHomeRun-Error` codes this type maps to dedicated cases.
    public static let deviceErrorCodes: ClosedRange<Int> = 801...811

    /// Maps a non-success status and its `X-HDHomeRun-Error` header (for example `"805 All Tuners In Use"`).
    /// Codes 801–811 map to their cases whatever the status; anything else becomes `.http`.
    public init(status: Int, errorHeader: String?) {
        let parsed = Self.parseErrorHeader(errorHeader)
        if let code = parsed.code, let known = Self.deviceError(code: code) {
            self = known
        } else {
            self = .http(status: status, code: parsed.code, message: parsed.message)
        }
    }

    /// The case for a device error code 801–811, or nil.
    public static func deviceError(code: Int) -> HDHomeRunClientError? {
        switch code {
        case 801: .unknownChannel
        case 802: .unknownTranscodeProfile
        case 803: .systemBusy
        case 804: .tunerInUse
        case 805: .allTunersInUse
        case 806: .tuneFailed
        case 807: .noVideoData
        case 808: .dvrFailure
        case 809: .playbackConnectionLimit
        case 810: .dvrFull
        case 811: .contentProtectionRequired
        default: nil
        }
    }

    /// Splits `"805 All Tuners In Use"` into (805, "All Tuners In Use"). A header without leading digits
    /// yields a nil code and the trimmed header as the message.
    public static func parseErrorHeader(_ header: String?) -> (code: Int?, message: String?) {
        guard let header else { return (nil, nil) }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6, let code = Int(digits) else { return (nil, trimmed) }
        let rest = trimmed.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        return (code, rest.isEmpty ? nil : rest)
    }

    /// The device error code (801–811), or the `X-HDHomeRun-Error` code carried by `.http`.
    public var code: Int? {
        switch self {
        case .unknownChannel: 801
        case .unknownTranscodeProfile: 802
        case .systemBusy: 803
        case .tunerInUse: 804
        case .allTunersInUse: 805
        case .tuneFailed: 806
        case .noVideoData: 807
        case .dvrFailure: 808
        case .playbackConnectionLimit: 809
        case .dvrFull: 810
        case .contentProtectionRequired: 811
        case .http(_, let code, _): code
        default: nil
        }
    }

    /// Maps a URLSession failure for a request to `host`.
    public init(transportError error: any Error, host: String) {
        if let mapped = error as? HDHomeRunClientError {
            self = mapped
            return
        }
        if error is CancellationError {
            self = .cancelled
            return
        }
        guard let urlError = error as? URLError else {
            self = .unreachable(host: host, reason: nil)
            return
        }
        switch urlError.code {
        case .cancelled:
            self = .cancelled
        case .badServerResponse, .cannotParseResponse, .zeroByteResource, .cannotDecodeRawData,
             .cannotDecodeContentData, .dataLengthExceedsMaximum, .httpTooManyRedirects:
            self = .invalidResponse
        case .badURL, .unsupportedURL:
            self = .invalidHost(host)
        default:
            self = .unreachable(host: host, reason: urlError.code)
        }
    }
}
