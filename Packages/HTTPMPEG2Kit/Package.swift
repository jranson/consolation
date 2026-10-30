// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HTTPMPEG2Kit",
    platforms: [.macOS("26.0"), .iOS("26.0"), .tvOS("27.0")],
    products: [
        .library(name: "HTTPMPEG2Kit", targets: ["HTTPMPEG2Kit"])
    ],
    targets: [
        .target(
            name: "HTTPMPEG2Kit",
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        ),
        .testTarget(
            name: "HTTPMPEG2KitTests",
            dependencies: ["HTTPMPEG2Kit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.enableUpcomingFeature("MemberImportVisibility")]
        )
    ],
    swiftLanguageModes: [.v6]
)
