// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceCloneStudio",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "VoiceCloneStudio", targets: ["VoiceCloneStudio"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceCloneStudio",
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VoiceCloneStudioTests", dependencies: ["VoiceCloneStudio"], path: "Tests")
    ]
)
