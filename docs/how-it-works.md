# How Worktrees works

Worktrees reads `git worktree list` and `git status` for each repo, and asks GitHub once per repo (`gh api graphql`) for the pull request on each branch. Once a day it also asks GitHub, through gh, for the latest Worktrees release (`gh api repos/antonijap/worktrees/releases/latest`); turn that off in Settings, General. Nothing else leaves your Mac. Git runs with the repo's own hooks, filesystem monitor, signature checks and external diff tools switched off, so a scanned repo's config never runs anything.

Sizes come from `du`, two folders at a time at low priority, after the scan has finished. They are measured again an hour later, or as often as Settings says.

On a big setup (200 repos, 1,000 worktrees, measured with `scripts/perf.sh` on an 18-core M-series Mac) the scan takes about 8 seconds, the GitHub pass 3 to 4 and disk sizes 5, using about 65 MB of memory. git runs on half the cores, 4 to 8 at a time, so a smaller Mac scans more slowly.

The app watches each repo's `.git` folder with FSEvents. A checkout, a commit, a fetch or a new worktree re-reads that one repo a second later. Edits to files in the working tree are not watched, so nothing fires while you type.

Delete first checks that the folder really is one of this repo's worktrees (its `.git` file and the repo's record of it must point at each other, and it must not be the repo, a scanned folder or your home folder), moves it aside, drops its entry with `git worktree remove`, then removes the files in the background. The row disappears at once, even for a worktree with a big `node_modules`.


## Demo mode

`Worktrees --demo` opens the app with five made-up repos and every state the app knows about, reading nothing from your disk and nothing from GitHub. It is what the screenshots are made from, and a quick way to see the app before pointing it at real projects.

```bash
swift build
.build/debug/Worktrees --demo
```

Deleting in demo mode only removes the row. `--snapshot out.png` renders the same sample data to a PNG without opening a window; the pictures here come from it (see [CONTRIBUTING.md](CONTRIBUTING.md)).
