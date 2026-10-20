import CoreServices
import Foundation

/// Watches each repo's `.git` folder with FSEvents and reports the repo path after 1s of quiet.
/// Only git's own bookkeeping counts: HEAD, refs and the worktrees folder. Edits to files in
/// the working tree are not watched, they'd fire on every keystroke.
@MainActor
final class RepoWatcher {
    /// What a stream's callback gets: which repo it is for, and a weak way back.
    private final class StreamContext {
        weak var watcher: RepoWatcher?
        let repoPath: String
        init(watcher: RepoWatcher, repoPath: String) { self.watcher = watcher; self.repoPath = repoPath }
    }

    private var streams: [String: (stream: FSEventStreamRef, context: StreamContext)] = [:]
    private var pending: [String: Task<Void, Never>] = [:]
    private let onChange: (String) -> Void
    private let queue = DispatchQueue(label: "me.apek.worktrees.fsevents", qos: .utility)

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
    }

    /// Starts watching new repos and stops watching ones that went away.
    func watch(repoPaths: [String]) {
        let wanted = Set(repoPaths)
        for path in Array(streams.keys) where !wanted.contains(path) { stop(path) }
        for path in wanted where streams[path] == nil { start(path) }
    }

    private func start(_ repoPath: String) {
        let gitDir = repoPath + "/.git"
        guard FileManager.default.fileExists(atPath: gitDir) else { return }
        let box = StreamContext(watcher: self, repoPath: repoPath)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, flags, _ in
            guard let info, let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let box = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
            // The .git folder itself moved or vanished: treat it like any other change.
            let rootChanged = (0..<count).contains { flags[$0] & UInt32(kFSEventStreamEventFlagRootChanged) != 0 }
            guard rootChanged || paths.prefix(count).contains(where: RepoWatcher.matters) else { return }
            let repoPath = box.repoPath
            Task { @MainActor in box.watcher?.schedule(repoPath) }
        }
        guard let stream = FSEventStreamCreate(
            nil, callback, &context, [gitDir] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        streams[repoPath] = (stream, box)
    }

    private func stop(_ repoPath: String) {
        guard let (stream, _) = streams.removeValue(forKey: repoPath) else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        pending[repoPath]?.cancel()
        pending[repoPath] = nil
    }

    /// Git bookkeeping that changes what the app shows: checkouts, commits, fetches, and
    /// worktrees being added or removed. Objects and logs are skipped. So is the index: the
    /// app's own `git status` rewrites it, which would make every refresh trigger the next.
    nonisolated static func matters(_ path: String) -> Bool {
        guard let range = path.range(of: "/.git/") else { return false }
        let inside = path[range.upperBound...]
        if inside.hasPrefix("objects/") || inside.hasPrefix("logs/") || inside.hasPrefix("lfs/") { return false }
        let name = (String(inside) as NSString).lastPathComponent
        if name.hasSuffix(".lock") { return false }
        if inside.hasPrefix("worktrees") {
            // A linked worktree's own index lives here too; only its HEAD, refs and lock matter,
            // plus the folder itself appearing or going.
            let parts = inside.split(separator: "/")
            if parts.count <= 2 { return true }
            if parts[2] == "refs" || parts[2] == "locked" { return true }
            return ["HEAD", "ORIG_HEAD", "MERGE_HEAD", "REBASE_HEAD"].contains(String(parts[2])) && parts.count == 3
        }
        if inside.hasPrefix("refs/") || inside == "packed-refs" { return true }
        return ["HEAD", "ORIG_HEAD", "FETCH_HEAD", "MERGE_HEAD", "REBASE_HEAD"].contains(name)
    }

    /// Waits for a second of quiet, then reports once. Git writes several files per operation.
    private func schedule(_ repoPath: String) {
        guard streams[repoPath] != nil else { return }
        pending[repoPath]?.cancel()
        pending[repoPath] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pending[repoPath] = nil
            self.onChange(repoPath)
        }
    }

    deinit {
        for (stream, _) in streams.values {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
