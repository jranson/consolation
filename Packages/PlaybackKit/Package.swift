// swift-tools-version: 6.2
import PackageDescription

let upcoming: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]

let package = Package(
    name: "PlaybackKit",
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("27.0")],
    products: [
        .library(name: "PlaybackKit", targets: ["PlaybackKit"]),
        .library(name: "MPEGTS", targets: ["MPEGTS"])
    ],
    targets: [
        // Pure-Swift MPEG transport stream parsing: Foundation only, no isolation defaults, fully unit-tested.
        .target(name: "MPEGTS", swiftSettings: upcoming),
        // FFmpeg's libavcodec and libavutil (LGPL-2.1), built by `make ffmpeg` into Frameworks/ (gitignored) and
        // embedded as dynamic frameworks.
        .binaryTarget(name: "libavcodec", path: "Frameworks/libavcodec.xcframework"),
        .binaryTarget(name: "libavutil", path: "Frameworks/libavutil.xcframework"),
        // The thin C wrapper PlaybackKit decodes MPEG-2 through; the only code that includes FFmpeg headers.
        .target(name: "LibavMPEG2", dependencies: ["libavcodec", "libavutil"]),
        // Engines and rendering. Mirrors the app: MainActor default isolation; pipeline work is explicitly nonisolated.
        .target(
            name: "PlaybackKit",
            dependencies: ["MPEGTS", "LibavMPEG2"],
            // The LGPL-2.1 text travels with the frameworks into every app bundle (a copy of LICENSES/LGPL-2.1.txt;
            // `make lint` checks the two match).
            resources: [.copy("Resources/LGPL-2.1.txt")],
            swiftSettings: upcoming + [.defaultIsolation(MainActor.self)]
        ),
        // Fixtures: golden synthetic streams and header-only capture excerpts from scripts/make-test-fixtures.sh.
        .testTarget(name: "MPEGTSTests", dependencies: ["MPEGTS"], resources: [.copy("Fixtures")],
                    swiftSettings: upcoming),
        .testTarget(
            name: "PlaybackKitTests",
            dependencies: ["PlaybackKit", "LibavMPEG2"],
            resources: [.copy("Fixtures")],
            swiftSettings: upcoming + [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v6]
)
