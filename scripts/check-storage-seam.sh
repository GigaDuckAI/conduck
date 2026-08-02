#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Fail if any source file outside the live-storage adapter opens a real
# persistent store directly.
#
# WHY THIS EXISTS: Conduck's three stores — the App-Group `UserDefaults`, the
# iCloud key-value store, and the synchronizable Keychain — are shared with the
# developer's own devices, and two of them SYNC. A test that writes one of them
# lands in the real container and propagates to the developer's phone and watch.
# The seam (`Services/Storage/`) exists so a test host runs on in-memory doubles
# instead. It only holds while every call site goes through it: ONE new
# `UserDefaults(suiteName:)` in a view model puts that view model's writes back
# into the real, syncing container, and nothing else would notice.
#
# WHY IT IS NOT A LINE-BASED grep: the first version was, and it could not fail.
# It matched fixed substrings line by line, so a formatter wrapping a long suite
# name across two lines defeated it; so did `.init(suiteName:)`, a bare
# `NSUbiquitousKeyValueStore()`, and an aliased receiver for
# `ubiquityIdentityToken`. Worse, every grep ended in `|| true` under `set -uo`
# with no `-e`, so a moved source directory made it print ✓ while scanning
# nothing. Both holes were demonstrated by execution, not inspection. Hence:
# multi-line regex matching, comments and string literals blanked out, an
# explicit assertion that files were actually scanned, and a second pass that
# guards the ADAPTER boundary as well as the raw-API one.
#
# Run from the repo root: `scripts/check-storage-seam.sh`

set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

SCAN_ROOT="Conduck"

# The single file allowed to touch the raw APIs.
ADAPTER="Conduck/Conduck/Services/Storage/LiveStorage.swift"

if [ ! -d "$SCAN_ROOT" ]; then
  echo "✗ scan root '$SCAN_ROOT' does not exist — this check would otherwise pass vacuously." >&2
  exit 1
fi
if [ ! -f "$ADAPTER" ]; then
  echo "✗ adapter '$ADAPTER' not found — the seam moved; update this script." >&2
  exit 1
fi

# Collect the files ONCE so the count can be asserted. A check that scans zero
# files must fail, not congratulate itself.
SWIFT_FILES=()
while IFS= read -r -d '' f; do SWIFT_FILES+=("$f"); done \
  < <(find "$SCAN_ROOT" -name '*.swift' -type f -print0)

if [ "${#SWIFT_FILES[@]}" -lt 100 ]; then
  echo "✗ only ${#SWIFT_FILES[@]} Swift files found under '$SCAN_ROOT' — expected hundreds." >&2
  echo "  Refusing to report success on what is almost certainly a broken scan." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Pass 1 — raw store APIs. Nothing outside the adapter may name these.
#
# `UserDefaults.standard` is deliberately NOT listed: it is device-local,
# unsynced, and a legitimate separate store (the mascot shuffle bag, and
# `UserIdentityManager`'s inert `hasBeenUsedKey` read).
# ---------------------------------------------------------------------------
RAW_PATTERNS=(
  'UserDefaults\s*(?:\.init)?\s*\(\s*suiteName'
  'NSUbiquitousKeyValueStore\s*(?:\.default\b|\.init\s*\(|\(\s*\))'
  'SecItemCopyMatching\s*\('
  'SecItemAdd\s*\('
  'SecItemUpdate\s*\('
  'SecItemDelete\s*\('
  '\.ubiquityIdentityToken\b'
)

# ---------------------------------------------------------------------------
# Pass 2 — the ADAPTER boundary. Naming a live adapter type is exactly as
# dangerous as naming the raw API it wraps: `LiveDefaultsStore(suiteName:)` in a
# new service opens the real App Group in a CONDUCK_TESTING host, and contains
# no raw API for pass 1 to catch.
# ---------------------------------------------------------------------------
ADAPTER_PATTERNS=(
  '\bLiveDefaultsStore\s*\('
  '\bLiveUbiquitousStore\s*\('
  '\bLiveSecretStore\s*\('
  '\bLiveCloudAvailability\s*\('
  '\bLiveKVSChangeSource\s*\('
  '\bSettingsDependencies\s*\.\s*live\s*\('
)

# ---------------------------------------------------------------------------
# Pass 3 — the App-Group CONTAINER DIRECTORY. Not a `UserDefaults` store, but
# the same shared, developer-owned container: a test driving one of these writes
# real files next to the installed app's. These sites predate the seam and are
# not yet routed through it, so they are allowlisted BY FILE — the point of
# listing them is that a NEW one fails the build instead of joining them
# silently. Unlike the three stores, this container does not iCloud-sync.
# ---------------------------------------------------------------------------
CONTAINER_PATTERN='containerURL\s*\(\s*forSecurityApplicationGroupIdentifier'
CONTAINER_ALLOWLIST=(
  "Conduck/Conduck/Services/PendingRetryStore.swift"
  "Conduck/Conduck/Services/SharedInboxDrainer.swift"
  "Conduck/Conduck/Services/ShareTargetsSnapshotWriter.swift"
  "Conduck/Conduck/Services/ConversationStore.swift"
  "Conduck/Conduck/MenuBar/DictationService.swift"
  "Conduck/Conduck/ViewModels/DiagnosticsRunner.swift"
  "Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift"
  "Conduck/ConduckShareExtension/ShareViewController.swift"
  "Conduck/ConduckShareExtensionMac/ShareViewController.swift"
)

# `LiveDefaultsStore.standard` is the sanctioned device-local store; its one
# consumer is the mascot shuffle bag.
ADAPTER_ALLOWLIST=(
  "Conduck/Conduck/Utilities/MascotCatalog.swift"
)

# Match PATTERN across a whole file with comments and string literals blanked
# out (newlines preserved, so reported line numbers stay true). Emits
# "path:line" per hit.
scan_files() {
  local pattern="$1"; shift
  PAT="$pattern" perl -0777 -ne '
    my $pat = $ENV{PAT};
    my $src = $_;
    # Blank comments and string literals so documentation naming the very APIs
    # it replaces — and key literals that merely look like calls — do not match.
    $src =~ s{/\*.*?\*/}{ my $m = $&; $m =~ s/[^\n]/ /g; $m }ges;
    $src =~ s{//[^\n]*}{}g;
    $src =~ s{"(?:\\.|[^"\\\n])*"}{""}g;
    while ($src =~ /$pat/gs) {
        my $line = 1 + (substr($src, 0, $-[0]) =~ tr/\n//);
        print "$ARGV:$line\n";
    }
  ' "$@"
}

is_allowlisted() {
  local file="$1"; shift
  local entry
  for entry in "$@"; do
    [ "$file" = "$entry" ] && return 0
  done
  return 1
}

violations=0

report() {
  local label="$1" hits="$2" advice="$3"
  if [ -n "$hits" ]; then
    echo "✗ $label"
    echo "$hits" | sed 's/^/    /'
    echo "    → $advice"
    violations=$((violations + 1))
  fi
}

for pattern in "${RAW_PATTERNS[@]}"; do
  hits=$(scan_files "$pattern" "${SWIFT_FILES[@]}" | grep -v "^${ADAPTER}:" || true)
  report "raw store API /$pattern/ is only allowed in ${ADAPTER}:" "$hits" \
         "route it through the protocols in Services/Storage/ConduckStorage.swift"
done

for pattern in "${ADAPTER_PATTERNS[@]}"; do
  raw=$(scan_files "$pattern" "${SWIFT_FILES[@]}" | grep -v "^${ADAPTER}:" || true)
  hits=""
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    file="${hit%:*}"
    is_allowlisted "$file" "${ADAPTER_ALLOWLIST[@]}" && continue
    hits+="${hit}"$'\n'
  done <<< "$raw"
  report "live adapter /$pattern/ constructed outside ${ADAPTER}:" "${hits%$'\n'}" \
         "use SettingsDependencies.processDefault (production) or TestStores (tests)"
done

raw=$(scan_files "$CONTAINER_PATTERN" "${SWIFT_FILES[@]}" || true)
hits=""
while IFS= read -r hit; do
  [ -z "$hit" ] && continue
  file="${hit%:*}"
  is_allowlisted "$file" "${CONTAINER_ALLOWLIST[@]}" && continue
  hits+="${hit}"$'\n'
done <<< "$raw"
report "NEW App-Group container access (not on the allowlist):" "${hits%$'\n'}" \
       "this writes real files into the developer's shared container from a test host — seam it, or add it to CONTAINER_ALLOWLIST with a reason"

if [ "$violations" -gt 0 ]; then
  echo
  echo "In production: SettingsDependencies.processDefault. In a test: TestStores."
  exit 1
fi

echo "✓ storage seam intact — ${#SWIFT_FILES[@]} Swift files scanned, no raw store"
echo "  or live-adapter access outside ${ADAPTER}"
