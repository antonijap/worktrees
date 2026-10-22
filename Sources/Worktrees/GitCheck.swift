import Foundation

/// Whether git can run. /usr/bin/git on a fresh Mac is only a stand-in that opens the Command
/// Line Tools installer when run, so it is run only once a real git is known to be there.
enum GitCheck {
    enum Status: Equatable, Sendable {
        case ready
        case missing
        /// Xcode's git is there, but every call fails until its license is accepted.
        case licenseNotAccepted
        /// A git is installed but fails to run for some other reason.
        case broken

        var message: String? {
            switch self {
            case .ready: nil
            case .missing: "Git isn't installed. Run \(GitCheck.installCommand) in a terminal, then rescan."
            case .licenseNotAccepted: "Git needs the Xcode license accepted. Run \(GitCheck.licenseCommand) in a terminal, then rescan."
            case .broken: "Git is installed but won't run. Try git --version in a terminal to see why, then rescan."
            }
        }
    }

    /// Tests set this to pretend.
    nonisolated(unsafe) static var override: Status?

    static let installCommand = "xcode-select --install"
    static let licenseCommand = "sudo xcodebuild -license accept"

    static var status: Status {
        if let override { return override }
        let fm = FileManager.default
        // Homebrew's git comes first on the app's PATH and needs nothing from Xcode.
        if ["/opt/homebrew/bin/git", "/usr/local/bin/git"].contains(where: fm.isExecutableFile(atPath:)) { return .ready }
        let developer = run("/usr/bin/xcode-select", ["-p"]).out
        let candidates = ["/Library/Developer/CommandLineTools/usr/bin/git"] + (developer.isEmpty ? [] : [developer + "/usr/bin/git"])
        guard candidates.contains(where: fm.isExecutableFile(atPath:)) else { return .missing }
        // A real git is there, so the stand-in passes through to it instead of offering an install.
        let probe = run("/usr/bin/git", ["--version"])
        if probe.status == 0 { return .ready }
        return probe.status == 69 ? .licenseNotAccepted : .broken
    }

    static var isInstalled: Bool { status == .ready }

    private static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
