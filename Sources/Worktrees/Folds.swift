import Observation
import SwiftUI

/// Which section headings are folded, in the worktree list and the details column. Kept across
/// launches. Keys are stable names ("list:Needs attention", "detail:uncommitted"), never
/// titles that change (the base branch in "Changes since"). A list group folds the same in the
/// Overview and in every repo, and a details section the same for every worktree: one choice
/// about what someone wants to see, not one per place.
@MainActor
@Observable
final class Folds {
    static let shared = Folds()
    static let key = "foldedSections"

    private(set) var folded: Set<String>
    /// Sample and snapshot runs keep folds in memory only; tests pass their own suite.
    @ObservationIgnored private let defaults: UserDefaults?

    init(defaults: UserDefaults? = DemoData.isOn || Snapshot.isOn ? nil : .standard) {
        self.defaults = defaults
        folded = Set(defaults?.stringArray(forKey: Self.key) ?? [])
    }

    func isFolded(_ key: String) -> Bool { folded.contains(key) }

    /// Snapshots start with these folded.
    func fold(_ keys: [String]) { folded.formUnion(keys) }

    func toggle(_ key: String) {
        if folded.contains(key) { folded.remove(key) } else { folded.insert(key) }
        defaults?.set(folded.sorted(), forKey: Self.key)
    }

    nonisolated static func list(_ title: String) -> String { "list:" + title }
    nonisolated static func detail(_ name: String) -> String { "detail:" + name }
}

/// A small heading that folds what is under it: a chevron, the title, an optional count.
/// A button for the keyboard and VoiceOver, which also hear whether it is open.
struct FoldHeading<Trailing: View>: View {
    let title: String
    let key: String
    var style: Style = .label
    /// After the fold, e.g. to hand keyboard focus back to the list.
    var onToggle: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    enum Style {
        /// The quiet group label in the worktree list.
        case label
        /// The section title in the details column.
        case title
    }

    var body: some View {
        let folds = Folds.shared
        let open = !folds.isFolded(key)
        Button {
            // At once, like Why it failed: rows mustn't play their delete animation.
            Motion.instantly { folds.toggle(key) }
            onToggle?()
        } label: {
            HStack(spacing: 6) {
                Icon(name: .chevronRight, size: style == .label ? 10 : 12)
                    .foregroundStyle(Theme.muted)
                    .rotationEffect(.degrees(open ? 90 : 0))
                Text(title)
                    .font(style == .label ? Font13.small.weight(.medium) : Font13.medium)
                    .foregroundStyle(style == .label ? Theme.muted : Theme.text)
                trailing()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(open ? "Fold \(title)" : "Show \(title)")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(open ? "expanded" : "collapsed")
        .accessibilityHint(open ? "Folds this section" : "Shows this section")
    }
}

extension FoldHeading where Trailing == EmptyView {
    init(title: String, key: String, style: Style = .label) {
        self.init(title: title, key: key, style: style, trailing: { EmptyView() })
    }
}

/// The worktree list's rows with folded groups' worktrees left out. Pure, so it can be tested.
enum FoldedList {
    /// For each group: its title (nil for the untitled main-checkout group, which can't fold)
    /// and its item ids. Returns the ids that show, in order.
    static func visible(groups: [(title: String?, ids: [String])], folded: Set<String>) -> [String] {
        groups.flatMap { group -> [String] in
            guard let title = group.title, folded.contains(Folds.list(title)) else { return group.ids }
            return []
        }
    }

    /// The row to select once the visible rows change: the same one if it still shows, else the
    /// one now in its place (so folding a group hands the selection to the row after it).
    static func selection(_ selected: String?, old: [String], new: [String]) -> String? {
        guard let selected else { return new.first }
        guard !new.contains(selected) else { return selected }
        if let index = old.firstIndex(of: selected), !new.isEmpty { return new[min(index, new.count - 1)] }
        return new.first
    }
}
