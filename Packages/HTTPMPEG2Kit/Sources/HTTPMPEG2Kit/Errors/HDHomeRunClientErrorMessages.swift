import Foundation

extension HDHomeRunClientError: LocalizedError {
    /// A short, user-facing sentence. Host apps may word and localize their own instead.
    public nonisolated var message: String {
        switch self {
        case .unknownChannel:
            "This channel is no longer available."
        case .unknownTranscodeProfile:
            "Couldn't start the stream (error 802)."
        case .systemBusy:
            "The HDHomeRun is scanning for channels. Live TV resumes when the scan finishes."
        case .tunerInUse:
            "That tuner is in use."
        case .allTunersInUse:
            "All tuners are busy."
        case .tuneFailed:
            "The HDHomeRun couldn't tune this channel."
        case .noVideoData:
            "No signal on this channel."
        case .dvrFailure:
            "The DVR reported a failure."
        case .playbackConnectionLimit:
            "The DVR is already playing to as many devices as it can."
        case .dvrFull:
            "The DVR is full."
        case .contentProtectionRequired:
            "This channel is copy-protected and can't be played."
        case .http(let status, let code, _):
            "The HDHomeRun returned an error (\(code.map { "error \($0)" } ?? "HTTP \(status)"))."
        default:
            nonDeviceMessage
        }
    }

    private nonisolated var nonDeviceMessage: String {
        switch self {
        case .invalidHost:
            "Enter a host name, an IP address or an http URL."
        case .unreachable(let host, _):
            "Can't reach the HDHomeRun at \(host)."
        case .connectionLost:
            "The connection to the HDHomeRun was lost."
        case .deviceMismatch:
            "A different HDHomeRun answered at this address."
        case .cancelled:
            "The request was cancelled."
        case .invalidResponse:
            "The HDHomeRun sent an unexpected response."
        case .decoding:
            "The HDHomeRun sent data that couldn't be read."
        case .localNetworkUnavailable:
            "Couldn't search the local network. Check the network connection and Local Network access."
        default:
            "Something went wrong with the HDHomeRun."
        }
    }

    public nonisolated var errorDescription: String? { message }
}
