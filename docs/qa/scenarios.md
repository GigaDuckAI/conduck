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
hold, but scenario 2 (live send) degrades to asserting on the in-flight or error
surface instead of a reply. Scenario 4 states its own degraded path.

**An unreachable gateway on iOS does not necessarily fail — it may park, and
that is by design.** The iPhone's gateway hop runs on a background
`URLSession`, which waits for connectivity and re-attempts connections outside
the app rather than surfacing a transport error. So a send to a host that is
down, refusing, or unresolvable can sit in flight indefinitely with no error at
all. That is not a hang and it is not a bug: the app may only fail a turn where
non-delivery is provable, and a request that has not moved on a device with a
route proves nothing. The honest assertion on this platform is therefore on the
IN-FLIGHT ROW's words — "Sending…" or "Waiting for a connection…", never
"{Gateway} is answering…", with Stop lit — and on what Stop then produces. Do
not read a persistent in-flight row here as a failure to report, and never
"fix" it with a client-side timeout: a drift-guard suite
(`ParkedConverseLaneDriftGuardTests`) exists to ban exactly that. macOS is the
platform that does fail fast; it sends on a foreground session.

**Targeting toolbar actions — coordinate-tap only.** SwiftUI `NavigationStack`
toolbars collapse the entire nav bar into one opaque `AXGroup` (`children: []`)
in the live `AXUIElement` tree that `axe` (an accessibility-driver CLI used
for simulator UI automation) reads, so the toolbar buttons are NOT
reachable by id OR by label — do not waste turns on `tap --id`/`--label` for
them. Tap by coordinate instead (iPhone 17 Pro, portrait, inline nav bar at
y≈89): Conversations x≈22, centered gateway-title/Clone x≈201, New conversation
x≈370. (The buttons carry `accessibilityIdentifier`s — `toolbar.*` — but those
surface to XCUITest/VoiceOver only, not to `axe`.) Non-toolbar controls
(composer, list rows, settings fields) ARE in the live tree — target those
normally.

Settings is not in that bar at all. On iPhone it is a leading item in the
conversation list's own nav bar (id `toolbar.settings`), so reaching it means
opening Conversations first and then tapping the leading edge of that list's
bar. It is a toolbar item like the rest, so the same collapse applies — tap it
by coordinate rather than by id, and measure that bar's y in the run instead of
reusing the value above, which belongs to the thread view. The bottom-pinned
Settings footer row exists only on the iPad and macOS sidebars.

---

## Scenario 1 — Seeded-conversation smoke

Launch args: `-ConduckQAMode -ConduckQAOpenClawURL <openclaw-url> -ConduckQAOpenClawToken <token> -ConduckQAHermesURL <hermes-url> -ConduckQAHermesToken <token> -ConduckQADefaultBackend openclaw`

Test instruction:

> Verify the red QA MODE banner is visible. Confirm the conversation list
> shows at least three pre-seeded threads. Open one — its prior turns should
> render in the thread (user bubbles plain, agent bubbles Markdown). Open
> Settings from the conversation list, go to Personal AI, and confirm that
> OpenClaw and Hermes each carry the green configured checkmark described in
> `qa-mode.md`. No live send required for this scenario.

Pass criteria:
- Banner visible.
- Conversation list has ≥ 3 threads.
- Opening a thread renders its seeded prior turns.
- OpenClaw and Hermes each carry the green configured checkmark in
  Settings → Personal AI.
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
gateway picker; once a conversation has turns its gateway is locked.

The gateway URL is deliberately never written to a log — a guard test enforces
it — so routing is verified from the title-bar binding, not from the log stream.

Test instruction:

> Verify the QA MODE banner. Start a NEW conversation. Confirm a gateway
> picker is present in the title bar (it appears only when ≥ 2 gateways are
> configured). Pick a gateway and send a short turn. Then start a second new
> conversation, pick the OTHER gateway, and send a turn there. Reopen each
> conversation and confirm its title bar shows the bound-gateway label (NOT
> the picker) for the gateway it was created on, and that the two
> conversations show different labels; with 2 gateways configured the label
> carries a `chevron.down` and tapping it opens the Clone & continue sheet.

Pass criteria:
- Title-bar gateway picker present on a new/empty conversation.
- Each of the 2 gateways is exercisable from its own new conversation.
- Reopening each conversation shows the bound-gateway label (not the picker)
  for the gateway it was created on, and the two conversations show different
  labels; clone-eligible threads show a `chevron.down` that opens the
  Clone & continue sheet.

Degraded path (gateway-reachability precheck failed):
- Routing UI (picker present, gateway bound after first turn) is still
  verifiable; only the actual reply degrades — on iOS to a parked in-flight row
  rather than an error surface, per the note in the setup section above.

---

## Scenario 4 — Negative path: unreachable gateway

Launch args: Scenario 1's, with `-ConduckQAOpenClawURL` pointed at an
unroutable host — `https://openclaw.invalid` — and the OpenClaw token left as
it is. The host is what makes the failure deterministic rather than
opportunistic: QA mode seeds the URL straight from the launch argument without
running the admissibility rules the Settings editor applies, so the failure has
to come from the address itself rather than from a rejected value — and
`.invalid` is reserved by RFC 2606, so it can never resolve. Hermes keeps its good URL, which leaves one working
gateway to contrast against.

Drive this one by hand. Every other scenario here seeds the good, reachable
URLs, which is the right default and also means none of them produces a
connection failure on demand.

Test instruction:

> Verify the QA MODE banner. Open an OpenClaw-bound conversation, type a turn,
> and send. TWO outcomes are correct on iOS and the run has to accept either.
> (a) The send fails and surfaces a `remoteAgent.error.*` recovery affordance —
> the retry card and error copy. (b) The send PARKS: the in-flight row stays up
> reading "Sending…" or "Waiting for a connection…" — never
> "{Gateway} is answering…" — with the composer's Stop control lit. In case (b),
> tap Stop and assert on the failed row it produces and its retry control. Then
> open the Hermes-bound conversation and send there, to confirm the behaviour
> belongs to the bad URL and not to the run.

Pass criteria:
- A bad-URL send either surfaces an error with recovery copy and a retry
  affordance, or parks in an in-flight row that never names the gateway and
  keeps Stop available.
- The parked row's words never claim the gateway is answering, and its elapsed
  clock is not attached to such a claim.
- Stop on a parked turn produces a failed row with a retry affordance, and its
  copy does not send the user to check a server that was never contacted.
- The app does not crash.
- The Hermes-bound conversation still sends, so the behaviour is attributable
  to the unroutable host.

Degraded path (gateway-reachability precheck failed):
- The OpenClaw half still holds — the failure-or-park surface is the thing
  under test. The Hermes contrast does not; skip that step.
