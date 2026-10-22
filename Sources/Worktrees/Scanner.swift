import Foundation

enum Scanner {
    /// The command line tool writes nothing, not even git's index cache.
    nonisolated(unsafe) static var readOnly = false

    /// Walks `root` and returns the main checkout path of every repository found.
    /// A linked worktree (where `.git` is a file) resolves to its main repository,
    /// so each repository shows up once and `git worktree list` fills in the rest.
    static func findRepos(root: URL, maxDepth: Int = Prefs.scanDepth, skipping skippedFolders: Set<String> = Prefs.skippedFolders,
                          home: URL = FolderFinder.home) -> [String] {
        var found = Set<String>()
        let fm = FileManager.default
        // The home folder is recognised by its file identity, not its path, so ~ reached as
        // /Users/<me>, through a symlink or a firmlinked path is still home.
        func identity(_ url: URL) -> String? {
            (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier.map { "\($0)" }
        }
        let homeID = identity(home)

        func walk(_ url: URL, depth: Int, isHome: Bool) {
            let gitURL = url.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: gitURL.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    found.insert(url.standardizedFileURL.path)
                } else if let main = mainRepo(forGitFile: gitURL) {
                    found.insert(main)
                }
                return
            }
            guard depth < maxDepth else { return }

            let children = (try? fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            // Straight under the home folder, the folders macOS guards with a permission prompt
            // are left alone, so adding ~ (or /Users) doesn't set off a string of prompts.
            let guarded = isHome ? FolderFinder.protected : []
            for child in children where !skippedFolders.contains(child.lastPathComponent) && !guarded.contains(child.lastPathComponent) {
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                let childIsHome = homeID != nil && values?.fileResourceIdentifier.map { "\($0)" } == homeID
                walk(child, depth: depth + 1, isHome: childIsHome)
            }
        }

        walk(root, depth: 0, isHome: homeID != nil && identity(root) == homeID)
        return found.sorted()
    }

    /// Reads a `.git` file (`gitdir: …/.git/worktrees/<name>`) and returns the main checkout.
    /// Submodules also use a `.git` file; those are skipped.
    private static func mainRepo(forGitFile file: URL) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw)
            : file.deletingLastPathComponent().appendingPathComponent(raw)
        let parts = gitDir.standardizedFileURL.pathComponents
        guard let idx = parts.lastIndex(of: "worktrees"), idx > 0 else { return nil }
        let common = URL(fileURLWithPath: NSString.path(withComponents: Array(parts[..<idx])))
        let main = common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common
        return FileManager.default.fileExists(atPath: main.path) ? main.standardizedFileURL.path : nil
    }

    static func loadRepo(path: String, root: URL) async -> Repo? {
        async let worktreeOutput = Shell.run("git", ["-C", path, "worktree", "list", "--porcelain", "-z"])
        async let remoteOutput = Shell.run("git", ["-C", path, "remote", "-v"])

        let listing = await worktreeOutput
        guard listing.ok else { return nil }
        var worktrees = parseWorktrees(listing.out)

        await withTaskGroup(of: (Int, LocalStatus?, Commit?).self) { group in
            for (index, wt) in worktrees.enumerated() where !wt.isPrunable {
                group.addTask {
                    async let status = loadStatus(wt.path)
                    async let commit = loadLastCommit(wt.path)
                    return (index, await status, await commit)
                }
            }
            for await (index, status, commit) in group {
                worktrees[index].status = status
                worktrees[index].lastCommit = commit
            }
        }

        let url = URL(fileURLWithPath: path)
        return Repo(
            path: path,
            name: url.lastPathComponent,
            group: groupName(for: url, root: root),
            remotes: parseRemotes(await remoteOutput.out),
            worktrees: worktrees
        )
    }

    /// The folder between the root and the repo, e.g. "work" for ~/Code/work/storefront.
    private static func groupName(for url: URL, root: URL) -> String {
        let rootParts = root.standardizedFileURL.pathComponents
        let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents
        guard parts.starts(with: rootParts) else { return url.deletingLastPathComponent().path.abbreviatingHome }
        let rest = parts.dropFirst(rootParts.count)
        return rest.isEmpty ? root.lastPathComponent : rest.joined(separator: "/")
    }

    /// -z output: every line ends in NUL and an empty line closes a block, so paths can hold anything.
    static func parseWorktrees(_ text: String) -> [Worktree] {
        var result: [Worktree] = []
        for (index, block) in text.components(separatedBy: "\0\0").enumerated() {
            var path: String?
            var head = ""
            var branch: String?
            var locked = false
            var prunable = false
            var bare = false
            for line in block.split(separator: "\0") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                else if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
                else if line.hasPrefix("branch ") {
                    branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "").sanitizedForDisplay
                }
                else if line == "locked" || line.hasPrefix("locked ") { locked = true }
                else if line == "prunable" || line.hasPrefix("prunable ") { prunable = true }
                else if line == "bare" { bare = true }
            }
            guard let path, !bare else { continue }
            result.append(Worktree(
                path: path,
                head: head,
                branch: branch,
                // The first entry is the main checkout, or the bare repo that was skipped above.
                isMain: index == 0,
                isLocked: locked,
                isPrunable: prunable
            ))
        }
        return result
    }

    static func parseRemotes(_ text: String) -> [Remote] {
        var seen = Set<String>()
        var remotes: [Remote] = []
        for line in text.split(separator: "\n") where line.contains("(fetch)") {
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, seen.insert(String(fields[0])).inserted else { continue }
            remotes.append(Remote(name: String(fields[0]), url: String(fields[1])))
        }
        return remotes
    }

    private static func loadStatus(_ path: String) async -> LocalStatus? {
        // Submodule contents are not this worktree's business, and the untracked cache saves
        // the directory walk on repos that have one.
        let result = await Shell.run("git", ["-C", path, "-c", "core.untrackedCache=true", "-c", "core.quotePath=false",
                                             "status", "--porcelain=v2", "--branch", "--ignore-submodules=dirty", "-z"],
                                     refreshIndex: !readOnly)
        guard result.ok else { return nil }
        return parseStatus(result.out)
    }

    /// Porcelain v2 with -z: NUL-terminated entries; a rename ("2 ...") is followed by the old
    /// path as an entry of its own. Each changed file is kept with its two-letter XY code.
    static func parseStatus(_ text: String) -> LocalStatus {
        var status = LocalStatus()
        var skipNext = false
        for line in text.split(separator: "\0") {
            if skipNext { skipNext = false; continue }
            if line.hasPrefix("# branch.upstream ") {
                status.upstream = String(line.dropFirst(18))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                if parts.count == 2 {
                    status.aheadKnown = true
                    status.ahead = Int(parts[0].dropFirst()) ?? 0
                    status.behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                status.changed += 1
                // "1 XY sub mH mI mW hH hI path", "2 XY sub mH mI mW hH hI Xscore path"
                let fields = line.split(separator: " ", maxSplits: line.hasPrefix("1 ") ? 8 : 9, omittingEmptySubsequences: false)
                if let path = fields.last, fields.count >= 9 {
                    // v2 writes "." for an untouched side; the rows use the v1 space.
                    status.files.append(UncommittedFile(code: fields[1].replacingOccurrences(of: ".", with: " "), path: String(path)))
                }
                if line.hasPrefix("2 ") { skipNext = true }
            } else if line.hasPrefix("u ") {
                status.conflicted += 1
                // "u XY sub m1 m2 m3 mW h1 h2 h3 path"
                let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if let path = fields.last, fields.count == 11 {
                    status.files.append(UncommittedFile(code: fields[1].replacingOccurrences(of: ".", with: " "), path: String(path)))
                }
            } else if line.hasPrefix("? ") {
                status.untracked += 1
                status.files.append(UncommittedFile(code: "??", path: String(line.dropFirst(2))))
            }
        }
        return status
    }

    private static func loadLastCommit(_ path: String) async -> Commit? {
        let result = await Shell.run("git", ["-C", path, "log", "-1", "--no-show-signature", "--format=%h%x1f%s%x1f%cr%x1f%ct"])
        let fields = result.out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\u{1f}")
        guard result.ok, fields.count == 4 else { return nil }
        return Commit(
            hash: fields[0],
            subject: fields[1].sanitizedForDisplay,
            relative: fields[2],
            date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0)
        )
    }
}
