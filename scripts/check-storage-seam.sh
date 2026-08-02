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
# Run from the repo root: `scripts/check-storage-seam.sh`

set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

# The single file allowed to touch the raw APIs.
ADAPTER="Conduck/Conduck/Services/Storage/LiveStorage.swift"

# Raw APIs that must not appear anywhere else. `UserDefaults.standard` is NOT
# listed: it is device-local, unsynced, and a legitimate separate store — see
# `UserIdentityManager`'s `hasBeenUsedKey` read.
PATTERNS=(
  'UserDefaults(suiteName:'
  'NSUbiquitousKeyValueStore.default'
  'SecItemCopyMatching('
  'SecItemAdd('
  'SecItemUpdate('
  'SecItemDelete('
  'FileManager.default.ubiquityIdentityToken'
)

violations=0

for pattern in "${PATTERNS[@]}"; do
  # Search Swift sources only; drop the adapter, and drop comment lines (the
  # seam is documented by naming the very APIs it replaces).
  hits=$(grep -rn --include='*.swift' -F "$pattern" Conduck/ \
           | grep -v "^${ADAPTER}:" \
           | grep -vE '^[^:]+:[0-9]+: *(//|///|\*)' \
           || true)
  if [ -n "$hits" ]; then
    echo "✗ '$pattern' is only allowed in ${ADAPTER}:"
    echo "$hits" | sed 's/^/    /'
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  echo
  echo "Route these through the protocols in Services/Storage/ConduckStorage.swift."
  echo "In production: SettingsDependencies.processDefault. In a test: TestStores."
  exit 1
fi

echo "✓ storage seam intact — no direct App-Group / iCloud-KVS / Keychain access outside ${ADAPTER}"
