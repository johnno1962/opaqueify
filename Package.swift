// swift-tools-version:5.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "opaqueify",
    platforms: [.macOS("10.12")],
    products: [
        .executable(name: "opaqueify", targets: ["opaqueify"]),
    ],
    dependencies: [
        .package(url: "https://github.com/johnno1962/SourceKitHeader.git", from: "2.0.0"),
        .package(url: "https://github.com/johnno1962/Popen.git", .branch("main")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5.git", .branch("main")),
    ],
    targets: [
        .target(name: "opaqueify", dependencies: ["SourceKitHeader", "Popen", "SwiftRegex"], path: "opaqueify/"),
    ]
)
