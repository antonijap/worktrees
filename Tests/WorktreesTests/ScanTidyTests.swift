import Foundation
import Testing
@testable import Worktrees

extension All {
    /// What the scan finds, and how scan depth and skipped folders change it.
    @Suite @MainActor struct ScanTests {
        @Test func defaultScanSkipsNodeModulesAndStopsAtFourLevels() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let found = Set(Scanner.findRepos(root: sb.root))
            #expect(found.contains(sb.repoPath("alpha")))
            #expect(found.contains(sb.repoPath("beta")))
            #expect(found.contains(sb.repoPath("gamma")))
            #expect(found.contains(sb.repoPath("sandboxed")))
            #expect(found.contains(sb.repoPath("delta")))
            #expect(!found.contains(sb.repoPath("hidden")), "node_modules is always skipped")
            #expect(!found.contains(sb.repoPath("deep")), "five folders down is past the default depth")
            #expect(found.count == 5)
        }

        @Test func scanDepthFindsDeeperRepos() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(5, forKey: Prefs.Key.scanDepth)
            #expect(Scanner.findRepos(root: sb.root).contains(sb.repoPath("deep")))
            sb.defaults.set(2, forKey: Prefs.Key.scanDepth)
            let shallow = Scanner.findRepos(root: sb.root)
            #expect(shallow.contains(sb.repoPath("beta")), "work/beta is two levels down")
            #expect(!shallow.contains(sb.repoPath("delta")), "work/team/delta is three levels down")
            sb.defaults.set(3, forKey: Prefs.Key.scanDepth)
            #expect(Scanner.findRepos(root: sb.root).contains(sb.repoPath("delta")))
        }

        @Test func extraSkippedFolderHidesItsRepos() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(["sandbox"], forKey: Prefs.Key.skippedFolders)
            let found = Scanner.findRepos(root: sb.root)
            #expect(!found.contains(sb.repoPath("sandboxed")))
            #expect(found.contains(sb.repoPath("alpha")))
        }

        @Test func worktreeStatesAreReadFromGit() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let dirty = try #require(sb.worktree("dirty", in: store))
            #expect(dirty.status?.isClean == false)
            let ahead = try #require(sb.worktree("ahead", in: store))
            #expect(ahead.status?.ahead == 1)
            let local = try #require(sb.worktree("local", in: store))
            let localStatus = try #require(local.status, "status must be read before judging the upstream")
            #expect(localStatus.upstream == nil)
            let stale = try #require(sb.worktree("stale", in: store))
            let age = Date().timeIntervalSince(try #require(stale.lastCommit).date) / 86_400
            #expect(age > 44 && age < 46)
            #expect(sb.worktree("claude", in: store)?.creator?.slug == "claude-code")
            #expect(sb.worktree("codex", in: store)?.creator?.slug == "codex")
        }
    }

    /// Which worktrees Tidy up offers, and how the Tidy up settings change that.
    @Suite @MainActor struct TidyTests {
        private func reasons(_ sb: Sandbox, _ store: Store) -> [String: TidyReason] {
            var out: [String: TidyReason] = [:]
            for (key, path) in sb.manifest.paths {
                if let wt = store.locate(worktreeID: path)?.1, let r = TidyCandidate.reason(for: wt) { out[key] = r }
            }
            return out
        }

        @Test func defaultsOfferMergedClosedAndStale() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let r = reasons(sb, store)
            #expect(r["merged"] == .merged)
            #expect(r["closed"] == .closed)
            #expect(r["release"] == .merged)
            #expect(r["claude"] == .merged)
            #expect(r["beta-merged"] == .merged)
            #expect(r["stale"] == .stale, "45 days without commits")
            #expect(r["codex"] == .stale, "40 days without commits")
            for key in ["fresh", "dirty", "ahead", "local", "failing", "gamma-unknown", "alpha"] {
                #expect(r[key] == nil, "\(key) must never be offered")
            }
        }

        @Test func staleDaysMoveTheLine() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            sb.defaults.set(7, forKey: Prefs.Key.staleDays)
            #expect(reasons(sb, store)["fresh"] == .stale, "10 days counts at 7")
            #expect(TidyReason.stale.label == "No commits in 7 days")
            sb.defaults.set(60, forKey: Prefs.Key.staleDays)
            let r = reasons(sb, store)
            #expect(r["stale"] == nil)
            #expect(r["codex"] == nil)
            #expect(r["merged"] == .merged, "merged doesn't depend on age")
        }

        @Test func staleOnesAreTickedOnlyWhenAsked() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            func ticked(_ key: String) -> Bool? {
                TidyCandidate.candidates(in: store.repos).first { $0.id == sb.path(key) }?.preselected
            }
            #expect(ticked("merged") == true)
            #expect(ticked("stale") == false)
            sb.defaults.set(true, forKey: Prefs.Key.preselectStale)
            #expect(ticked("stale") == true)
        }

        @Test func protectedBranchIsNeverOfferedAndLosesItsPR() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            #expect(sb.worktree("release", in: store)?.pullRequest?.number == 6)
            sb.defaults.set(Prefs.Default.protectedBranches + ["release"], forKey: Prefs.Key.protectedBranches)
            #expect(reasons(sb, store)["release"] == nil)
            await store.loadGitHub()
            #expect(sb.worktree("release", in: store)?.pullRequest == nil, "a protected branch keeps no stale PR")
        }

        @Test func emptyingTheListLetsMainBeLookedUp() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set([String](), forKey: Prefs.Key.protectedBranches)
            _ = await sb.loadedStore()
            #expect(sb.askedBranches().contains("main"))
        }
    }
}
