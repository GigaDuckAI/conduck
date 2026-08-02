#!/bin/bash
# SPDX-License-Identifier: Apache-2.0

#
# Remove per-uuid settings keys whose owning gateway / voice endpoint is no
# longer on its roster, from THIS MAC's App-Group preferences.
#
# WHY THIS IS A SCRIPT AND NOT A MIGRATION IN THE APP. An in-app sweep has to
# decide "is this key an orphan?" from the roster, and both roster readers are
# fail-open: a `try?` decode failure and "nothing stored yet" both surface as an
# empty list, indistinguishable from "this user has no gateways". Feeding that
# into an irreversible deletion across BOTH stores means one malformed record —
# or a roster clobbered by an add that itself read empty before iCloud
# delivered — erases every gateway's URL, model, auth scheme and file-server
# config from every device the user owns. Losing the roster alone is
# recoverable; the slots outlive it and return with it. So the app never sweeps.
#
# The litter this collects predates `deleteCustomGateway` purging its own key
# family. It exists on developer machines that ran the old test suite against
# the real container. It is not something a user can accumulate today.
#
# SAFETY POSTURE, deliberately different from the in-app version:
#   * prints every key it would remove, grouped, and requires a typed "yes"
#   * touches ONLY this Mac's App-Group plist — never the iCloud key-value
#     store — so a wrong answer here cannot propagate to another device
#   * refuses to run if either roster is missing or undecodable, rather than
#     treating that as "zero gateways"
#
# Usage:  scripts/cleanup-orphan-slots.sh [--apply]
#         (default is a dry run)

set -euo pipefail

APP_GROUP="${CONDUCK_APP_GROUP:-group.ai.gigaduck.agentrelay}"
PLIST="$HOME/Library/Group Containers/$APP_GROUP/Library/Preferences/$APP_GROUP.plist"
APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

if [ ! -f "$PLIST" ]; then
  echo "✗ No App-Group preferences at:" >&2
  echo "  $PLIST" >&2
  echo "  Set CONDUCK_APP_GROUP if this Mac uses a different identity namespace." >&2
  exit 1
fi

python3 - "$PLIST" "$APPLY" <<'PY'
import json, plistlib, re, subprocess, sys, uuid as uuidmod

plist_path, apply = sys.argv[1], sys.argv[2] == "1"
with open(plist_path, "rb") as fh:
    data = plistlib.load(fh)

GATEWAY_ROSTER = "remoteAgent.customGateways"
ENDPOINT_ROSTER = "stt.customVoiceEndpoints"

# Mirrors SettingsManager.gatewayOwnedKeyPrefixes / voiceEndpointOwnedKeyPrefixes.
# Every prefix ends in a dot: that is what keeps a family from matching the
# legacy single-slot key it was derived from (`remoteAgent.url` is not
# `remoteAgent.url.`), which would put migration-read slots in scope.
GATEWAY_PREFIXES = [
    "remoteAgent.url.", "remoteAgent.authScheme.", "remoteAgent.model.",
    "remoteAgent.certFingerprint.", "remoteAgent.transportHint.",
    "remoteAgent.lastChatSuccess.",
    "fileServer.url.", "fileServer.available.", "fileServer.folderCapable.",
    "fileServer.certFingerprint.", "fileServer.testedLocally.",
    "fileServer.folderProbeRevision.", "fileServer.folderProbeAttempt.",
    "fileServer.keepImagesInline.",
    "imageHistory.policy.",
]
ENDPOINT_PREFIXES = [
    "stt.custom.url.", "stt.custom.model.", "stt.custom.authScheme.",
    "stt.custom.certFingerprint.", "tts.custom.model.",
]

def roster_ids(key, label):
    """Decode a roster, or refuse. 'Absent' and 'undecodable' are NOT 'empty'."""
    blob = data.get(key)
    if blob is None:
        sys.exit(f"✗ {label} roster ({key}) is absent. Refusing to treat that as "
                 f"'no {label}s' — that assumption is the whole reason this is not "
                 f"an in-app migration.")
    try:
        entries = json.loads(bytes(blob))
    except Exception as exc:
        sys.exit(f"✗ {label} roster ({key}) did not decode: {exc}. Refusing to run.")
    return {str(e["id"]).lower() for e in entries}

gateways = roster_ids(GATEWAY_ROSTER, "gateway")
endpoints = roster_ids(ENDPOINT_ROSTER, "voice endpoint")

def orphan(key):
    for p in GATEWAY_PREFIXES:
        if key.startswith(p):
            suffix = key[len(p):]
            if not suffix.startswith("custom_"):
                return None           # built-in suffix — never in scope
            suffix = suffix[len("custom_"):]
            break
    else:
        for p in ENDPOINT_PREFIXES:
            if key.startswith(p):
                suffix = key[len(p):]
                break
        else:
            return None
        try:
            uuidmod.UUID(suffix)
        except ValueError:
            return None
        return ("voice endpoint", suffix) if suffix.lower() not in endpoints else None
    try:
        uuidmod.UUID(suffix)
    except ValueError:
        return None                   # malformed suffix: leave it alone
    return ("gateway", suffix) if suffix.lower() not in gateways else None

doomed = {}
for key in sorted(data):
    hit = orphan(key)
    if hit:
        doomed.setdefault(hit, []).append(key)

print(f"App Group : {plist_path}")
print(f"Keys      : {len(data)}")
print(f"On roster : {len(gateways)} gateway(s), {len(endpoints)} voice endpoint(s)")
print()

if not doomed:
    print("✓ No orphaned per-uuid keys. Nothing to do.")
    sys.exit(0)

total = sum(len(v) for v in doomed.values())
for (kind, ident), keys in sorted(doomed.items()):
    print(f"  {kind} {ident} — {len(keys)} key(s)")
    for k in keys:
        print(f"      {k}")
print()
print(f"{total} key(s) across {len(doomed)} absent owner(s).")
print()
print("NOTE: this removes them from THIS MAC's App-Group plist only. Copies in the")
print("iCloud key-value store are left alone — the dual-written families there can")
print("re-hydrate on a later launch, so re-run this after one if keys reappear.")
print("That one-sided blast radius is the point: nothing here reaches your phone.")

if not apply:
    print()
    print("Dry run. Re-run with --apply to delete.")
    sys.exit(0)

print()
try:
    answer = input(f'Type "yes" to delete {total} key(s): ')
except EOFError:
    sys.exit("✗ No terminal to confirm on. Refusing to delete unattended.")
if answer.strip() != "yes":
    sys.exit("Aborted — nothing was deleted.")

domain = plist_path.rsplit("/", 1)[-1][: -len(".plist")]
for keys in doomed.values():
    for k in keys:
        subprocess.run(["defaults", "delete", domain, k], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(f"✓ Removed {total} key(s). Quit and relaunch Conduck to pick up the change.")
PY
