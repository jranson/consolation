// swift-tools-version: 6.2
import PackageDescription

let upcoming: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]

let package = Package(
    name: "MediaSourceKit",
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("27.0")],
    products: [
        .library(name: "MediaSourceKit", targets: ["MediaSourceKit"])
    ],
    dependencies: [
        .package(path: "../PlaybackKit"),
        .package(path: "../HTTPMPEG2Kit")
    ],
    targets: [
        // The sources model. No views, so no default isolation: sources are actors, value types are `nonisolated`, and
        // only HomeShelfComposer is MainActor.
        .target(
            name: "MediaSourceKit",
            dependencies: [
                .product(name: "PlaybackKit", package: "PlaybackKit"),
                .product(name: "HTTPMPEG2Kit", package: "HTTPMPEG2Kit")
            ],
            swiftSettings: upcoming
        ),
        // Fixtures are synthetic lineups: documentation addresses (192.0.2.x), synthetic DeviceIDs and call signs.
        .testTarget(
            name: "MediaSourceKitTests",
            dependencies: [
                "MediaSourceKit",
                .product(name: "PlaybackKit", package: "PlaybackKit"),
                .product(name: "HTTPMPEG2Kit", package: "HTTPMPEG2Kit")
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: upcoming
        )
    ],
    swiftLanguageModes: [.v6]
)
