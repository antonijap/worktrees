import Foundation
import Observation

/// Failure excerpts from GitHub Actions runs, fetched lazily and kept per run id. Only runs
/// whose check is failing get fetched, and only once a worktree with one is selected.
@MainActor
@Observable
final class CheckLogs {
    static let shared = CheckLogs()

    enum Entry: Equatable {
        case loading
        /// gh couldn't fetch it; the link still works.
        case unavailable
        case lines([String])
    }

    private(set) var entries: [String: Entry] = [:]
    private var fetchedAt: [String: Date] = [:]
    /// A run still in progress or re-run keeps its id, so a miss is tried again after a while.
    private let retryAfter: TimeInterval = 120

    func excerpt(for runID: String) -> Entry? { entries[runID] }

    func load(runID: String, slug: String, job: String? = nil) {
        guard !DemoData.isOn else { return }
        if let entry = entries[runID] {
            let stale = Date().timeIntervalSince(fetchedAt[runID] ?? .distantPast) > retryAfter
            guard entry == .unavailable, stale else { return }
        }
        entries[runID] = .loading
        Task {
            let lines = await GitHub.failedLogExcerpt(slug: slug, runID: runID, job: job)
            entries[runID] = lines.map(Entry.lines) ?? .unavailable
            fetchedAt[runID] = Date()
        }
    }

    /// Demo mode: put an excerpt in without asking gh.
    func seed(runID: String, lines: [String]) { entries[runID] = .lines(lines) }
}
