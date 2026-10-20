import Foundation

/// Sample repos for `Worktrees --demo`: made-up projects, every state covered, nothing read
/// from disk or GitHub. For screenshots and for trying the app without a project folder.
enum DemoData {
    /// `Worktrees --demo`: sample data only, no disk access, no GitHub.
    static let isOn = CommandLine.arguments.contains("--demo") || (Snapshot.isOn && !CommandLine.arguments.contains("--real"))
    static let home = "/Users/sam"
    static let viewer = "sam"

    static func repos() -> [Repo] {
        let now = Date()
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }
        func commit(_ subject: String, days: Double, hash: String) -> Commit {
            Commit(hash: hash, subject: subject, relative: relative(days), date: ago(days))
        }
        let checksRun = "https://github.com/example/storefront/actions/runs/7351"
        func check(_ name: String, _ result: String, run: String? = nil) -> PullRequest.CheckItem {
            PullRequest.CheckItem(
                conclusion: result == "PENDING" ? nil : result, status: result == "PENDING" ? "IN_PROGRESS" : "COMPLETED",
                state: nil, name: name, detailsUrl: (run ?? checksRun) + "/job/\(abs(name.hashValue) % 9000 + 1000)", workflowName: "CI"
            )
        }
        func status(upstream: String? = "origin/x", ahead: Int = 0, behind: Int = 0, changed: Int = 0,
                    untracked: Int = 0, conflicted: Int = 0, aheadKnown: Bool = true) -> LocalStatus {
            LocalStatus(upstream: upstream, ahead: ahead, behind: behind, aheadKnown: upstream != nil && aheadKnown,
                        changed: changed, untracked: untracked, conflicted: conflicted)
        }
        func pr(_ number: Int, _ title: String, state: String = "OPEN", draft: Bool = false, repo: String, branch: String,
                review: String? = nil, checks: [PullRequest.CheckItem]? = nil, by author: String = viewer, updated: Double = 0.3,
                labels: [String] = [], reviews: [PullRequest.Review] = [], merge: String? = nil, mergeable: String? = nil) -> PullRequest {
            PullRequest(
                number: number, title: title, state: state, isDraft: draft,
                url: "https://github.com/example/\(repo)/pull/\(number)", headRefName: branch,
                reviewDecision: review, statusCheckRollup: checks,
                author: author, baseRefName: "main", updatedAt: ago(updated), labels: labels, reviews: reviews,
                mergeStateStatus: merge, mergeable: mergeable
            )
        }
        func review(_ name: String, _ state: PullRequest.Review.State) -> PullRequest.Review { PullRequest.Review(name: name, state: state) }
        func wt(_ repo: String, _ branch: String, path: String? = nil, main: Bool = false, missing: Bool = false, status: LocalStatus,
                last: Commit, pr: PullRequest? = nil) -> Worktree {
            let folder = path ?? "\(home)/Code/\(repo)-\(branch.split(separator: "/").last.map(String.init) ?? branch)"
            var w = Worktree(path: folder, head: last.hash + "000000000000000000000000000000000", branch: branch,
                             isMain: main, isLocked: false, isPrunable: missing)
            w.status = status
            w.lastCommit = last
            w.pullRequest = pr
            return w
        }
        let origin = { (slug: String) in [Remote(name: "origin", url: "git@github.com:\(slug).git")] }
        let passing = [check("Build", "SUCCESS"), check("Unit tests", "SUCCESS"), check("Lint", "SUCCESS"), check("Deploy preview", "SKIPPED")]
        let failing = [check("Build", "SUCCESS"), check("Unit tests", "FAILURE"), check("Lint", "SUCCESS")]
        let running = [check("Build", "SUCCESS"), check("Unit tests", "PENDING"), check("Lint", "PENDING")]

        let storefront = Repo(
            path: "\(home)/Code/storefront", name: "storefront", group: "Code", remotes: origin("example/storefront"),
            worktrees: [
                wt("storefront", "main", path: "\(home)/Code/storefront", main: true,
                   status: status(upstream: "origin/main"), last: commit("Bump dependencies", days: 0.2, hash: "a1b2c3d")),
                wt("storefront", "feature/SHOP-412-checkout-redesign",
                   status: status(upstream: "origin/feature/SHOP-412-checkout-redesign"),
                   last: commit("Align the summary card with the new spacing scale", days: 0.4, hash: "d4e5f6a"),
                   pr: pr(1842, "SHOP-412 Checkout redesign", repo: "storefront", branch: "feature/SHOP-412-checkout-redesign", review: "REVIEW_REQUIRED", checks: passing,
                          updated: 0.4, labels: ["design", "checkout"], reviews: [review("mira", .commented), review("jonas", .waiting)], merge: "BLOCKED")),
                wt("storefront", "fix/SHOP-430-cart-badge-count",
                   path: "\(home)/Code/storefront/.claude/worktrees/cart-badge",
                   status: status(upstream: "origin/fix/SHOP-430-cart-badge-count"),
                   last: commit("Count bundles once in the cart badge", days: 1.2, hash: "b7c8d9e"),
                   pr: pr(1851, "SHOP-430 Cart badge counts bundles twice", repo: "storefront", branch: "fix/SHOP-430-cart-badge-count", review: "REVIEW_REQUIRED", checks: failing,
                          updated: 0.1, labels: ["bug"], reviews: [review("mira", .waiting)], merge: "BLOCKED")),
                wt("storefront", "feature/SHOP-398-gift-cards",
                   path: "\(home)/.supacode/repos/storefront/gift-cards",
                   status: status(upstream: "origin/feature/SHOP-398-gift-cards"),
                   last: commit("Gift card balance endpoint", days: 3, hash: "c0ffee1"),
                   pr: pr(1799, "SHOP-398 Gift cards", state: "MERGED", repo: "storefront", branch: "feature/SHOP-398-gift-cards", checks: passing)),
                wt("storefront", "feature/SHOP-405-wishlist",
                   status: status(upstream: "origin/feature/SHOP-405-wishlist", changed: 2),
                   last: commit("Wishlist sharing", days: 6, hash: "5a7e1e5"),
                   pr: pr(1812, "SHOP-405 Wishlist", state: "MERGED", repo: "storefront", branch: "feature/SHOP-405-wishlist", checks: passing)),
                wt("storefront", "chore/SHOP-401-drop-legacy-theme",
                   status: status(upstream: "origin/chore/SHOP-401-drop-legacy-theme"),
                   last: commit("Remove the legacy theme switcher", days: 41, hash: "0ddba11"),
                   pr: pr(1780, "SHOP-401 Drop the legacy theme", state: "CLOSED", repo: "storefront", branch: "chore/SHOP-401-drop-legacy-theme")),
                wt("storefront", "spike/SHOP-377-search-index",
                   missing: true,
                   status: status(upstream: "origin/spike/SHOP-377-search-index"),
                   last: commit("Try the hosted search index", days: 30, hash: "deadbe1")),
            ]
        )

        let ledger = Repo(
            path: "\(home)/Code/ledger-api", name: "ledger-api", group: "Code", remotes: origin("example/ledger-api"),
            worktrees: [
                wt("ledger-api", "main", path: "\(home)/Code/ledger-api", main: true,
                   status: status(upstream: "origin/main", behind: 2), last: commit("Release 4.12", days: 2, hash: "f00d001")),
                wt("ledger-api", "feature/LED-77-batch-exports",
                   path: "\(home)/Code/ledger-api/.claude/worktrees/batch-exports",
                   status: status(upstream: "origin/feature/LED-77-batch-exports"),
                   last: commit("Stream CSV rows instead of buffering", days: 0.1, hash: "1ead001"),
                   pr: pr(312, "LED-77 Batch exports", repo: "ledger-api", branch: "feature/LED-77-batch-exports", checks: running)),
                wt("ledger-api", "feature/LED-82-statement-pdf",
                   status: status(upstream: "origin/feature/LED-82-statement-pdf"),
                   last: commit("First pass at the PDF layout", days: 0.3, hash: "9d7f001"),
                   pr: pr(318, "LED-82 Statement PDF", draft: true, repo: "ledger-api", branch: "feature/LED-82-statement-pdf", checks: passing)),
                wt("ledger-api", "fix/LED-79-timezones",
                   status: status(upstream: "origin/fix/LED-79-timezones", changed: 3, untracked: 1),
                   last: commit("Store timestamps in UTC", days: 0.2, hash: "7a1e5e5")),
                wt("ledger-api", "fix/LED-80-rounding",
                   status: status(upstream: nil),
                   last: commit("Round half to even in totals", days: 0.6, hash: "2bad5e7")),
                wt("ledger-api", "fix/LED-81-csv-quotes",
                   status: status(upstream: "origin/fix/LED-81-csv-quotes", ahead: 2),
                   last: commit("Quote fields with commas", days: 0.8, hash: "c5b0a1e")),
                wt("ledger-api", "feature/LED-64-audit-log",
                   path: "\(home)/.supacode/repos/ledger-api/audit-log",
                   status: status(upstream: "origin/feature/LED-64-audit-log"),
                   last: commit("Record who changed a ledger entry", days: 1.5, hash: "a0d1710"),
                   pr: pr(301, "LED-64 Audit log", repo: "ledger-api", branch: "feature/LED-64-audit-log", review: "APPROVED", checks: passing,
                          by: "jonas", updated: 1.4, reviews: [review("sam", .approved), review("mira", .approved)], merge: "BEHIND")),
            ]
        )

        let kiosk = Repo(
            path: "\(home)/Code/kiosk-app", name: "kiosk-app", group: "Code", remotes: origin("example/kiosk-app"),
            worktrees: [
                wt("kiosk-app", "main", path: "\(home)/Code/kiosk-app", main: true,
                   status: status(upstream: "origin/main"), last: commit("Point release 2.3.1", days: 5, hash: "beefed1")),
                wt("kiosk-app", "feature/KSK-15-idle-screen",
                   path: "\(home)/Code/kiosk-app/.claude/worktrees/idle-screen",
                   status: status(upstream: "origin/feature/KSK-15-idle-screen"),
                   last: commit("Dim the idle screen after two minutes", days: 0.9, hash: "1d1e5c1"),
                   pr: pr(58, "KSK-15 Idle screen", repo: "kiosk-app", branch: "feature/KSK-15-idle-screen", review: "CHANGES_REQUESTED", checks: passing,
                          updated: 0.9, labels: ["ux"], reviews: [review("jonas", .changesRequested), review("mira", .approved)], merge: "BLOCKED")),
                wt("kiosk-app", "fix/KSK-21-receipt-printer",
                   status: status(upstream: "origin/fix/KSK-21-receipt-printer", changed: 1, conflicted: 2),
                   last: commit("Retry the printer handshake", days: 0.3, hash: "9e1c0de"),
                   pr: pr(61, "KSK-21 Receipt printer drops the first job", repo: "kiosk-app", branch: "fix/KSK-21-receipt-printer", checks: passing,
                          by: "mira", updated: 0.3, reviews: [review("sam", .waiting)], merge: "DIRTY", mergeable: "CONFLICTING")),
                wt("kiosk-app", "feature/KSK-9-dark-mode",
                   status: status(upstream: "origin/feature/KSK-9-dark-mode"),
                   last: commit("Dark mode tokens", days: 12, hash: "da4c0de"),
                   pr: pr(49, "KSK-9 Dark mode", state: "MERGED", repo: "kiosk-app", branch: "feature/KSK-9-dark-mode", checks: passing)),
            ]
        )

        let docs = Repo(
            path: "\(home)/Code/handbook", name: "handbook", group: "Code", remotes: origin("example/handbook"),
            worktrees: [
                wt("handbook", "main", path: "\(home)/Code/handbook", main: true,
                   status: status(upstream: "origin/main"), last: commit("Onboarding checklist", days: 9, hash: "5a1ad00")),
                wt("handbook", "docs/HB-12-oncall-rota",
                   path: "\(home)/.supacode/repos/handbook/oncall-rota",
                   status: status(upstream: "origin/docs/HB-12-oncall-rota"),
                   last: commit("Rota for Q3", days: 48, hash: "0ca11ed"),
                   pr: pr(23, "HB-12 On-call rota", state: "MERGED", repo: "handbook", branch: "docs/HB-12-oncall-rota")),
                wt("handbook", "docs/HB-19-expense-policy",
                   status: status(upstream: "origin/docs/HB-19-expense-policy"),
                   last: commit("Expense policy draft", days: 36, hash: "e4a3b2c")),
            ]
        )

        let toolkit = Repo(
            path: "\(home)/Code/design-toolkit", name: "design-toolkit", group: "Code", remotes: origin("example/design-toolkit"),
            worktrees: [
                wt("design-toolkit", "main", path: "\(home)/Code/design-toolkit", main: true,
                   status: status(upstream: "origin/main"), last: commit("Icon set 2.0", days: 20, hash: "1c0ff33")),
            ]
        )

        // Long names, for checking that nothing wraps or spills at narrow widths.
        let longName = "customer-experience-platform-web"
        let longBranch = "feature/CXP-20481-lidar-room-scan-experiment-with-depth-fallback"
        let platform = Repo(
            path: "\(home)/Code/\(longName)", name: longName, group: "Code", remotes: origin("example/\(longName)"),
            worktrees: [
                wt(longName, "main", path: "\(home)/Code/\(longName)", main: true,
                   status: status(upstream: "origin/main"), last: commit("Release 12.4.0", days: 1, hash: "9a8b7c6")),
                wt(longName, longBranch,
                   path: "\(home)/Code/\(longName)/.claude/worktrees/lidar-room-scan-experiment-with-depth-fallback",
                   status: status(upstream: "origin/\(longBranch)", changed: 3, untracked: 2),
                   last: commit("Fall back to depth data when the LiDAR mesh has holes in it", days: 0.2, hash: "d3c4b5a"),
                   pr: pr(20481, "CXP-20481 LiDAR room scan experiment with depth fallback", repo: longName, branch: longBranch,
                          review: "REVIEW_REQUIRED", checks: passing, by: "jonas", updated: 0.2,
                          labels: ["experiment", "needs-design-review", "ios"],
                          reviews: [review("mira", .waiting), review("sam", .waiting), review("platform-reviewers", .waiting)], merge: "BLOCKED")),
            ]
        )

        return [storefront, ledger, kiosk, docs, toolkit, platform]
    }

    /// Fake folder sizes, keyed by worktree path.
    static func sizes(for repos: [Repo]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for wt in repos.flatMap(\.worktrees) where !wt.isPrunable {
            // Stable per path, so a size doesn't change after a row is deleted.
            var seed: UInt64 = 1469598103934665603
            for byte in wt.path.utf8 { seed = (seed ^ UInt64(byte)) &* 1099511628211 }
            let mb = Int64(80 + (seed >> 40) % 1400)
            result[wt.path] = (wt.isMain ? mb * 3 : mb) * 1_048_576
        }
        return result
    }

    /// A believable failed-step tail for the sample failing run.
    @MainActor static func seedLogs() {
        CheckLogs.shared.seed(runID: "7351", lines: [
            "FAIL src/cart/badge.test.ts",
            "  Cart badge",
            "    counts a bundle once (12 ms)",
            "      expect(received).toBe(expected)",
            "      Expected: 1",
            "      Received: 2",
            "        at Object.<anonymous> (src/cart/badge.test.ts:41:27)",
            "Tests: 1 failed, 86 passed, 87 total",
            "Error: Process completed with exit code 1.",
        ])
    }

    /// Fake detail contents, so the detail column has files and commits to show.
    static func details(for wt: Worktree) -> WorktreeDetails {
        let last = wt.lastCommit ?? Commit(hash: "0000000", subject: "", relative: "", date: .now)
        var changes = wt.isMain ? [] : [
            FileChange(path: "src/features/\(wt.branchName.title.lowercased().replacingOccurrences(of: " ", with: "-"))/index.ts", added: 142, removed: 18),
            FileChange(path: "src/components/Summary.tsx", added: 36, removed: 9),
            FileChange(path: "src/styles/tokens.css", added: 4, removed: 1),
            FileChange(path: "ios/CartBadgeView.swift", added: 12, removed: 3),
            FileChange(path: "scripts/export_batches.py", added: 9, removed: 2),
            FileChange(path: ".github/workflows/ci.yml", added: 3, removed: 1),
            FileChange(path: "docs/screenshot.png", added: nil, removed: nil),
        ]
        // One big branch, so the capped list has something to show more of.
        if wt.branch == "feature/SHOP-412-checkout-redesign" {
            changes += (1...50).map { FileChange(path: "src/checkout/steps/Step\($0).tsx", added: $0 * 3, removed: $0 % 4) }
        }
        var uncommitted: [UncommittedFile] = []
        if let s = wt.status {
            uncommitted += (0..<s.conflicted).map { UncommittedFile(code: "UU", path: "src/conflict-\($0 + 1).ts") }
            uncommitted += (0..<s.changed).map { UncommittedFile(code: " M", path: "src/edited-\($0 + 1).ts") }
            uncommitted += (0..<s.untracked).map { UncommittedFile(code: "??", path: "notes-\($0 + 1).md") }
        }
        let age = Date().timeIntervalSince(last.date) / 86_400
        let commits = wt.isMain ? [last] : [
            last,
            Commit(hash: "7f3a9c1", subject: "Wire up the new endpoint", relative: relative(age + 1), date: last.date.addingTimeInterval(-86_400)),
            Commit(hash: "3c1d2e4", subject: "Scaffold", relative: relative(age + 2), date: last.date.addingTimeInterval(-2 * 86_400)),
        ]
        return WorktreeDetails(base: "origin/main", changes: changes, commits: commits, uncommitted: uncommitted,
                               existing: Set(changes.map(\.path) + uncommitted.map(\.path)))
    }

    private static func relative(_ days: Double) -> String {
        func plural(_ n: Int, _ unit: String) -> String { "\(n) \(unit)\(n == 1 ? "" : "s") ago" }
        if days < 1 { return plural(max(1, Int(days * 24)), "hour") }
        if days < 14 { return plural(max(1, Int(days)), "day") }
        if days < 60 { return plural(Int(days / 7), "week") }
        return plural(Int(days / 30), "month")
    }

    /// Sample diffs, as git would print them, so the diff panel has something to show.
    static func diff(for path: String, scope: DiffLoader.Scope) -> FileDiff {
        if case .untracked = scope {
            return DiffLoader.parse("""
            @@ -0,0 +1,8 @@
            +# Notes
            +
            +- Check the badge count after adding a bundle **twice**
            +- Ask design about the *empty* cart state
            +- Release notes: mention the `badgeCount` fix
            +
            +> Bundles count once, see [SHOP-430](https://example.com/SHOP-430).
            +
            """)
        }
        if path.hasSuffix(".png") { return FileDiff(body: .binary) }
        if path.hasSuffix("tokens.css") {
            return DiffLoader.parse("""
            @@ -12,8 +12,11 @@ :root {
               --space-2: 8px;
               --space-3: 12px;
               --space-4: 16px;
            +  --space-5: 20px;
            +  --space-6: 24px;
               --radius-sm: 4px;
               --radius-md: 6px;
            -  --radius-lg: 10px;
            +  --radius-lg: 8px;
            +  --radius-pill: 999px;
             }
            """)
        }
        if path.hasSuffix(".swift") {
            return DiffLoader.parse("""
            @@ -1,14 +1,23 @@
             import SwiftUI
             
            -/// The cart icon with a count.
            +/* The cart icon with a count. A bundle counts once,
            +   however many items it holds. */
             struct CartBadgeView: View {
                 let items: [CartItem]
            +    @Environment(\\.accessibilityReduceMotion) private var reduceMotion
             
            -    private var count: Int { items.reduce(0) { $0 + $1.quantity } }
            +    private var count: Int {
            +        items.reduce(0) { $0 + ($1.isBundle ? 1 : $1.quantity) }
            +    }
             
                 var body: some View {
                     Image(systemName: "cart")
                         .overlay(alignment: .topTrailing) {
            -                Text("\\(count)").font(.caption2)
            +                if count > 0 {
            +                    Text("\\(min(count, 99))")
            +                        .font(.caption2.monospacedDigit())
            +                        .padding(2)
            +                }
                         }
            +            .accessibilityLabel("Cart, \\(count) items")
                 }
             }
            """)
        }
        if path.hasSuffix(".py") {
            return DiffLoader.parse("""
            @@ -10,12 +10,19 @@ from ledger import Batch
             
             
            -def export(batches):
            -    return [b.to_row() for b in batches]
            +def export(batches: list[Batch], limit: int = 500) -> list[dict]:
            +    \"\"\"Rows for the CSV export, oldest first.
            +
            +    Batches past `limit` wait for the next run.
            +    \"\"\"
            +    ordered = sorted(batches, key=lambda b: b.created_at)
            +    return [b.to_row() for b in ordered[:limit]]
             
             
             @retry(times=3)
             def upload(rows, bucket="exports"):
            -    client.put(bucket, rows)
            +    # Empty runs still write a file, so the job shows as done.
            +    client.put(bucket, rows or [], timeout=30.0)
            """)
        }
        if path.hasSuffix(".yml") {
            return DiffLoader.parse("""
            @@ -4,9 +4,11 @@ on:
             jobs:
               test:
                 runs-on: macos-14
            -    timeout-minutes: 20
            +    timeout-minutes: 15
            +    env:
            +      CI: true  # quieter test output
                 steps:
                   - uses: actions/checkout@v4
                   - run: "npm ci && npm test"
            """)
        }
        if path.hasSuffix("Summary.tsx") {
            return DiffLoader.parse("""
            @@ -1,7 +1,8 @@
             import { useMemo } from "react";
             import { useCart } from "../cart/useCart";
            -import { formatPrice } from "../utils";
            +import { formatPrice, pluralize } from "../utils";
            +import { Badge } from "./Badge";
             
             export function Summary() {
               const { items, total } = useCart();
            @@ -18,14 +19,19 @@ export function Summary() {
               return (
                 <section className="summary">
            -      <h2>Order summary</h2>
            -      <p>{items.length} items</p>
            +      <header className="summary-header">
            +        <h2>Order summary</h2>
            +        <Badge count={count} />
            +      </header>
            +      <p>{pluralize(count, "item")}</p>
                   <ul>
                     {items.map((item) => (
            -          <li key={item.id}>{item.name}</li>
            +          <li key={item.id}>
            +            {item.name} <span className="muted">x{item.quantity}</span>
            +          </li>
                     ))}
                   </ul>
            -      <strong>{formatPrice(total)}</strong>
            +      <strong aria-live="polite">{formatPrice(total)}</strong>
                 </section>
               );
             }
            """)
        }
        if path.hasSuffix("index.ts") || path.hasPrefix("src/checkout") {
            return DiffLoader.parse("""
            @@ -3,6 +3,7 @@ import type { CartItem } from "./types";
             
             export function badgeCount(items: CartItem[]): number {
            -  return items.reduce((sum, item) => sum + item.quantity, 0);
            +  // A bundle is one line in the cart whatever it holds.
            +  return items.reduce((sum, item) => sum + (item.bundle ? 1 : item.quantity), 0);
             }
             
             export function isEmpty(items: CartItem[]): boolean {
            @@ -41,7 +42,7 @@ export function merge(a: CartItem[], b: CartItem[]): CartItem[] {
                 const existing = result.find((item) => item.id === incoming.id);
                 if (existing) {
            -      existing.quantity += incoming.quantity;
            +      existing.quantity = existing.bundle ? existing.quantity : existing.quantity + incoming.quantity;
                 } else {
                   result.push({ ...incoming });
                 }
            """)
        }
        return DiffLoader.parse("""
        @@ -8,7 +8,7 @@ export const settings = {
           retries: 3,
           timeoutMs: 8000,
        -  verbose: false,
        +  verbose: true,
           endpoint: "https://api.example.com",
         };
        """)
    }
}
