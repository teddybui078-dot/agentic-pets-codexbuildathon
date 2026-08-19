// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AgenticPets",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AgenticPets",
            path: "Sources/AgenticPets",
            resources: [.copy("Resources")]
        )
    ]
)
