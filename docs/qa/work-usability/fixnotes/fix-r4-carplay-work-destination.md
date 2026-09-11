# fix-r4-carplay-work-destination — Codex round 4 on the CarPlay Work destination

Source: `docs/qa/work-usability/verify/codex-r4-carplay-work-destination.md` (1 P1, 8 P2,
2 P3). Rounds 1–3: `fixnotes/fix-r1/r2/r3-carplay-work-destination.md`. Design:
`docs/qa/work-usability/design/carplay-work-destination.md`.

| ID | Verdict |
|---|---|
| CP-R4-06 (P2, NEW) | **FIXED** — End during microphone startup now drives the `.idle` transition itself |
| CP-R4-10 (P2) | **FIXED for every mutation Codex names inside this lane's files** — 17 named survivors closed; the out-of-lane rows are forwarded below |
| CP-R4-01 (P1) | **FORWARDED** (intents) — no CarPlay half; see below |
| CP-R4-02 (P2) | **FORWARDED** — iOS microphone/session ownership lives in `InAppAudioRecorder`/`AudioRecorder` |
| CP-R4-03 (P2) | **FORWARDED, CarPlay side already as tight as it can be** — the unserialised commit is in `WorkVoiceCaptureCoordinator` |
| CP-R4-04, 05, 07, 08, 09 (P2) | **FORWARDED** — retry store / coordinator / relay / `ContentView` / recorder |
| CP-R4-11 (P3) | **FORWARDED** — `Localizable.xcstrings`, not this lane's catalog |
| CP-R4-12 (P3) | **FORWARDED** — `handoff.md`, the docs pass |

Files touched: `Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift`,
`Conduck/Conduck/CarPlay/CarPlayConverseUploader.swift`,
`Conduck/ConduckTests/CarPlayWorkNoteTests.swift`,
`Conduck/ConduckTests/CarPlayVoiceTimingContractTests.swift`,
`Conduck/ConduckTests/CarPlayAttemptCancellationOutcomeTests.swift`. **No catalog rows** —
nothing here adds a sentence anyone reads or hears.

---

## CP-R4-06 — End during microphone startup stranded the modal and the car radio · **FIXED**

`beginWorkNote` / `beginSession` flip `sessionActive` and leave `state` alone; the listen does
not reach `.recording` until the commit far below the cold-route settle and the VAD model load.
"End" inside that window therefore ends a REAL session whose `state` never moved, so
`endSession`'s closing `state = .idle` is an **equal assignment** — and `@Observable` publishes
nothing for one. The observer never fires: nothing dismisses the Listening modal, the dismiss
completion that frees the car radio never runs, and the driver is left on a "Listening" screen
whose own "End" is already a no-op (`endSession` guards on `sessionActive`). The abandoned
startup supplies no signal either — it discards its engine and returns.

**Fix: the End handler asks whether `state` CAN carry the end, and drives the transition itself
when it cannot.**

- The question is asked at the call site, BEFORE `endFromButton()`: afterwards the answer is
  `.idle` for every session there has ever been.
- `finishIdleEndTheObserverCannotDeliver(service:)` runs `applyState(service.state, service:)`
  — the observer's OWN chokepoint, so this is the missed transition and not a second, divergent
  one — behind `service === recordingService` so a stale connection's End cannot clear the live
  one's screen.
- Same shape the lane already uses for the other end `state` cannot deliver: a capture-start
  failure fires `onCaptureStartFailed`, whose scene handler also runs `applyState` by hand. One
  mechanism, two triggers.

`templateDidDisappear` is deliberately **not** routed through this: the modal is already gone
there and that path frees the audio session directly (`deactivateAudioSession()`), so the only
thing it misses is a picker repaint — and repainting the root from a dismiss callback is the
CarPlay assertion source the `.idle` arm's comment names.

**Executable, new** — `EqualAssignmentProbe` is a two-case `@Observable` stand-in for `state`,
and `testEndDuringMicrophoneStartupStillClearsTheScreenAndFreesTheCar` measures the premise
rather than asserting it in a comment: an equal assignment publishes nothing, a real change
publishes once. If Observation ever changes, that case fails FIRST and says the hand-driven
transition is now a second dismiss.

**For the docs pass** (the handoff is not this lane's file): design §7 already rewrites step 77,
but nothing in the script reaches the startup window. Add **73a. End while the microphone is
still starting.** *Tap Add to Work and tap End within about a second — before the Listening
screen has reacted to your voice. Must be true: the Listening modal dismisses on its own, the
picker comes back, and the car's own audio (Maps, music) resumes. Failure: the Listening screen
stays up over a session that is already dead, its End button doing nothing, with the car still
silent.*

## CP-R4-10 — the strengthened guards still admitted their own mutations · **FIXED in this lane's files**

Codex named seventeen concrete survivors inside CarPlay files. Each is closed by the same three
moves the round-3 note established — pin the WHOLE short body, pin a statement by its
NEIGHBOURS, or EXECUTE the seam — plus one new one: **census a name when its danger is a place
nobody is looking.**

| Codex's survivor | Closed by |
|---|---|
| picker gate loses `self.pendingStart == nil` (scene :1012) | the whole four-condition guard, pinned as text |
| `\|\| true` on the leftover-dismiss condition (scene :678) | `dismissModalLeftOverBy` pinned as a WHOLE BODY |
| `setMuteButton(service:)` inside `ensureVoicePresented` | a CENSUS: four mentions in the scene, each named; `ensureVoicePresented` pinned to have none, and no trailing-button write of its own |
| New voice chat row routed to `startWorkNote` | both row handlers pinned WHOLE, each naming its own starter |
| `presentationGeneration &= 0` before a flag write | a CENSUS of four mentions, each named — a regex for plain assignment cannot see a compound operator |
| parking wrapped in `if !capture.guardToken.audioPreserved` (service :2034) | the parking pinned as the function's unconditional OPENING, not its first mention |
| `terminalizeAbandonedUserTurn` writing `"sending"` (service :2201) | its whole body pinned, so the stored value is asserted and not just the call |
| destination guard moved above the settle in `reArmAfterSettle` | its position pinned AFTER the sleep |
| Work hint's English catalog value changed (`Localizable.xcstrings:841`) | the three hint VALUES asserted, plus that the two details differ |
| `isLive` replaced by `(controllerAttached == sceneActive)` | all 64 Boolean states enumerated; exactly one may act |
| post-readiness guard wrapped in `if workCapture != nil` (service :1602) | `assertAskedUnconditionally`: the check is the FIRST `guard` after the suspension and nothing between them opens a block |
| `let attemptID = listenAttemptID &+ 1` (service :736) | the whole assignment pinned with its neighbours |
| an impossible `.recording` condition around the hand-on task | `handOnArmingSlotAfterAbandonedStartup` pinned WHOLE |
| cleanup deleted only from the stale arm (service :884) | `armBody`: each arm brace-matched and asserted ALONE, so the mute arm's identical lines no longer answer for it |
| `recordingService != nil` inverted (scene :150) | the whole `if` pinned, condition included |
| hint callback's two lines wrapped in `if !service.isSceneActive` (scene :183–184) | the whole callback pinned |
| uploader's final dispatch consumer (`CarPlayConverseUploader.swift:499`) | **EXTRACTED and EXECUTED** — see below |

### The dispatch consumer is now executable, not readable

Codex's objection was exact: the pre-dispatch recheck lived as an inline closure inside
`uploadConverse`, which this suite cannot drive (a background `URLSession`, a live gateway, a
ledger insert). A body that consumes the mark and then answers `false` reads identically to one
that refuses the dispatch — and dispatches the turn the driver just ended.

- `CarPlayConverseUploader.consumeDispatchCancelMark(turnToken:)` is that closure, lifted to a
  named method and INTERNAL rather than private, precisely so the guard can run it. The call
  site is `let cancelledBeforeDispatch = consumeDispatchCancelMark(turnToken: turnToken)`, and
  that line is itself pinned — inlining it again puts the decision back out of reach.
- `testTheProductionPreDispatchConsumerRefusesExactlyTheEndedTurnAndConsumesItOnce` drives the
  production singleton: another turn's mark is not consumed, the ended turn's is, it is
  consumed exactly once, and the `0` sentinel belongs to no turn.

### Twenty-three mutation runs, twenty-three red

| # | Mutation | Caught by |
|---|---|---|
| N1 | End handler drops the idle cleanup | `testEndDuringMicrophoneStartup…` |
| N2 | state asked AFTER the end | `testEndDuringMicrophoneStartup…` |
| N3 | helper drops the service-identity check | `testEndDuringMicrophoneStartup…` |
| N4 | .idle arm loses the dismiss | `testEndDuringMicrophoneStartup…` |
| M14 | picker gate loses the claim condition | `testEverySessionStartClaims…` |
| M15 | leftover-dismiss condition `\|\| true` | `testEverySessionStartClaims…` |
| M16 | setMuteButton inside ensureVoicePresented | `testAWorkNoteOffersEndAndNoMute` |
| M17 | trailing button written in the present | `testAWorkNoteOffersEndAndNoMute` |
| M18 | New voice chat row routes to Work | `testTheDriveLongOverride…` |
| M19 | presentationGeneration &= 0 before the flag write | `testAPresentCompletionActs…` |
| M24 | isLive conjunction becomes an equality | `testTheStartGateAdmitsOneClaim…` |
| M29 | didConnect stale check inverted | `testAReconnectTearsDownTheStaleService` |
| M30 | hint callback gated on a background scene | `testStartFailureHintIsOneShot` |
| M20 | parking wrapped in a preservation test | `testTheWordsAreParked…` |
| M21 | abandoned turn settled to sending | `testEverySuspensionInTheChatHop…` |
| M25 | post-readiness guard scoped to Work | `testTheStalenessChecksAroundTheSpeechPreflight…` |
| M26 | startup captures the NEXT lineage | `testASupersededListenStartup…` |
| M27 | hand-on gated on an impossible state | `testASupersededListenStartup…` |
| M28 | stale arm loses its cleanup | `testACommitNeverLandsOnADeadSession` |
| E6 | consumer consumes the mark and refuses nothing | `testTheProductionPreDispatchConsumer…` |
| E7 | consumer answers a constant | `testTheProductionPreDispatchConsumer…` |
| E8 | the pre-dispatch recheck is inlined again | `testTheProductionPreDispatchConsumer…` |
| M22 | destination guard MOVED above the settle | `testTheWorkLaneReachesNoGateway…` |

### Still out of reach, and stated plainly

The whole `startSession`/`startWorkNote`/`ensureVoicePresented` coordinator still cannot be
EXECUTED: `startIsLive` reads `interfaceController != nil`, so without a real
`CPInterfaceController` every start answers false and no wiring test can tell a correct
coordinator from a broken one. R1–R3 said so and it is still true; what changed this round is
that every mutation Codex could NAME in it is now caught by a whole-body or neighbour pin.

---

## Nobody undo (adds to `e-carplay.md`, `fix-r1/r2/r3-carplay*.md`)

- **An end that never left `.idle` reaches the scene BY HAND, never by assignment.**
  `@Observable` publishes nothing for an equal assignment (measured, in
  `testEndDuringMicrophoneStartup…`), and a session can be ended before its listen ever commits
  the microphone. The End handler asks `state == .idle` BEFORE the end and calls
  `finishIdleEndTheObserverCannotDeliver` after it. Do not "simplify" that to trusting the
  observer, and do not ask the question after the end — the answer is `.idle` either way.
- **That hand-driven end runs `applyState`, the observer's own chokepoint.** Not a bespoke
  dismiss-plus-refresh beside it. Two transitions for one event is how one of them rots.
- **`consumeDispatchCancelMark` is internal so a test can RUN it.** Re-inlining it into
  `uploadConverse` — or making it private — removes the only executable proof that an ended
  turn is refused its dispatch, because `uploadConverse` itself cannot be driven from this
  suite. Its call site is pinned for the same reason.
- **A short protection is pinned as a WHOLE BODY; a statement, by its NEIGHBOURS; a NAME, by a
  census.** The census is the new one and it is for the mutation that hides where nobody is
  looking: `presentationGeneration &= 0` and a fifth `setMuteButton(` call are both invisible to
  every assertion scoped to the function that is supposed to own them. If a change adds a
  legitimate mention, add it to the census by name — do not raise the count alone.
- **Two arms that run the same cleanup are asserted SEPARATELY.** `armBody` brace-matches one
  arm; a scan of the span containing both is satisfied by either, so deleting one is invisible.
- **A check "after a suspension" means the FIRST `guard` after it, with no block opened in
  between.** `assertAskedUnconditionally` is the rule; `if workCapture != nil { guard … }` is
  the mutation it exists for, and it is exactly the destination-scoped question the round-2 fix
  removed.
- **Catalog VALUES are pinned where the sentence names a control.** The two start-failure
  details exist only to name the row that failed; equal values, or the wrong value on the Work
  row, sends a private thought to an AI with every key-scoped guard still green.

---

## Measured

| Run | Result |
|---|---|
| `build-for-testing` (iOS sim, scheme Conduck) | 0 errors |
| The four CarPlay classes | **73 tests, 0 failures** (`CarPlayWorkNoteTests` 34, `CarPlayVoiceTimingContractTests` 22, `CarPlayAttemptCancellationOutcomeTests` 13, `CarPlayCancelClaimLifetimeTests` 4) |
| Mutation runs | 23 mutations, 23 red (table above) |
| Whole `ConduckTests` bundle | 4 failures, **none in this lane and none caused by it**: `STTKeyBlackoutLaneTests` fails because `AppleSpeechRelayCoordinator.swift` gained a third `deferred: true` arm while this round was running (the relay lane's CP-R4-07 fix, whose own count guard needs bumping); the other three — `SpeechChunkQueueSeamStallTests`, `WorkDeskWriteOwnershipDriftGuardTests`, `WorkboardCopyTruthGuardTests` — pass on a re-run and were reading another lane's file mid-edit. Re-run once the concurrent lanes land. |

## Forwarded, with the reason each is not mine

- **CP-R4-01** (P1, attended-entry boundary on Work) — `Conduck/Intents/*` and
  `WorkboardVoiceCaptureView`. Codex withdrew the CarPlay half in round 3 and did not re-file
  it: `CPListItem.handler` receives no provenance, and CarPlay publishes nothing that separates
  a physical row tap from an OS voice invocation of the same row. Every path this finding names
  is an intent or the desk sheet.
- **CP-R4-02** (P2, one iOS microphone/session owner) — `InAppAudioRecorder.swift:804` is `#if
  os(macOS)`; the gate has to be built there. CarPlay's side of it is one call:
  `beginSession`/`beginWorkNote` both funnel through `startListening`, so a lease taken at the
  top of that function covers the whole lane, and the release belongs with
  `deactivateAudioSession()`.
- **CP-R4-03** (P2, a superseded retry overwriting a transcript) — the CarPlay half is already
  as tight as this lane can make it: `attachWorkNoteTranscript` asks
  `PendingRetryGuard.stillOwnsCapture` and then reaches the coordinator with no suspension in
  between. The window Codex describes opens INSIDE
  `WorkVoiceCaptureCoordinator.attachTranscript` (store load, write queue), and only a
  claim-checked commit there can close it.
- **CP-R4-04** (P2) — `PendingRetryStore`. **CP-R4-05** (P2) —
  `WorkVoiceCaptureCoordinator`. **CP-R4-07** (P2) — `AppleSpeechRelayCoordinator`.
  **CP-R4-09** (P2) — `InAppAudioRecorder` + the Mac desk sheet.
- **CP-R4-08** (P2, a foreground phone never discovering a CarPlay retry) — `ContentView`.
  Re-confirmed by grep: `PendingRetryStore.queueDidChangeNotification` still has exactly one
  production subscriber, `MenuBar/DictationService.swift`. This stays the most user-visible of
  the forwarded set — it is what makes CarPlay's spoken *"Add the words on your iPhone"* point
  at nothing until a lifecycle refresh.
- **CP-R4-10's out-of-lane rows** — five of Codex's named survivors sit in files this lane does
  not own, and each needs the same treatment applied here: `DictationService.swift:774` (return
  `retired`, not `true` — `PendingRetryOwnershipHandoffTests:297`) and `:373` (release wrapped
  in `if state == .recording` — `PendingRetrySurfaceHandoffTests:437`), both the Mac lane;
  `WatchNoteView.swift:415` (`.visible` → `.spoken` — `ErrorSurfaceDriftGuardTests:692`), the
  watch lane; `InAppAudioRecorder.swift:555` (`releaseWorkPublication` zeroing the count —
  `WorkboardVoiceScreenshotLaneTests:189`) and the shared cancellation check moved before
  `ensureLoaded` (`WorkboardAudioCaptureTests:585/660`), the recorder.
- **CP-R4-11** (P3, quit copy) — `Conduck/Localizable.xcstrings`, owned by the Mac lane this
  round.
- **CP-R4-12** (P3, QA steps 77+, the entitlement key, the missing long-drive and
  competing-start steps) — `handoff.md`, the docs pass. The entitlement half remains checkable
  and correct: the project declares `com.apple.developer.carplay-voice-based-conversation`.
