# fix-r3-carplay-work-destination — Codex round 3 on the CarPlay Work destination

Source: `docs/qa/work-usability/verify/codex-r3-carplay-work-destination.md` (1 P1, 9 P2,
1 P3). Rounds 1–2: `fixnotes/fix-r1-carplay-work-destination.md`,
`fixnotes/fix-r2-carplay-work-destination.md`. Design:
`docs/qa/work-usability/design/carplay-work-destination.md`.

| ID | Verdict |
|---|---|
| CP-R3-02 (P2) | **FIXED** — outstanding-attempt retention in `CarPlayConverseUploader`, registered at the mint |
| CP-R3-10 (P2) | **FIXED for every mutation Codex names inside this lane's files** — 20 mutation runs, 20 red; the residue is named below |
| CP-R3-01 (P1) | **FORWARDED** (intents) — the CarPlay half Codex withdrew itself |
| CP-R3-03/04/05/07/08/09 (P2) | **FORWARDED** — recorder / relay / retry-store / Mac-quit ownership |
| CP-R3-06 (P2) | **FORWARDED** — `ContentView`; confirmed by grep, one consumer only |
| CP-R3-11 (P3) | **FORWARDED** — `handoff.md` belongs to the docs pass |

Files touched: `Conduck/Conduck/CarPlay/CarPlayConverseUploader.swift`,
`Conduck/Conduck/CarPlay/CarPlayRecordingService.swift`,
`Conduck/ConduckTests/CarPlayWorkNoteTests.swift`,
`Conduck/ConduckTests/CarPlayVoiceTimingContractTests.swift`,
`Conduck/ConduckTests/CarPlayAttemptCancellationOutcomeTests.swift`. **No catalog rows** —
every change is a guard, a registry or a test; none of them adds a sentence anyone reads or
hears.

---

## CP-R3-02 — a live cancel claim could be evicted by the retention ceiling · **FIXED**

R2 made the claim set bounded by AGE rather than by a newer turn's token, on the grounds that
age "cannot mistake a suspended turn for a finished one". It can. Age is *evidence about*
orphanhood, and the oldest mark is normally an orphan — but it is also exactly the mark of the
turn that has been suspended since before every other one started. On a long drive, once
`cancelClaimCeiling` (32) newer marks accumulate, `trimCancelClaims` evicts the lowest token:
chat A, parked in `beginGatewayAttempt`, resumes to find no claim in front of it and dispatches
the transcript the driver had ended the session on.

**Fix: retain the marks of attempts that are PROVEN still live, and let the ceiling pick its
victims from what is left.**

- `CarPlayConverseUploader.outstandingDispatchTokens` holds every token whose hop has not
  exited. `trimCancelClaims(_:outstanding:)` subtracts that set before sorting by age, so an
  outstanding mark is not a candidate at any count; `markCancelClaim(in:turnToken:outstanding:)`
  forwards it, with **no default** — a caller that forgets the argument is the defect the
  parameter exists to stop, so the compiler asks.
- Registered **at the mint**, not at the `uploadConverse` call:
  `CarPlayRecordingService.startConverseHop` pairs
  `beginPendingDispatch(turnToken:)` with a `defer`-ed `endPendingDispatch(turnToken:)` on the
  same scope, immediately after `mintTurnToken()`. Two suspensions (the file-lane revalidation,
  the outbox mint) and one executor hop sit between the mint and the uploader, and `endSession`
  can cancel the token the instant it exists — registering later leaves exactly the window this
  finding is about. The `defer` covers every exit of the hop: dispatched, refused, thrown.
- The ceiling is now a bound on ORPHANS, not on the set. A drive with more than 32
  simultaneously suspended dispatches keeps all of their marks and exceeds the ceiling — the
  correct trade, since the alternative is dropping a live claim, and it cannot run away because
  each token is released by the `defer` on the hop that minted it.

## CP-R3-10 — the strengthened guards still admitted their own mutations · **FIXED in this lane's files**

Codex's objection is right in kind: a guard that asserts a *call is present* is satisfied by
the call with `|| true` beside it, by the call inside `if false`, or by a correct pure rule
reached through a caller that lies about its arguments. The answer is not more searching. Where
the thing being protected is a short function, the CONTRACT IS THE WHOLE BODY, and that is what
is now pinned; where it is a statement, the statement is pinned with its neighbours; and where
a seam is genuinely executable, it is executed.

**Executable, new** — `CarPlayCancelClaimLifetimeTests` now drives the PRODUCTION singleton:
`testTheProductionCancelDepositsItsMarkAndKeepsItWhileTheDispatchIsOutstanding` calls the real
`cancel(turnToken:)`, `beginPendingDispatch` and `endPendingDispatch` and reads the result
through two `#if DEBUG` seams on the uploader (`hasPendingDispatchCancel(turnToken:)`,
`resetDispatchCancellationState()`). This closes the whole C:123/177/200/220/240 family in one
case: those five tests exercise the static helpers on a local set, so a `cancel` that stopped
calling `markCancelClaim` passed every one of them while real cancellation did nothing.

**Whole-body pins, one per lying-caller mutation:**

| Guard | Pins | Kills |
|---|---|---|
| `testTheGateIsAskedHonestly` (new) | `claimStart`, `startIsLive`, `releaseStart` bodies, verbatim | `claimHeld: false` · `… \|\| true` · `releaseStart` losing `refreshPicker()` |
| `testTheListenLineageAsksBothHalves` (new) | `isCurrentListen` body, verbatim | dropping the generation comparison (W:422, W:1268, W:1321) |
| `testACommitNeverLandsOnADeadSession` | the same body, in its own file | T:290 |
| `testTheDispatchTokenIsHeldOpenFromTheMintUntilTheHopExits` (new) | the register/`defer` pair at the mint, plus one call site each | an unregistered or unreleased token |

**Statement pins, by exact text or by neighbours:** the ownership guard in
`attachWorkNoteTranscript` (`guard await PendingRetryGuard.stillOwnsCapture(…) else {` whole) ·
`reArmAfterSettle`'s `guard sessionDestination == .chat else { return }` whole ·
`disconnectCleanup`'s `recordingService?.teardown()` between its two neighbours ·
`claimStart`'s hint consumption as the LAST statement before the return, plus one `= true`
writer in the file · the no-gateway picker's `insert`/`updateSections` statements alongside the
mention count · the configured picker's `detailText: detail` · `presentationGeneration` with
no plain assignment anywhere (regex) and exactly one bump · `installVoiceTemplateButtons(`
absent from `startWorkNote` · exactly three `CarPlayCaptureDestination` mentions in the scene,
with both declarations named, and row 0 claiming the literal `.chat`.

### Twenty mutation runs, twenty red

| # | Mutation | Caught by |
|---|---|---|
| M1 | `startIsLive` returns `… \|\| true` | `testTheGateIsAskedHonestly` |
| M2 | `releaseStart` drops `refreshPicker()`, keeps its condition | `testTheGateIsAskedHonestly` |
| M3 | `claimStart` passes `claimHeld: false` | `testTheGateIsAskedHonestly` |
| M4 | `isCurrentListen` → `sessionActive` | `testTheListenLineageAsksBothHalves` |
| M4b | same mutation | `testACommitNeverLandsOnADeadSession` |
| M5 | `stillOwnsCapture(…) \|\| true` | `testTheWordsAreParked…` |
| M6 | re-arm restriction → `if sessionDestination == .chat { }` | `testTheWorkLaneReachesNoGateway…` |
| M7 | `firstSectionItems.reversed()` at the paint | `testTheMicCouldNotStartHint…` |
| M8 | literal chat retry sentence in place of `detail` | `testTheMicCouldNotStartHint…` |
| M9 | `installVoiceTemplateButtons(service:)` after the clear | `testAWorkNoteOffersEndAndNoMute` |
| M10 | a separate sticky `workMode` flag | `testTheDriveLongOverride…` |
| M11 | `presentationGeneration = 0` before each flag write | `testAPresentCompletionActsOnlyForItsOwnPresentation` |
| M12 | `if false { recordingService?.teardown() }` | `testAReconnectTearsDownTheStaleService` |
| M13 | hint re-raised right after `claimStart` consumed it | `testStartFailureHintIsOneShot` |
| E1 | production `cancel` deposits no mark | `testTheProductionCancelDeposits…` |
| E2 | production `cancel` passes `outstanding: []` | `testTheProductionCancelDeposits…` |
| E3 | `trimCancelClaims` ignores `outstanding` | `testAnOutstandingAttemptsClaimSurvives…` |
| E4 | `beginPendingDispatch` is a no-op | `testTheProductionCancelDeposits…` |
| E5 | the mint pair loses its `defer` | `testTheDispatchTokenIsHeldOpen…` |
| — | (three R2 controls re-run unchanged) | `CarPlayCancelClaimLifetimeTests` |

### Still out of reach, and stated plainly

Codex's prescribed fix — "exercise the production start/presentation coordinator with
controllable preflight and presentation completions" — needs a protocol in place of
`CPInterfaceController` and an injectable `CarPlayRecordingService` across an 81 KB scene
delegate whose starters are private. `startIsLive` reads `interfaceController != nil`, so
without a real controller every start answers false and no wiring test can distinguish a
correct coordinator from a broken one. That is a design change, not a fix, and R1 and R2 both
said so. What changed this round is that the mutations Codex could name are now caught: the
gap left is a mutation nobody has named, not the ones in the report.

---

## Nobody undo (adds to `e-carplay.md`, `fix-r1/r2-carplay.md`, `fix-r1/r2-carplay-work-destination.md`)

- **A cancel claim is dropped only when its attempt is PROVEN gone.** Age bounds the ORPHANS;
  it is not evidence of orphanhood on its own, and the oldest mark is precisely the mark of the
  turn that has been suspended longest. `trimCancelClaims` subtracts `outstanding` before it
  sorts. Do not restore a plain oldest-first eviction, and do not give
  `markCancelClaim`/`trimCancelClaims` a default for `outstanding` — the compiler asking each
  caller is the guard.
- **`beginPendingDispatch` is called at the MINT and released by a `defer` on the same scope.**
  Not at the `uploadConverse` call: two suspensions and an executor hop sit between them, and
  `endSession` can cancel the token the instant it exists. One register, one release, one hop.
- **The set may exceed `cancelClaimCeiling` while many dispatches are suspended together.**
  That is the design, not a leak: every outstanding token is released by the hop that minted
  it. Do not "fix" it by evicting a live claim.
- **A short protection is pinned as a WHOLE BODY, not by a `contains`.** `claimStart`,
  `startIsLive`, `releaseStart` and `isCurrentListen` are each their own contract; a search for
  any part of one admits `|| true`, `claimHeld: false`, a dropped `refreshPicker()` and a
  dropped generation comparison with the searched text still in place. If a change to one of
  them is deliberate, restate the body in the guard — do not weaken the guard to a `contains`.
- **A statement that must be unconditional is pinned by its NEIGHBOURS.** `if false { … }`
  keeps every token a presence assertion looks for. `recordingService?.teardown()` sits between
  `CarPlaySpeechService.shared.cancel()` and `self.interfaceController = nil`, and that is the
  assertion.
- **`presentationGeneration` has exactly one writer — the `didSet` increment.** A reset to `0`
  leaves the declaration, the bump and every ordering assertion intact while two presentations
  share generation 1, which is the race the generation exists to close.
- **A mention COUNT is never the whole guard.** Three mentions of `firstSectionItems` are
  satisfied by `.reversed()` at the paint; the count stays, but each of the three statements is
  now named as well.
- **The uploader's two `#if DEBUG` seams are the only executable proof that production
  cancellation happens at all.** They are read-only plus a reset for test hygiene; do not
  delete them to "keep the production surface clean" without replacing the executable case.

---

## Measured

| Run | Result |
|---|---|
| `build-for-testing` (iOS sim, scheme Conduck) | 0 errors |
| The four CarPlay classes | **71 tests, 0 failures** (`CarPlayWorkNoteTests` 33, `CarPlayCancelClaimLifetimeTests` 12, `CarPlayVoiceTimingContractTests` 22, `CarPlayAttemptCancellationOutcomeTests` 4) |
| Whole `ConduckTests` bundle | **5,469 tests, 1 skipped, 0 failures** |
| Mutation runs | 20 mutations, 20 red (table above) |

## Forwarded, with the reason each is not mine

- **CP-R3-01** (P1, an attended-gesture boundary on Work) — `Conduck/Intents/*` and
  `WorkboardVoiceCaptureView`, the shortcuts lane's files. Codex withdrew the CarPlay half
  itself ("I am not treating the absence of a physical-tap discriminator in CarPlay's handler
  as independent proof"), and R2's API point stands: `CPListItem.handler` receives no
  provenance and CarPlay publishes nothing that separates a physical row tap from an OS voice
  invocation of the same row.
- **CP-R3-03** (iOS microphone/session arbitration) — `InAppAudioRecorder` + `AudioRecorder`.
  Confirmed as stated: the arbitration block at `InAppAudioRecorder.swift:772` is `#if
  os(macOS)`. CarPlay's side of a shared gate is small — `beginSession`/`beginWorkNote` both
  funnel through `startListening`, so a lease taken there is one call.
- **CP-R3-04** (a missing STT key retiring the Watch recovery path) — the relay.
- **CP-R3-05, CP-R3-09** (reservation confirmation before attachment; cancellation on the
  parked-transcript path) — the recorder.
- **CP-R3-06** (a foreground phone never discovering a CarPlay-created retry) — `ContentView`.
  Confirmed by grep: `PendingRetryStore.queueDidChangeNotification` has exactly ONE consumer in
  the app, `MenuBar/DictationService.swift:151`. This is the one that makes CarPlay's spoken
  *"Add the words on your iPhone"* point at nothing until a lifecycle refresh, so it stays the
  most user-visible of the forwarded set.
- **CP-R3-07** (a partial save that preserves audio but not the screenshot) — `PendingRetryStore`.
- **CP-R3-08** (the Mac quit deadline and an undurable stopped capture) — `AppDelegate` /
  recorder, the Mac lane.
- **CP-R3-11** (P3: QA steps 77+, the entitlement key, the long-drive and competing-start
  steps) — `handoff.md`, the docs pass. The entitlement half remains checkable and correct:
  the project declares `com.apple.developer.carplay-voice-based-conversation`.
