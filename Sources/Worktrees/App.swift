import AppKit
import SwiftUI

@main
struct WorktreesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let store = Store.shared
    @AppStorage(sidebarCollapsedKey) private var sidebarCollapsed = false
    @AppStorage(detailCollapsedKey) private var detailCollapsed = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    init() {
        if CommandLine.arguments.contains("--dump") { Dump.runAndExit() }
        if Snapshot.isOn { Snapshot.runAndExit() }
        // No window tabs: it's a single-window app, and View > Show Tab Bar would take over ⇧⌘T.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApplication.shared.setActivationPolicy(.regular)
        // Sample runs and background reinstalls (WORKTREES_BACKGROUND=1) must not take focus
        // from whatever the person is doing.
        if !DemoData.isOn, ProcessInfo.processInfo.environment["WORKTREES_BACKGROUND"] != "1" {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        // The main window is made by AppDelegate, not a WindowGroup: its hosting view needs
        // the safe area off before it is first laid out (see MainWindow).
        Settings {
            SettingsView()
                .environment(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                // The one window, back after ⌘W.
                Button("Show Worktrees") { delegate.showWindow() }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .sidebar) {
                Button(sidebarCollapsed ? "Show Folders" : "Hide Folders") { sidebarCollapsed.toggle() }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                // Follows what is on screen: details can be hidden by a narrow window as well.
                Button(store.detailsShown ? "Hide Details" : "Show Details") {
                    if store.detailsShown { detailCollapsed = true } else if store.detailsCanShow {
                        detailCollapsed = false
                        let total = NSApplication.shared.keyWindow.map { Double($0.contentLayoutRect.width) } ?? .infinity
                        let width = UserDefaults.standard.object(forKey: ColumnWidth.worktreesKey) as? Double ?? ColumnWidth.worktreesDefault
                        UserDefaults.standard.set(Swift.min(width, total - ColumnWidth.detailMinimum), forKey: ColumnWidth.worktreesKey)
                    }
                }
                .keyboardShortcut("s", modifiers: [.option, .command])
                .disabled(!store.detailsShown && !store.detailsCanShow)
                Picker("Appearance", selection: Binding(get: { appearance }, set: { appearance = $0; Appearance.apply($0) })) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Rescan") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.showTidyUp)
            }
            CommandGroup(after: .textEditing) {
                Button("Find") { store.focusFilterRequest += 1 }
                    .keyboardShortcut("f")
                    .disabled(store.showTidyUp)
            }
            CommandMenu("Worktree") {
                let pair = store.selectedPair
                Button("Open on GitHub") {
                    if let (repo, wt) = store.selectedPair, let url = repo.githubURL(for: wt) {
                        Sounds.play(.open)
                        Open.url(url)
                    }
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(pair.flatMap { $0.0.githubURL(for: $0.1) } == nil)

                Button("Open in \(Open.folderEditor?.name ?? "Editor")") {
                    if let (_, wt) = store.selectedPair {
                        Sounds.play(.open)
                        Open.inEditor(wt.path)
                    }
                }
                .keyboardShortcut("o")
                .disabled(Open.folderEditor == nil || pair == nil || pair?.1.isPrunable == true)

                Divider()

                Button("Tidy Up…") { store.openTidyUp() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Delete Worktree…") {
                    if let (_, wt) = store.selectedPair, !wt.isMain { store.confirmDeleteID = wt.id }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(pair == nil || pair?.1.isMain == true || store.filterFocused || store.showTidyUp)
            }
        }
    }
}

/// Makes and keeps the one main window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply()
        let window = MainWindow.make(
            content: ContentView().environment(Store.shared),
            title: DemoData.isOn ? "Worktrees (sample data)" : "Worktrees"
        )
        window.setFrameAutosaveName("Main")
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    /// Brings the main window back, from closed or minimized.
    func showWindow() {
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

/// The app's window: title bar hidden over the content, with the hosting view's safe area
/// switched off before it is first laid out. With the safe area on, SwiftUI makes every
/// scroll view extend up under the title bar strip, and the AppKit scroll view then sits
/// over the column top bars and takes the clicks meant for the buttons there. The columns
/// lay out under the title bar on purpose and keep their own traffic-light inset.
enum MainWindow {
    static func make<Content: View>(content: Content, title: String, size: CGSize = CGSize(width: 1280, height: 800)) -> NSWindow {
        let hosting = NSHostingView(rootView: content)
        hosting.safeAreaRegions = []
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = CGSize(width: ColumnWidth.windowMinimumWithoutDetail, height: 480)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

enum Open {
    /// Opens a web link. Only https: a PR or check link that turned out to be a file: or custom
    /// scheme URL would hand it to some other app.
    static func url(_ url: URL) {
        // Sample links point nowhere real.
        guard !DemoData.isOn, url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(url)
    }

    /// The editor things open in.
    @MainActor static var editor: Editor? { Editors.shared.chosen }
    /// The editor, when it can open a whole worktree; plain text editors can't.
    @MainActor static var folderEditor: Editor? { editor.flatMap { $0.takesFolder ? $0 : nil } }

    /// Opens a worktree folder, or one file or folder in it, in the chosen editor. Most editors
    /// only honour the first of several paths handed over through Launch Services, so an editor
    /// with a command line tool in its bundle gets the worktree and the file through that, which
    /// opens the file inside the worktree's window. Others get the one path they should open.
    /// Sample paths exist nowhere, so demo mode only plays the sound. A failure is said in the footer.
    @MainActor static func inEditor(_ path: String, file: String? = nil) {
        guard let editor, !DemoData.isOn else { return }
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: path).standardizedFileURL.path
        // ".claude/" from git status names a folder: no trailing slash, resolved in the worktree.
        var target = file.map { $0.hasPrefix("/") ? $0 : folder + "/" + $0 } ?? folder
        while target.count > 1, target.hasSuffix("/") { target.removeLast() }
        target = URL(fileURLWithPath: target).standardizedFileURL.path
        var isDirectory: ObjCBool = false
        // A link whose target is gone still exists as a link.
        guard fm.fileExists(atPath: target, isDirectory: &isDirectory) || (try? fm.attributesOfItem(atPath: target)) != nil else {
            Store.shared.show("\((target as NSString).lastPathComponent) isn't there any more")
            return
        }
        if isDirectory.boolValue && !editor.takesFolder {
            Store.shared.show("\(editor.name) opens files, not folders")
            return
        }
        // A file opens in its worktree's window when the editor takes folders. A folder inside
        // the worktree (an untracked ".claude/") opens the worktree's window rather than a
        // project of its own, which would also leave editor settings behind in it.
        let inside = target.hasPrefix(folder + "/")
        let paths: [String]
        if isDirectory.boolValue {
            paths = inside ? [folder] : [target]
        } else {
            paths = editor.takesFolder && inside ? [folder, target] : [target]
        }
        let failed: @Sendable (String) -> Void = { reason in
            Task { @MainActor in Store.shared.show("Couldn't open in \(editor.name): \(reason)") }
        }
        if let launch = editor.commandLine(opening: paths) {
            Shell.launch(launch.executable, launch.arguments, onFailure: failed)
            return
        }
        NSWorkspace.shared.open([URL(fileURLWithPath: paths.last ?? target)], withApplicationAt: editor.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { failed(error.localizedDescription) }
        }
    }
}

