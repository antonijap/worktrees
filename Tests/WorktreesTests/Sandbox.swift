import Foundation
import Testing
@testable import Worktrees

/// Every test suite runs inside this one, one test at a time: the settings suite, the fake gh
/// and the notification sink are process-wide, so parallel tests would trip over each other.
@Suite(.serialized) @MainActor struct All {}

/// Throwaway fixture repos (scripts/make-fixtures.py) with the app pointed at them: its own
/// settings suite, a fake gh, no user git config, notifications caught, a Trash of its own.
/// Nothing reaches the real ~/Code, the real settings, GitHub or the real Trash.
@MainActor
final class Sandbox {
    struct Manifest: Decodable {
        let root: String
        let gh: String
        let fakeGh: String
        let paths: [String: String]
    }

    let dir: URL
    let manifest: Manifest
    let defaults: UserDefaults
    private let suiteName: String
    private(set) var notifications: [(title: String, body: String, url: String)] = []
    let trashDir: URL

    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Fixtures already built (the big ones for timing) are used as they are and kept.
    private let keepFixtures: Bool

    init(existing: URL? = nil) throws {
        TestMode.underTests = true
        keepFixtures = existing != nil
        if let existing {
            dir = existing
        } else {
            Self.sweepLeftovers()
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("worktrees-tests-\(UUID().uuidString.prefix(8))")
            let make = Process()
            make.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            make.arguments = ["-I", Self.repoRoot.appendingPathComponent("scripts/make-fixtures.py").path, dir.path]
            make.standardOutput = FileHandle.nullDevice
            try make.run()
            make.waitUntilExit()
            guard make.terminationStatus == 0 else { throw SandboxError.fixtures }
        }
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: dir.appendingPathComponent("fixtures.json")))

        suiteName = "worktrees-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        trashDir = dir.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)

        Prefs.testStore = defaults
        Shell.ghExecutable = manifest.fakeGh
        // An empty gh config as a second fence: even a real gh would find no account.
        Shell.extraEnvironment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                                  "GH_CONFIG_DIR": dir.appendingPathComponent("gh-config").path]
        Shell.ghExecutable = manifest.fakeGh
        GitHub.viewer = nil
        let trashDir = self.trashDir
        Store.trash = { url in
            let dest = trashDir.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        Notifier.sink = { [weak self] title, body, url in self?.notifications.append((title, body, url)) }
    }

    enum SandboxError: Error { case fixtures, timeout }

    /// A run that crashed never reached close(); its fixtures go the next time.
    private static func sweepLeftovers() {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("worktrees-tests-") {
            let url = tmp.appendingPathComponent(name)
            let made = (try? fm.attributesOfItem(atPath: url.path))?[.creationDate] as? Date ?? .distantPast
            if Date().timeIntervalSince(made) > 600 { try? fm.removeItem(at: url) }
        }
    }

    /// Hooks go back to their fenced test-mode values, never to the real ones: with gh unset,
    /// test mode blocks it; with no settings suite, an empty one is read.
    func close() {
        Prefs.testStore = nil
        Shell.ghExecutable = nil
        Notifier.sink = { _, _, _ in }
        Store.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        GitHub.viewer = nil
        defaults.removePersistentDomain(forName: suiteName)
        if !keepFixtures { try? FileManager.default.removeItem(at: dir) }
    }

    /// Waits for scans and GitHub passes a test started to finish, so none outlives it.
    func settle(_ store: Store) async throws {
        try await waitUntil(15) { !store.isBusy }
    }

    var root: URL { URL(fileURLWithPath: manifest.root) }
    /// A worktree's path as git reports it (symlinks resolved: /private/var/…).
    func path(_ key: String) -> String { manifest.paths[key]! }
    /// A repo's path as the scan reports it (standardized: /var/…).
    func repoPath(_ key: String) -> String { URL(fileURLWithPath: path(key)).standardizedFileURL.path }

    /// A store that scans only the fixtures, already scanned and looked up on GitHub.
    func loadedStore() async -> Store {
        let store = Store(testingRoots: [root])
        await store.refresh()
        return store
    }

    func worktree(_ key: String, in store: Store) -> Worktree? {
        store.locate(worktreeID: path(key))?.1
    }

    /// Writes the canned pull requests gh returns for one repo.
    func setPullRequests(_ slug: String, _ prs: [String: [[String: Any]]]) throws {
        let parts = slug.split(separator: "/")
        let file = URL(fileURLWithPath: manifest.gh).appendingPathComponent("\(parts[0])/\(parts[1]).json")
        try JSONSerialization.data(withJSONObject: prs).write(to: file)
    }

    /// Branches gh was asked about, in call order.
    func askedBranches() -> [String] {
        let log = (try? String(contentsOfFile: manifest.gh + "/calls.log", encoding: .utf8)) ?? ""
        return log.split(separator: "\n").flatMap { line -> [String] in
            guard let fields = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String] else { return [] }
            return fields.filter { $0.key.hasPrefix("b") && $0.key.dropFirst().allSatisfy(\.isNumber) }.map(\.value)
        }
    }

    func signOut() throws {
        try Data().write(to: URL(fileURLWithPath: manifest.gh).appendingPathComponent("signed-out"))
    }

    /// The settings observer runs on the main queue after a write; waits for its effect.
    func waitUntil(_ timeout: Double = 3, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { throw SandboxError.timeout }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// git in a fixture repo, with the same isolation as the fixtures were made with.
    @discardableResult
    func git(_ args: [String], in path: String) async -> Shell.Result {
        await Shell.run("git", ["-C", path] + args, limited: false)
    }
}

/// A pull request as fake-gh returns it.
func fixturePR(_ number: Int, _ branch: String, _ state: String, checks: String? = nil) -> [String: Any] {
    var commit: [String: Any] = [:]
    if let checks {
        commit["statusCheckRollup"] = ["contexts": ["nodes": [[
            "__typename": "CheckRun", "name": "ci", "conclusion": checks, "status": "COMPLETED",
            "detailsUrl": "https://github.com/fixture/alpha/actions/runs/\(number)0/job/1",
        ]]]]
    }
    return [
        "number": number, "title": "Fixture PR \(number)", "state": state, "isDraft": false,
        "url": "https://github.com/fixture/alpha/pull/\(number)", "headRefName": branch, "baseRefName": "main",
        "author": ["login": "fixture-user"], "labels": ["nodes": []], "latestReviews": ["nodes": []],
        "reviewRequests": ["nodes": []], "commits": ["nodes": [["commit": commit]]],
    ]
}
