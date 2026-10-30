//
//  CaptureDeviceIdentification.swift
//  Consolation
//

#if !os(tvOS)
import AVFoundation
import Foundation

// MARK: - USB UVC capture device identification

/// Names (or parts of names) of the cameras built into Macs, iPads and Apple displays, and of Continuity Camera.
/// Any other external video device counts as a capture card. Matched case-insensitively against `localizedName`;
/// add to this list as new Apple cameras appear.
nonisolated let faceTimeCameraNameTokens: [String] = [
    "FaceTime",
    "Studio Display Camera",
    "Pro Display XDR",
    "Desk View",
    "Continuity Camera",
    "iPhone Camera",
    "iPad Camera"
]

/// Whether a video device's name is one of Apple's own cameras (`faceTimeCameraNameTokens`).
nonisolated func isFaceTimeCameraName(_ name: String) -> Bool {
    faceTimeCameraNameTokens.contains { name.localizedCaseInsensitiveContains($0) }
}

/// Returns `true` only for a USB video capture device, such as Elgato Game Capture HD60 X: an external video
/// device that isn't a Continuity Camera or one of Apple's own cameras.
nonisolated func deviceIsUSBVideoCapture(_ device: AVCaptureDevice) -> Bool {
    guard device.deviceType == .external, !device.isContinuityCamera else { return false }
    return !isFaceTimeCameraName(device.localizedName)
}

enum CaptureSessionError: LocalizedError {
    case noVideoDevice
    case cannotAddVideoInput

    var errorDescription: String? {
        switch self {
        case .noVideoDevice:
            return "No video capture device was found."
        case .cannotAddVideoInput:
            return "This capture device cannot be used as a video input."
        }
    }
}
#endif
