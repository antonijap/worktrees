import SwiftUI

/// One status per worktree, most urgent first. Drives the Overview groups, the status text
/// and the VoiceOver label. The row glyph shows PR state and checks separately.
enum WorktreeState: Equatable {
    case missing, conflicted, failing, changesRequested
    /// Merged on GitHub, but the worktree still has work that isn't in the merge.
    case mergedWithLocalWork
    case dirty
    /// Commits not on GitHub yet; 0 means the branch was never pushed.
    case notPushed(ahead: Int)
    case running, draft, readyForReview, approved
    /// Merged, clean and nothing unpushed: safe to delete.
    case merged
    case closed, noPR, clean

    init(_ wt: Worktree) {
        let pr = wt.pullRequest
        let open = pr?.isOpen == true
        let status = wt.status
        let hasLocalWork = wt.isDirty || (status?.ahead ?? 0) > 0

        if wt.isPrunable { self = .missing }
        else if (status?.conflicted ?? 0) > 0 { self = .conflicted }
        else if open, pr?.checks == .failing { self = .failing }
        else if open, pr?.reviewDecision == "CHANGES_REQUESTED" { self = .changesRequested }
        else if pr?.state == "MERGED" { self = hasLocalWork ? .mergedWithLocalWork : .merged }
        else if pr?.state == "CLOSED", !hasLocalWork { self = .closed }
        else if wt.isDirty { self = .dirty }
        else if let status, status.upstream != nil, status.ahead > 0 { self = .notPushed(ahead: status.ahead) }
        // No upstream but a PR exists: pushed without -u. The PR proves it's on GitHub.
        else if let status, status.upstream == nil, pr == nil, !wt.isMain, wt.branch != nil { self = .notPushed(ahead: 0) }
        else if open, pr?.checks == .pending { self = .running }
        else if open, pr?.isDraft == true { self = .draft }
        else if open, pr?.reviewDecision == "APPROVED" { self = .approved }
        else if open { self = .readyForReview }
        else if wt.isMain { self = .clean }
        else { self = .noPR }
    }

    var label: String {
        switch self {
        case .missing: "Missing on disk"
        case .conflicted: "Merge conflicts"
        case .failing: "Checks failing"
        case .changesRequested: "Changes requested"
        case .mergedWithLocalWork: "Merged, with local changes"
        case .dirty: "Uncommitted changes"
        case .notPushed(let ahead):
            ahead == 0 ? "Not pushed yet" : "\(ahead) commit\(ahead == 1 ? "" : "s") not pushed"
        case .running: "Checks running"
        case .draft: "Draft"
        case .readyForReview: "Waiting for review"
        case .approved: "Approved"
        case .merged: "Merged"
        case .closed: "PR closed"
        case .noPR: "No PR yet"
        case .clean: "Clean"
        }
    }

    var color: Color {
        switch self {
        case .missing, .conflicted, .failing, .changesRequested, .mergedWithLocalWork: Theme.danger
        case .dirty, .notPushed, .running: Theme.warning
        case .readyForReview, .approved: Theme.success
        case .merged: Theme.merged
        case .draft, .closed, .noPR, .clean: Theme.muted
        }
    }

    /// The Overview group this state belongs to.
    var group: OverviewGroup {
        switch self {
        case .missing, .conflicted, .failing, .changesRequested, .mergedWithLocalWork: .attention
        case .dirty, .notPushed, .running, .draft: .inProgress
        case .readyForReview: .review
        case .approved: .merge
        case .merged: .cleanup
        case .closed, .noPR, .clean: .other
        }
    }

    var needsAttention: Bool { group == .attention }
}

enum OverviewGroup: CaseIterable {
    case attention, inProgress, review, merge, cleanup, other

    var title: String {
        switch self {
        case .attention: "Needs attention"
        case .inProgress: "In progress"
        case .review: "Waiting for review"
        case .merge: "Ready to merge"
        case .cleanup: "Merged, safe to delete"
        case .other: "Everything else"
        }
    }
}

/// Splits `feature/SHOP-412-checkout-redesign` into kind, ticket and a readable title.
struct BranchName {
    let kind: String?
    let ticket: String?
    let title: String

    init(_ branch: String) {
        let pattern = #/^(?:([\w.-]+)/)?(?:([A-Za-z][A-Za-z0-9]+-\d+)[-_]?)?(.*)$/#
        guard let m = branch.firstMatch(of: pattern) else {
            kind = nil; ticket = nil; title = branch
            return
        }
        kind = m.1.map(String.init)
        ticket = m.2.map { String($0).uppercased() }
        let words = String(m.3).replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces)
        title = words.isEmpty ? (ticket ?? branch) : words.prefix(1).uppercased() + words.dropFirst()
    }
}

extension PullRequest {
    /// Title without a leading "[SHOP-412]" or "SHOP-412:" since the ticket is shown separately.
    var cleanTitle: String {
        title.replacing(#/^\s*\[?[A-Za-z][A-Za-z0-9]+-\d+\]?:?\s*/#, with: "")
    }
}

extension Repo {
    /// The PR if there is one, else the pushed branch, else the repo.
    func githubURL(for wt: Worktree) -> URL? {
        if let pr = wt.pullRequest, let url = URL(string: pr.url) { return url }
        guard let base = githubRemote?.webURL else { return nil }
        if wt.status?.upstream != nil, let branch = wt.remoteBranch {
            return base.appendingPathComponent("tree").appendingPathComponent(branch)
        }
        return base
    }

    var needsAttention: Bool {
        worktrees.contains { WorktreeState($0).needsAttention }
    }
}

extension Worktree {
    /// Linked worktrees, plus main checkouts with recent work in progress. Old checkouts with
    /// leftover changes would otherwise bury the worktrees that matter. The Overview and
    /// `worktrees list` both go by this.
    func showsInOverview(now: Date = .now) -> Bool {
        guard isMain else { return true }
        return WorktreeState(self).group == .inProgress && (lastCommit?.date ?? .distantPast) > now.addingTimeInterval(-14 * 86_400)
    }

    var branchName: BranchName { BranchName(branch ?? "") }

    /// What a person would call this worktree: the PR title, else the branch in words.
    var displayTitle: String {
        if let pr = pullRequest { return pr.cleanTitle }
        guard let branch else { return "Detached at \(head.prefix(7))" }
        return isMain ? branch : branchName.title
    }
}

extension PullRequest {
    var checkCounts: (passed: Int, failed: Int, pending: Int, skipped: Int) {
        var c = (passed: 0, failed: 0, pending: 0, skipped: 0)
        for item in statusCheckRollup ?? [] {
            let result = (item.conclusion?.isEmpty == false ? item.conclusion : item.state)?.uppercased() ?? ""
            switch result {
            case "SUCCESS", "NEUTRAL": c.passed += 1
            case "SKIPPED": c.skipped += 1
            case "FAILURE", "ERROR", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": c.failed += 1
            default: c.pending += 1
            }
        }
        return c
    }
}

/// The glyph shows the PR's state, a corner badge shows its checks.
extension Worktree {
    var prGlyph: (icon: IconName, color: Color, label: String) {
        guard let pr = pullRequest else { return (.prGitBranch, Theme.muted, "No linked pull request") }
        switch pr.state {
        case "MERGED": return (.prGitMerge, Theme.merged, "Pull request merged")
        case "CLOSED": return (.prGitPullRequestClosed, Theme.danger, "Pull request closed")
        default:
            return pr.isDraft
                ? (.prGitPullRequestDraft, Theme.muted, "Pull request in draft")
                : (.prGitPullRequest, Theme.success, "Pull request open")
        }
    }

    var checkBadge: CheckBadge? {
        guard let checks = pullRequest?.checks else { return nil }
        switch checks {
        case .passing: return .passing
        case .failing: return .failing
        case .pending: return .running
        case .none: return nil
        }
    }
}

enum CheckBadge {
    case passing, failing, running

    /// SF Symbol, drawn in its `.circle.fill` variant.
    var symbol: String {
        switch self {
        case .passing: "checkmark"
        case .failing: "xmark"
        case .running: "ellipsis"
        }
    }

    var fill: Color {
        switch self {
        case .passing: Theme.badgeGreen
        case .failing: Theme.badgeRed
        case .running: Theme.badgeYellow
        }
    }

    var label: String {
        switch self {
        case .passing: "Checks passed"
        case .failing: "Checks failed"
        case .running: "Checks in progress"
        }
    }
}
