// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SembleKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SembleKit", targets: ["SembleKit"]),
    ],
    targets: [
        .target(
            name: "SembleKit",
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SembleKitTests",
            dependencies: ["SembleKit"]
        ),
    ]
)
