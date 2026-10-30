//
//  AppIdentifierTests.swift
//  ConsolationTests
//

import Foundation
import Testing
@testable import Consolation

struct AppIdentifierTests {
    @Test func namesAndCopyright() {
        #expect(AppIdentifier.name == "Consolation")
        #expect(AppIdentifier.nameTM == "Consolation™")
        #expect(AppIdentifier.nameSlug == "consolation")
        #expect(AppIdentifier.copyright == "Copyright © 2026 Centennial OSS Inc.")
    }

    @Test func linksPointAtTheProject() {
        #expect(AppIdentifier.repoURL.absoluteString == "https://github.com/centennial-oss/consolation")
        #expect(AppIdentifier.privacyURL.absoluteString
            == "https://github.com/centennial-oss/consolation/blob/main/PRIVACY.md")
        #expect(AppIdentifier.appleStoreReviewURL.absoluteString
            == "https://apps.apple.com/us/app/consolation/id1563856788?action=write-review")
    }

    /// The tests run inside the app, so this catches a PRODUCT_BUNDLE_IDENTIFIER change in the project.
    @Test func bundleIdentifierMatchesTheProject() {
        #expect(AppIdentifier.defaultBundleID == "org.centennialoss.consolation")
        #expect(AppIdentifier.bundleID == AppIdentifier.defaultBundleID)
        #expect(AppIdentifier.scoped("settings") == "org.centennialoss.consolation.settings")
    }
}
