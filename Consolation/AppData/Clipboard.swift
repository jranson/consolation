//
//  Clipboard.swift
//  Consolation
//
//  Copies text for Copy Details and Copy Diagnostics. Apple TV has no clipboard.
//

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum Clipboard {
    static var isAvailable: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}
