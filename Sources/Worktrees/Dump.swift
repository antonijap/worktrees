import Foundation

/// `Worktrees --dump [folder]` prints the scan as text and exits. Handy for checking the scanner without the UI.
enum Dump {
    static func runAndExit() -> Never {
        let args = CommandLine.arguments
        // `--dump --sounds <dir>` writes every UI sound as a WAV, for listening without the app.
        if let i = args.firstIndex(of: "--sounds"), args.indices.contains(i + 1) {
            for sound in UISound.allCases {
                let url = URL(fileURLWithPath: args[i + 1]).appendingPathComponent("\(sound).wav")
                try? sound.wav().write(to: url)
                print(url.path)
            }
            exit(0)
        }
        // `--dump --sanitize <text>` prints the text as the UI would show it, with its scalars.
        if let i = args.firstIndex(of: "--sanitize"), args.indices.contains(i + 1) {
            let clean = args[i + 1].sanitizedForDisplay
            print(clean.unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))
            exit(0)
        }
        // `--dump --verify <worktree> <repo>` prints whether Delete would accept the folder.
        if let i = args.firstIndex(of: "--verify"), args.indices.contains(i + 2) {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let listing = await Shell.run("git", ["-C", args[i + 2], "worktree", "list", "--porcelain", "-z"])
                let others = Scanner.parseWorktrees(listing.out).map(\.path).filter { $0 != args[i + 1] }
                print(WorktreeCheck.problem(deleting: args[i + 1], repoPath: args[i + 2], roots: [NSHomeDirectory() + "/Code"], others: others) ?? "ok")
                done.signal()
            }
            done.wait()
            exit(0)
        }
        // `--dump --details <worktree>` prints the detail column's data for one worktree.
        if let i = args.firstIndex(of: "--details"), args.indices.contains(i + 1) {
            let wt = Worktree(path: args[i + 1], head: "", branch: nil, isMain: false, isLocked: false, isPrunable: false)
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                let d = await DetailsLoader.load(wt)
                print("base: \(d.base ?? "none")")
                for c in d.changes { print("change: +\(c.added.map(String.init) ?? "-") -\(c.removed.map(String.init) ?? "-") \(c.path)") }
                for c in d.commits { print("commit: \(c.hash) \(c.subject)") }
                for u in d.uncommitted { print("uncommitted: \(u.code) \(u.path)") }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        let folder = args.firstIndex(of: "--dump").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let root = URL(fileURLWithPath: folder ?? NSHomeDirectory() + "/Code")
        let done = DispatchSemaphore(value: 0)

        Task.detached {
            let paths = Scanner.findRepos(root: root)
            for path in paths {
                guard var repo = await Scanner.loadRepo(path: path, root: root) else {
                    print("! could not read \(path)")
                    continue
                }
                if let slug = repo.githubRemote?.githubSlug, CommandLine.arguments.contains("--github") {
                    let branches = repo.worktrees.compactMap(\.remoteBranch).filter { !Prefs.protectedBranches.contains($0) }
                    let lookups = await GitHub.pullRequests(slug: slug, branches: Array(Set(branches)))
                    for i in repo.worktrees.indices {
                        if let branch = repo.worktrees[i].remoteBranch, case .found(let pr)? = lookups[branch] {
                            repo.worktrees[i].pullRequest = pr
                        }
                    }
                }
                print("\(repo.group)/\(repo.name)  [\(repo.githubRemote?.githubSlug ?? "no GitHub remote")]")
                for wt in repo.worktrees {
                    let s = wt.status
                    var line = "   \(wt.isMain ? "*" : "-") \(wt.displayBranch)  \(wt.path.abbreviatingHome)"
                    if let s { line += "  ~\(s.changed) ?\(s.untracked) ↑\(s.ahead) ↓\(s.behind)" }
                    if let pr = wt.pullRequest {
                        line += "  PR #\(pr.number) \(pr.state) checks:\(pr.checks) by:\(pr.author ?? "?") base:\(pr.baseRefName ?? "?")"
                        line += " reviews:\(pr.reviews.map { "\($0.name)=\($0.stateText)" }) labels:\(pr.labels) merge:\(pr.mergeStateStatus ?? "?")"
                    }
                    if let reason = TidyCandidate.reason(for: wt) { line += "  tidy:\(reason)" }
                    if let creator = wt.creator { line += "  by:\(creator.slug)" }
                    print(line)
                    // `--dump --files` also lists each worktree's uncommitted files.
                    if args.contains("--files") { for f in wt.status?.files ?? [] { print("       \(f.code) \(f.path)") } }
                }
            }
            print("\(paths.count) repos")
            done.signal()
        }
        done.wait()
        exit(0)
    }
}
