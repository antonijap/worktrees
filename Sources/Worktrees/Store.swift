import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class Store {
    /// The one the app runs on. Snapshot and dump runs make their own.
    static let shared = Store()

    /// Folders to scan. Each can hold many projects (~/Code) or be a single repo.
    var roots: [URL] {
        didSet { if !DemoData.isOn, !isTesting, saveRoots, !onboardingActive { UserDefaults.standard.set(roots.map(\.path), forKey: "roots") } }
    }
    @ObservationIgnored private var saveRoots = true
    /// Until onboarding finishes, folder changes (from Settings too) are not saved, and commands
    /// that need the main window are off.
    var onboardingActive = false

    /// Onboarding scans the folders picked so far without saving them.
    func setRoots(_ urls: [URL], save: Bool) {
        saveRoots = save
        roots = urls
        saveRoots = true
    }
    private var isTesting: Bool { Prefs.testStore != nil }
    var repos: [Repo] = []
    var isScanning = false
    var isLoadingGitHub = false
    /// Whether the details column is on screen, and whether the window has room for it at
    /// all, as the layout last worked them out. The View menu reads these.
    var detailsShown = true
    var detailsCanShow = true
    var progress = ""
    var githubNote: String?
    var deleteError: String?
    /// When anything was last read from git, full scan or one repo. The footer shows it.
    var lastScan: Date?
    /// When every folder was last scanned. Rescan-on-activate goes by this one.
    var lastFullScan: Date?
    /// When each repo was last read, for the detail column to reload on.
    var repoRefreshed: [String: Date] = [:]
    /// When GitHub was last asked about every repo.
    var lastGitHub: Date?
    /// Failed lookups per repo from the latest pass over it, for the status line.
    private var githubFailures: [String: Int] = [:]
    private var githubSignedInAt: Date?
    /// A newer release than this build, once the daily check has found one.
    var availableUpdate: UpdateCheck.Release?

    /// Looks for a newer release at most once a day, after a GitHub pass found gh signed in.
    /// A failed look counts as the day's look too, so a 404 or a rate limit isn't retried on
    /// every pass. What it finds is kept, so the notice survives a relaunch.
    func checkForUpdate(current: String? = UpdateCheck.current, now: Date = .now) async {
        guard !DemoData.isOn, let defaults = Prefs.store else { return }
        guard Prefs.checkForUpdates, let current else {
            availableUpdate = nil
            return
        }
        if availableUpdate == nil { availableUpdate = UpdateCheck.saved(in: defaults, newerThan: current) }
        guard githubSignedIn == true else { return }
        if let last = defaults.object(forKey: UpdateCheck.lastCheckKey) as? Date, now.timeIntervalSince(last) < UpdateCheck.interval { return }
        defaults.set(now, forKey: UpdateCheck.lastCheckKey)
        guard let latest = await UpdateCheck.latest() else { return }
        UpdateCheck.save(latest, in: defaults)
        availableUpdate = UpdateCheck.isNewer(latest.version, than: current) ? latest : nil
    }

    enum UpdateAnswer: Equatable {
        case upToDate(String)
        case available(UpdateCheck.Release)
        case cantCheck(String)
    }

    /// Check for Updates in the menu: asks now, whatever the daily schedule and the setting say,
    /// since the person asked. Still only through gh.
    func checkForUpdateNow(current: String? = UpdateCheck.current) async -> UpdateAnswer {
        guard let current else { return .cantCheck("This build has no version number to compare.") }
        guard await GitHub.signedIn() else {
            return .cantCheck("Worktrees checks through gh, and gh isn't signed in. New versions are listed on github.com/antonijap/worktrees/releases.")
        }
        guard let latest = await UpdateCheck.latest() else {
            return .cantCheck("GitHub didn't answer. Try again in a moment.")
        }
        if let defaults = Prefs.store {
            UpdateCheck.save(latest, in: defaults)
            defaults.set(Date(), forKey: UpdateCheck.lastCheckKey)
        }
        guard UpdateCheck.isNewer(latest.version, than: current) else {
            availableUpdate = nil
            return .upToDate(current)
        }
        availableUpdate = latest
        return .available(latest)
    }

    /// Whether git could run at the last scan. Without it no repo can be read.
    var gitStatus: GitCheck.Status = .ready
    /// Whether gh had a token at the last GitHub pass. nil until the first one.
    var githubSignedIn: Bool?
    /// Failing and merged, per PR URL, as last seen. A notification only goes out for a change
    /// from a state seen before, so the first pass after launch stays quiet.
    @ObservationIgnored private var prSeen: [String: (failing: Bool, merged: Bool)] = [:]
    private var githubRunning = false
    /// Repos a queued GitHub pass must cover; nil means all of them.
    private var githubQueuedScope: Set<String>? = []

    /// The worktree shown in the detail column. Lives here so menu commands can act on it.
    var selectedID: String?
    /// Worktree whose delete confirmation is showing.
    var confirmDeleteID: String?
    /// Filter text shared by the folder and worktree columns.
    var filter = ""
    /// Bumped to ask the filter field to take focus (⌘F).
    var focusFilterRequest = 0
    /// One-line message in the status bar, e.g. after a delete. Clears itself.
    var notice: String?
    /// A glyph shown before the notice, e.g. a check when a tidy up finished.
    var noticeIcon: IconName?
    /// The Tidy up sheet is showing.
    var showTidyUp = false

    /// A short word next to the Tidy up button instead of the sheet, when there is nothing to
    /// offer: shown for two seconds. `tidyNoteCount` goes up each time, so the broom sweeps again.
    enum TidyNote: Equatable {
        case allTidy, checking, needsGitHub
        var text: String {
            switch self {
            case .allTidy: "All tidy"
            case .checking: "Checking GitHub…"
            case .needsGitHub: "Needs GitHub"
            }
        }
        var announcement: String {
            switch self {
            case .allTidy: "All tidy, nothing to clean"
            case .checking: "Checking GitHub, try Tidy up again in a moment"
            case .needsGitHub: "Tidy up needs GitHub to tell which worktrees are done"
            }
        }
    }
    var tidyNote: TidyNote?
    var tidyNoteCount = 0
    @ObservationIgnored private var tidyNoteHide: Task<Void, Never>?

    func showTidyNote(_ note: TidyNote) {
        tidyNote = note
        tidyNoteCount += 1
        announce(note.announcement)
        tidyNoteHide?.cancel()
        tidyNoteHide = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.tidyNote = nil
        }
    }

    /// Opens the Tidy up sheet from the button, the menu or ⇧⌘T, when there is something to
    /// clean. Otherwise the button says so (All tidy, or that GitHub hasn't answered yet: before
    /// it has, an open PR looks like no PR). An alert that is up would swallow the sheet, so a
    /// pending delete question or error is dropped first. A flag left at true by a sheet that
    /// went away without SwiftUI noticing (the window was closed under it) is flipped so the
    /// sheet presents again.
    func openTidyUp() {
        guard lastGitHub != nil else {
            showTidyNote(isLoadingGitHub || isScanning ? .checking : .needsGitHub)
            return
        }
        guard !TidyCandidate.candidates(in: repos).isEmpty else {
            showTidyNote(.allTidy)
            return
        }
        tidyNote = nil
        confirmDeleteID = nil
        deleteError = nil
        if showTidyUp {
            showTidyUp = false
            DispatchQueue.main.async { self.showTidyUp = true }
        } else {
            showTidyUp = true
        }
    }
    /// Folder size in bytes per worktree path, measured in the background after each scan.
    var sizes: [String: Int64] = [:]
    private var sizing: Set<String> = []
    private var sizeMeasuredAt: [String: Date] = [:]

    /// Worktrees being deleted. Hidden from scan results until git has forgotten them,
    /// so a scan that started before the delete can't bring the row back.
    private var pendingDeletes: Set<String> = []
    private var settledDeletes: Set<String> = []

    private var rescanQueued = false
    private var githubQueued = false
    /// Which scanned folder each repo was found under, for per-repo refreshes.
    private var repoRoots: [String: URL] = [:]
    /// Repos being re-read on their own, and ones that changed again meanwhile.
    private var refreshingRepos: Set<String> = []
    private var repoRefreshQueued: Set<String> = []
    private var watcher: RepoWatcher?
    /// Moves a folder to the Trash and returns where it went. Tests swap in a folder of their own.
    nonisolated(unsafe) static var trash: (URL) throws -> URL? = { url in
        if let folder = TestMode.trashFolder {
            let dest = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        guard !TestMode.underTests else { throw CocoaError(.fileWriteNoPermission) }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// How long a partial GitHub pass trusts the last sign-in check.
    nonisolated static let githubSignInTrust: TimeInterval = 5 * 60
    /// True while the filter field has focus, so ⌘⌫ deletes text there instead of a worktree.
    var filterFocused = false

    /// For tests: scans only `roots`, with no file watcher and no GitHub timer, and never
    /// saves the folders.
    init(testingRoots: [URL]) {
        roots = testingRoots
        prefsSeen = PrefsSnapshot()
        // Only its own test's settings suite: a store left over from an earlier test must not
        // react to a later test's writes.
        let own = Prefs.testStore
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: own, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, own != nil, Prefs.testStore === own else { return }
                self.prefsChanged()
            }
        }
    }

    init() {
        if DemoData.isOn {
            roots = [URL(fileURLWithPath: DemoData.home + "/Code")]
            return
        }
        if let saved = UserDefaults.standard.stringArray(forKey: "roots") {
            roots = saved.map { URL(fileURLWithPath: $0) }
        } else if let legacy = UserDefaults.standard.string(forKey: "root") {
            // Earlier builds kept a single folder.
            roots = [URL(fileURLWithPath: legacy)]
        } else if Onboarding.isNeeded() {
            // Onboarding asks; nothing is scanned until folders are picked.
            roots = []
        } else {
            let code = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Code")
            roots = FileManager.default.fileExists(atPath: code.path) ? [code] : []
        }
        prefsSeen = PrefsSnapshot()
        syncBackgroundActivity()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefsChanged() }
        }
        watcher = RepoWatcher { [weak self] path in
            guard let self else { return }
            Task { await self.refreshRepo(path: path) }
        }
        startGitHubTimer()
    }

    /// Asks GitHub again every few minutes (Settings picks how often, or never), only while the
    /// app is in use unless Settings says to keep going in the background. Coming back to the
    /// front rescans anyway.
    private func startGitHubTimer() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                // Counted from the last full pass, so a scan that just asked GitHub resets the clock
                // and waking from sleep doesn't fire on top of the activate rescan.
                guard let interval = Prefs.githubRefreshInterval,
                      NSApplication.shared.isActive || Prefs.githubInBackground,
                      !self.repos.isEmpty, !self.isScanning, !self.isLoadingGitHub,
                      Date().timeIntervalSince(self.lastGitHub ?? .distantPast) >= interval
                else { continue }
                await self.loadGitHub()
            }
        }
    }

    /// The settings that change what is on screen, as last acted on. UserDefaults reports every
    /// change (column widths too), so only a real change to one of these does anything.
    private struct PrefsSnapshot: Equatable {
        var scanDepth = Prefs.scanDepth
        var skipped = Prefs.skippedFolders
        var protected = Prefs.protectedBranches
        var display = [String(Prefs.staleDays), String(Prefs.preselectStale), String(Prefs.trashOnDelete),
                       String(Prefs.checkForUpdates)] + Prefs.hiddenTools.sorted()
    }
    @ObservationIgnored private var prefsSeen: PrefsSnapshot?
    @ObservationIgnored private var backgroundActivity: NSObjectProtocol?

    private func prefsChanged() {
        guard !DemoData.isOn else { return }
        syncBackgroundActivity()
        let now = PrefsSnapshot()
        guard let before = prefsSeen, now != before else { return }
        prefsSeen = now
        if now.scanDepth != before.scanDepth || now.skipped != before.skipped {
            Task { await refresh() }
        } else if now.protected != before.protected {
            // Branches taken off the list need a lookup; the pass also drops the PR of ones added.
            Task { await loadGitHub() }
        }
        if !Prefs.checkForUpdates { availableUpdate = nil }
        let hidden = Prefs.hiddenTools
        var updated = repos
        for r in updated.indices {
            for w in updated[r].worktrees.indices {
                let wt = updated[r].worktrees[w]
                updated[r].worktrees[w].creatorHidden = wt.creator.map { hidden.contains($0.slug) } ?? false
            }
        }
        repos = updated
        // The Tidy up sheet reads stale days and the Trash setting as it draws.
        prefsVersion += 1
    }

    /// Goes up when a setting that changes what is drawn changes. Views that read settings as
    /// they draw read this, so they draw again.
    var prefsVersion = 0

    /// Background refresh only works if App Nap lets the timer run.
    private func syncBackgroundActivity() {
        let wanted = Prefs.githubInBackground && Prefs.githubRefreshInterval != nil
        if wanted, backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Checking GitHub in the background"
            )
        } else if !wanted, let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
        }
    }

    /// Scanning, re-reading a repo or asking GitHub. Tests wait for this to settle.
    var isBusy: Bool { isScanning || githubRunning || !refreshingRepos.isEmpty }

    /// Repos found under one scanned folder, for Settings.
    func repoCount(in root: URL) -> Int {
        let path = root.standardizedFileURL.path
        return repoRoots.values.filter { $0.standardizedFileURL.path == path }.count
    }

    /// Adds folders, skipping ones already listed, then rescans.
    func addRoots(_ urls: [URL]) {
        guard !DemoData.isOn else { return }
        let known = Set(roots.map(\.standardizedFileURL.path))
        let new = urls.filter { !known.contains($0.standardizedFileURL.path) }
        guard !new.isEmpty else { return }
        roots += new
        Task { await refresh() }
    }

    func removeRoot(_ url: URL) {
        guard !DemoData.isOn else { return }
        roots.removeAll { $0.standardizedFileURL.path == url.standardizedFileURL.path }
        Task { await refresh() }
    }

    /// "~/Code/work" for one folder, "3 folders" for several.
    var rootsSummary: String {
        switch roots.count {
        case 0: "no folders"
        case 1: roots[0].path.abbreviatingHome
        default: "\(roots.count) folders"
        }
    }

    func locate(worktreeID: String) -> (Repo, Worktree)? {
        for repo in repos {
            if let wt = repo.worktrees.first(where: { $0.id == worktreeID }) { return (repo, wt) }
        }
        return nil
    }

    func refresh() async {
        if DemoData.isOn {
            GitHub.viewer = DemoData.viewer
            githubSignedIn = true
            repos = DemoData.repos()
            DemoData.seedLogs()
            for r in repos.indices { repos[r].worktrees.removeAll { pendingDeletes.contains($0.id) } }
            sizes = DemoData.sizes(for: repos)
            lastScan = Date()
            lastFullScan = lastScan
            lastGitHub = lastScan
            for repo in repos { repoRefreshed[repo.id] = lastScan }
            return
        }
        guard !isScanning else {
            // A folder was added or removed mid-scan; run again once this one ends.
            rescanQueued = true
            return
        }
        isScanning = true
        // Checked off the main thread (it runs xcode-select and git once). Without a working git
        // nothing is scanned: on a fresh Mac, running git would open the tools installer.
        gitStatus = await Task.detached(priority: .userInitiated) { GitCheck.status }.value
        guard gitStatus == .ready else {
            isScanning = false
            lastScan = Date()
            return
        }

        progress = "Finding repositories…"
        // Deletes that finished before this scan started are safe to stop hiding afterwards.
        let settledAtStart = settledDeletes
        let roots = self.roots
        let depth = Prefs.scanDepth
        let skipped = Prefs.skippedFolders
        // Repo path paired with the scanned folder it was found under; a repo reachable
        // from two folders is listed once.
        let found: [(path: String, root: URL)] = await Task.detached(priority: .userInitiated) {
            var seen = Set<String>()
            var result: [(path: String, root: URL)] = []
            for root in roots {
                for path in Scanner.findRepos(root: root, maxDepth: depth, skipping: skipped) where seen.insert(path).inserted {
                    result.append((path, root))
                }
            }
            return result
        }.value

        repoRoots = Dictionary(found.map { ($0.path, $0.root) }, uniquingKeysWith: { a, _ in a })
        var loaded: [Repo] = []
        progress = "Reading 0 of \(found.count)"
        // Repos show as they come in, a few times a second, so the first ones are on screen
        // long before the slowest finishes. Known repos not re-read yet keep their old rows.
        let foundPaths = Set(found.map(\.path))
        let previous = repos.filter { foundPaths.contains($0.id) }
        var published = Date.distantPast
        func publish(final: Bool) {
            guard final || Date().timeIntervalSince(published) > 0.1 else { return }
            published = Date()
            let fresh = Set(loaded.map(\.id))
            // The final list is what was read this time; a repo that failed to load drops out
            // rather than living on as its old row. Deletes in flight stay hidden throughout.
            var rows = final ? loaded : loaded + previous.filter { !fresh.contains($0.id) }
            for r in rows.indices { rows[r].worktrees.removeAll { pendingDeletes.contains($0.id) } }
            repos = rows.sorted { ($0.group, $0.name.lowercased(), $0.path) < ($1.group, $1.name.lowercased(), $1.path) }
        }
        await withTaskGroup(of: Repo?.self) { group in
            for item in found {
                group.addTask { await Scanner.loadRepo(path: item.path, root: item.root) }
            }
            for await repo in group {
                if var repo {
                    carryOver(into: &repo, previous: previous)
                    loaded.append(repo)
                }
                progress = "Reading \(loaded.count) of \(found.count)"
                publish(final: false)
            }
        }

        pendingDeletes.subtract(settledAtStart)
        settledDeletes.subtract(settledAtStart)
        // Scanning ends before the final publish, so the list may settle into its new order
        // in one move. Nothing awaits between here and the GitHub pass below.
        isScanning = false
        progress = ""
        publish(final: true)
        lastScan = Date()
        lastFullScan = lastScan
        for repo in repos { repoRefreshed[repo.id] = lastScan }
        watcher?.watch(repoPaths: repos.map(\.path))
        // Sizes come later and never hold up the scan. Main checkouts are skipped here (they
        // can't be tidied and carry the whole .git); the detail view measures one on demand.
        let paths = loaded.flatMap(\.worktrees).filter { !$0.isPrunable && !$0.isMain }.map(\.path)
        Task(priority: .utility) { await loadSizes(for: paths) }
        // A newer scan may start while GitHub loads below; isScanning is already down, so
        // this one can't mark that one finished.
        if rescanQueued {
            rescanQueued = false
            await refresh()
            return
        }
        await loadGitHub()
    }

    /// Keeps PR data from the last scan on screen until GitHub answers again, but only while
    /// the worktree is still on that PR's branch. A switched branch gets no stale PR.
    /// Also hides worktrees that are being deleted.
    private func carryOver(into repo: inout Repo, previous: [Repo]? = nil) {
        let previous = Dictionary(
            (previous ?? repos).first { $0.id == repo.id }?.worktrees.map { ($0.id, $0.pullRequest) } ?? [],
            uniquingKeysWith: { a, _ in a }
        )
        for w in repo.worktrees.indices {
            let wt = repo.worktrees[w]
            if let pr = previous[wt.id] ?? nil, pr.headRefName == wt.remoteBranch {
                repo.worktrees[w].pullRequest = pr
            }
        }
        repo.worktrees.removeAll { pendingDeletes.contains($0.id) }
    }

    /// Re-reads one repo after git changed something in it. A full scan already running
    /// will pick the change up, so this only runs between scans.
    func refreshRepo(path: String) async {
        guard !isScanning, !DemoData.isOn, let root = repoRoots[path] else { return }
        guard !refreshingRepos.contains(path) else {
            repoRefreshQueued.insert(path)
            return
        }
        refreshingRepos.insert(path)
        defer { refreshingRepos.remove(path) }
        repeat {
            repoRefreshQueued.remove(path)
            let settledAtStart = settledDeletes
            let loaded = await Scanner.loadRepo(path: path, root: root)
            guard !isScanning, let r = repos.firstIndex(where: { $0.id == path }) else { return }
            guard var repo = loaded else {
                // The repo folder itself is gone: drop it rather than showing a ghost until ⌘R.
                if !FileManager.default.fileExists(atPath: path + "/.git") {
                    repos.remove(at: r)
                    repoRoots[path] = nil
                    watcher?.watch(repoPaths: repos.map(\.path))
                }
                return
            }
            carryOver(into: &repo)
            // Prune ran before this listing, so deletes settled by then are done hiding.
            pendingDeletes.subtract(settledAtStart)
            settledDeletes.subtract(settledAtStart)
            repos[r] = repo
            lastScan = Date()
            repoRefreshed[path] = lastScan
            if ProcessInfo.processInfo.environment["WORKTREES_TRACE"] != nil {
                FileHandle.standardError.write("refreshed \(path): \(repo.worktrees.count) worktrees\n".data(using: .utf8)!)
            }
            // Main checkouts are skipped here as in the full scan; the detail view measures on demand.
            let paths = repo.worktrees.filter { !$0.isPrunable && !$0.isMain }.map(\.path)
            Task(priority: .utility) { await loadSizes(for: paths) }
            await loadGitHub(only: [path])
        } while repoRefreshQueued.contains(path)
    }

    /// Loads PR data. If a load is already running, queues one more pass so worktrees
    /// found by a newer scan still get looked up.
    func loadGitHub(only repoIDs: Set<String>? = nil) async {
        guard !DemoData.isOn else { return }
        guard !githubRunning else {
            // Queue the union of what was asked for; a full pass (nil) covers everything.
            githubQueued = true
            if let repoIDs, let queued = githubQueuedScope { githubQueuedScope = queued.union(repoIDs) }
            else { githubQueuedScope = nil }
            return
        }
        // Set before the first await, so a second caller can't slip in during the sign-in check.
        githubRunning = true
        var scope = repoIDs
        repeat {
            githubQueued = false
            githubQueuedScope = []
            // The footer only shows the spinner for a full pass; one repo's refresh stays quiet.
            isLoadingGitHub = scope == nil
            await loadGitHubOnce(only: scope)
            scope = githubQueuedScope
        } while githubQueued
        isLoadingGitHub = false
        githubRunning = false
        await checkForUpdate()
    }

    private func loadGitHubOnce(only repoIDs: Set<String>?) async {
        // gh auth status hits the network; a partial pass trusts a recent full one.
        let signedIn: Bool
        if let at = githubSignedInAt, repoIDs != nil, Date().timeIntervalSince(at) < Store.githubSignInTrust {
            signedIn = true
        } else {
            signedIn = await GitHub.signedIn()
            githubSignedInAt = signedIn ? Date() : nil
        }
        githubSignedIn = signedIn
        guard signedIn else {
            githubNote = "GitHub status is off: gh isn't signed in. Run `gh auth login`, then refresh."
            return
        }
        if GitHub.viewer == nil { GitHub.viewer = await GitHub.viewerLogin() }
        if repoIDs == nil { githubFailures = [:] } else { for id in repoIDs ?? [] { githubFailures[id] = nil } }
        defer {
            if repoIDs == nil { lastGitHub = Date() }
            let failures = githubFailures.values.reduce(0, +)
            githubNote = failures == 0 ? nil
                : "\(failures) GitHub lookup\(failures == 1 ? "" : "s") failed, showing older data"
        }

        struct Job: Sendable {
            let repoID: String
            let worktreeID: String
            let slug: String
            let branch: String
        }

        // Protected branches never have a PR of their own, so they are not looked up.
        let protected = Prefs.protectedBranches
        let jobs: [Job] = repos.flatMap { repo -> [Job] in
            if let repoIDs, !repoIDs.contains(repo.id) { return [] }
            guard let slug = repo.githubRemote?.githubSlug else { return [] }
            return repo.worktrees.compactMap { wt in
                guard let branch = wt.remoteBranch, !protected.contains(branch) else { return nil }
                return Job(repoID: repo.id, worktreeID: wt.id, slug: slug, branch: branch)
            }
        }

        // One gh call per repo answers every branch in it.
        let byRepo = Dictionary(grouping: jobs, by: \.repoID)
        await withTaskGroup(of: [(Job, GitHub.Lookup)].self) { group in
            for (_, repoJobs) in byRepo {
                group.addTask {
                    let lookups = await GitHub.pullRequests(slug: repoJobs[0].slug, branches: Array(Set(repoJobs.map(\.branch))))
                    return repoJobs.map { ($0, lookups[$0.branch] ?? .failed) }
                }
            }
            // Results land in a copy and are published once, so the lists don't re-render per PR.
            var results: [(Job, GitHub.Lookup)] = []
            for await part in group { results += part }
            var updated = repos
            // A branch on the protected list has no lookup any more, so an old PR must not linger.
            for r in updated.indices where repoIDs?.contains(updated[r].id) ?? true {
                for w in updated[r].worktrees.indices {
                    if let branch = updated[r].worktrees[w].remoteBranch, protected.contains(branch) {
                        updated[r].worktrees[w].pullRequest = nil
                    }
                }
            }
            for (job, lookup) in results {
                guard let r = updated.firstIndex(where: { $0.id == job.repoID }),
                      let w = updated[r].worktrees.firstIndex(where: { $0.id == job.worktreeID })
                else { continue }
                switch lookup {
                case .found(let pr):
                    updated[r].worktrees[w].pullRequest = pr
                    noteChange(pr, repo: updated[r].name)
                case .none: updated[r].worktrees[w].pullRequest = nil
                case .failed: githubFailures[job.repoID, default: 0] += 1
                }
            }
            repos = updated
        }
    }

    private func noteChange(_ pr: PullRequest, repo: String) {
        let now = (failing: pr.checks == .failing, merged: pr.state == "MERGED")
        defer { prSeen[pr.url] = now }
        guard let before = prSeen[pr.url] else { return }
        if now.failing, !before.failing, Prefs.notifyChecksFailed {
            Notifier.post(title: "Checks failed", body: "#\(pr.number) \(pr.title) in \(repo)", url: pr.url)
        }
        if now.merged, !before.merged, Prefs.notifyMerged {
            Notifier.post(title: "Pull request merged", body: "#\(pr.number) \(pr.title) in \(repo). Its worktree can go.", url: pr.url)
        }
    }

    /// Removes a linked worktree. The row goes at once; the disk work follows in the background.
    /// The branch is kept. On failure `deleteError` is set and the folder is rescanned.
    func deleteWorktree(_ wt: Worktree, in repo: Repo) {
        let name = URL(fileURLWithPath: wt.path).lastPathComponent
        Task {
            let trash = Prefs.trashOnDelete
            let failures = await deleteWorktrees([wt], in: repo)
            if let error = failures.first?.error {
                deleteError = error
            } else {
                show(trash ? "Moved \(name) to the Trash. Branch kept." : "Deleted \(name). Branch kept.")
            }
        }
    }

    /// Removes several worktrees of one repo, one after another so their `git worktree prune`
    /// calls never overlap. Rows vanish at once. Returns what failed, with the reason.
    @discardableResult
    func deleteWorktrees(_ wts: [Worktree], in repo: Repo) async -> [(worktree: Worktree, error: String)] {
        let wts = wts.filter { !$0.isMain }
        guard !wts.isEmpty else { return [] }
        for wt in wts {
            pendingDeletes.insert(wt.id)
            sizes[wt.id] = nil
            sizeMeasuredAt[wt.id] = nil
        }
        if let r = repos.firstIndex(where: { $0.id == repo.id }) {
            let ids = Set(wts.map(\.id))
            repos[r].worktrees.removeAll { ids.contains($0.id) }
        }
        var failures: [(worktree: Worktree, error: String)] = []
        for wt in wts {
            // Demo rows just go; there is no folder behind them.
            if DemoData.isOn { settledDeletes.insert(wt.id); continue }
            let others = repo.worktrees.map(\.path).filter { $0 != wt.path }
            if let error = await Self.removeFromDisk(wt, repoPath: repo.path, roots: roots.map(\.path), others: others) {
                pendingDeletes.remove(wt.id)
                failures.append((wt, error))
            } else {
                settledDeletes.insert(wt.id)
            }
        }
        // A scan that was already running read the worktree list before the prune,
        // and a failed delete may have left the folder half moved.
        if isScanning || !failures.isEmpty { await refresh() }
        return failures
    }

    /// Measures folders that were never measured, or not for a while, a couple at a time
    /// off the main thread. Safe to call often: work in flight is not repeated.
    /// A size older than `maxAge` is measured again; the old number stays on screen until the
    /// new one lands. nil (Settings: Never) measures each folder once per launch. Measuring is the
    /// costliest thing the app does (du walks every node_modules), so the default is an hour.
    func loadSizes(for paths: [String], maxAge: TimeInterval? = Prefs.sizeMaxAge) async {
        guard !DemoData.isOn else { return }
        let now = Date()
        let todo = paths.filter { path in
            guard !sizing.contains(path), !pendingDeletes.contains(path) else { return false }
            guard let measured = sizeMeasuredAt[path] else { return true }
            guard let maxAge else { return false }
            return now.timeIntervalSince(measured) > maxAge
        }
        guard !todo.isEmpty else { return }
        sizing.formUnion(todo)
        await withTaskGroup(of: (String, Int64?).self) { group in
            for path in todo {
                group.addTask { (path, await DiskUsage.bytes(at: path)) }
            }
            for await (path, bytes) in group {
                sizing.remove(path)
                // A folder deleted while du was running must not come back with a size.
                guard !pendingDeletes.contains(path), !settledDeletes.contains(path) else { continue }
                // A failed measurement (no permission, folder gone) is also remembered, so it
                // isn't retried on every scan.
                sizeMeasuredAt[path] = Date()
                if let bytes { sizes[path] = bytes }
            }
        }
    }

    /// Deletes the checked worktrees, per repo in sequence, repos in parallel. One closing
    /// notice when everything is done, one alert listing whatever failed. Branches are kept.
    func tidy(_ requested: [TidyCandidate]) {
        // Only what still qualifies right now, by the latest scan data.
        let candidates = requested.filter { c in
            guard let (_, wt) = locate(worktreeID: c.id) else { return false }
            return TidyCandidate.reason(for: wt) != nil
        }
        guard !candidates.isEmpty else { return }
        let n = candidates.count
        let bytes = candidates.compactMap { sizes[$0.worktree.id] }.reduce(0, +)
        let byRepo = Dictionary(grouping: candidates, by: \.repo.id)
        let trash = Prefs.trashOnDelete
        show("Deleting \(n) worktree\(n == 1 ? "" : "s")…")
        Task {
            var failures: [(worktree: Worktree, error: String)] = []
            await withTaskGroup(of: [(worktree: Worktree, error: String)].self) { group in
                for (_, group_) in byRepo {
                    let repo = group_[0].repo
                    let wts = group_.map(\.worktree)
                    group.addTask { await self.deleteWorktrees(wts, in: repo) }
                }
                for await part in group { failures += part }
            }
            let done = n - failures.count
            let count = "\(done) worktree\(done == 1 ? "" : "s")"
            if trash {
                // Nothing is freed until the Trash is emptied.
                show("Moved \(count) to the Trash. Branches kept.", icon: failures.isEmpty ? .check : nil)
            } else {
                // "Up to": du counts clones and hard links in full, so the real gain can be less.
                let space = bytes > 0 && failures.isEmpty ? ", up to \(formatBytes(bytes)) freed" : ""
                show("Deleted \(count)\(space). Branches kept.", icon: failures.isEmpty ? .check : nil)
            }
            if !failures.isEmpty {
                deleteError = failures.map { "\(URL(fileURLWithPath: $0.worktree.path).lastPathComponent): \($0.error)" }
                    .joined(separator: "\n")
            }
        }
    }

    /// Shows a status-bar line for a few seconds and reads it out to VoiceOver.
    func show(_ message: String, icon: IconName? = nil) {
        notice = message
        noticeIcon = icon
        announce(message)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, self.notice == message else { return }
            self.notice = nil
            self.noticeIcon = nil
        }
    }

    func announce(_ message: String) {
        // No app object under tests.
        guard let app = NSApp else { return }
        NSAccessibility.post(
            element: app.mainWindow as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    /// Rescans when the data is older than `age`, e.g. when the app comes back to the front.
    func refreshIfStale(olderThan age: TimeInterval = 120) {
        guard let lastFullScan, Date().timeIntervalSince(lastFullScan) > age else { return }
        Task { await refresh() }
    }

    var selectedPair: (Repo, Worktree)? {
        selectedID.flatMap(locate(worktreeID:))
    }

    /// Renames the folder aside (instant on the same volume), lets git forget it with
    /// `worktree prune`, then deletes the renamed folder off the main thread.
    /// Faster than `git worktree remove`, which deletes every file before returning.
    /// With Move to Trash on, the folder goes to the Trash under its own name instead, so
    /// Put Back restores it where it was.
    private nonisolated static func removeFromDisk(_ wt: Worktree, repoPath: String, roots: [String], others: [String]) async -> String? {
        let fm = FileManager.default

        // A worktree git has already lost only needs its entry dropped; nothing is moved.
        guard !wt.isPrunable, fm.fileExists(atPath: wt.path) else {
            return await forget(wt, repoPath: repoPath)
        }

        if let problem = WorktreeCheck.problem(deleting: wt.path, repoPath: repoPath, roots: roots, others: others) {
            return problem
        }

        let url = URL(fileURLWithPath: wt.path)
        if Prefs.trashOnDelete {
            let trashed: URL?
            do {
                trashed = try Store.trash(url)
            } catch {
                return "Couldn't move \(wt.path.abbreviatingHome) to the Trash: \(error.localizedDescription)"
            }
            if let failure = await forget(wt, repoPath: repoPath) {
                // Git still knows the worktree, so the folder comes back out of the Trash.
                guard let trashed, (try? fm.moveItem(at: trashed, to: url)) != nil else {
                    return failure + " The folder is still in the Trash."
                }
                return failure
            }
            return nil
        }
        // Hidden name, so a rescan never picks it up while it's being deleted.
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).deleting-\(UUID().uuidString.prefix(8))")
        do {
            try fm.moveItem(at: url, to: aside)
        } catch {
            return "Couldn't move \(wt.path.abbreviatingHome) aside: \(error.localizedDescription)"
        }

        if let error = await forget(wt, repoPath: repoPath) {
            // Git still knows the worktree, so the folder goes back where it was.
            try? fm.moveItem(at: aside, to: url)
            return error
        }
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: aside) }.value
        return nil
    }

    /// Drops this one worktree's entry from the repo (a lock is overridden, the folder may be
    /// gone already) and confirms git no longer lists it. Other stale entries are left alone.
    private nonisolated static func forget(_ wt: Worktree, repoPath: String) async -> String? {
        let force = wt.isLocked ? ["--force", "--force"] : ["--force"]
        let remove = await Shell.run("git", ["-C", repoPath, "worktree", "remove"] + force + [wt.path], limited: false)
        guard remove.ok else {
            let message = remove.err.trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "git worktree remove failed." : message
        }
        let listing = await Shell.run("git", ["-C", repoPath, "worktree", "list", "--porcelain", "-z"], limited: false)
        if listing.ok, Scanner.parseWorktrees(listing.out).contains(where: { $0.path == wt.path }) {
            return "git still lists \(wt.path.abbreviatingHome)."
        }
        return nil
    }
}

/// Before a folder is deleted as a worktree, it has to really be one of this repo's worktrees.
/// A forged or stale entry in `git worktree list` must not point Delete at some other folder.
enum WorktreeCheck {
    /// Nil when the folder is safe to delete, otherwise the reason it is not.
    nonisolated static func problem(deleting path: String, repoPath: String, roots: [String], others: [String] = []) -> String? {
        let fm = FileManager.default
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        let repo = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath().standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path

        func isAncestorOrSame(_ a: String, of b: String) -> Bool { a == b || b.hasPrefix(a.hasSuffix("/") ? a : a + "/") }
        if isAncestorOrSame(real, of: home) { return "\(path.abbreviatingHome) is not a worktree folder." }
        if isAncestorOrSame(real, of: repo) { return "\(path.abbreviatingHome) holds the repository itself." }
        for root in roots {
            let r = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
            if isAncestorOrSame(real, of: r) { return "\(path.abbreviatingHome) holds a scanned folder." }
        }
        // Moving a symlink would leave the real folder, and its registration, behind.
        if let attrs = try? fm.attributesOfItem(atPath: path), attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            return "\(path.abbreviatingHome) is a link, not the worktree folder."
        }
        // Another worktree inside this one would go with it.
        for other in others {
            let o = URL(fileURLWithPath: other).resolvingSymlinksInPath().standardizedFileURL.path
            if o != real, isAncestorOrSame(real, of: o) { return "\(path.abbreviatingHome) holds another worktree, \(other.abbreviatingHome)." }
        }

        // <worktree>/.git is a plain file saying "gitdir: <repo>/.git/worktrees/<name>".
        let dotGit = real + "/.git"
        guard let attrs = try? fm.attributesOfItem(atPath: dotGit), attrs[.type] as? FileAttributeType == .typeRegular,
              let contents = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir: ")
        else { return "\(path.abbreviatingHome) has no worktree .git file." }
        var admin = String(line.dropFirst(8))
        if !admin.hasPrefix("/") { admin = real + "/" + admin }
        let adminReal = URL(fileURLWithPath: admin).resolvingSymlinksInPath().standardizedFileURL.path
        let adminRoot = URL(fileURLWithPath: repo + "/.git/worktrees").resolvingSymlinksInPath().standardizedFileURL.path
        guard adminReal.hasPrefix(adminRoot + "/"), adminReal.dropFirst(adminRoot.count + 1).contains("/") == false
        else { return "\(path.abbreviatingHome) does not belong to \(repoPath.abbreviatingHome)." }

        // And that entry points back at this folder.
        guard let back = try? String(contentsOfFile: adminReal + "/gitdir", encoding: .utf8) else {
            return "\(repoPath.abbreviatingHome) has no record of \(path.abbreviatingHome)."
        }
        let backReal = URL(fileURLWithPath: back.trimmingCharacters(in: .whitespacesAndNewlines))
            .resolvingSymlinksInPath().standardizedFileURL.path
        guard backReal == dotGit else { return "\(repoPath.abbreviatingHome) lists \(path.abbreviatingHome) under another folder." }
        return nil
    }
}
