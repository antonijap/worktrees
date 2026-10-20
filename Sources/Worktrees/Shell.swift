import Foundation

/// Caps how many child processes run at once, so a big scan doesn't fork hundreds of gits.
actor Limiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum Shell {
    struct Result: Sendable {
        let status: Int32
        let out: String
        let err: String
        var ok: Bool { status == 0 }
    }

    // git and gh queue separately: a long scan must not hold up PR lookups, or the reverse.
    private static let gitLimiter = Limiter(4)
    private static let ghLimiter = Limiter(4)

    // Apps launched from Finder get a bare PATH, so add the Homebrew locations where git and gh live.
    private static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env["GIT_TERMINAL_PROMPT"] = "0"
        // Read-only calls skip the optional index lock, so they never get in the way of an
        // editor or a running git. The scan's status opts back in (refreshIndex) to keep
        // git's caches current.
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GH_PROMPT_DISABLED"] = "1"
        env["NO_COLOR"] = "1"
        return env
    }()

    /// `limited: false` skips the queue, for user actions that shouldn't wait behind a scan.
    /// `refreshIndex: true` lets git status write back its refreshed index and untracked cache
    /// (git's normal behaviour, skipped if someone else holds the lock); everything else runs
    /// without taking optional locks.
    static func run(_ tool: String, _ args: [String], in dir: String? = nil, limited: Bool = true,
                    refreshIndex: Bool = false) async -> Result {
        guard limited else {
            return await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    cont.resume(returning: runBlocking(tool, args, in: dir, refreshIndex: refreshIndex))
                }
            }
        }
        let limiter = tool == "gh" ? ghLimiter : gitLimiter
        await limiter.acquire()
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: runBlocking(tool, args, in: dir, refreshIndex: refreshIndex))
            }
        }
        await limiter.release()
        return result
    }

    /// Starts a program and returns at once: for handing paths to an editor's command line
    /// tool. Arguments go straight to the program, never through a shell. Its output is
    /// dropped, so a tool that leaves the app it starts holding our pipes can't block anything;
    /// a non-zero exit or a failure to start is passed to `onFailure`.
    static func launch(_ executable: String, _ args: [String], onFailure: @escaping @Sendable (String) -> Void) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            if finished.terminationStatus != 0 { onFailure("its command line tool stopped with code \(finished.terminationStatus)") }
        }
        do {
            try process.run()
        } catch {
            onFailure(error.localizedDescription)
        }
    }

    /// A scanned repo's own config can name programs to run (a filesystem monitor, a signature
    /// checker, an external diff, hooks, a pager). None of them are wanted here, so every git
    /// call switches them off ahead of whatever the repo says.
    private static let gitGuards = [
        "-c", "core.fsmonitor=false", "-c", "log.showSignature=false", "-c", "core.hooksPath=/dev/null",
        "-c", "diff.external=", "-c", "core.pager=cat",
    ]

    private static func runBlocking(_ tool: String, _ args: [String], in dir: String?, refreshIndex: Bool) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [tool] + (tool == "git" ? gitGuards : []) + args
        var env = environment
        if refreshIndex { env["GIT_OPTIONAL_LOCKS"] = "1" }
        process.environment = env
        if let dir { process.currentDirectoryURL = URL(fileURLWithPath: dir) }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return Result(status: -1, out: "", err: error.localizedDescription)
        }

        // Drain stderr on its own thread so a chatty stderr can't block stdout.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()

        return Result(
            status: process.terminationStatus,
            out: String(decoding: outData, as: UTF8.self),
            err: String(decoding: errData, as: UTF8.self)
        )
    }
}
