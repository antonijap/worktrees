import Foundation
import Testing
@testable import Worktrees

extension All {
    /// Disk sizes, folder counts, delete wording and the menu bar list.
    @Suite @MainActor struct MoreFeatureTests {
        @Test func sizesAreMeasuredAgainOnlyWhenOldEnough() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = Store(testingRoots: [sb.root])
            await store.refresh()
            try await sb.settle(store)
            let path = sb.path("fresh")
            // The scan measures sizes in the background; a call while that runs returns at once.
            try await sb.waitUntil(10) { store.sizes[path] != nil }
            let first = try #require(store.sizes[path])
            try Data(count: 2_000_000).write(to: URL(fileURLWithPath: path).appendingPathComponent("big.bin"))
            await store.loadSizes(for: [path], maxAge: nil)
            #expect(store.sizes[path] == first, "Never: measured once")
            await store.loadSizes(for: [path], maxAge: 60 * 60)
            #expect(store.sizes[path] == first, "an hour hasn't passed")
            await store.loadSizes(for: [path], maxAge: 0)
            #expect((store.sizes[path] ?? 0) > first + 1_500_000, "old enough: measured again")
        }

        @Test func foldersCountTheirRepos() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            #expect(store.repoCount(in: sb.root) == 5)
            #expect(store.repoCount(in: sb.root.appendingPathComponent("elsewhere")) == 0)
        }

        @Test func singleDeleteSaysWhereTheFolderWent() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let (repo, merged) = try #require(store.locate(worktreeID: sb.path("merged")))
            store.deleteWorktree(merged, in: repo)
            try await sb.waitUntil { store.notice == "Deleted merged. Branch kept." }

            sb.defaults.set(true, forKey: Prefs.Key.trashOnDelete)
            let (repo2, closed) = try #require(store.locate(worktreeID: sb.path("closed")))
            store.deleteWorktree(closed, in: repo2)
            try await sb.waitUntil { store.notice == "Moved closed to the Trash. Branch kept." }
            try await sb.settle(store)
        }

        @Test func tidyUpSaysTrashAndNoSpaceFreed() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            sb.defaults.set(true, forKey: Prefs.Key.trashOnDelete)
            let store = await sb.loadedStore()
            store.tidy(TidyCandidate.candidates(in: store.repos).filter { $0.id == sb.path("closed") })
            try await sb.waitUntil(10) { store.notice == "Moved 1 worktree to the Trash. Branches kept." }
            try await sb.settle(store)
        }

        @Test func menuBarListsWhatNeedsAttention() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            let listed = Set(MenuBarMenu.attention(in: store.repos).map(\.worktree.path))
            #expect(listed.contains(sb.path("failing")), "failing checks")
            #expect(listed.contains(sb.path("dirty")), "merged with local changes")
            #expect(listed.contains(sb.path("ahead")), "merged with unpushed commits")
            #expect(!listed.contains(sb.path("merged")))
            #expect(!listed.contains(sb.path("fresh")))
        }
    }

    /// The fences: once tests run, nothing falls back to the real gh, settings or Trash.
    @Suite @MainActor struct FenceTests {
        @Test func realGhIsBlockedWhenNoFakeIsSet() async throws {
            let sb = try Sandbox()
            sb.close()
            #expect(Shell.ghExecutable == nil)
            let result = await Shell.run("gh", ["auth", "token"], limited: false)
            #expect(result.status == 127)
            #expect(result.err.contains("blocked"))
        }

        @Test func settingsFallBackToAnEmptySuiteNotTheRealOne() throws {
            let sb = try Sandbox()
            sb.close()
            #expect(Prefs.testStore == nil)
            #expect(Prefs.store === TestMode.inertDefaults)
            #expect(Prefs.store !== UserDefaults.standard)
        }

        @Test func trashIsRefusedOutsideASandbox() throws {
            let sb = try Sandbox()
            sb.close()
            let probe = FileManager.default.temporaryDirectory.appendingPathComponent("worktrees-tests-probe-\(UUID().uuidString)")
            try Data().write(to: probe)
            defer { try? FileManager.default.removeItem(at: probe) }
            #expect(throws: (any Error).self) { _ = try Store.trash(probe) }
            #expect(FileManager.default.fileExists(atPath: probe.path), "still where it was")
        }

        @Test func onlyTheTestCopyAndBareBuildTakeAFakeGh() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let env = ["WORKTREES_GH": "/tmp/fake"]
            sb.defaults.set("/tmp/test-copy-fake", forKey: TestMode.Key.fakeGh)
            #expect(TestMode.fakeGh(bundleID: "me.apek.worktrees", environment: env, defaults: sb.defaults) == nil, "the installed app ignores both")
            #expect(TestMode.fakeGh(bundleID: "me.apek.worktrees.test", environment: env, defaults: sb.defaults) == "/tmp/test-copy-fake")
            #expect(TestMode.fakeGh(bundleID: nil, environment: env, defaults: sb.defaults) == "/tmp/fake")
        }
    }
}
