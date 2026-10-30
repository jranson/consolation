//
//  IOSAppOrientationDelegate.swift
//  Consolation
//

#if os(iOS)
import UIKit

/// Let iPadOS own orientation policy; the preview layer follows the active interface orientation. iPhone never
/// turns upside down.
final class IOSAppOrientationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .allButUpsideDown : .all
    }
}
#endif
