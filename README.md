<img alt="Worktrees: a small, well designed Mac app for every git worktree. Written in Swift." src="docs/banner.png" width="1280">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/hero-dark.png">
  <img alt="Worktrees on a Mac: the Overview with a worktree whose checks are failing selected, and one of its changed files open as a coloured diff" src="docs/hero-light.png" width="1600">
</picture>

A small Mac app that finds every git worktree in your project folders and shows its pull request, its CI checks, its uncommitted files and what changed since the main branch.

I made it because I run a lot of worktrees at once, one per ticket, and kept losing track of which ones were done. Coding agents make even more of them, and they pile up.

## What it does

- Scans the folders you pick and lists each repo with its worktrees, including ones that live outside those folders.
- Shows whether each worktree's pull request is open, draft, merged or closed, whether its checks pass, who has reviewed it, its labels, and why it can't merge yet.
- Puts every worktree on one Overview page, sorted into needs attention, in progress, ready for review and everything else.
- Tells you which tool made each worktree: Claude Code, Codex, Cursor, Windsurf, Conductor, Copilot, Supacode and others, known by where they keep worktrees or how they name branches. A worktree in some other hidden tool folder, like `~/.foo`, is tagged `foo`. Type the tool name in the filter to see only those.
- Tidy up (⇧⌘T) lists everything that can go: merged, closed, or untouched for a month, as long as it is clean with nothing unpushed and no open PR. Tick what you want, see how much disk space it frees, delete in one go. Branches are kept.
- Shows each worktree's size on disk.
- Keeps itself fresh: it watches each repo for checkouts, commits and new worktrees, and asks GitHub again every five minutes while the app is in front.
- Lists a worktree's uncommitted files, its changed files with line counts, and the commits on its branch.
- Click a changed file to see its diff right there, syntax coloured, with line numbers and the usual green and red. Long lines wrap or scroll sideways. Click again to fold it.
- Opens a worktree on GitHub or in your editor, or deletes it. Every delete asks first, and deleting keeps the branch. Zed, VS Code, Cursor, Windsurf, Sublime Text, Nova, BBEdit, Xcode, Fleet, the JetBrains IDEs, CotEditor and TextEdit are found on their own; pick one in Settings.
- The columns can be dragged to the width you like, and the folder column can be hidden.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/tour-dark.png">
  <img alt="A short tour: the Overview, a worktree with failing checks, one of its diffs open, then the Tidy up sheet" src="docs/tour-light.png" width="1600">
</picture>

## Install

Download `Worktrees-<version>.zip` from the [latest release](https://github.com/antonijap/worktrees/releases), unzip it and drag Worktrees.app to Applications. The app is signed ad hoc, not notarized, so the first time you open it macOS will refuse a double-click. Right-click the app, choose Open, then Open again in the dialog. After that it opens normally.

To build it yourself you need macOS 14 or later and the Xcode command line tools:

```bash
git clone https://github.com/antonijap/worktrees.git
cd worktrees
scripts/bundle.sh --install
```

This builds the app and copies it to `/Applications`.

Pull request and checks data comes from the [GitHub CLI](https://cli.github.com). Install it and run `gh auth login` once. Without it, the app still shows everything local, but Tidy up stays empty, since it can't tell which branches have an open pull request.

## Use

The first launch scans `~/Code` if it exists. Add or remove folders in Settings (⌘,). A folder can hold many projects or be a single repo.

| Shortcut | Action                         |
| -------- | ------------------------------ |
| ⌘R       | Rescan                         |
| ⌘F       | Filter                         |
| ⇧⌘T      | Tidy up                        |
| ⇧⌘G      | Open on GitHub                 |
| ⌘O       | Open in your editor            |
| ⌘⌫       | Delete the selected worktree   |
| ⌃⌘S      | Show or hide the folder column |

## Demo mode

`Worktrees --demo` opens the app with five made-up repos and every state the app knows about, reading nothing from your disk and nothing from GitHub. It is what the screenshots are made from, and a quick way to see the app before pointing it at real projects.

```bash
swift build
.build/debug/Worktrees --demo
```

Deleting in demo mode only removes the row. `--snapshot out.png` renders the same sample data to a PNG without opening a window; the pictures here come from it (see [CONTRIBUTING.md](CONTRIBUTING.md)).

## How it works

Worktrees reads `git worktree list` and `git status` for each repo, and asks GitHub once per repo (`gh api graphql`) for the pull request on each branch. Nothing leaves your Mac except those GitHub requests. Git runs with the repo's own hooks, filesystem monitor, signature checks and external diff tools switched off, so a scanned repo's config never runs anything.

Sizes come from `du`, two folders at a time at low priority, after the scan has finished. They are measured again an hour later.

The app watches each repo's `.git` folder with FSEvents. A checkout, a commit, a fetch or a new worktree re-reads that one repo a second later. Edits to files in the working tree are not watched, so nothing fires while you type.

Delete first checks that the folder really is one of this repo's worktrees (its `.git` file and the repo's record of it must point at each other, and it must not be the repo, a scanned folder or your home folder), moves it aside, drops its entry with `git worktree remove`, then removes the files in the background. The row disappears at once, even for a worktree with a big `node_modules`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Short version: colours from `Theme.swift`, no dashes, try to break your own change.

## Credits

- Line icons from [Lucide](https://lucide.dev) (ISC).
- Pull request icons and the GitHub mark from [Octicons](https://primer.style/octicons) (MIT).
- The layout borrows from Zed's Delta, and the worktree icons follow [Supacode](https://supacode.sh).

## License

[MIT](LICENSE)
