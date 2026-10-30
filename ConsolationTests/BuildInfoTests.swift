//
//  BuildInfoTests.swift
//  ConsolationTests
//

import Foundation
import Testing
@testable import Consolation

struct BuildInfoTests {
    @Test func formatsOSVersions() {
        let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)
        #expect(BuildInfo.formatOSVersion(version) == "26.1.0")
        #expect(BuildInfo.osVersion.split(separator: ".").count == 3)
    }

    @Test func versionComesFromInfoPlist() {
        #expect(!BuildInfo.version.isEmpty)
        #expect(!BuildInfo.buildNumber.isEmpty)
    }

    @Test func reportsAKnownPlatformAndArchitecture() {
        #expect(["macOS", "iOS", "iPadOS", "tvOS"].contains(BuildInfo.osName))
        #expect(["arm64", "x86_64"].contains(BuildInfo.runningArch))
    }

    @Test func copyableBlobListsEveryField() {
        let lines = BuildInfo.copyableBlob.split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines[0] == "Version: \(BuildInfo.version) (\(BuildInfo.buildNumber)) "
            + "(\(BuildInfo.osName) \(BuildInfo.osVersion), \(BuildInfo.runningArch))")
        #expect(lines[1] == "Commit: \(BuildInfo.commit)")
        #expect(lines[2] == "Date: \(BuildInfo.buildDate)")
        #expect(lines[3] == "Build Type: \(BuildInfo.buildType) (\(BuildInfo.buildArch))")
    }
}
