import AppKit
import Foundation
import Observation

/// First launch: pick the folders to scan, check gh, offer a few extras. Shown instead of
/// assuming everyone keeps their projects in ~/Code.
enum Onboarding {
    static let doneKey = "onboarded"

    /// Needed until finished once. Someone who used an earlier version skips it: they have saved
    /// folders, or at least a saved main window (0.1.0 scanned ~/Code without saving it).
    /// Demo and snapshot runs never show it on their own.
    static func isNeeded(_ defaults: UserDefaults = .standard) -> Bool {
        guard !DemoData.isOn else { return false }
        if defaults.bool(forKey: doneKey) { return false }
        return ["roots", "root", "NSWindow Frame Main"].allSatisfy { defaults.object(forKey: $0) == nil }
    }

    static func markDone(_ defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: doneKey)
    }
}

/// A folder in the home folder that holds repos, offered on the Folders step.
struct FolderSuggestion: Identifiable, Hashable, Sendable {
    let url: URL
    let repoCount: Int
    var picked: Bool
    var id: String { url.path }
}

enum FolderFinder {
    /// Where people keep projects, checked right in the home folder, in this order.
    static let names = [
        "Code", "Developer", "Projects", "src", "dev", "repos", "git", "GitHub", "workspace", "Sites", "work",
    ]

    /// Never looked into without being chosen: macOS asks for permission the moment an app
    /// reads these, which is no way to start. Choose Another Folder reaches them without a prompt.
    static let protected: Set<String> = ["Documents", "Desktop", "Downloads", "Library", "Pictures", "Movies", "Music"]

    /// The folders under `home` that hold at least one repo, most repos first. Slow (walks
    /// folders), so call it off the main thread. Two names for one folder (Code and code on a
    /// case-insensitive disk, or a symlink) count once.
    static func find(home: URL, depth: Int, skipping: Set<String>) -> [FolderSuggestion] {
        var seen = Set<String>()
        var result: [FolderSuggestion] = []
        for name in names {
            let url = home.appendingPathComponent(name)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileResourceIdentifierKey, .canonicalPathKey]),
                  values.isDirectory == true else { continue }
            let identity = values.fileResourceIdentifier.map { "\($0)" } ?? values.canonicalPath ?? url.path
            guard seen.insert(identity).inserted else { continue }
            let count = Scanner.findRepos(root: url, maxDepth: depth, skipping: skipping, home: home).count
            if count > 0 { result.append(FolderSuggestion(url: url, repoCount: count, picked: true)) }
        }
        return result.sorted { $0.repoCount > $1.repoCount }
    }

    /// Repos in one folder the person chose themselves.
    static func count(in url: URL, depth: Int, skipping: Set<String>) -> Int {
        Scanner.findRepos(root: url, maxDepth: depth, skipping: skipping).count
    }

    /// The home folder to look in. The test copy of the app looks in its fixtures instead.
    static var home: URL {
        if TestMode.isTestApp, let path = UserDefaults.standard.string(forKey: TestMode.Key.home) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }
}

/// Where gh stands, for the GitHub step.
enum GitHubSetup: Equatable, Sendable {
    case notInstalled
    case signedOut(path: String)
    case ready(path: String, login: String?)

    static func check() async -> GitHubSetup {
        guard let path = await installedPath() else { return .notInstalled }
        guard await GitHub.signedIn() else { return .signedOut(path: path) }
        return .ready(path: path, login: await GitHub.viewerLogin())
    }

    /// The fake gh in tests and the test copy, otherwise wherever `which` finds it.
    private static func installedPath() async -> String? {
        if let fake = Shell.ghExecutable {
            return FileManager.default.isExecutableFile(atPath: fake) ? fake : nil
        }
        guard !TestMode.on else { return nil }
        let which = await Shell.run("which", ["gh"], limited: false)
        let path = which.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return which.ok && !path.isEmpty ? path : nil
    }
}

/// What the scan found, for the All set step.
struct OnboardingStats: Equatable {
    var repos = 0
    var worktrees = 0
    var attention = 0
    var tidy = 0

    @MainActor init(store: Store) {
        repos = store.repos.count
        worktrees = store.repos.reduce(0) { $0 + $1.extraWorktreeCount }
        attention = store.repos.reduce(0) { total, repo in total + repo.worktrees.filter { WorktreeState($0).needsAttention }.count }
        tidy = store.lastGitHub == nil ? 0 : TidyCandidate.candidates(in: store.repos).count
    }

    init(repos: Int, worktrees: Int, attention: Int, tidy: Int) {
        self.repos = repos
        self.worktrees = worktrees
        self.attention = attention
        self.tidy = tidy
    }
}

@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable {
        case welcome, folders, github, ready

        var name: String {
            switch self {
            case .welcome: "Welcome"
            case .folders: "Folders"
            case .github: "GitHub"
            case .ready: "All set"
            }
        }
    }

    var step: Step = .welcome
    var suggestions: [FolderSuggestion] = []
    var finding = false
    var github: GitHubSetup?
    var checkingGitHub = false
    /// Checked when the Folders step opens. Without git, folders can be picked but no repo read.
    var gitStatus: GitCheck.Status = .ready
    let store: Store
    private let home: URL

    init(store: Store, home: URL = FolderFinder.home) {
        self.store = store
        self.home = home
        store.onboardingActive = true
    }

    var pickedFolders: [URL] { suggestions.filter(\.picked).map(\.url) }
    var canContinue: Bool { step != .folders || !pickedFolders.isEmpty }

    func start() {
        guard suggestions.isEmpty, !finding else { return }
        finding = true
        let home = self.home
        let depth = Prefs.scanDepth
        let skipped = Prefs.skippedFolders
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                FolderFinder.find(home: home, depth: depth, skipping: skipped)
            }.value
            // Folders chosen by hand while looking stay, after the ones found.
            let chosen = suggestions.filter { s in !found.contains { $0.id == s.id } }
            suggestions = found + chosen
            finding = false
        }
    }

    /// Adds folders picked in the open panel, ticked, with their repo count.
    func add(_ urls: [URL]) async {
        let depth = Prefs.scanDepth
        let skipped = Prefs.skippedFolders
        for url in urls {
            let real = url.resolvingSymlinksInPath().standardizedFileURL
            if let i = suggestions.firstIndex(where: { $0.url.resolvingSymlinksInPath().standardizedFileURL == real }) {
                suggestions[i].picked = true
                continue
            }
            let count = await Task.detached(priority: .userInitiated) {
                FolderFinder.count(in: url, depth: depth, skipping: skipped)
            }.value
            suggestions.append(FolderSuggestion(url: url, repoCount: count, picked: true))
        }
    }

    func toggle(_ suggestion: FolderSuggestion) {
        guard let i = suggestions.firstIndex(of: suggestion) else { return }
        suggestions[i].picked.toggle()
    }

    func next() {
        guard canContinue else { return }
        switch step {
        case .welcome:
            step = .folders
            start()
            Task { gitStatus = await Task.detached(priority: .userInitiated) { GitCheck.status }.value }
        case .folders:
            // The scan starts now, so All set has numbers by the time it shows. Nothing is
            // saved until Open Worktrees: quitting halfway brings onboarding back.
            store.setRoots(pickedFolders, save: false)
            Task { await store.refresh() }
            step = .github
            checkGitHub()
        case .github:
            step = .ready
        case .ready:
            break
        }
    }

    func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    func checkGitHub() {
        guard !checkingGitHub else { return }
        checkingGitHub = true
        // Back to Checking, so a second look that ends the same way still shows it happened.
        github = nil
        Task {
            let result = await GitHubSetup.check()
            github = result
            checkingGitHub = false
            // Signed in after all: the scan's PR pass may have run without it.
            if case .ready = result, store.githubSignedIn == false { await store.loadGitHub() }
        }
    }

    var stats: OnboardingStats { OnboardingStats(store: store) }

    /// Open Worktrees: the folders are saved and onboarding won't come back. Folders added in
    /// Settings meanwhile are kept: the store's list is the one saved.
    func finish(_ defaults: UserDefaults = .standard) {
        store.onboardingActive = false
        store.setRoots(store.roots, save: true)
        Onboarding.markDone(defaults)
    }
}
