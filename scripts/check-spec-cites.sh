#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Fail if a source file cites a named section of docs/ai-context/spec.md that
# the document does not contain.
#
# A citation here means the quoted form — `spec.md "Privacy & Security"`, and
# equally the bare `spec "Trigger Architecture"` or a quote separated from the
# path by a verb (`spec.md locks "…"`) — in a
# file's header comment. The quoted string has to match a live `#` heading in
# the spec, character for character once whitespace is collapsed. A file that
# cites `docs/ai-context/spec.md` with no quoted name is not a citation this
# check has any opinion about, and that is the form to prefer.
#
# WHY THIS EXISTS: the spec was rewritten from a sprawling inventory into a
# short document about decisions, and every heading changed. Nothing noticed, so
# dozens of citations across the tree went on naming sections that had ceased to
# exist — in the exact layer README.md and CONTRIBUTING.md tell every reader is
# where the detailed documentation lives. A reader who follows such a pointer,
# finds nothing, and concludes the header comments are decoration has drawn the
# correct conclusion from the evidence available to them.
#
# WHY THE FIX IS TO DROP THE NAME, NOT TO RETARGET IT: the spec's headings are
# full prose sentences — "Authentication fails closed, and keyless is never
# inferred" — and they are reworded whenever the decision underneath them is
# re-explained. A name copied into a source header is therefore stale at the
# next rewording, and the repository has already run that experiment once. The
# bare path is the durable form: `docs/ai-context/spec.md` stays true no matter
# how the document is reorganised, and the spec is short enough to skim.
#
# WHY THE MATCH IS EXACT: an approximate match would let a citation drift a word
# at a time while still passing, which is how the previous set decayed. Where a
# destination genuinely earns the extra words, quoting a heading exactly is
# accepted — this check is what keeps that promise honest.
#
# WHY IT SCANS THE SWIFT TREE ONLY: the per-file header comment is the only
# place in this repository that cites the spec by section name. Markdown files
# link to it as a file, which is a link and either resolves or does not.
#
# Zero citations is a passing state, not a broken scan — the steady state this
# check defends is that nobody writes one. What would make it pass vacuously is
# an empty source tree or an unparsed spec, and both are asserted below.
#
# Run from the repo root: `scripts/check-spec-cites.sh`

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

SPEC="docs/ai-context/spec.md"
SCAN_ROOT="Conduck"

if [ ! -f "$SPEC" ]; then
  echo "✗ '$SPEC' not found — this check would otherwise pass vacuously." >&2
  exit 1
fi
if [ ! -d "$SCAN_ROOT" ]; then
  echo "✗ scan root '$SCAN_ROOT' does not exist — the source tree moved." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The live headings, whitespace-collapsed so a citation broken across two
# comment lines can be compared with one written on a single line.
# ---------------------------------------------------------------------------
HEADINGS="$(mktemp)"
trap 'rm -f "$HEADINGS"' EXIT

perl -ne '
    chomp;
    next unless s/^\#{1,6}\s+//;
    s/\s+/ /g;
    s/^\s+|\s+$//g;
    print "$_\n" if length;
' "$SPEC" | sort -u > "$HEADINGS"

heading_count=$(wc -l < "$HEADINGS" | tr -d ' ')
if [ "$heading_count" -lt 10 ]; then
  echo "✗ only $heading_count headings parsed out of '$SPEC'." >&2
  echo "  Refusing to report success on what is almost certainly a broken scan." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# The citations. Written to a file rather than piped into the loop below, so
# that the counters the loop keeps survive it — a subshell would discard them.
# Matched across newlines because a long section name wraps onto a second
# comment line: `spec.md "Gateway Setup & Pairing (…` continuing under a `//`.
# The continuation marker is folded back into a single space before comparison,
# which is why the heading list above is collapsed the same way.
# ---------------------------------------------------------------------------
SWIFT_FILES=()
while IFS= read -r -d '' f; do SWIFT_FILES+=("$f"); done \
  < <(find "$SCAN_ROOT" -name '*.swift' -type f -print0)

if [ "${#SWIFT_FILES[@]}" -lt 100 ]; then
  echo "✗ only ${#SWIFT_FILES[@]} Swift files found under '$SCAN_ROOT' — expected hundreds." >&2
  echo "  Refusing to report success on what is almost certainly a broken scan." >&2
  exit 1
fi

CITATIONS="$(mktemp)"
trap 'rm -f "$HEADINGS" "$CITATIONS"' EXIT

# Only COMMENT text is scanned. A quoted string in code is a UI label or a test
# assertion, never a spec citation, and matching one produces a false failure
# that teaches the next reader to ignore this check.
#
# Three citation shapes are recognised, because all three have occurred here:
#   spec.md "Name"        the plain form
#   spec "Name"           the path abbreviated away
#   spec.md locks "Name"  a verb between the path and the quote
# The connector is at most two short lowercase words, which keeps the match
# anchored to a citation rather than to any quote that happens to follow the
# word "spec" a few characters later.
perl -0777 -ne '
    my $src = $_;
    # Blank every line that is not a comment, preserving length and newlines so
    # the reported line numbers stay true.
    my @out;
    for my $l (split /\n/, $src, -1) {
        push @out, ($l =~ m{^\s*(?://|/\*|\*|\#)}) ? $l : (" " x length($l));
    }
    my $c = join "\n", @out;
    while ($c =~ /\bspec(?:\.md)?`?[ \t]*(?:[a-z]{2,10}[ \t]+){0,2}"([^"]{1,300})"/gs) {
        my $cite = $1;
        my $line = 1 + (substr($c, 0, $-[0]) =~ tr/\n//);
        # Fold a comment continuation ("…\n//   more words") back into a space.
        $cite =~ s{\n[ \t]*(?:///|//|\*)?[ \t]*}{ }g;
        $cite =~ s/\s+/ /g;
        $cite =~ s/^\s+|\s+$//g;
        print "$ARGV\t$line\t$cite\n";
    }
' "${SWIFT_FILES[@]}" > "$CITATIONS"

dead=()
total=0
while IFS=$'\t' read -r file line cite; do
  [ -z "${cite:-}" ] && continue
  total=$((total + 1))
  grep -Fxq -- "$cite" "$HEADINGS" && continue
  dead+=("$file:$line  \"$cite\"")
done < "$CITATIONS"

if [ "${#dead[@]}" -gt 0 ]; then
  echo "✗ citations naming a section that $SPEC does not contain:"
  printf '    %s\n' "${dead[@]}"
  echo
  echo "    → drop the quoted name. Cite \`$SPEC\` and nothing else."
  echo
  echo "The spec's headings are whole sentences, and they are reworded whenever the"
  echo "decision underneath them is re-explained — so a section name copied into a"
  echo "source header goes stale on its own, silently, and points a reader at nothing."
  echo "The bare path survives every rewrite. Where naming a destination genuinely"
  echo "helps, quote a heading that exists, exactly as it is written today."
  exit 1
fi

if [ "$total" -eq 0 ]; then
  echo "✓ no spec section name is cited anywhere — ${#SWIFT_FILES[@]} Swift files scanned;"
  echo "  every reference to $SPEC is the bare path, which is the form that lasts"
else
  echo "✓ spec citations resolve — ${#SWIFT_FILES[@]} Swift files scanned, $total quoted"
  echo "  section name(s), every one a live heading in $SPEC"
fi
