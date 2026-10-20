import AppKit
import SwiftUI

/// A code editor on this Mac. The app opens worktrees and files in the one the person picked
/// in Settings, or in the first installed one from the list below.
struct Editor: Identifiable, Hashable {
    let id: String
    let name: String
    let url: URL
    /// Whether the app opens a folder as a project. Plain text editors take files only.
    let takesFolder: Bool

    static let key = "editor"

    /// Known editors, in default order. Several bundle ids where an app ships as more than
    /// one build. Plain text editors and Xcode come last, TextEdit at the very end so there
    /// is always something.
    static let known: [(name: String, bundleIDs: [String], takesFolder: Bool)] = [
        ("Zed", ["dev.zed.Zed", "dev.zed.Zed-Preview"], true),
        ("Visual Studio Code", ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], true),
        ("VSCodium", ["com.vscodium", "com.vscodium.VSCodiumInsiders"], true),
        ("Cursor", ["com.todesktop.230313mzl4w4u92"], true),
        ("Windsurf", ["com.exafunction.windsurf"], true),
        ("Sublime Text", ["com.sublimetext.4", "com.sublimetext.3"], true),
        ("Nova", ["com.panic.Nova"], true),
        ("Fleet", ["com.jetbrains.fleet"], true),
        ("IntelliJ IDEA", ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"], true),
        ("WebStorm", ["com.jetbrains.WebStorm"], true),
        ("PyCharm", ["com.jetbrains.pycharm", "com.jetbrains.pycharm.ce"], true),
        ("GoLand", ["com.jetbrains.goland"], true),
        ("PhpStorm", ["com.jetbrains.PhpStorm"], true),
        ("Rider", ["com.jetbrains.rider"], true),
        ("CLion", ["com.jetbrains.CLion"], true),
        ("RubyMine", ["com.jetbrains.rubymine"], true),
        ("RustRover", ["com.jetbrains.rustrover"], true),
        ("DataGrip", ["com.jetbrains.datagrip"], true),
        ("Android Studio", ["com.google.android.studio", "com.google.android.studio-EAP"], true),
        ("TextMate", ["com.macromates.TextMate"], true),
        ("CotEditor", ["com.coteditor.CotEditor"], false),
        ("BBEdit", ["com.barebones.bbedit"], false),
        ("Xcode", ["com.apple.dt.Xcode"], false),
        ("TextEdit", ["com.apple.TextEdit"], false),
    ]

    /// The editor's own command line tool and its arguments for opening `paths` (absolute,
    /// so none can be read as an option), or nil to go through Launch Services. Tools are
    /// looked up inside the app bundle the editor resolved to, never on PATH.
    func commandLine(opening paths: [String]) -> (executable: String, arguments: [String])? {
        let contents = url.appendingPathComponent("Contents")
        func tool(_ relative: String) -> String? {
            let path = contents.appendingPathComponent(relative).path
            return FileManager.default.isExecutableFile(atPath: path) ? path : nil
        }
        // Zed: one window with the worktree, the file opened in it.
        if id.hasPrefix("dev.zed."), let cli = tool("MacOS/cli") {
            return (cli, paths)
        }
        // VS Code and its forks ship a launcher script per product; Cursor also ships a "code".
        for name in ["cursor", "windsurf", "codium", "code-insiders", "code"] {
            if let cli = tool("Resources/app/bin/\(name)") { return (cli, paths) }
        }
        if let subl = tool("SharedSupport/bin/subl") {
            return (subl, paths)
        }
        // JetBrains IDEs and Android Studio hand the paths to the running instance.
        if id.hasPrefix("com.jetbrains.") && id != "com.jetbrains.fleet" || id.hasPrefix("com.google.android.studio") {
            return ("/usr/bin/open", ["-na", url.path, "--args"] + paths)
        }
        return nil
    }

    /// The app's icon drawn for `size` points, from the best representation for the screen
    /// it lands on, so it stays crisp at small sizes.
    @MainActor func icon(size: CGFloat) -> NSImage {
        if let cached = Self.icons[id]?[size] { return cached }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            source.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            return true
        }
        Self.icons[id, default: [:]][size] = image
        return image
    }

    @MainActor private static var icons: [String: [CGFloat: NSImage]] = [:]
}

/// The editors on this Mac and the one in use. Views read `chosen`, so a change in Settings
/// reaches every button and menu at once. `refresh()` looks again, since apps come and go.
@MainActor
@Observable
final class Editors {
    static let shared = Editors()

    private(set) var installed: [Editor] = []
    /// Bundle id of the chosen editor, as stored. Empty until something is chosen; the
    /// default is written back the first time it is resolved so it doesn't drift.
    var chosenID: String {
        didSet { UserDefaults.standard.set(chosenID, forKey: Editor.key) }
    }

    init() {
        chosenID = UserDefaults.standard.string(forKey: Editor.key) ?? ""
        refresh()
    }

    /// Looks the known editors up again. Cheap: one Launch Services query per bundle id.
    func refresh() {
        installed = Editor.known.compactMap { entry in
            for id in entry.bundleIDs {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    return Editor(id: id, name: entry.name, url: url, takesFolder: entry.takesFolder)
                }
            }
            return nil
        }
        if chosenID.isEmpty, let first = installed.first { chosenID = first.id }
    }

    /// The chosen editor. A chosen build that is gone falls back to another build of the
    /// same app (Zed Preview for Zed), then to the first installed. Nil only when nothing
    /// on the list is installed.
    var chosen: Editor? {
        if let exact = installed.first(where: { $0.id == chosenID }) { return exact }
        if let family = Editor.known.first(where: { $0.bundleIDs.contains(chosenID) }),
           let other = installed.first(where: { $0.name == family.name }) { return other }
        return installed.first
    }
}

/// The chosen editor's app icon at a given size, drawn for the exact size so it stays crisp.
/// In dark mode a hairline traces the icon's tile, so a dark icon (Zed's) still reads on a
/// dark bar.
struct EditorIcon: View {
    let editor: Editor
    var size: CGFloat = 12
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: editor.icon(size: size))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay {
                if colorScheme == .dark {
                    // App icons fill about 80% of their square, with corners about 22% of that.
                    let tile = size * 0.8
                    RoundedRectangle(cornerRadius: tile * 0.225, style: .continuous)
                        .strokeBorder(Theme.muted, lineWidth: 0.5)
                        .frame(width: tile, height: tile)
                }
            }
            .accessibilityHidden(true)
    }
}
