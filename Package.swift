// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Worktrees",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Worktrees", path: "Sources/Worktrees", exclude: ["Resources"]),
        // Runs on throwaway repos in a temp folder, with a fake gh and its own settings suite.
        .testTarget(name: "WorktreesTests", dependencies: ["Worktrees"], path: "Tests/WorktreesTests"),
    ]
)
