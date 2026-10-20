import SwiftUI

/// Lists every worktree that can go: merged, closed, or untouched for a month, all clean with
/// nothing unpushed. One Delete for the checked ones. Branches are kept.
struct TidyUpView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var checked: Set<String> = []
    /// Candidates already offered once, so a row ticks itself only the first time it appears.
    @State private var seen: Set<String> = []
    /// Row the keyboard is on. Arrows move it, space toggles it.
    @State private var cursor: String?
    @State private var confirming = false
    @FocusState private var listFocused: Bool

    /// Nothing is judged until GitHub has answered once: before that an open PR looks like no PR.
    private var githubReady: Bool { store.lastGitHub != nil }

    private var candidates: [TidyCandidate] {
        githubReady ? TidyCandidate.candidates(in: store.repos) : []
    }

    var body: some View {
        let candidates = self.candidates
        let chosen = candidates.filter { checked.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tidy up")
                    .font(Font13.title)
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Text("Worktrees that are clean, pushed and done with. Deleting removes the folder, the branch stays.")
                    .font(Font13.small)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, contentInset)
            .padding(.top, 20)
            .padding(.bottom, 8)

            list(candidates)

            footer(candidates: candidates, chosen: chosen)
        }
        .frame(width: 600)
        .frame(height: height(for: candidates))
        .background(Theme.background)
        .onAppear { adopt(candidates) }
        .onChange(of: candidates.map(\.id)) {
            adopt(candidates)
            // Everything went (deleted elsewhere, or a rescan): close and say so by the button.
            if candidates.isEmpty {
                dismiss()
                store.showTidyNote(.allTidy)
            }
        }
        .task(id: candidates.map(\.id)) {
            // Usually already measured after the scan; this covers worktrees found since.
            await store.loadSizes(for: candidates.map(\.worktree.path))
        }
        .alert(confirmTitle(chosen.count), isPresented: $confirming) {
            // Cancel is the default: Return and Escape both back out, only a click on Delete deletes.
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) {
                // Re-check against the latest scan; anything that stopped qualifying is left alone.
                let final = TidyCandidate.candidates(in: store.repos).filter { checked.contains($0.id) }
                guard !final.isEmpty else { dismiss(); return }
                Sounds.play(.delete)
                store.tidy(final)
                dismiss()
            }
        } message: {
            Text(verbatim: confirmMessage(chosen))
        }
    }

    /// Ticks rows the first time they show up, if their reason is a safe bet.
    private func adopt(_ candidates: [TidyCandidate]) {
        for c in candidates where !seen.contains(c.id) {
            seen.insert(c.id)
            if c.preselected { checked.insert(c.id) }
        }
        if cursor == nil || !candidates.contains(where: { $0.id == cursor }) {
            cursor = candidates.first?.id
        }
    }

    /// Enough for the rows, within a sensible range. Sheets take their ideal size.
    private func height(for candidates: [TidyCandidate]) -> CGFloat {
        let sections = Set(candidates.map(\.reason)).count
        let rows = CGFloat(candidates.count) * 43 + CGFloat(sections) * 32
        return min(560, max(260, 160 + rows))
    }

    private func list(_ candidates: [TidyCandidate]) -> some View {
        let ids = candidates.map(\.id)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(TidyReason.allCases, id: \.self) { reason in
                    let rows = candidates.filter { $0.reason == reason }
                    if !rows.isEmpty {
                        SectionLabel(text: reason.label, count: rows.count, inset: 0)
                        VStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, c in
                                row(c)
                                if index < rows.count - 1 { RowDivider() }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .panel()
                    }
                }
            }
            .padding(.horizontal, contentInset)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .defaultFocus($listFocused, true)
        .onKeyPress(.upArrow) { move(-1, in: ids) }
        .onKeyPress(.downArrow) { move(1, in: ids) }
        .onKeyPress(.space) {
            guard let cursor else { return .ignored }
            if checked.contains(cursor) { checked.remove(cursor) } else { checked.insert(cursor) }
            return .handled
        }
        .accessibilityHint("Arrow keys move between worktrees, space ticks one")
    }

    private func move(_ step: Int, in ids: [String]) -> KeyPress.Result {
        guard !ids.isEmpty else { return .ignored }
        let current = cursor.flatMap { ids.firstIndex(of: $0) }
        cursor = ids[current.map { min(max($0 + step, 0), ids.count - 1) } ?? 0]
        return .handled
    }

    private func row(_ c: TidyCandidate) -> some View {
        let wt = c.worktree
        var meta = [MetaLine.Item(text: c.repo.name, priority: MetaLine.low)]
        if let ticket = wt.branchName.ticket { meta.append(.init(text: ticket, priority: MetaLine.medium)) }
        if let pr = wt.pullRequest { meta.append(.init(text: "#\(pr.number)", priority: MetaLine.high)) }
        if let creator = wt.creator { meta.append(.init(text: creator.name, priority: MetaLine.low, isCreator: true)) }
        if let commit = wt.lastCommit { meta.append(.init(text: shortAge(commit.date), priority: MetaLine.high)) }
        let size = store.sizes[wt.path]
        let isOn = Binding(
            get: { checked.contains(c.id) },
            set: { if $0 { checked.insert(c.id) } else { checked.remove(c.id) } }
        )
        let onCursor = listFocused && cursor == c.id
        return Toggle(isOn: isOn) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(wt.displayTitle)
                        .font(Font13.body)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    MetaLine(items: meta)
                }
                Spacer(minLength: 8)
                Text(verbatim: size.map(formatBytes) ?? "")
                    .font(Font13.small.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(minHeight: 28)
        .background(onCursor ? Theme.hover : .clear, in: Rectangle())
        // Keyboard cursor, shown as a ring the way the filter field shows focus.
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: onCursor ? 2 : 0).padding(2))
        .contentShape(Rectangle())
        .onTapGesture { cursor = c.id }
        .help(wt.path.abbreviatingHome)
        .accessibilityLabel(
            ([wt.displayTitle, c.reason.label] + meta.map(\.spoken)
             + [size.map(formatBytes) ?? "size unknown"]).joined(separator: ", ")
        )
    }

    private func footer(candidates: [TidyCandidate], chosen: [TidyCandidate]) -> some View {
        let measured = chosen.compactMap { store.sizes[$0.worktree.path] }
        let total = measured.reduce(0, +)
        var summary = "\(chosen.count) of \(candidates.count) selected"
        if !chosen.isEmpty {
            if measured.count == chosen.count { summary += ", \(formatBytes(total))" }
            else if total > 0 { summary += ", at least \(formatBytes(total))" }
            else { summary += ", measuring" }
        }
        return HStack(spacing: 8) {
            if !candidates.isEmpty {
                TickerText(summary, value: Double(chosen.count) + Double(total) / 1e15)
                    .font(Font13.small.monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            // With nothing to delete there is nothing to cancel, so the one button says Done.
            Button(candidates.isEmpty ? "Done" : "Cancel") { dismiss() }
                .buttonStyle(BarButtonStyle())
                .keyboardShortcut(.cancelAction)
            if !candidates.isEmpty {
                Button(chosen.isEmpty ? "Delete…" : chosen.count == 1 ? "Delete 1 worktree…" : "Delete \(chosen.count) worktrees…") {
                    confirming = true
                }
                .buttonStyle(BarButtonStyle())
                .disabled(chosen.isEmpty)
                .help("Removes the checked folders. Branches are kept.")
            }
        }
        .padding(.horizontal, contentInset)
        .frame(height: 48)
        .hairline(.top)
    }

    private func confirmTitle(_ n: Int) -> String {
        n == 1 ? "Delete this worktree?" : "Delete \(n) worktrees?"
    }

    private func confirmMessage(_ chosen: [TidyCandidate]) -> String {
        let measured = chosen.compactMap { store.sizes[$0.worktree.path] }
        let total = measured.reduce(0, +)
        var lines: [String] = []
        if chosen.count <= 3 {
            lines.append("Removes " + chosen.map { $0.worktree.path.abbreviatingHome }.joined(separator: ", ") + ".")
        } else {
            lines.append("Removes \(chosen.count) worktree folders.")
        }
        if total > 0 {
            // du counts clones and hard links in full, so the real gain can be smaller.
            lines.append("Frees up to \(formatBytes(total)) of disk space\(measured.count < chosen.count ? ", not every folder is measured yet" : "").")
        }
        lines.append("Every branch stays, locally and on GitHub. Nothing uncommitted or unpushed is in this list.")
        lines.append("Ignored files that git doesn't track, such as .env, go with the folders.")
        return lines.joined(separator: "\n\n")
    }
}
