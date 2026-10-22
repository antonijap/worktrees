import Foundation
import Testing
@testable import Worktrees

extension All {
    /// First launch on the fixtures, with the fixture folder standing in for the home folder.
    @Suite @MainActor struct OnboardingTests {
        private func home(_ sb: Sandbox) -> URL { sb.dir.resolvingSymlinksInPath() }

        @Test func onlyNewInstallsSeeIt() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            #expect(Onboarding.isNeeded(sb.defaults), "nothing saved yet")
            sb.defaults.set(["/x"], forKey: "roots")
            #expect(!Onboarding.isNeeded(sb.defaults), "folders saved by an earlier version")
            sb.defaults.removeObject(forKey: "roots")
            sb.defaults.set("0 0 800 600 0 0 1440 900", forKey: "NSWindow Frame Main")
            #expect(!Onboarding.isNeeded(sb.defaults), "0.1.0 never saved ~/Code, but it saved its window")
            sb.defaults.removeObject(forKey: "NSWindow Frame Main")
            Onboarding.markDone(sb.defaults)
            #expect(!Onboarding.isNeeded(sb.defaults))
        }

        @Test func findsProjectFoldersButNeverLooksInDocuments() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let found = FolderFinder.find(home: home(sb), depth: 4, skipping: Prefs.skippedFolders)
            let names = found.map(\.url.lastPathComponent)
            #expect(names == ["Code", "Projects"], "most repos first; src is the same folder as Code")
            #expect(found.first?.repoCount == 5)
            #expect(found.last?.repoCount == 1)
            #expect(found.allSatisfy { $0.picked })
            #expect(!names.contains("Developer"), "empty: no repos, not offered")
            #expect(!names.contains("Documents"))
        }

        @Test func walkingThroughAllFourSteps() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = Store(testingRoots: [])
            let model = OnboardingModel(store: store, home: home(sb))
            #expect(model.step == .welcome)

            model.next()
            #expect(model.step == .folders)
            try await sb.waitUntil { !model.finding && model.suggestions.count == 2 }

            // Untick everything: Continue is off.
            for s in model.suggestions { model.toggle(s) }
            #expect(!model.canContinue)
            model.next()
            #expect(model.step == .folders)

            // Only Code.
            model.toggle(try #require(model.suggestions.first { $0.url.lastPathComponent == "Code" }))
            model.next()
            #expect(model.step == .github)
            #expect(store.roots.map(\.lastPathComponent) == ["Code"])

            try await sb.waitUntil { model.github != nil }
            #expect(model.github == .ready(path: sb.manifest.fakeGh, login: "fixture-user"))

            try await sb.settle(store)
            model.next()
            #expect(model.step == .ready)
            let stats = model.stats
            #expect(stats.repos == 5)
            #expect(stats.worktrees == 13)
            #expect(stats.attention == 3)
            #expect(stats.tidy == 7)

            #expect(Onboarding.isNeeded(sb.defaults), "nothing is marked done before Open Worktrees")
            model.finish(sb.defaults)
            #expect(!Onboarding.isNeeded(sb.defaults))
        }

        @Test func backGoesBackAndStopsAtWelcome() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let model = OnboardingModel(store: Store(testingRoots: []), home: home(sb))
            model.step = .github
            model.back()
            #expect(model.step == .folders)
            model.back()
            model.back()
            #expect(model.step == .welcome)
        }

        @Test func chosenFolderIsAddedOnceAndTicked() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let model = OnboardingModel(store: Store(testingRoots: []), home: home(sb))
            model.start()
            try await sb.waitUntil { !model.finding }
            let code = try #require(model.suggestions.first { $0.url.lastPathComponent == "Code" })
            model.toggle(code)
            // src is a symlink to Code: choosing it ticks Code again instead of adding a second row.
            await model.add([home(sb).appendingPathComponent("src")])
            #expect(model.suggestions.count == 2)
            #expect(model.suggestions.first { $0.id == code.id }?.picked == true)
            await model.add([home(sb).appendingPathComponent("Documents/GitHub")])
            #expect(model.suggestions.count == 3)
            #expect(model.suggestions.last?.repoCount == 1, "a folder chosen by hand is counted")
        }

        @Test func githubStates() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            #expect(await GitHubSetup.check() == .ready(path: sb.manifest.fakeGh, login: "fixture-user"))
            try sb.signOut()
            #expect(await GitHubSetup.check() == .signedOut(path: sb.manifest.fakeGh))
            Shell.ghExecutable = sb.dir.appendingPathComponent("no-such-gh").path
            #expect(await GitHubSetup.check() == .notInstalled)
            Shell.ghExecutable = nil
            #expect(await GitHubSetup.check() == .notInstalled, "test mode never looks for the real gh")
        }

        @Test func scanningHomeSkipsGuardedFolders() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let home = home(sb)
            let fromHome = Scanner.findRepos(root: home, maxDepth: 4, skipping: Prefs.skippedFolders, home: home)
            #expect(fromHome.contains { $0.hasSuffix("/Projects/omega") })
            #expect(!fromHome.contains { $0.hasSuffix("/Documents/GitHub/guarded") }, "Documents right under home is never walked")
            // From the folder above home (like adding /Users), home is still recognised.
            let fromAbove = Scanner.findRepos(root: home.deletingLastPathComponent(), maxDepth: 5, skipping: Prefs.skippedFolders, home: home)
            // Exact path: other fixture folders in the same temp folder may hold their own Documents.
            #expect(!fromAbove.contains(sb.repoPath("guarded")))
            #expect(fromAbove.contains(sb.repoPath("omega")), "the walk did reach this home")
            // Chosen directly, Documents/GitHub is fine: only the walk from home avoids it.
            let direct = Scanner.findRepos(root: home.appendingPathComponent("Documents/GitHub"), maxDepth: 4, skipping: Prefs.skippedFolders, home: home)
            #expect(direct.count == 1)
        }

        @Test func foldersAddedInSettingsDuringOnboardingAreKept() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = Store(testingRoots: [])
            let model = OnboardingModel(store: store, home: home(sb))
            #expect(store.onboardingActive)
            model.next()
            try await sb.waitUntil { !model.finding && !model.suggestions.isEmpty }
            model.next()
            let extra = home(sb).appendingPathComponent("Documents/GitHub")
            store.addRoots([extra])
            try await sb.settle(store)
            model.finish(sb.defaults)
            #expect(!store.onboardingActive)
            #expect(store.roots.contains(extra))
            #expect(store.roots.contains { $0.lastPathComponent == "Code" })
        }

        @Test func checkAgainShowsItIsChecking() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let model = OnboardingModel(store: Store(testingRoots: []), home: home(sb))
            model.checkGitHub()
            try await sb.waitUntil { model.github != nil }
            model.checkGitHub()
            #expect(model.github == nil, "back to Checking while it looks again")
            try await sb.waitUntil { model.github != nil }
        }

        @Test func noFoldersFoundLeavesChooseAnother() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let empty = sb.dir.appendingPathComponent("Developer")
            #expect(FolderFinder.find(home: empty, depth: 4, skipping: Prefs.skippedFolders).isEmpty)
        }
    }
}
