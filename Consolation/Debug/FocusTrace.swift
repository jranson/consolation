//
//  FocusTrace.swift
//  Consolation
//
//  tvOS: prints every focus move (what had focus, what has it now, and the move's heading) when the app runs with
//  `CONSOLATION_FOCUS_TRACE=1` in its environment, for diagnosing focus on a real Apple TV from the console.
//

import SwiftUI
#if os(tvOS)
import OSLog
import UIKit
#endif

extension View {
    func focusTrace() -> some View {
        #if os(tvOS)
        modifier(FocusTraceModifier())
        #else
        self
        #endif
    }
}

#if os(tvOS)
private struct FocusTraceModifier: ViewModifier {
    static let isEnabled = ProcessInfo.processInfo.environment["CONSOLATION_FOCUS_TRACE"] == "1"
    static let log = Logger(subsystem: AppIdentifier.bundleID, category: "Focus")

    func body(content: Content) -> some View {
        if Self.isEnabled {
            content.onReceive(NotificationCenter.default.publisher(for: UIFocusSystem.didUpdateNotification)) { note in
                guard let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                        as? UIFocusUpdateContext else { return }
                let line = "Focus: \(Self.describe(context.previouslyFocusedItem)) -> "
                    + "\(Self.describe(context.nextFocusedItem)) heading \(context.focusHeading.rawValue)"
                Self.log.notice("\(line, privacy: .public)")
                print(line)
            }
        } else {
            content
        }
    }

    private static func describe(_ item: (any UIFocusItem)?) -> String {
        guard let item else { return "none" }
        let frame = item.frame
        let label = (item as? NSObject)?.accessibilityLabel ?? ""
        let place = "(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))"
        return "\(type(of: item))[\(label)] at \(place)"
    }
}
#endif
