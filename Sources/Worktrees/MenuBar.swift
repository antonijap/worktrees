import AppKit
import SwiftUI

/// The optional menu bar icon: the app's mark, and the number of worktrees that need
/// attention when there are any.
struct MenuBarLabel: View {
    @Environment(Store.self) private var store

    private static let mark: NSImage = {
        let image = IconName.folderGit2.image.copy() as! NSImage
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }()

    var body: some View {
        let count = MenuBarMenu.attention(in: store.repos).count
        HStack(spacing: 4) {
            Image(nsImage: Self.mark)
            if count > 0 { Text(verbatim: "\(count)") }
        }
        .accessibilityLabel(count > 0 ? "Worktrees, \(count) need attention" : "Worktrees")
    }
}

struct MenuBarMenu: View {
    @Environment(Store.self) private var store
    @Environment(\.openSettings) private var openSettings
    let showWindow: () -> Void

    /// The ones the Overview lists under Needs attention.
    static func attention(in repos: [Repo]) -> [(repo: Repo, worktree: Worktree)] {
        repos.flatMap { repo in repo.worktrees.filter { WorktreeState($0).needsAttention }.map { (repo, $0) } }
    }

    var body: some View {
        let attention = Self.attention(in: store.repos)
        Text(attention.isEmpty ? "Nothing needs attention" : "\(attention.count) need\(attention.count == 1 ? "s" : "") attention")
        ForEach(attention.prefix(8), id: \.worktree.id) { item in
            Button("\(item.worktree.displayTitle)  \(item.repo.name)") {
                store.selectedID = item.worktree.id
                showWindow()
            }
        }
        Divider()
        Button("Show Worktrees") { showWindow() }
        Button("Rescan") { Task { await store.refresh() } }
            .disabled(store.isScanning)
        Button("Tidy Up…") {
            showWindow()
            store.openTidyUp()
        }
        .disabled(store.onboardingActive)
        Divider()
        Button("Settings…") {
            NSApplication.shared.activate(ignoringOtherApps: true)
            openSettings()
        }
        Button("Quit Worktrees") { NSApplication.shared.terminate(nil) }
    }
}
