# Contributing

Thanks for looking. This is a small app with strong opinions, so here is what they are.

## Design first

Every change is a design change, even plumbing. Decide how it looks, reads and behaves, then build it from the design system:

- Colours come from the tokens in `Theme.swift`. No hex in views. A new token needs a contrast check before it lands: text at least 4.5:1 against every background it sits on, icons and borders at least 3:1, in both light and dark mode.
- Type uses the `Font13` scale. Spacing uses `columnInset` and the paddings already in use. Corners stay on the 4, 6, 8 radius scale.
- Icons come from `Icons.swift`. Add new ones with `scripts/make-icons.py`, never by pasting SVG.
- Reuse what exists (`panel()`, `hairline`, `BarButtonStyle`, `IconButton`, `SectionLabel`, `MetaLine`) before making something new. If you do need a new component, make it reusable.
- Keep it quiet and compact. Rows are 28pt on purpose.

## Punctuation

No middots, em dashes or en dashes anywhere: UI copy, comments, commit messages, docs. Use a comma, a full stop or a space. `scripts/lint.sh` checks this.

## Before you open a pull request

- `swift build`, `swift test --no-parallel` and `scripts/lint.sh` all pass.
- Keyboard and VoiceOver work for anything you added.
- Try to break your own change first: empty lists, errors, a rescan while a sheet is open, a worktree that vanished from disk.
- If the UI changed, add before and after screenshots in light and dark. `--snapshot` below makes them.

## Running it

```bash
swift build
.build/debug/Worktrees            # bare executable, uses its own defaults domain
.build/debug/Worktrees --demo     # sample data, no disk or network access
.build/debug/Worktrees --dump ~/Code   # prints the scan as text
scripts/bundle.sh                 # builds build/Worktrees.app
```

## Tests

Tests never touch your own repos, settings, Trash or GitHub. They run on throwaway git repos that `scripts/make-fixtures.py` builds in a temp folder (worktrees merged, closed, failing, stale, fresh, dirty, ahead, unpushed, protected, made by Claude Code and Codex, a repo in `node_modules`, one in `sandbox/`, one five folders deep), with a fake `gh` (`scripts/fake-gh.py`) answering from canned pull requests, a settings suite of their own, and notifications and the Trash caught.

```bash
swift test --no-parallel          # unit and integration tests, about a minute
scripts/e2e-snapshots.sh          # pictures of each feature on the fixtures, in .build/e2e
scripts/test-app.sh               # opens "Worktrees Test", a separate copy on the fixtures, to try by hand
scripts/test-app.sh --clean       # quits it and deletes its fixtures and settings
scripts/test-app.sh --onboarding  # the test copy starting at first-launch onboarding
scripts/perf.sh                   # times a big setup (200 repos, 1,000 worktrees); not in CI
```

`--no-parallel` matters: the tests share process-wide hooks (the settings suite, the fake gh), so they run one at a time. The test copy of the app has its own bundle id, so its settings and folders live apart from the real app's, and it never posts notifications or registers a login item.

## Snapshots

`--snapshot` renders the app with sample data into a PNG at 2x without opening a window, taking focus, touching disk, GitHub or UserDefaults. Use it to check a visual change and for the README screenshots.

```bash
.build/debug/Worktrees --snapshot out.png                      # overview, light, 1280x800
.build/debug/Worktrees --snapshot out.png --dark               # dark mode
.build/debug/Worktrees --snapshot out.png --select /Users/sam/Code/storefront/.claude/worktrees/cart-badge
.build/debug/Worktrees --snapshot out.png --folder ledger-api  # a repo folder instead of the overview
.build/debug/Worktrees --snapshot out.png --size 1440x900
.build/debug/Worktrees --snapshot out.png --tidy               # the Tidy up sheet on its own
.build/debug/Worktrees --snapshot out.png --reveal             # hover-only controls drawn as if hovered
.build/debug/Worktrees --snapshot out.png --expand             # long lists in the detail column fully shown
.build/debug/Worktrees --snapshot out.png --diffs "changes:src/components/Summary.tsx,uncommitted:notes-1.md"   # diff panels open
.build/debug/Worktrees --snapshot out.png --chrome --click 90,16   # the app's real window, with a click sent at a point
.build/debug/Worktrees --snapshot out.png --collapsed          # folders column hidden
.build/debug/Worktrees --snapshot out.png --no-detail          # details column hidden
.build/debug/Worktrees --snapshot out.png --wrap off           # diff panels' Wrap choice: on, off or auto
.build/debug/Worktrees --snapshot out.png --chrome --wheel 700,500,-3,0,shift   # scroll wheel events at a point, to the scroll view under it (dx,dy in lines, optional Shift)
.build/debug/Worktrees --snapshot out.png --resize 700          # narrow (or widen) the window after loading, as a drag would
.build/debug/Worktrees --snapshot out.png --widths 180,480     # folders and worktrees column widths
.build/debug/Worktrees --snapshot out.png --tidy-empty          # Tidy up pressed with nothing to clean: the All tidy note
.build/debug/Worktrees --snapshot out.png --sheet-check         # exits 0 if the Tidy up sheet attaches to the window
.build/debug/Worktrees --snapshot out.png --real ~/Code          # real folders instead of sample data, still read-only
.build/debug/Worktrees --snapshot out.png --settings tidy       # a Settings page: general, folders, tidy, github, tools, advanced
.build/debug/Worktrees --snapshot out.png --real <dir> --tidy -staleDays 7   # a setting given for this run only, nothing saved
```

`--why-collapsed` starts the Why it failed block folded, so what is below it shows.

### README pictures

The hero is a snapshot put into a window by `scripts/make-hero.swift`: rounded corners, traffic lights and a hairline border. With `--card` (what the README uses) it sits on a light grey card (#F0F0F2, 80pt of padding) with a soft shadow, its corners rounded like the banner's and transparent outside them, the same grey in light and dark. `--pixel` puts it on a generated 16-bit style landscape instead, and without either it gets soft colour blobs. The hero is made by `scripts/make-tour.sh` along with the tour, below, so the two can't drift apart.

The banner and the social preview are the ember landscape (`--scene`: night, dawn, ocean, ember, mono or aurora) with the icon, the name and the tagline. The icon is a 3D render, `docs/icon-3d.png` (1024, transparent), made in Blender by `scripts/render-icon-3d.py` and scaled down from its 2048 output, so the banner can be redone without Blender. Type is Inter from [rsms.me/inter](https://rsms.me/inter) (SIL Open Font Licence), which must be installed (for example in `~/Library/Fonts` or `/Library/Fonts`); the font files are not in the repo. Inter Display is used for the title when it is installed.

```bash
# Only to change the icon render (needs Blender):
/Applications/Blender.app/Contents/MacOS/Blender -b --factory-startup -P scripts/render-icon-3d.py -- --out build/icon3d
sips -Z 1024 build/icon3d/icon-3d-tilt-back-ember.png --out docs/icon-3d.png
# The banner (3840x1500) and the social preview (2560x1280), ember by default:
swift scripts/make-banner.swift docs
```

The tour, `docs/tour-light.png` and `docs/tour-dark.png`, is an animated PNG in light and dark: the hero, moving. Four snapshots at the hero's size (the default selection, `--select $S`, the same with the diff open, which is the hero, and that frame dimmed with the `--tidy` sheet laid over its top) each go through `make-hero.swift --card` with the same flags, then ffmpeg joins them at 1.8 seconds each. The third frame is copied to `docs/hero-light.png` and `docs/hero-dark.png`. A GIF can't do this: its alpha is on or off, so the soft corners need a PNG. `--preview` also writes, to `build/readme-previews/`, the heroes and tours flattened on both of GitHub's page colours, side by side stills, and `index.html` to compare them. It needs ffmpeg and ImageMagick:

```bash
swift build
scripts/make-tour.sh --preview
```

Sample worktree paths are the ones in `DemoData.swift`. Reinstalling the app for a look without it stealing focus: `pkill -x Worktrees; scripts/bundle.sh --install && open -g /Applications/Worktrees.app` (or set `WORKTREES_BACKGROUND=1`).

## Releasing

`scripts/release.sh` builds the app, signs it and zips it, then prints the SHA-256 and writes the Homebrew cask to `build/worktrees.rb`. It notarizes when two things are on the Mac:

1. A "Developer ID Application" certificate in the keychain (Xcode, Settings, Accounts, Manage Certificates, plus, Developer ID Application).
2. Notary credentials saved as a keychain profile: `xcrun notarytool store-credentials worktrees-notary --apple-id <your Apple ID> --team-id <team id>`, with an app-specific password from account.apple.com.

Without them the zip is ad hoc signed, and the script says so. After the GitHub release is published, copy `build/worktrees.rb` over `Casks/worktrees.rb` in [antonijap/homebrew-tap](https://github.com/antonijap/homebrew-tap) and push it: the cask's checksum must match the zip on the release.
