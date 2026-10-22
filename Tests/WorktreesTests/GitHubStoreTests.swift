import Foundation
import Testing
@testable import Worktrees

extension All {
    /// PR lookups through the fake gh: no PR is not a failure, failures are counted, sign-in.
    @Suite @MainActor struct GitHubTests {
        @Test func branchWithoutPRIsNotAFailedLookup() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            // gamma's gh call fails on purpose: its one worktree is the only failure.
            #expect(store.githubNote == "1 GitHub lookup failed, showing older data")
            #expect(sb.worktree("fresh", in: store)?.pullRequest == nil)
            #expect(sb.worktree("failing", in: store)?.pullRequest?.checks == .failing)
            #expect(store.githubSignedIn == true)
            #expect(GitHub.viewer == "fixture-user")
        }

        @Test func noteClearsWhenEveryLookupWorks() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try sb.setPullRequests("fixture/gamma", [:])
            let store = await sb.loadedStore()
            #expect(store.githubNote == nil)
        }

        @Test func protectedBranchesAreNotAskedAbout() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            _ = await sb.loadedStore()
            let asked = sb.askedBranches()
            #expect(!asked.contains("main"))
            #expect(asked.contains("feat/merged"))
            #expect(asked.contains("release"))
        }

        @Test func signedOutSaysSoAndLooksNothingUp() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try sb.signOut()
            let store = await sb.loadedStore()
            #expect(store.githubSignedIn == false)
            #expect(store.githubNote?.contains("gh isn't signed in") == true)
            #expect(sb.askedBranches().isEmpty)
        }
    }

    /// Notifications fire on a change between two passes, never on the first look.
    @Suite @MainActor struct NotificationTests {
        @Test func firstPassStaysQuiet() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(true, forKey: Prefs.Key.notifyChecksFailed)
            sb.defaults.set(true, forKey: Prefs.Key.notifyMerged)
            _ = await sb.loadedStore()
            #expect(sb.notifications.isEmpty, "PR 3 was already failing at launch")
        }

        @Test func checksTurningRedNotifies() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(true, forKey: Prefs.Key.notifyChecksFailed)
            try sb.setPullRequests("fixture/alpha", ["feat/failing": [fixturePR(3, "feat/failing", "OPEN", checks: "SUCCESS")]])
            let store = await sb.loadedStore()
            #expect(sb.notifications.isEmpty)
            try sb.setPullRequests("fixture/alpha", ["feat/failing": [fixturePR(3, "feat/failing", "OPEN", checks: "FAILURE")]])
            await store.loadGitHub()
            #expect(sb.notifications.count == 1)
            #expect(sb.notifications.first?.title == "Checks failed")
            #expect(sb.notifications.first?.body.contains("#3") == true)
            #expect(sb.notifications.first?.url == "https://github.com/fixture/alpha/pull/3")
            // Still red on the next pass: no second notification.
            await store.loadGitHub()
            #expect(sb.notifications.count == 1)
        }

        @Test func mergeNotifiesOnlyWhenAsked() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try sb.setPullRequests("fixture/alpha", ["feat/fresh": [fixturePR(9, "feat/fresh", "OPEN", checks: "SUCCESS")]])
            let store = await sb.loadedStore()
            try sb.setPullRequests("fixture/alpha", ["feat/fresh": [fixturePR(9, "feat/fresh", "MERGED", checks: "SUCCESS")]])
            await store.loadGitHub()
            #expect(sb.notifications.isEmpty, "merge notifications are off by default")

            sb.defaults.set(true, forKey: Prefs.Key.notifyMerged)
            try sb.setPullRequests("fixture/alpha", ["feat/fresh": [fixturePR(10, "feat/fresh", "OPEN")]])
            await store.loadGitHub()
            try sb.setPullRequests("fixture/alpha", ["feat/fresh": [fixturePR(10, "feat/fresh", "MERGED")]])
            await store.loadGitHub()
            #expect(sb.notifications.map(\.title) == ["Pull request merged"])
        }
    }

    /// Settings changes reach what is on screen without a rescan.
    @Suite @MainActor struct LiveSettingsTests {
        @Test func hidingAToolTagUpdatesTheRows() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            #expect(sb.worktree("claude", in: store)?.shownCreator?.name == "Claude Code")
            sb.defaults.set(["claude-code"], forKey: Prefs.Key.hiddenTools)
            try await sb.waitUntil { sb.worktree("claude", in: store)?.creatorHidden == true }
            #expect(sb.worktree("claude", in: store)?.shownCreator == nil)
            #expect(sb.worktree("codex", in: store)?.shownCreator?.name == "Codex", "other tools keep their tag")
            sb.defaults.set([String](), forKey: Prefs.Key.hiddenTools)
            try await sb.waitUntil { sb.worktree("claude", in: store)?.creatorHidden == false }
        }

        @Test func displaySettingsBumpTheRedrawCounter() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let before = store.prefsVersion
            sb.defaults.set(14, forKey: Prefs.Key.staleDays)
            try await sb.waitUntil { store.prefsVersion > before }
        }

        @Test func unrelatedWritesDoNothing() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let before = store.prefsVersion
            sb.defaults.set(320.0, forKey: "someColumnWidth")
            // Then a real change: once that lands, the unrelated write before it has been seen too.
            sb.defaults.set(true, forKey: Prefs.Key.trashOnDelete)
            try await sb.waitUntil { store.prefsVersion > before }
            #expect(store.prefsVersion == before + 1, "only the Trash setting counted")
        }

        @Test func addingASkippedFolderRescans() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            #expect(store.repos.contains { $0.path == sb.repoPath("sandboxed") })
            sb.defaults.set(["sandbox"], forKey: Prefs.Key.skippedFolders)
            try await sb.waitUntil(10) { !store.repos.contains { $0.path == sb.repoPath("sandboxed") } }
            try await sb.settle(store)
        }
    }

    /// Deleting for real and moving to the Trash.
    @Suite @MainActor struct DeleteTests {
        private func branchExists(_ sb: Sandbox, _ branch: String) async -> Bool {
            await sb.git(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: sb.path("alpha")).ok
        }

        private func gitLists(_ sb: Sandbox, _ path: String) async -> Bool {
            let listing = await sb.git(["worktree", "list", "--porcelain", "-z"], in: sb.path("alpha"))
            return Scanner.parseWorktrees(listing.out).contains { $0.path == path }
        }

        @Test func deleteRemovesFolderAndKeepsBranch() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let (repo, wt) = try #require(store.locate(worktreeID: sb.path("merged")))
            let failures = await store.deleteWorktrees([wt], in: repo)
            #expect(failures.isEmpty)
            try await sb.waitUntil { !FileManager.default.fileExists(atPath: sb.path("merged")) }
            // The folder is renamed aside first; that copy must be gone too.
            let parent = URL(fileURLWithPath: sb.path("merged")).deletingLastPathComponent().path
            try await sb.waitUntil {
                !((try? FileManager.default.contentsOfDirectory(atPath: parent)) ?? []).contains { $0.hasPrefix(".merged.deleting-") }
            }
            #expect(await !gitLists(sb, sb.path("merged")))
            #expect(await branchExists(sb, "feat/merged"))
            #expect((try? FileManager.default.contentsOfDirectory(atPath: sb.trashDir.path))?.isEmpty == true)
        }

        @Test func trashKeepsTheFolderUnderItsOwnName() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(true, forKey: Prefs.Key.trashOnDelete)
            let store = await sb.loadedStore()
            let (repo, wt) = try #require(store.locate(worktreeID: sb.path("closed")))
            let failures = await store.deleteWorktrees([wt], in: repo)
            #expect(failures.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: sb.path("closed")))
            let trashed = sb.trashDir.appendingPathComponent("closed")
            #expect(FileManager.default.fileExists(atPath: trashed.appendingPathComponent("closed.txt").path), "files intact in the Trash")
            #expect(await !gitLists(sb, sb.path("closed")))
            #expect(await branchExists(sb, "feat/closed"))
        }

        @Test func failedTrashLeavesEverythingInPlace() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(true, forKey: Prefs.Key.trashOnDelete)
            Store.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
            let store = await sb.loadedStore()
            let (repo, wt) = try #require(store.locate(worktreeID: sb.path("merged")))
            let failures = await store.deleteWorktrees([wt], in: repo)
            #expect(failures.first?.error.contains("Couldn't move") == true)
            #expect(FileManager.default.fileExists(atPath: sb.path("merged")))
            #expect(await gitLists(sb, sb.path("merged")))
        }

        @Test func tidyDeletesOnlyWhatStillQualifies() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let all = TidyCandidate.candidates(in: store.repos)
            let picked = all.filter { [sb.path("merged"), sb.path("beta-merged"), sb.path("release")].contains($0.id) }
            #expect(picked.count == 3)
            // release gets an uncommitted file after it was picked: by the latest scan it no longer qualifies.
            try Data("new work\n".utf8).write(to: URL(fileURLWithPath: sb.path("release")).appendingPathComponent("wip.txt"))
            await store.refresh()
            store.tidy(picked)
            try await sb.waitUntil(10) {
                !FileManager.default.fileExists(atPath: sb.path("merged")) && !FileManager.default.fileExists(atPath: sb.path("beta-merged"))
            }
            try await sb.waitUntil { store.notice?.hasPrefix("Deleted 2 worktrees") == true }
            #expect(FileManager.default.fileExists(atPath: sb.path("release") + "/wip.txt"), "changed since it was picked, left alone")
            #expect(FileManager.default.fileExists(atPath: sb.path("closed")), "not picked, not touched")
            try await sb.settle(store)
        }
    }

    /// Guards that keep tests and the test app away from real system state.
    @Suite @MainActor struct IsolationTests {
        @Test func noRealNotificationsOrLoginItemsUnderTests() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            #expect(Notifier.available == false)
            #expect(LoginItem.set(true) != nil, "tests must never register a login item")
        }

        @Test func testStoreNeverSavesFolders() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let before = UserDefaults.standard.stringArray(forKey: "roots")
            let store = Store(testingRoots: [sb.root])
            store.roots = [sb.root, sb.root.appendingPathComponent("work")]
            #expect(UserDefaults.standard.stringArray(forKey: "roots") == before)
        }
    }
}
