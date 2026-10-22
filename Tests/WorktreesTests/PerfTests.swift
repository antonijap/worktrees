import Darwin
import Foundation
import Testing
@testable import Worktrees

extension All {
    /// Timing on a big setup. Off by default; scripts/perf.sh builds the fixtures
    /// (make-fixtures.py --many 200) and runs this with WORKTREES_PERF pointing at them.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["WORKTREES_PERF"] != nil)) @MainActor
    struct PerfTests {
        private func residentMB() -> Double {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
        }

        private func time(_ label: String, _ body: () async throws -> Void) async rethrows -> Double {
            let start = Date()
            try await body()
            let seconds = Date().timeIntervalSince(start)
            print("PERF \(label): \(String(format: "%.2f", seconds)) s, \(String(format: "%.0f", residentMB())) MB resident")
            return seconds
        }

        @Test func bigSetup() async throws {
            let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WORKTREES_PERF"]))
            let sb = try Sandbox(existing: dir)
            defer { sb.close() }

            var found: [String] = []
            let find = await time("find repos (200)") { found = Scanner.findRepos(root: sb.root) }
            #expect(found.count == 200)

            let store = Store(testingRoots: [sb.root])
            // gh blocked first, so the scan is timed on its own.
            Shell.ghExecutable = nil
            let scan = await time("scan and git status (1,200 worktrees)") { await store.refresh() }
            Shell.ghExecutable = sb.manifest.fakeGh
            let github = await time("GitHub pass (200 fake gh calls)") { await store.loadGitHub() }
            #expect(store.repos.count == 200)
            #expect(store.repos.reduce(0) { $0 + $1.worktrees.count } == 1_200)
            try await sb.settle(store)

            let paths = store.repos.flatMap(\.worktrees).filter { !$0.isMain }.map(\.path)
            let sizes = await time("disk sizes (1,000 worktrees, 100 with 2,000 files)") { await store.loadSizes(for: paths, maxAge: 0) }
            #expect(store.sizes.count >= 1_000)

            let tidy = await time("tidy candidates") { _ = TidyCandidate.candidates(in: store.repos) }
            // Budgets with room for a slower Mac; the point is catching a regression by 10x.
            #expect(find < 5)
            #expect(scan < 60)
            #expect(github < 60)
            #expect(sizes < 120)
            #expect(tidy < 0.2)
            #expect(residentMB() < 500)
        }
    }
}
