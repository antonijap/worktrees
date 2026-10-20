import Foundation

/// One file's changes, as the diff panel under its row shows them.
struct FileDiff: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        enum Kind: Sendable { case context, added, removed }
        let id: Int
        let kind: Kind
        let oldNumber: Int?
        let newNumber: Int?
        let text: String
    }

    struct Hunk: Equatable, Sendable, Identifiable {
        let id: Int
        /// The function or block the hunk sits in, from the @@ line, often empty.
        let context: String
        let oldStart: Int
        let newStart: Int
        let lines: [Line]
    }

    enum Body: Equatable, Sendable {
        case text([Hunk])
        case binary
        case tooLarge
        /// Nothing to show: an empty file, or a change git has no lines for (mode only).
        case empty
        /// An untracked folder: git lists it as one entry.
        case folder
        /// An untracked symlink, pointing at the path given. Its target is never read.
        case symlink(String)
        /// git couldn't produce the diff.
        case failed
    }

    let body: Body
    /// Set for a rename, "old path".
    var renamedFrom: String?
    /// Each read of a file is its own version, so cached colouring never outlives the text.
    var version = UUID()

    /// The hunks a panel shows for a budget of rows: each @@ row and each line costs one,
    /// and the hunk the budget runs out in is cut short.
    static func page(_ hunks: [Hunk], budget: Int) -> [Hunk] {
        var budget = budget
        return hunks.compactMap { hunk in
            guard budget > 0 else { return nil }
            budget -= 1
            let take = min(hunk.lines.count, budget)
            budget -= take
            return take == hunk.lines.count ? hunk : Hunk(id: hunk.id, context: hunk.context, oldStart: hunk.oldStart, newStart: hunk.newStart, lines: Array(hunk.lines.prefix(take)))
        }
    }

    var lineCount: Int {
        if case .text(let hunks) = body { return hunks.reduce(0) { $0 + $1.lines.count } }
        return 0
    }
}

enum DiffLoader {
    /// Files bigger than this are not read whole as "all added".
    static let untrackedLimit = 400_000

    /// What a row's diff is of.
    enum Scope: Hashable, Sendable {
        /// Committed on the branch, against the merge base.
        case sinceBase(String)
        /// Staged and unstaged against HEAD.
        case uncommitted
        /// A file git doesn't know yet: all of it is new.
        case untracked
    }

    static func load(worktree path: String, file: String, oldPath: String? = nil, scope: Scope) async -> FileDiff {
        if DemoData.isOn { return DemoData.diff(for: file, scope: scope) }
        switch scope {
        case .untracked:
            return untrackedFile(at: path + "/" + file)
        case .sinceBase(let base):
            // Literal pathspecs: a name like [id].tsx must not act as a glob.
            var args = ["-C", path, "--literal-pathspecs", "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff",
                        "--no-textconv", "--find-renames", "\(base)...HEAD", "--", file]
            if let oldPath { args.append(oldPath) }
            let result = await Shell.run("git", args, limited: false)
            return result.ok ? parse(result.out) : FileDiff(body: .failed)
        case .uncommitted:
            let result = await Shell.run("git", ["-C", path, "--literal-pathspecs", "-c", "core.quotePath=false", "diff", "--no-color",
                                                 "--no-ext-diff", "--no-textconv", "HEAD", "--", file], limited: false)
            return result.ok ? parse(result.out) : FileDiff(body: .failed)
        }
    }

    private static func untrackedFile(at path: String) -> FileDiff {
        // Looked at before it is read: a link is never followed, a folder or a pipe never opened,
        // a huge file never loaded.
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path), let type = attrs[.type] as? FileAttributeType else {
            return FileDiff(body: .failed)
        }
        switch type {
        case .typeSymbolicLink:
            return FileDiff(body: .symlink((try? fm.destinationOfSymbolicLink(atPath: path))?.sanitizedForDisplay ?? "?"))
        case .typeDirectory: return FileDiff(body: .folder)
        case .typeRegular: break
        default: return FileDiff(body: .failed)
        }
        if let size = attrs[.size] as? Int, size > untrackedLimit { return FileDiff(body: .tooLarge) }
        guard let data = fm.contents(atPath: path) else { return FileDiff(body: .failed) }
        if data.count > untrackedLimit { return FileDiff(body: .tooLarge) }
        if data.prefix(8000).contains(0) { return FileDiff(body: .binary) }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return FileDiff(body: .binary) }
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return FileDiff(body: .empty) }
        let added = lines.enumerated().map { i, line in
            FileDiff.Line(id: i, kind: .added, oldNumber: nil, newNumber: i + 1, text: line.sanitizedForDisplay)
        }
        return FileDiff(body: .text([FileDiff.Hunk(id: 0, context: "", oldStart: 0, newStart: 1, lines: added)]))
    }

    /// Unified diff from git, one file. Headers are skipped, hunks and their lines kept with
    /// old and new line numbers worked out from the @@ ranges.
    static func parse(_ text: String) -> FileDiff {
        var hunks: [FileDiff.Hunk] = []
        var renamedFrom: String?
        var binary = false
        var current: (context: String, oldStart: Int, newStart: Int, lines: [FileDiff.Line])?
        var old = 0, new = 0, lineID = 0

        func close() {
            if let c = current { hunks.append(FileDiff.Hunk(id: hunks.count, context: c.context, oldStart: c.oldStart, newStart: c.newStart, lines: c.lines)) }
            current = nil
        }

        // Newlines of either kind, and the empty piece after git's final newline is not a line.
        var pieces = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if pieces.last == "" { pieces.removeLast() }
        for raw in pieces {
            let line = String(raw)
            if line.hasPrefix("@@") {
                close()
                // "@@ -12,7 +12,9 @@ func name()"
                let parts = line.split(separator: "@@", maxSplits: 2, omittingEmptySubsequences: false)
                let ranges = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                let context = parts.count > 2 ? parts[2].trimmingCharacters(in: .whitespaces) : ""
                let numbers = ranges.split(separator: " ")
                func start(_ s: Substring) -> Int { Int(s.dropFirst().split(separator: ",").first ?? "0") ?? 0 }
                old = numbers.count > 0 ? start(numbers[0]) : 0
                new = numbers.count > 1 ? start(numbers[1]) : 0
                current = (context.sanitizedForDisplay, old, new, [])
                continue
            }
            guard current != nil else {
                if line.hasPrefix("rename from ") { renamedFrom = String(line.dropFirst(12)).sanitizedForDisplay }
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { binary = true }
                continue
            }
            if line.hasPrefix("\\") { continue }  // "\ No newline at end of file"
            let kind: FileDiff.Line.Kind
            switch line.first {
            case "+": kind = .added
            case "-": kind = .removed
            case " ", nil: kind = .context
            default:
                // A new file header mid-stream (several files in one diff) ends the hunk.
                close()
                if line.hasPrefix("Binary files ") { binary = true }
                continue
            }
            let body = String(line.dropFirst()).sanitizedForDisplay
            let entry: FileDiff.Line
            switch kind {
            case .added: entry = FileDiff.Line(id: lineID, kind: .added, oldNumber: nil, newNumber: new, text: body); new += 1
            case .removed: entry = FileDiff.Line(id: lineID, kind: .removed, oldNumber: old, newNumber: nil, text: body); old += 1
            case .context: entry = FileDiff.Line(id: lineID, kind: .context, oldNumber: old, newNumber: new, text: body); old += 1; new += 1
            }
            lineID += 1
            current?.lines.append(entry)
        }
        close()
        if binary { return FileDiff(body: .binary, renamedFrom: renamedFrom) }
        return FileDiff(body: hunks.isEmpty ? .empty : .text(hunks), renamedFrom: renamedFrom)
    }
}
