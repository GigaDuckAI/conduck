#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Fail if docs/ai-context/spec.md is growing back into the document it replaced,
# in any of the three ways it can:
#
#   whole file    — the document as a whole is over its word ceiling
#   per decision  — one `###` decision under "The decisions" is over its own
#   folder        — docs/ai-context/ holds something other than the two documents
#
# WHY THIS EXISTS: the previous spec.md reached 537 KB. Long before that it had
# stopped being read, and a document nobody reads is not merely useless — it
# starts making claims that are false, because nothing contradicts them. It was
# rewritten in a day, down to 48 KB, as a record of decisions rather than a
# description of the software. Sixteen days later it was 106 KB. Nineteen
# commits, not one of them unreasonable on its own, each adding a paragraph that
# looked worth adding.
#
# The prohibition against exactly this is already written down in three separate
# places — the product's own CLAUDE.md, the top of spec.md itself, and
# CONTRIBUTING.md under "Documentation" — and all three were in force during the
# doubling. Prose did not hold, so this is the mechanical version. Every other
# invariant in this repository that review kept failing to enforce ended up as a
# script; this is that, for the one rule whose failure mode is silent.
#
# WHY WORDS AND NOT BYTES: words are the reading burden, which is the thing
# actually being rationed. A byte count moves when a paragraph is rewrapped, a
# table is realigned, or a long identifier is renamed — changes that cost a
# reader nothing — and a limit that fires on those teaches contributors that the
# limit is noise. The whole-file number below is exactly `wc -w`, so anyone can
# reproduce it in one command without reading this script.
#
# WHY TWO DECISIONS ARE EXEMPT AND NAMED: two sections are far over the
# per-decision ceiling today. Failing the build on them would mean either
# rewriting them under time pressure or, far more likely, quietly raising the
# ceiling for everyone — which is how a limit dies. They are grandfathered by
# exact word count instead: they may shrink, they may not grow, and the debt is
# legible right here in the script rather than in someone's memory. Everything
# written after them gets the strict rule from its first line.
#
# WHY GROWTH FAILS BUT SHRINKAGE ONLY WARNS: spec.md's own "How the rules are
# enforced" section states the convention these guards follow — they never pin a
# count that unrelated edits will disturb, because a contributor taught to bump
# a number is a contributor who has stopped reading the rule. So trimming a
# grandfathered section prints the smaller number and the line to paste; it does
# not fail. The one shrinkage that DOES fail is a section falling to the general
# ceiling, because then the exemption is finished and leaving it listed would
# hand back an allowance nobody is using.
#
# WHY IT COUNTS THE FILES IN THE FOLDER: a ceiling on one file is satisfiable by
# starting a second one. The two documents under docs/ai-context/ are the whole
# set — spec.md for decisions, project-structure.md for the folder map — and an
# architecture-part-2.md would defeat every number above while looking like
# tidying up.
#
# Run from the repo root: `scripts/check-spec-size.sh`

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

SPEC="docs/ai-context/spec.md"
DOC_DIR="docs/ai-context"

# ---------------------------------------------------------------------------
# The ceilings.
#
# WHOLE FILE — this is a fuse, not a target. Measured 2026-08-19: 18,192 words.
# The headroom below is enough that a decision can be added or reworded without
# tripping it, and nowhere near enough for the file to keep doubling. A focused
# content cut is planned and will land around 13,000 words; whoever finishes it
# RATCHETS THIS NUMBER DOWN to just above whatever the file then measures. A
# fuse left at the old level after a cut is a fuse that permits the cut to be
# undone.
#
# PER DECISION — a decision that cannot be stated, justified, and have its
# rejected alternatives recorded in this many words is usually two decisions.
# ---------------------------------------------------------------------------
FILE_CEILING=19000
DECISION_CEILING=650

# `words:heading` — the exact count each section measures today. Growth fails.
# See "WHY TWO DECISIONS ARE EXEMPT AND NAMED" above.
GRANDFATHERED=(
  "4028:A file the agent produces comes back in a folder the app named for that one reply"
  "1453:What the user has already seen is a fact about the account, and it syncs"
)

# The complete contents of docs/ai-context/. There is no third document.
EXPECTED_DOCS=(
  "spec.md"
  "project-structure.md"
)

if [ ! -f "$SPEC" ]; then
  echo "✗ '$SPEC' not found — this check would otherwise pass vacuously." >&2
  exit 1
fi

# `status` is the exit code. `too_long` is narrower: it says the document is
# over a limit, which is the only failure the closing advice about what to cut
# applies to. A bookkeeping failure — a spent exemption, a reworded heading —
# does not want that advice attached to it.
status=0
too_long=0

# ---------------------------------------------------------------------------
# Whole file. Plain `wc -w`: whitespace-delimited tokens, markup included.
# ---------------------------------------------------------------------------
file_words=$(wc -w < "$SPEC" | tr -d ' ')

if [ "$file_words" -gt "$FILE_CEILING" ]; then
  echo "✗ $SPEC is $file_words words; the ceiling is $FILE_CEILING."
  echo "    → cut, do not relocate. Raising the ceiling is not the fix."
  status=1
  too_long=1
fi

# ---------------------------------------------------------------------------
# Per decision. A decision is one `###` heading inside `## The decisions`, and
# it runs to the next heading at that level or to the end of the section.
# Words are counted the same way as above, minus the heading's own `###`
# marker, which is markup rather than reading.
# ---------------------------------------------------------------------------
SECTIONS="$(mktemp)"
trap 'rm -f "$SECTIONS"' EXIT

perl -e '
    my ($in, $cur, $n) = (0, undef, 0);
    while (my $line = <>) {
        chomp $line;
        if ($line =~ /^##[ \t]+(.*)$/) {
            printf "%d\t%s\n", $n, $cur if defined $cur;
            $cur = undef;
            $in  = ($1 eq "The decisions") ? 1 : 0;
            next;
        }
        if ($in && $line =~ /^###[ \t]+(.*)$/) {
            printf "%d\t%s\n", $n, $cur if defined $cur;
            ($cur, $n) = ($1, 0);
            $n += scalar(() = $cur =~ /\S+/g);
            next;
        }
        next unless $in && defined $cur;
        $n += scalar(() = $line =~ /\S+/g);
    }
    printf "%d\t%s\n", $n, $cur if defined $cur;
' "$SPEC" > "$SECTIONS"

decision_count=$(wc -l < "$SECTIONS" | tr -d ' ')
if [ "$decision_count" -lt 10 ]; then
  echo "✗ only $decision_count decisions parsed out of '$SPEC'." >&2
  echo "  Refusing to report success on what is almost certainly a broken scan —" >&2
  echo "  the '## The decisions' heading was renamed, or the section is gone." >&2
  exit 1
fi

allowance_for() {
  local heading="$1" entry
  for entry in "${GRANDFATHERED[@]}"; do
    [ "${entry#*:}" = "$heading" ] && { echo "${entry%%:*}"; return 0; }
  done
  return 1
}

oversized=()
retired=()
trimmed=()
largest_words=0
largest_heading=""
matched=0

while IFS=$'\t' read -r words heading; do
  [ -z "${heading:-}" ] && continue

  if allowed=$(allowance_for "$heading"); then
    matched=$((matched + 1))
    if [ "$words" -gt "$allowed" ]; then
      oversized+=("\"$heading\"
        $words words, and this section is grandfathered at $allowed. It may shrink; it may not grow.")
    elif [ "$words" -le "$DECISION_CEILING" ]; then
      retired+=("\"$heading\"
        now $words words, at or under the general ceiling of $DECISION_CEILING.")
    elif [ "$words" -lt "$allowed" ]; then
      trimmed+=("\"$heading\"
  is now $words words, down from the recorded $allowed — lower its GRANDFATHERED
  entry to \"$words:\" so the allowance ratchets down with the section.")
    fi
    continue
  fi

  if [ "$words" -gt "$largest_words" ]; then
    largest_words="$words"
    largest_heading="$heading"
  fi

  if [ "$words" -gt "$DECISION_CEILING" ]; then
    oversized+=("\"$heading\"
        $words words, against a ceiling of $DECISION_CEILING.")
  fi
done < "$SECTIONS"

if [ "$matched" -ne "${#GRANDFATHERED[@]}" ]; then
  echo "✗ a grandfathered heading no longer appears under '## The decisions'."
  echo "    → it was reworded, split, or removed. Update GRANDFATHERED in this script"
  echo "      to match the heading as it reads today, keeping its recorded count, or"
  echo "      drop the entry if the section is gone. A stale exemption silently grants"
  echo "      an allowance to nothing while the real section runs under no limit."
  status=1
fi

if [ "${#oversized[@]}" -gt 0 ]; then
  echo "✗ decisions over their word limit:"
  printf '    %s\n' "${oversized[@]}"
  status=1
  too_long=1
fi

if [ "${#retired[@]}" -gt 0 ]; then
  echo "✗ a grandfathered exemption is spent and still listed:"
  printf '    %s\n' "${retired[@]}"
  echo "    → delete its line from GRANDFATHERED in this script. The section is under"
  echo "      the general ceiling now and does not need an allowance; leaving one"
  echo "      listed hands back room nobody is using, which is how a debt list stops"
  echo "      describing any real debt. This is the good failure — it means the work"
  echo "      was done."
  status=1
fi

# ---------------------------------------------------------------------------
# The folder. Dot-entries are ignored: a .DS_Store is not a document, and
# failing on one would only teach a contributor to distrust this check.
# ---------------------------------------------------------------------------
unexpected=()
while IFS= read -r entry; do
  name="$(basename "$entry")"
  case "$name" in .*) continue ;; esac
  for expected in "${EXPECTED_DOCS[@]}"; do
    [ "$name" = "$expected" ] && continue 2
  done
  unexpected+=("$entry")
done < <(find "$DOC_DIR" -mindepth 1 -maxdepth 1 | sort)

missing=()
for expected in "${EXPECTED_DOCS[@]}"; do
  [ -f "$DOC_DIR/$expected" ] || missing+=("$DOC_DIR/$expected")
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "✗ expected document(s) missing from $DOC_DIR:"
  printf '    %s\n' "${missing[@]}"
  echo "    → these two are the project's architecture documentation. Restore them."
  status=1
fi

if [ "${#unexpected[@]}" -gt 0 ]; then
  echo "✗ $DOC_DIR holds something other than the two documents:"
  printf '    %s\n' "${unexpected[@]}"
  echo "    → a third document is how a word ceiling gets satisfied without anything"
  echo "      being cut. Decisions go in spec.md, folders and targets go in"
  echo "      project-structure.md, and everything else goes in the header comment of"
  echo "      the file it describes."
  status=1
  too_long=1
fi

if [ "$too_long" -ne 0 ]; then
  echo
  echo "Two fixes are not available here."
  echo
  echo "Deleting the rejected alternatives is not one. They are the most valuable"
  echo "content in the document and the only part that cannot be reconstructed by"
  echo "reading the code — a contributor who does not know what was refused will"
  echo "propose it again, which is the entire reason this file exists."
  echo
  echo "Moving prose into another document is not one either. The reading burden is"
  echo "the same and it is now in a place nobody maintains."
  echo
  echo "What to cut is whatever fails the one-file rule: a sentence belongs in this"
  echo "document only if it CANNOT be confirmed by opening one file. Anything a reader"
  echo "could check by reading the code belongs in that file's header comment instead —"
  echo "type and method inventories, UI labels, provider model identifiers, walkthroughs"
  echo "of how something is implemented, and current status. See CONTRIBUTING.md,"
  echo "\"Documentation\"."
fi

if [ "$status" -ne 0 ]; then
  exit 1
fi

# Advisory, not failure: a grandfathered section that got smaller. Bash treats
# an empty array as unset under `set -u`, hence the length tests.
if [ "${#retired[@]}" -gt 0 ]; then printf '· %s\n' "${retired[@]}"; fi
if [ "${#trimmed[@]}" -gt 0 ]; then printf '· %s\n' "${trimmed[@]}"; fi

echo "✓ $SPEC within budget — $file_words words of $FILE_CEILING, $decision_count decisions,"
echo "  largest unexempt one $largest_words of $DECISION_CEILING (\"$largest_heading\")"
