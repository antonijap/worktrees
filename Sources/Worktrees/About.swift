import AppKit

/// The About window, with who made the app.
enum About {
    static let author = "Antonija Pek"
    static let site = URL(string: "https://apek.me")!

    @MainActor static func show() {
        let credits = NSMutableAttributedString(
            string: "Made by \(author)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        )
        credits.append(NSAttributedString(string: "apek.me", attributes: [.font: NSFont.systemFont(ofSize: 11), .link: site]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

/// Check for Updates in the menu: asks GitHub now and says what it found.
enum UpdatePrompt {
    @MainActor static func run(store: Store) async {
        let answer = await store.checkForUpdateNow()
        let alert = NSAlert()
        switch answer {
        case .upToDate(let version):
            alert.messageText = "Worktrees is up to date"
            alert.informativeText = "You have \(version), the latest version."
        case .available(let release):
            alert.messageText = "Worktrees \(release.version) is out"
            alert.informativeText = "You have \(UpdateCheck.current ?? "an older version"). With Homebrew: brew upgrade --cask worktrees. Or download it from GitHub."
            alert.addButton(withTitle: "Download")
            alert.addButton(withTitle: "Later")
        case .cantCheck(let reason):
            alert.messageText = "Couldn't check for updates"
            alert.informativeText = reason
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, case .available(let release) = answer { Open.url(release.url) }
    }
}
