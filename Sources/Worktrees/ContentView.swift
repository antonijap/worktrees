import AppKit
import SwiftUI

let sidebarCollapsedKey = "sidebarCollapsed"
let detailCollapsedKey = "detailCollapsed"

/// The two fixed columns can be dragged; the detail column takes the rest.
enum ColumnWidth {
    static let foldersKey = "foldersWidth"
    static let worktreesKey = "worktreesWidth"
    static let folders: ClosedRange<Double> = 180...320
    static let worktrees: ClosedRange<Double> = 260...480
    static let foldersDefault: Double = 220
    static let worktreesDefault: Double = 320
    /// What the detail column never goes below.
    static let detailMinimum: Double = 360
    /// The narrowest window with the detail column hidden: the worktrees column alone, with
    /// room for its title between the window's fixed controls.
    static let windowMinimumWithoutDetail: Double = worktrees.lowerBound + 40
    /// Whether a window this wide can show the detail column at its minimum next to the
    /// worktrees column at its stored width (with the folders column hidden, which goes
    /// first). Below this the details hide by themselves, without touching the saved choice.
    static func detailFits(in total: Double, worktrees: Double) -> Bool {
        total >= worktrees.clamped(to: Self.worktrees) + detailMinimum
    }

    /// Whether a window this wide can show the folders column without squeezing the worktrees
    /// column below its stored width (`worktrees`), as `fit` would lay it out.
    static func foldersFit(in total: Double, worktrees: Double, detailHidden: Bool = false) -> Bool {
        if detailHidden { return total >= folders.lowerBound + windowMinimumWithoutDetail }
        return total >= folders.lowerBound + worktrees.clamped(to: Self.worktrees) + detailMinimum
    }

    /// The widths that fit in `total`. Stored widths are preferences. The worktrees column in
    /// the middle keeps its width longest: as the window narrows the detail column gives first
    /// (down to its minimum), then the folders column (down to its own), then the folders
    /// column hides, then the detail column hides (see detailFits), and only then does the
    /// worktrees column shrink, by then with the whole window to itself.
    /// With the detail column hidden it needs no room, and the worktrees column takes whatever
    /// the folders leave (the caller stretches it; the width returned is its minimum share).
    static func fit(total: Double, folders: Double, worktrees: Double, foldersHidden: Bool, detailHidden: Bool = false) -> (folders: Double, worktrees: Double, showFolders: Bool) {
        var f = folders.clamped(to: Self.folders)
        var w = worktrees.clamped(to: Self.worktrees)
        if detailHidden {
            // The folders column gives first, down to its minimum, as in foldersFit.
            let showFolders = !foldersHidden && total >= Self.folders.lowerBound + Self.worktrees.lowerBound
            if showFolders { f = Swift.min(f, total - Self.worktrees.lowerBound) }
            return (f, Swift.max(Self.worktrees.lowerBound, total - (showFolders ? f : 0)), showFolders)
        }
        let room = total - detailMinimum
        if !foldersHidden {
            if f + w > room { f = Swift.max(Self.folders.lowerBound, room - w) }
            if f + w <= room { return (f, w, true) }
        }
        w = Swift.max(Self.worktrees.lowerBound, Swift.min(w, room))
        return (f, w, false)
    }
}

enum Folder: Hashable {
    case overview
    case repo(String)
}

/// The window's fixed controls. The folders toggle and Rescan sit right after the traffic
/// lights and the details toggle at the far right, drawn over the columns' top bars so they
/// never move when a column opens or closes. The bars leave room for them.
enum FixedControls {
    static let gap: CGFloat = 2
    /// Where the leading pair ends.
    static let leadingEnd: CGFloat = trafficLightInset + iconButtonSize * 2 + gap
    /// Room a bar leaves at its leading edge when the cluster sits over it: the bars' own
    /// 6pt spacing after it.
    static let leadingRoom: CGFloat = leadingEnd + 6
    /// Clear of the window's rounded corner, as the detail bar's buttons are.
    static let trailingInset: CGFloat = 10
    /// Room a bar leaves at its trailing edge for the details toggle.
    static let trailingRoom: CGFloat = trailingInset + iconButtonSize + barButtonGap
}

/// Where keyboard focus is. The worktree list takes it by default, so arrow keys work at launch.
enum Pane: Hashable {
    case list, filter
}

/// Three columns: folders, the folder's worktrees, what happened in the selected one.
struct ContentView: View {
    @Environment(Store.self) private var store
    @State private var folder: Folder
    @AppStorage(sidebarCollapsedKey) private var sidebarCollapsed = false
    @AppStorage(detailCollapsedKey) private var detailCollapsed = false
    @AppStorage(ColumnWidth.foldersKey) private var foldersWidth = ColumnWidth.foldersDefault
    @AppStorage(ColumnWidth.worktreesKey) private var worktreesWidth = ColumnWidth.worktreesDefault
    @FocusState private var focus: Pane?

    init(folder: Folder = .overview) {
        _folder = State(initialValue: folder)
    }

    var body: some View {
        @Bindable var store = store
        GeometryReader { geometry in
        // Details hide by themselves when there is no room for them; the saved choice stays.
        // Folders went before them, so they stay hidden too.
        let detailRoom = ColumnWidth.detailFits(in: geometry.size.width, worktrees: worktreesWidth)
        let autoHidden = !detailCollapsed && !detailRoom
        let detailHidden = detailCollapsed || autoHidden
        // Room for details if the worktrees column gave up its extra width.
        let detailCanShow = ColumnWidth.detailFits(in: geometry.size.width, worktrees: ColumnWidth.worktrees.lowerBound)
        let fit = ColumnWidth.fit(total: geometry.size.width, folders: foldersWidth, worktrees: worktreesWidth,
                                  foldersHidden: sidebarCollapsed || autoHidden, detailHidden: detailHidden)
        let folders = fit.folders
        let worktrees = fit.worktrees
        // A drag stops where the detail column (or, with it hidden, the worktrees column) would
        // drop below its minimum.
        let spare = detailHidden
            ? geometry.size.width - (fit.showFolders ? folders : 0) - ColumnWidth.worktrees.lowerBound
            : geometry.size.width - (fit.showFolders ? folders : 0) - worktrees - ColumnWidth.detailMinimum
        HStack(spacing: 0) {
            if fit.showFolders {
                // Opens and closes at once: no slide, the controls above stay where they are.
                Sidebar(folder: $folder, focus: $focus)
                    .frame(width: folders)
                    .hairline(.trailing)
                    .transition(.identity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Folders")
                    .overlay(alignment: .trailing) {
                        ColumnDivider(width: $foldersWidth, shown: folders, range: ColumnWidth.folders, limit: folders + spare,
                                      defaultWidth: ColumnWidth.foldersDefault, label: "Folders width")
                    }
                    .zIndex(2)
            }

            WorktreeColumn(folder: folder, focus: $focus, sidebarCollapsed: !fit.showFolders, detailCollapsed: detailHidden)
            .frame(width: detailHidden ? nil : worktrees)
            .frame(maxWidth: detailHidden ? .infinity : nil)
            .background(Theme.sidebar)
            // At the window's edge with details hidden, so no line there.
            .hairline(.trailing, shown: !detailHidden)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Worktrees")
            .overlay(alignment: .trailing) {
                if !detailHidden {
                    ColumnDivider(width: $worktreesWidth, shown: worktrees, range: ColumnWidth.worktrees, limit: worktrees + spare,
                                  defaultWidth: ColumnWidth.worktreesDefault, label: "Worktrees width")
                }
            }
            .zIndex(1)
            .background {
                // With details hidden, the delete dialog hangs off this column instead.
                if detailHidden, let (repo, wt) = store.selectedPair {
                    Color.clear.modifier(DeleteConfirmation(repo: repo, worktree: wt)).id(wt.id)
                }
            }

            if !detailHidden {
            Group {
                if let (repo, wt) = store.selectedPair {
                    WorktreeDetailView(repo: repo, worktree: wt).id(wt.id)
                } else if store.roots.isEmpty {
                    VStack(spacing: 10) {
                        Icon(name: .folderGit2, size: 28).foregroundStyle(Theme.muted)
                        Text("Add the folders that hold your projects")
                            .font(Font13.medium)
                            .foregroundStyle(Theme.text)
                        Button("Add Folder…") {
                            if let urls = FolderPicker.choose() { store.addRoots(urls) }
                        }
                        .buttonStyle(BarButtonStyle())
                    }
                } else {
                    VStack(spacing: 8) {
                        Icon(name: .gitBranch, size: 24).foregroundStyle(Theme.muted)
                        Text(store.isScanning ? "Scanning…" : "Select a worktree")
                            .font(Font13.body)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Details")
            }
        }
        .overlay(alignment: .topLeading) {
            LeadingControls(sidebarCollapsed: $sidebarCollapsed, foldersShown: fit.showFolders,
                            foldersFit: !autoHidden && ColumnWidth.foldersFit(in: geometry.size.width, worktrees: worktreesWidth, detailHidden: detailHidden))
        }
        .overlay(alignment: .topTrailing) {
            DetailToggle(shown: !detailHidden, fits: detailCanShow) {
                if detailHidden {
                    // Make room by narrowing the worktrees column if it has to.
                    worktreesWidth = Swift.min(worktreesWidth, geometry.size.width - ColumnWidth.detailMinimum)
                    detailCollapsed = false
                } else {
                    detailCollapsed = true
                }
            }
        }
        .onChange(of: [!detailHidden, detailCanShow], initial: true) {
            store.detailsShown = !detailHidden
            store.detailsCanShow = detailCanShow
        }
        .ignoresSafeArea()
        // The window can't be made narrower than what is showing needs.
        // Details hide by themselves in a narrow window, so the worktrees column alone sets the
        // narrowest the window can go.
        .background(WindowMinimum(width: ColumnWidth.windowMinimumWithoutDetail))
        .defaultFocus($focus, .list)
        .task {
            // The text field otherwise becomes first responder at launch and swallows arrow keys.
            focus = .list
            if store.repos.isEmpty { await store.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshIfStale()
            Editors.shared.refresh()
        }
        .onChange(of: store.focusFilterRequest) {
            // The field lives in the folders column; no point asking for it where it can't fit.
            if ColumnWidth.foldersFit(in: NSApplication.shared.keyWindow.map { Double($0.frame.width) } ?? .infinity,
                                     worktrees: worktreesWidth, detailHidden: detailCollapsed)
                && (detailCollapsed || ColumnWidth.detailFits(in: NSApplication.shared.keyWindow.map { Double($0.frame.width) } ?? .infinity, worktrees: worktreesWidth)) { sidebarCollapsed = false }
            // The field may only just be appearing; focus it on the next run loop turn.
            DispatchQueue.main.async { focus = .filter }
        }
        .onChange(of: focus) { store.filterFocused = focus == .filter }
        .onChange(of: store.deleteError) { if store.deleteError != nil { Sounds.play(.error) } }
        .sheet(isPresented: $store.showTidyUp) {
            TidyUpView().environment(store)
        }
        // Closing the window takes the sheet with it; the flag must not stay behind.
        .onDisappear { store.showTidyUp = false }
        .alert("Couldn't delete", isPresented: Binding(
            get: { store.deleteError != nil }, set: { if !$0 { store.deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: store.deleteError ?? "")
        }
        }
    }
}

/// Folders toggle and Rescan, fixed after the traffic lights. Its own view, so scanning
/// state changes redraw only this.
private struct LeadingControls: View {
    @Environment(Store.self) private var store
    @Binding var sidebarCollapsed: Bool
    let foldersShown: Bool
    let foldersFit: Bool

    var body: some View {
        HStack(spacing: FixedControls.gap) {
            IconButton(icon: .panelLeft,
                       label: foldersShown ? "Hide folders" : foldersFit ? "Show folders" : "No room for the folders column",
                       shortcut: foldersShown || foldersFit ? "⌃⌘S" : nil) {
                Sounds.play(.tap)
                sidebarCollapsed.toggle()
            }
            .disabled(!foldersShown && !foldersFit)
            IconButton(icon: .refreshCw, label: "Rescan", shortcut: "⌘R",
                       busy: store.isScanning || store.isLoadingGitHub, busyLabel: "Scanning") {
                Task {
                    await store.refresh()
                    Sounds.play(.refreshed)
                    store.announce("Rescan finished, \(store.repos.count) repos")
                }
            }
            .disabled(store.isScanning || store.isLoadingGitHub)
        }
        .frame(height: barHeight)
        .padding(.leading, trafficLightInset)
    }
}

/// Details toggle, fixed at the window's trailing edge. The folders icon mirrored: a panel
/// on the right.
private struct DetailToggle: View {
    /// Whether the details are on screen, which they aren't when hidden or out of room.
    let shown: Bool
    /// Whether the window could show them (narrowing the worktrees column if it must).
    let fits: Bool
    let toggle: () -> Void

    var body: some View {
        IconButton(icon: .panelLeft, label: shown ? "Hide details" : fits ? "Show details" : "No room for the details column",
                   shortcut: shown || fits ? "⌥⌘S" : nil, mirrored: true) {
            Sounds.play(.tap)
            toggle()
        }
        .disabled(!shown && !fits)
        .frame(height: barHeight)
        .padding(.trailing, FixedControls.trailingInset)
    }
}

/// Sets the hosting window's minimum content width, and again whenever `width` changes. A
/// window narrower than the new minimum (showing the details again in a small window) grows
/// to fit. Nothing animates.
private struct WindowMinimum: NSViewRepresentable {
    let width: Double

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // The view may not be in a window yet on its first update.
        DispatchQueue.main.async {
            guard let window = view.window, window.contentMinSize.width != width else { return }
            window.contentMinSize = CGSize(width: width, height: window.contentMinSize.height)
            let content = window.contentRect(forFrameRect: window.frame)
            if content.width < width, !window.styleMask.contains(.fullScreen) {
                var frame = window.frame
                frame.size.width += width - content.width
                window.setFrame(frame, display: true, animate: false)
            }
        }
    }
}

/// The drag handle on a column's trailing edge. The visible line is the column's own hairline;
/// this is the 8pt strip around it that takes the drag, the double-click reset, the arrow
/// keys when focused, and the VoiceOver increment and decrement. Nothing animates.
struct ColumnDivider: View {
    @Binding var width: Double
    /// The width the column has right now, which can be less than the stored one.
    let shown: Double
    let range: ClosedRange<Double>
    /// The most the column can take right now without squeezing the detail column.
    let limit: Double
    let defaultWidth: Double
    let label: String
    @State private var dragStart: Double?
    @State private var hovering = false
    @FocusState private var focused: Bool

    private static let step: Double = 20

    /// What the column really shows, so a drag or a step starts from there.
    private var current: Double { shown.clamped(to: range) }

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            // The keyboard focus ring, drawn by hand because the strip itself is clear.
            .overlay { if focused { Rectangle().fill(Theme.accent).frame(width: 2) } }
            // Half past the edge, so the strip straddles the hairline. zIndex on the column
            // keeps the outer half above the next column.
            .offset(x: 4)
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if hovering { NSCursor.pop(); hovering = false }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStart == nil { dragStart = current }
                        set((dragStart ?? current) + value.translation.width)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { width = defaultWidth }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.leftArrow) { nudge(-1); return .handled }
            .onKeyPress(.rightArrow) { nudge(1); return .handled }
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(current)) points")
            .accessibilityHint("Adjust to resize the column")
            .accessibilityAdjustableAction { direction in
                nudge(direction == .increment ? 1 : -1)
            }
            .accessibilityAction(named: "Reset width") { width = defaultWidth }
    }

    private func set(_ value: Double) {
        width = Swift.min(value, Swift.max(limit, range.lowerBound)).clamped(to: range)
    }

    private func nudge(_ sign: Double) {
        set(current + sign * Self.step)
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Folders

struct Sidebar: View {
    @Environment(Store.self) private var store
    @Binding var folder: Folder
    var focus: FocusState<Pane?>.Binding

    private var visibleRepos: [Repo] {
        let q = store.filter.trimmingCharacters(in: .whitespaces).lowercased()
        let repos = store.repos.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !q.isEmpty else { return repos }
        return repos.filter { repo in
            repo.name.lowercased().contains(q) || repo.worktrees.contains { $0.matches(q) }
        }
    }

    var body: some View {
        @Bindable var store = store
        let repos = visibleRepos
        let withWorktrees = repos.filter { $0.extraWorktreeCount > 0 }
        let others = repos.filter { $0.extraWorktreeCount == 0 }

        VStack(spacing: 0) {
            // The bar itself is empty: the folders toggle and Rescan are drawn over it by the
            // window (FixedControls), so they stay put when this column goes.
            Color.clear
                .frame(height: barHeight)
                .hairline(.bottom)

            SearchField(text: $store.filter, prompt: "Filter by ticket, branch or PR", focus: focus)
                .padding(.horizontal, 6)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    FolderRow(selected: folder == .overview, action: { folder = .overview }) {
                        Icon(name: .inbox, size: 14).foregroundStyle(Theme.muted)
                        Text("Overview").foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .accessibilityLabel("Overview, all worktrees by status")

                    if !withWorktrees.isEmpty {
                        SectionLabel(text: "With worktrees")
                        ForEach(withWorktrees) { folderRow($0) }
                    }
                    if !others.isEmpty {
                        SectionLabel(text: withWorktrees.isEmpty ? "Projects" : "Other repos")
                        ForEach(others) { folderRow($0) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.sidebar)
    }

    private func folderRow(_ repo: Repo) -> some View {
        let isSelected = folder == .repo(repo.id)
        let linked = repo.extraWorktreeCount
        let attention = repo.needsAttention
        return FolderRow(selected: isSelected, action: { folder = .repo(repo.id) }) {
            Icon(name: linked > 0 ? .folderGit2 : .folder, size: 14)
                .foregroundStyle(Theme.muted)
            Text(repo.name).foregroundStyle(Theme.text).lineLimit(1)
            Spacer(minLength: 4)
            if attention {
                CheckBadgeView(badge: .failing, size: 12)
                    .transition(.opacity)
            }
            if linked > 0 {
                TickerText(linked)
                    .font(Font13.small.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
        }
        .motion(Motion.quick, value: attention, reduced: Motion.fade)
        .accessibilityLabel(
            "\(repo.name), \(linked) linked worktree\(linked == 1 ? "" : "s")"
                + (attention ? ", needs attention" : "")
        )
    }
}

struct FolderRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button {
            Sounds.play(.tap)
            action()
        } label: {
            HStack(spacing: 7) { content() }
                .font(selected ? Font13.medium : Font13.body)
                .padding(.horizontal, 8)
                .frame(minHeight: 28)
                .background(
                    selected ? Theme.sidebarSelected : hovering ? Theme.hover : .clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

struct SectionLabel: View {
    let text: String
    var count: Int? = nil
    /// Horizontal inset. Lists use 8 so the label sits over the rows; panels use 0.
    var inset: CGFloat = 8

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
            if let count { TickerText(count).monospacedDigit() }
        }
        .font(Font13.small.weight(.medium))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, inset)
        .padding(.top, 12)
        .padding(.bottom, 3)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var focus: FocusState<Pane?>.Binding

    private var focused: Bool { focus.wrappedValue == .filter }

    var body: some View {
        HStack(spacing: 6) {
            Icon(name: .search, size: 12).foregroundStyle(Theme.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.muted))
                .textFieldStyle(.plain)
                .font(Font13.body)
                .foregroundStyle(Theme.text)
                .focused(focus, equals: .filter)
                .accessibilityLabel("Filter")
                .onKeyPress(.escape) {
                    text = ""
                    focus.wrappedValue = .list
                    return .handled
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Icon(name: .x, size: 12)
                        .foregroundStyle(Theme.muted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .frame(height: 28)
        // A filled field with no border; the icon and placeholder say what it is.
        .background(Theme.hover, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent, lineWidth: focused ? 2 : 0)
        )
        .contentShape(Rectangle())
        .onTapGesture { focus.wrappedValue = .filter }
    }
}

extension Worktree {
    /// Filter match on what people type: title, branch, ticket or PR number.
    func matches(_ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let q = query.hasPrefix("#") ? String(query.dropFirst()) : query
        return displayTitle.lowercased().contains(q)
            || (creator?.matches(q) ?? false)
            || (branch?.lowercased().contains(q) ?? false)
            || (branchName.ticket?.lowercased().contains(q) ?? false)
            || (pullRequest.map { String($0.number).hasPrefix(q) } ?? false)
    }
}
