import Foundation

/// Options from Settings that change how the app scans, tidies and talks to GitHub.
/// UserDefaults is safe to read from any thread, so scans and lookups read these directly.
/// Demo and snapshot runs always get the defaults, so the pictures never depend on this Mac.
enum Prefs {
    enum Key {
        static let staleDays = "staleDays"
        static let preselectStale = "preselectStale"
        static let protectedBranches = "protectedBranches"
        static let trashOnDelete = "trashOnDelete"
        static let githubRefreshMinutes = "githubRefreshMinutes"
        static let githubInBackground = "githubInBackground"
        static let notifyChecksFailed = "notifyChecksFailed"
        static let notifyMerged = "notifyMerged"
        static let hiddenTools = "hiddenTools"
        static let scanDepth = "scanDepth"
        static let skippedFolders = "skippedFolders"
        static let sizeMaxAgeMinutes = "sizeMaxAgeMinutes"
        static let menuBarIcon = "menuBarIcon"
        static let checkForUpdates = "checkForUpdates"

        /// Everything Reset puts back. Folders, editor, appearance and sounds have their own keys.
        static let all = [
            staleDays, preselectStale, protectedBranches, trashOnDelete, githubRefreshMinutes, githubInBackground,
            notifyChecksFailed, notifyMerged, hiddenTools, scanDepth, skippedFolders, sizeMaxAgeMinutes, menuBarIcon,
            checkForUpdates,
        ]
    }

    enum Default {
        static let staleDays = 30
        static let protectedBranches = ["main", "master", "develop", "dev", "trunk"]
        static let githubRefreshMinutes = 5
        static let scanDepth = 4
        /// Always skipped. Settings can only add to these: walking ~/Library sets off privacy prompts.
        static let skippedFolders = [
            "node_modules", "Pods", "DerivedData", "build", "dist", "vendor", "Carthage", "target", "venv", "Library",
        ]
        static let sizeMaxAgeMinutes = 60
    }

    static let staleDayChoices = [7, 14, 30, 60, 90]
    /// 0 is Manual: only ⌘R and coming back to the front ask GitHub.
    static let githubRefreshChoices = [1, 2, 5, 15, 0]
    static let scanDepthChoices = [2, 3, 4, 5, 6]
    static let sizeMaxAgeChoices = [15, 60, 360, 0]

    /// Tests point this at a throwaway suite, so they never read or write the real settings.
    nonisolated(unsafe) static var testStore: UserDefaults?
    /// The command line tool reads the app's settings domain, wherever it is run from.
    nonisolated(unsafe) static var cliStore: UserDefaults?

    static var store: UserDefaults? {
        if let testStore { return testStore }
        if let cliStore { return cliStore }
        if TestMode.underTests { return TestMode.inertDefaults }
        return DemoData.isOn ? nil : .standard
    }

    /// Also reads a number saved as text, as `defaults write` and launch arguments store it.
    /// Anything else falls back: integer(forKey:) would read "abc" as 0, which means Manually.
    private static func int(_ key: String, _ fallback: Int, in choices: [Int]) -> Int {
        let saved = store?.object(forKey: key)
        let value = (saved as? Int) ?? (saved as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let value, choices.contains(value) else { return fallback }
        return value
    }

    private static func bool(_ key: String) -> Bool { store?.bool(forKey: key) ?? false }

    /// Trimmed, without blanks or repeats, in the order given.
    static func cleaned(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func list(_ key: String, _ fallback: [String]) -> [String] {
        guard let saved = store?.stringArray(forKey: key) else { return fallback }
        return cleaned(saved)
    }

    static var staleDays: Int { int(Key.staleDays, Default.staleDays, in: staleDayChoices) }
    static var staleAfter: TimeInterval { TimeInterval(staleDays) * 86_400 }
    static var preselectStale: Bool { bool(Key.preselectStale) }
    /// Branches that are never tidied and never looked up on GitHub. An emptied list is kept
    /// empty: every branch is then fair game.
    static var protectedBranches: Set<String> { Set(list(Key.protectedBranches, Default.protectedBranches)) }
    static var trashOnDelete: Bool { bool(Key.trashOnDelete) }
    /// nil when GitHub is only asked by hand.
    static var githubRefreshInterval: TimeInterval? {
        let minutes = int(Key.githubRefreshMinutes, Default.githubRefreshMinutes, in: githubRefreshChoices)
        return minutes == 0 ? nil : TimeInterval(minutes) * 60
    }
    static var githubInBackground: Bool { bool(Key.githubInBackground) }
    static var notifyChecksFailed: Bool { bool(Key.notifyChecksFailed) }
    static var notifyMerged: Bool { bool(Key.notifyMerged) }
    /// Creator slugs whose tag is hidden.
    static var hiddenTools: Set<String> { Set(list(Key.hiddenTools, [])) }
    static var scanDepth: Int { int(Key.scanDepth, Default.scanDepth, in: scanDepthChoices) }
    /// Folder names skipped on top of the built-in ones. A name with a slash could never match.
    static var extraSkippedFolders: [String] { list(Key.skippedFolders, []).filter { !$0.contains("/") } }
    static var skippedFolders: Set<String> { Set(Default.skippedFolders + extraSkippedFolders) }
    /// nil when sizes are only measured once, then on demand.
    static var sizeMaxAge: TimeInterval? {
        let minutes = int(Key.sizeMaxAgeMinutes, Default.sizeMaxAgeMinutes, in: sizeMaxAgeChoices)
        return minutes == 0 ? nil : TimeInterval(minutes) * 60
    }
    static var menuBarIcon: Bool { bool(Key.menuBarIcon) }
    /// On unless turned off.
    static var checkForUpdates: Bool { store?.object(forKey: Key.checkForUpdates) as? Bool ?? true }

    static func reset() {
        guard let store else { return }
        for key in Key.all { store.removeObject(forKey: key) }
    }
}
