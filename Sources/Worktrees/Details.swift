import Foundation

struct FileChange: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    /// nil for binary files.
    let added: Int?
    let removed: Int?
    /// Where a renamed file came from.
    var oldPath: String? = nil

    var fileName: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

struct UncommittedFile: Identifiable, Hashable, Sendable {
    var id: String { path }
    let code: String
    let path: String

    var label: String {
        switch code.trimmingCharacters(in: .whitespaces) {
        case "??": "New"
        case let c where c.contains("D"): "Deleted"
        case let c where c.contains("A"): "Added"
        case let c where c.contains("R"): "Renamed"
        case let c where c.contains("U"): "Conflict"
        default: "Modified"
        }
    }
}

/// What the detail pane shows for one worktree. Loaded on selection, not during the scan.
struct WorktreeDetails: Sendable {
    let base: String?
    let changes: [FileChange]
    let commits: [Commit]
    let uncommitted: [UncommittedFile]
    /// Paths among `changes` and `uncommitted` that exist on disk.
    var existing: Set<String> = []

    var added: Int { changes.compactMap(\.added).reduce(0, +) }
    var removed: Int { changes.compactMap(\.removed).reduce(0, +) }
}

enum DetailsLoader {
    static func load(_ wt: Worktree) async -> WorktreeDetails {
        if DemoData.isOn { return DemoData.details(for: wt) }
        let path = wt.path
        let base = await baseBranch(path)


        var changes: [FileChange] = []
        var commits: [Commit] = []
        let format = "--format=%h%x1f%s%x1f%cr%x1f%ct"

        if let base, !wt.isMain {
            async let diff = Shell.run("git", ["-C", path, "-c", "core.quotePath=false", "diff", "--numstat", "--no-ext-diff", "--no-textconv", "\(base)...HEAD"])
            async let log = Shell.run("git", ["-C", path, "log", "-200", "--no-show-signature", format, "\(base)..HEAD"])
            changes = parseNumstat(await diff.out)
            commits = parseLog(await log.out)
        } else {
            commits = parseLog(await Shell.run("git", ["-C", path, "log", "-50", "--no-show-signature", format]).out)
        }

        return WorktreeDetails(
            base: base,
            changes: changes,
            commits: commits,
            // The scan's status already lists these; no second status run per selection.
            uncommitted: wt.status?.files ?? [],
            existing: existing(in: path, changes: changes, uncommitted: wt.status?.files ?? [])
        )
    }

    /// Which listed files are on disk right now, so rows know whether they can open in the editor
    /// without a stat per render.
    private static func existing(in path: String, changes: [FileChange], uncommitted: [UncommittedFile]) -> Set<String> {
        let fm = FileManager.default
        let all = Set(changes.map(\.path) + uncommitted.map(\.path))
        return all.filter { fm.fileExists(atPath: path + "/" + $0) }
    }

    /// Git-ignored files that aren't build output, e.g. .env.local. Deleting the worktree removes
    /// them, so the delete dialog asks for this list; nothing else does, since listing ignored
    /// files walks the whole tree.
    static func ignored(_ wt: Worktree) async -> [String] {
        if DemoData.isOn { return wt.isMain ? [] : [".env.local"] }
        let result = await Shell.run("git", ["-C", wt.path, "-c", "core.quotePath=false", "ls-files", "-o", "-i",
                                             "--exclude-standard", "--directory", "-z"], limited: false)
        return result.ok ? parseIgnored(result.out) : []
    }

    /// origin's default branch, e.g. "origin/main".
    private static func baseBranch(_ path: String) async -> String? {
        let head = await Shell.run("git", ["-C", path, "rev-parse", "--abbrev-ref", "origin/HEAD"])
        let name = head.out.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.ok, !name.isEmpty, name != "origin/HEAD" { return name }
        for candidate in ["origin/main", "origin/master", "origin/develop"] {
            if await Shell.run("git", ["-C", path, "rev-parse", "--verify", "--quiet", candidate]).ok {
                return candidate
            }
        }
        return nil
    }

    /// One line per file: "added\tremoved\tpath", with "-" for binary files. core.quotePath=false
    /// keeps non-ASCII paths literal. A rename reads "old => new" or "dir/{old => new}/file"; the
    /// new name is what matters here.
    static func parseNumstat(_ text: String) -> [FileChange] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            let (new, old) = renamedPath(String(fields[2]))
            return FileChange(path: new, added: Int(fields[0]), removed: Int(fields[1]), oldPath: old)
        }
    }

    /// (new path, old path) for a rename, (path, nil) otherwise.
    private static func renamedPath(_ path: String) -> (String, String?) {
        guard path.contains(" => ") else { return (path, nil) }
        if let open = path.range(of: "{"), let close = path.range(of: "}", range: open.upperBound..<path.endIndex),
           let arrow = path.range(of: " => ", range: open.upperBound..<close.lowerBound) {
            let head = path[..<open.lowerBound], tail = path[close.upperBound...]
            let new = (head + path[arrow.upperBound..<close.lowerBound] + tail).replacingOccurrences(of: "//", with: "/")
            let old = (head + path[open.upperBound..<arrow.lowerBound] + tail).replacingOccurrences(of: "//", with: "/")
            return (new, old)
        }
        let parts = path.components(separatedBy: " => ")
        return (parts.last ?? path, parts.count > 1 ? parts.first : nil)
    }

    /// One record per line, fields separated by the unit separator the format asks for.
    static func parseLog(_ text: String) -> [Commit] {
        text.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\u{1f}")
            guard f.count == 4 else { return nil }
            return Commit(hash: f[0], subject: f[1].sanitizedForDisplay, relative: f[2], date: Date(timeIntervalSince1970: TimeInterval(f[3]) ?? 0))
        }
    }

    /// Folders that are rebuilt or reinstalled anyway, so losing them is fine.
    private static let regenerable: Set<String> = [
        "node_modules", ".build", "build", "dist", "out", "DerivedData", "Pods", ".next", ".expo", ".turbo",
        ".cache", "coverage", "target", ".gradle", "vendor", ".venv", "venv", "__pycache__", ".swiftpm", ".DS_Store",
        ".idea", ".vscode", "xcuserdata",
    ]

    private static func parseIgnored(_ text: String) -> [String] {
        // -z output: one NUL-terminated path per entry, folders with a trailing slash.
        text.split(separator: "\0").compactMap { line in
            let path = line.hasSuffix("/") ? String(line.dropLast()) : String(line)
            guard !path.isEmpty else { return nil }
            let parts = path.split(separator: "/").map(String.init)
            if parts.contains(where: regenerable.contains) || path.hasSuffix(".log") { return nil }
            return path
        }
    }

}
