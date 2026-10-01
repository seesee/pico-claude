// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PicoClaude",
    platforms: [.macOS(.v14)],
    targets: [
        // Everything testable: transcript scanning, merging, MQTT framing.
        .target(name: "PicoClaudeCore"),
        // The menu bar app.
        .executableTarget(name: "PicoClaude", dependencies: ["PicoClaudeCore"]),
        .testTarget(name: "PicoClaudeCoreTests", dependencies: ["PicoClaudeCore"]),
    ]
)
