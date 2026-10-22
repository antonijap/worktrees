import AppKit
import SwiftUI

/// `Worktrees --snapshot <out.png> [--dark] [--select <worktree path>] [--folder <repo name|overview>]
/// [--size WxH] [--tidy] [--tidy-empty] [--reveal] [--expand] [--diffs keys] [--collapsed] [--no-detail] [--wrap on|off|auto] [--wheel x,y,dx,dy[,shift]] [--resize W] [--widths F,W] [--click x,y]` renders the app with sample data into a PNG at 2x and exits.
///
/// Headless on purpose: the window is never ordered on screen, the app never activates, nothing
/// is read from disk or the network and nothing is written to UserDefaults. For checking visual
/// changes and for the README screenshots.
enum Snapshot {
    static var isOn: Bool { CommandLine.arguments.contains("--snapshot") }
    /// `--reveal`: draw hover-only controls (copy buttons, icon button hover boxes) as if hovered,
    /// so a snapshot can check their placement.
    static let reveal = isOn && CommandLine.arguments.contains("--reveal")
    /// `--why-collapsed`: the Why it failed block starts folded, so what is below it shows.
    static let whyCollapsed = isOn && CommandLine.arguments.contains("--why-collapsed")
    /// `--expand`: capped lists in the detail column start expanded.
    static let expand = isOn && CommandLine.arguments.contains("--expand")
    /// `--diffs a,b`: diff panels open for these "section:path" keys, e.g. "changes:src/x.ts".
    static let openDiffs: Set<String> = {
        guard isOn, let i = CommandLine.arguments.firstIndex(of: "--diffs"), CommandLine.arguments.indices.contains(i + 1) else { return [] }
        return Set(CommandLine.arguments[i + 1].split(separator: ",").map(String.init))
    }()

    @MainActor static func runAndExit() -> Never {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }
        guard let out = value("--snapshot"), out.hasSuffix(".png") else {
            FileHandle.standardError.write(Data("usage: Worktrees --snapshot <out.png> [--dark] [--select <path>] [--folder <name>] [--size WxH] [--tidy] [--settings <page>] [--reveal] [--collapsed]\n".utf8))
            exit(2)
        }
        let dark = args.contains("--dark")
        var size = CGSize(width: 1280, height: 800)
        if let s = value("--size") {
            let parts = s.split(separator: "x").compactMap { Double($0) }
            let minimum = ColumnWidth.windowMinimumWithoutDetail
            guard parts.count == 2, parts[0] >= minimum, parts[1] >= 480 else {
                fail("--size wants WxH, at least \(Int(minimum))x480")
            }
            size = CGSize(width: parts[0], height: parts[1])
        }

        // Preferences that would otherwise come from the real defaults domain. Values the UI
        // never writes go in the argument domain (volatile, read first). The layout ones go in
        // the registration domain so a --click can change them in process; a bare executable
        // has its own defaults domain, which is wiped at the end so nothing carries over.
        guard Bundle.main.bundleIdentifier == nil else { fail("--snapshot runs from the bare executable, not the app bundle") }
        var layout: [String: Any] = [sidebarCollapsedKey: args.contains("--collapsed"), detailCollapsedKey: args.contains("--no-detail")]
        if let spec = value("--widths") {
            let widths = spec.split(separator: ",").compactMap { Double($0) }
            guard widths.count == 2 else { fail("--widths wants two numbers, e.g. 220,320") }
            layout[ColumnWidth.foldersKey] = widths[0].clamped(to: ColumnWidth.folders)
            layout[ColumnWidth.worktreesKey] = widths[1].clamped(to: ColumnWidth.worktrees)
        }
        for key in layout.keys { UserDefaults.standard.removeObject(forKey: key) }
        UserDefaults.standard.register(defaults: layout)
        var defaults: [String: Any] = [Sounds.enabledKey: false]
        if let root = value("--real") { defaults["roots"] = [root] }
        // `--wrap on|off|auto`: the diff panels' wrap choice.
        if let wrap = value("--wrap") {
            guard ["on", "off", "auto"].contains(wrap) else { fail("--wrap wants on, off or auto") }
            defaults[DiffPanel.wrapKey] = wrap
        }
        // `--settings <page>`: the Settings window on one page (general, folders, tidy, github,
        // tools, advanced).
        let settingsPane = value("--settings")
        if let settingsPane {
            guard SettingsPane(rawValue: settingsPane) != nil else {
                fail("--settings wants one of \(SettingsPane.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            defaults["settingsPane"] = settingsPane
        }
        // Settings given on the command line (`-staleDays 7`) stay; the ones above are added.
        let given = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        UserDefaults.standard.setVolatileDomain(given.merging(defaults) { _, ours in ours }, forName: UserDefaults.argumentDomain)
        NSApplication.shared.setActivationPolicy(.prohibited)
        NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

        let store = Store()
        Task { await store.refresh() }
        // A real folder also waits for its GitHub pass, which follows the scan straight away.
        wait(until: { DemoData.isOn ? store.lastGitHub != nil : store.lastFullScan != nil && !store.isLoadingGitHub }, atMost: 60)

        // `--tidy-empty`: nothing to clean, Tidy up pressed: the window with its All tidy note.
        if args.contains("--tidy-empty") { store.repos = []; store.openTidyUp() }
        // `--busy`: the Rescan button shown mid-scan.
        if args.contains("--busy") { store.isScanning = true }
        if let path = value("--select") {
            guard store.locate(worktreeID: path) != nil else { fail("no sample worktree at \(path)") }
            store.selectedID = path
        }
        var folder: Folder = .overview
        if let name = value("--folder"), name != "overview" {
            guard let repo = store.repos.first(where: { $0.name == name }) else { fail("no sample repo named \(name)") }
            folder = .repo(repo.id)
        }

        // `--onboarding <step>`: the first-launch window on one step (welcome, folders, github,
        // ready), with sample folders and gh signed out.
        let onboardingStep = value("--onboarding")
        var onboardingModel: OnboardingModel?
        if let onboardingStep {
            let steps: [String: OnboardingModel.Step] = ["welcome": .welcome, "folders": .folders, "github": .github, "ready": .ready]
            guard let step = steps[onboardingStep] else { fail("--onboarding wants welcome, folders, github or ready") }
            let model = OnboardingModel(store: store, home: URL(fileURLWithPath: DemoData.home))
            model.step = step
            model.suggestions = [
                FolderSuggestion(url: URL(fileURLWithPath: DemoData.home + "/Code"), repoCount: 5, picked: true),
                FolderSuggestion(url: URL(fileURLWithPath: DemoData.home + "/Projects"), repoCount: 3, picked: true),
                FolderSuggestion(url: URL(fileURLWithPath: DemoData.home + "/src"), repoCount: 1, picked: false),
            ]
            model.github = .signedOut(path: "/opt/homebrew/bin/gh")
            // `--no-git`: the Folders step as it looks on a Mac without git.
            if args.contains("--no-git") { model.gitStatus = .missing }
            onboardingModel = model
        }
        let tidy = args.contains("--tidy") || settingsPane != nil || onboardingModel != nil
        let root: AnyView = onboardingModel.map { AnyView(OnboardingView(model: $0) {}.environment(store)) }
            ?? (settingsPane != nil
            ? AnyView(SettingsView().environment(store))
            : tidy
            ? AnyView(TidyUpView().environment(store))
            : value("--resize") != nil
                // Free to follow the window, so a resize lays out again.
                ? AnyView(ContentView(folder: folder).environment(store).frame(maxWidth: .infinity, maxHeight: .infinity))
                : AnyView(ContentView(folder: folder).environment(store).frame(width: size.width, height: size.height)))
        // `--chrome` uses the app's own window (hidden title bar over the content, traffic
        // lights in the corner), for checking what a click near the corner reaches.
        let chrome = args.contains("--chrome") && !tidy
        let window: NSWindow
        let hosting: NSView
        if chrome {
            window = MainWindow.make(content: root, title: "Snapshot", size: size)
            hosting = window.contentView!
        } else {
            let view = NSHostingView(rootView: root)
            view.sizingOptions = tidy ? [.intrinsicContentSize] : []
            view.frame = tidy ? CGRect(origin: .zero, size: view.fittingSize) : CGRect(origin: .zero, size: size)
            window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            hosting = view
        }
        let frame = hosting.frame
        window.appearance = NSApplication.shared.appearance
        if args.contains("--sheet-check") {
            // Presents the Tidy up sheet the way the button does and reports whether it attached.
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            wait(until: { false }, atMost: 0.5)
            store.isScanning = args.contains("--while-scanning")
            if args.contains("--with-error") { store.deleteError = "sample error"; wait(until: { false }, atMost: 0.5) }
            if args.contains("--with-confirm") { store.confirmDeleteID = store.selectedID; wait(until: { false }, atMost: 0.5) }
            store.openTidyUp()
            wait(until: { (window.attachedSheet?.frame.width ?? 0) >= 600 }, atMost: 3)
            if args.contains("--churn") {
                for _ in 0..<10 { store.repos = DemoData.repos(); wait(until: { false }, atMost: 0.05) }
                wait(until: { false }, atMost: 0.5)
            }
            let tidy = window.attachedSheet.map { $0.frame.width >= 600 } ?? false
            print("sheet attached: \(window.attachedSheet != nil), tidy sheet: \(tidy), sheet size: \(window.attachedSheet?.frame.size ?? .zero), showTidyUp: \(store.showTidyUp), windows: \(NSApplication.shared.windows.count)")
            exit(tidy ? 0 : 1)
        }
        // Never ordered front. Layout still runs, and the run loop lets async sample data settle.
        hosting.layoutSubtreeIfNeeded()
        wait(until: { false }, atMost: 0.8)
        hosting.layoutSubtreeIfNeeded()

        // `--click x,y` (points from the top left) sends a real mouse down and up through the
        // window, so hit targets can be checked, then the picture is taken after the result.
        for spec in args.enumerated().filter({ $0.element == "--click" }).compactMap({ args.indices.contains($0.offset + 1) ? args[$0.offset + 1] : nil }) {
            let p = spec.split(separator: ",").compactMap { Double($0) }
            guard p.count == 2 else { fail("--click wants x,y") }
            // Off screen windows don't get events unless ordered in; keep it far away.
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            let point = NSPoint(x: p[0], y: frame.height - p[1])
            if let hit = window.contentView?.superview?.hitTest(point) ?? window.contentView?.hitTest(point) {
                print("hit: \(type(of: hit)) window frame \(hit.convert(hit.bounds, to: nil))")
            }
            for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1)] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) {
                    window.sendEvent(event)
                }
            }
            wait(until: { false }, atMost: 0.6)
            hosting.layoutSubtreeIfNeeded()
            print("clicked \(Int(p[0])),\(Int(p[1])): folders \(UserDefaults.standard.bool(forKey: sidebarCollapsedKey) ? "hidden" : "shown"), details \(UserDefaults.standard.bool(forKey: detailCollapsedKey) ? "hidden" : "shown")")
        }

        // `--wheel x,y,dx,dy[,shift]` sends a scroll wheel event (lines; positive dy scrolls up,
        // positive dx left) at a point, optionally with Shift held, to check sideways scrolling.
        for spec in args.enumerated().filter({ $0.element == "--wheel" }).compactMap({ args.indices.contains($0.offset + 1) ? args[$0.offset + 1] : nil }) {
            let p = spec.split(separator: ",")
            let n = p.prefix(4).compactMap { Double($0) }
            guard n.count == 4 else { fail("--wheel wants x,y,dx,dy[,shift]") }
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            let inWindow = NSPoint(x: n[0], y: frame.height - n[1])
            let onScreen = window.convertPoint(toScreen: inWindow)
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            for _ in 0..<5 {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(n[3]), wheel2: Int32(n[2]), wheel3: 0) else { continue }
                cg.location = CGPoint(x: onScreen.x, y: mainHeight - onScreen.y)
                if p.count > 4, p[4] == "shift" { cg.flags = .maskShift }
                // Straight to the innermost scroll view under the point (window routing of a
                // made-up event only reaches it for the first burst).
                if let event = NSEvent(cgEvent: cg) {
                    var view = window.contentView?.hitTest(inWindow)
                    while let v = view, !(v is NSScrollView) { view = v.superview }
                    if let scroller = view { scroller.scrollWheel(with: event) } else { window.sendEvent(event) }
                }
                wait(until: { false }, atMost: 0.05)
            }
            wait(until: { false }, atMost: 0.3)
            hosting.layoutSubtreeIfNeeded()
            print("wheel \(spec)")
        }

        // `--resize W` narrows (or widens) the window after everything above, the way a person
        // dragging its edge would, to check what survives a resize.
        if let spec = value("--resize"), let w = Double(spec) {
            guard w >= ColumnWidth.windowMinimumWithoutDetail else { fail("--resize wants a width of at least \(Int(ColumnWidth.windowMinimumWithoutDetail))") }
            for step in stride(from: Double(hosting.frame.width), through: w, by: w < hosting.frame.width ? -40 : 40) + [w] {
                window.setContentSize(NSSize(width: step, height: hosting.frame.height))
                if !chrome { hosting.setFrameSize(NSSize(width: step, height: hosting.frame.height)) }
                hosting.layoutSubtreeIfNeeded()
                wait(until: { false }, atMost: 0.05)
            }
            wait(until: { false }, atMost: 0.5)
            hosting.layoutSubtreeIfNeeded()
        }

        let bounds = hosting.bounds
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("could not make a bitmap") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { fail("could not encode PNG") }
        do {
            try png.write(to: URL(fileURLWithPath: out))
        } catch {
            fail("could not write \(out): \(error.localizedDescription)")
        }
        print("\(out) \(Int(bounds.width))x\(Int(bounds.height))@2x")
        for key in [sidebarCollapsedKey, detailCollapsedKey, ColumnWidth.foldersKey, ColumnWidth.worktreesKey] { UserDefaults.standard.removeObject(forKey: key) }
        exit(0)
    }

    /// Spins the main run loop until the condition holds or the time is up.
    @MainActor private static func wait(until done: () -> Bool, atMost seconds: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
