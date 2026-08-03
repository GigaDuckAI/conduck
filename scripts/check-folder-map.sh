#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Fail if the folder map in docs/ai-context/project-structure.md and the actual
# repository have drifted apart, in either direction:
#
#   forward — a directory containing Swift source that the map never mentions
#   reverse — a path the map names in backticks that no longer exists
#
# WHY THIS EXISTS: project-structure.md used to be a hand-maintained tree naming
# every individual file. It reached 111 KB, went 12% incomplete, and nobody
# noticed, because nothing checked it. It is now a folder-level map instead — and
# folders, unlike files, barely move: hundreds of Swift files were added over a
# recent two-month window without a single new directory. That makes the map
# cheap to keep true and cheap to verify, so this check exists to make "true" the
# only state it can be in. Expect it to fire a couple of times a year; when it
# does, the fix is one line of prose.
#
# WHY IT CHECKS BOTH DIRECTIONS: a missing entry leaves a reader with a blind
# spot, but a stale entry is worse — it sends them looking for something that is
# not there and quietly undermines trust in the rest of the document.
#
# WHY IT DOES NOT CHECK FILES: the filesystem is the file inventory, and it never
# goes stale. What a file does belongs in that file's header comment. See
# CONTRIBUTING.md, "Documentation".
#
# HOW PATHS ARE MATCHED: the map writes main-app folders relative to the app
# source root (`Services/RemoteAgent/`) because that reads better, and everything
# else relative to the repository root (`Conduck/ConduckWatch Watch App/`). Both
# forms are accepted, in both directions.
#
# Run from the repo root: `scripts/check-folder-map.sh`

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

MAP="docs/ai-context/project-structure.md"
SCAN_ROOT="Conduck"
APP_ROOT="Conduck/Conduck"

if [ ! -f "$MAP" ]; then
  echo "✗ '$MAP' not found — this check would otherwise pass vacuously." >&2
  exit 1
fi
if [ ! -d "$SCAN_ROOT" ]; then
  echo "✗ scan root '$SCAN_ROOT' does not exist — the source tree moved." >&2
  exit 1
fi

MAP_TEXT="$(cat "$MAP")"

# ---------------------------------------------------------------------------
# Forward pass — every directory holding Swift source must be named in the map.
# ---------------------------------------------------------------------------
SWIFT_DIRS=()
while IFS= read -r d; do SWIFT_DIRS+=("$d"); done < <(
  find "$SCAN_ROOT" -name '*.swift' -type f -print0 \
    | xargs -0 -n1 dirname \
    | sort -u
)

if [ "${#SWIFT_DIRS[@]}" -lt 10 ]; then
  echo "✗ only ${#SWIFT_DIRS[@]} directories with Swift source found under '$SCAN_ROOT'." >&2
  echo "  Refusing to report success on what is almost certainly a broken scan." >&2
  exit 1
fi

missing=()
for dir in "${SWIFT_DIRS[@]}"; do
  # The app source root itself is described as a row of its own; it is a prefix
  # of half the paths in the document, so matching it literally proves nothing.
  [ "$dir" = "$APP_ROOT" ] && continue

  relative="${dir#"$APP_ROOT"/}"

  if [[ "$MAP_TEXT" == *"$dir"* ]]; then continue; fi
  if [ "$relative" != "$dir" ] && [[ "$MAP_TEXT" == *"\`$relative/\`"* ]]; then continue; fi

  missing+=("$dir")
done

# ---------------------------------------------------------------------------
# Reverse pass — every path the map names in backticks must exist.
#
# A backticked span counts as a path candidate when it contains a slash. That
# keeps the rule simple and keeps backticks meaning "path" in this document; a
# backticked shell command containing a slash would need excluding here, so do
# not write one.
# ---------------------------------------------------------------------------
stale=()
while IFS= read -r token; do
  [ -z "$token" ] && continue
  candidate="${token%/}"

  [ -e "$candidate" ] && continue
  [ -e "$APP_ROOT/$candidate" ] && continue

  stale+=("$token")
done < <(
  grep -o '`[^`]*`' "$MAP" \
    | tr -d '`' \
    | grep '/' \
    | sort -u
)

status=0

if [ "${#missing[@]}" -gt 0 ]; then
  echo "✗ directories with Swift source that $MAP never mentions:"
  printf '    %s\n' "${missing[@]}"
  echo "    → add a row naming the folder and saying in one sentence what lives there."
  status=1
fi

if [ "${#stale[@]}" -gt 0 ]; then
  echo "✗ paths named in $MAP that do not exist:"
  printf '    %s\n' "${stale[@]}"
  echo "    → the path moved or was deleted; correct or remove the entry."
  status=1
fi

if [ "$status" -ne 0 ]; then
  echo
  echo "The map is folder-level on purpose. Do not add individual files to fix this."
  exit 1
fi

echo "✓ folder map current — ${#SWIFT_DIRS[@]} Swift source directories, all mapped,"
echo "  and every path the map names exists"
