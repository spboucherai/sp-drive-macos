// swift-tools-version: 6.0
// Author: Simon-Pierre Boucher — contact@spboucher.ai
// File: Package.swift
// Description: Swift packages of SP Drive's engine room — SPDriveCore (models, API, auth, persistence, security) and SPDriveSync (transfers, change feed, journal, conflicts) — and their tests.
import PackageDescription

// No user interface and no AppKit/UIKit here: both targets are linked by the macOS app, by its File Provider
// extension and by the iOS app and its extensions. Only extension-safe API is used; there is no dependency.
let package = Package(
    name: "SPDriveCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SPDriveCore", targets: ["SPDriveCore"]),
        .library(name: "SPDriveSync", targets: ["SPDriveSync"]),
        .executable(name: "spdrive-cli", targets: ["spdrive-cli"]),
    ],
    targets: [
        .target(name: "SPDriveCore", path: "Core", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "SPDriveSync", dependencies: ["SPDriveCore"], path: "Sync"),
        .executableTarget(name: "spdrive-cli", dependencies: ["SPDriveCore", "SPDriveSync"], path: "Tools/spdrive-cli"),
        .testTarget(name: "CoreTests", dependencies: ["SPDriveCore", "SPDriveSync"], path: "Tests/CoreTests"),
    ],
    swiftLanguageModes: [.v6]
)
