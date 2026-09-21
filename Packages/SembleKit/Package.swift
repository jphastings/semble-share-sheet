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
    dependencies: [
        // OAuth 2.1 + DPoP, including the ATProto ("Bluesky") flavour. The
        // last tag (0.7.2, January 2026) predates the per-origin DPoP nonce
        // cache and the PAR/refresh fixes on main, so the commit is pinned
        // until the next release.
        .package(url: "https://github.com/ATProtoKit/OAuthenticator", revision: "b455b1259da75f056d1e24f8926227eaa13e1c7a"),
        // JWT/JWK signing for the DPoP proofs.
        .package(url: "https://github.com/ATProtoKit/Jot", from: "0.1.1"),
    ],
    targets: [
        .target(
            name: "SembleKit",
            dependencies: [
                .product(name: "OAuthenticator", package: "OAuthenticator"),
                .product(name: "Jot", package: "Jot"),
            ],
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
