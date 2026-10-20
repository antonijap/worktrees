import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(Sounds.enabledKey) private var soundsEnabled = true
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: appearance) { Appearance.apply(appearance) }
            } header: {
                Text("Appearance")
            }

            Section {
                let editors = Editors.shared
                if editors.installed.isEmpty {
                    Text("No editor found.").font(Font13.body).foregroundStyle(Theme.muted)
                } else {
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
                    .labelsHidden()
                }
            } header: {
                Text("Editor")
            } footer: {
                Text("Where Open in Editor, ⌘O, Return and double-clicking a file go. Only installed editors are listed.")
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                if DemoData.isOn {
                    Text("Sample data. Folders can't be changed in demo mode.")
                        .font(Font13.body)
                        .foregroundStyle(Theme.muted)
                }
                if store.roots.isEmpty {
                    Text("No folders yet. Add the folders that hold your projects.")
                        .font(Font13.body)
                        .foregroundStyle(Theme.muted)
                }
                ForEach(DemoData.isOn ? [] : store.roots, id: \.self) { root in
                    HStack(spacing: 8) {
                        Icon(name: .folder, size: 14).foregroundStyle(Theme.muted)
                        Text(verbatim: root.path.abbreviatingHome)
                            .font(Font13.body)
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") { store.removeRoot(root) }
                            .accessibilityLabel("Remove \(root.lastPathComponent)")
                    }
                }
                if !DemoData.isOn {
                    HStack {
                        Spacer()
                        Button("Add Folder…") {
                            if let urls = FolderPicker.choose() { store.addRoots(urls) }
                        }
                    }
                }
            } header: {
                Text("Scanned folders")
            } footer: {
                Text("Each folder can hold many projects or be a single repo. Worktrees are found wherever they live, even outside these folders.")
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(isOn: $soundsEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Play sounds")
                            .font(Font13.body)
                            .foregroundStyle(Theme.text)
                        Text("Short sounds when you select, open, delete or rescan.")
                            .font(Font13.small)
                            .foregroundStyle(Theme.muted)
                        if !Sounds.systemAllows {
                            Text("Interface sounds are off in System Settings > Sound, so the app stays silent either way.")
                                .font(Font13.small)
                                .foregroundStyle(Theme.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: soundsEnabled) {
                    // A sample, so turning sound on confirms what it sounds like.
                    if soundsEnabled { Sounds.play(.tap) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.never)
        .onAppear { Editors.shared.refresh() }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
