// swift-tools-version: 5.9
//
//  Package.swift
//  IndoorPositioning
//
//  Step-counting PDR (Pedestrian Dead Reckoning) with map constraints.
//  Deliberately dependency-free so it can be dropped into an app target
//  without touching its package graph.
//

import PackageDescription

let package = Package(
    name: "IndoorPositioning",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PDRCore", targets: ["PDRCore"]),
        .library(name: "PDRMotion", targets: ["PDRMotion"]),
        .executable(name: "pdr-validate", targets: ["pdr-validate"]),
    ],
    targets: [
        .target(name: "PDRCore"),
        .target(name: "PDRMotion", dependencies: ["PDRCore"]),
        .executableTarget(name: "pdr-validate", dependencies: ["PDRCore"]),
        .testTarget(name: "PDRCoreTests", dependencies: ["PDRCore"]),
    ]
)
