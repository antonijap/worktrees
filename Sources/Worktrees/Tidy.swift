import Foundation

/// Why a worktree can go. Only clean worktrees with nothing unpushed and no open PR qualify.
enum TidyReason: Int, Comparable, CaseIterable {
    case merged, closed, stale

    static func < (a: TidyReason, b: TidyReason) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .merged: "Merged"
        case .closed: "PR closed"
        case .stale: "No commits in \(Prefs.staleDays) days"
        }
    }
}

struct TidyCandidate: Identifiable, Hashable {
    let repo: Repo
    let worktree: Worktree
    let reason: TidyReason
    /// Ticked when the sheet opens. Merged and closed are safe bets, as long as git could
    /// confirm there is nothing unpushed. Stale ones get a look first, unless Settings says otherwise.
    let preselected: Bool

    var id: String { worktree.id }

    static func == (a: TidyCandidate, b: TidyCandidate) -> Bool { a.id == b.id && a.reason == b.reason }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension TidyCandidate {
    /// Never a main checkout, a locked worktree, a protected branch, or anything with
    /// uncommitted files, unpushed commits or an open PR.
    /// The settings are read once per call by default; `candidates` reads them once for all.
    static func reason(for wt: Worktree, now: Date = .now,
                       protected: Set<String> = Prefs.protectedBranches, staleAfter: TimeInterval = Prefs.staleAfter) -> TidyReason? {
        guard !wt.isMain, !wt.isPrunable, !wt.isLocked, let branch = wt.branch,
              !protected.contains(branch),
              let status = wt.status, status.isClean, status.ahead == 0
        else { return nil }
        let pr = wt.pullRequest
        if pr?.isOpen == true { return nil }
        if pr?.state == "MERGED" { return .merged }
        if pr?.state == "CLOSED" { return .closed }
        // No PR and no upstream: the commits only exist here, so that counts as unpushed.
        // No ahead count: the upstream was deleted, so unpushed work can't be ruled out.
        guard status.upstream != nil, status.aheadKnown, let last = wt.lastCommit else { return nil }
        return now.timeIntervalSince(last.date) >= staleAfter ? .stale : nil
    }

    static func candidates(in repos: [Repo], now: Date = .now) -> [TidyCandidate] {
        let preselectStale = Prefs.preselectStale
        let protected = Prefs.protectedBranches
        let staleAfter = Prefs.staleAfter
        return repos.flatMap { repo in
            repo.worktrees.compactMap { wt in
                reason(for: wt, now: now, protected: protected, staleAfter: staleAfter).map {
                    TidyCandidate(repo: repo, worktree: wt, reason: $0,
                                  preselected: ($0 != .stale || preselectStale) && wt.status?.aheadKnown == true)
                }
            }
        }
        // Titles are worked out once each, not on every comparison: turning a branch name into
        // words is the slow part, and a big setup sorts hundreds of these.
        .map { (candidate: $0, title: $0.worktree.displayTitle) }
        .sorted {
            if $0.candidate.reason != $1.candidate.reason { return $0.candidate.reason < $1.candidate.reason }
            return ($0.candidate.repo.name, $0.title) < ($1.candidate.repo.name, $1.title)
        }
        .map(\.candidate)
    }
}

/// "1.2 GB", "340 MB", "12 KB".
func formatBytes(_ bytes: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: bytes)
}

/// Folder sizes via `du`, a couple at a time so a big node_modules doesn't starve the scan.
enum DiskUsage {
    private static let limiter = Limiter(2)

    /// nil when du couldn't read the folder (missing, or no permission yet). Runs at low
    /// priority, follows a symlinked worktree path, and finishes even if the caller gave up,
    /// so a path never gets stuck half measured.
    static func bytes(at path: String) async -> Int64? {
        await limiter.acquire()
        let result = await Shell.run("nice", ["-n", "10", "du", "-skH", path], limited: false)
        await limiter.release()
        guard result.ok,
              let field = result.out.split(whereSeparator: { $0 == "\t" || $0 == " " }).first,
              let kb = Int64(field) else { return nil }
        return kb * 1024
    }
}
