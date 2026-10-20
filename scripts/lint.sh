#!/bin/bash
# House rules that are easy to break by accident. Run before committing; CI runs it too.
#   1. No middots, em dashes or en dashes in Sources, README, CONTRIBUTING, CHANGELOG or docs.
#   2. No hex colour literals outside Theme.swift (colours come from tokens).
#   3. No .opacity( applied to a text colour (it breaks the contrast the token promises).
cd "$(dirname "$0")/.."
status=0

text_files=$(find Sources README.md CONTRIBUTING.md CHANGELOG.md docs .github -type f \( -name '*.swift' -o -name '*.md' -o -name '*.yml' \) 2>/dev/null)

hits=$(perl -CSD -ne 'print "$ARGV:$.: $_" if /[\x{B7}\x{2014}\x{2013}]/' $text_files 2>/dev/null)
if [[ -n "$hits" ]]; then
    echo "Middot, em dash or en dash found. Use a comma, a full stop or a space instead:"
    echo "$hits"
    status=1
fi

hits=$(grep -nE '0x[0-9A-Fa-f]{6}\b|#[0-9A-Fa-f]{6}\b' $(find Sources -name '*.swift' ! -name Theme.swift) 2>/dev/null)
if [[ -n "$hits" ]]; then
    echo "Hex colour outside Theme.swift. Add a token instead:"
    echo "$hits"
    status=1
fi

hits=$(grep -nE 'Theme\.(text|muted|accent|success|danger|warning|merged)\.opacity\(' $(find Sources -name '*.swift') 2>/dev/null)
if [[ -n "$hits" ]]; then
    echo ".opacity( on a text colour. Pick a token that already has the right contrast:"
    echo "$hits"
    status=1
fi

if [[ $status -eq 0 ]]; then echo "lint ok"; fi
exit $status
