import Foundation

/// `worktrees`: the app's view of your worktrees, in a terminal or for an agent.
/// The same executable as the app. Called through the `worktrees` link (or with a command as
/// the first argument) it prints and exits before any window or app state is made.
/// Read-only: it never changes a repo, a worktree or a setting.
enum CLI {
    static let name = "worktrees"
    static let commands: Set<String> = ["list", "show", "tidy", "folders", "help", "version", "--help", "-h", "--version"]

    /// True for `worktrees …` and for `Worktrees list …`. A plain launch from Finder or the
    /// Dock (no command, capital W) opens the app as usual.
    static func isInvocation(_ args: [String] = CommandLine.arguments) -> Bool {
        let invokedAs = URL(fileURLWithPath: args.first ?? "").lastPathComponent
        return invokedAs == name || args.dropFirst().contains(where: commands.contains)
    }

    /// The app this executable belongs to, found through the `worktrees` link: Bundle.main
    /// only sees the link's folder.
    static let appBundle: Bundle? = {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let exe = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? Bundle(url: app) : nil
    }()

    static var appVersion: String? { appBundle?.infoDictionary?["CFBundleShortVersionString"] as? String }

    static func runAndExit() -> Never {
        let args = Array(CommandLine.arguments.dropFirst())
        Scanner.readOnly = true
        // The installed app never takes a fake gh from the environment; the test copy keeps its own.
        Shell.ghExecutable = TestMode.fakeGh(bundleID: appBundle?.bundleIdentifier ?? Bundle.main.bundleIdentifier,
                                             environment: ProcessInfo.processInfo.environment, defaults: appDefaults)
        let done = DispatchSemaphore(value: 0)
        var status: Int32 = 0
        Task.detached {
            var out = Output()
            status = await run(args, out: &out)
            // Warnings first, so they come before the output they are about.
            FileHandle.standardError.write(Data(out.stderr.utf8))
            FileHandle.standardOutput.write(Data(out.stdout.utf8))
            done.signal()
        }
        done.wait()
        exit(status)
    }

    struct Output {
        var stdout = ""
        var stderr = ""
        mutating func line(_ text: String = "") { stdout += text + "\n" }
        mutating func error(_ text: String) { stderr += "worktrees: " + text + "\n" }
    }

    static let usage = """
    worktrees: every git worktree with its pull request, checks and changes.

    Usage:
      worktrees [list]            the worktrees the app's Overview shows, grouped the same way
      worktrees list --attention  only the ones that need attention
      worktrees list --all        every checkout, main ones included
      worktrees show <worktree>   one worktree, by path, folder name or branch
      worktrees tidy              what Tidy up would offer to delete (deletes nothing)
      worktrees folders           the folders scanned, with repo counts
      worktrees version

    Options:
      --json          machine-readable output (schema 1)
      --no-github     skip pull request lookups (faster, offline)
      --repo <name>   only worktrees of this repo
      --root <path>   scan this folder instead of the app's folders

    Folders and settings come from the Worktrees app. Nothing is ever changed.
    """

    /// Exit codes: 0 done, 1 nothing matched or a scan problem, 2 wrong usage.
    static func run(_ arguments: [String], out: inout Output) async -> Int32 {
        var json = false, attentionOnly = false, everything = false, noGitHub = false
        var repoFilter: String?, rootOverride: String?
        var words: [String] = []
        var i = 0
        // Read left to right, so a flag's value is never taken for a flag of its own.
        while i < arguments.count {
            let arg = arguments[i]
            switch arg {
            case "--json": json = true
            case "--attention": attentionOnly = true
            case "--all": everything = true
            case "--no-github": noGitHub = true
            case "--repo", "--root":
                guard i + 1 < arguments.count else {
                    out.error("\(arg) needs a value")
                    return 2
                }
                if arg == "--repo" { repoFilter = arguments[i + 1] } else { rootOverride = arguments[i + 1] }
                i += 1
            default: words.append(arg)
            }
            i += 1
        }
        let command = words.first ?? "list"
        let rest = Array(words.dropFirst())

        switch command {
        case "help", "--help", "-h", "version", "--version":
            guard rest.isEmpty else {
                out.error("unexpected \(rest[0]). Try worktrees help.")
                return 2
            }
            out.line(command.contains("help") || command == "-h" ? usage : (appVersion ?? "development build"))
            return 0
        case "list", "show", "tidy", "folders":
            break
        default:
            out.error("unknown command \(command). Try worktrees help.")
            return 2
        }
        if let unknown = command == "show" ? rest.dropFirst().first : rest.first {
            out.error("unexpected \(unknown). Try worktrees help.")
            return 2
        }

        let roots = rootOverride.map { [URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)] } ?? savedRoots()
        guard !roots.isEmpty else {
            out.error("no folders to scan yet. Open Worktrees once and pick them, or pass --root <path>.")
            return 1
        }
        guard GitCheck.status == .ready else {
            out.error(GitCheck.status.message ?? "git can't run")
            return 1
        }

        if command == "folders" {
            guard repoFilter == nil else {
                out.error("folders lists the scanned folders; --repo doesn't apply")
                return 2
            }
            return folders(roots, json: json, out: &out)
        }

        var scan = await load(roots: roots, github: !noGitHub)
        if let repoFilter {
            scan.repos = scan.repos.filter { $0.name == repoFilter }
            if scan.repos.isEmpty {
                out.error("no repo named \(repoFilter)")
                return 1
            }
        }

        switch command {
        case "show":
            guard let query = rest.first else {
                out.error("show needs a worktree: a path, a folder name or a branch")
                return 2
            }
            return show(query, scan: scan, json: json, out: &out)
        case "tidy":
            return tidy(scan, json: json, out: &out)
        default:
            return list(scan, attentionOnly: attentionOnly, everything: everything, json: json, out: &out)
        }
    }

    // MARK: Loading

    /// The app's settings, also when called through a link from outside the app bundle.
    static var appDefaults: UserDefaults {
        if let testStore = Prefs.testStore { return testStore }
        let id = appBundle?.bundleIdentifier ?? Bundle.main.bundleIdentifier ?? "me.apek.worktrees"
        if id == Bundle.main.bundleIdentifier { return .standard }
        return UserDefaults(suiteName: id) ?? .standard
    }

    /// The folders the app scans: the saved ones, or ~/Code for someone on 0.1.0 who never
    /// changed it. Empty before onboarding has picked any.
    static func savedRoots() -> [URL] {
        let defaults = appDefaults
        if let saved = defaults.stringArray(forKey: "roots") { return saved.map { URL(fileURLWithPath: $0) } }
        if let legacy = defaults.string(forKey: "root") { return [URL(fileURLWithPath: legacy)] }
        guard !Onboarding.isNeeded(defaults) else { return [] }
        let code = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Code")
        return FileManager.default.fileExists(atPath: code.path) ? [code] : []
    }

    struct Scan {
        var roots: [URL]
        var repos: [Repo]
        /// "ok", "partial" (some lookups failed), "signed-out" or "skipped".
        var github: String
        var githubFailures = 0
        /// Worktrees whose lookup failed: their PR is unknown, so Tidy up can't judge them.
        var unknown: Set<String> = []
    }

    static func load(roots: [URL], github: Bool) async -> Scan {
        if Prefs.testStore == nil, !TestMode.isTestApp { Prefs.cliStore = appDefaults }
        let depth = Prefs.scanDepth
        let skipped = Prefs.skippedFolders
        var seen = Set<String>()
        var found: [(path: String, root: URL)] = []
        for root in roots {
            for path in Scanner.findRepos(root: root, maxDepth: depth, skipping: skipped) where seen.insert(path).inserted {
                found.append((path, root))
            }
        }
        var repos = await withTaskGroup(of: Repo?.self) { group in
            for item in found { group.addTask { await Scanner.loadRepo(path: item.path, root: item.root) } }
            var loaded: [Repo] = []
            for await repo in group { if let repo { loaded.append(repo) } }
            return loaded
        }
        repos.sort { ($0.group, $0.name) < ($1.group, $1.name) }

        guard github else { return Scan(roots: roots, repos: repos, github: "skipped") }
        guard await GitHub.signedIn() else { return Scan(roots: roots, repos: repos, github: "signed-out") }
        let protected = Prefs.protectedBranches
        var failures = 0
        var unknown = Set<String>()
        await withTaskGroup(of: (Int, [String: GitHub.Lookup]).self) { group in
            for (index, repo) in repos.enumerated() {
                guard let slug = repo.githubRemote?.githubSlug else { continue }
                let branches = Set(repo.worktrees.compactMap(\.remoteBranch).filter { !protected.contains($0) })
                guard !branches.isEmpty else { continue }
                group.addTask { (index, await GitHub.pullRequests(slug: slug, branches: Array(branches))) }
            }
            for await (index, lookups) in group {
                for w in repos[index].worktrees.indices {
                    guard let branch = repos[index].worktrees[w].remoteBranch, !protected.contains(branch),
                          let lookup = lookups[branch] else { continue }
                    switch lookup {
                    case .found(let pr): repos[index].worktrees[w].pullRequest = pr
                    case .none: repos[index].worktrees[w].pullRequest = nil
                    case .failed:
                        failures += 1
                        unknown.insert(repos[index].worktrees[w].id)
                    }
                }
            }
        }
        return Scan(roots: roots, repos: repos, github: failures == 0 ? "ok" : "partial", githubFailures: failures, unknown: unknown)
    }

    // MARK: Output

    struct Item: Encodable {
        struct PR: Encodable {
            let number: Int
            let title: String
            let state: String
            let draft: Bool
            let checks: String
            let url: String
        }
        struct Local: Encodable {
            let changed: Int
            let untracked: Int
            let conflicted: Int
            let ahead: Int
            let behind: Int
            let upstream: String?

            private enum CodingKeys: String, CodingKey { case changed, untracked, conflicted, ahead, behind, upstream }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(changed, forKey: .changed)
                try c.encode(untracked, forKey: .untracked)
                try c.encode(conflicted, forKey: .conflicted)
                try c.encode(ahead, forKey: .ahead)
                try c.encode(behind, forKey: .behind)
                try c.encode(upstream, forKey: .upstream)
            }
        }
        struct Commit: Encodable {
            let hash: String
            let subject: String
            let date: Date
        }
        let repo: String
        let repoPath: String
        let path: String
        let branch: String?
        let isMain: Bool
        let title: String
        let group: String
        let groupTitle: String
        let state: String
        let createdBy: String?
        let pullRequest: PR?
        let local: Local?
        let lastCommit: Commit?
        let tidy: String?

        private enum CodingKeys: String, CodingKey {
            case repo, repoPath, path, branch, isMain, title, group, groupTitle, state, createdBy, pullRequest, local, lastCommit, tidy
        }

        /// Every key is always there; a missing value is null, never a missing key.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(repo, forKey: .repo)
            try c.encode(repoPath, forKey: .repoPath)
            try c.encode(path, forKey: .path)
            try c.encode(branch, forKey: .branch)
            try c.encode(isMain, forKey: .isMain)
            try c.encode(title, forKey: .title)
            try c.encode(group, forKey: .group)
            try c.encode(groupTitle, forKey: .groupTitle)
            try c.encode(state, forKey: .state)
            try c.encode(createdBy, forKey: .createdBy)
            try c.encode(pullRequest, forKey: .pullRequest)
            try c.encode(local, forKey: .local)
            try c.encode(lastCommit, forKey: .lastCommit)
            try c.encode(tidy, forKey: .tidy)
        }
    }

    static func groupKey(_ group: OverviewGroup) -> String {
        switch group {
        case .attention: "attention"
        case .inProgress: "in-progress"
        case .review: "review"
        case .merge: "merge"
        case .cleanup: "cleanup"
        case .other: "other"
        }
    }

    static func checksKey(_ checks: PullRequest.Checks) -> String {
        switch checks {
        case .none: "none"
        case .passing: "passing"
        case .failing: "failing"
        case .pending: "pending"
        }
    }

    static func item(_ wt: Worktree, in repo: Repo, github: Bool) -> Item {
        let state = WorktreeState(wt)
        let reason = github ? TidyCandidate.reason(for: wt) : nil
        return Item(
            repo: repo.name, repoPath: repo.path, path: wt.path, branch: wt.branch, isMain: wt.isMain,
            title: wt.displayTitle, group: groupKey(state.group), groupTitle: state.group.title, state: state.label,
            createdBy: wt.creator?.name,
            pullRequest: wt.pullRequest.map {
                Item.PR(number: $0.number, title: $0.title, state: $0.state, draft: $0.isDraft, checks: checksKey($0.checks), url: $0.url)
            },
            local: wt.status.map {
                Item.Local(changed: $0.changed, untracked: $0.untracked, conflicted: $0.conflicted, ahead: $0.ahead, behind: $0.behind, upstream: $0.upstream)
            },
            lastCommit: wt.lastCommit.map { Item.Commit(hash: $0.hash, subject: $0.subject, date: $0.date) },
            tidy: reason.map { r in
                switch r {
                case .merged: "merged"
                case .closed: "closed"
                case .stale: "stale"
                }
            }
        )
    }

    /// Every JSON answer: schema 1, the app version, when, how GitHub went, the folders, and
    /// the payload under one key (`worktrees`, `worktree` or `folders`).
    struct Report<Payload: Encodable>: Encodable {
        let key: String
        let app: String
        let generatedAt: Date
        let github: String?
        let githubFailures: Int?
        let roots: [String]
        let payload: Payload

        struct Key: CodingKey {
            var stringValue: String
            var intValue: Int? { nil }
            init(_ s: String) { stringValue = s }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(1, forKey: Key("schema"))
            try c.encode(app, forKey: Key("app"))
            try c.encode(generatedAt, forKey: Key("generatedAt"))
            try c.encode(github, forKey: Key("github"))
            try c.encode(githubFailures, forKey: Key("githubFailures"))
            try c.encode(roots, forKey: Key("roots"))
            try c.encode(payload, forKey: Key(key))
        }
    }

    static func encode<Payload: Encodable>(_ payload: Payload, key: String = "worktrees", scan: Scan) -> String {
        render(Report(key: key, app: appVersion ?? "development", generatedAt: Date(), github: scan.github,
                      githubFailures: scan.githubFailures, roots: scan.roots.map(\.path), payload: payload))
    }

    private static func render<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private static func items(_ scan: Scan, overviewOnly: Bool = false) -> [Item] {
        let github = scan.github != "skipped" && scan.github != "signed-out"
        return scan.repos.flatMap { repo in
            repo.worktrees.filter { !overviewOnly || $0.showsInOverview() }
                .map { item($0, in: repo, github: github && !scan.unknown.contains($0.id)) }
        }
    }

    static func list(_ scan: Scan, attentionOnly: Bool, everything: Bool, json: Bool, out: inout Output) -> Int32 {
        var all = everything ? items(scan) : items(scan, overviewOnly: true)
        if attentionOnly { all = all.filter { $0.group == "attention" } }
        if json {
            out.line(encode(all, scan: scan))
            return 0
        }
        for group in OverviewGroup.allCases {
            let rows = all.filter { $0.group == groupKey(group) }
            guard !rows.isEmpty else { continue }
            out.line("\(group.title) (\(rows.count))")
            for row in rows { out.line("  " + describe(row)) }
            out.line()
        }
        if all.isEmpty { out.line(attentionOnly ? "Nothing needs attention." : "No worktrees found.") }
        out.line(footer(scan, count: all.count))
        return 0
    }

    private static func describe(_ row: Item) -> String {
        var parts = [row.title, row.repo, row.state]
        if let pr = row.pullRequest { parts.append("#\(pr.number)") }
        if let by = row.createdBy { parts.append(by) }
        parts.append(row.path.abbreviatingHome)
        return parts.joined(separator: "  ")
    }

    private static func footer(_ scan: Scan, count: Int) -> String {
        let github: String
        switch scan.github {
        case "ok": github = "pull requests up to date"
        case "skipped": github = "pull requests skipped"
        case "signed-out": github = "gh isn't signed in, no pull requests"
        default: github = "\(scan.githubFailures) GitHub lookup\(scan.githubFailures == 1 ? "" : "s") failed"
        }
        return "\(count) worktree\(count == 1 ? "" : "s") in \(scan.repos.count) repo\(scan.repos.count == 1 ? "" : "s"), \(github)."
    }

    static func show(_ query: String, scan: Scan, json: Bool, out: inout Output) -> Int32 {
        let all = items(scan)
        let expanded = (query as NSString).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : FileManager.default.currentDirectoryPath + "/" + expanded
        let real = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().standardizedFileURL.path
        let matches = all.filter {
            URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().standardizedFileURL.path == real
                || $0.branch == query || URL(fileURLWithPath: $0.path).lastPathComponent == query
        }
        guard let row = matches.first else {
            out.error("no worktree matches \(query)")
            return 1
        }
        if matches.count > 1 {
            out.error("\(matches.count) worktrees match \(query); showing the first. Use the path to pick one.")
        }
        if json {
            out.line(encode(row, key: "worktree", scan: scan))
            return 0
        }
        out.line(row.title)
        out.line("  State      \(row.state) (\(row.groupTitle))")
        out.line("  Repo       \(row.repo)  \(row.repoPath.abbreviatingHome)")
        out.line("  Path       \(row.path.abbreviatingHome)")
        if let branch = row.branch { out.line("  Branch     \(branch)") }
        if let pr = row.pullRequest { out.line("  PR         #\(pr.number) \(pr.state.lowercased()), checks \(pr.checks)  \(pr.url)") }
        if let local = row.local {
            out.line("  Local      \(local.changed) changed, \(local.untracked) untracked, \(local.ahead) ahead, \(local.behind) behind")
        }
        if let commit = row.lastCommit { out.line("  Last       \(commit.hash) \(commit.subject)") }
        if let by = row.createdBy { out.line("  Made by    \(by)") }
        if let tidy = row.tidy { out.line("  Tidy up    can go (\(tidy))") }
        return 0
    }

    static func tidy(_ scan: Scan, json: Bool, out: inout Output) -> Int32 {
        let rows = items(scan).filter { $0.tidy != nil }
        if json {
            out.line(encode(rows, scan: scan))
            return 0
        }
        if scan.github == "skipped" || scan.github == "signed-out" {
            out.line("Tidy up needs GitHub to tell which worktrees are done.")
            return 0
        }
        guard !rows.isEmpty else {
            out.line("All tidy.")
            return 0
        }
        for row in rows { out.line("\(row.tidy ?? "")  \(row.title)  \(row.repo)  \(row.path.abbreviatingHome)") }
        out.line()
        out.line("\(rows.count) can go. Delete them from the app's Tidy up (⇧⌘T); this command changes nothing.")
        return 0
    }

    static func folders(_ roots: [URL], json: Bool, out: inout Output) -> Int32 {
        let depth = Prefs.scanDepth
        let skipped = Prefs.skippedFolders
        let counts = roots.map { (root: $0, repos: Scanner.findRepos(root: $0, maxDepth: depth, skipping: skipped).count) }
        if json {
            struct Folder: Encodable { let path: String; let repos: Int }
            out.line(render(Report(key: "folders", app: appVersion ?? "development", generatedAt: Date(), github: nil,
                                   githubFailures: nil, roots: roots.map(\.path),
                                   payload: counts.map { Folder(path: $0.root.path, repos: $0.repos) })))
            return 0
        }
        for c in counts { out.line("\(c.root.path.abbreviatingHome)  \(c.repos) repo\(c.repos == 1 ? "" : "s")") }
        return 0
    }
}
