import Foundation
import Testing
@testable import Worktrees

extension All {
    /// The update check and the git check.
    @Suite @MainActor struct ReleaseReadinessTests {
        private func publish(_ sb: Sandbox, tag: String, url: String? = nil) throws {
            let release = ["tag_name": tag, "html_url": url ?? "https://github.com/antonijap/worktrees/releases/tag/\(tag)"]
            try JSONSerialization.data(withJSONObject: release).write(to: URL(fileURLWithPath: sb.manifest.gh).appendingPathComponent("release.json"))
        }

        @Test func versionsCompareByNumber() {
            #expect(UpdateCheck.isNewer("1.10.0", than: "1.9.2"))
            #expect(UpdateCheck.isNewer("1.0.1", than: "1.0"))
            #expect(!UpdateCheck.isNewer("1.0", than: "1.0.0"))
            #expect(!UpdateCheck.isNewer("0.9", than: "1.0.0"))
            #expect(!UpdateCheck.isNewer("banana", than: "1.0.0"), "not a version, never newer")
        }

        @Test func latestReleaseIsReadThroughGh() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            #expect(await UpdateCheck.latest() == nil, "no releases yet: GitHub answers 404")
            try publish(sb, tag: "v1.2.0")
            let latest = try #require(await UpdateCheck.latest())
            #expect(latest.version == "1.2.0")
            #expect(latest.url.absoluteString == "https://github.com/antonijap/worktrees/releases/tag/v1.2.0")
            try publish(sb, tag: "v1.3.0", url: "https://example.com/evil")
            #expect(await UpdateCheck.latest() == nil, "only a github.com link is opened")
        }

        @Test func newerReleaseShowsOncePerDay() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try publish(sb, tag: "v1.1.0")
            let store = await sb.loadedStore()
            store.availableUpdate = nil
            sb.defaults.removeObject(forKey: UpdateCheck.lastCheckKey)
            let now = Date()
            await store.checkForUpdate(current: "1.0.0", now: now)
            #expect(store.availableUpdate?.version == "1.1.0")

            // A newer one comes out an hour later: not asked again until a day has passed.
            try publish(sb, tag: "v1.2.0")
            await store.checkForUpdate(current: "1.0.0", now: now.addingTimeInterval(3600))
            #expect(store.availableUpdate?.version == "1.1.0")
            await store.checkForUpdate(current: "1.0.0", now: now.addingTimeInterval(UpdateCheck.interval + 1))
            #expect(store.availableUpdate?.version == "1.2.0")
        }

        @Test func noUpdateWhenCurrentOffOrSignedOut() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try publish(sb, tag: "v1.0.0")
            let store = await sb.loadedStore()
            sb.defaults.removeObject(forKey: UpdateCheck.lastCheckKey)
            await store.checkForUpdate(current: "1.0.0")
            #expect(store.availableUpdate == nil, "already on the latest")

            try publish(sb, tag: "v2.0.0")
            sb.defaults.removeObject(forKey: UpdateCheck.lastCheckKey)
            sb.defaults.set(false, forKey: Prefs.Key.checkForUpdates)
            await store.checkForUpdate(current: "1.0.0")
            #expect(store.availableUpdate == nil, "turned off in Settings")

            sb.defaults.set(true, forKey: Prefs.Key.checkForUpdates)
            store.githubSignedIn = false
            await store.checkForUpdate(current: "1.0.0")
            #expect(store.availableUpdate == nil, "gh signed out: nothing is asked")

            store.githubSignedIn = true
            await store.checkForUpdate(current: nil)
            #expect(store.availableUpdate == nil, "a build with no version never checks")
        }

        @Test func aFailedLookCountsAsTheDaysLook() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = await sb.loadedStore()
            sb.defaults.removeObject(forKey: UpdateCheck.lastCheckKey)
            let now = Date()
            await store.checkForUpdate(current: "1.0.0", now: now)
            #expect(store.availableUpdate == nil, "no releases yet")
            try publish(sb, tag: "v1.1.0")
            await store.checkForUpdate(current: "1.0.0", now: now.addingTimeInterval(60))
            #expect(store.availableUpdate == nil, "not asked again the same day, even after a 404")
        }

        @Test func foundUpdateSurvivesARelaunchUntilInstalled() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try publish(sb, tag: "v1.1.0")
            let first = await sb.loadedStore()
            sb.defaults.removeObject(forKey: UpdateCheck.lastCheckKey)
            await first.checkForUpdate(current: "1.0.0")
            #expect(first.availableUpdate?.version == "1.1.0")

            // Relaunch the same day: gh isn't asked, the saved release is shown.
            let second = Store(testingRoots: [sb.root])
            second.githubSignedIn = false
            await second.checkForUpdate(current: "1.0.0")
            #expect(second.availableUpdate?.version == "1.1.0")

            // After upgrading to 1.1.0 the notice is gone.
            let third = Store(testingRoots: [sb.root])
            await third.checkForUpdate(current: "1.1.0")
            #expect(third.availableUpdate == nil)
        }

        @Test func turningChecksOffHidesTheNotice() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try publish(sb, tag: "v1.1.0")
            let store = await sb.loadedStore()
            sb.defaults.removeObject(forKey: UpdateCheck.lastCheckKey)
            await store.checkForUpdate(current: "1.0.0")
            #expect(store.availableUpdate != nil)
            sb.defaults.set(false, forKey: Prefs.Key.checkForUpdates)
            try await sb.waitUntil { store.availableUpdate == nil }
        }

        @Test func withoutGitNothingIsScanned() async throws {
            let sb = try Sandbox()
            defer {
                GitCheck.override = nil
                sb.close()
            }
            GitCheck.override = .missing
            let store = Store(testingRoots: [sb.root])
            await store.refresh()
            #expect(store.gitStatus == .missing)
            #expect(store.repos.isEmpty, "no repo is read, so the tools installer never pops up")
            #expect(!store.isScanning)
            GitCheck.override = .ready
            await store.refresh()
            #expect(store.repos.count == 5)
            try await sb.settle(store)
        }

        @Test func checkForUpdatesIsOnUnlessTurnedOff() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            #expect(Prefs.checkForUpdates)
            sb.defaults.set(false, forKey: Prefs.Key.checkForUpdates)
            #expect(!Prefs.checkForUpdates)
        }

        @Test func gitStatusReachesTheStore() async throws {
            let sb = try Sandbox()
            defer {
                GitCheck.override = nil
                sb.close()
            }
            #expect(GitCheck.status == .ready, "this Mac has git")
            GitCheck.override = .licenseNotAccepted
            let store = Store(testingRoots: [sb.root])
            await store.refresh()
            #expect(store.gitStatus == .licenseNotAccepted)
            #expect(store.gitStatus.message?.contains(GitCheck.licenseCommand) == true)
            #expect(GitCheck.Status.missing.message?.contains(GitCheck.installCommand) == true)
            #expect(GitCheck.Status.ready.message == nil)
            #expect(GitCheck.Status.broken.message?.contains("git --version") == true)
        }
    }
}
