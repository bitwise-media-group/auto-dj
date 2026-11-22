// swift-tools-version: 6.0
// Copyright 2026 BitWise Media Group Ltd
// SPDX-License-Identifier: MIT

import PackageDescription

// auto-dj, the Swift rewrite (ADR 0018):
//   AutoDJKit — every rule and engine, no UI: SQLCipher + master.db, ANLZ, features,
//               cue rules, set planning, the preview timeline and render engine.
//   AutoDJCommands — the command line's commands (swift-argument-parser) on AutoDJKit.
//   auto-dj   — the command line: Sources/AutoDJCLI/AutoDJCLI.swift runs AutoDJCommands.
// The macOS app (App/, built from project.yml with XcodeGen) depends on AutoDJKit, and embeds the
// command line as Contents/MacOS/auto-dj: an Xcode tool target builds the same entry point against
// AutoDJCommands, so Xcode signs and notarizes it with the app.
let package = Package(
    name: "AutoDJ",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AutoDJKit", targets: ["AutoDJKit"]),
        .library(name: "AutoDJCommands", targets: ["AutoDJCommands"]),
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
        .target(
            name: "AutoDJCommands",
            dependencies: [
                "AutoDJKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/AutoDJCommands"
        ),
        .executableTarget(
            name: "AutoDJCLI",
            dependencies: ["AutoDJCommands"],
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
