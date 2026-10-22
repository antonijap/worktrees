import Foundation

struct Remote: Hashable, Sendable {
    let name: String
    let url: String

    /// "owner/repo" when the remote points at GitHub.
    var githubSlug: String? {
        // Also matches SSH host aliases such as git@github.com-work:owner/repo.git
        let pattern = #/github\.com[^:/\s]*[:/]([^/\s]+)/([^/\s]+?)(?:\.git)?/?$/#
        guard let match = url.firstMatch(of: pattern) else { return nil }
        return "\(match.1)/\(match.2)"
    }

    var webURL: URL? {
        githubSlug.flatMap { URL(string: "https://github.com/\($0)") }
    }
}

struct LocalStatus: Hashable, Sendable {
    var upstream: String?
    var ahead = 0
    var behind = 0
    /// False when git printed no ahead/behind line, e.g. the upstream branch was deleted
    /// on GitHub and pruned. `ahead` is then 0 by default, not by fact.
    var aheadKnown = false
    var changed = 0
    var untracked = 0
    var conflicted = 0
    /// The files behind those counts, so the detail column needs no status call of its own.
    var files: [UncommittedFile] = []

    var isClean: Bool { changed == 0 && untracked == 0 && conflicted == 0 }
}

struct Commit: Hashable, Sendable {
    let hash: String
    let subject: String
    let relative: String
    let date: Date
}

struct PullRequest: Decodable, Hashable, Sendable {
    let number: Int
    let title: String
    let state: String
    let isDraft: Bool
    let url: String
    let headRefName: String
    let reviewDecision: String?
    let statusCheckRollup: [CheckItem]?
    // Extra fields from the same gh query. Optional so sample data and old callers need none.
    var author: String? = nil
    var baseRefName: String? = nil
    var updatedAt: Date? = nil
    var labels: [String] = []
    var reviews: [Review] = []
    var mergeStateStatus: String? = nil
    var mergeable: String? = nil

    /// One person or team and where their review stands.
    struct Review: Hashable, Sendable {
        enum State: String, Sendable { case approved, changesRequested, commented, waiting }
        let name: String
        let state: State

        var stateText: String {
            switch state {
            case .approved: "approved"
            case .changesRequested: "changes requested"
            case .commented: "commented"
            case .waiting: "waiting"
            }
        }
    }

    struct CheckItem: Decodable, Hashable, Sendable {
        let conclusion: String?
        let status: String?
        let state: String?
        // A CheckRun (GitHub Actions and most apps) has name, detailsUrl and workflowName.
        // A StatusContext (older integrations) has context and targetUrl.
        var name: String?
        var detailsUrl: String?
        var workflowName: String?
        var context: String?
        var targetUrl: String?

        init(conclusion: String?, status: String?, state: String?, name: String? = nil, detailsUrl: String? = nil,
             workflowName: String? = nil, context: String? = nil, targetUrl: String? = nil) {
            self.conclusion = conclusion; self.status = status; self.state = state
            self.name = name; self.detailsUrl = detailsUrl; self.workflowName = workflowName
            self.context = context; self.targetUrl = targetUrl
        }

        static let failingValues: Set<String> = ["FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE"]

        var isFailing: Bool {
            [conclusion, state, status].compactMap { $0?.uppercased() }.contains(where: Self.failingValues.contains)
        }

        /// "Build and test" or "ci/circleci: build".
        var displayName: String {
            if let name, !name.isEmpty {
                if let workflowName, !workflowName.isEmpty, workflowName != name { return "\(workflowName): \(name)" }
                return name
            }
            return context ?? "Check"
        }

        /// Where the logs live.
        var link: URL? { (detailsUrl ?? targetUrl).flatMap(URL.init(string:)) }

        /// The GitHub Actions run id when the link points at a run on github.com. Only such
        /// links lead to a `gh run view`, so a link elsewhere never drives a gh call.
        var actionsRunID: String? {
            guard let raw = detailsUrl ?? targetUrl, let url = URL(string: raw), url.scheme == "https",
                  url.host()?.lowercased() == "github.com",
                  let m = url.path().firstMatch(of: #/\/actions\/runs\/(\d+)/#) else { return nil }
            return String(m.1)
        }
    }

    var failingChecks: [CheckItem] { (statusCheckRollup ?? []).filter(\.isFailing) }

    /// The failing check worth opening first: one with logs on Actions, else any with a link.
    var firstLinkedFailingCheck: CheckItem? {
        failingChecks.first { $0.actionsRunID != nil } ?? failingChecks.first { $0.link != nil }
    }

    enum Checks { case none, passing, failing, pending }

    var checks: Checks {
        guard let items = statusCheckRollup, !items.isEmpty else { return .none }
        let pending: Set = ["IN_PROGRESS", "QUEUED", "PENDING", "EXPECTED", "WAITING", "REQUESTED"]
        var sawPending = false
        for item in items {
            let values = [item.conclusion, item.state, item.status].compactMap { $0?.uppercased() }
            if item.isFailing { return .failing }
            if item.conclusion == nil || item.conclusion == "", values.contains(where: pending.contains) {
                sawPending = true
            }
        }
        return sawPending ? .pending : .passing
    }

    var isOpen: Bool { state == "OPEN" }

    /// Why an open PR can't merge yet, when GitHub says it can't. Nil when it's clean, a draft,
    /// unknown, or the reason is already the checks row.
    var mergeProblem: String? {
        guard isOpen, !isDraft else { return nil }
        let base = baseRefName ?? "the base branch"
        if mergeable == "CONFLICTING" || mergeStateStatus == "DIRTY" { return "Has conflicts with \(base)" }
        switch mergeStateStatus {
        case "BEHIND": return "Behind \(base)"
        case "BLOCKED":
            if reviewDecision == "REVIEW_REQUIRED" || reviewDecision == "CHANGES_REQUESTED" { return "Blocked by required reviews" }
            if checks == .failing { return "Blocked by failing checks" }
            if checks == .pending { return "Waiting for checks" }
            return "Blocked by branch rules"
        default: return nil
        }
    }
}

// Text that GitHub hands over is sanitized as it is decoded, so every view sees clean strings.
extension PullRequest {
    private enum Keys: String, CodingKey {
        case number, title, state, isDraft, url, headRefName, reviewDecision, statusCheckRollup
        case author, baseRefName, updatedAt, labels, latestReviews, reviewRequests, mergeStateStatus, mergeable
    }
    private struct Actor: Decodable { var login: String?; var name: String?; var slug: String? }
    private struct Label: Decodable { let name: String? }
    private static let isoDate = ISO8601DateFormatter()
    private static let isoDateFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func date(from text: String) -> Date? {
        isoDate.date(from: text) ?? isoDateFractional.date(from: text)
    }

    /// Sanitized, non-empty, each once.
    static func labelNames(_ raw: [String?]) -> [String] {
        var names: [String] = []
        for name in raw.compactMap({ $0?.sanitizedForDisplay }) where !name.isEmpty && !names.contains(name) { names.append(name) }
        return names
    }

    /// Latest review per person, then whoever is still asked. A fresh request after a review
    /// means that review is spent, so the person goes back to waiting. The author's own
    /// comments are not reviews.
    static func reviewList(author: String?, latest: [(login: String?, state: String?)], requested: [String?]) -> [Review] {
        var list: [Review] = []
        for r in latest {
            guard let name = r.login?.sanitizedForDisplay, !name.isEmpty, name != author,
                  !list.contains(where: { $0.name == name }) else { continue }
            let state: Review.State? = switch r.state {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changesRequested
            case "COMMENTED": .commented
            default: nil
            }
            if let state { list.append(Review(name: name, state: state)) }
        }
        for raw in requested {
            guard let name = raw?.sanitizedForDisplay, !name.isEmpty, name != author else { continue }
            list.removeAll { $0.name == name }
            list.append(Review(name: name, state: .waiting))
        }
        return list
    }
    private struct LatestReview: Decodable { let author: Actor?; let state: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        number = try c.decode(Int.self, forKey: .number)
        title = try c.decode(String.self, forKey: .title).sanitizedForDisplay
        state = try c.decode(String.self, forKey: .state)
        isDraft = try c.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
        url = try c.decode(String.self, forKey: .url)
        headRefName = try c.decode(String.self, forKey: .headRefName).sanitizedForDisplay
        reviewDecision = try c.decodeIfPresent(String.self, forKey: .reviewDecision)
        statusCheckRollup = try c.decodeIfPresent([CheckItem].self, forKey: .statusCheckRollup)
        author = try c.decodeIfPresent(Actor.self, forKey: .author)?.login?.sanitizedForDisplay
        baseRefName = try c.decodeIfPresent(String.self, forKey: .baseRefName)?.sanitizedForDisplay
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt).flatMap(Self.date(from:))
        labels = Self.labelNames((try c.decodeIfPresent([Label].self, forKey: .labels) ?? []).map(\.name))
        mergeStateStatus = try c.decodeIfPresent(String.self, forKey: .mergeStateStatus)
        mergeable = try c.decodeIfPresent(String.self, forKey: .mergeable)

        reviews = Self.reviewList(
            author: author,
            latest: (try c.decodeIfPresent([LatestReview].self, forKey: .latestReviews) ?? []).map { ($0.author?.login, $0.state) },
            requested: (try c.decodeIfPresent([Actor].self, forKey: .reviewRequests) ?? []).map { $0.login ?? $0.name ?? $0.slug }
        )
    }
}

extension PullRequest.CheckItem {
    private enum Keys: String, CodingKey {
        case conclusion, status, state, name, detailsUrl, workflowName, context, targetUrl
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            conclusion: try c.decodeIfPresent(String.self, forKey: .conclusion),
            status: try c.decodeIfPresent(String.self, forKey: .status),
            state: try c.decodeIfPresent(String.self, forKey: .state),
            name: try c.decodeIfPresent(String.self, forKey: .name)?.sanitizedForDisplay,
            detailsUrl: try c.decodeIfPresent(String.self, forKey: .detailsUrl),
            workflowName: try c.decodeIfPresent(String.self, forKey: .workflowName)?.sanitizedForDisplay,
            context: try c.decodeIfPresent(String.self, forKey: .context)?.sanitizedForDisplay,
            targetUrl: try c.decodeIfPresent(String.self, forKey: .targetUrl)
        )
    }
}

struct Worktree: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let head: String
    let branch: String?
    let isMain: Bool
    let isLocked: Bool
    let isPrunable: Bool
    /// The tool that made this worktree, read off its path and branch. Never for a main checkout.
    let creator: Creator?
    /// Settings hides this tool's tag. Stored, not read live, so a change to the setting is a
    /// change to the data and every row showing the tag redraws.
    var creatorHidden: Bool
    var status: LocalStatus?
    var lastCommit: Commit?
    var pullRequest: PullRequest?

    var displayBranch: String {
        branch ?? "detached @ \(head.prefix(7))"
    }

    /// The branch name to look up on GitHub: the upstream's name when it differs from the local one.
    var remoteBranch: String? {
        if let upstream = status?.upstream, let slash = upstream.firstIndex(of: "/") {
            return String(upstream[upstream.index(after: slash)...])
        }
        return branch
    }

    var isDirty: Bool { !(status?.isClean ?? true) }

    init(path: String, head: String, branch: String?, isMain: Bool, isLocked: Bool, isPrunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.isMain = isMain
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        creator = isMain ? nil : Creator(path: path, branch: branch)
        creatorHidden = creator.map { Prefs.hiddenTools.contains($0.slug) } ?? false
    }
}

extension Worktree {
    /// The creator tag to show, unless Settings hides that tool's tag.
    var shownCreator: Creator? { creatorHidden ? nil : creator }
}

/// The tool that made a worktree. Shown as a quiet tag so you can tell an agent's checkout
/// from one you made by hand.
struct Creator: Hashable, Sendable {
    let name: String
    /// The filter matches when the typed text starts one of these.
    let searchTerms: [String]
    /// One token, for `--dump`.
    let slug: String

    /// A tool we know by where it puts worktrees or how it names branches.
    struct Known: Sendable {
        let name: String
        let slug: String
        /// Folder runs the worktree sits inside, matched as whole path components anywhere in
        /// the path, so `.codex/worktrees` also matches with a moved home or a custom CODEX_HOME.
        var folders: [String] = []
        /// Branch prefixes, including the slash.
        var branches: [String] = []
        var searchTerms: [String] = []
    }

    /// Add a tool here. Folders are checked for every tool before any branch prefix. A tool
    /// whose folder is too common to trust (Crystal's `<repo>/worktrees`, gwq's `~/worktrees`)
    /// is left out rather than guessed at.
    static let known: [Known] = [
        Known(name: "Claude Code", slug: "claude-code", folders: [".claude/worktrees"], branches: ["claude/"], searchTerms: ["claude"]),
        Known(name: "Supacode", slug: "supacode", folders: [".supacode"]),
        Known(name: "Cursor", slug: "cursor", folders: [".cursor/worktrees"], branches: ["cursor/"]),
        Known(name: "Windsurf", slug: "windsurf", folders: [".windsurf/worktrees"]),
        Known(name: "Conductor", slug: "conductor", folders: ["conductor/workspaces"]),
        Known(name: "Sculptor", slug: "sculptor", folders: [".sculptor/workspaces"]),
        Known(name: "Superset", slug: "superset", folders: [".superset/worktrees"]),
        Known(name: "Emdash", slug: "emdash", folders: ["emdash/worktrees"]),
        Known(name: "Gemini CLI", slug: "gemini", folders: [".gemini/worktrees"]),
        Known(name: "Vibe Kanban", slug: "vibe-kanban", folders: ["vibe-kanban/worktrees"], branches: ["vk/"], searchTerms: ["vibe", "kanban"]),
        Known(name: "Container Use", slug: "container-use", folders: ["container-use/worktrees"], branches: ["container-use/"], searchTerms: ["container"]),
        Known(name: "uzi", slug: "uzi", folders: ["uzi/worktrees"]),
        // Codex's folder (~/.codex/worktrees) isn't confirmed, so it is left to the hidden folder rule.
        Known(name: "Codex", slug: "codex", branches: ["codex/"]),
        Known(name: "Copilot", slug: "copilot", branches: ["copilot/"]),
    ]

    /// Hidden folders that hold other tools' data rather than being a tool themselves; the
    /// folder below names the tool instead (`~/.local/share/foo` is "foo").
    private static let sharedHidden: Set<String> = [".local", ".cache", ".config"]

    /// Hidden folders in home that are not a tool, so a worktree in one gets no tag.
    private static let notTools: Set<String> = [
        ".worktrees", ".worktree", ".work", ".git", ".Trash", ".ssh", ".tmp", ".temp", ".backup", ".old", ".archive",
    ]

    private static let homeParts = URL(fileURLWithPath: DemoData.isOn ? DemoData.home : NSHomeDirectory())
        .standardizedFileURL.pathComponents

    /// Known folder, then known branch prefix, then a hidden tool folder, then nothing.
    init?(path: String, branch: String?) {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        func contains(_ run: [String]) -> Bool {
            guard !run.isEmpty, run.count < parts.count else { return false }
            // The run must hold folders above the worktree, not the worktree folder itself.
            return (0..<(parts.count - run.count)).contains { Array(parts[$0..<($0 + run.count)]) == run }
        }
        if let tool = Self.known.first(where: { $0.folders.contains { contains($0.split(separator: "/").map(String.init)) } }) {
            self.init(tool)
        } else if let branch, let tool = Self.known.first(where: { $0.branches.contains { branch.hasPrefix($0) } }) {
            self.init(tool)
        } else if let folder = Self.hiddenToolFolder(parts) {
            // A folder named after a known tool gets that tool's name: ~/.codex is "Codex".
            let lower = folder.lowercased()
            if let tool = Self.known.first(where: { $0.slug == lower || $0.searchTerms.contains(lower) }) { self.init(tool) }
            else { self.init(name: folder, searchTerms: [folder.lowercased()], slug: folder.lowercased()) }
        } else {
            return nil
        }
    }

    /// Filter match: the start of the name, the slug or a search term, so "claude code",
    /// "vibe-kanban" and "claude" all find Claude Code or Vibe Kanban.
    func matches(_ query: String) -> Bool {
        name.lowercased().hasPrefix(query) || slug.hasPrefix(query) || searchTerms.contains { $0.hasPrefix(query) }
    }

    private init(_ tool: Known) {
        self.init(name: tool.name, searchTerms: tool.searchTerms.isEmpty ? [tool.slug] : tool.searchTerms, slug: tool.slug)
    }

    private init(name: String, searchTerms: [String], slug: String) {
        self.name = name
        self.searchTerms = searchTerms
        self.slug = slug
    }

    /// The tool name from a hidden folder in `~/.foo/...` or `<repo>/.foo/worktrees/...`,
    /// without the dot. Only letters, digits, `-` and `_` count, so a folder name can't put
    /// odd text on screen; anything else gets no tag.
    private static func hiddenToolFolder(_ parts: [String]) -> String? {
        let home = homeParts
        // The last component is the worktree itself, so it never names the tool.
        for i in parts.indices.dropLast() where parts[i].hasPrefix(".") {
            let underHome = i == home.count && parts.starts(with: home)
            let holdsWorktrees = parts[i + 1] == "worktrees" && i + 1 < parts.count - 1
            guard underHome || holdsWorktrees else { continue }
            var folder = parts[i]
            if underHome, notTools.contains(folder) { return nil }
            if underHome, sharedHidden.contains(folder) {
                // ~/.local/share/foo, ~/.cache/foo, ~/.config/foo. Other ~/.local folders
                // (bin, state) hold no tool's worktrees.
                if folder == ".local" && parts[i + 1] != "share" { return nil }
                let j = folder == ".local" ? i + 2 : i + 1
                guard j < parts.count - 1 else { return nil }
                folder = parts[j]
            }
            let name = String(folder.drop { $0 == "." })
            let allowed = name.unicodeScalars.allSatisfy {
                ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
            }
            return allowed && !name.isEmpty && name.count <= 24 ? name : nil
        }
        return nil
    }
}

struct Repo: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let name: String
    let group: String
    var remotes: [Remote]
    var worktrees: [Worktree]

    var githubRemote: Remote? {
        let github = remotes.filter { $0.githubSlug != nil }
        return github.first { $0.name == "origin" } ?? github.first { $0.name == "upstream" } ?? github.first
    }

    var mainWorktree: Worktree? { worktrees.first { $0.isMain } ?? worktrees.first }
    var extraWorktreeCount: Int { worktrees.filter { !$0.isMain }.count }
    var dirtyCount: Int { worktrees.filter(\.isDirty).count }
    var openPRCount: Int { worktrees.filter { $0.pullRequest?.isOpen == true }.count }
    var hasFailingChecks: Bool {
        worktrees.contains { $0.pullRequest?.isOpen == true && $0.pullRequest?.checks == .failing }
    }

    var lastActivity: Date {
        worktrees.compactMap { $0.lastCommit?.date }.max() ?? .distantPast
    }
}

extension String {
    /// Text from git or GitHub, made safe to put on screen: control characters (tab and newline
    /// stay), bidirectional overrides and isolates, directional marks, and terminal OSC
    /// sequences are dropped, so a crafted branch or PR title can't reorder or hide what's shown.
    var sanitizedForDisplay: String {
        var out = replacing(#/\u{1B}\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\)?/#, with: "")
        out.unicodeScalars.removeAll { scalar in
            switch scalar.value {
            case 0x09, 0x0A: false
            case 0x202A...0x202E, 0x2066...0x2069, 0x200E, 0x200F: true
            default: scalar.properties.generalCategory == .control
            }
        }
        return out
    }

    /// Replaces the home directory with ~ for display.
    var abbreviatingHome: String {
        let home = DemoData.isOn ? DemoData.home : NSHomeDirectory()
        return hasPrefix(home) ? "~" + dropFirst(home.count) : self
    }
}
