// swift-tools-version:5.9
// VougaDev Native for iOS: the shell every VougaDev web app ships as its own App Store app (README.md). The core is
// `VougaDevShell`; each shared extension is its own library, which an app adds only when it uses it.
import PackageDescription

let package = Package(
    name: "VougaDevShell",
    defaultLocalization: "en",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "VougaDevShell", targets: ["VougaDevShell"]),
        .library(name: "VougaDevTracking", targets: ["VougaDevTracking"]),
        .library(name: "VougaDevOfflineMap", targets: ["VougaDevOfflineMap"]),
    ],
    dependencies: [
        // Push in every app: FCM on iOS as on Android (VougaDev Notify sends to both); inert without the app's
        // GoogleService-Info.plist.
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "12.0.0"),
    ],
    targets: [
        .target(name: "VougaDevShell", dependencies: [.product(name: "FirebaseMessaging", package: "firebase-ios-sdk")],
                resources: [.process("Resources")]),
        .target(name: "VougaDevTracking", dependencies: ["VougaDevShell"], resources: [.process("Resources")]),
        .target(name: "VougaDevOfflineMap", dependencies: ["VougaDevShell"], resources: [.process("Resources")]),
        .testTarget(name: "VougaDevShellTests", dependencies: ["VougaDevShell", "VougaDevTracking", "VougaDevOfflineMap"]),
    ]
)
