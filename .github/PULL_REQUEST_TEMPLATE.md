## What changed

One or two sentences. Link the issue if there is one.

## Checklist

- [ ] Colours come from `Theme.swift` tokens. Any new token has its contrast checked (text 4.5:1, icons and borders 3:1, light and dark).
- [ ] Type uses the `Font13` scale, spacing uses `columnInset` and the existing paddings, corners stay on 4, 6, 8.
- [ ] Icons were added through `scripts/make-icons.py`, not pasted by hand.
- [ ] Existing components reused where they fit (`panel()`, `hairline`, `BarButtonStyle`, `IconButton`, `SectionLabel`, `MetaLine`).
- [ ] No middots, em dashes or en dashes anywhere. `scripts/lint.sh` passes.
- [ ] `swift build` passes.
- [ ] Keyboard and VoiceOver work for anything new.
- [ ] I tried to break my own change (empty states, errors, a rescan mid-action) before opening this.

## Screenshots

Before and after, light and dark, if the UI changed.
