import Foundation
import Testing
@testable import Worktrees

extension All {
    /// The `worktrees` command on the fixtures, and putting it on the PATH.
    @Suite @MainActor struct CLITests {
        private func run(_ sb: Sandbox, _ args: [String], github: Bool = true) async -> (code: Int32, out: String, err: String) {
            var output = CLI.Output()
            let code = await CLI.run(args + ["--root", sb.root.path] + (github ? [] : ["--no-github"]), out: &output)
            return (code, output.stdout, output.stderr)
        }

        private struct Report: Decodable {
            struct Item: Decodable {
                struct PR: Decodable { let number: Int; let checks: String; let state: String }
                let path: String
                let branch: String?
                let group: String
                let isMain: Bool
                let pullRequest: PR?
                let tidy: String?
                let createdBy: String?
            }
            let schema: Int
            let github: String
            let githubFailures: Int
            let worktrees: [Item]
        }

        private func decode(_ text: String) throws -> Report {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Report.self, from: Data(text.utf8))
        }

        @Test func runsAsCommandOnlyWhenCalledThatWay() {
            #expect(CLI.isInvocation(["/opt/homebrew/bin/worktrees"]))
            #expect(CLI.isInvocation(["/opt/homebrew/bin/worktrees", "list"]))
            #expect(CLI.isInvocation(["/Applications/Worktrees.app/Contents/MacOS/Worktrees", "list"]))
            #expect(!CLI.isInvocation(["/Applications/Worktrees.app/Contents/MacOS/Worktrees"]), "a normal launch opens the app")
            #expect(!CLI.isInvocation(["/Applications/Worktrees.app/Contents/MacOS/Worktrees", "-psn_0_12345"]))
            #expect(!CLI.isInvocation(["/Applications/Worktrees.app/Contents/MacOS/Worktrees", "--demo"]))
            #expect(CLI.isInvocation(["/Applications/Worktrees.app/Contents/MacOS/Worktrees", "--json", "list"]), "a flag before the command")
        }

        @Test func listJSONMatchesTheOverview() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let result = await run(sb, ["list", "--json"])
            #expect(result.code == 0)
            let report = try decode(result.out)
            #expect(report.schema == 1)
            #expect(report.github == "partial", "gamma's lookup fails on purpose")
            #expect(report.githubFailures == 1)
            // Every key is there, a missing value is null.
            #expect(result.out.contains("\"tidy\" : null"))
            #expect(result.out.contains("\"pullRequest\" : null"))
            // Linked worktrees only: the fixture main checkouts are clean.
            #expect(report.worktrees.count == 13)
            #expect(report.worktrees.allSatisfy { !$0.isMain })
            let byPath = Dictionary(uniqueKeysWithValues: report.worktrees.map { ($0.path, $0) })
            #expect(byPath[sb.path("failing")]?.group == "attention")
            #expect(byPath[sb.path("failing")]?.pullRequest?.checks == "failing")
            #expect(byPath[sb.path("merged")]?.tidy == "merged")
            #expect(byPath[sb.path("claude")]?.createdBy == "Claude Code")
            #expect(byPath[sb.path("fresh")]?.pullRequest == nil)
        }

        @Test func allIncludesMainCheckouts() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let report = try decode(await run(sb, ["list", "--all", "--json"]).out)
            #expect(report.worktrees.count == 18, "13 linked worktrees and 5 main checkouts")
        }

        @Test func attentionOnly() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let report = try decode(await run(sb, ["list", "--attention", "--json"]).out)
            #expect(Set(report.worktrees.map(\.path)) == [sb.path("failing"), sb.path("dirty"), sb.path("ahead")])
        }

        @Test func textListIsGroupedLikeTheApp() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let result = await run(sb, [])
            #expect(result.code == 0)
            #expect(result.out.contains("Needs attention (3)"))
            #expect(result.out.contains("Merged, safe to delete"))
            #expect(result.out.contains("13 worktrees in 5 repos, 1 GitHub lookup failed."))
        }

        @Test func withoutGitHubNothingIsLookedUp() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let result = await run(sb, ["list", "--json"], github: false)
            let report = try decode(result.out)
            #expect(report.github == "skipped")
            #expect(report.worktrees.allSatisfy { $0.pullRequest == nil && $0.tidy == nil })
            #expect(sb.askedBranches().isEmpty)
        }

        @Test func showFindsByBranchFolderOrPath() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            for query in ["feat/failing", "failing", sb.path("failing")] {
                let result = await run(sb, ["show", query, "--json"])
                #expect(result.code == 0, "\(query)")
                let report = try JSONDecoder().decode([String: AnyDecodable].self, from: Data(result.out.utf8))
                #expect(report["schema"] != nil)
                #expect(report["worktree"] != nil, "one worktree, under a singular key")
            }
            let text = await run(sb, ["show", "feat/failing"])
            #expect(text.out.contains("Checks failing"))
            #expect(text.out.contains("#3"))
            let missing = await run(sb, ["show", "no-such-thing"])
            #expect(missing.code == 1)
        }

        @Test func tidyListsWhatTheSheetWouldOffer() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let result = await run(sb, ["tidy", "--json"])
            let report = try decode(result.out)
            #expect(Set(report.worktrees.map(\.path)) == Set(["merged", "closed", "release", "claude", "beta-merged", "stale", "codex"].map { sb.path($0) }))
            let text = await run(sb, ["tidy"])
            #expect(text.out.contains("7 can go."))
            #expect(text.out.contains("changes nothing"))
        }

        @Test func wrongUsageSaysSo() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            #expect(await run(sb, ["frobnicate"]).code == 2)
            #expect(await run(sb, ["list", "extra"]).code == 2)
            #expect(await run(sb, ["show"]).code == 2)
            #expect(await run(sb, ["list", "--repo", "nope"]).code == 1)
            var out = CLI.Output()
            #expect(await CLI.run(["list", "--root"], out: &out) == 2)
            #expect(await run(sb, ["list", "--repo", "beta", "--json"]).code == 0)
            // A flag's value is never read as a flag: this asks for a repo named --json.
            #expect(await run(sb, ["--repo", "--json", "list"]).code == 1)
            #expect(await run(sb, ["folders", "--repo", "beta"]).code == 2, "--repo means nothing for folders")
            #expect(await run(sb, ["version", "extra"]).code == 2)
            #expect(await run(sb, ["help", "x"]).code == 2)
        }

        @Test func failedLookupIsNeverCalledStale() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            try sb.setPullRequests("fixture/alpha", ["fail": []])
            try JSONSerialization.data(withJSONObject: ["fail": true]).write(to: URL(fileURLWithPath: sb.manifest.gh + "/fixture/alpha.json"))
            let report = try decode(await run(sb, ["tidy", "--json"]).out)
            let paths = Set(report.worktrees.map(\.path))
            #expect(!paths.contains(sb.path("stale")), "its PR is unknown, so it can't be judged stale")
            #expect(paths == [sb.path("beta-merged")])
        }

        @Test func foldersJSONHasTheSameEnvelope() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let out = await run(sb, ["folders", "--json"]).out
            let report = try JSONDecoder().decode([String: AnyDecodable].self, from: Data(out.utf8))
            #expect(report["schema"] != nil)
            #expect(report["folders"] != nil)
        }

        @Test func helpAndFolders() async throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let help = await run(sb, ["help"])
            #expect(help.out.contains("worktrees list --attention"))
            let folders = await run(sb, ["folders"])
            #expect(folders.out.contains("5 repos"))
        }

        @Test func readOnlyScanLeavesGitsIndexAlone() async throws {
            let sb = try Sandbox()
            defer {
                Scanner.readOnly = false
                sb.close()
            }
            // An uncommitted file makes git status want to refresh the index.
            let wt = sb.path("fresh")
            try Data("x".utf8).write(to: URL(fileURLWithPath: wt + "/fresh.txt"))
            let index = try #require(await sb.git(["rev-parse", "--git-path", "index"], in: wt).out.trimmingCharacters(in: .whitespacesAndNewlines))
            let indexPath = index.hasPrefix("/") ? index : wt + "/" + index
            let before = try FileManager.default.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date
            try await Task.sleep(for: .milliseconds(1100))
            Scanner.readOnly = true
            _ = await run(sb, ["list", "--json"], github: false)
            let after = try FileManager.default.attributesOfItem(atPath: indexPath)[.modificationDate] as? Date
            #expect(before == after)
        }

        // MARK: Installing

        private func fakeApp(in dir: URL) throws -> String {
            let exe = dir.appendingPathComponent("Worktrees.app/Contents/MacOS/Worktrees")
            try FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: exe)
            return exe.resolvingSymlinksInPath().path
        }

        @Test func installsIntoTheFirstWritableFolder() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let a = sb.dir.appendingPathComponent("binA").path, b = sb.dir.appendingPathComponent("binB").path
            for d in [a, b] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
            let exe = try fakeApp(in: sb.dir.appendingPathComponent("apps"))
            #expect(CommandLineTool.status(in: [a, b], executable: exe, caskrooms: []) == .notInstalled)
            #expect(CommandLineTool.install(folders: [a, b], executable: exe, allowPassword: false, caskrooms: []) == nil)
            #expect(CommandLineTool.status(in: [a, b], executable: exe, caskrooms: []) == .installed(path: a + "/worktrees"))
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: a + "/worktrees") == exe)
            #expect(CommandLineTool.uninstall(folders: [a, b], allowPassword: false, caskrooms: []) == nil)
            #expect(CommandLineTool.status(in: [a, b], executable: exe, caskrooms: []) == .notInstalled)
        }

        @Test func neverTouchesSomeoneElsesWorktrees() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let a = sb.dir.appendingPathComponent("binA").path, b = sb.dir.appendingPathComponent("binB").path
            for d in [a, b] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
            try Data("#!/bin/sh\necho other\n".utf8).write(to: URL(fileURLWithPath: a + "/worktrees"))
            let exe = try fakeApp(in: sb.dir.appendingPathComponent("apps"))
            #expect(CommandLineTool.status(in: [a, b], executable: exe, caskrooms: []) == .taken(path: a + "/worktrees"))
            // A link further down the PATH would never run, so it refuses and says why.
            #expect(CommandLineTool.install(folders: [a, b], executable: exe, allowPassword: false, caskrooms: [])?.contains("another tool") == true)
            #expect(!FileManager.default.fileExists(atPath: b + "/worktrees"))
            #expect(CommandLineTool.uninstall(folders: [a, b], allowPassword: false, caskrooms: []) == nil)
            #expect(FileManager.default.fileExists(atPath: a + "/worktrees"), "the other one is still there")
            #expect(try String(contentsOfFile: a + "/worktrees", encoding: .utf8).contains("other"))
        }

        @Test func homebrewsLinkIsLeftToHomebrew() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let a = sb.dir.appendingPathComponent("binA").path
            let cask = sb.dir.appendingPathComponent("Caskroom/worktrees").path
            for d in [a, cask] { try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true) }
            let exe = try fakeApp(in: sb.dir.appendingPathComponent("apps"))
            try FileManager.default.createSymbolicLink(atPath: a + "/worktrees", withDestinationPath: exe)
            #expect(CommandLineTool.status(in: [a], executable: exe, caskrooms: [cask]) == .homebrew(path: a + "/worktrees"))
            #expect(CommandLineTool.uninstall(folders: [a], allowPassword: false, caskrooms: [cask])?.contains("brew uninstall") == true)
            #expect(FileManager.default.fileExists(atPath: a + "/worktrees"), "Homebrew's link stays")
        }

        @Test func movedAppIsPointedAtAgain() throws {
            let sb = try Sandbox()
            defer { sb.close() }
            let a = sb.dir.appendingPathComponent("binA").path
            try FileManager.default.createDirectory(atPath: a, withIntermediateDirectories: true)
            let old = try fakeApp(in: sb.dir.appendingPathComponent("old"))
            let new = try fakeApp(in: sb.dir.appendingPathComponent("new"))
            #expect(CommandLineTool.install(folders: [a], executable: old, allowPassword: false, caskrooms: []) == nil)
            #expect(CommandLineTool.status(in: [a], executable: new, caskrooms: []) == .elsewhere(path: a + "/worktrees", target: old))
            #expect(CommandLineTool.install(folders: [a], executable: new, allowPassword: false, caskrooms: []) == nil)
            #expect(CommandLineTool.status(in: [a], executable: new, caskrooms: []) == .installed(path: a + "/worktrees"))
        }
    }
}

/// Decodes any JSON value, for checking a report has a key.
private struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if (try? container.decode([String: AnyDecodable].self)) != nil { return }
        if (try? container.decode([AnyDecodable].self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(Bool.self)) != nil { return }
        _ = container.decodeNil()
    }
}
