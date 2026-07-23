# Conduck QA Mode

Launch-arg-gated, DEBUG-only mode that boots the app into a verifiable state
for automated QA simulator runs and ad-hoc local debugging — **without a
working sim Keychain** (the unsigned simulator build cannot persist gateway
config there) and **without onboarding standing between the agent and the
conversation UI**.

**Conduck's QA mode talks to the REAL gateway over the network** — there is no
in-process offline mock. A typed turn produces a real, model-generated reply;
it is real and SLOW (30s–2min on modest self-hosted hardware). The deliberate
consequence: QA round-trips require the gateway to be running and reachable
from the machine under test.

## What QA mode does at boot

1. **Seeds the gateway config into an in-memory override** for both built-in
   backends (OpenClaw + Hermes) AND — when the custom flags are supplied — a
   **user-defined custom gateway** (a roster record `{name, model?}` + url +
   token, all in-memory; never written to the real registry/Keychain),
   bypassing the sim Keychain that the unsigned build can't write. After
   seeding, Settings → Personal AI shows each gateway's status pill as
   **"Configured"** — including the named custom row, which also demonstrates
   the "Add custom gateway" cap state (1 of `maxCustomGateways` used).
2. **Seeds 2 (or 3) sample conversations** — one bound to OpenClaw, one to
   Hermes, and (when a custom gateway is seeded) a third bound to the custom
   `custom_<uuid>` — each with a few turns, so the conversation list / search /
   swipe-delete / thread-switching / per-thread gateway badge all have content
   from the first frame.
3. **Skips onboarding** — the app lands directly in the populated
   conversation UI rather than the Welcome → STT-chooser flow.
4. **Sets the default backend to OpenClaw.** Because 2 gateways are
   configured, the title-bar gateway picker appears on a new/empty
   conversation.
5. **Renders a red `QA MODE` banner** above all content. If it's missing, the
   QA build did NOT activate.

## What QA mode does NOT change

The send path is real. A typed turn goes through the normal
`RemoteAgentClient` → `POST /v1/chat/completions` to the actual gateway. The
only difference from a production run is *where the gateway config came from*
(in-memory override vs Keychain) and *what conversations exist at boot* (2
seeds vs whatever the user has). Everything downstream of "config resolved" is
production code.

## Activation

QA mode is gated entirely by launch arguments. The DEBUG binary serves both
QA and dev runs without any rebuild.

```bash
xcrun simctl launch <UDID> com.example.Conduck \
  -ConduckQAMode \
  -ConduckQAOpenClawURL https://openclaw.example.com \
  -ConduckQAOpenClawToken <token> \
  -ConduckQAHermesURL https://hermes.example.com:8443 \
  -ConduckQAHermesToken <token> \
  -ConduckQADefaultBackend openclaw \
  -ConduckQACustomName "Home vLLM" \
  -ConduckQACustomURL https://my-gateway.example.com \
  -ConduckQACustomToken <token> \
  -ConduckQACustomModel llama3
```

| Flag | Purpose |
|---|---|
| `-ConduckQAMode` | Master switch. Without it, every QA hook no-ops; the binary boots the real onboarding/UI. |
| `-ConduckQAOpenClawURL <url>` | OpenClaw gateway HTTPS URL seeded into the OpenClaw config override. |
| `-ConduckQAOpenClawToken <token>` | OpenClaw bearer token seeded into the override. |
| `-ConduckQAHermesURL <url>` | Hermes gateway HTTPS URL seeded into the Hermes config override. |
| `-ConduckQAHermesToken <token>` | Hermes bearer token seeded into the override. |
| `-ConduckQADefaultBackend <backend>` | Which backend is the default pointer — `openclaw` or `hermes`. Drives the title-bar picker default. |
| `-ConduckQACustomURL <url>` + `-ConduckQACustomToken <token>` | **Optional.** Both required to seed a custom gateway (a fixed-UUID in-memory roster record). Omit the pair to test built-ins-only. |
| `-ConduckQACustomName <name>` | Optional custom-gateway display name (default "QA Custom Gateway") — the picker label + badge monogram source. |
| `-ConduckQACustomModel <model>` | Optional model string sent in the request `model` field (e.g. `llama3`) — exercises the model-on-wire path for a model-requiring server. Omit → model omitted (gateway default). |

## Where the tokens come from

The two bearer tokens live in your gitignored `.env` (template:
`.env.example`) as `OPENCLAW_GATEWAY_TOKEN` and `HERMES_API_SERVER_KEY`,
pointing at your own gateway instances. The automated QA harness — maintainer
tooling, not part of this repository; everything it does is reproducible
manually with the launch arguments above — `source`s that file at run time and
interpolates the values onto the launch-arg line — **the tokens are never
bundled into the app and never echoed to logs**. The gateway URLs are
non-secret config and are supplied to the harness as constants. If `.env` or a
token is missing, the harness warns and continues config-unseeded: the UI is
still testable, but sends will error.

## Gateway reachability

Because replies are real, a live round-trip needs the gateway reachable. The
harness runs a precheck:

```bash
curl -sf https://openclaw.example.com/v1/models \
  -H "Authorization: Bearer $OPENCLAW_GATEWAY_TOKEN"
```

A JSON response means live round-trips work. An HTML page means the chat
endpoint is off; a connection failure means the machine can't reach the gateway
(network/VPN down, or the server is down). In any failure case the run falls
back to **config-seeded-only**: the seeded UI and gateway-pill state are still
valid, but a typed send will surface an error from the `remoteAgent.error.*`
family rather than a reply.

## Production safety

The entire `QA/` namespace is wrapped in `#if DEBUG`. Release / App Store
builds physically cannot enter QA mode — the launch-arg parser, the
in-memory config override, the conversation seeder, and the banner don't exist
in the production binary. A clean personal build boots straight into real
onboarding with no seeded config or conversations. There are no QA secrets
bundled; the tokens enter only as runtime launch args sourced from `.env`.

## Other developer launch flags (independent of QA mode)

DEBUG-only flags that are NOT part of QA mode — they don't need `-ConduckQAMode`
and live in `QA/DebugFlags.swift` (separate `#if DEBUG` namespace).

| Flag | Purpose |
|---|---|
| `-ConduckShowOnboarding` | Force the onboarding wizard to appear on EVERY launch, regardless of the persisted `onboarding_completed` flag. The AMBIENT dev-convenience flag (lives enabled in the shared scheme for first-run iteration). The OPPOSITE of QA mode / `-ConduckSkipOnboarding`, which *skip* onboarding — and those explicit skip intents WIN if both are set (so an automated QA launch is never trapped on first-run; `RootView.init()` iOS / `AppDelegate` macOS precedence). Read-only override — never writes `UserDefaults`, so unsetting it restores normal behavior, and completing onboarding still lands you in the app for that session. Wires both iOS/iPad (`RootView`) and macOS (`AppDelegate`). Lets you iterate on first-run with a plain Cmd+R — no uninstall. Pre-added (enabled) to the `Conduck` scheme's Run ▸ Arguments; untick the checkbox to disable. |
| `-ConduckSkipOnboarding` | Skip the onboarding wizard on every launch WITHOUT any of QA mode's other side effects (no seeded conversations, no gateway override, no QA banner, no Keychain skip). For QA scenarios that must exercise the REAL, unseeded app minus first-run — empty conversation state, genuine settings persistence, etc. — where full `-ConduckQAMode` would mask the thing under test. Beats `-ConduckShowOnboarding` if both are set. Read-only override (never writes `UserDefaults`). Wires both iOS/iPad (`RootView`) and macOS (`AppDelegate`). |

## Limitations / out of scope

These stay developer / hardware gates and are NOT exercised by QA mode:

- **Real microphone / STT** — the sim has no real mic; QA verifies the typed
  composer path, not voice capture.
- **Shortcuts / App-Intent invocation** — the sim cannot bind App Intents.
- **Watch / CarPlay hardware round-trip** — sim-best-effort only; accept a
  log breadcrumb as evidence, not a cross-device receipt.
- **CloudKit sync** — cross-device conversation sync needs signed devices.
- **Signed Keychain persistence** — the whole reason QA mode uses an
  in-memory override; real Keychain restore-across-uninstalls is a
  signed-device gate.
- **In-process offline mock** — deliberately deferred. Conduck QA hits the
  real gateway; there is no canned-reply path, which is why an unreachable
  gateway degrades the run to config-seeded-only.
