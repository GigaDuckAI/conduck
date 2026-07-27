#!/bin/bash
#
# Run Conduck's LIVE TLS certificate-pinning tests
# (`ConduckTests/RemoteAgentLiveTLSTrustTests`) against a real loopback HTTPS
# server with a self-signed certificate.
#
# WHY A RUNNER SCRIPT AND NOT A SELF-CONTAINED TEST: the macOS test host is the
# sandboxed Conduck app. The App Sandbox denies `bind()` to the app and to every
# process it spawns, so the fixture cannot be started from inside a test —
# Python fails with `PermissionError: [Errno 1] Operation not permitted` before
# a single socket is bound. Granting `com.apple.security.network.server` would
# fix it by giving a client-only app the ability to listen, which is not a trade
# worth making for a test. So the fixture runs HERE, outside the sandbox, and
# hands the tests its ports + the expected pins through a file inside the app's
# own container — the one place a sandboxed app can read.
#
# The expected pins are computed by OPENSSL:
#   openssl x509 -pubkey | openssl pkey -pubin -outform DER | openssl dgst -sha256
# — the same recipe a user follows to pin their own gateway, and deliberately
# NOT the app's own `spkiDER(from:)`. A test that asks the code under test what
# the right answer is cannot catch that code drifting.
#
# Usage:
#   scripts/run-live-tls-tests.sh [extra xcodebuild args...]
#
# Extra args are appended to the xcodebuild invocation, so a narrower or wider
# selection works:
#   scripts/run-live-tls-tests.sh -only-testing:ConduckTests/RemoteAgentLiveTLSTrustTests/testSameOriginRedirectIsFollowed
#
# Exits with xcodebuild's status. The fixture is always torn down.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT="$REPO_ROOT/Conduck/Conduck.xcodeproj"
CONFIGS="$REPO_ROOT/Conduck/Configs"
DERIVED_DATA="${CONDUCK_DERIVED_DATA:-$HOME/Library/Caches/gigaduck-builds/live-tls}"

[ -f "$PROJECT/project.pbxproj" ] || { echo "no Xcode project at $PROJECT" >&2; exit 2; }

# --- the app's container, the only path a sandboxed test can read -------------
#
# `Identity-Override.xcconfig` (gitignored, private) wins over the community
# defaults, exactly as the build does.
read_identity() {
  local key="$1" value=""
  for file in "$CONFIGS/Identity.xcconfig" "$CONFIGS/Identity-Override.xcconfig"; do
    [ -f "$file" ] || continue
    local found
    found="$(sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*//p" "$file" | tail -1)"
    [ -n "$found" ] && value="$found"
  done
  printf '%s' "$value"
}

BUNDLE_ID="$(read_identity CONDUCK_BUNDLE_ID_BASE)"
[ -n "$BUNDLE_ID" ] || { echo "could not read CONDUCK_BUNDLE_ID_BASE from $CONFIGS" >&2; exit 2; }
CONTAINER_TMP="$HOME/Library/Containers/$BUNDLE_ID/Data/tmp"
HANDOFF="$CONTAINER_TMP/conduck-live-tls-fixture.json"

# --- tools -------------------------------------------------------------------

pick_tool() {
  local name="$1"; shift
  for candidate in "$@"; do
    [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
  done
  echo "no $name found (tried: $*)" >&2
  return 2
}

# `/usr/bin/openssl` is a real LibreSSL binary. `/usr/bin/python3` is an xcrun
# shim, fine here (this script is not sandboxed) but preferred last anyway.
OPENSSL="$(pick_tool openssl /usr/bin/openssl /opt/homebrew/bin/openssl /usr/local/bin/openssl)"
PYTHON="$(pick_tool python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 \
  /Library/Developer/CommandLineTools/usr/bin/python3 /usr/bin/python3)"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/conduck-live-tls.XXXXXX")"
FIXTURE_PID=""

cleanup() {
  if [ -n "$FIXTURE_PID" ]; then
    kill "$FIXTURE_PID" 2>/dev/null || true
    wait "$FIXTURE_PID" 2>/dev/null || true
  fi
  rm -f "$HANDOFF"
  rm -rf "$WORKDIR"
}
trap cleanup EXIT INT TERM

# --- certificates ------------------------------------------------------------
#
# EC via `ecparam ... -param_enc named_curve`, NOT `req -newkey ec`: on the
# LibreSSL that ships with macOS the latter emits EXPLICIT curve parameters in
# the SubjectPublicKeyInfo. Apple's TLS stack refuses such a certificate
# outright (handshake dies with a decode error, the challenge never fires), and
# its SPKI would not match the app's named-curve prefix either — the fixture
# would fail for a reason that has nothing to do with the code under test.
"$OPENSSL" ecparam -name prime256v1 -genkey -noout -param_enc named_curve \
  -out "$WORKDIR/ec-key.pem" 2>/dev/null
"$OPENSSL" req -new -x509 -key "$WORKDIR/ec-key.pem" -out "$WORKDIR/ec-cert.pem" \
  -days 2 -subj "/CN=conduck-loopback-ec" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
"$OPENSSL" req -new -x509 -newkey rsa:2048 -nodes \
  -keyout "$WORKDIR/rsa-key.pem" -out "$WORKDIR/rsa-cert.pem" \
  -days 2 -subj "/CN=conduck-loopback-rsa" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null

spki_pin() {
  local cert="$1" digest
  # LibreSSL prints a bare digest; OpenSSL prefixes `SHA2-256(...)= `. Take the
  # last field either way.
  digest="$("$OPENSSL" x509 -pubkey -noout -in "$cert" \
    | "$OPENSSL" pkey -pubin -outform DER \
    | "$OPENSSL" dgst -sha256 | awk '{print $NF}')"
  case "$digest" in
    # SHA-256 of nothing: what an empty pipeline yields. A pin equal to it would
    # make every "match" assertion compare two mistakes.
    e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855|"")
      echo "openssl produced no usable SPKI digest for $cert" >&2; exit 2 ;;
  esac
  printf '%s' "$digest"
}

EC_PIN="$(spki_pin "$WORKDIR/ec-cert.pem")"
RSA_PIN="$(spki_pin "$WORKDIR/rsa-cert.pem")"

# --- fixture -----------------------------------------------------------------

mkfifo "$WORKDIR/stdin.fifo"
"$PYTHON" "$SCRIPT_DIR/live-tls-fixture.py" "$WORKDIR" \
  < "$WORKDIR/stdin.fifo" > "$WORKDIR/stdout.log" 2> "$WORKDIR/stderr.log" &
FIXTURE_PID=$!
# Hold the write end open for the life of this script: closing it (on exit, or
# on a crash) is the fixture's EOF teardown signal, so it can never be orphaned.
exec 9> "$WORKDIR/stdin.fifo"

for _ in $(seq 1 200); do
  [ -f "$WORKDIR/ports.json" ] && break
  kill -0 "$FIXTURE_PID" 2>/dev/null || break
  sleep 0.1
done
if [ ! -f "$WORKDIR/ports.json" ]; then
  echo "the loopback TLS fixture never reported its ports:" >&2
  cat "$WORKDIR/stderr.log" >&2 || true
  exit 2
fi

# --- hand off to the sandboxed test ------------------------------------------

mkdir -p "$CONTAINER_TMP"
"$PYTHON" - "$WORKDIR/ports.json" "$EC_PIN" "$RSA_PIN" "$HANDOFF" <<'PY'
import json, os, sys
ports_path, ec_pin, rsa_pin, out = sys.argv[1:5]
with open(ports_path) as handle:
    payload = json.load(handle)
payload["ecPin"] = ec_pin
payload["rsaPin"] = rsa_pin
tmp = out + ".tmp"
with open(tmp, "w") as handle:
    json.dump(payload, handle)
os.rename(tmp, out)
PY

echo "live TLS fixture up: $(cat "$WORKDIR/ports.json")"
echo "  ec  pin $EC_PIN"
echo "  rsa pin $RSA_PIN"
echo "  handoff $HANDOFF"

# --- run ---------------------------------------------------------------------
#
# SIGNED (no `CODE_SIGNING_ALLOWED=NO`): an unsigned macOS host crashes before
# the tests start (no App Group / KVS / CloudKit entitlements), and the signed
# suite is the project's standard anyway.
set +e
xcodebuild test \
  -project "$PROJECT" \
  -scheme Conduck \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  -only-testing:ConduckTests/RemoteAgentLiveTLSTrustTests \
  "$@"
STATUS=$?
set -e
exit "$STATUS"
