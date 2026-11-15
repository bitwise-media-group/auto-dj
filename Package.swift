// swift-tools-version: 6.0
// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import PackageDescription

// auto-dj, the Swift rewrite (ADR 0018):
//   AutoDJKit — every rule and engine, no UI: SQLCipher + master.db, ANLZ, features,
//               cue rules, set planning, the preview timeline and render engine.
//   auto-dj   — the command line (the same commands and flags as the Go CLI it replaces).
// The macOS app (App/, built from project.yml with XcodeGen) depends on AutoDJKit.
let package = Package(
    name: "AutoDJ",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AutoDJKit", targets: ["AutoDJKit"]),
        .executable(name: "auto-dj", targets: ["AutoDJCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        .target(
            name: "AutoDJKit",
            path: "Sources/AutoDJKit",
            // the DSP (features, time-stretch, the mix) is per-sample work that is ~20x slower
            // unoptimised: build it optimised in Debug too, so the app run from Xcode and
            // `swift test` stay usable
            swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "AutoDJCLI",
            dependencies: [
                "AutoDJKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AutoDJCLI"
        ),
        .testTarget(
            name: "AutoDJKitTests",
            dependencies: ["AutoDJKit"],
            path: "Tests/AutoDJKitTests",
            exclude: ["Fixtures"]
        ),
    ]
)
