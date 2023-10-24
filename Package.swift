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
        .package(url: "https://github.com/johnno1962/SourceKitHeader.git",
                 .upToNextMajor(from: "2.0.0")),
        .package(url: "https://github.com/johnno1962/SwiftRegex5.git",
                 .upToNextMajor(from: "5.2.3")),
        .package(url: "https://github.com/johnno1962/Fortify.git",
                 .upToNextMajor(from: "2.1.5")),
        .package(url: "https://github.com/johnno1962/Popen.git",
                 .upToNextMajor(from: "1.2.4")),
    ],
    targets: [
        .target(name: "opaqueify", dependencies: ["SourceKitHeader", "SwiftRegex", "Fortify", "Popen"], path: "opaqueify/"),
    ]
)
