import Foundation
import SwiftUI
import Testing
@testable import Worktrees

extension All {
    /// Colour in Why it failed, and Check for Updates in the menu.
    @Suite @MainActor struct PatchTests {
        @Test func logLinesGetTheirColour() {
            #expect(LogHighlight.lineRole("FAIL src/cart/badge.test.ts") == .failure)
            #expect(LogHighlight.lineRole("Error: Process completed with exit code 1.") == .failure)
            #expect(LogHighlight.lineRole("Tests: 1 failed, 86 passed, 87 total") == .failure, "a failure beats a pass")
            #expect(LogHighlight.lineRole("warning: unused variable 'x'") == .warning)
            #expect(LogHighlight.lineRole("✓ builds the app") == .success)
            #expect(LogHighlight.lineRole("      Expected: 1") == .expected)
            #expect(LogHighlight.lineRole("      Received: 2") == .received)
            #expect(LogHighlight.lineRole("$ swift test") == .command)
            #expect(LogHighlight.lineRole("  counts a bundle once (12 ms)") == .plain)
            #expect(LogHighlight.lineRole("errorless handling") == .plain, "whole words only")
        }

        @Test func locationsAndStringsInsideALine() {
            let line = #"    at Object.<anonymous> (src/cart/badge.test.ts:41:27) "bundle""#
            let spans = LogHighlight.spans(line)
            #expect(spans.map(\.role) == [.location, .string])
            #expect(String(line[spans[0].range]) == "src/cart/badge.test.ts:41:27")
            #expect(String(line[spans[1].range]) == "\"bundle\"")
        }

        @Test func attributedTextKeepsTheWords() {
            let lines = ["FAIL a.ts", "  plain", "Expected: 1"]
            let text = LogHighlight.attributed(lines)
            #expect(String(text.characters) == lines.joined(separator: "\n"), "VoiceOver and copy get the plain text")
        }

        private func publish(_ sb: Sandbox, tag: String) throws {
            let release = ["tag_name": tag, "html_url": "https://github.com/antonijap/worktrees/releases/tag/\(tag)"]
            try JSONSerialization.data(withJSONObject: release).write(to: URL(fileURLWithPath: sb.manifest.gh).appendingPathComponent("release.json"))
        }

        @Test func checkForUpdatesNowSaysWhatItFound() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let store = Store(testingRoots: [])
            #expect(await store.checkForUpdateNow(current: "1.1.0") == .cantCheck("GitHub didn't answer. Try again in a moment."), "no release yet: 404")

            try publish(sb, tag: "v1.1.0")
            #expect(await store.checkForUpdateNow(current: "1.1.0") == .upToDate("1.1.0"))
            #expect(store.availableUpdate == nil)

            try publish(sb, tag: "v1.2.0")
            // Asked by hand: no once-a-day wait, and the setting being off doesn't stop it.
            sb.defaults.set(false, forKey: Prefs.Key.checkForUpdates)
            let answer = await store.checkForUpdateNow(current: "1.1.0")
            #expect(answer == .available(UpdateCheck.Release(version: "1.2.0", url: URL(string: "https://github.com/antonijap/worktrees/releases/tag/v1.2.0")!)))
            #expect(store.availableUpdate?.version == "1.2.0")

            try sb.signOut()
            if case .cantCheck(let reason) = await store.checkForUpdateNow(current: "1.1.0") {
                #expect(reason.contains("gh isn't signed in"))
            } else {
                Issue.record("signed out should say it can't check")
            }
            #expect(await store.checkForUpdateNow(current: nil) == .cantCheck("This build has no version number to compare."))
        }

        @Test func aboutNamesTheAuthor() {
            #expect(About.author == "Antonija Pek")
            #expect(About.site.absoluteString == "https://apek.me")
        }
    }
}
