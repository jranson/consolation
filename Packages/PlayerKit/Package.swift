// swift-tools-version: 6.2
import PackageDescription

let upcoming: [SwiftSetting] = [.enableUpcomingFeature("MemberImportVisibility")]

let package = Package(
    name: "PlayerKit",
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("27.0")],
    products: [
        .library(name: "PlayerKit", targets: ["PlayerKit"])
    ],
    dependencies: [
        .package(path: "../PlaybackKit")
    ],
    targets: [
        // Multi-view: the tile session, its state machine, grid geometry, tile roles and the player views. Generic over
        // the host's item type, so it needs no media-source package. Mirrors the app: MainActor default isolation;
        // value types and geometry are explicitly nonisolated.
        .target(
            name: "PlayerKit",
            dependencies: [.product(name: "PlaybackKit", package: "PlaybackKit")],
            swiftSettings: upcoming + [.defaultIsolation(MainActor.self)]
        ),
        .testTarget(
            name: "PlayerKitTests",
            dependencies: ["PlayerKit", .product(name: "PlaybackKit", package: "PlaybackKit")],
            swiftSettings: upcoming + [.defaultIsolation(MainActor.self)]
        )
    ],
    swiftLanguageModes: [.v6]
)
