#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Fail if the legal text bundled into the app has drifted from the canonical
# copy at the repository root.
#
# Three files exist twice: LICENSE, NOTICE and THIRD_PARTY_NOTICES.md at the
# root, and the same bytes under Conduck/Conduck/Resources/Legal/ where the app
# can read them. The root copies are canonical. The bundled copies are the ones
# that ship, and therefore the ones carrying the obligation.
#
# WHY THIS EXISTS: Apache-2.0 §4 and the MIT notice requirement attach to every
# distribution, not to the source tree — what discharges them is the text a user
# can actually read, which here is the in-app Open Source Licenses screen fed by
# the bundled copies. Nothing but hand-copying keeps the two sides equal. Edit a
# dependency's licence paragraph at the root, ship without re-copying, and the
# app displays notices that are wrong about the software it contains, silently
# and with a clean diff.
#
# WHY IT RUNS HERE WHEN A TEST ALREADY CHECKS IT: `LegalNoticesResourceTests`
# pins the same equality, but it is a simulator test — it needs a macOS runner,
# an Xcode toolchain and most of an hour, and it is gated behind these guards
# anyway. `cmp` on Linux answers the same question in a second, at no cost on a
# public repository. The test stays: it is what protects the equality for
# someone running the suite locally with no CI in front of them.
#
# WHY THE NAMES DIFFER: the bundled files carry a `.txt` extension the root
# files do not, because a resource without an extension is awkward to bundle and
# to display. That rename is the whole difference permitted — the bytes must
# match exactly.
#
# Run from the repo root: `scripts/check-legal-copies.sh`

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

LEGAL_DIR="Conduck/Conduck/Resources/Legal"

# `root:bundled` — the bundled name is the root name plus the resource-friendly
# extension, except for the notices file which already has one.
PAIRS=(
  "LICENSE:LICENSE.txt"
  "NOTICE:NOTICE.txt"
  "THIRD_PARTY_NOTICES.md:THIRD_PARTY_NOTICES.md"
)

if [ ! -d "$LEGAL_DIR" ]; then
  echo "✗ '$LEGAL_DIR' does not exist — the bundled legal resources moved." >&2
  echo "  Refusing to report success on a check that would otherwise compare nothing." >&2
  exit 1
fi

drifted=()
status=0

for pair in "${PAIRS[@]}"; do
  root="${pair%%:*}"
  bundled="$LEGAL_DIR/${pair#*:}"

  if [ ! -f "$root" ]; then
    echo "✗ canonical '$root' not found — it moved, or it was deleted." >&2
    status=1
    continue
  fi
  if [ ! -f "$bundled" ]; then
    echo "✗ bundled copy '$bundled' not found — the app would show nothing on the" >&2
    echo "  Open Source Licenses screen. Copy '$root' there." >&2
    status=1
    continue
  fi

  cmp -s "$root" "$bundled" && continue
  drifted+=("$root  →  $bundled")
done

if [ "${#drifted[@]}" -gt 0 ]; then
  echo "✗ bundled legal text differs from the canonical copy at the repository root:"
  printf '    %s\n' "${drifted[@]}"
  echo "    → copy the root file over the bundled one; the root is canonical."
  echo
  echo "The bundled copy is what the app displays, so this is the copy that carries"
  echo "the attribution obligation to anyone who installs the build. Editing one side"
  echo "alone ships legal text that no longer describes the software around it."
  status=1
fi

if [ "$status" -ne 0 ]; then
  exit 1
fi

echo "✓ bundled legal text matches the repository root — ${#PAIRS[@]} files compared"
echo "  byte for byte against $LEGAL_DIR"
