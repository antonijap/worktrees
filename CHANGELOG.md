# Changelog

## Unreleased

- Knows more tools that make worktrees: Codex, Cursor, Windsurf, Conductor, Copilot, Gemini CLI, Sculptor, Superset, Emdash, Vibe Kanban, Container Use and uzi, by folder or branch prefix. A worktree in any other hidden tool folder is tagged with that folder's name.
- Tidy up with nothing to clean no longer opens an empty sheet: the broom gives a quick sweep and says All tidy (or Checking GitHub… before GitHub has answered).

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
