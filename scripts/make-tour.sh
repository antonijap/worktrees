#!/bin/bash
# Makes the README hero and tour from one code path, so they can't drift apart:
# docs/hero-light.png and docs/hero-dark.png, and docs/tour-light.png and docs/tour-dark.png,
# animated PNGs (APNG). Four --snapshot frames at the hero's size (the default selection, a
# worktree with failing checks, the same with one diff open, then that frame dimmed with the
# Tidy up sheet over its top) each go through make-hero.swift with the same flags. The third
# frame is the hero, so the tour is the hero, moving: same grey card, padding, window chrome and
# shadow. 1.8 seconds a frame.
# Needs ffmpeg and ImageMagick (magick). Run from the repo root after `swift build`.
# `--preview` also writes, to build/readme-previews/, each tour and each hero and tour still
# flattened on GitHub's page colours (#ffffff and #0d1117), and index.html to compare them.
set -euo pipefail

app=.build/debug/Worktrees
S=/Users/sam/Code/storefront/.claude/worktrees/cart-badge
F=changes:src/features/cart-badge-count/index.ts
size=(--size 1280x860)
# The frame design, shared by the hero and every tour frame.
card=(--card)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for mode in light dark; do
    flag=()
    [ "$mode" = dark ] && flag=(--dark)
    d="$work/$mode"
    mkdir -p "$d"
    $app --snapshot "$d/s1.png" "${size[@]}" ${flag[@]+"${flag[@]}"}
    $app --snapshot "$d/s2.png" --select $S --why-collapsed "${size[@]}" ${flag[@]+"${flag[@]}"}
    $app --snapshot "$d/s3.png" --select $S --why-collapsed --diffs $F "${size[@]}" ${flag[@]+"${flag[@]}"}
    $app --snapshot "$d/sheet.png" --tidy ${flag[@]+"${flag[@]}"}
    # The diff frame dimmed, with the sheet laid over its top centre the way macOS attaches it.
    dim=$([ "$mode" = dark ] && echo 40 || echo 12)
    # The sheet gets a soft shadow of its own (2 sigma of pad less its 12px drop puts 36px above the sheet).
    magick "$d/s3.png" -fill black -colorize "$dim%" \
        \( "$d/sheet.png" \( +clone -background black -shadow 35x24+0+12 \) +swap -background none -layers merge +repage \) \
        -gravity north -geometry +0-36 -composite "$d/s4.png"
    for i in 1 2 3 4; do
        swift scripts/make-hero.swift "$d/s$i.png" "$d/f$i.png" ${flag[@]+"${flag[@]}"} "${card[@]}" > /dev/null
    done
    cp "$d/f3.png" "docs/hero-$mode.png"
    echo "docs/hero-$mode.png $(( $(stat -f %z "docs/hero-$mode.png") / 1024 )) KB"
    ffmpeg -v error -y -framerate 1/1.8 -i "$d/f%d.png" -plays 0 -f apng "docs/tour-$mode.png"
    echo "docs/tour-$mode.png $(( $(stat -f %z "docs/tour-$mode.png") / 1024 )) KB"

    if [ "${1:-}" = --preview ]; then
        out=build/readme-previews
        mkdir -p "$out"
        for page in ffffff 0d1117; do
            for i in 1 2 3 4; do magick "$d/f$i.png" -background "#$page" -flatten "$d/p$i.png"; done
            ffmpeg -v error -y -framerate 1/1.8 -i "$d/p%d.png" -plays 0 -f apng "$out/tour-$mode-on-$page.png"
            cp "$d/p3.png" "$out/hero-$mode-on-$page.png"
            cp "$d/p1.png" "$out/tour-$mode-still-on-$page.png"
            # Hero and the tour's first frame side by side, to check the card matches.
            magick "$out/hero-$mode-on-$page.png" "$out/tour-$mode-still-on-$page.png" -background "#$page" \
                -splice 80x0 +append -gravity east -splice 80x0 -gravity north -splice 0x80 -gravity south -splice 0x80 \
                -resize 50% "$out/side-by-side-$mode-on-$page.png"
        done
    fi
done

if [ "${1:-}" = --preview ]; then
    out=build/readme-previews
    {
        echo '<!doctype html><meta charset="utf-8"><title>README previews</title>'
        echo '<style>body{margin:0;font:14px -apple-system,sans-serif}section{padding:32px}h2{font-weight:600;margin:0 0 16px}'
        echo '.row{display:grid;grid-template-columns:1fr 1fr;gap:24px}img{width:100%;display:block}p{margin:0 0 8px;opacity:.7}</style>'
        for page in ffffff 0d1117; do
            fg=$([ $page = ffffff ] && echo 1f2328 || echo e6edf3)
            echo "<section style=\"background:#$page;color:#$fg\"><h2>On #$page</h2>"
            for mode in light dark; do
                echo "<p>$mode: hero, then the tour playing</p><div class=row>"
                echo "<img src=\"hero-$mode-on-$page.png\"><img src=\"tour-$mode-on-$page.png\"></div><br>"
            done
            echo '</section>'
        done
    } > "$out/index.html"
    echo "$out/index.html"
fi
