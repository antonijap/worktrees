import Foundation
import Testing
@testable import Worktrees

extension All {
    /// Section headings that fold what is under them.
    @Suite @MainActor struct FoldTests {
        @Test func foldsAreRememberedAcrossLaunches() throws {
            let name = "worktrees-folds-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { defaults.removePersistentDomain(forName: name) }

            let first = Folds(defaults: defaults)
            #expect(!first.isFolded(Folds.list("In progress")))
            first.toggle(Folds.list("In progress"))
            first.toggle(Folds.detail("commits"))
            #expect(first.isFolded(Folds.list("In progress")))

            // A new launch reads them back.
            let second = Folds(defaults: defaults)
            #expect(second.folded == [Folds.list("In progress"), Folds.detail("commits")])
            second.toggle(Folds.list("In progress"))
            #expect(Folds(defaults: defaults).folded == [Folds.detail("commits")])
        }

        @Test func sampleRunsKeepFoldsInMemory() {
            let folds = Folds(defaults: nil)
            folds.toggle(Folds.detail("changes"))
            #expect(folds.isFolded(Folds.detail("changes")))
        }

        @Test func foldedGroupsLeaveTheListAndTheArrowKeys() {
            let groups: [(title: String?, ids: [String])] = [
                (nil, ["main"]),
                ("Needs attention", ["a", "b"]),
                ("In progress", ["c"]),
                ("Everything else", ["d", "e"]),
            ]
            #expect(FoldedList.visible(groups: groups, folded: []) == ["main", "a", "b", "c", "d", "e"])
            #expect(FoldedList.visible(groups: groups, folded: [Folds.list("In progress"), Folds.list("Everything else")]) == ["main", "a", "b"])
            // The untitled main checkout can't be folded, and detail folds don't touch the list.
            #expect(FoldedList.visible(groups: groups, folded: [Folds.detail("Needs attention")]) == ["main", "a", "b", "c", "d", "e"])
        }

        @Test func foldingAGroupMovesTheSelectionToAVisibleRow() {
            let before = ["a", "b", "c", "d", "e"]
            // "c" and "d" were In progress; that group folds.
            let after = ["a", "b", "e"]
            #expect(FoldedList.selection("c", old: before, new: after) == "e", "the row now in its place")
            #expect(FoldedList.selection("b", old: before, new: after) == "b", "a visible selection stays")
            #expect(FoldedList.selection("e", old: before, new: ["a"]) == "a", "past the end: the last one")
            #expect(FoldedList.selection("c", old: before, new: []) == nil, "everything folded: nothing to act on")
            #expect(FoldedList.selection(nil, old: [], new: after) == "a")
        }

        @Test func keysDontDependOnChangingTitles() {
            // "Changes since origin/main" and "Changes since origin/develop" fold together.
            #expect(Folds.detail("changes") == "detail:changes")
            #expect(Folds.list("Needs attention") != Folds.detail("Needs attention"))
        }
    }
}
