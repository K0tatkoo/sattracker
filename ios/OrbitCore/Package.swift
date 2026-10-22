// swift-tools-version: 6.2
//
// Orbit's engine for iPhone: orbit propagation (a Swift port of the
// satellite.js 5.0.0 that the Android app's page runs,
// app/src/main/assets/lib/satellite.min.js), look angles and passes, the
// category list, and the palette. No UI and no UIKit, so the app and its
// widget share it, and it builds and tests on the Mac with `swift test`.
//
// The port is held to the JavaScript by fixtures that satellite.js itself
// wrote (`node tools/sgp4-fixtures.mjs`, see Tests/OrbitCoreTests/Fixtures).
import PackageDescription

let package = Package(
    name: "OrbitCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
    ],
    targets: [
        .target(name: "OrbitCore"),
        .testTarget(
            name: "OrbitCoreTests",
            dependencies: ["OrbitCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
