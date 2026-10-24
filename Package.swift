// swift-tools-version:5.9
// VougaDev Native for iOS: the shell every VougaDev web app ships as its own App Store app (README.md).
import PackageDescription

let package = Package(
    name: "VougaDevShell",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VougaDevShell", targets: ["VougaDevShell"]),
    ],
    targets: [
        .target(name: "VougaDevShell", resources: [.process("Resources")]),
        .testTarget(name: "VougaDevShellTests", dependencies: ["VougaDevShell"]),
    ]
)
