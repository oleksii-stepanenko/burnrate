// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Burnrate",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Burnrate",
            path: "Sources/Burnrate",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
