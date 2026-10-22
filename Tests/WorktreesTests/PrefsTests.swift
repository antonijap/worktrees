import Foundation
import Testing
@testable import Worktrees

extension All {
    /// Settings read from their own suite: defaults, out-of-range values, list cleanup, reset.
    @Suite @MainActor struct PrefsTests {
        private func withSuite(_ body: (UserDefaults) throws -> Void) rethrows {
            TestMode.underTests = true
            let name = "worktrees-prefs-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            Prefs.testStore = defaults
            defer {
                Prefs.testStore = nil
                defaults.removePersistentDomain(forName: name)
            }
            try body(defaults)
        }

        @Test func defaultsWhenNothingIsSaved() {
            withSuite { _ in
                #expect(Prefs.staleDays == 30)
                #expect(Prefs.staleAfter == 30 * 86_400)
                #expect(Prefs.preselectStale == false)
                #expect(Prefs.protectedBranches == ["main", "master", "develop", "dev", "trunk"])
                #expect(Prefs.trashOnDelete == false)
                #expect(Prefs.githubRefreshInterval == TimeInterval(5 * 60))
                #expect(Prefs.githubInBackground == false)
                #expect(Prefs.hiddenTools.isEmpty)
                #expect(Prefs.scanDepth == 4)
                #expect(Prefs.skippedFolders == Set(Prefs.Default.skippedFolders))
                #expect(Prefs.sizeMaxAge == TimeInterval(60 * 60))
                #expect(Prefs.menuBarIcon == false)
            }
        }

        @Test func valuesOffTheMenuFallBackToTheDefault() {
            withSuite { d in
                d.set(3, forKey: Prefs.Key.staleDays)
                d.set(99, forKey: Prefs.Key.scanDepth)
                d.set(7, forKey: Prefs.Key.githubRefreshMinutes)
                d.set(-1, forKey: Prefs.Key.sizeMaxAgeMinutes)
                #expect(Prefs.staleDays == 30)
                #expect(Prefs.scanDepth == 4)
                #expect(Prefs.githubRefreshInterval == TimeInterval(5 * 60))
                #expect(Prefs.sizeMaxAge == TimeInterval(60 * 60))
            }
        }

        @Test func everyChoiceOnTheMenuIsKept() {
            withSuite { d in
                for days in Prefs.staleDayChoices {
                    d.set(days, forKey: Prefs.Key.staleDays)
                    #expect(Prefs.staleDays == days)
                }
                d.set(0, forKey: Prefs.Key.githubRefreshMinutes)
                #expect(Prefs.githubRefreshInterval == nil, "0 is Manually")
                d.set(15, forKey: Prefs.Key.githubRefreshMinutes)
                #expect(Prefs.githubRefreshInterval == TimeInterval(15 * 60))
                d.set(0, forKey: Prefs.Key.sizeMaxAgeMinutes)
                #expect(Prefs.sizeMaxAge == nil, "0 is Never")
                d.set(6, forKey: Prefs.Key.scanDepth)
                #expect(Prefs.scanDepth == 6)
            }
        }

        @Test func numbersSavedAsTextAreRead() {
            withSuite { d in
                d.set("7", forKey: Prefs.Key.staleDays)
                d.set("5", forKey: Prefs.Key.scanDepth)
                d.set("abc", forKey: Prefs.Key.githubRefreshMinutes)
                #expect(Prefs.staleDays == 7)
                #expect(Prefs.scanDepth == 5)
                #expect(Prefs.githubRefreshInterval == TimeInterval(5 * 60), "text that isn't a number falls back")
            }
        }

        @Test func branchListsAreTrimmedAndDeduplicated() {
            withSuite { d in
                d.set([" develop", "main ", "", "main", "  "], forKey: Prefs.Key.protectedBranches)
                #expect(Prefs.protectedBranches == ["develop", "main"])
            }
        }

        @Test func anEmptiedBranchListStaysEmpty() {
            withSuite { d in
                d.set([String](), forKey: Prefs.Key.protectedBranches)
                #expect(Prefs.protectedBranches.isEmpty)
            }
        }

        @Test func skippedFoldersOnlyAddToTheBuiltInOnes() {
            withSuite { d in
                d.set(["sandbox", "a/b", " cache "], forKey: Prefs.Key.skippedFolders)
                #expect(Prefs.extraSkippedFolders == ["sandbox", "cache"], "a name with a slash can never match")
                #expect(Prefs.skippedFolders.isSuperset(of: Prefs.Default.skippedFolders))
                #expect(Prefs.skippedFolders.contains("Library"))
                #expect(Prefs.skippedFolders.contains("sandbox"))
            }
        }

        @Test func resetPutsEverySettingBack() {
            withSuite { d in
                d.set(7, forKey: Prefs.Key.staleDays)
                d.set(true, forKey: Prefs.Key.trashOnDelete)
                d.set(["claude-code"], forKey: Prefs.Key.hiddenTools)
                d.set(["release"], forKey: Prefs.Key.protectedBranches)
                d.set(true, forKey: Prefs.Key.menuBarIcon)
                Prefs.reset()
                for key in Prefs.Key.all { #expect(d.object(forKey: key) == nil, "\(key) left behind") }
                #expect(Prefs.staleDays == 30)
                #expect(Prefs.trashOnDelete == false)
            }
        }

        @Test func cleanedKeepsOrder() {
            #expect(Prefs.cleaned(["b", "a", " b", "c"]) == ["b", "a", "c"])
        }
    }
}
