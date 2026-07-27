#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Stamp every tracked source file with an SPDX license identifier.
#
# WHY SPDX AND NOT THE APACHE BOILERPLATE: the Apache-2.0 appendix suggests an
# 11-line notice per file. The one-line SPDX tag carries the same information in
# a form both humans and license scanners parse deterministically, which is the
# only property that actually matters here. The Linux kernel made the same trade.
#
# WHY NO COPYRIGHT LINE AND NO YEAR: a year in 500+ files is a maintenance
# treadmill that buys nothing. Copyright arises on creation — Estonian Copyright
# Act §§7 and 11 impose no notice formality — so the tag is not what secures the
# rights. The year that does carry meaning is the year of FIRST PUBLICATION, and
# that lives in exactly one place: the root NOTICE file, which is also the file
# Apache-2.0 §4(d) propagates to downstream redistributors. Nothing here needs
# touching when the calendar rolls over.
#
# A holder line would also become WRONG over time. Contributions arrive under
# DCO 1.1 with no CLA, so contributors keep their copyright: once an outside pull
# request lands, a blanket "Copyright GigaDuck OÜ" on every file would assert
# ownership the company does not hold.
#
# WHY THE BLANK LINE AFTER THE TAG: SwiftFormat's `--header` rule treats the
# first comment block followed by a blank line as the replaceable file header. No
# SwiftFormat config exists in this repository today, but if one is ever added,
# the blank line keeps the SPDX tag outside the block it would rewrite.
#
# Usage:
#   scripts/add-spdx-headers.sh            # insert missing headers everywhere
#   scripts/add-spdx-headers.sh --check    # verify only; non-zero if any missing
#   scripts/add-spdx-headers.sh --staged   # insert into STAGED files only, and
#                                          # re-stage them (used by the pre-commit hook)
#
# `--check` is what CI runs. Re-running any mode is a no-op, so it is safe to run
# at any time.

set -euo pipefail

readonly SPDX_TAG='SPDX-License-Identifier: Apache-2.0'

check_only=false
staged_only=false
case "${1:-}" in
    --check) check_only=true ;;
    --staged) staged_only=true ;;
    "") ;;
    *)
        printf 'usage: %s [--check|--staged]\n' "$0" >&2
        exit 2
        ;;
esac

# Run from the repository root so `git ls-files` paths resolve regardless of the
# caller's working directory.
cd "$(git rev-parse --show-toplevel)"

# Tracked files only. Sweeping the working tree instead would reach into build
# output and untracked scratch files, which must never be stamped.
#
# NUL-delimited throughout: paths in this repository contain spaces
# ("ConduckWatch Watch App/"), and any whitespace-split loop mangles them.
#
# In --staged mode the candidate set is the files this commit is about to record
# (added/copied/modified) rather than the whole index, so a commit only ever
# rewrites files it already touches.
if [ "$staged_only" = true ]; then
    list_candidates() {
        git diff --cached --name-only --diff-filter=ACM -z -- \
            '*.swift' '*.js' '*.py' '*.sh'
    }
else
    list_candidates() { git ls-files -z '*.swift' '*.js' '*.py' '*.sh'; }
fi

missing=()
while IFS= read -r -d '' file; do
    # A staged deletion or rename can leave a path in the diff that is no longer
    # on disk; nothing to stamp there.
    [ -f "$file" ] || continue
    # Idempotency: a file already carrying the tag near the top is left alone.
    # Five lines is enough to cover a shebang plus a short preamble without
    # matching a stray mention deeper in a file's prose.
    if head -5 "$file" | grep -qF "$SPDX_TAG"; then
        continue
    fi
    missing+=("$file")
done < <(list_candidates)

if [ ${#missing[@]} -eq 0 ]; then
    printf 'All tracked source files carry the SPDX header.\n'
    exit 0
fi

if [ "$check_only" = true ]; then
    printf 'error: %d source file(s) are missing the SPDX license header:\n' "${#missing[@]}" >&2
    printf '  %s\n' "${missing[@]}" >&2
    printf '\nFix with:\n  scripts/add-spdx-headers.sh\n' >&2
    exit 1
fi

# A file that is only PARTIALLY staged (some hunks staged, others not) must not
# be stamped here: the `git add` below would sweep the unstaged hunks into the
# commit too, silently recording changes the author did not stage. Rare, but the
# failure is invisible, so refuse instead of guessing.
if [ "$staged_only" = true ]; then
    partial=()
    for file in "${missing[@]}"; do
        if ! git diff --quiet -- "$file"; then
            partial+=("$file")
        fi
    done
    if [ ${#partial[@]} -gt 0 ]; then
        printf 'error: %d staged file(s) also have UNSTAGED changes and need the SPDX header:\n' "${#partial[@]}" >&2
        printf '  %s\n' "${partial[@]}" >&2
        printf '\nStamping them here would pull those unstaged changes into the commit.\n' >&2
        printf 'Stage or stash them, then commit again:\n  scripts/add-spdx-headers.sh && git add -u\n' >&2
        exit 1
    fi
fi

for file in "${missing[@]}"; do
    # Comment syntax by extension. Swift and JavaScript take `//`; Python and
    # shell take `#`.
    case "$file" in
        *.swift|*.js) prefix='//' ;;
        *.py|*.sh)    prefix='#' ;;
        *)
            printf 'error: no comment syntax known for %s\n' "$file" >&2
            exit 1
            ;;
    esac

    header="$prefix $SPDX_TAG"
    scratch="$(mktemp)"

    # A shebang must stay on line 1 or the kernel will not honour it, so the tag
    # goes on line 2 for those files and on line 1 for everything else.
    if head -1 "$file" | grep -q '^#!'; then
        head -1 "$file" > "$scratch"
        printf '%s\n\n' "$header" >> "$scratch"
        tail -n +2 "$file" >> "$scratch"
    else
        printf '%s\n\n' "$header" > "$scratch"
        cat "$file" >> "$scratch"
    fi

    # Preserve the executable bit and any other mode bits: mktemp creates 0600,
    # and a clobbered mode would silently break the runner scripts.
    chmod --reference="$file" "$scratch" 2>/dev/null || {
        mode=$(stat -f '%Lp' "$file")
        chmod "$mode" "$scratch"
    }
    mv "$scratch" "$file"
done

if [ "$staged_only" = true ]; then
    # Re-stage so the header lands in THIS commit rather than dangling as an
    # unstaged edit the author has to notice and commit separately.
    git add -- "${missing[@]}"
fi

# Never silent: the author should always see that their commit was modified.
printf 'Added the SPDX header to %d file(s):\n' "${#missing[@]}"
printf '  %s\n' "${missing[@]}"
