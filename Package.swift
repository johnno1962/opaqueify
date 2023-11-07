// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "opaqueify",
    platforms: [.macOS("10.12")],
    products: [
        .executable(name: "opaqueify", targets: ["opaqueify"]),
        .library(name: "Opaqueifier", targets: ["Opaqueifier"]),
    ],
    dependencies: [
        .package(url: "https://github.com/johnno1962/SourceKitHeader.git",
                 .upToNextMinor(from: "2.0.0")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5.git",
                 .upToNextMinor(from: "6.0.0")),
        .package(url: "https://github.com/johnno1962/Fortify.git",
                 .upToNextMinor(from: "2.1.5")),
        .package(url: "https://github.com/johnno1962/Popen.git",
                 .upToNextMinor(from: "2.0.0")),
        .package(url: "https://github.com/johnno1962/DLKit.git",
                 .upToNextMinor(from: "3.2.2")),
    ],
    targets: [
        .target(name: "opaqueify", dependencies: [
            "Opaqueifier", "Fortify"], path: "opaqueify/"),
        .target(name: "Opaqueifier", dependencies: [
            "SourceKitHeader", "SwiftRegex", "Popen", "DLKit"], path: "Opaqueifier/"),
    ]
)
