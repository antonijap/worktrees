// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Worktrees",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Worktrees", path: "Sources/Worktrees")
    ]
)
