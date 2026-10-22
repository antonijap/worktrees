# Changelog

## 1.0.0 (2026-10-22)

- First launch asks where your projects live, instead of assuming ~/Code
- Redesigned Settings, six pages
- Tidy up: pick stale days, protect branches, move to Trash
- GitHub: refresh interval, background checks, notifications
- Hide tool tags you don't use
- Menu bar icon and open at login
- Tells you when a new version is out
- Signed and notarized: opens with a double-click
- Install with Homebrew: `brew install --cask antonijap/tap/worktrees`
- Faster with hundreds of worktrees
- Warns when git isn't installed
- Fixed: a branch without a PR no longer counts as a failed lookup
- Fixed: Settings no longer opens by itself at launch

## 0.1.0 (2026-10-20)

First release.

**See every worktree**

- Scans any number of folders you pick in Settings and lists every git worktree, including ones that live outside them (Claude Code under `.claude/worktrees`, Supacode under `~/.supacode`), tagged with the tool that made them.
- An Overview that sorts worktrees into what needs attention, in progress, waiting for review, ready to merge, merged and safe to delete, and everything else.
- For each worktree: its pull request, reviewers and where they stand, labels, why it can't merge yet, checks with links to failing logs (and the failing lines for GitHub Actions), uncommitted files, changes since the main branch and the commits on the branch.
- Click a file to see its diff under the row, syntax coloured with a light and a dark code theme. Long lines wrap or scroll sideways.

**Clean up**

- Tidy up (⇧⌘T) lists merged, closed and stale worktrees across all repos with their disk size, and deletes the ones you tick in one go.
- Delete is instant, always asks first, keeps the branch, and warns about uncommitted work, ignored files like `.env` and commits not on GitHub.

**Get around**

- Open on GitHub (⇧⌘G) or in your editor (⌘O). Zed, VS Code, Cursor, Windsurf, Sublime Text, JetBrains IDEs and more, picked in Settings.
- Works from the keyboard: arrows, Return to open, ⌘F to filter by ticket, branch or PR number.
- Click any path, branch or value to copy it.
- Columns resize, collapse (⌃⌘S, ⌥⌘S) and fit small windows.
- Light, dark or system appearance. Quiet motion that respects Reduce Motion, and optional sounds.

**Under the hood**

- Stays fresh by watching each repo's git folder, and refreshes GitHub data every few minutes.
- One `git status` per worktree and one GitHub query per repo.
- Git never runs programs named in a scanned repo's config, and Delete checks a folder really is that repo's worktree before touching it.
- `--demo` and `--snapshot` for screenshots and checking changes without a window.
