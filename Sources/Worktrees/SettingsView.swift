import AppKit
import SwiftUI

/// Settings: a sidebar of pages, each a stack of grouped rows with the label on the left and
/// the control on the right.
struct SettingsView: View {
    @AppStorage("settingsPane") private var pane = SettingsPane.general

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    SidebarItem(pane: item, selected: item == pane) { pane = item }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(width: 184)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebar)
            .hairline(.trailing)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(pane.title)
                        .font(Font13.title)
                        .foregroundStyle(Theme.text)
                        .accessibilityAddTraits(.isHeader)
                    if DemoData.isOn && !Snapshot.isOn {
                        // Sample runs read none of these, so they must not write the real ones either.
                        Text("Sample data. Settings can't be changed in demo mode.")
                            .font(Font13.small)
                            .foregroundStyle(Theme.muted)
                    }
                    Group {
                        switch pane {
                        case .general: GeneralPane()
                        case .folders: FoldersPane()
                        case .tidy: TidyPane()
                        case .github: GitHubPane()
                        case .tools: ToolsPane()
                        case .advanced: AdvancedPane()
                        }
                    }
                    // Snapshots draw the pages as they look in use; their defaults domain is wiped.
                    .disabled(DemoData.isOn && !Snapshot.isOn)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
            .background(Theme.background)
        }
        .frame(width: 720, height: 540)
        .onAppear { Editors.shared.refresh() }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, folders, tidy, github, tools, advanced
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .folders: "Folders"
        case .tidy: "Tidy up"
        case .github: "GitHub"
        case .tools: "Tools"
        case .advanced: "Advanced"
        }
    }

    var icon: IconName {
        switch self {
        case .general: .settings2
        case .folders: .folder
        case .tidy: .brushCleaning
        case .github: .markGithub
        case .tools: .tags
        case .advanced: .slidersHorizontal
        }
    }
}

private struct SidebarItem: View {
    let pane: SettingsPane
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Icon(name: pane.icon, size: 14)
                Text(pane.title).font(selected ? Font13.medium : Font13.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Theme.text : Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(selected ? Theme.selected : hovering ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Building blocks

/// A labelled panel of rows, with an optional note under it.
private struct SettingsGroup<Content: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Font13.label)
                .tracking(0.4)
                .foregroundStyle(Theme.muted)
                .accessibilityAddTraits(.isHeader)
            // Each row draws a line under itself; the last one lands on the panel's border.
            VStack(spacing: 0) { content }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .panel()
            if let note {
                Text(note)
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Label and an optional line under it on the left, the control on the right.
private struct SettingsRow<Control: View>: View {
    let label: String
    var note: String? = nil
    var warning: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(Font13.medium).foregroundStyle(Theme.text)
                if let note {
                    Text(note).font(Font13.small).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                if let warning {
                    Text(warning).font(Font13.small).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // VoiceOver hears the label and note on the control itself, so a segmented
            // picker keeps its segments instead of being merged into one element. A row with
            // no control is only text, so that text stays.
            .accessibilityHidden(Control.self != EmptyView.self)
            control
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel(label)
                .accessibilityHint([note, warning].compactMap { $0 }.joined(separator: " "))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .hairline(.bottom)
    }
}

/// A toggle row; the switch carries the label for VoiceOver.
private struct ToggleRow: View {
    let label: String
    var note: String? = nil
    var warning: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(label: label, note: note, warning: warning) {
            Toggle(label, isOn: $isOn).toggleStyle(.switch).controlSize(.small)
        }
    }
}

/// Names as removable chips, with a field to add one. Used for branches and folder names.
private struct ChipEditor: View {
    @Binding var names: [String]
    let placeholder: String
    /// Rejects a name with a reason, or nil to accept it.
    var check: (String) -> String? = { _ in nil }
    @State private var draft = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChipFlow(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    HStack(spacing: 4) {
                        Text(verbatim: name).font(Font13.mono).foregroundStyle(Theme.text)
                        Button {
                            names.removeAll { $0 == name }
                        } label: {
                            Icon(name: .x, size: 11).foregroundStyle(Theme.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(name)")
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 6)
                    .padding(.vertical, 3)
                    .background(Theme.control, in: RoundedRectangle(cornerRadius: 4))
                }
                HStack(spacing: 4) {
                    Icon(name: .plus, size: 11).foregroundStyle(Theme.muted)
                    TextField(placeholder, text: $draft)
                        .textFieldStyle(.plain)
                        .font(Font13.mono)
                        .frame(width: 110)
                        .onSubmit(add)
                        .accessibilityLabel(placeholder)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border))
            }
            if let problem {
                Text(problem).font(Font13.small).foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hairline(.bottom)
        .onChange(of: draft) { problem = nil }
    }

    private func add() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let reason = check(name) {
            problem = reason
            AccessibilityNotification.Announcement(reason).post()
            return
        }
        if !names.contains(name) { names.append(name) }
        draft = ""
    }
}

/// Lays children out left to right, wrapping onto new lines.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A string list stored in UserDefaults, as a binding.
private func listBinding(_ key: String, default fallback: [String]) -> Binding<[String]> {
    Binding(
        get: { Prefs.cleaned(UserDefaults.standard.stringArray(forKey: key) ?? fallback) },
        set: { UserDefaults.standard.set(Prefs.cleaned($0), forKey: key) }
    )
}

// MARK: - Pages

private struct GeneralPane: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.Key.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Sounds.enabledKey) private var soundsEnabled = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @AppStorage(Prefs.Key.menuBarIcon) private var menuBarIcon = false
    @State private var loginOn = LoginItem.isOn
    @State private var loginProblem: String?

    var body: some View {
        SettingsGroup(label: "Look") {
            SettingsRow(label: "Appearance", note: "Follow macOS, or keep the app light or dark.") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
                .onChange(of: appearance) { Appearance.apply(appearance) }
            }
            ToggleRow(
                label: "Play sounds",
                note: "Short sounds when you select, open, delete or rescan.",
                warning: Sounds.systemAllows ? nil : "Interface sounds are off in System Settings > Sound, so the app stays silent either way.",
                isOn: $soundsEnabled
            )
            .onChange(of: soundsEnabled) {
                // A sample, so turning sound on confirms what it sounds like.
                if soundsEnabled { Sounds.play(.tap) }
            }
        }

        SettingsGroup(label: "Opening files") {
            let editors = Editors.shared
            if editors.installed.isEmpty {
                SettingsRow(label: "Editor", note: "No editor found. Install one, like Zed or VS Code, and it shows up here.") { EmptyView() }
            } else {
                SettingsRow(label: "Editor", note: "Open in Editor, ⌘O, Return and double-clicking a file all go here. Only installed editors are listed.") {
                    Picker("Editor", selection: Binding(
                        get: { editors.chosen?.id ?? "" },
                        set: { editors.chosenID = $0 }
                    )) {
                        ForEach(editors.installed) { editor in
                            HStack(spacing: 6) {
                                Image(nsImage: editor.icon(size: 16))
                                Text(editor.name)
                            }
                            .tag(editor.id)
                        }
                    }
                }
            }
        }

        SettingsGroup(label: "Command line") {
            CommandLineRow()
        }

        SettingsGroup(label: "Updates") {
            ToggleRow(
                label: "Check for updates",
                note: updateNote,
                isOn: $checkForUpdates
            )
            if let update = store.availableUpdate {
                SettingsRow(label: "Worktrees \(update.version) is out", note: "You have \(UpdateCheck.current ?? "a build from source").") {
                    Button("Download…") { Open.url(update.url) }
                }
            }
        }

        SettingsGroup(label: "Startup") {
            ToggleRow(
                label: "Open at login",
                note: LoginItem.outsideApplications ? "Works best from the Applications folder: macOS remembers this copy of the app." : nil,
                warning: loginProblem,
                isOn: Binding(get: { loginOn }, set: { on in
                    loginProblem = LoginItem.set(on)
                    loginOn = LoginItem.isOn
                })
            )
            ToggleRow(
                label: "Show in menu bar",
                note: "A small icon with the number of worktrees that need attention.",
                isOn: $menuBarIcon
            )
        }
        .onAppear { loginOn = LoginItem.isOn }
    }

    private var updateNote: String {
        store.githubSignedIn == false
            ? "Can't check right now: gh isn't signed in. Updates are listed on github.com/antonijap/worktrees/releases."
            : "Once a day, through gh. Nothing else is sent."
    }
}

private struct FoldersPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        SettingsGroup(label: "Scanned folders", note: "Each folder can hold many projects or be a single repo. Worktrees are found wherever they live, even outside these folders.") {
            if DemoData.isOn {
                SettingsRow(label: "Sample data", note: "Folders can't be changed in demo mode.") { EmptyView() }
            } else if store.roots.isEmpty {
                SettingsRow(label: "No folders yet", note: "Add the folders that hold your projects.") { EmptyView() }
            } else {
                ForEach(store.roots, id: \.self) { root in
                    HStack(spacing: 10) {
                        Icon(name: .folder, size: 14).foregroundStyle(Theme.muted)
                        Text(verbatim: root.path.abbreviatingHome)
                            .font(Font13.medium)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        let count = store.repoCount(in: root)
                        if store.lastFullScan != nil {
                            Text("\(count) repo\(count == 1 ? "" : "s")").font(Font13.small).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { store.removeRoot(root) }
                            .controlSize(.small)
                            .accessibilityLabel("Remove \(root.lastPathComponent)")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .hairline(.bottom)
                }
            }
        }
        if !DemoData.isOn {
            HStack {
                Spacer()
                Button {
                    if let urls = FolderPicker.choose() { store.addRoots(urls) }
                } label: {
                    Label { Text("Add Folder…") } icon: { Icon(name: .plus, size: 12) }
                }
            }
        }
    }
}

private struct TidyPane: View {
    @AppStorage(Prefs.Key.staleDays) private var staleDays = Prefs.Default.staleDays
    @AppStorage(Prefs.Key.preselectStale) private var preselectStale = false
    @AppStorage(Prefs.Key.trashOnDelete) private var trashOnDelete = false

    var body: some View {
        SettingsGroup(label: "What counts as done") {
            SettingsRow(label: "Stale after", note: "Clean, pushed worktrees with no commits for this long show up in Tidy up.") {
                Picker("Stale after", selection: $staleDays) {
                    ForEach(Prefs.staleDayChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
            }
            ToggleRow(
                label: "Tick stale ones by default",
                note: "Merged and closed are ticked already. Stale ones otherwise wait for a look.",
                isOn: $preselectStale
            )
        }

        SettingsGroup(label: "Protected branches", note: "Worktrees on these branches never show up in Tidy up, and are never looked up on GitHub.") {
            ChipEditor(names: listBinding(Prefs.Key.protectedBranches, default: Prefs.Default.protectedBranches), placeholder: "Add branch") { name in
                name.contains(" ") ? "Branch names have no spaces." : nil
            }
        }

        SettingsGroup(label: "Deleting") {
            ToggleRow(
                label: "Move to Trash instead of deleting",
                note: "Put Back returns the files, but git forgets the worktree either way: its branch is how you pick the work up again. Space is freed when you empty the Trash.",
                isOn: $trashOnDelete
            )
        }
    }
}

private struct GitHubPane: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.Key.githubRefreshMinutes) private var refreshMinutes = Prefs.Default.githubRefreshMinutes
    @AppStorage(Prefs.Key.githubInBackground) private var inBackground = false
    @AppStorage(Prefs.Key.notifyChecksFailed) private var notifyChecks = false
    @AppStorage(Prefs.Key.notifyMerged) private var notifyMerged = false
    @State private var notificationsBlocked = false

    var body: some View {
        SettingsGroup(label: "Account") {
            HStack(spacing: 12) {
                let signedIn = store.githubSignedIn
                Icon(name: signedIn == false ? .alert : signedIn == true ? .check : .dash, size: 14)
                    .foregroundStyle(signedIn == false ? Theme.warning : signedIn == true ? Theme.success : Theme.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(accountTitle(signedIn)).font(Font13.medium).foregroundStyle(Theme.text)
                    Text(signedIn == false
                         ? "Run gh auth login in a terminal, then check again."
                         : "Pull requests and checks come from the GitHub CLI.")
                        .font(Font13.small).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                Button {
                    Task { await store.loadGitHub() }
                } label: {
                    Label { Text("Check Again") } icon: { Icon(name: .refreshCw, size: 12) }
                }
                .controlSize(.small)
                .disabled(store.isLoadingGitHub || DemoData.isOn)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .hairline(.bottom)
        }

        SettingsGroup(label: "Refresh") {
            SettingsRow(label: "Check GitHub every", note: "Fewer checks save your API rate limit. Rescanning always checks.") {
                Picker("Check GitHub every", selection: $refreshMinutes) {
                    ForEach(Prefs.githubRefreshChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Manually" : minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                    }
                }
            }
            ToggleRow(
                label: "Keep checking in the background",
                note: "Off: checks only run while Worktrees is in front.",
                isOn: $inBackground
            )
            .disabled(refreshMinutes == 0)
        }

        SettingsGroup(label: "Notifications", note: notificationNote) {
            ToggleRow(label: "When checks fail", note: "On a pull request that was passing or still running.", isOn: notifyBinding($notifyChecks))
            ToggleRow(label: "When a pull request is merged", note: "So you know its worktree can go.", isOn: notifyBinding($notifyMerged))
        }
        .disabled(!Notifier.available)
        .task {
            guard notifyChecks || notifyMerged else { return }
            notificationsBlocked = !(await Notifier.allowed())
        }
    }

    private var notificationNote: String? {
        if !Notifier.available { return "Notifications need the Worktrees app, not a command line build." }
        if notificationsBlocked { return "Notifications for Worktrees are off in System Settings > Notifications." }
        return nil
    }

    private func accountTitle(_ signedIn: Bool?) -> String {
        switch signedIn {
        case true?: GitHub.viewer.map { "Signed in as \($0)" } ?? "Signed in"
        case false?: "gh isn't signed in"
        case nil: "Not checked yet"
        }
    }

    /// Turning one on asks macOS for permission the first time.
    private func notifyBinding(_ value: Binding<Bool>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue }, set: { on in
            value.wrappedValue = on
            guard on else { return }
            Task { notificationsBlocked = !(await Notifier.requestPermission()) }
        })
    }
}

private struct ToolsPane: View {
    @Environment(Store.self) private var store

    var body: some View {
        let hidden = listBinding(Prefs.Key.hiddenTools, default: [])
        SettingsGroup(label: "Show tags for", note: "Worktrees are tagged with the tool that made them. Turn a tool off to hide its tag. A worktree in another hidden folder, like ~/.foo, is tagged foo.") {
            ForEach(Creator.known, id: \.slug) { tool in
                SettingsRow(label: tool.name, note: describe(tool)) {
                    Toggle(tool.name, isOn: Binding(
                        get: { !hidden.wrappedValue.contains(tool.slug) },
                        set: { on in
                            var list = hidden.wrappedValue.filter { $0 != tool.slug }
                            if !on { list.append(tool.slug) }
                            hidden.wrappedValue = list
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }

    private func describe(_ tool: Creator.Known) -> String {
        let folders = tool.folders.map { $0.hasPrefix(".") ? "~/" + $0 : $0 }
        let branches = tool.branches.map { "branches named \($0)" }
        return (folders + branches).joined(separator: ", ")
    }
}

private struct AdvancedPane: View {
    @Environment(Store.self) private var store
    @AppStorage(Prefs.Key.scanDepth) private var scanDepth = Prefs.Default.scanDepth
    @AppStorage(Prefs.Key.sizeMaxAgeMinutes) private var sizeMinutes = Prefs.Default.sizeMaxAgeMinutes
    @State private var confirmingReset = false

    var body: some View {
        SettingsGroup(label: "Scanning") {
            SettingsRow(label: "Look this deep for repos", note: "Folders inside a scanned folder. Deeper finds more and takes longer.") {
                Picker("Look this deep for repos", selection: $scanDepth) {
                    ForEach(Prefs.scanDepthChoices, id: \.self) { Text("\($0) levels").tag($0) }
                }
            }
        }

        SettingsGroup(label: "Also skip these folders", note: "Always skipped: \(Prefs.Default.skippedFolders.joined(separator: ", ")).") {
            ChipEditor(names: listBinding(Prefs.Key.skippedFolders, default: []), placeholder: "Add folder") { name in
                name.contains("/") ? "One folder name, no slashes." : nil
            }
        }

        SettingsGroup(label: "Disk sizes") {
            SettingsRow(label: "Measure again after", note: "Measuring big node_modules folders keeps the disk busy.") {
                Picker("Measure again after", selection: $sizeMinutes) {
                    ForEach(Prefs.sizeMaxAgeChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : minutes < 60 ? "\(minutes) minutes" : minutes == 60 ? "1 hour" : "\(minutes / 60) hours").tag(minutes)
                    }
                }
            }
        }

        SettingsGroup(label: "Reset") {
            SettingsRow(label: "Reset all settings", note: "Every option on these pages goes back to how it was on first launch. Your folders stay.") {
                Button("Reset…") { confirmingReset = true }
                    .disabled(DemoData.isOn)
            }
        }
        .alert("Reset all settings?", isPresented: $confirmingReset) {
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("Reset", role: .destructive) { reset() }
        } message: {
            Text("Appearance, sounds, editor, Tidy up, GitHub, tags and scanning go back to their defaults. Open at login is turned off.")
        }
    }

    private func reset() {
        Prefs.reset()
        for key in [Appearance.key, Sounds.enabledKey] { UserDefaults.standard.removeObject(forKey: key) }
        Appearance.apply()
        // Empty picks the first installed editor again, as on first launch.
        Editors.shared.chosenID = ""
        Editors.shared.refresh()
        _ = LoginItem.set(false)
        store.show("Settings reset")
    }
}

enum FolderPicker {
    /// Asks for one or more folders to scan.
    @MainActor static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that contain your projects, or a single repo."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }
}

/// The `worktrees` command: whether it is on the PATH, and a button to add or remove it.
private struct CommandLineRow: View {
    @State private var status = CommandLineTool.status()
    @State private var problem: String?

    var body: some View {
        SettingsRow(label: title, note: note, warning: problem ?? CommandLineTool.blocker) {
            switch status {
            case .installed:
                Button("Uninstall") { act { CommandLineTool.uninstall() } }
            case .elsewhere:
                Button("Update") { act { CommandLineTool.install() } }
                    .disabled(CommandLineTool.blocker != nil)
            case .notInstalled:
                Button("Install") { act { CommandLineTool.install() } }
                    .disabled(CommandLineTool.blocker != nil)
            case .taken, .homebrew:
                EmptyView()
            }
        }
        .onAppear { status = CommandLineTool.status() }
        // Installed or removed in a terminal meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = CommandLineTool.status()
        }
    }

    private var title: String {
        switch status {
        case .installed(let path): "worktrees is at \(path)"
        case .elsewhere: "worktrees points at another copy of the app"
        case .taken(let path): "\(path) is another tool"
        case .homebrew(let path): "worktrees is at \(path), from Homebrew"
        case .notInstalled: "Install the worktrees command"
        }
    }

    private var note: String {
        "Lists every worktree in a terminal. worktrees list --json gives scripts and agents the same view."
    }

    private func act(_ action: () -> String?) {
        problem = action()
        status = CommandLineTool.status()
    }
}

/// The menu command: installs, then says where, or why not.
enum CommandLineToolPrompt {
    @MainActor static func run() {
        let problem = CommandLineTool.install()
        let alert = NSAlert()
        if let problem {
            alert.messageText = "Couldn't install the worktrees command"
            alert.informativeText = problem
        } else {
            let where_: String = {
                switch CommandLineTool.status() {
                case .installed(let path), .homebrew(let path): path
                default: "your PATH"
                }
            }()
            alert.messageText = "worktrees is installed"
            alert.informativeText = "It's at \(where_). Try worktrees in a terminal, or worktrees list --json for scripts and agents."
        }
        alert.runModal()
    }
}
