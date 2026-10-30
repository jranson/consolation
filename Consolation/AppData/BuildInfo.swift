//
//  BuildInfo.swift
//  Consolation
//
//  Version and build metadata. BuildInfo.generated.swift supplies commit, date, configuration and architecture;
//  CI rewrites it with `make generate-build-info`.
//

import Foundation
#if os(iOS)
import UIKit
#endif

enum BuildInfo {
    /// Semantic version from Info.plist (MARKETING_VERSION). Release builds set it with TAGVER.
    nonisolated static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "localdev"
    }

    /// Build number from Info.plist (CURRENT_PROJECT_VERSION). Release builds set it with BUILDNUM.
    nonisolated static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var commit: String { BuildInfoGenerated.buildCommit }
    static var buildDate: String { BuildInfoGenerated.buildDate }
    static var buildType: String { BuildInfoGenerated.buildConfiguration }
    static var buildArch: String { BuildInfoGenerated.buildArch }

    /// The architecture this copy is running as, which can differ from a universal build's label.
    nonisolated static var runningArch: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    /// The operating system this copy is running on: macOS, iOS, iPadOS or tvOS.
    static var osName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(iOS)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            return "macOS"
        }
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #else
        return "unknown"
        #endif
    }

    /// The running OS version, e.g. "26.1.0". ProcessInfo reports it the same way on every platform.
    nonisolated static var osVersion: String {
        formatOSVersion(ProcessInfo.processInfo.operatingSystemVersion)
    }

    nonisolated static func formatOSVersion(_ version: OperatingSystemVersion) -> String {
        "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Copyable blob for support and bug reports.
    static var copyableBlob: String {
        """
        Version: \(version) (\(buildNumber)) (\(osName) \(osVersion), \(runningArch))
        Commit: \(commit)
        Date: \(buildDate)
        Build Type: \(buildType) (\(buildArch))
        """
    }
}
