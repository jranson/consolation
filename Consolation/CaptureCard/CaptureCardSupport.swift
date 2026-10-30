//
//  CaptureCardSupport.swift
//  Consolation
//
//  Which devices have the Capture Card pane. Capture cards are UVC devices: the Mac and USB-C iPads take them;
//  iPhone (including iPhone Duo, until UVC support there is confirmed) and Apple TV don't.
//

import Foundation
#if os(iOS)
import UIKit
#endif

enum CaptureCardSupport {
    /// The Capture Card pane, its Home card and its menus exist on this device.
    static var isAvailable: Bool {
        #if os(macOS)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    /// The pill's and the Home card's symbol.
    nonisolated static let systemImage = "gamecontroller"
}
