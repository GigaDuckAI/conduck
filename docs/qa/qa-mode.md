# Conduck QA Mode

The manual scenarios that use these flags: [scenarios.md](scenarios.md).

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

1. **Seeds the gateway config into an in-memory override** for the two
   self-hosted built-in gateways (OpenClaw + Hermes) AND — when the custom
   flags are supplied — a **user-defined custom gateway** (a roster record
   `{name, model?}` + url + token, all in-memory; never written to the real
   registry/Keychain), bypassing the sim Keychain that the unsigned build
   can't write. After seeding, Settings → Personal AI marks each seeded
   gateway with a small green checkmark, which is the app's only "configured"
   indicator. There is no status pill and no visible word "Configured": the
   checkmark carries "Configured" as its VoiceOver label and nothing more, so
   looking for that text on screen finds nothing. The named custom row gets
   the same checkmark and also demonstrates the cap state under "Set up a
   custom server" (one of `Constants.maxCustomGateways` used).
2. **Seeds three sample conversations** — one bound to OpenClaw, one bound to
   Hermes, and a second OpenClaw thread that is a long Markdown-heavy
   scroll-stress transcript (headings, nested lists, inline code, fenced code
   blocks) for exercising lazy bubble layout. Supplying the custom flags adds
   a fourth, bound to the custom `custom_<uuid>`. Each thread carries several
   turns, so the conversation list / search / swipe-delete / thread-switching /
   per-thread gateway badge all have content from the first frame. That is the
   `-ConduckQAMode` seed set; `-ConduckQAScreenshotMode` seeds three threads
   too, but curated marketing ones carrying attachments instead of these.
3. **Skips onboarding** — the app lands directly in the populated
   conversation UI rather than the Welcome → STT-chooser flow.
4. **Sets the default gateway** to whatever `-ConduckQADefaultBackend` names,
   and to OpenClaw when that flag is absent. Because the launch arguments above
   configure two gateways, the title-bar gateway picker appears on a new/empty
   conversation — supply both URL+token pairs, or only one gateway is seeded and
   the picker will not appear.
5. **Renders a red `QA MODE` banner** above all content. If it is missing on a
   `-ConduckQAMode` launch, the QA build did NOT activate. The banner is not a
   universal activation signal: `-ConduckQAScreenshotMode` activates QA mode
   with the banner deliberately suppressed, because a red strip would ruin an
   App Store capture — so on that launch its absence is expected and proves
   nothing.

## What QA mode does NOT change

The send path is real. A typed turn goes through the normal
`RemoteAgentClient` → `POST /v1/chat/completions` to the actual gateway. The
only difference from a production run is *where the gateway config came from*
(in-memory override vs Keychain) and *what conversations exist at boot* (the
seeded threads vs whatever the user has). Everything downstream of "config
resolved" is production code.

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
| `-ConduckQADefaultBackend <backend>` | Which gateway is the default pointer — `openclaw` or `hermes`. Drives the title-bar picker default. |
| `-ConduckQACustomURL <url>` + `-ConduckQACustomToken <token>` | **Optional.** Both required to seed a custom gateway (a fixed-UUID in-memory roster record). Omit the pair to test built-ins-only. |
| `-ConduckQACustomName <name>` | Optional custom-gateway display name (default "QA Custom Gateway") — the picker label + badge monogram source. |
| `-ConduckQACustomModel <model>` | Optional model string sent in the request `model` field (e.g. `llama3`) — exercises the model-on-wire path for a model-requiring server. Omit → model omitted (gateway default). |

## Where the tokens come from

Both tokens belong to **your own** gateway instances. Nothing in this
repository stores or reads them: you paste each onto the launch-arg line
above. **They are never bundled into the app and never echoed to logs.** The
gateway URLs are non-secret config.

**OpenClaw** — read `gateway.auth.mode` in `~/.openclaw/openclaw.json` on your
server first, because it decides which credential the gateway checks. In `token`
mode — also the behaviour when the key is absent — the credential is
`gateway.auth.token`. In `password` mode it is `gateway.auth.password`, which
rides in the same bearer header. `none` means the gateway is keyless, so launch
without a token flag at all. `trusted-proxy` means the credential belongs to the
proxy in front of the gateway and cannot be read out of this file.

Whichever key applies, what you paste must be the literal value. A `${SOME_VAR}`
placeholder or a `{source: env|file|exec, …}` object is a *reference* to the
secret rather than the secret, so pasting it verbatim yields a plausible-looking
token that silently fails auth — resolve it first and paste the result.

If the config carries no credential key at all, the value is
`OPENCLAW_GATEWAY_TOKEN` in the Docker compose `.env` — that is the one case
where the compose file holds the real credential. Otherwise the token there is
only a setup seed and can drift from what the gateway actually checks.

**Hermes** — use the value at `API_SERVER_KEY` in `~/.hermes/.env` on your
server. Hermes does not generate one; if the key is absent, add it with a long
random value. Hermes also ships its OpenAI API server switched **off**, so the
same file needs `API_SERVER_ENABLED=true` — then restart Hermes.

If you keep these in a local `.env` for convenience, note that it is gitignored
and read by nothing here — it is a paste-source, not configuration.

The automated QA harness is maintainer tooling and is **not part of this
repository**; everything it does is reproducible manually with the launch
arguments above. Launching with a token missing is supported: the UI is fully
testable config-unseeded, but sends will error.

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
back to **config-seeded-only**: the seeded UI and the gateway-configured
checkmarks are still valid, but a typed send will surface an error from the
`remoteAgent.error.*` family rather than a reply.

## Production safety

The entire `QA/` namespace is wrapped in `#if DEBUG`. Release / App Store
builds physically cannot enter QA mode — the launch-arg parser, the
in-memory config override, the conversation seeder, and the banner don't exist
in the production binary. A clean personal build boots straight into real
onboarding with no seeded config or conversations. There are no QA secrets
bundled; the tokens enter only as runtime launch args sourced from `.env`.

## Other developer launch flags (independent of QA mode)

DEBUG-only flags that are NOT part of QA mode — they don't need `-ConduckQAMode`
and live in `QA/DebugFlags.swift` (separate `#if DEBUG` namespace), except where
a row notes otherwise.

| Flag | Purpose |
|---|---|
| `-ConduckShowOnboarding` | Force the onboarding wizard to appear on EVERY launch, regardless of the persisted `onboarding_completed` flag. The AMBIENT dev-convenience flag (pre-added to the shared scheme for first-run iteration). The OPPOSITE of QA mode / `-ConduckSkipOnboarding`, which *skip* onboarding — and those explicit skip intents WIN if both are set (so an automated QA launch is never trapped on first-run; `RootView.init()` iOS / `AppDelegate` macOS precedence). Read-only override — never writes `UserDefaults`, so unsetting it restores normal behavior, and completing onboarding still lands you in the app for that session. Wires both iOS/iPad (`RootView`) and macOS (`AppDelegate`). Lets you iterate on first-run with a plain Cmd+R — no uninstall. Pre-added to the `Conduck` scheme's Run ▸ Arguments and shipped unticked, like every argument in that block; tick the checkbox to enable it. |
| `-ConduckSkipOnboarding` | Skip the onboarding wizard on every launch WITHOUT any of QA mode's other side effects (no seeded conversations, no gateway override, no QA banner, no Keychain skip). For QA scenarios that must exercise the REAL, unseeded app minus first-run — empty conversation state, genuine settings persistence, etc. — where full `-ConduckQAMode` would mask the thing under test. Beats `-ConduckShowOnboarding` if both are set. Read-only override (never writes `UserDefaults`). Wires both iOS/iPad (`RootView`) and macOS (`AppDelegate`). |
| `-ConduckUncapCustomGateways` | Lift `Constants.maxCustomGateways` to the badge-palette ceiling (`RemoteAgentBadgePalette.customPalette.count`) so a dev/QA rig can wire more custom gateways than the shipping cap allows — e.g. the whole test fleet in one Debug build. Lives beside the constant in `Utilities/Constants.swift`, NOT in `QA/DebugFlags.swift`: the Watch target compiles that file but not `QA/`. Read once at launch; Release builds contain no override path. Pre-added unticked to the shared scheme's Run ▸ Arguments. |

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
- **OpenRouter** — three built-in gateways ship, and OpenRouter is the hosted
  lane rather than a server of your own. It is configured with an API key and a
  model instead of a URL and a token, so the URL+token flags above cannot
  express it and QA mode does not seed it. Exercising OpenRouter means
  configuring it by hand on a signed device.
