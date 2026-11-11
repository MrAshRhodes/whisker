// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Whisker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Whisker", targets: ["Whisker"]),
        .library(name: "WhiskerCore", targets: ["WhiskerCore"]),
    ],
    dependencies: [
        // Pinned exactly: the updater verifies what gets installed, so a new Sparkle is a reviewed change.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
    ],
    targets: [
        // Pure logic: settings model, profiles, button actions, pointer and scroll curves, per-app matching.
        .target(name: "WhiskerCore", path: "Sources/WhiskerCore"),
        // App shell: event engine, menu bar item, settings window, permissions, login item, updates.
        .executableTarget(
            name: "Whisker",
            dependencies: ["WhiskerCore", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Whisker",
            // Sparkle.framework is embedded in Contents/Frameworks by Scripts/build_app.sh.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(name: "WhiskerCoreTests", dependencies: ["WhiskerCore"], path: "Tests/WhiskerCoreTests"),
        .testTarget(name: "WhiskerAppTests", dependencies: ["Whisker"], path: "Tests/WhiskerAppTests"),
    ]
)
