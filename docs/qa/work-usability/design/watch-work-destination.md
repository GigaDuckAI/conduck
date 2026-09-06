# Watch — Work as a destination in the Ask chooser

Lane: Apple Watch Work destination. Tip read: `a197ccd`. Status: **design, final** (Codex rounds 1–3 folded in; round 3 found no open finding after the four corrections it named; see "Codex rounds" at the end).

## The founder's intent, verbatim

> Then on the watch its just for recording. when the user presses ask, he can select work as a destination (even if only 1 gateway is configured). when sending there its basically also only a stt step.

## What the lane does today

| Surface | Behaviour at `a197ccd` |
|---|---|
| Launchpad (`WatchNoteView.launchpadView`) | Duck · prominent orange **Ask** · a *bordered* **Save to Work** button (`watch.work.launchpad.save`, `tray.and.arrow.down.fill`) · **Conversations**. Both capture buttons sit inside the "Enable on Watch" master-switch branch and are greyed while `recordingService.isBusy && path.isEmpty`. |
| **Ask** (`beginInAppAsk`) | `refuseAskIfBusy()` → `configuredBackendRefs()`; **≥ 2** gateways → `confirmationDialog("Ask which gateway?")` with one row per gateway; **0 or 1** → `pushNewCapture(ref: configured.first ?? defaultBackendRef)` straight into a new draft thread. With **zero** gateways the draft thread is pushed anyway and the turn fails inside it later with "Set up your personal AI on iPhone first." |
| **Save to Work** (`beginWorkCapture`) | `refuseAskIfBusy()` → push `WatchRoute.workCapture(nonce:)` → `startWorkCapture(requestID:)` at the push site; the push ignores the start's return value on purpose, because a capacity refusal is *rendered* by the pushed screen from `workCaptureOutcome`. `WatchWorkCaptureView` renders the recorder and one terminal line; the phone publishes the clip to the desk, then transcribes and attaches the words (`RelayReply { text; workSaved }`), never a converse hop. |
| Headless (Action Button / ControlWidget / `RecordNoteIntent`) | `resolveHeadlessCaptureTarget()` → `HeadlessDrainDecision` → continue-or-new on the **default gateway**. Never Work. |
| Siri text lane (`CaptureWorkboardIntent`, "Add to Work") | Text-only note straight onto the desk, hands-free and explicit. Untouched by this lane. |
| Capture chrome | A draft thread's `navigationTitle` is `threadBackendName`, which is **empty until the conversation is minted**, and `.toolbar(.hidden)` while capturing; `WatchThreadCaptureOverlay` names no destination. The Work screen is titled by `watch.work.capture.title`. |
| Tests that pin it | `WatchWorkCaptureUITests` (route identity, terminal copy), `WatchHeadlessDrainDecisionTests`, `WatchCaptureGuardTests` (headless refusals, the Ask-hint mint), relay retryability tests. **Nothing pins the launchpad button, the `≥ 2` threshold, the chooser title, or `startWorkCapture` itself** — the c3 fixnote says the button order is a founder-QA item. |

The code comment in `beginWorkCapture` argues for the separate button: *"A sticky destination toggle fails in exactly one direction and it is the unrecoverable one: a private thought reaching an AI because a switch was still flipped from last time."* That is an argument against a **sticky mode**. A row in a chooser that opens on **every** Ask press is not sticky: there is no last-destination preference, every press asks again, and each accepted capture stamps its lane explicitly (`startCapture` stamps `.chat` and writes the Ask hint; `startWorkCapture` stamps `.work` and clears the hint and every conversation pin). What a per-press chooser cannot rule out is an honest mis-tap, which is why decision 7 puts the picked destination on the capture screen itself.

## Verdict

**change_required.** The implementation does not match the intent on three points: Work is a separate button, not a destination in the Ask chooser; the chooser is skipped with one gateway; and with zero gateways Ask opens a thread that cannot send instead of offering the one destination that works. The change reuses every existing path — the chooser, `pushNewCapture`, `beginWorkCapture`, `WatchRoute.workCapture`, `startWorkCapture`, the relay — and adds no state.

## Decisions

| # | Decision | Why |
|---|---|---|
| 1 | **Work is the last row of the Ask chooser; the launchpad's separate "Save to Work" button is removed.** | The founder's stated shape. One fewer button on a 41 mm face; one entry point for "record something" instead of two that look alike. A per-press choice has no last-destination preference, so the sticky-mode objection does not apply. |
| 2 | **The chooser opens on every Ask press — 0, 1 or N gateways — and stays a `confirmationDialog`.** | Verbatim founder intent ("even if only 1 gateway is configured"). Cost: one extra tap per Ask on a single-gateway watch. The existing chooser is reused rather than a new list sheet: for the common roster (one or two gateways) that is two or three rows plus Cancel; a longer roster scrolls. Acceptance is a QA step, not a claim: the **maximum supported roster** with long, similar names, at the largest text size and under VoiceOver, on a 41 mm face — every label readable, every row selectable without accidental activation while scrolling. The presentation changes to a list sheet only if that fails. |
| 3 | **Row order: gateways in roster order (`configuredBackendRefs()`: built-ins in enum order, then customs), then Add to Work as the last destination; dismissal is the system's Cancel, wherever watchOS places it.** | Ask is the AI button, so the AI rows lead; for the common single-gateway roster that is one gateway row above Add to Work. Work last is a stable *relationship*, not a fixed position; on a long roster it is a scroll away, which is accepted. (Codex preferred Work first in round 1 and withdrew the objection in round 2.) |
| 4 | **Work row wording: "Add to Work"** (new key `watch.ask.destination.work`), and the Work capture screen's title becomes "Add to Work" too (new key `watch.work.capture.navigationTitle`; `watch.work.capture.title` retired). | One name per thing: the action of putting a recording on the desk from a satellite surface is "Add to Work" on CarPlay's picker row, in the wrist's own Siri intent, in the Mac compose header and in Shortcuts; the wrist's "Save to Work" was the one outlier, and on the same wrist Siri says "Add to Work". A bare "Work" is rejected because a custom gateway can be *named* "Work" and two identical rows would be the worst possible chooser. The receipt stays "Saved to Work." on the wrist as it does in the car. |
| 5 | **Chooser title: "Where to?"** (new key `watch.ask.destination.title`); "Ask which gateway?" is retired. | The old title is false the moment Work is a row. "Where to?" is the shortest honest question and contains no word for sending (the Work fixnote's rule). The title stays visible so the sheet is named for VoiceOver and a first-time user is not looking at a bare gateway name. |
| 6 | **Zero gateways: the chooser still opens with Add to Work as its only row, and the dialog's message is a new short line, "No personal AI available."** (new key `watch.ask.destination.noAI`). The existing refusal "Set up your personal AI on iPhone first." is **not** reused here. | The watch is a useful private recorder with no AI at all, and today's zero-gateway Ask pushes a thread that can only fail. The existing sentence says "first", which above the one row that works reads as a prerequisite for recording; and its meaning is pinned by `WatchCaptureGuardTests` for the headless lane. "Available" is the honest word under the I3 ambiguity — an empty roster is also what a locked keychain or an un-hydrated wrist reads — and it promises nothing about the phone: a deferred save and a full queue still say their own lines. |
| 7 | **The picked destination is visible while recording, wrist raised.** A `.new` draft thread shows the picked gateway's short name during arming and recording, in `WatchThreadCaptureOverlay` as one secondary caption above the ring; the Work screen already carries its title. Scope stated honestly: a `.existing` thread names its persisted ref (empty while the roster is still loading, and empty by the existing rule for a custom missing from both rosters); AOD shows no destination, as today. | Codex round 1: `pushNewCapture` starts the service synchronously and the draft's toolbar is hidden while capturing, so a mis-tapped gateway row would record and dispatch with no destination cue on screen. One caption line closes that for the case the chooser creates. |
| 8 | **Master switch re-checked at both push sites**, after the busy refusal and before any route push, hint write or start; an open chooser is dismissed when the switch turns off. | Pre-existing gap the chooser now widens to every Ask: the switch is read only when the launchpad is drawn, and the dialog is attached outside the enabled branch, so a row picked after the phone turned the wrist off would still start. A live capture is still never interrupted by the switch. |
| 9 | **Headless triggers are untouched.** Action Button / ControlWidget / `RecordNoteIntent` keep resolving to the default gateway through `HeadlessDrainDecision` and never reach Work; the Siri "Add to Work" text intent stays as is. Precisely: **no implicit or hands-free trigger reroutes to Work** — the only hands-free door to the desk is the one that names Work in its own phrase. | Not asked for, and a trigger with no screen in front of the person routing a thought to the desk (or the reverse) is the silent reroute the spec forbids. |
| 10 | **Busy ordering unchanged:** `beginInAppAsk` refuses before the chooser opens; each row re-checks at its push site because the sheet can be answered seconds later. The dialog stays attached to the launchpad `VStack`, not to the (disabled) Ask button. Every path that replaces the root's navigation or takes over the root also dismisses an open chooser: the headless proceed arms (`.directStart` / `.pushAndStart`), the headless refusal arms that write a root `.error`, and an accepted notification deep link. | Existing rule and reason (an Action-Button press while the sheet is open must not leave every row dead). `refuseAskIfBusy` logging `"ask.refused"` for a Work pick is now accurate, since Work is reached through Ask — U-18 closes. |
| 11 | **Route identity and service contract unchanged.** The Work row calls `beginWorkCapture()`; `WatchRoute.workCapture(nonce:)` keeps carrying no `WatchCaptureTarget`; `WatchCaptureDestination` stays a separate axis; the push still ignores `startWorkCapture`'s return value so a capacity refusal is rendered by the screen. No new persisted state: the only thing written is the Ask hint an accepted gateway capture already writes, and `startWorkCapture` clears it. | The structural guarantees c2/c3 built are what make the chooser safe: a Work pick cannot mint, pin or hint a conversation, and a gateway pick cannot inherit `.work`. |
| 12 | **Launchpad busy caption:** while a Work capture owns the machine after recording (`captureDestination == .work`, `isBusy`, not capturing), the launchpad shows "Saving to Work…" (existing key `watch.work.capture.saving`) instead of "Still answering your last question." | The Work screen's back button is enabled once the mic is off, so the launchpad can be reached mid-save; describing a private save as answering a question is the one sentence this lane must never show. |
| 13 | **Master switch: Work stays behind the same gate as Ask.** | Unchanged; U-17 remains a founder call. A Work capture still needs the iPhone leg the switch governs. |
| 14 | **The testable half is a pure row builder**, `WatchAskDestinationRows`, kept in `WatchNoteView.swift` beside the view that owns it (the `WatchWorkCaptureCopy` pattern), plus service-level tests for the lane transitions and the capacity hand-off that nothing pins today. | The wiring "Ask always opens the chooser" is two lines of view code and is pinned by founder QA, not by a text guard. |

## Change list

### `Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift`

1. **Header comment** (lines 6–14): the two triggers no longer both push chat threads. Rewrite: Ask = destination chooser on every press (every configured gateway, then Add to Work) → a new draft thread or the Work capture screen; headless = default gateway → continue-or-new, never Work.
2. **State:** rename `showGatewayChooser` → `showDestinationChooser`. Keep `askGatewayRefs: [String]` and its snapshot comment (the per-ref Keychain read reason still holds).
3. **`beginInAppAsk()`**:
   ```swift
   /// In-app "Ask" entry point. Opens the destination chooser on EVERY press —
   /// every configured gateway in roster order, then Add to Work — so Work is
   /// always offered beside the gateways and no press silently assumes one. A
   /// gateway row starts a NEW conversation bound to that gateway; the Work row
   /// starts a private capture that reaches no gateway. Headless triggers never
   /// come here.
   private func beginInAppAsk() {
       guard !refuseAskIfBusy() else { return }
       askGatewayRefs = settingsReader.configuredBackendRefs()
       showDestinationChooser = true
   }
   ```
   Delete the `count >= 2` branch and the direct `pushNewCapture(ref: configured.first ?? settingsReader.defaultBackendRef)` call.
4. **`pushNewCapture(ref:)`**: add the master-switch re-check between the busy guard and the route push — `guard settingsReader.isWatchEnabled() else { WatchLog.note(.capture, "ask.disabled"); return }` — with a comment: the switch is read when the launchpad is drawn, and the chooser can be answered after the phone has turned the wrist off; refusing here starts nothing and writes no hint. Update its comment ("THE CHOKE POINT for both in-app Ask paths (single-gateway tap and the chooser)") to "the choke point for every gateway row".
5. **`beginWorkCapture()`**: same `isWatchEnabled()` re-check after the busy guard; body otherwise unchanged (push, then `startWorkCapture(requestID: nonce)`, return value ignored — keep the existing comment that the pushed view renders a refusal). Rewrite the "A SEPARATE BUTTON, NEVER A MODE ON ASK" comment: reached only from the destination chooser's Add to Work row; **a per-press pick, never a mode** — there is no last-destination preference, and `startWorkCapture` stamps `.work` and clears the Ask hint and every conversation pin, so nothing from an earlier gateway press can ride along. Do **not** add a `.refusedBusy` guard around the push: a capacity refusal is a sentence the pushed screen shows.
6. **Launchpad:** delete the "Save to Work" `Button` block and its "The desk's own button, deliberately NOT a mode on Ask" comment. Ask, Conversations and the turned-off line remain; nothing else moves. Change the busy caption:
   ```swift
   if recordingService.isCapturing {
       Text("Recording…")  // xcstrings
   } else if recordingService.captureDestination == .work {
       Text(String(localized: LocalizedStringResource("watch.work.capture.saving", defaultValue: "Saving to Work…")))
   } else {
       Text("Still answering your last question.")  // xcstrings
   }
   ```
7. **Chooser** (same attachment point, same "Deliberately NOT on the Ask button" comment):
   ```swift
   .confirmationDialog(
       String(localized: LocalizedStringResource("watch.ask.destination.title", defaultValue: "Where to?")),
       isPresented: $showDestinationChooser,
       titleVisibility: .visible
   ) {
       ForEach(WatchAskDestinationRows.rows(configured: askGatewayRefs), id: \.self) { row in
           switch row {
           case .gateway(let ref):
               Button(displayName(forRef: ref)) { pushNewCapture(ref: ref) }
           case .work:
               Button(String(localized: LocalizedStringResource("watch.ask.destination.work", defaultValue: "Add to Work"))) {
                   beginWorkCapture()
               }
           }
       }
   } message: {
       if WatchAskDestinationRows.showsNoAILine(configured: askGatewayRefs) {
           Text(String(localized: LocalizedStringResource("watch.ask.destination.noAI", defaultValue: "No personal AI available.")))
       }
   }
   .onChange(of: settingsReader.isWatchEnabled()) { _, enabled in
       if !enabled { showDestinationChooser = false }
   }
   ```
   The dialog's Cancel is the system's. **Dismissal sites:** in `drainCoordinatorIfNeeded`, set `showDestinationChooser = false` in the `.directStart` and `.pushAndStart` arms before they start, and in all **three** arms that write a root `recordingService.state = .error(...)` — the `.disabledError` arm inside the `.refused` resolution branch, the `.disabledError` arm in the target branch, and the `.directStart`/`.pushAndStart` gateway-refused arm inside the `.refused` branch (a root error must not sit under a live sheet); in `drainDeepLinkIfNeeded`, set it after the `isCapturing` guard passes and before `path` is replaced. The `.refuse` arms (a live turn owns the machine) leave the sheet alone — a row picked afterwards is refused at its push site, as today.
8. **`WatchAskDestinationRows`** (new, same file, below `WatchRoute`):
   ```swift
   /// The rows the Ask chooser offers, as a pure value so the truth table is
   /// testable without a watch face: every configured gateway in roster order,
   /// then Add to Work — always present, always last.
   nonisolated enum WatchAskDestinationRows {
       enum Row: Hashable { case gateway(String); case work }
       static func rows(configured: [String]) -> [Row] { configured.map(Row.gateway) + [.work] }
       /// An empty roster is explained in one line rather than hidden behind a
       /// thread that cannot send. "Available", not "set up": an empty roster is
       /// also what a locked keychain or an un-hydrated wrist reads (I3).
       static func showsNoAILine(configured: [String]) -> Bool { configured.isEmpty }
   }
   ```
9. **`WatchRoute.workCapture` doc comment:** "a second 'Save to Work' always remounts" → "a second Add to Work pick always remounts".

### `Conduck/ConduckWatch Watch App/Views/WatchConversationThreadView.swift`

10. **`threadBackendName`**: keep the persisted-conversation lookup first, unchanged. Add ONE fallback: when `conversationID == nil` and `autoCaptureTarget` is `.new(backendRef)`, take the ref from `backendRef` instead of the roster row, then apply the **existing** missing-custom guard and the same `RemoteAgentRefMetadata.shortDisplayName(for:customs:)` call. Never substitute the default ref for a `.existing` target; never invent a name for a custom missing from both rosters. This also makes the draft's navigation title correct from the first frame.
11. **`WatchThreadCaptureOverlay`**: add `let destinationName: String`; in the non-AOD `VStack`, **before** the `if isLive` branch (so it shows during arming and recording alike), render `Text(destinationName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)` when non-empty. Pass `threadBackendName` from the call site. The `VStack` is centred and does not scroll, and the cancel-X is a separate 44 pt overlay: keep clearance from it and keep Stop fully reachable — verify arming, recording and the "1 min left" state at the largest text size on 41 mm (QA). The AOD branch is unchanged.

### `Conduck/ConduckWatch Watch App/Views/WatchWorkCaptureView.swift`

12. `screenTitle` reads the new key `watch.work.capture.navigationTitle` ("Add to Work"). Comments only otherwise: header "Pushed from the launchpad's 'Save to Work' button" → "Pushed from the Ask chooser's Add to Work row"; rule 1 "reached by its OWN button so there is no mode to leave switched on" → "reached by a per-press pick in the Ask chooser, so there is no mode to leave switched on"; `symbolName` comment "the same one the launchpad button carries" → "the desk's own glyph".

### `Conduck/ConduckWatch Watch App/Services/WatchSettingsReader.swift`

13. `configuredBackendRefs()` doc comment: "≥2 → present a picker; 1 → straight to record" → "the gateway rows of the Ask destination chooser, shown on every press".

### `Conduck/ConduckWatch Watch App/Localizable.xcstrings` — owner: the catalog owner named for this phase (listed, not edited by the designer)

| Action | Key | Default value |
|---|---|---|
| add | `watch.ask.destination.title` | `Where to?` |
| add | `watch.ask.destination.work` | `Add to Work` |
| add | `watch.ask.destination.noAI` | `No personal AI available.` |
| add | `watch.work.capture.navigationTitle` | `Add to Work` |
| retire | `watch.work.launchpad.save` | `Save to Work` (button removed) |
| retire | `watch.work.capture.title` | `Save to Work` (wording changed → new key) |
| retire | `Ask which gateway?` (bare-literal manual key) | `Ask which gateway?` |

Reused verbatim in a second role, no catalog change: `watch.work.capture.saving` ("Saving to Work…") on the launchpad caption — the same sentence for the same state on the same device. Untouched: every `watch.work.capture.*` terminal line, `watch.work.refusal.*`, the headless refusal sentences.

### Tests — `Conduck/ConduckWatchTests`

New watch test *files* need a `pbxproj` edit, so append to existing files.

In `ConduckWatchSmokeTests.swift`, a new top-level class `WatchAskDestinationRowsTests`:
- `testWorkIsAlwaysOfferedAndAlwaysLast` — for `[]`, `["hermes"]`, `["hermes","openclaw"]`, `["hermes","custom_<uuid>"]`: `rows(...).last == .work` and `.work` appears exactly once.
- `testGatewaysKeepRosterOrderAheadOfWork` — `rows(["b","a"]) == [.gateway("b"), .gateway("a"), .work]`.
- `testTheNoAILineShowsOnlyForAnEmptyRoster` — `showsNoAILine([]) == true`, `showsNoAILine(["hermes"]) == false`.

In `WatchCaptureGuardTests.swift` — **inside the existing class**, because `stageGateways(_:default:chosen:)` is private to it; use the service's public seams `recordPermissionRequest`, `recordSessionActivator` and `sessionCoordinator` (the `ActivationGate` / `makeService` helpers in `WatchArmActivationTests` are private and not reusable). Read `inFlightConversationID`, `captureMintCount`, `captureDestination`, `workCaptureID`, `workCaptureOutcome` and the injected in-memory store — `pendingConversationID` and `mintedConversationID` are `private` and cannot be asserted on. Cancel pending starts and release any suspended activator in `tearDown`; reset the shared settings between cases as the class already does.

- `testAnExplicitGatewayPickWritesItsHintWithNoChosenDefault` — stage `[hermes]` with `chosen: false`, `recordPermissionRequest = { false }` (so nothing arms); `startCapture(boundTo: .new(backendRef: "hermes"), requestID:)` → `consumePendingInAppNewConversationBackend() == "hermes"` and `captureDestination == .chat`. Pins that an explicit pick is written regardless of the headless default gate.
- `testAHintDrivenMintBypassesTheDefaultGate` — the `WatchDraftMintTests` shape: seed the hint with a captured ref, `chosen: false`, run the mint through the existing resolver seam → exactly one conversation in the store, bound to that ref; no claim about network dispatch (a configured ref would reach `WatchAudioUploader.shared.uploadConverse`, which no seam intercepts — use an unavailable captured ref as `WatchDraftMintTests` does, or remove the ref after the pick).
- `testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing` — precondition **`state == .idle`** (entering Work from `.error` runs `dismissError()`, which clears the hint by itself and would make the check vacuous); then seed a stale hint (`setPendingInAppNewConversationBackend("custom_<uuid>")`) **immediately before** the Work start (a cancel already clears it, so seeding earlier proves nothing), `recordPermissionRequest = { false }`; `startWorkCapture(requestID: r)` → `consumePendingInAppNewConversationBackend() == nil`, `captureDestination == .work`, `inFlightConversationID == nil`, `captureMintCount` unchanged, store conversation count unchanged.
- `testAGatewayPickAfterADeniedWorkCaptureIsChat` — `recordPermissionRequest = { false }`; `startWorkCapture`, then **await and assert** `state == .error` **and** `captureDestination == .work` (the denial is async; not a cancel, which would reset the lane by itself); only then `startCapture(boundTo: .new("hermes"), requestID:)` with a fresh request id → `captureDestination == .chat`.
- `testAFullQueueRefusesTheWorkPickBeforeArmingAndKeepsEveryQueuedRecording` — there is no ready-made full-queue fixture: populate `AppleRelayPendingQueue.shared` to capacity through its `enqueue(...)` with unique test request IDs, temporary audio files and `destination: .work`; count permission and activator calls with the two seams; `startWorkCapture(requestID: r)` → returns `.refusedBusy`, zero permission/activator calls, `state == .idle`, `workCaptureID == r`, `workCaptureOutcome == .refused(reason: WatchWorkCaptureRefusal.queueFull.message)`, `captureDestination == .chat` (the stamp is written only on an accepted start), and **every seeded request ID is still present with its bytes intact** (an unchanged `entryCount` alone proves nothing). Clean up only the test-owned entries through `claimEntry(requestID:)`; `StorageTestSupport` isolates defaults and secrets, not the queue's audio directory.

No existing test names the launchpad button, the `≥ 2` threshold or the old title, so none is expected to break; `ErrorSurfaceDriftGuardTests`' `canRetry` gate on `WatchNoteView.swift` and the relay ownership guards are untouched by every edit above.

### Docs

- `docs/ai-context/project-structure.md` line 80: "the Save-to-Work capture screen that is its own route rather than a mode on Ask" → "the Add-to-Work capture screen, reached from Ask's destination chooser and its own route rather than a mode on it". Present tense.
- `docs/ai-context/spec.md`: **no edit** — neither the Work section nor "The Watch is not a remote control" names the button or the wording; both stay true. (3 words of headroom; a zero-word change is the right one.)
- `docs/qa/work-usability/handoff.md`: decision 1 → "Watch: Add to Work is the last row of the Ask chooser, shown on every press; no separate button"; the **Watch** paragraph's first sentence; U-18 closed; U-17 reworded ("Save to Work" → "the Work row"); QA steps 52, 53, 55, 56, 59, 65 rewritten around Ask → Where to? → Add to Work; step 54 rewritten from "Ask behaves exactly as before" to Ask → pick the gateway row → a normal chat turn, and the desk gains nothing; plus new steps: chooser open → Cancel, with 0, 1 and N gateways → no capture, no route push, no hint written (a following Action-Button press lands on the default gateway as before); single gateway → Ask still opens the chooser; zero gateways → the chooser shows "No personal AI available." and only Add to Work, and that capture lands on the desk; the picked gateway's name is visible on the recording overlay; back out of a saving Work capture → the launchpad reads "Saving to Work…"; the maximum supported roster with long similar names at the largest text size and under VoiceOver → every label readable, every row selectable; chooser open → turn the wrist off on the phone → pick a row → nothing starts; chooser open → Action Button → the sheet is gone and the headless capture runs; chooser open → Action Button with the default gateway unavailable → the sheet is gone, the root shows the refusal, Dismiss clears it; chooser open → a notification tap → the sheet is gone and the thread opens to read; chooser open → the machine goes busy → a row pick is refused and the live capture is untouched; the destination caption never crowds Stop or the cancel-X at the largest text size.
- `docs/qa/work-usability/fixnotes/c3-watch-ui.md` "Nobody undo", first bullet: prefix "*Superseded by `design/watch-work-destination.md`: the door is a per-press row in the Ask chooser; the rule that survives is no sticky destination.*" so it cannot prompt a reversal.
- `README.md` line 55 (public repo): "from your wrist with *Save to Work*, which your iPhone saves for you" → "from your wrist, where Ask offers *Add to Work* and your iPhone saves it for you".

## Open risks

- **One extra tap per Ask on a single-gateway watch.** The founder's own wording. If it grates in QA, the reversal is a `count >= 1` bypass — but that drops Work off the single-gateway path, which is the case the founder explicitly named.
- **Long rosters.** Three gateways make five rows with Work and Cancel; the sheet scrolls. QA acceptance is the maximum supported roster with long, similar names, at the largest text size and under VoiceOver, on a 41 mm face — every label readable, every row selectable without accidental activation; a list sheet only if that fails.
- **`confirmationDialog` `message:` rendering on watchOS** is a QA check, not a claim: the line must sit under the title without pushing Add to Work below the bezel at large text.
- **Discoverability:** Work is no longer on the launchpad; it is one tap deeper, on every press. The founder's trade.
- **A custom gateway named "Add to Work"** would collide with the row. Nobody names a server that; no guard.

## Codex rounds

### Round 1 (`verify/codex-design-watch-r1.md`) — 11 findings

| # | Finding | Outcome |
|---|---|---|
| 1 | MAJOR: the picked gateway is invisible while recording (draft title empty, toolbar hidden, overlay names nothing), so "a wrong pick is visible before the mic opens" was false. | **Accepted** → decision 7, changes 10–11. |
| 2 | MAJOR: master switch checked only at draw; a row picked after the phone turned the wrist off still starts. | **Accepted** → decision 8, changes 4, 5, 7. |
| 3 | MAJOR: N gateways → more than four buttons; use a list sheet or make max-roster QA an acceptance condition; drop unverified rendering claims. | **Partly accepted.** The `confirmationDialog` stays (reuse the existing chooser; the common roster is one or two gateways); the unverified claims are removed; the largest-roster 41 mm check is a QA acceptance step. |
| 4 | MINOR: Work-last has weak rationale; put Work first for a stable position. | **Held.** Ask is the AI button and the top row is the fastest; for the common single-gateway case the two orders differ only in which of two rows leads, and leading with the private desk misreads "Ask". Rationale rewritten honestly (a stable relationship, not a fixed position). |
| 5 | MINOR: "Set up your personal AI on iPhone first." reads as a prerequisite above the only working row, and its meaning is pinned for the headless lane. | **Accepted** → decision 6, new key `watch.ask.destination.noAI`. |
| 6 | MINOR: "nothing is persisted" was inaccurate (an accepted gateway capture writes the Ask hint). | **Accepted** → wording fixed in the intro and decision 11; the hint is preserved, never cleared on a mere dismissal; headless proceed arms dismiss the chooser. |
| 7 | MAJOR: the proposed tests miss the behaviour that motivates the change; text guards are brittle. | **Accepted** → the two source guards are dropped; service-level tests added for the explicit-pick mint with no chosen default, the two lane transitions, and the capacity hand-off. "No existing test breaks" softened to what was checked. |
| 8 | MINOR: spell out the capacity-refusal contract (push regardless of `.refusedBusy`; stamp written only on an accepted start). | **Accepted** → change 5, decision 11, the capacity test. |
| 9 | MINOR: the launchpad busy caption can call a Work save "answering your last question". | **Accepted** → decision 12, change 6. |
| 10 | MINOR: prefer "Add to Work" for the row and the screen title. | **Accepted** → decision 4; two keys retired, two added. |
| 11 | NIT: stale comments (`configuredBackendRefs`, `pushNewCapture`, root header), c3 fixnote instruction should read as superseded; new watch app files may not need a pbxproj edit. | **Accepted** for the comments and the fixnote line; the helper stays beside its view for cohesion either way. |

Also accepted from "What I agree with": the boundary is stated as *no implicit or hands-free reroute to Work*, since the Siri text intent is a hands-free door that names Work explicitly (decision 9).

### Round 2 (`verify/codex-design-watch-r2.md`) — 9 findings

| # | Finding | Outcome |
|---|---|---|
| 1 | NIT: Work-last is defensible; fix two claims (built-ins are in enum order, not "first-added"; Cancel is placed by the system). | **Accepted** → decision 3 reworded; "always one tap" removed from the `beginInAppAsk` comment. |
| 2 | MINOR: keeping `confirmationDialog` is reasonable; the acceptance criterion must be the maximum roster, long similar names, largest text, VoiceOver. | **Accepted** → decision 2. |
| 3 | MINOR: the destination cue covers less than claimed (`.existing` depends on the loaded roster; missing customs stay unnamed; AOD names nothing). | **Accepted** → decision 7 narrowed; change 10 keeps the persisted lookup first and the missing-custom guard. |
| 4 | MINOR: the overlay caption needs its own small-face check; place it before `if isLive`. | **Accepted** → change 11, QA step. |
| 5 | MINOR: dismissal also needed for the deep-link path and the headless refusal arms that write a root error. | **Accepted** → decision 10, change 7. |
| 6 | MAJOR: the explicit-pick test would reach real transport; split it. | **Accepted** → two tests, no network claim. |
| 7 | MAJOR: `pendingConversationID` / `mintedConversationID` are private; a cancel already clears the hint and the lane, so the transition tests were vacuous as written. | **Accepted** → assertions on public seams; stale hint seeded immediately before the Work start; the reverse transition uses a denied permission, not a cancel. |
| 8 | MINOR: no ready-made full-queue fixture; unchanged `entryCount` proves nothing. | **Accepted** → the capacity test populates the queue itself and asserts every seeded entry survives. |
| 9 | MINOR: the view-level guards (switch re-check, dismissals) are not unit-testable; add explicit QA cases. | **Accepted** → the QA steps in the handoff edit. |

Agreed without change: the copy set ("Where to?", "Add to Work" for row and screen, "No personal AI available." as honest under I3, "Saving to Work…" reused); `watchEnabledCache` is `@Observable`-tracked so the `onChange` fires (tests that flip it must go through `updateFromContext` / `refreshWatchEnabledCache`, not raw defaults); busy → switch → synchronous push/start with no `await` between them.

### Round 3 (`verify/codex-design-watch-r3.md`) — closing, 4 corrections, then ready

| # | Finding | Outcome |
|---|---|---|
| 1 | MINOR: change 7 said two root-error arms; the code has three. | **Accepted** → all three named; QA case for chooser → unavailable headless gateway → Dismiss. |
| 2 | MINOR: the stale-hint test is vacuous unless it starts from `.idle` (entering Work from `.error` runs `dismissError()`); the reverse test must await `.error` + `.work` first. | **Accepted** → preconditions written into both tests. |
| 3 | MINOR: QA step 54 ("Ask behaves exactly as before") and chooser-cancel checks were missing. | **Accepted** → step 54 rewritten; Cancel checks for 0/1/N added. |
| 4 | NIT: the open-risks line still said "the founder's largest roster". | **Accepted** → the maximum-supported-roster criterion repeated. |

Codex's closing verdict: ready to implement after these corrections, no further product decision needed; every earlier finding closed; no standing-rule violation (no new `WatchRecordingState` case, no `WatchCaptureTarget` case for Work, no relay wire literal, no Work converse hop, `spec.md` untouched, catalog keys listed only).

A note for the record: a first attempt at round 3 through `exec resume --last` resumed another lane's Codex session (the Mac design running in the same worktree) and answered about that document; it was discarded and round 3 was re-run as a fresh `exec`. Round 2 was a genuine resume of round 1's session but read draft 2 from disk rather than stdin, which is why its opening line says no stdin was attached.
