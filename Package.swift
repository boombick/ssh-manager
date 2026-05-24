// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSHManager",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SSHManager",
            path: "Sources/SSHManager",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
