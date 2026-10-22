import Foundation

/// Fences for tests and for the test copy of the app (scripts/test-app.sh, bundle id ending in
/// ".test"). Once on, it stays on: work still running after a test ended must never fall back to
/// the real gh, the real settings or the real Trash.
enum TestMode {
    /// Set by the test suite before anything runs; never cleared.
    nonisolated(unsafe) static var underTests = false

    /// The test copy of the app, told apart by its bundle id.
    static let isTestApp = Bundle.main.bundleIdentifier?.hasSuffix(".test") == true

    static var on: Bool { underTests || isTestApp }

    /// Settings the test copy reads, written by scripts/test-app.sh into its own domain.
    enum Key {
        static let fakeGh = "testFakeGh"
        static let trash = "testTrash"
        /// Where onboarding looks for project folders, instead of the real home folder.
        static let home = "testHome"
    }

    /// The fake gh for this run: the test copy's own setting, or WORKTREES_GH for the bare
    /// executable (snapshots and dumps run that way). The installed app never takes either.
    static var fakeGh: String? {
        fakeGh(bundleID: Bundle.main.bundleIdentifier, environment: ProcessInfo.processInfo.environment, defaults: .standard)
    }

    static func fakeGh(bundleID: String?, environment: [String: String], defaults: UserDefaults) -> String? {
        if bundleID?.hasSuffix(".test") == true { return defaults.string(forKey: Key.fakeGh) }
        guard bundleID == nil else { return nil }
        return environment["WORKTREES_GH"]
    }

    /// The test copy keeps the user's git config out, like the fixtures were made.
    static var gitEnvironment: [String: String] {
        guard isTestApp else { return [:] }
        // An empty gh config too: even a real gh would find no account.
        let ghConfig = NSTemporaryDirectory() + "worktrees-test-app-gh-config"
        return ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GH_CONFIG_DIR": ghConfig]
    }

    /// The test copy's Trash: a folder next to its fixtures, so Move to Trash never reaches ~/.Trash.
    static var trashFolder: URL? {
        guard isTestApp, let path = UserDefaults.standard.string(forKey: Key.trash) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Settings to read when a test's own suite is gone: an empty one, never the real domain.
    static let inertDefaults = UserDefaults(suiteName: "worktrees-tests-inert")
}
