# f-arm — the three ARMING lanes now hold a real reservation, and every operation they perform against their entry is token-checked. r6a#1 CONFIRMED and fixed; e-surfaces §Refuted 1 and §Refuted 2 REVERSED (the L1 primitive they lacked now exists). Nothing refuted.

Slug `f-arm`. Sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`. No commits, pushes, stash, checkout, reset or
index operations. `Identity-Override.xcconfig` untouched (the counterfactual copy got a dereferenced
COPY of it under my slug dir; the symlink in the worktree was never opened). Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet
touched. No file outside my ownership edited.

Files changed — six, of which one is new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/PendingRetryGuard.swift` | `Token.claim` (the real reservation, taken at `arm` by id, 90 s); `arm` reserves after the write; `disarm` = `clear(claim)`; NEW `renew`, `stillOwnsCapture`, `recordPublicationState(_:transcript:publicationState:)`; `leaseDuration` / `leaseRenewalInterval`; `#if CONDUCK_TESTING storeForTesting` |
| `Conduck/Conduck/Intents/ConverseIntent.swift` | `heldCapture(_:audio:reservation:)` carries the store-issued token; `recordRecoveryState(_:on:transcript:)`; the 45 s `leaseRenewal` task with a function-scope `defer`; TWO `stillOwnsCapture` gates, one per destination, each immediately before its hand-off |
| `Conduck/Conduck/Services/InAppAudioRecorder.swift` | NEW `PendingRetryLaneReserving` + `PendingRetryClaim.reservationOnly`; `heldRetryClaim`, `reserveDurableRetry`, `handBackUnfinishedRetry`, `startRenewingRetryLease`/`stopRenewingRetryLease` (120 s); `retryWorkCapture` reserves before it transcribes and hands back on every non-finishing outcome; `releaseDurableRetry` clears through the reservation; `armDurableRetry` records the id only when the save LANDED; `retryRefusedBusy` |
| `Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift` | the busy sentence in the error state + the a11y status it changes |
| `Conduck/ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift` | 12 → **13** cases; the existing disarm-count and ordering assertions are **unchanged** and pass unchanged |
| `Conduck/ConduckTests/WorkVoiceRecoveryTests.swift` | 27 → **30** cases; `RecordingRetryLane` grows the reservation half (`claim(id:duration:)`, `renew`, `confirmOwnership`, `release`, `clear(_:)`, `reserveForAnotherSurface`, `isReserved`, `reservations`/`releases`/`renewals`) |
| `Conduck/ConduckTests/ArmSideReservationTests.swift` | **NEW**, 11 cases — the disarm through the reservation, ownership by token, the renewal, and the arming lanes' own census |

`VoicePermissionsTests`, `WorkboardVoiceLaneTests` and `WorkboardAudioCaptureTests` are mine and are
**unchanged** — 6/0, 11/0 and 19/0 throughout. Listing them as mine gave me the right to change them,
not a reason to.

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · targeted 10-class set
`Executed 157 tests, with 0 failures (0 unexpected)` · signed macOS `** BUILD SUCCEEDED **` ·
**counterfactual: 12 cases go red on a tree with only the mechanisms r6a#1 names reverted, each on the
one it names** (§Counterfactual). **One RED test left in the tree on purpose: the census allowlist in
`PendingRetrySurfaceHandoffTests`, which L5 assigns to the integrator — §Requests 1.**

---

## The finding

### r6a#1 (major, O-1) — two surfaces could finish one capture, because the three arming lanes addressed their entry by id and nothing checked whether it was still theirs. CONFIRMED in every clause, fixed.

**Verified first, by call path, at the anchors given** (`1e9a004`, re-located by symbol):

| Clause | What the code did |
|---|---|
| the headless intent arms at `:319` and transcribes at `:519` without a store-issued claim | yes — `PendingRetryGuard.arm` returned a `Token` of `{retryID, notificationID, audioPreserved}` and took no reservation at all |
| `heldCapture` fabricates a token (`:779-788`) | yes — `token: UUID()`, with a doc comment saying so and calling it deliberate |
| `PendingRetryGuard.disarm` uses lease-blind `clear(ifCurrentID:)` (`:121`) | yes — `cancelDeferredNotification` then `clear(ifCurrentID: token.retryID)`, which deletes the entry and its recording for whoever holds them |
| the Work sheet calls `retryWorkCapture` (`WorkboardVoiceCaptureView.swift:208-209`) whose recorder clears by id (`InAppAudioRecorder.swift:933-936`) | yes — `releaseDurableRetry` was `guard armedDurableRetryID == id` + `clear(ifCurrentID: id)`, correct about WHICH capture and blind to whether it was still the recorder's |
| meanwhile `claimNext` can reserve either row | yes — both retry surfaces select through it (e-surfaces), and nothing in the arming lanes consulted or took a lease |

So the collision was real in both directions: an intent completing deleted the recording a retry card was
mid-transcription on, and a retry card selecting a capture the intent was still finishing produced — for
Chat — two user turns and two gateway effects for one thing said once.

**Fix = L1/L3/L4, every clause.**

- **`PendingRetryGuard.arm` retains the REAL claim.** It calls `store.claim(id: metadata.id, duration:
  leaseDuration)` immediately after the write, against the id this caller minted — never `claimNext`.
  `leaseDuration = deferredNotificationDelay = 90 s` (L4, the short half: an intent may be killed at any
  instant, and a hold that outlived its own "tap to retry" notice would refuse the person their own
  recording behind a card whose button does nothing).
- **`disarm` is `clear(claim)`**, and cancels the notification only after the clear returns true. A
  refused clear leaves the entry, the recording AND the notice — the surface that owns the capture is the
  one that will cancel it.
- **`InAppAudioRecorder` reserves before it transcribes and clears through the reservation.**
  `retryWorkCapture` → `reserveDurableRetry(for:)` → refuse = `retryRefusedBusy`, the standing error kept,
  nothing deleted, no provider round trip. `releaseDurableRetry` clears through the held claim (or takes
  one by id when the finish came from a path that never reserved), so it can no longer delete a capture
  another surface took over.
- **The Work sheet's retry renews per L2** — 120 s ticks against the 600 s horizon — and
  **`ConverseIntent` renews at 45 s** against its 90 s horizon. Both stop on every exit: the intent's by a
  function-scope `defer { leaseRenewal.cancel() }`, the recorder's by `stopRenewingRetryLease()` in both
  `handBackUnfinishedRetry` and `releaseDurableRetry`.
- **`ConverseIntent`'s held capture carries the real token** (`reservation.claim?.token ?? metadata.id`
  — the capture's own id stands in when arming preserved nothing, so the value names no reservation *by
  construction* rather than by a random draw), and **confirms ownership before either hand-off**: once
  immediately before `WorkVoiceCaptureCoordinator.recover`, once immediately before `runConverseHop`.
  Both refusals surface `pendingRetry.card.busy` and do nothing else.
- **Every fabricated token, every `clear(ifCurrentID:)` and every `recordPublicationState(id:)` in my
  files is gone.** Measured over production source: `grep -rn --include='*.swift'` for
  `clear(ifCurrentID:`, `recordPublicationState(id:`, `PendingRetryRecord`, `PendingRetryStore.shared.load()`
  and `retryLane.load()` across `Conduck/Conduck/`, excluding the store's own declarations → **zero hits**.
  The only surviving `recordPublicationState(` calls are the claim form, in `PendingRetryGuard` and
  `WorkVoiceCaptureCoordinator`.
- **Both `.phaseOneFailed`-gated disarms survive EXACTLY.** `git show HEAD:…/ConverseIntent.swift | grep -n phaseOneFailed`
  vs the working tree: `if workPublicationState != .phaseOneFailed {` is at `:414` on **both**, and
  `if !transcriptCaptured, workPublicationState != .phaseOneFailed {` moved only by the lines inserted
  above it (`:689` → `:746`). Byte-identical text; `HeadlessRetryGuardSpanTests` still measures three
  disarms in the documented order, and **not one of its existing assertions was re-anchored or weakened**
  (11 pre-existing + e-surfaces' twelfth all pass unchanged).

**Regression tests — the three the brief names, and how each proves it.**

| Brief's requirement | Case | What it does |
|---|---|---|
| the intent cannot disarm a capture another surface holds (clear returns false → the capture survives) | `ArmSideReservationTests.testTheIntentCannotDisarmACaptureAnotherSurfaceHolds` | arms, takes the intent's hold, releases it, lets `claimNext` take it over, then disarms with the STALE token: the entry is still queued, the recording is byte-identical, and the new holder still owns it |
| the Work sheet's retry is refused while the menu bar holds the lease (busy, nothing deleted) | `WorkVoiceRecoveryTests.testTheSheetsRetryIsRefusedWhileAnotherSurfaceHoldsTheRecording` | another surface reserves; the retry is refused, `retryRefusedBusy` is true, the transcription hop ran **once**, the entry and bytes are untouched, and the state on screen is the one that was already there |
| the recorder's own clear succeeds only with its live token | `WorkVoiceRecoveryTests.testASuccessfulTryAgainReleasesTheDurableRetry` (positive, pre-existing — the double's `clear(_:)` refuses a token that does not match, so a successful finish proves the live one) + `…testRecordAgainLeavesARecordingAnotherSurfaceIsFinishing` (negative — Record Again lets go of a capture another surface holds and deletes nothing) |

Plus: `…testARetryReservesBeforeItTranscribesAndHandsTheCaptureBackWhenItFails` (the reservation is live
DURING the hop, is over THIS capture, and is handed back the moment the retry fails);
`ArmSideReservationTests.testOwnershipIsAnsweredByTheTokenAndNotByTheIdentifier`;
`…testAVerdictFromAnOvertakenLaneIsNotWritten`; `…testAnArmThatPreservedNothingStillOwnsItsCapture`;
`…testTheIntentDisarmsTheCaptureItStillHolds` (the control that must not regress);
`HeadlessRetryGuardSpanTests.testTheIntentConfirmsItStillOwnsTheCaptureBeforeEitherHandoff` (exactly two
gates, one per lane, each before its hand-off — the Chat one before the hop that stores the user turn).

### The one thing r6a#1 does not name, found while tracing it: an arming lane retained a SECOND copy of the recording.

`claim(id:)` answers with the parked bytes, because a surface that SELECTED a capture needs them to
finish it. An arming lane already holds those bytes — it recorded them. Retaining the store's copy on
`PendingRetryGuard.Token.claim` for the whole span of `perform()` puts a second recording of up to
`Constants.maxAudioSize` (15 MB) beside the first, in the most memory-constrained process in the app —
and `ConverseIntent`'s own doc comment claimed the opposite ("so no recording is materialised a second
time"). Same shape on `InAppAudioRecorder.heldRetryClaim`.

**Fix inside my ownership:** `PendingRetryClaim.reservationOnly` (declared beside
`PendingRetryLaneReserving` in `InAppAudioRecorder.swift`, because both arming lanes hold a reservation
this way) — the same capture and the same token with `audioData` dropped. Safe by measurement, not by
assumption: `grep -n 'claim\.\(entry\|token\|id\)' PendingRetryStore.swift` shows every claim-taking
operation (`renew`, `release`, `clear`, `confirmOwnership`, `recordPublicationState`) reads `claim.id`
and `claim.token` and **nothing else**.

**Regression test:** `ArmSideReservationTests.testAnArmingLaneRetainsAReservationAndNotASecondCopyOfTheRecording`
— arms through the real guard, asserts the retained claim carries no bytes, and carries its own control
(a caller that ASKS the store is still handed the recording, so the case cannot pass on an empty queue),
then proves the stripped reservation still works: `stillOwnsCapture` is true and the disarm finishes
exactly that capture and only it.

---

## e-surfaces' two refutations, REVERSED

Both were correct when written and both are now false, for the one reason each gave.

1. **"ConverseIntent: move the disarms to the claim API." REFUTED (a) there is no operation that reserves
   a KNOWN capture; (b) a ten-minute hold in an intent process outlives the OS kill the guard exists
   for.** (a) is gone: `claim(id:duration:)` exists (f-queue) and is what `arm` calls. (b) is gone: the
   hold is **90 s**, the same window as the deferred notice, so an intent the OS killed hands the capture
   back by the time its own notification tells the person to tap and retry. Both e-surfaces' stated
   residual hazards close with it — the intent's durable `.published` write now LANDS (token-checked and
   accepted), and `recover`'s writes against the entry land too.
2. **"WorkboardVoiceCaptureView selects via claimNext." REFUTED — that surface does not read the
   queue.** Still true as written, and irrelevant now: the sheet does not SELECT, it ADDRESSES. Try Again
   reserves the capture the recorder is holding, by its id, before it transcribes — which is the property
   K5 wanted from `claimNext` there, reached by the primitive that fits an arming lane. The sheet's own
   file gained only the busy sentence; the reservation lives in the recorder, where the capture does.
   `PendingRetryQueueWriting` was NOT widened (f-queue §Requests 1 asked for that and it is not needed):
   `PendingRetryLaneReserving` REFINES it in a file I own, and `WorkVoiceRecoveryTests.RecordingRetryLane`
   — also mine — conforms to the refinement. **No foreign file was touched to land O-1.**

---

## Counterfactual — MEASURED, in an isolated copy

`~/Library/Caches/gigaduck-builds/f-arm/cf-tree` (rsync, `.git` excluded), with **only the mechanisms
r6a#1 names** reverted and the whole API surface kept so every case still compiles. Ten scripted
replacements, each verified to have matched exactly once:

| Mutation | What it restores |
|---|---|
| M1 | `PendingRetryGuard.disarm` is the lease-blind `clear(ifCurrentID:)` again |
| M2 | `ConverseIntent.heldCapture` mints `token: UUID()` |
| M3a/M3b | neither hand-off confirms ownership |
| M4a/M4b | the recorder takes no reservation and clears by id |
| M5a/M5b | neither lane renews (and the recorder does not stop renewing on hand-back) |
| M6 | the retained claim keeps the recording |
| M7 | the verdict is written by id again |

`** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` = 0, then:

```
** TEST EXECUTE FAILED **
	 Executed 90 tests, with 25 failures (0 unexpected) in 1.690 (1.709) seconds
```

Per class: `ArmSideReservationTests` 11 executed / 16 failures · `HeadlessRetryGuardSpanTests` 13 / 3 ·
`WorkVoiceRecoveryTests` 30 / 6 · `VoicePermissionsTests` 6 / 0 · `WorkboardAudioCaptureTests` 19 / 0 ·
`WorkboardVoiceLaneTests` 11 / 0. **12 distinct cases red**, first failure each:

| Case | First failure on the counterfactual |
|---|---|
| `testTheIntentCannotDisarmACaptureAnotherSurfaceHolds` | `:105 ("[]") is not equal to ("[3F1B55BF-…]")` — the intent deleted a capture it no longer held; then `:113 ("nil") is not equal to ("Optional(512 bytes)")` and `:118` the new holder's reservation gone |
| `testAVerdictFromAnOvertakenLaneIsNotWritten` | `:308 XCTAssertFalse failed - the write is refused, not silently applied`; `:311 (…published) is not equal to (…phaseOneFailed)`; `:315 XCTAssertNil failed: "words from a lane that lost the capture"` |
| `testAnArmingLaneRetainsAReservationAndNotASecondCopyOfTheRecording` | `:188 XCTAssertTrue failed - The token holds a whole second copy of the recording…` |
| `testNoArmingLaneStillReachesTheLeaseBlindOperations` | `:398 … PendingRetryGuard.swift still calls clear(ifCurrentID:` |
| `testNoLaneMintsATokenTheStoreNeverIssued` | `:449 … ConverseIntent.swift builds a claim carrying a token no store issued` |
| `testTheHeadlessLaneRenewsWhileItWorksAndStopsOnEveryExit` | `:334 XCTAssertTrue failed - The Shortcuts lane never extends its reservation…`, then `:340 XCTUnwrap failed` |
| `testTheRecorderRenewsItsReservationWhileARetryRunsAndStopsOnEveryExit` | `:364 XCTAssertTrue failed - A retry that reserves but never renews…`, `:371` the renewal left running over a reservation given up |
| `HeadlessRetryGuardSpanTests.testTheIntentConfirmsItStillOwnsTheCaptureBeforeEitherHandoff` | `:394 ("0") is not equal to ("2")`, then `:409 XCTUnwrap failed` |
| `HeadlessRetryGuardSpanTests.testTheIntentHandsTheRecoveryTheCaptureItArmedRatherThanOneItSelected` | `:370 XCTAssertFalse failed - The Shortcuts lane mints a claim token no store issued` |
| `testTheSheetsRetryIsRefusedWhileAnotherSurfaceHoldsTheRecording` | `:766 failed - a retry that never ran must not report a transcript` |
| `testARetryReservesBeforeItTranscribesAndHandsTheCaptureBackWhenItFails` | `:822 ("[false, false]") is not equal to ("[false, true]")`, `:831` and `:833` — nothing reserved, nothing handed back |
| `testRecordAgainLeavesARecordingAnotherSurfaceIsFinishing` | `:871 XCTAssertNotNil failed - The recorder let go of a capture it armed…` |

The cases that stay green are the controls whose mechanism the counterfactual does not touch:
`testTheIntentDisarmsTheCaptureItStillHolds`, `testAnArmThatPreservedNothingStillOwnsItsCapture`,
`testTheLeaseBlindCensusMatchesTheShapesItExistsToRefuse` (Rule 0 — it asserts the matcher),
`testOwnershipIsAnsweredByTheTokenAndNotByTheIdentifier` (it drives `confirmOwnership`, which is
f-queue's mechanism and not mutated here), and `testASuccessfulTryAgainReleasesTheDurableRetry` — which
is the point: the finish path must keep working on either tree. The CF tree went with the build cache.

---

## Decisions

1. **`PendingRetryLaneReserving` instead of widening `PendingRetryQueueWriting`.** f-queue §Requests 1
   asked for the parent protocol to be widened plus the `RecordingRetryLane` double updated — "one
   change, three files, none of them mine". A refinement declared in `InAppAudioRecorder.swift` gets the
   same result in files that ARE mine, with no risk to any parallel agent's build: the parent keeps its
   two conformers and its meaning, and only the recorder's injected seam demands the reservation half.
2. **The headless hold is 90 s (L4's simpler half), and the intent ALSO renews at 45 s.** L4 offered
   either. The short horizon is what makes an OS kill safe; the renewal is what makes a slow provider
   safe (a custom STT request is allowed 300 s and attempted three times), and a renewal loop in a
   process that dies simply stops. Both, because each covers the other's failure.
3. **A refused renewal does NOT stop the loop** — deliberately unlike the sibling helper
   `PendingRetryLeaseRenewal.whileRenewing`. Measured reason: `PendingRetryStore.renew` is
   `(try? withExclusiveLock { … }) ?? false`, so it answers false for a cross-process lock it could not
   take as well as for a hold somebody overtook. Stopping on the first would give away a reservation that
   is still ours. What turns a genuine takeover into a user-visible refusal is `confirmOwnership` before
   the hand-off, not the renewal's return value. Stated at both loops as a constraint.
4. **The recorder reserves when a RETRY starts, not when the capture is armed.** A hold kept from the
   moment of failure would refuse the person their own recording on the retry card for as long as the
   sheet stayed open, and the recorder is finishing nothing in between.
5. **`armDurableRetryID` is recorded only when the save LANDED** (`guard (try? await retryLane.save(…)) != nil else { return }`).
   A save that threw parked nothing, so there is no entry to reserve — and without this, the next Try
   Again would ask the queue for a capture that was never queued and read the refusal as somebody else's
   hold, i.e. it would refuse the person a retry it could have run from the bytes in hand.
6. **The busy state is `pendingRetry.card.busy` on every surface** (e-surfaces §Decisions 5's sixth key,
   already in the catalog) rather than a typed error. Nothing failed: the recording is safe and is being
   finished elsewhere. On the sheet it renders in the error state beside the standing error, and it is
   folded into `accessibilityStatusID`/`accessibilityStatusMessage` because the refusal deliberately does
   NOT change `state` — without that, the only thing that changed would be invisible to VoiceOver.
7. **The recorder does not confirm ownership again before `attachTranscript`.** L3's letter allows the
   finishing `clear(claim)` to be the check, and it is token-gated. The residual window needs five
   consecutive missed renewals (an app suspended >10 minutes mid-retry) and its worst outcome is an
   IDEMPOTENT second attach of the same words to the same card — where the alternative, refusing there,
   would throw away words that were just bought. The intent gates instead, because its hand-offs are not
   idempotent: a Chat send is a user turn and a gateway effect.
8. **`PendingRetryGuard.storeForTesting` is a `#if CONDUCK_TESTING` seam.** What the guard now guarantees
   is a property of the RESERVATION — that a disarm deletes only a capture this process still holds — and
   no assertion about that is possible without two holders over one entry. `PendingRetryStore.shared` is
   a process-global singleton over one App-Group file every capture test in this bundle shares. Nil in
   every other build; the declaration itself compiles only under the flag.
9. **No Codex consult.** The one genuinely hard call — whether an arming lane may hold a reservation at
   all — was decided by the orchestrator in L1/L4 and is settled by evidence in this repo (the 90 s
   notification window against the 600 s default), not by a technical unknown.

## Deviations

1. **`PendingRetryQueueWriting` is unchanged**, against f-queue §Requests 1. §Decisions 1 — same
   guarantee, no foreign edit, and the census now passes from the arming lanes' side.
2. **`WorkVoiceCaptureCoordinator.swift` was not touched.** My brief allowed it "only if the claim type
   forces it"; the claim type is unchanged, so it did not.
3. **`PendingRetryLeaseRenewal.whileRenewing` (another agent's new file) is not consumed.** It is pinned
   to `PendingRetryStore.shared` and to a 120 s default; my recorder renews through its injected
   `retryLane` (the test double) and my intent needs 45 s against a 90 s hold. §Requests 4 records the
   consolidation for whoever wants it.

---

## Catalog

**Keys I ADDED in source: NONE. Keys I made DEAD: NONE.** No `.xcstrings` file was opened.

`pendingRetry.card.busy` = `"This recording is already being finished. Try again in a moment."` gains
**four new call sites** — `Intents/ConverseIntent.swift` ×2 (the Work gate and the Chat gate) and
`Views/Workboard/WorkboardVoiceCaptureView.swift` ×2 (the visible sentence and the a11y status). All four
carry the byte-identical default value, and it matches the value already in `Localizable.xcstrings`
(verified by parsing the catalog). Nothing for the serial copy agent to splice from this slice.

---

## Requests

1. **INTEGRATOR — L5's census, and it is RED right now.** `PendingRetrySurfaceHandoffTests.testNoProductionCallerRemainsOnTheSupersededQueueOperations`
   fails with exactly two assertions, both of which say the migration LANDED:
   ```
   :283 XCTAssertEqual failed: ("[]") is not equal to ("["Conduck/Services/PendingRetryGuard.swift",
        "Conduck/Services/InAppAudioRecorder.swift"]") — `clear(ifCurrentID:`
   :283 XCTAssertEqual failed: ("[]") is not equal to ("["Conduck/Intents/ConverseIntent.swift"]")
        — `recordPublicationState(id:`
   ```
   The edit is in `PendingRetrySurfaceHandoffTests.swift` (not mine, and actively being edited by another
   f-agent — I did not touch it): set `"clear(ifCurrentID:"` and `"recordPublicationState(id:"` to `[]`
   and delete the three allowlist comments explaining why the arming lanes could not migrate. Their
   reasons are gone: `claim(id:duration:)` exists and all three lanes use it.
2. **Owner of `Services/PendingRetryStore.swift` — the superseded operations now have ZERO production
   callers and can go.** Measured across `Conduck/Conduck/`: `load()`, `clear(ifCurrentID:)`,
   `updateAttemptIfCurrent`, `recordPublicationState(id:)` and `PendingRetryRecord` appear only in the
   store's own declarations. `PendingRetryQueueWriting` still declares `clear(ifCurrentID:)`, and its two
   conformers (the store and `WorkVoiceRecoveryTests.RecordingRetryLane`) still implement it — retiring
   it means editing both, and `PendingRetryDurabilityTests`/`PendingRetryQueueTests` still call `load()`
   legitimately (K2 allows tests to). **O-2 (`PendingRetryRecord`) retires in the same edit.**
3. **Owner of `MenuBar/DictationPopoverView.swift` — e-surfaces §Requests 1 still stands**
   (`hasSavedRetryAudio` should read `service.pendingRetryCount > 0`). Unrelated to my files; repeated so
   it is not lost.
4. **Whoever consolidates the renewal.** Two hand-rolled renewal loops now exist (mine) beside
   `PendingRetryLeaseRenewal.whileRenewing` (another agent's). A single home would want: an injectable
   store (my recorder renews through a protocol seam), a caller-supplied interval (45 s for a 90 s hold),
   and §Decisions 3's rule about a refused renewal — the shared helper currently ENDS the loop on false,
   which for a transient lock failure gives away a hold that is still the caller's.
5. **Nobody undo these** — each is pinned by a case measured red on the counterfactual:
   - **`arm` takes its reservation by ID and holds it for 90 s.** `claimNext` here would hold a
     stranger's recording, and a ten-minute hold would outlive the notice that invites the retry.
   - **`disarm` is `clear(claim)`, and the notification is cancelled only after it succeeds.**
   - **The intent confirms ownership TWICE, once per destination, each immediately before its hand-off.**
     One check higher up leaves the Chat send — the one that costs a duplicate turn and a duplicate
     gateway call — outside it.
   - **The token the intent hands `recover` is the store's, never `UUID()`.** A fabricated token is
     indistinguishable at the call site and refused at the store, silently.
   - **The recorder reserves BEFORE the hop and hands back on every non-finishing outcome**, and clears
     only through the reservation.
   - **An arming lane retains the reservation, not the recording.**
   - **Both `.phaseOneFailed`-gated disarms stay exactly as they are.**

---

## Refuted

**Nothing.** r6a#1 holds in every clause at the anchors quoted, and every design direction in the brief
(L1, L2, L3, L4) was implementable as specified. The two places the letter moved are recorded as
decisions rather than refusals: the protocol refinement instead of widening `PendingRetryQueueWriting`
(§Decisions 1, which avoids every foreign edit), and the recorder's finish relying on the token-gated
`clear(claim)` rather than a further `confirmOwnership` (§Decisions 7, which L3 explicitly permits).

The two REFUTATIONS this wave was told to reverse are reversed, and both for the exact reason each gave
— see §"e-surfaces' two refutations, REVERSED".

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/f-arm/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from a tail
or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`.

- **Simulator TCC checked BEFORE trusting any run:**
  `sqlite3 …/5C851D88…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0. No stale denial.
- **iOS `build-for-testing`** → `ios-bft-4.log` (final): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, ten quoted `-only-testing:` flags → `test-3.log`:
  ```
  ** TEST EXECUTE SUCCEEDED **
	 Executed 157 tests, with 0 failures (0 unexpected) in 2.507 (2.539) seconds
  ```

  | Class | Result line |
  |---|---|
  | `ArmSideReservationTests` (**new**) | `Executed 11 tests, with 0 failures (0 unexpected) in 0.076 (0.078) seconds` |
  | `HeadlessRetryGuardSpanTests` | `Executed 13 tests, with 0 failures (0 unexpected) in 0.057 (0.059) seconds` (was 12) |
  | `WorkVoiceRecoveryTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.280 (0.285) seconds` (was 27) |
  | `WorkboardVoiceLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.084 (0.086) seconds` (unchanged) |
  | `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.147 (0.151) seconds` (unchanged) |
  | `VoicePermissionsTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.002 (0.003) seconds` (unchanged) |
  | `PendingRetryQueueTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.009 (0.013) seconds` |
  | `PendingRetryDurabilityTests` | `Executed 26 tests, with 0 failures (0 unexpected) in 0.095 (0.100) seconds` |
  | `PendingRetryLeaseTests` | `Executed 13 tests, with 0 failures (0 unexpected) in 0.049 (0.052) seconds` |
  | `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 1.707 (1.710) seconds` |
- **`PendingRetrySurfaceHandoffTests` run separately and reported red on purpose** (`test-1.log`:
  `Executed 165 tests, with 2 failures`) — the census allowlist, §Requests 1. It is the ONLY failure
  anywhere in my runs, and both of its assertions say the migration succeeded.
- **macOS `build -destination 'platform=macOS'`** → `mac-2.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 808 Swift files scanned…`, exit 0.
- **`git diff --check`** → no output, exit 0. `git status --short` filtered for `xcstrings`, `pbxproj`,
  `Conduck/Configs` and `docs/qa` → **empty**. The new test file: **0 tab lines, 0 trailing-whitespace
  lines**, opens with `// SPDX-License-Identifier: Apache-2.0` + a header comment.
- **Warnings: ZERO added.** macOS full build: the only warnings in my four production files are the four
  pre-existing main-actor-isolation ones in `ConverseIntent.swift` that e-surfaces and d-retry both
  recorded (`:240`, `:478`, and the two that moved with my insertions: `:530`→`:555`, `:553`→`:578` —
  same code, same count, four then and four now). **Zero** in `PendingRetryGuard.swift`,
  `InAppAudioRecorder.swift`, `WorkboardVoiceCaptureView.swift` and all three test files, on both
  platforms.
- **Suite delta from this slice: +15** (`ArmSideReservationTests` NEW 11, `HeadlessRetryGuardSpanTests`
  12 → 13, `WorkVoiceRecoveryTests` 27 → 30). **The watch target compiles none of my files** —
  `grep -c ArmSideReservationTests project.pbxproj` = 0, the synchronized group covers the new test
  source, and the four production files are iOS/macOS app-target sources the watch target's
  `membershipExceptions` never names. **No `.pbxproj` edit was needed or made.**
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim is
  assigned, and other f-agents were editing this tree throughout (nine of their files are modified and
  four more are new in `git status` at end of task) — a full run would report their in-flight state as mine.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh f-arm` → `removed:
  f-arm`; every log quoted above went with it, and so did the counterfactual tree.

## What I did NOT verify, plainly

- **Two PROCESSES on one container are still untested** (O-5 / Gate 2). My cases drive the real store,
  the real `flock` and the real write orders, but from one process; the intent-vs-app race is reasoned
  from the lock, not measured across processes.
- **No renewal was ever observed firing.** Both intervals are 45 s and 120 s, so the tests assert the
  timer's SHAPE in source (started before the hop, cancelled on every exit) and the store's `renew`
  behaviour is pinned by f-queue's own cases. A wall-clock test would have to wait out a real interval.
- **No UI, no screen, no device.** The busy sentence on the voice sheet, its VoiceOver reading, and the
  Shortcuts-side refusal message are all founder-QA items below.
- **`ConverseIntent.perform()` cannot be driven in this bundle at all** — it takes an `IntentFile` from
  the Shortcuts runtime and a live provider — so everything asserted about that function is asserted over
  comment-stripped SOURCE, which is this file's standing method.
- **I ran no other agent's counterfactual and did not re-run theirs.**

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven, e-queue's six, e-surfaces' eight and f-queue's five, which all still apply.

1. **A Shortcut and the app, racing for one recording.** Airplane mode. Run the Action Button / Shortcut
   capture so it parks a recording, then — before the "Recording Saved" notice arrives — open the app and
   tap Retry on the card. Exactly one of them may finish it: one produces the card (or the chat turn),
   the other must say **"This recording is already being finished. Try again in a moment."** and change
   nothing. There must never be two cards, two chat turns, or two replies.
2. **The Shortcut killed mid-flight, then retried at once.** Start a Shortcut capture on a terrible
   connection and force-quit the Shortcuts host while it is thinking. When the "Recording Saved" notice
   arrives at 90 seconds, tap it and press Retry immediately: it must offer you the recording **now**,
   not refuse it. (This is the whole reason the headless hold is 90 seconds rather than ten minutes.)
3. **The desk voice sheet and the retry card, at once.** Park a Work voice capture (airplane mode,
   destination Work). With the voice sheet still open showing its error, retry from the home-screen card,
   and while that is running press **Try Again** on the sheet. The sheet must show the busy sentence and
   do nothing else — no second spinner, no second provider charge — and when the card's retry finishes,
   exactly one audio card carries the words.
4. **Record Again while the card is retrying.** Same setup, but press **Record Again** on the sheet while
   the card's retry is in flight. The new recording must start, and the FIRST recording must still be
   there and must still finish correctly on the card. Nothing may vanish.
5. **A long Work retry does not lose its hold.** With a deliberately slow custom STT endpoint, start the
   sheet's Try Again and let it run past ten minutes. It must still finish onto the same card, and the
   retry card must not have taken the recording away in the meantime.
6. **VoiceOver on the voice sheet's refusal.** With the sheet in its error state, trigger the busy
   refusal (step 3). VoiceOver must read the busy sentence — the visible state does not otherwise change,
   so this is the only signal a non-sighted person gets.
7. **The Shortcut whose save failed still works.** Fill the device storage (or otherwise make the parked
   write fail) and run a Shortcut capture: it must still transcribe and still deliver its answer. The one
   thing that must NOT happen is a refusal — with nothing parked, this process holds the only copy.

---

## Settled facts — one sentence each, for whoever writes the docs

- A lane that makes a recording reserves that exact recording the moment it parks it, so a Shortcut, the
  app's retry card and the desk's voice sheet can all be live at once without two of them finishing one
  recording.
- A Shortcut holds its recording for ninety seconds — the same ninety seconds after which it tells you to
  open the app and retry — so a Shortcut the system shuts down hands the recording back exactly when the
  notice invites you to pick it up.
- A lane that is still working extends its hold as it goes, so a slow transcription cannot have its
  recording taken or deleted underneath it, and a lane that dies stops extending simply by being gone.
- Before a Shortcut writes anything to your desk or sends anything to your assistant, it checks that the
  recording is still its own; if another surface took it over, it stops and says so rather than doing the
  same thing twice.
- Finishing a recording deletes it only for the surface that is holding it — a Shortcut completing can no
  longer delete the recording the app is in the middle of transcribing.
- Try Again on the desk's voice sheet reserves the recording before it spends anything on transcribing
  it, and when another surface already holds it the sheet says the recording is being finished elsewhere
  rather than reporting a failure that did not happen.
- Starting a new recording lets go of the previous capture without deleting a recording somebody else is
  finishing.
- A recording whose parking failed is still transcribed and still delivered: with nothing saved there is
  nothing for another surface to hold, and the copy in hand is the only one there is.
- A lane that recorded the audio keeps only its claim on the recording, never a second copy of the audio
  itself, so a background capture never carries two copies of the same recording through the work.
