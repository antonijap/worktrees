import AppKit
import Foundation

/// Puts the `worktrees` command on the PATH: a link to this app's executable, which runs as
/// the command line tool when called by that name (see CLI). Homebrew installs the same link
/// itself, so its users never need this.
enum CommandLineTool {
    /// Checked in this order; the first one that can be written to without a password wins.
    static let folders = ["/opt/homebrew/bin", "/usr/local/bin"]

    enum Status: Equatable {
        case notInstalled
        /// Our link, pointing at this copy of the app.
        case installed(path: String)
        /// Our link, but to another copy of the app (moved, or an older one).
        case elsewhere(path: String, target: String)
        /// Something else called `worktrees` is already there; it is left alone.
        case taken(path: String)
        /// Homebrew put it there and looks after it.
        case homebrew(path: String)
    }

    /// Folders where Homebrew keeps installed casks; a `worktrees` cask there owns the link.
    static let caskrooms = ["/opt/homebrew/Caskroom/worktrees", "/usr/local/Caskroom/worktrees"]

    static var executable: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath().path
    }

    /// A link whose target is any Worktrees.app's executable counts as ours.
    static func isOurs(target: String) -> Bool {
        target.hasSuffix("Worktrees.app/Contents/MacOS/Worktrees")
    }

    private static func linkTarget(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeSymbolicLink else { return nil }
        return try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    static func status(in folders: [String] = folders, executable: String = executable, caskrooms: [String] = caskrooms) -> Status {
        let fm = FileManager.default
        var taken: String?
        for folder in folders {
            let path = folder + "/" + CLI.name
            if let target = linkTarget(path) {
                guard isOurs(target: target) else { taken = taken ?? path; continue }
                if caskrooms.contains(where: { fm.fileExists(atPath: $0) }) { return .homebrew(path: path) }
                let real = URL(fileURLWithPath: target).resolvingSymlinksInPath().path
                return real == executable ? .installed(path: path) : .elsewhere(path: path, target: target)
            }
            if (try? fm.attributesOfItem(atPath: path)) != nil { taken = taken ?? path }
        }
        return taken.map { .taken(path: $0) } ?? .notInstalled
    }

    /// Why installing can't work from here, or nil when it can.
    static var blocker: String? {
        if DemoData.isOn || TestMode.on { return "Not from a sample or test copy of the app." }
        if Bundle.main.bundleIdentifier == nil { return "Only from the Worktrees app, not a command line build." }
        // Opened straight from Downloads, macOS runs the app from a hidden copy that goes away.
        if Bundle.main.bundlePath.contains("/AppTranslocation/") { return "Move Worktrees to Applications first." }
        return nil
    }

    /// Links `worktrees` to this app. nil on success, otherwise what went wrong.
    /// Without a writable folder it asks for an administrator password to use /usr/local/bin.
    @MainActor
    static func install(folders: [String] = folders, executable: String = executable, allowPassword: Bool = true,
                        caskrooms: [String] = caskrooms) -> String? {
        let fm = FileManager.default
        switch status(in: folders, executable: executable, caskrooms: caskrooms) {
        case .installed, .homebrew: return nil
        case .taken(let path):
            // Another tool with the name comes first on the PATH: a link further down would never run.
            return "\(path) is another tool called worktrees. Remove or rename it, then install again."
        case .elsewhere(let path, _):
            // Our own link to an old copy: point it here.
            if fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent) {
                try? fm.removeItem(atPath: path)
                return link(at: path, to: executable)
            }
            return allowPassword ? withPassword("ln -sfn \(quoted(executable)) \(quoted(path))") : "Can't write to \((path as NSString).deletingLastPathComponent)."
        case .notInstalled:
            for folder in folders where fm.isWritableFile(atPath: folder) {
                let path = folder + "/" + CLI.name
                if (try? fm.attributesOfItem(atPath: path)) != nil { continue }
                return link(at: path, to: executable)
            }
            let fallback = folders.last ?? "/usr/local/bin"
            let path = fallback + "/" + CLI.name
            if (try? fm.attributesOfItem(atPath: path)) != nil || linkTarget(path) != nil {
                return "\(path) already exists and isn't Worktrees. Remove it, or call the app's executable directly."
            }
            guard allowPassword else { return "No folder on the PATH can be written to." }
            return withPassword("mkdir -p \(quoted(fallback)) && ln -s \(quoted(executable)) \(quoted(path))")
        }
    }

    /// Removes our link and nothing else. nil on success.
    @MainActor
    static func uninstall(folders: [String] = folders, allowPassword: Bool = true, caskrooms: [String] = caskrooms) -> String? {
        let fm = FileManager.default
        // Homebrew's link is Homebrew's: brew uninstall --cask worktrees removes it.
        if caskrooms.contains(where: { fm.fileExists(atPath: $0) }) { return "Homebrew installed it. Run brew uninstall --cask worktrees to remove it." }
        var problem: String?
        for folder in folders {
            let path = folder + "/" + CLI.name
            guard let target = linkTarget(path), isOurs(target: target) else { continue }
            if fm.isWritableFile(atPath: folder) {
                do { try fm.removeItem(atPath: path) } catch { problem = error.localizedDescription }
            } else if allowPassword {
                problem = withPassword("rm \(quoted(path))") ?? problem
            } else {
                problem = "Can't write to \(folder)."
            }
        }
        return problem
    }

    private static func link(at path: String, to executable: String) -> String? {
        do {
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: executable)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// macOS asks for the password in its own dialog; the app never sees it.
    @MainActor
    private static func withPassword(_ command: String) -> String? {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        // -128: the person pressed Cancel.
        if error[NSAppleScript.errorNumber] as? Int == -128 { return "Cancelled." }
        return error[NSAppleScript.errorMessage] as? String ?? "Couldn't install."
    }
}
