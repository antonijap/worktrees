import SwiftUI

// MARK: - Worktree column

struct WorktreeColumn: View {
    @Environment(Store.self) private var store
    let folder: Folder
    var focus: FocusState<Pane?>.Binding
    /// The folders column is hidden, so the window's fixed controls sit over this bar's start.
    let sidebarCollapsed: Bool
    /// The detail column is hidden, so the details toggle sits over this bar's end.
    let detailCollapsed: Bool

    private struct ListSection: Identifiable {
        let title: String?
        let items: [(repo: Repo, worktree: Worktree)]
        var id: String { title ?? "all" }
    }

    private var title: String {
        if case .repo(let id) = folder, let repo = store.repos.first(where: { $0.id == id }) { return repo.name }
        return "Overview"
    }

    private var groups: [ListSection] {
        let query = store.filter.trimmingCharacters(in: .whitespaces).lowercased()
        let newestFirst: (Worktree, Worktree) -> Bool = {
            ($0.lastCommit?.date ?? .distantPast) > ($1.lastCommit?.date ?? .distantPast)
        }
        switch folder {
        case .repo(let id):
            guard let repo = store.repos.first(where: { $0.id == id }) else { return [] }
            let sorted = repo.worktrees.filter { $0.matches(query) }.sorted {
                $0.isMain != $1.isMain ? $0.isMain : newestFirst($0, $1)
            }
            return [ListSection(title: nil, items: sorted.map { (repo, $0) })]
        case .overview:
            // Linked worktrees, plus main checkouts with recent work in progress. Old checkouts
            // with leftover changes would otherwise bury the worktrees that matter.
            let recent = Date().addingTimeInterval(-14 * 86_400)
            let all = store.repos.flatMap { repo in
                repo.worktrees
                    .filter { wt in
                        !wt.isMain || (WorktreeState(wt).group == .inProgress && (wt.lastCommit?.date ?? .distantPast) > recent)
                    }
                    .filter { $0.matches(query) || repo.name.lowercased().contains(query) }
                    .map { (repo: repo, worktree: $0) }
            }
            .sorted { newestFirst($0.worktree, $1.worktree) }
            return OverviewGroup.allCases.map { group in
                ListSection(title: group.title, items: all.filter { WorktreeState($0.worktree).group == group })
            }
            .filter { !$0.items.isEmpty }
        }
    }

    /// One flat list: labels and worktrees are rows of their own, each with a stable id, so a
    /// worktree that changes group moves rather than being destroyed and remade.
    private enum ListRow: Identifiable {
        case label(String, Int)
        case item(Repo, Worktree)
        var id: String {
            switch self {
            case .label(let title, _): "label:\(title)"
            case .item(_, let wt): wt.id
            }
        }
    }

    /// Typing in the filter changes the rows on every keystroke; those changes don't move.
    @State private var settledFilter = ""

    var body: some View {
        let groups = self.groups
        let ids = groups.flatMap { $0.items.map(\.worktree.id) }
        let rows: [ListRow] = groups.flatMap { group -> [ListRow] in
            (group.title.map { [ListRow.label($0, group.items.count)] } ?? []) + group.items.map { ListRow.item($0.repo, $0.worktree) }
        }
        // Mid-scan the list only grows (arrivals fade in on their own); the reorder comes with
        // the final publish, after scanning has stopped, and again when GitHub's answers regroup rows.
        let still = store.isScanning || store.filter != settledFilter

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                // The count goes before the title would truncate.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        Text(title).font(Font13.medium).foregroundStyle(Theme.text).lineLimit(1).fixedSize()
                        TickerText(ids.count).font(Font13.small.monospacedDigit()).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    Text(title).font(Font13.medium).foregroundStyle(Theme.text).lineLimit(1)
                }
                .accessibilityLabel("\(title), \(ids.count)")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer()
                TidyButton()
            }
            // Room for the window's fixed controls when they sit over this bar.
            .padding(.leading, sidebarCollapsed ? FixedControls.leadingRoom : columnInset)
            .padding(.trailing, detailCollapsed ? FixedControls.trailingRoom : 8)
            .frame(height: barHeight)
            .hairline(.bottom)

            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if ids.isEmpty && !store.isScanning {
                        Text(store.filter.isEmpty ? "No worktrees here" : "Nothing matches the filter. Esc clears it.")
                            .font(Font13.body)
                            .foregroundStyle(Theme.muted)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 12)
                    }
                    ForEach(rows) { row in
                        switch row {
                        case .label(let title, let count):
                            SectionLabel(text: title, count: count)
                                .motionTransition(.opacity.animation(Motion.quick))
                        case .item(let repo, let wt):
                            WorktreeListRow(
                                repo: repo,
                                worktree: wt,
                                showRepo: folder == .overview,
                                selected: store.selectedID == wt.id
                            ) {
                                store.selectedID = wt.id
                                focus.wrappedValue = .list
                            }
                            // Arrivals fade in; a deleted row fades out to the left while the
                            // rows below close up with the list spring.
                            .motionTransition(
                                .asymmetric(
                                    insertion: .opacity.animation(Motion.quick),
                                    removal: .opacity.combined(with: .move(edge: .leading)).animation(.easeOut(duration: 0.18))
                                ),
                                reduced: .opacity.animation(Motion.fade)
                            )
                        }
                    }
                }
                .padding(6)
                .motion(still ? nil : Motion.list, value: rows.map(\.id))
                .id(folder)
            }
            .task(id: store.filter) {
                // A quarter second of quiet means the person has stopped typing.
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { settledFilter = store.filter }
            }
            .scrollIndicators(.never)
            .focusable()
            .focused(focus, equals: .list)
            .focusEffectDisabled()
            .onKeyPress(.upArrow) { move(-1, in: ids, proxy: proxy) }
            .onKeyPress(.downArrow) { move(1, in: ids, proxy: proxy) }
            .onKeyPress(.return) {
                guard let (_, wt) = store.selectedPair, Open.folderEditor != nil, !wt.isPrunable else { return .ignored }
                Sounds.play(.open)
                Open.inEditor(wt.path)
                return .handled
            }
            .onKeyPress(.escape) {
                guard !store.filter.isEmpty else { return .ignored }
                store.filter = ""
                return .handled
            }
            }

            StatusFooter()
        }
        .onAppear { keepSelection(old: [], new: ids) }
        .onChange(of: folder) { store.selectedID = ids.first }
        .onChange(of: ids) { old, new in keepSelection(old: old, new: new) }
    }

    private func move(_ step: Int, in ids: [String], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let current = store.selectedID.flatMap { ids.firstIndex(of: $0) }
        let next = current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0
        store.selectedID = ids[next]
        // Keeps the row on screen; a plain jump, selection never animates.
        proxy.scrollTo(ids[next])
        return .handled
    }

    /// Keeps the selection when it's still listed. When the selected worktree goes away
    /// (deleted, filtered out), selects the row that took its place rather than jumping to the top.
    private func keepSelection(old: [String], new: [String]) {
        guard let selected = store.selectedID else {
            store.selectedID = new.first
            return
        }
        guard !new.contains(selected) else { return }
        if let index = old.firstIndex(of: selected), !new.isEmpty {
            store.selectedID = new[min(index, new.count - 1)]
        } else {
            store.selectedID = new.first
        }
    }
}

/// Scan status, freshness and short notices. Sits under the worktree list so it stays
/// visible when the folder column is collapsed.
struct StatusFooter: View {
    @Environment(Store.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(spacing: 6) {
                if store.isScanning || store.isLoadingGitHub {
                    ProgressView().controlSize(.mini)
                    Text(verbatim: store.isScanning ? store.progress : "Checking GitHub…")
                } else if let notice = store.notice {
                    NoticeView(text: notice, icon: store.noticeIcon)
                        .id(store.noticeIcon)
                        .motionTransition(.opacity.combined(with: .offset(y: 4)).animation(.easeOut(duration: 0.2)),
                                          reduced: .opacity.animation(Motion.fade))
                } else if let note = store.githubNote {
                    Text(verbatim: note).foregroundStyle(Theme.warning)
                } else if let scanned = store.lastScan {
                    Text(verbatim: "\(store.repos.count) repos in \(store.rootsSummary), scanned \(shortAge(scanned, now: context.date))")
                }
                Spacer(minLength: 0)
            }
            .font(Font13.small)
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, columnInset)
            .frame(height: 28)
            .hairline(.top)
            .motion(Motion.quick, value: store.notice != nil, reduced: Motion.fade)
        }
    }
}

/// A short status line. "Deleting 4 worktrees…" turning into "Deleted 4 worktrees, up to
/// 3,1 GB freed" ticks its numbers over, and a check, when there is one, springs in once.
/// Reduce Motion: final text at once, no spring.
private struct NoticeView: View {
    let text: String
    let icon: IconName?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Icon(name: icon, size: 12)
                    .foregroundStyle(Theme.success)
                    .scaleEffect(settled || reduceMotion ? 1 : 0.8)
                    .onAppear {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) { settled = true }
                    }
            }
            Text(verbatim: text)
                .foregroundStyle(Theme.text)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .motion(.easeInOut(duration: 0.4), value: text, reduced: Motion.fade)
        }
    }
}

struct WorktreeListRow: View {
    @Environment(Store.self) private var store
    let repo: Repo
    let worktree: Worktree
    let showRepo: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let state = WorktreeState(worktree)
        let meta = subtitle
        Button {
            Sounds.play(.tap)
            action()
        } label: {
            HStack(alignment: .top, spacing: 9) {
                WorktreeGlyph(worktree: worktree, size: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.displayTitle)
                        .font(selected ? Font13.medium : Font13.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    MetaLine(items: meta)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                selected ? Theme.selected : hovering ? Theme.hover : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            guard Open.folderEditor != nil, !worktree.isPrunable else { return }
            Sounds.play(.open)
            Open.inEditor(worktree.path)
        })
        .contextMenu { WorktreeActions(repo: repo, worktree: worktree) }
        .help(worktree.displayTitle)
        .accessibilityLabel(
            ([worktree.displayTitle, state.label, worktree.prGlyph.label]
             + meta.map(\.spoken)).joined(separator: ", ")
        )
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// The PR number and age matter most, then the ticket; the repo name and the creator tag
    /// go first when the row is narrow.
    private var subtitle: [MetaLine.Item] {
        var parts: [MetaLine.Item] = []
        if showRepo { parts.append(.init(text: repo.name, priority: MetaLine.low)) }
        if worktree.isMain { parts.append(.init(text: "main checkout", priority: MetaLine.medium)) }
        if let ticket = worktree.branchName.ticket { parts.append(.init(text: ticket, priority: MetaLine.medium)) }
        if let pr = worktree.pullRequest { parts.append(.init(text: "#\(pr.number)", priority: MetaLine.high)) }
        if let creator = worktree.creator { parts.append(.init(text: creator.name, priority: MetaLine.low, isCreator: true)) }
        if let commit = worktree.lastCommit { parts.append(.init(text: shortAge(commit.date), priority: MetaLine.high)) }
        return parts
    }
}

/// The three actions, shared by the context menu and the main menu.
struct WorktreeActions: View {
    @Environment(Store.self) private var store
    let repo: Repo
    let worktree: Worktree

    var body: some View {
        if let url = repo.githubURL(for: worktree) {
            Button(worktree.pullRequest != nil ? "Open PR on GitHub" : "Open on GitHub") {
                Sounds.play(.open)
                Open.url(url)
            }
        }
        if let editor = Open.folderEditor, !worktree.isPrunable {
            Button("Open in \(editor.name)") {
                Sounds.play(.open)
                Open.inEditor(worktree.path)
            }
        }
        if !worktree.isMain {
            Divider()
            Button("Delete Worktree…") {
                store.selectedID = worktree.id
                store.confirmDeleteID = worktree.id
            }
        }
    }
}

/// Short metadata items laid out with space between them, no separator glyphs.
/// Rows of items, left to right, wrapping between items when a row is full. An item that can
/// shrink (a truncating Text) is given the room left on its row before the row breaks.
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var rowSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(width: width, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * rowSpacing
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private struct Row { var items: [(Int, CGSize)] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            let ideal = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            let lead = row.items.isEmpty ? 0 : spacing
            let room = width - row.width - lead
            var size = ideal
            if ideal.width > room {
                // Offer what is left; a truncating item takes it if that leaves it readable,
                // anything else goes to the next row (and is held to the row width there).
                let shrunk = subview.sizeThatFits(ProposedViewSize(width: max(room, 0), height: nil))
                if shrunk.width <= room, room >= min(ideal.width, 140), shrunk.width < ideal.width {
                    size = shrunk
                } else {
                    if !row.items.isEmpty {
                        rows.append(Row())
                        row = rows[rows.count - 1]
                    }
                    size = ideal.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
                }
            }
            let gap = row.items.isEmpty ? 0 : spacing
            row.items.append((index, size))
            row.width += gap + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

struct MetaLine: View {
    /// An item and how much it matters: when the line is short of room, whole items go,
    /// lowest first, rather than any being cut down to a stub.
    struct Item {
        let text: String
        var priority: Int = 1
        /// The creator tag, which VoiceOver reads as "made by".
        var isCreator = false

        var spoken: String { isCreator ? "made by \(text)" : text }
    }

    /// PR number and age stay longest, then the ticket, then the rest.
    static let high = 3, medium = 2, low = 1

    let items: [Item]

    var body: some View {
        PriorityRow(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(verbatim: item.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Zero-sized when dropped: nothing of it shows.
                    .clipped()
                    .layoutValue(key: PriorityRow.Priority.self, value: item.priority)
            }
        }
        .font(Font13.small)
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The row's own label says everything; this is the visual summary.
        .accessibilityHidden(true)
    }
}

/// Lays items out in a row in their own order, but fits them by priority: the highest go in
/// first, whole, and a lower one that doesn't fit is left out. One item may be shortened with
/// an ellipsis if at least `minimumShown` of it still shows; anything shorter is dropped.
struct PriorityRow: Layout {
    var spacing: CGFloat = 10
    /// About four characters and an ellipsis at 12pt.
    var minimumShown: CGFloat = 34

    struct Priority: LayoutValueKey {
        static let defaultValue = 1
    }

    /// Width each item gets (zero when dropped). A shortened item gets what it draws in its
    /// slot, so no gap opens after its ellipsis.
    private func widths(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let available = proposal.width ?? .infinity
        let order = subviews.indices.sorted { subviews[$0][Priority.self] > subviews[$1][Priority.self] }
        var result = Array(repeating: CGFloat(0), count: subviews.count)
        var used: CGFloat = 0
        var shortened = false
        for i in order {
            let gap = used > 0 ? spacing : 0
            if used + gap + ideal[i] <= available {
                result[i] = ideal[i]
                used += gap + ideal[i]
            } else if !shortened, available - used - gap >= minimumShown {
                let slot = available - used - gap
                result[i] = min(slot, subviews[i].sizeThatFits(ProposedViewSize(width: slot, height: nil)).width)
                used += gap + result[i]
                shortened = true
            }
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = widths(proposal, subviews)
        let shown = w.filter { $0 > 0 }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: shown.reduce(0, +) + spacing * CGFloat(max(0, shown.count - 1)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let w = widths(ProposedViewSize(width: bounds.width, height: bounds.height), subviews)
        var x = bounds.minX
        for (i, subview) in subviews.enumerated() {
            guard w[i] > 0 else {
                subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w[i], height: bounds.height))
            x += w[i] + spacing
        }
    }
}

// MARK: - Worktree detail

struct WorktreeDetailView: View {
    @Environment(Store.self) private var store
    let repo: Repo
    let worktree: Worktree
    @State private var details: WorktreeDetails?
    /// Sections showing every row rather than the first 20. The view is keyed to the
    /// worktree, so this starts over when another one is selected.
    @State private var expanded: Set<String> = Snapshot.expand ? ["uncommitted", "changes", "commits"] : []
    /// Rows whose diff panel is open, keyed by section and path.
    @State private var openDiffs: Set<String> = Snapshot.openDiffs
    /// Diffs read so far, keyed the same way. Cleared with each reload, so they match the
    /// worktree's HEAD and status.
    @State private var diffs: [String: FileDiff] = [:]
    /// A reload of the same worktree is on its way; the old lists dim until it lands.
    @State private var reloading = false
    /// Counts loads, so a reload crossfades the lists instead of changing them in place.
    @State private var loadCount = 0
    @State private var showLoading = false
    @State private var failingHovered = false
    @State private var whyExpanded = !Snapshot.whyCollapsed

    private var state: WorktreeState { WorktreeState(worktree) }

    /// Reload when this worktree's HEAD or working tree changed, so the file lists match the
    /// status rows. A rescan that found nothing new here leaves the lists alone.
    private var reloadKey: String {
        "\(worktree.id)|\(worktree.head)|\(worktree.status.hashValue)"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusPanel
                    whyItFailed
                    if let details {
                        Group {
                            uncommittedSection(details)
                            if !worktree.isMain { changesSection(details) }
                            commitsSection(details)
                        }
                        .opacity(reloading ? 0.5 : 1)
                        .motion(.easeOut(duration: 0.12), value: reloading, reduced: Motion.fade)
                        .id(loadCount)
                        .transition(.opacity)
                    }
                }
                .padding(.horizontal, contentInset)
                .padding(.vertical, 20)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .motion(Motion.quick, value: details == nil, reduced: Motion.fade)
                .motion(Motion.quick, value: loadCount, reduced: Motion.fade)
            }
            .scrollIndicators(.never)

            footer
        }
        .task(id: worktree.id) {
            // Main checkouts aren't measured by the scan; measure the one being looked at.
            if !worktree.isPrunable { await store.loadSizes(for: [worktree.path]) }
        }
        .task(id: reloadKey) {
            // Only show "Loading" if git takes a moment; fast loads never flash it.
            showLoading = false
            reloading = details != nil
            let slow = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { showLoading = true }
            }
            let loaded = await DetailsLoader.load(worktree)
            slow.cancel()
            guard !Task.isCancelled else { return }
            details = loaded
            diffs = [:]
            loadCount += 1
            reloading = false
            showLoading = false
        }
        .modifier(DeleteConfirmation(repo: repo, worktree: worktree))
    }

    /// Full button labels when the bar has room for them and a readable breadcrumb, else
    /// icons only. The whole bar is tried both ways, so the breadcrumb's minimum counts.
    private var topBar: some View {
        ViewThatFits(in: .horizontal) {
            bar(labels: true)
            bar(labels: false)
        }
    }

    private func bar(labels: Bool) -> some View {
        HStack(spacing: 6) {
            // One line always: the repo name gives way first, then the branch truncates in
            // the middle, and the whole thing yields to the buttons.
            CopyValue(worktree.branch ?? worktree.path, label: worktree.branch == nil ? "path" : "branch name") {
                HStack(spacing: 6) {
                    Icon(name: .folderGit2, size: 12).fixedSize()
                    Text(verbatim: repo.name).lineLimit(1).truncationMode(.tail).frame(minWidth: 48, alignment: .leading)
                    Text(verbatim: "/").fixedSize()
                    Text(verbatim: worktree.displayBranch).lineLimit(1).truncationMode(.middle)
                }
                .font(Font13.small)
                .foregroundStyle(Theme.muted)
            }
            // Keeps a readable stretch of the breadcrumb; the buttons drop their labels
            // before it gets any narrower.
            .frame(minWidth: 150, idealWidth: 150, maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                if let branch = worktree.branch {
                    Button("Copy Branch Name") { Clipboard.copy(branch, label: "branch name", store: store) }
                }
                Button("Copy Path") { Clipboard.copy(worktree.path, label: "path", store: store) }
            }
            Spacer(minLength: 12)
            // The 26pt buttons leave 3pt above and below in the 32pt bar; the gaps between
            // them and to the window edge match that.
            HStack(spacing: barButtonGap) { barButtons(labels: labels) }
                .fixedSize()
                .layoutPriority(2)
        }
        .padding(.leading, columnInset)
        // Room for the window's fixed details toggle at the far right.
        .padding(.trailing, FixedControls.trailingRoom)
        .frame(height: barHeight)
        .hairline(.bottom)
    }

    @ViewBuilder
    private func barButtons(labels: Bool) -> some View {
        if let url = repo.githubURL(for: worktree) {
            let title = worktree.pullRequest != nil ? "Open PR on GitHub" : "Open on GitHub"
            Button { Sounds.play(.open); Open.url(url) } label: {
                HStack(spacing: 5) {
                    Icon(name: .markGithub, size: 12)
                    if labels { Text(title) }
                }
            }
            .buttonStyle(BarButtonStyle())
            .help("\(title) (⇧⌘G)")
            .accessibilityLabel(title)
        }
        if let editor = Open.folderEditor, !worktree.isPrunable {
            Button { Sounds.play(.open); Open.inEditor(worktree.path) } label: {
                HStack(spacing: 5) {
                    EditorIcon(editor: editor, size: 12)
                    if labels { Text("Open in \(editor.name)") }
                }
            }
            .buttonStyle(BarButtonStyle())
            .help("Open in \(editor.name) (⌘O or Return)")
            .accessibilityLabel("Open in \(editor.name)")
        }
        if !worktree.isMain {
            Button { store.confirmDeleteID = worktree.id } label: {
                HStack(spacing: 5) {
                    Icon(name: .trash2, size: 12)
                    if labels { Text("Delete") }
                }
            }
            .buttonStyle(BarButtonStyle())
            .help("Remove this worktree's folder. The branch is kept. (⌘⌫)")
            .accessibilityLabel("Delete")
        }
    }



    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(worktree.displayTitle)
                .font(Font13.title)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            // Items never break inside; the path shrinks first, then the line wraps between items.
            FlowLayout(spacing: 10, rowSpacing: 6) {
                if state == .failing, let check = worktree.pullRequest?.firstLinkedFailingCheck, let url = check.link {
                    // Straight to the logs of the first failing check.
                    Button {
                        Sounds.play(.open)
                        Open.url(url)
                    } label: {
                        HStack(spacing: 5) {
                            WorktreeGlyph(worktree: worktree, size: 13, ring: Theme.background)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                            Text(verbatim: state.label).foregroundStyle(state.color).fontWeight(.medium)
                                .underline(failingHovered)
                                .contentTransition(.opacity)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { over in
                        failingHovered = over
                        (over ? NSCursor.pointingHand : NSCursor.arrow).set()
                    }
                    .onDisappear { if failingHovered { NSCursor.arrow.set() } }
                    .help("Open the logs of \(check.displayName)")
                    .accessibilityLabel(state.label)
                    .accessibilityHint("Opens the failing check's logs")
                } else {
                    HStack(spacing: 5) {
                        WorktreeGlyph(worktree: worktree, size: 13, ring: Theme.background)
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text(verbatim: state.label).foregroundStyle(state.color).fontWeight(.medium)
                            .contentTransition(.opacity)
                    }
                    .fixedSize()
                }
                if let ticket = worktree.branchName.ticket { TicketPill(text: ticket).fixedSize() }
                if let creator = worktree.creator {
                    Text(verbatim: creator.name)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityLabel("made by \(creator.name)")
                }
                CopyValue(worktree.path, label: "path") {
                    Text(verbatim: worktree.path.abbreviatingHome)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .contextMenu {
                    Button("Copy Path") { Clipboard.copy(worktree.path, label: "path", store: store) }
                    if let branch = worktree.branch {
                        Button("Copy Branch Name") { Clipboard.copy(branch, label: "branch name", store: store) }
                    }
                }
            }
            .font(Font13.small)
        }
    }

    private var statusPanel: some View {
        VStack(spacing: 0) {
            StatusRow(title: "Pull request", copies: worktree.pullRequest.map { [("PR number", "#\($0.number)"), ("PR link", $0.url)] } ?? [], hasLink: worktree.pullRequest != nil) {
                if let pr = worktree.pullRequest {
                    HStack(spacing: 10) {
                        if let url = URL(string: pr.url) {
                            LinkText(text: "#\(pr.number)", url: url, label: "Open pull request #\(pr.number) on GitHub")
                        } else {
                            Text(verbatim: "#\(pr.number)")
                        }
                        Text(verbatim: prState(pr))
                    }
                } else {
                    Text("None").foregroundStyle(Theme.muted)
                }
            }
            if let pr = worktree.pullRequest, pr.isOpen, pr.checks != .none {
                RowDivider()
                StatusRow(title: "Checks", hasLink: true) { checksValue(pr) }.transition(.opacity)
            }
            if let pr = worktree.pullRequest, pr.isOpen, !pr.reviews.isEmpty {
                RowDivider()
                StatusRow(title: "Reviewers") { reviewersValue(pr) }.transition(.opacity)
            }
            if let pr = worktree.pullRequest, let problem = pr.mergeProblem {
                RowDivider()
                StatusRow(title: "Merge") { Text(verbatim: problem).foregroundStyle(Theme.warning) }.transition(.opacity)
            }
            if let pr = worktree.pullRequest, !pr.labels.isEmpty {
                RowDivider()
                StatusRow(title: "Labels") {
                    let shown = pr.labels.prefix(4)
                    // Pills keep their words and wrap to a second line when the row is narrow.
                    FlowLayout(spacing: 4, rowSpacing: 4) {
                        ForEach(shown, id: \.self) { TicketPill(text: $0, mono: false).lineLimit(1) }
                        if pr.labels.count > shown.count {
                            Text(verbatim: "+\(pr.labels.count - shown.count)").foregroundStyle(Theme.muted).fixedSize()
                        }
                    }
                    .padding(.vertical, 5)
                    .help(pr.labels.joined(separator: ", "))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(pr.labels.joined(separator: ", "))
                }
            }
            if let pr = worktree.pullRequest, let updated = prUpdated(pr) {
                RowDivider()
                StatusRow(title: "Updated") { Text(verbatim: updated) }.transition(.opacity)
            }
            RowDivider()
            StatusRow(title: "Working tree") { Text(verbatim: workingTree) }
            RowDivider()
            StatusRow(title: "Remote", copies: worktree.status?.upstream.map { [("upstream name", $0)] } ?? []) { Text(verbatim: remote) }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .panel()
        // Fresh GitHub data crossfades in; rows that appear with it fade in.
        .motion(Motion.quick, value: worktree.pullRequest, reduced: Motion.fade)
    }

    /// Failing GitHub Actions runs: the last lines of their failed steps, fetched on demand.
    private var actionsRuns: [(check: PullRequest.CheckItem, runID: String)] {
        guard let pr = worktree.pullRequest, pr.isOpen else { return [] }
        var seen = Set<String>()
        return pr.failingChecks.compactMap { check in
            guard let id = check.actionsRunID, seen.insert(id).inserted else { return nil }
            return (check, id)
        }
    }

    @ViewBuilder
    private var whyItFailed: some View {
        let runs = actionsRuns
        if !runs.isEmpty, let slug = repo.githubRemote?.githubSlug {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    Motion.instantly { whyExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Icon(name: .chevronRight, size: 12)
                            .foregroundStyle(Theme.muted)
                            .rotationEffect(.degrees(whyExpanded ? 90 : 0))
                        Text("Why it failed").font(Font13.medium).foregroundStyle(Theme.text)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Why it failed")
                .accessibilityValue(whyExpanded ? "expanded" : "collapsed")
                .accessibilityAddTraits(.isHeader)
                // The panel appears and goes at once; the sections below jump with it.
                VStack(spacing: 0) {
                    if whyExpanded {
                        VStack(spacing: 0) {
                            ForEach(Array(runs.enumerated()), id: \.element.runID) { index, run in
                                logExcerpt(run.check, runID: run.runID)
                                if index < runs.count - 1 { RowDivider() }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .panel()
                    }
                }
            }
            .transaction { $0.animation = nil }
            .task(id: runs.map(\.runID)) {
                for run in runs { CheckLogs.shared.load(runID: run.runID, slug: slug, job: run.check.name) }
            }
        }
    }

    private func logExcerpt(_ check: PullRequest.CheckItem, runID: String) -> some View {
        let logs = CheckLogs.shared
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(verbatim: check.displayName).font(Font13.small.weight(.medium)).foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                if let url = check.link {
                    LinkText(text: "Open logs", url: url, label: "Open the logs of \(check.displayName)", font: Font13.small)
                }
            }
            let entry = logs.excerpt(for: runID)
            // The spinner line crossfades into the log when it lands.
            Group {
                switch entry {
                case .lines(let lines):
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(Font13.mono)
                        .foregroundStyle(Theme.text)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .unavailable:
                    Text("Couldn't fetch the log here. The link above has it.")
                        .font(Font13.small).foregroundStyle(Theme.muted)
                case .loading, nil:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Fetching the failed steps").font(Font13.small).foregroundStyle(Theme.muted)
                    }
                }
            }
            .transition(.opacity)
            .motion(Motion.quick, value: entry, reduced: Motion.fade)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "2h ago by mira": the author only when it's someone else's PR.
    private func prUpdated(_ pr: PullRequest) -> String? {
        var parts: [String] = []
        if let at = pr.updatedAt { parts.append(shortAge(at)) }
        // Without a known viewer every PR would look like someone else's, so the author waits.
        if let author = pr.author, let viewer = GitHub.viewer, author != viewer { parts.append("by \(author)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Each reviewer with where they stand. Approved and changes requested carry a glyph as
    /// well as the words, so colour is never the only signal.
    private func reviewersValue(_ pr: PullRequest) -> some View {
        let shown = pr.reviews.prefix(4)
        // Each reviewer stays whole; the line wraps between them when the row is narrow.
        return FlowLayout(spacing: 12, rowSpacing: 2) {
            ForEach(shown, id: \.name) { review in
                HStack(spacing: 4) {
                    switch review.state {
                    case .approved: Icon(name: .check, size: 12).foregroundStyle(Theme.success)
                    case .changesRequested: Icon(name: .x, size: 12).foregroundStyle(Theme.danger)
                    default: EmptyView()
                    }
                    Text(verbatim: review.name)
                    Text(verbatim: review.stateText).foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(review.name), \(review.stateText)")
            }
            if pr.reviews.count > shown.count {
                Text(verbatim: "+\(pr.reviews.count - shown.count)").foregroundStyle(Theme.muted).fixedSize()
            }
        }
        .padding(.vertical, 5)
        .help(pr.reviews.map { "\($0.name) \($0.stateText)" }.joined(separator: ", "))
    }

    private func prState(_ pr: PullRequest) -> String {
        switch pr.state {
        case "MERGED": return "Merged"
        case "CLOSED": return "Closed"
        default:
            let base = pr.isDraft ? "Draft" : "Open"
            switch pr.reviewDecision {
            case "APPROVED": return "\(base), approved"
            case "CHANGES_REQUESTED": return "\(base), changes requested"
            case "REVIEW_REQUIRED": return "\(base), waiting for review"
            default: return base
            }
        }
    }

    /// Failing checks by name, each opening its logs, then the passing and skipped counts.
    @ViewBuilder
    private func checksValue(_ pr: PullRequest) -> some View {
        let failing = pr.failingChecks
        let checksURL = URL(string: pr.url + "/checks")
        if failing.isEmpty {
            if let checksURL {
                LinkText(text: checksSummary(pr), url: checksURL, label: "Open checks on GitHub")
            } else {
                Text(verbatim: checksSummary(pr))
            }
        } else {
            let shown = failing.prefix(3)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, check in
                    if let url = check.link {
                        LinkText(text: check.displayName, url: url, label: "Open the logs of \(check.displayName)", color: Theme.danger)
                    } else {
                        Text(verbatim: check.displayName).foregroundStyle(Theme.danger)
                    }
                }
                HStack(spacing: 10) {
                    if failing.count > shown.count, let checksURL {
                        LinkText(text: "and \(failing.count - shown.count) more failing", url: checksURL, label: "Open all checks on GitHub")
                    }
                    let c = pr.checkCounts
                    if c.passed > 0 || c.skipped > 0 {
                        Text(verbatim: [c.passed > 0 ? "\(c.passed) passing" : nil, c.skipped > 0 ? "\(c.skipped) skipped" : nil]
                            .compactMap { $0 }.joined(separator: ", "))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(.vertical, 5)
        }
    }

    private func checksSummary(_ pr: PullRequest) -> String {
        let c = pr.checkCounts
        var parts: [String] = []
        if c.failed > 0 { parts.append("\(c.failed) failing") }
        if c.pending > 0 { parts.append("\(c.pending) running") }
        if c.passed > 0 { parts.append("\(c.passed) passing") }
        if c.skipped > 0 { parts.append("\(c.skipped) skipped") }
        return parts.joined(separator: ", ")
    }

    private var workingTree: String {
        guard let s = worktree.status else { return worktree.isPrunable ? "Folder is missing" : "Unknown" }
        if s.isClean { return "Clean" }
        var parts: [String] = []
        if s.conflicted > 0 { parts.append("\(s.conflicted) conflicted") }
        if s.changed > 0 { parts.append("\(s.changed) modified") }
        if s.untracked > 0 { parts.append("\(s.untracked) new") }
        return parts.joined(separator: ", ")
    }

    private var remote: String {
        guard let s = worktree.status else { return "Unknown" }
        guard let upstream = s.upstream else { return "Not pushed yet" }
        if s.ahead == 0 && s.behind == 0 { return "Up to date with \(upstream)" }
        var parts: [String] = []
        if s.ahead > 0 { parts.append("\(s.ahead) to push") }
        if s.behind > 0 { parts.append("\(s.behind) to pull") }
        return parts.joined(separator: ", ") + " (\(upstream))"
    }

    /// A binding for one section's expanded state.
    private func isExpanded(_ section: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(section) }, set: { if $0 { expanded.insert(section) } else { expanded.remove(section) } })
    }

    private func uncommittedSection(_ d: WorktreeDetails) -> some View {
        Section(title: "Uncommitted", trailing: Text(verbatim: "\(d.uncommitted.count)")) {
            if d.uncommitted.isEmpty { EmptyRow(text: "Nothing uncommitted") }
            CappedList(items: d.uncommitted, what: "files", expanded: isExpanded("uncommitted")) { file in
                let key = "uncommitted:\(file.path)"
                FileRow(icon: .filePen, path: file.path, worktreePath: worktree.path, exists: d.existing.contains(file.path),
                        expanded: isOpen(key)) {
                    Text(file.label)
                        .font(Font13.small.weight(.medium))
                        .foregroundStyle(file.label == "Conflict" ? Theme.danger : Theme.muted)
                }
                diffPanel(key: key, file: file.path, scope: file.code == "??" ? .untracked : .uncommitted)
            }
        }
    }

    private func changesSection(_ d: WorktreeDetails) -> some View {
        let base = d.base ?? "the default branch"
        return Section(title: "Changes since \(base)", trailing: diffStat(d.added, d.removed)) {
            if d.changes.isEmpty { EmptyRow(text: "No changes since \(base)") }
            CappedList(items: d.changes, what: "files", expanded: isExpanded("changes")) { file in
                let key = "changes:\(file.path)"
                FileRow(icon: .file, path: file.path, worktreePath: worktree.path, exists: d.existing.contains(file.path),
                        renamedFrom: file.oldPath, expanded: isOpen(key)) {
                    if let added = file.added, let removed = file.removed {
                        diffStat(added, removed)
                            .font(Font13.mono)
                            .accessibilityLabel("\(added) lines added, \(removed) removed")
                    } else {
                        Text("binary").font(Font13.small).foregroundStyle(Theme.muted)
                    }
                }
                diffPanel(key: key, file: file.path, oldPath: file.oldPath, scope: .sinceBase(d.base ?? "HEAD"))
            }
        }
    }

    private func isOpen(_ key: String) -> Binding<Bool> {
        Binding(get: { openDiffs.contains(key) }, set: { if $0 { openDiffs.insert(key) } else { openDiffs.remove(key) } })
    }

    /// The diff under a row, read the first time the row opens. It appears and goes at once;
    /// an accordion that slides would only slow a review down.
    @ViewBuilder
    private func diffPanel(key: String, file: String, oldPath: String? = nil, scope: DiffLoader.Scope) -> some View {
        if openDiffs.contains(key) {
            RowDivider()
            DiffPanel(diff: diffs[key], path: file, editorName: Open.editor?.name ?? "an editor")
                // Keyed on the load too, so a reload that cleared the diffs reads again.
                .task(id: "\(key)#\(loadCount)") {
                    guard diffs[key] == nil else { return }
                    let diff = await DiffLoader.load(worktree: worktree.path, file: file, oldPath: oldPath, scope: scope)
                    guard !Task.isCancelled else { return }
                    diffs[key] = diff
                }
                .transaction { $0.animation = nil }
        }
    }

    private func commitsSection(_ d: WorktreeDetails) -> some View {
        Section(
            title: worktree.isMain ? "Recent commits" : "Commits on this branch",
            trailing: Text(verbatim: "\(d.commits.count)")
        ) {
            if d.commits.isEmpty { EmptyRow(text: "No commits on this branch yet") }
            CappedList(items: d.commits, id: \.hash, what: "commits", expanded: isExpanded("commits")) { commit in
                HStack(spacing: 8) {
                    Icon(name: .gitCommitHorizontal, size: 14).foregroundStyle(Theme.muted)
                    Text(commit.subject).font(Font13.body).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    CommitHash(hash: commit.hash).fixedSize().layoutPriority(1)
                    Text(shortAge(commit.date)).font(Font13.small).foregroundStyle(Theme.muted)
                        .frame(width: 58, alignment: .trailing)
                        .fixedSize().layoutPriority(1)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Commit \(commit.subject), \(shortAge(commit.date))")
                .accessibilityAction(named: "Copy commit hash") {
                    Clipboard.copy(commit.hash, label: "commit hash", store: store)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if showLoading {
                ProgressView().controlSize(.mini)
                Text("Loading changes")
            } else if let d = details, !d.changes.isEmpty {
                diffStat(d.added, d.removed).font(Font13.small.monospacedDigit()).fixedSize()
                Text(verbatim: "since \(d.base ?? "the default branch")")
            }
            Spacer()
            // The right side keeps its numbers; the "since" text on the left gives way.
            if let bytes = store.sizes[worktree.path] {
                TickerText("\(formatBytes(bytes)) on disk", value: Double(bytes)).font(Font13.small.monospacedDigit())
                    .fixedSize().layoutPriority(1)
            }
            if let c = worktree.lastCommit { Text(verbatim: "Last commit \(c.relative)").layoutPriority(1) }
        }
        .font(Font13.small)
        .foregroundStyle(Theme.muted)
        .lineLimit(1)
        .padding(.horizontal, columnInset)
        .frame(height: 28)
        .hairline(.top)
    }
}

// MARK: - Building blocks

private struct Section<Content: View>: View {
    let title: String
    let trailing: Text
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(Font13.medium).foregroundStyle(Theme.text)
                trailing.font(Font13.small.monospacedDigit()).foregroundColor(Theme.muted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content() }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .panel()
        }
    }
}

/// Rows with dividers, the first 20 by default and a quiet full-width button that shows the
/// rest in place, or folds them away again. Lazy, so a list in the thousands costs only what
/// is on screen. The section header keeps the full count.
private struct CappedList<Item, ID: Hashable, Row: View>: View {
    let items: [Item]
    let id: KeyPath<Item, ID>
    /// Noun for the button, "files" or "commits".
    let what: String
    @Binding var expanded: Bool
    @ViewBuilder let row: (Item) -> Row
    @State private var hovering = false

    static var limit: Int { 20 }

    init(items: [Item], id: KeyPath<Item, ID>, what: String, expanded: Binding<Bool>, @ViewBuilder row: @escaping (Item) -> Row) {
        self.items = items; self.id = id; self.what = what; self._expanded = expanded; self.row = row
    }

    var body: some View {
        let shown = (expanded ? items[...] : items.prefix(Self.limit)).map { (key: $0[keyPath: id], item: $0) }
        let hidden = items.count - shown.count
        LazyVStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.key) { index, entry in
                row(entry.item)
                if index < shown.count - 1 || items.count > Self.limit { RowDivider() }
            }
            if items.count > Self.limit {
                Button {
                    Motion.instantly { expanded.toggle() }
                } label: {
                    Text(verbatim: expanded ? "Show fewer" : "Show \(hidden) more")
                        .font(Font13.small.weight(.medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                        // Edge to edge: inside a rounded panel a plain background would round itself.
                        .background(hovering ? Theme.hover : .clear, in: Rectangle())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                .accessibilityLabel(expanded ? "Show the first \(Self.limit) \(what) only" : "Show \(hidden) more \(what)")
            }
        }
        // Opens and closes at once, no animation.
        .transaction { $0.animation = nil }
    }
}

extension CappedList where Item: Identifiable, ID == Item.ID {
    init(items: [Item], what: String, expanded: Binding<Bool>, @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items: items, id: \.id, what: what, expanded: expanded, row: row)
    }
}

private struct EmptyRow: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(Font13.body)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
    }
}

private struct StatusRow<Value: View>: View {
    let title: String
    /// What the row offers to copy, as (label, text). The first shows as a hover button,
    /// all of them sit in the context menu.
    var copies: [(label: String, text: String)] = []
    /// The value holds a link, so VoiceOver must reach it as its own element.
    var hasLink = false
    @ViewBuilder let value: () -> Value
    @Environment(Store.self) private var store
    @State private var hovering = false

    private var styledValue: some View {
        value()
            .font(Font13.body)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .contentTransition(.opacity)
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(Font13.body)
                .foregroundStyle(Theme.muted)
                .frame(width: 100, alignment: .leading)
            // A plain value copies itself on click. A value with a link keeps the link's click
            // and gets the copy button beside it instead.
            Group {
                if let first = copies.first, !hasLink {
                    CopyValue(first.text, label: first.label) { styledValue }
                } else {
                    HStack(spacing: 2) {
                        styledValue
                        if let first = copies.first {
                            CopyButton(text: first.text, label: first.label, shown: hovering)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            ForEach(copies, id: \.text) { item in
                Button("Copy \(item.label.capitalized.replacingOccurrences(of: "Pr ", with: "PR "))") {
                    Clipboard.copy(item.text, label: item.label, store: store)
                }
            }
        }
        // Rows with a button inside stay a group named after the title; plain rows read as one,
        // title and value together, so no label is set over the combined text.
        .accessibilityElement(children: copies.isEmpty && !hasLink ? .combine : .contain)
        .modifier(GroupLabel(title: copies.isEmpty && !hasLink ? nil : title))
    }
}

private struct GroupLabel: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.accessibilityLabel(title) } else { content }
    }
}

/// A commit hash that copies itself on click.
private struct CommitHash: View {
    let hash: String
    @Environment(Store.self) private var store
    @State private var copied = false
    @State private var hovering = false
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Button {
            Clipboard.copy(hash, label: "commit hash", store: store)
            copied = true
            reset?.cancel()
            reset = Task {
                try? await Task.sleep(for: .milliseconds(1200))
                if !Task.isCancelled { copied = false }
            }
        } label: {
            // The hash keeps its width while "Copied" shows, so the row doesn't reflow.
            Text(verbatim: hash)
                .font(Font13.mono)
                .hidden()
                .overlay(alignment: .trailing) {
                    Text(verbatim: copied ? "Copied" : hash)
                        .font(Font13.mono)
                        .foregroundStyle(copied ? Theme.success : Theme.muted)
                        .underline(hovering && !copied)
                        .lineLimit(1)
                        .fixedSize()
                        .contentTransition(.opacity)
                        .motion(Motion.quick, value: copied, reduced: Motion.fade)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copy commit hash")
        .accessibilityLabel(copied ? "Copied" : "Copy commit hash \(hash)")
    }
}

/// One file. A click shows or hides its changes under the row; a double-click, or the button
/// that appears on hover, opens it in the chosen editor. Return and space toggle the changes
/// when the row has focus.
private struct FileRow<Trailing: View>: View {
    let icon: IconName
    let path: String
    let worktreePath: String
    /// Only files that exist: a deleted file has nothing to open.
    var exists = true
    /// For a renamed file, where it came from.
    var renamedFrom: String? = nil
    @Binding var expanded: Bool
    @ViewBuilder let trailing: () -> Trailing
    @State private var hovering = false
    @State private var editorHovered = false

    private var editor: Editor? { exists ? Open.editor : nil }
    private var fileName: String { (path as NSString).lastPathComponent }

    var body: some View {
        Button {
            // A click, Return or space toggles at once. The second click of a double-click
            // takes the first one's toggle back and opens the file instead.
            if let event = NSApplication.shared.currentEvent, event.type == .leftMouseUp, event.clickCount == 2, editor != nil {
                Motion.instantly { expanded.toggle() }
                open()
            } else {
                Motion.instantly { expanded.toggle() }
            }
        } label: {
            HStack(spacing: 8) {
                Icon(name: .chevronRight, size: 10)
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Icon(name: icon, size: 14).foregroundStyle(Theme.muted)
                Text(verbatim: fileName)
                    .font(Font13.body)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(verbatim: renamedFrom.map { "from \($0)" } ?? (path as NSString).deletingLastPathComponent)
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 8)
                // Hover shows a button that opens the file; it sits inside the row, so moving
                // the pointer onto it keeps the row hovered.
                if let editor {
                    // A small bordered pill, "Open in Zed", the same 22pt as the row's other controls.
                    Button(action: open) {
                        HStack(spacing: 5) {
                            EditorIcon(editor: editor, size: 12)
                            Text(verbatim: "Open in \(editor.name)")
                                .font(Font13.small)
                                .foregroundStyle(Theme.text)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 7)
                        .frame(height: 22)
                        .background(editorHovered ? Theme.controlHover : Theme.control, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 0.5))
                        .contentShape(Rectangle())
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .onHover { editorHovered = $0 }
                    .opacity(hovering || editorHovered || Snapshot.reveal ? 1 : 0)
                    // Out of the way when hidden: no clicks, no tab stop. VoiceOver has the row's action.
                    .allowsHitTesting(hovering || editorHovered)
                    .focusable(hovering || editorHovered)
                    .help("Open in \(editor.name)")
                    .accessibilityLabel("Open \(fileName) in \(editor.name)")
                }
                // The label keeps its size; the name and folder truncate instead.
                trailing().fixedSize().layoutPriority(1)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            // Edge to edge, touching the dividers; the panel's own clip rounds the outer corners.
            .background(hovering ? Theme.hover : .clear, in: Rectangle())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(expanded ? "Hide Changes" : "Show Changes") { Motion.instantly { expanded.toggle() } }
            if let editor { Button("Open in \(editor.name)") { open() } }
        }
        .help(editor.map { "Click to show the changes, double-click to open in \($0.name)" } ?? "Click to show the changes")
        .accessibilityLabel(fileName)
        .accessibilityValue(
            [expanded ? "changes shown" : "changes hidden", (path as NSString).deletingLastPathComponent, renamedFrom.map { "renamed from \($0)" }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        )
        .accessibilityHint(expanded ? "Hides the changes" : "Shows the changes")
        .modifier(OpenAction(name: editor?.name, open: open))
    }

    private func open() {
        guard editor != nil else { return }
        Sounds.play(.open)
        // The worktree goes along, so the file opens in the worktree's window.
        Open.inEditor(worktreePath, file: worktreePath + "/" + path)
    }
}

/// An "Open in <editor>" VoiceOver action, only when there is an editor to open in.
private struct OpenAction: ViewModifier {
    let name: String?
    let open: () -> Void
    func body(content: Content) -> some View {
        if let name { content.accessibilityAction(named: "Open in \(name)") { open() } } else { content }
    }
}

struct TicketPill: View {
    let text: String
    /// Ticket keys are mono; labels and other words are not.
    var mono = true

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .default))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// PR-state glyph with a check badge in the corner.
struct WorktreeGlyph: View {
    let worktree: Worktree
    let size: CGFloat
    var ring: Color = Theme.sidebar

    var body: some View {
        let glyph = worktree.prGlyph
        Icon(name: glyph.icon, size: size)
            .foregroundStyle(glyph.color)
            .overlay(alignment: .bottomTrailing) {
                if let badge = worktree.checkBadge {
                    CheckBadgeView(badge: badge, size: max(10, size * 0.72), ring: ring)
                        .offset(x: size * 0.16, y: size * 0.16)
                }
            }
            .help(worktree.checkBadge.map { "\(glyph.label), \($0.label.lowercased())" } ?? glyph.label)
            .accessibilityHidden(true)
    }
}

/// SF Symbol in its circle.fill variant: the symbol cut out in the background colour.
/// The symbol swaps with a down-up replace when the state changes, and bounces once when a
/// check starts failing. Reduce Motion: a plain crossfade, no bounce.
struct CheckBadgeView: View {
    let badge: CheckBadge
    let size: CGFloat
    var ring: Color = Theme.sidebar
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var failures = 0

    var body: some View {
        Image(systemName: badge.symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolVariant(.circle.fill)
            .symbolRenderingMode(.palette)
            .fontWeight(.black)
            .foregroundStyle(ring, badge.fill)
            .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace.downUp))
            .symbolEffect(.bounce, options: .nonRepeating, value: failures)
            .frame(width: size, height: size)
            .background(Circle().fill(ring).padding(-1))
            .motion(Motion.quick, value: badge, reduced: Motion.fade)
            .onChange(of: badge) { old, new in
                if new == .failing, old != .failing, !reduceMotion { failures += 1 }
            }
            .accessibilityHidden(true)
    }
}

/// "+12  −3", with zero counts in the neutral colour.
func diffStat(_ added: Int, _ removed: Int) -> Text {
    Text(verbatim: "+\(added)").foregroundColor(added > 0 ? Theme.success : Theme.muted)
        + Text(verbatim: "  −\(removed)").foregroundColor(removed > 0 ? Theme.danger : Theme.muted)
}

/// "just now", "5m ago", "16h ago", "3d ago", "2w ago", "4mo ago", "1y ago".
func shortAge(_ date: Date, now: Date = .now) -> String {
    let s = max(0, now.timeIntervalSince(date))
    switch s {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(s / 60))m ago"
    case ..<86_400: return "\(Int(s / 3600))h ago"
    case ..<(86_400 * 14): return "\(Int(s / 86_400))d ago"
    case ..<(86_400 * 60): return "\(Int(s / (86_400 * 7)))w ago"
    case ..<(86_400 * 365): return "\(Int(s / (86_400 * 30)))mo ago"
    default: return "\(Int(s / (86_400 * 365)))y ago"
    }
}

/// The "Delete this worktree?" dialog. It hangs off the detail column, or off the worktree
/// column while details are hidden, so Delete works either way.
struct DeleteConfirmation: ViewModifier {
    let repo: Repo
    let worktree: Worktree
    @Environment(Store.self) private var store
    /// Ignored files the dialog lists, fetched when it is asked for.
    @State private var ignored: [String]?

    func body(content: Content) -> some View {
        content
            // The ignored files (.env and the like) the delete would take are listed only when asked.
            // The dialog opens at once and the line about them fills in when the list arrives; a
            // list from an earlier open is never written over a newer one.
            .task(id: store.confirmDeleteID == worktree.id) {
                ignored = nil
                guard store.confirmDeleteID == worktree.id else { return }
                let list = await DetailsLoader.ignored(worktree)
                guard !Task.isCancelled, store.confirmDeleteID == worktree.id else { return }
                ignored = list
            }
            .alert("Delete this worktree?", isPresented: Binding(
                get: { store.confirmDeleteID == worktree.id },
                set: { if !$0 { store.confirmDeleteID = nil } }
            )) {
                // Cancel is the default: Return and Escape both back out, only a click on Delete deletes.
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
                Button("Delete", role: .destructive) { delete() }
            } message: {
                Text(verbatim: deleteMessage)
            }
    }

    private var deleteMessage: String {
        var lines = ["Removes the folder \(worktree.path.abbreviatingHome)."]
        if let branch = worktree.branch {
            let pushed = worktree.status?.upstream != nil || worktree.pullRequest != nil
            lines.append("The branch \(branch) stays\(pushed ? ", locally and on GitHub" : "").")
        }
        if let s = worktree.status, !s.isClean {
            let count = s.changed + s.untracked + s.conflicted
            lines.append("It has \(count) uncommitted file\(count == 1 ? "" : "s"). Those changes will be lost.")
        }
        if ignored == nil {
            lines.append("Checking for ignored files that git doesn't track…")
        } else if let ignored, !ignored.isEmpty {
            let names = ignored.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            let more = ignored.count > 3 ? " and \(ignored.count - 3) more" : ""
            lines.append("Also removes \(ignored.count) ignored file\(ignored.count == 1 ? "" : "s") that git doesn't track: \(names)\(more).")
        }
        if let s = worktree.status {
            if s.upstream == nil, !worktree.isMain, worktree.pullRequest == nil {
                lines.append("This branch was never pushed. Its commits stay on the local branch.")
            } else if s.ahead > 0 {
                lines.append("\(s.ahead) commit\(s.ahead == 1 ? " is" : "s are") not on GitHub yet. They stay on the local branch.")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private func delete() {
        Sounds.play(.delete)
        store.deleteWorktree(worktree, in: repo)
    }
}

/// The broom in the worktree bar. With nothing to clean it doesn't open the sheet: the broom
/// gives a quick sweep and a word appears beside it for two seconds (All tidy, or Checking
/// GitHub…). Under Reduce Motion the word just appears and goes.
struct TidyButton: View {
    @Environment(Store.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            if let note = store.tidyNote {
                Text(verbatim: note.text)
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .fixedSize()
                    .motionTransition(.opacity.combined(with: .move(edge: .trailing)), reduced: .identity)
                    .accessibilityHidden(true)  // announced instead
            }
            IconButton(icon: .brushCleaning, label: "Tidy up", shortcut: "⇧⌘T") {
                Sounds.play(.tap)
                store.openTidyUp()
            }
            // Two sweeps either way over half a second, one keyframe run per press; it ends
            // at rest and nothing re-arms it.
            .keyframeAnimator(initialValue: 0.0, trigger: reduceMotion ? 0 : store.tidyNoteCount) { content, angle in
                content.rotationEffect(.degrees(angle))
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-15, duration: 0.09)
                    CubicKeyframe(15, duration: 0.125)
                    CubicKeyframe(-15, duration: 0.125)
                    CubicKeyframe(15, duration: 0.11)
                    CubicKeyframe(0, duration: 0.05)
                }
            }
        }
        .motion(Motion.quick, value: store.tidyNote, reduced: nil)
    }
}
