// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "meetnote",
    platforms: [.macOS("26.0")],
    targets: [
        .target(
            name: "MeetnoteCore",
            path: "Sources/MeetnoteCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "meetnote",
            dependencies: ["MeetnoteCore"],
            path: "Sources/meetnote",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Embed Info.plist so TCC permission prompts (mic / system
                // audio) carry proper usage descriptions for a bare CLI binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .executableTarget(
            name: "MeetnoteBar",
            dependencies: ["MeetnoteCore"],
            path: "Sources/MeetnoteBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
