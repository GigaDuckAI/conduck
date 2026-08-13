# Conduck QA Scenarios

Each scenario is one QA run. Read the relevant section before the run and use
it to scope what you exercise.

Setup background for every scenario (automated by the maintainer-side QA
harness — not part of this repository; the manual equivalent is the launch-arg
flow in `qa-mode.md`): build the
Debug binary, install to a per-run ephemeral simulator, source `.env` for the
gateway tokens, run the gateway-reachability precheck, launch with the QA
launch args, and verify the red `QA MODE` banner is visible. Conduck has no
backend / DB — state assertions come from UI screenshots + the run's own
`xcrun simctl spawn <UDID> log stream --predicate 'process == "Conduck"'`
filter, never from database queries.

Live round-trips depend on the gateway being reachable: if the Step-2 precheck
warned the gateway was unreachable, scenarios 1 and 3 (seeded-state / UI) still
hold, but scenario 2 (live send) degrades to asserting on the error surface
instead of a reply.

**Targeting toolbar actions — coordinate-tap only.** SwiftUI `NavigationStack`
toolbars collapse the entire nav bar into one opaque `AXGroup` (`children: []`)
in the live `AXUIElement` tree that `axe` (an accessibility-driver CLI used
for simulator UI automation) reads, so the toolbar buttons are NOT
reachable by id OR by label — do not waste turns on `tap --id`/`--label` for
them. Tap by coordinate instead (iPhone 17 Pro, portrait, inline nav bar at
y≈89): Conversations x≈22, centered gateway-title/Clone x≈201, New conversation x≈370. Settings is a conversation-list footer row (id `toolbar.settings`) — in the live tree, tap by id or row coordinate, not a nav-bar coordinate. (The buttons
carry `accessibilityIdentifier`s — `toolbar.*` — but
those surface to XCUITest/VoiceOver only, not to `axe`.) Non-toolbar controls
(composer, list rows, settings fields) ARE in the live tree — target those
normally.

---

## Scenario 1 — Seeded-conversation smoke

Launch args: `-ConduckQAMode -ConduckQAOpenClawURL <openclaw-url> -ConduckQAOpenClawToken <token> -ConduckQAHermesURL <hermes-url> -ConduckQAHermesToken <token> -ConduckQADefaultBackend openclaw`

Test instruction:

> Verify the red QA MODE banner is visible. Confirm the conversation list
> shows at least 2 pre-seeded threads. Open one — its prior turns should
> render in the thread (user bubbles plain, agent bubbles Markdown). Go to
> Settings → Personal AI and confirm both OpenClaw and Hermes show a
> "Configured" status pill. No live send required for this scenario.

Pass criteria:
- Banner visible.
- Conversation list has ≥ 2 threads.
- Opening a thread renders its seeded prior turns.
- Both gateways show "Configured" in Settings → Personal AI.
- No errors in the app's debug log stream.

---

## Scenario 2 — Live typed round-trip

Launch args: same as Scenario 1.

Test instruction:

> Verify the QA MODE banner. Open one of the seeded conversations (or start a
> new one). Type a short message in the composer and send it. The in-flight
> "answering…" indicator with an elapsed clock should appear — this is
> EXPECTED; the reply is a real gateway round-trip and is SLOW. Wait up to
> ~2 minutes. Confirm a real agent reply bubble appears and persists in the
> thread. Screenshot the resulting thread.

Pass criteria:
- Banner visible.
- The in-flight "answering…" / elapsed-clock state renders during the wait
  (NOT treated as a hang).
- A real agent reply bubble appears within ~2 minutes and persists.

Degraded path (gateway-reachability precheck failed):
- Instead of a reply, the send surfaces a `remoteAgent.error.*` failure with
  a retry affordance — assert on that failure surface, not on a reply.

---

## Scenario 3 — Multi-gateway routing

Launch args: same as Scenario 1.

Because 2 gateways are configured, a new/empty conversation shows a title-bar
gateway picker; once a conversation has turns its backend is locked.

Test instruction:

> Verify the QA MODE banner. Start a NEW conversation. Confirm a gateway
> picker is present in the title bar (it appears only when ≥ 2 gateways are
> configured). Pick a backend, send a short turn, and confirm the reply
> routes through the chosen gateway (correlate via the log stream — the
> request goes to the chosen gateway's URL). Then start a second new
> conversation, pick the OTHER backend, send a turn, confirm it routes to
> that gateway. Reopen the first conversation and confirm its title bar now
> shows the bound-gateway label (NOT the picker) matching the backend you
> originally chose; with 2 gateways configured the label carries a `chevron.down`
> and tapping it opens the Clone & continue sheet.

Pass criteria:
- Title-bar gateway picker present on a new/empty conversation.
- A turn routes to the selected gateway (log-stream evidence: request hits
  the chosen gateway URL).
- Each of the 2 backends is exercisable from its own new conversation.
- Reopening a conversation with turns shows the bound-gateway label (not the
  picker), matching the originally chosen backend; clone-eligible threads show a
  `chevron.down` that opens the Clone & continue sheet.

Degraded path (gateway-reachability precheck failed):
- Routing UI (picker present, backend bound after first turn) is still
  verifiable; only the actual reply degrades to an error surface.

---

## Scenario 4 — Negative path: unreachable / bad gateway (future variant)

Status: NOT exercised by the default harness. The harness always seeds the
GOOD, reachable gateway URLs, so it cannot produce a deterministic connection
failure on demand.

To verify the error surface deliberately (rather than relying on an
opportunistic gateway outage), a future / manual variant should launch QA mode
with a deliberately bad URL — e.g. swap `-ConduckQAOpenClawURL` for an
unroutable host (`https://openclaw.invalid`) while keeping the token. Expected
behavior:

> Open the OpenClaw-bound conversation, type a turn, send. The send should
> fail and surface a `remoteAgent.error.*` recovery affordance (the retry
> card / error copy), NOT hang indefinitely. Assert on the failure surface
> and the presence of a retry control.

Pass criteria (manual variant):
- A bad-URL send surfaces an error with recovery copy + a retry affordance.
- The app does not hang or crash on the failure.

Until a `-ConduckQABadBackend`-style harness lever exists, this is a manual
launch-arg override, not an automated QA scenario.
