# e-surfaces — the retry surfaces now speak to a QUEUE. r5a#4, r5a#5 and r5a#8/O-16 CONFIRMED and fixed; O-17 closed. ONE design direction REFUTED with measured reasons (ConverseIntent cannot hold a reservation).

Slug `e-surfaces`. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`. No commits, pushes, stash, checkout,
reset or index operations. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet
touched. No file outside my ownership edited.

Files changed — seven, of which one is new:

| File | Change |
|---|---|
| `Conduck/Conduck/ContentView.swift` | `runPendingRetry` splits into `runPendingRetry` (reserve / release) + `attemptPendingRetry`; `finishWorkRetry` and `finishPendingRetry` take the claim; NEW `discardPendingRetry` + `discardButtonTapped`; `pendingRetryCount` state; `refreshPendingRetryState` reads `pendingCount()` |
| `Conduck/Conduck/MenuBar/DictationService.swift` | `retryLast` splits into `retryLast` (reserve / release) + `attemptRetry`; NEW `settleAfterFinishing` (the backlog state) and `refreshPendingRetryCount`; `pendingRetryCount` property; `preserveForRetry`'s bookkeeping URL moved off the pre-id-scoped name (e-queue §Requests 3) |
| `Conduck/Conduck/Views/Components/PendingRetryCard.swift` | `pendingCount` + `onDiscard` + the confirmed Discard affordance (O-16) |
| `Conduck/Conduck/Intents/ConverseIntent.swift` | NEW `heldCapture(_:audio:)` — the claim-shaped value the ARMING process hands `recover`; the two `.phaseOneFailed` disarm gates are **byte-identical**, and both `recordRecoveryState` call shapes are unchanged |
| `Conduck/Conduck/ViewModels/DiagnosticsRunner.swift` | the one `pendingCount()` line + the count in `factPendingRetry` (O-17) |
| `Conduck/ConduckTests/RemoteAgent/HeadlessRetryGuardSpanTests.swift` | 11 → 12 cases; nothing existing weakened or re-anchored (all 11 pass unchanged) |
| `Conduck/ConduckTests/PendingRetrySurfaceHandoffTests.swift` | **NEW**, 9 cases — the surface sequence, the discard, the legacy-caller census, the three surface shapes |

`Views/Workboard/WorkboardVoiceCaptureView.swift`, `DiagnosticsFocusTests.swift` and
`RemoteAgentRecoveryCopyLaneTests.swift` are mine and are **unchanged** — reasons under §Refuted 2
and §Decisions 6.

---

## Findings

### r5a#4 (major) — after finishing the newest capture, neither surface offered the next. CONFIRMED, fixed.

**Verified first, by call path.** `DictationService.finishWorkRetry` ended `state = .idle` (`:408` at
`f794856`), as did the Chat arm (`:309-314`), and `retryLast` is reachable only from `.error`
(`guard case .error = state else { return }`, `:186`). `DictationPopoverView` draws its audio Retry
inside `case .error(let message, let isRetryable)` and nowhere else (`:991`, `:1356`), so a queue with
two captures lost the second the moment the first finished — until an unrelated capture failed. On
iOS, `PendingRetryCard` took no count at all (`:13-32`) and `releasePendingRetry` re-read only the
boolean `hasPending()`, so a card still standing after a successful retry read as a retry that failed.
Both halves hold exactly as written.

**Fix = K5.** Both surfaces re-query `pendingCount()` after every terminal clear.
- iOS: `finishPendingRetry(_ claim:)` sets `pendingRetryCount`, and the card renders
  `pendingRetry.card.count` above one.
- macOS: `settleAfterFinishing(_ claim:)` settles into `.idle` only when the count is zero, and
  otherwise into `.error(message: <N recordings waiting>, isRetryable: true)` — which is not an
  apology but the one state that offers the next tap. **The one thing this cannot finish from inside
  my ownership is §Requests 1**: the popover's `hasSavedRetryAudio` asks the error TAXONOMY whether
  bytes were saved, and the taxonomy can only answer for the capture that just failed in this
  process. I set `lastError` from the next capture's arming code, which is present for every capture
  the recorder or this service armed and absent for one the Shortcuts lane armed before anything
  failed. So the macOS backlog button works in the common case and is withheld in that one; the
  one-line change that would ask the count instead is in §Requests.

**Regression tests.**
- `PendingRetrySurfaceHandoffTests.testFinishingOneOfTwoLeavesTheSurfaceRetryCapableWithTheCountDecremented`
  — the behaviour: two waiting, finish the offered one, `pendingCount() == 1`, and the next
  `claimNext()` is the OTHER capture with its own bytes.
- `…testTheMenuBarSettlesIntoAStateThatOffersTheNextTap` — the source half, which is the half that
  actually broke: `settleAfterFinishing` re-reads the queue, `.idle` sits inside
  `guard pendingRetryCount > 0 else`, and the backlog `.error` is what remains.
- `…testTheCardShowsTheBacklogAndConfirmsTheDiscard` — the count is rendered only above one.

### r5a#5 (minor) — two surfaces could transcribe and finish the same capture. CONFIRMED, fixed.

**Verified:** `ContentView.swift:1457` and `MenuBar/DictationService.swift:193` both took
`load().first` and both later `clear(ifCurrentID:)`; nothing between them said who held what, and
`load()` materialised every queued recording to hand back one.

**Fix = K2 consumed at both surfaces.** Selection is `claimNext()`, the reservation goes back through
`release(claim)` on every outcome that leaves the capture waiting, and only the outcome that retired
the entry reports the capture finished. Each surface funnels that into ONE statement
(`if await attempt…(claim) == false { await release(claim) }`) rather than a duty every early return
has to remember — which is the shape the old code got wrong.

**Production callers of the superseded operations, after this wave:**

| Operation | Callers left | Why |
|---|---|---|
| `load()` | **none** | both surfaces select through `claimNext` |
| `updateAttemptIfCurrent(id:)` | **none** | both surfaces count attempts through `updateAttempt(claim:)` |
| `clear(ifCurrentID:)` | `PendingRetryGuard.swift`, `InAppAudioRecorder.swift` | both release a capture the SAME process armed, addressed by the id it minted — neither selects. §Requests 2 |
| `recordPublicationState(id:)` | `Conduck/Intents/ConverseIntent.swift` | same reason. §Refuted 1 |

**Regression tests.** `…testNoProductionCallerRemainsOnTheSupersededQueueOperations` — an EXACT-set
census over all 410 shipping Swift files, both directions: a new legacy caller fails it, and so does a
listed one that has been migrated, so the allowlist cannot outlive its reasons. Its Rule 0 control
(`…testTheCensusScanReachesProductionSourceAndItsNeedlesMatch`) proves the scan reaches production
source, excludes tests, and that the needles match a call broken across lines while NOT matching the
claim form. Plus `…testTheCardSelectsReservesAndCountsThroughTheClaimAPI` and
`…testTheMenuBarSettlesIntoAStateThatOffersTheNextTap` for the two surfaces' shape, and
`…testAReleasedCaptureIsOfferedAgainAtOnceAndIsStillCounted` /
`…testAnUnreleasedReservationLeavesACaptureCountedButUnclaimable` for the lease from both sides.

### r5a#8 (minor, O-16) — an expiry-exempt entry had no user-facing discard. CONFIRMED, fixed.

**Verified:** `grep -rn 'PendingRetryStore.shared.clear()'` over production → **zero hits**, and
`isExemptFromExpiry` (`resolvedDestination == .work && publicationState != .published`) means a Work
capture the desk never accepted keeps its bytes in the App Group indefinitely. The card offered Retry
and Troubleshoot and no dismiss.

**Fix = K5's Discard.** `PendingRetryCard` gains a destructive "Discard recording" button, confirmed
in the card (`confirmationDialog`, title / body / action keys under §Catalog), calling
`onDiscard` → `ContentView.discardPendingRetry()` → `claimNext()` → `finishPendingRetry(claim)`,
which is `clear(_ claim:)` + `PendingRetryGuard.cancelDeferredNotification(for: claim.id)` + a fresh
count. **Not `clear()`** — e-queue §Requests 4 is explicit that the discard-everything operation would
also delete a capture another surface is finishing.

*How the deferred notification is cancelled by the same identifier:* `PendingRetryGuard.arm` schedules
under `notificationID(for: metadata.id)` = `"conduck-pending-retry-" + id.uuidString`, and
`cancelDeferredNotification(for:)` rebuilds exactly that string and removes it pending AND delivered.
The discard path calls that function, so it cannot drift from the scheduler.

**Regression tests.** `…testDiscardingTheOfferedCaptureRemovesExactlyThatOne` (two waiting; the
offered one's record, recording and screenshot are gone, the other's recording is byte-identical and
still claimable, count 1) · `…testTheCardShowsTheBacklogAndConfirmsTheDiscard` (the affordance exists,
is confirmed, says the recording cannot be recovered, and reaches the host) ·
`…testTheCardSelectsReservesAndCountsThroughTheClaimAPI` asserts `discardPendingRetry` contains no
`PendingRetryStore.shared.clear()`.

### O-17 — the parked-retry row described the newest of possibly several. CLOSED.

One line beside the existing snapshot, exactly as e-queue §Requests 1 specifies:

```swift
let pendingRetryCount = await PendingRetryStore.shared.pendingCount()
```

`diagnosticSnapshot()` keeps its signature and its meaning. The count travels in `factPendingRetry`
— `parked(code 12, 8m left, 3 waiting)` / `orphaned(3 waiting)` — which is the anonymous report line
a support conversation reads, and needs no catalog key. **The on-screen sentence still describes one
capture**; §Requests 4 names the key that would fix that, deliberately not minted here because my
brief scopes this file to "the one-line count only".

---

## How I know the tests bite — MEASURED, not argued

A counterfactual copy of the tree under `~/Library/Caches/gigaduck-builds/e-surfaces/cf-tree` (rsync,
`.git` excluded), reverting only the mechanisms the findings name. Three passes, because two of the
cases are controls on OPPOSITE halves of the lease and cannot both be red at once.

**Pass 1 (`cf-test-1.log`)** — M1 ContentView back to `load().first` with no reservation,
`clear(ifCurrentID:)` and `hasPending()` · M2 `settleAfterFinishing` always `.idle` and `retryLast`
back to `load().first` · M3 the card renders the count at any size and its confirmation body key
becomes the button's · M4 the intent SELECTS via `claimNext(surface: .work)` · M5 `clear(_ claim:)`
removes every waiting capture (the `clear()` mistake). `** TEST BUILD SUCCEEDED **`,
`grep -c ': error: '` = 0, then:

```
** TEST EXECUTE FAILED **
	 Executed 12 tests, with 1 failure (0 unexpected)      ← HeadlessRetryGuardSpanTests
	 Executed 9 tests, with 17 failures (0 unexpected)     ← PendingRetrySurfaceHandoffTests
```

| Case | First failure on the counterfactual |
|---|---|
| `HeadlessRetryGuardSpanTests.testTheIntentHandsTheRecoveryTheCaptureItArmedRatherThanOneItSelected` | `:327 XCTAssertFalse failed - The Shortcuts lane now RESERVES a capture out of the queue…` |
| `testFinishingOneOfTwoLeavesTheSurfaceRetryCapableWithTheCountDecremented` | `:93 ("0") is not equal to ("1")`, then `:104 XCTUnwrap failed` — the capture behind the finished one is gone |
| `testDiscardingTheOfferedCaptureRemovesExactlyThatOne` | `:184 ("0") is not equal to ("1") - exactly one capture left`, then `:186 XCTUnwrap failed` |
| `testNoProductionCallerRemainsOnTheSupersededQueueOperations` | `:280 ("["Conduck/MenuBar/DictationService.swift", "Conduck/ContentView.swift"]") is not equal to ("[]")` for `load()`, and a second `:280` for `clear(ifCurrentID:` naming ContentView |
| `testTheCardSelectsReservesAndCountsThroughTheClaimAPI` | `:338 :341 :344 :349 :354 :359 :362` — seven assertions, one per statement the surface stopped making |
| `testTheMenuBarSettlesIntoAStateThatOffersTheNextTap` | `:400 XCTAssertTrue failed - Nothing re-reads the queue after the finish…`, then `:414 XCTUnwrap failed - The idle/backlog choice is no longer gated…` |
| `testTheCardShowsTheBacklogAndConfirmsTheDiscard` | `:443` the count is no longer gated above one, `:450` the confirmation no longer says it cannot be recovered |

**Pass 2 (`cf-test-2.log`)** — `release(_:)` neutered to a no-op, everything else as pass 1:

```
Test Case '…testAReleasedCaptureIsOfferedAgainAtOnceAndIsStillCounted' failed
  PendingRetrySurfaceHandoffTests.swift:128: XCTUnwrap failed … a released capture is takeable at
  once, not after the lease lapses
Test Case '…testAnUnreleasedReservationLeavesACaptureCountedButUnclaimable' passed   ← correct: it is the control for the OTHER half
```

**Pass 3 (`cf-test-5.log`)** — `release` restored, `claimNext`'s live-lease skip disabled:

```
Test Case '…testAnUnreleasedReservationLeavesACaptureCountedButUnclaimable' failed
  PendingRetrySurfaceHandoffTests.swift:152: XCTAssertNil failed: "PendingRetryClaim(entry: …"
Test Case '…testAReleasedCaptureIsOfferedAgainAtOnceAndIsStillCounted' passed
```

**8 of my 9 new cases, plus the new `HeadlessRetryGuardSpanTests` case, measured red on the mutation
each names.** The ninth
(`testTheCensusScanReachesProductionSourceAndItsNeedlesMatch`) is the census's Rule 0 control and
stays green by design — it asserts the matcher, not the code. The CF tree went with the build cache
at end of task.

*Two of the pass-3 attempts died before any test case started* — `Simulator device failed to launch
… Busy ("Application failed preflight checks")`, no `Executed` line at all — and one attempt on the
REAL tree died the same way (`test-4.log`). Each was retried with no change to the tree and went
green (`cf-test-5.log`, `test-5.log`). I did NOT run `simctl shutdown all`: the failing bundle id in
the first two was `com.example.Conduck`, i.e. another agent's install on the shared simulator, and
shutting it down would have killed their run. Reported rather than hidden.

---

## Decisions

1. **`claimNext()` with NO surface filter at both retry surfaces.** Both route by
   `resolvedDestination` after they have the capture, exactly as they did with `load().first`, and
   both can finish either kind. Filtering would make the iOS card refuse a Chat capture it is
   perfectly able to send, and would leave a Work capture parked on macOS behind a menu bar that had
   filtered it out. `PendingRetrySurface` exists for a caller that genuinely serves one lane; neither
   of these is one.
2. **The reservation is released in ONE statement per surface, not in every early return.** Each
   surface's body became `attemptPendingRetry` / `attemptRetry`, returning `true` only when the entry
   was actually retired. The alternative — a `defer` with a fire-and-forget `Task` — cannot `await`,
   so the release could land after the user's next tap and hand them "this recording is already being
   finished" about their own. Measured cost of the chosen shape: one extra function per surface.
   `…testTheCardSelectsReservesAndCountsThroughTheClaimAPI` pins that exactly one statement may say
   `return true` and that it follows the finish.
3. **`refreshPendingRetryState()` reads `pendingCount()` instead of `hasPending()`.** Same predicate
   (`liveQueueLocked(…).isEmpty` vs `.count`), same cost, one fewer actor hop, and the card needs the
   number anyway. `hasPending()` keeps its signature and its other callers.
4. **The card renders the count only ABOVE one.** At exactly one the headline already says a recording
   is waiting; "1 recording waiting" beside it is the same sentence twice. The key is still referenced
   in source, so the catalog audit is satisfied.
5. **A sixth copy key, `pendingRetry.card.busy`, beyond K5's five.** Without it a Retry tap that finds
   every capture reserved does nothing visible — the card stays up and the button just stops working,
   which is the exact reading the count was added to prevent. It is reachable on both platforms: a
   force-quit mid-retry leaves a live ten-minute reservation, and on macOS the main window and the
   menu bar can hold one another's. Both call sites carry the identical default value.
6. **`DiagnosticsFocusTests` and `RemoteAgentRecoveryCopyLaneTests` untouched.** Neither asserts
   anything about the retry queue — the first drives `DiagnosticsFocus`'s deny-list, the second the
   per-lane `AppError` copy — and both pass unchanged (4/0 and 12/0). Listing them as mine gave me the
   right to change them, not a reason to.
7. **No Codex consult.** The one genuinely hard call — whether the Shortcuts lane can hold a
   reservation — is settled by evidence inside this repo (§Refuted 1), not by a technical unknown.

## Deviations

1. **K5 says all four surfaces "select via claimNext". `WorkboardVoiceCaptureView` does not, and
   cannot from inside my ownership** — §Refuted 2.
2. **K5 says `ConverseIntent` moves its disarms to the claim API. It does not** — §Refuted 1. The two
   `.phaseOneFailed` gates the brief told me to keep exactly ARE byte-identical, and
   `HeadlessRetryGuardSpanTests` still measures three disarms in the documented order.
3. **`DictationService.preserveForRetry`'s bookkeeping URL changed** (e-queue §Requests 3). It built
   `…/pending_retry_audio.m4a` literally; that filename is now the pre-id-scoped recording the store
   folds in once and then never reads or deletes. It is `PendingRetryFiles.audio(captureID, .chat)`
   now — the file the store actually writes. No behaviour depends on it (the store derives the real
   path), which is why this is a naming fix and not a finding.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/e-surfaces/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from a
tail or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`. The one
throwaway tree copy lived under the slug dir and went with it.

- **Simulator TCC checked BEFORE trusting any run**, per the standing rule:
  `sqlite3 …/6C3FB33E…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0 (`.notDetermined`). No stale denial.
- **iOS `build-for-testing`** → `ios-bft-6.log` (final): `grep -c ': error: '` = **0**, and
  `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, thirteen quoted `-only-testing:` flags → `test-5.log`:
  ```
  ** TEST EXECUTE SUCCEEDED **
	 Executed 161 tests, with 0 failures (0 unexpected) in 6.312 (6.348) seconds
  ```
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

  | Class | Result line |
  |---|---|
  | `PendingRetrySurfaceHandoffTests` (**new**) | `Executed 9 tests, with 0 failures (0 unexpected) in 1.623 (1.625) seconds` |
  | `HeadlessRetryGuardSpanTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.048 (0.050) seconds` (was 11) |
  | `DiagnosticsFocusTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.011 (0.012) seconds` (unchanged) |
  | `RemoteAgentRecoveryCopyLaneTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.010 (0.012) seconds` (unchanged) |
  | `PendingRetryQueueTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.008 (0.012) seconds` |
  | `PendingRetryDurabilityTests` | `Executed 21 tests, with 0 failures (0 unexpected) in 0.068 (0.072) seconds` |
  | `PendingRetryDestinationTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.010 (0.012) seconds` |
  | `WorkVoiceRecoveryTests` | `Executed 27 tests, with 0 failures (0 unexpected) in 0.260 (0.266) seconds` |
  | `VoicePermissionsTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds` |
  | `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.930 (2.931) seconds` |
  | `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 1.126 (1.127) seconds` |
  | `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.136 (0.139) seconds` |
  | `WorkboardVoiceLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.082 (0.084) seconds` |

  Beyond the classes my brief names I ran the two drift-guard registries (the card is a registered
  retry surface in one of them) and the two Workboard voice-lane classes, because both assert about
  the surfaces I rewrote.
- **macOS `build -destination 'platform=macOS'`** → `mac-3.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
  `ContentView.swift` and `MenuBar/DictationService.swift` both compile there.
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 803 Swift files scanned…`,
  exit 0. `DictationService.swift` keeps its existing `CONTAINER_ALLOWLIST` row (its
  `containerURL(forSecurityApplicationGroupIdentifier:)` call is the one I re-pointed, not a new one);
  the new test file names no container.
- **`git diff --check`** → no output, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` and all three mirror triplets → **empty**. The new file checked by
  hand: **0 trailing-whitespace lines, 0 tab lines**, opens with
  `// SPDX-License-Identifier: Apache-2.0` + a header comment.
- **Warnings: ZERO added.** On both platforms the only warnings touching my files are pre-existing and
  at code I did not modify — `ConverseIntent.swift:240/478/530/553` (main-actor isolation, the same
  class d-retry recorded), `DictationService.swift:835` (`startDisplayTimer`, the same
  captured-`self` class as `NetworkPathObserver`/`CloudSyncMonitor`/`ReadStateStore`), and
  `DiagnosticsRunner.swift:3424` (an unrelated `claim()`). **Zero** in `ContentView.swift`,
  `PendingRetryCard.swift`, `PendingRetrySurfaceHandoffTests.swift` and
  `HeadlessRetryGuardSpanTests.swift` on both platforms.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim
  is assigned, and other agents were editing this tree throughout — a full run would report their
  in-flight state as mine. **Suite delta from this slice: +10** (`PendingRetrySurfaceHandoffTests`
  NEW 9, `HeadlessRetryGuardSpanTests` 11 → 12; every other class unchanged in count). **The watch
  target compiles none of my files** — `grep -c` for `PendingRetrySurfaceHandoffTests.swift` in
  `project.pbxproj` is 0, and the four production files I touched are iOS/macOS app-target sources
  that the watch target's `membershipExceptions` never names. **No `.pbxproj` edit was needed or
  made**; the synchronized group covers the new test file.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh e-surfaces` →
  `removed: e-surfaces`; every log quoted above went with it, and so did the counterfactual tree.
  Re-run to reproduce.

## What I did NOT verify, plainly

- **No UI, no screen.** The card's new count line, the Discard confirmation, and the macOS backlog
  state are all founder-QA items below. A source guard proves the statements are there; it cannot
  prove the sheet looks right or that VoiceOver reads the new button sensibly.
- **The macOS backlog Retry BUTTON is unverified end to end**, and one branch of it is known not to
  draw — §Requests 1. I proved the service reaches the state; the popover's gate is not my file.
- **Two PROCESSES contending on the reservation are still untested**, as e-queue recorded. My cases
  drive the real `flock` from one process.
- **`AppError.from(errorCode:message:)` round-tripping every arming code** is assumed, not measured;
  it is the same call `refreshPendingRetryState` has always made on iOS.
- **I ran no other agent's counterfactual and did not re-run theirs.**

---

## Catalog

**Keys ADDED in source (six). No `.xcstrings` file was opened — the serial copy agent splices these.**

```
pendingRetry.card.count                  = "%lld recordings waiting"
pendingRetry.card.discard                = "Discard recording"
pendingRetry.card.discard.confirm.title  = "Discard this recording?"
pendingRetry.card.discard.confirm.body   = "This deletes the recording from this device. It can't be recovered."
pendingRetry.card.discard.confirm.action = "Discard"
pendingRetry.card.busy                   = "This recording is already being finished. Try again in a moment."
```

Notes for the splice:
- `pendingRetry.card.count` is referenced from **two** files with the identical default value —
  `Views/Components/PendingRetryCard.swift` (the iOS card) and `MenuBar/DictationService.swift` (the
  macOS backlog state). It is the one key here that wants **plural variations** in the catalog; the
  source carries the `%lld` form only.
- `pendingRetry.card.busy` is likewise referenced from both `ContentView.swift` and
  `MenuBar/DictationService.swift`, same default value. It is §Decisions 5's sixth key, beyond K5's
  five.
- `pendingRetry.card.discard.confirm.body` is a multi-line source literal with a `\` continuation; the
  extracted value is the single sentence above.
- **Reused, not added:** `common.cancel` (the confirmation's cancel), and
  `workboard.capture.retry.voice.message`, `pendingRetry.headline`,
  `pendingRetry.headline.terminal`, `"No saved recording to retry."` — all unchanged.

**Keys made DEAD: NONE.** No string-bearing branch was deleted; every existing key on both surfaces
still has its call site.

---

## Requests

1. **Owner of `MenuBar/DictationPopoverView.swift` — ONE line, and r5a#4's macOS half is not fully
   closed without it.** `hasSavedRetryAudio` (`:1322-1324`) is
   ```swift
   service.lastError?.shouldPreserveForRetry == true
   ```
   It is a PROXY for "are there bytes to retry?", and the store now answers that question directly.
   `DictationService` exposes `private(set) var pendingRetryCount: Int`, refreshed on every finish and
   every preserve, so the line wants to be:
   ```swift
   service.pendingRetryCount > 0
   ```
   Why it matters: after a terminal finish with captures still waiting I settle into
   `.error(…, isRetryable: true)` with `lastError` rebuilt from the NEXT capture's arming code. A
   capture the Shortcuts lane armed carries no code until something fails, so `lastError` is nil,
   `hasSavedRetryAudio` is false, and the popover draws no Retry for a recording that is definitely
   there. I refused to set `lastError` to a plausible-looking error to force the button: a typed error
   mirror that names a failure which did not happen is the class of thing this round exists to remove.
   `service.lastError` has exactly one reader in the whole app (measured:
   `grep -rn 'service\.lastError'` → that line), so the change is safe.
2. **Owner of `Services/InAppAudioRecorder.swift` + `Services/PendingRetryStore.swift` — the last
   `clear(ifCurrentID:)` callers, together or not at all.** `releaseDurableRetry` (`:930-937`) is
   gated on `armedDurableRetryID == id`, this recorder's own arm, so it cannot reach a stranger's
   capture — but it is lease-blind, so it CAN delete a capture the iOS card is mid-retry on (the
   voice sheet and the card are both reachable on one screen). Moving it means adding
   `claimNext`/`release`/`clear(_ claim:)` to `PendingRetryQueueWriting` **and** updating
   `WorkVoiceRecoveryTests.RecordingRetryLane`, which conforms to it — one change, three files, none
   of them mine. e-queue §Requests 2 says the store is ready either way. When it lands, delete
   `"Conduck/Services/InAppAudioRecorder.swift"` from the census allowlist in
   `PendingRetrySurfaceHandoffTests`; the test FAILS until you do, which is the point.
3. **Owner of `Services/PendingRetryStore.swift` — reserve BY ID, ~12 lines, and §Refuted 1 closes.**
   ```swift
   /// Reserve exactly this capture, for the process that ARMED it rather than
   /// selected it. Same lease, same token discipline as `claimNext`; nil when
   /// the capture is not queued or somebody else's reservation is live.
   func claim(id: UUID) async -> PendingRetryClaim?
   ```
   With it, `PendingRetryGuard.arm` can hand back a claim, `ConverseIntent` can hold a real one, and
   two things become true that are not today: the intent's disarm goes through `clear(_ claim:)`, and
   `WorkVoiceCaptureCoordinator.recover`'s durable `.published` write after a successful
   republication actually lands on the Shortcuts lane instead of being refused (see §Refuted 1's
   residual hazard). Without it the intent lane stays on the two superseded id-keyed operations, which
   is why they must not be deleted this wave.
4. **Whoever closes O-17's on-screen half.** `factPendingRetry` now carries the count, but the row's
   sentence still describes one capture. The key I did not mint, because my brief scopes
   `DiagnosticsRunner` to the count line: `diagnostics.voice.pendingRetry.waiting` ≈
   `"%lld recordings are waiting to retry."`, rendered instead of the singular detail when
   `pendingRetryCount > 1`. One `if`, one key.
5. **Nobody undo these** — each is pinned by a case measured red on a counterfactual:
   - Selection is `claimNext`, the release is ONE statement in the caller, and only the path that
     retired the entry returns `true`. Spreading the release back over the early returns is r5a#5.
   - Every terminal clear is followed by a fresh `pendingCount()`, and the macOS `.idle` sits inside
     `guard pendingRetryCount > 0 else`. Returning to `.idle` unconditionally is r5a#4 exactly.
   - The discard goes through `clear(_ claim:)`, never `clear()`, and cancels the deferred notice by
     `PendingRetryGuard.cancelDeferredNotification(for:)` rather than by a rebuilt identifier.
   - The card's count renders only above one, and the confirmation says the recording cannot be
     recovered.
   - `ConverseIntent` hands `recover` the capture it ARMED (`Self.heldCapture`) and calls no
     selection primitive. §Refuted 1 is why.
   - The census is an EXACT set in both directions. Turning it into a subset check lets the allowlist
     outlive its reasons.

---

## Refuted

### 1. "ConverseIntent: move the disarms to the claim API." REFUTED — the code makes it impossible, and it would be wrong if it were possible.

The brief's design direction, and I did not implement it. Two independent reasons, both checkable in
the tree as it stands.

**(a) There is no operation that reserves a KNOWN capture.** The store offers exactly one selection
primitive, `claimNext(surface:)`, and it answers "the newest capture nobody has reserved"
(`PendingRetryStore.swift`, the `for metadata in entries` scan). `ConverseIntent` does not select a
capture: it mints `captureID`, writes the entry through `PendingRetryGuard.arm`, and addresses that
entry by that id for the rest of `perform()`. Whenever anything armed after it — the in-app recorder,
a second Shortcut host — `claimNext` returns somebody ELSE's capture, and an intent that took it would
put a ten-minute hold on a recording it is never going to finish, and read that recording's bytes into
the most memory-constrained process in the app to do it. Reserving by id would fix this in about
twelve lines, in a file I do not own: §Requests 3.

**(b) A reservation held by an intent process outlives the OS kill this guard exists for.** The lease
is ten minutes (`PendingRetryStore.claimLeaseDuration = 600`). `PendingRetryGuard.arm` schedules the
"Recording Saved / Tap to retry your transcription" notification at
`deferredNotificationDelay = 90` seconds. So an intent killed mid-flight while holding a reservation
would tell the user at 90 s to open the app and retry, and `claimNext` would refuse them their own
recording for another 510 s — the card up, the button doing nothing. That is strictly worse than
today, on the exact failure this whole lane was built for.

**What I did instead.** `recover` now takes a claim (e-recover landed it mid-wave), so `ConverseIntent`
hands it `Self.heldCapture(_:audio:)` — the same record and bytes it always passed, in the claim's
shape, with a token that names no reservation. The consequences are written at the declaration:
nothing else can be handed this capture by mistake, and every write `recover` attempts against the
entry is refused by the store's token check. This lane writes its own verdict either side of the call
through `recordRecoveryState`, exactly as it did before reservations existed, and
`HeadlessRetryGuardSpanTests` now pins that (`testTheIntentHandsTheRecoveryTheCaptureItArmedRatherThanOneItSelected`,
measured red when the lane selects instead).

**The residual hazard, stated rather than hidden.** e-recover's `recover` writes `.published` to the
entry the moment a republication lands, so that a later retry cannot read a stale `.phaseOneFailed` as
licence to resurrect a card the person deleted. On this lane that write is refused, so the entry keeps
`.phaseOneFailed`. It is reachable only when phase one failed AND `recover` then threw AND the process
survived to run its catch — and even there `ConverseIntent`'s own catch would overwrite the verdict
with its stale in-memory `workPublicationState`, so a real claim alone would not close it either.
§Requests 3 is the fix for both halves.

Both `.phaseOneFailed`-gated disarms are **byte-identical** to `f794856`, as the brief required
(`if workPublicationState != .phaseOneFailed` in the `.notConfigured` arm;
`if !transcriptCaptured, workPublicationState != .phaseOneFailed` in the catch chain), and
`HeadlessRetryGuardSpanTests` still measures exactly three disarms in the documented order — 12/0.

### 2. "WorkboardVoiceCaptureView selects via claimNext." REFUTED — that surface does not read the queue.

Traced: the sheet's Try Again calls `recorder.retryWorkCapture()`
(`WorkboardVoiceCaptureView.swift:209`), which finishes `InAppAudioRecorder.pendingWorkCapture` — an
IN-MEMORY value this recorder is holding — and releases the entry through
`InAppAudioRecorder.releaseDurableRetry` (`:930-937`), gated on `armedDurableRetryID == id`. There is
no queue read anywhere on that path, so there is nothing for `claimNext` to replace, and the file
draws no store call at all. e-queue's §Refuted already qualified r5a#5 the same way.

Moving it means changing `PendingRetryQueueWriting` and the `RecordingRetryLane` double in
`WorkVoiceRecoveryTests` — both outside my ownership, both named in §Requests 2. The file is
unchanged for d-retry §Decisions 5's reason as well: widening its Try Again gate would put a retry on
`.noSpeechDetected`, where it cannot work.

### 3. Nothing else. r5a#4, r5a#5, r5a#8/O-16 and O-17 were all traced against the current tree by call path before any code changed, and all four hold exactly at the anchors quoted in §Findings.

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven and e-queue's six, which all still apply.

1. **The backlog, on iPhone.** Park TWO recordings (airplane mode; record a Chat voice note, let it
   fail; record a second). Open the app: the card must say **"2 recordings waiting"**. Turn the
   network back on and tap Retry ONCE. Exactly one must go through, and the card must still be there
   with the count gone (one left) rather than disappearing or reading as a failure. Tap Retry again:
   the second goes, the card disappears.
2. **The backlog, on Mac.** Same two recordings, from the menu bar. After the first Retry succeeds the
   popover must NOT go quiet — it must say how many are left and still offer Retry. *If the Retry
   button is missing while the sentence says one is waiting, that is §Requests 1 and not a new bug —
   tell me and it is a one-line fix.*
3. **Discard, and that it takes exactly one.** With two waiting, tap **Discard recording** on the
   card. Confirm the dialog says the recording is deleted from this device and cannot be recovered.
   After confirming: the count must drop by one, the OTHER recording must still be retryable and must
   still produce the right words, and no "Recording Saved" notification may arrive later for the one
   you discarded. **Cancel** on that dialog must change nothing at all.
4. **Discard the last one.** With one waiting, discard it: the card must disappear, and Settings →
   Diagnostics must report no parked recording.
5. **Two surfaces, one recording (Mac).** With one capture waiting, open the menu bar's Retry and the
   main window's retry and press both. One must do the work; the other must say **"This recording is
   already being finished. Try again in a moment."** — never produce a second card or a duplicate
   transcript.
6. **The exempt Work capture, end to end (O-16's actual case).** Airplane mode, Action Button with
   Destination = Work, speak. The desk write fails, the recording parks and never expires. Confirm it
   is still there after ten minutes (it must be), then discard it from the card and confirm it is
   gone for good.
7. **Diagnostics counts them.** With two waiting, Settings → Diagnostics → the "Recording waiting to
   retry" row, then **Copy report**: the report line must read `parked(code …, …m left, 2 waiting)`.
   The row's own sentence still speaks about one — that is §Requests 4, not a bug.
8. **VoiceOver over the card.** The Discard button must announce as "Discard recording", and the count
   line must be read. The card is the one place a destructive action sits beside a Retry.

---

## Settled facts — one sentence each, for whoever writes the docs

- The retry card speaks for every recording that is waiting, not just the newest: it says how many
  there are, and finishing one leaves it standing for the next instead of disappearing.
- A retry surface reserves the recording it is working on, so the menu bar, the app and a Shortcut can
  be open at once without two of them transcribing or finishing the same one.
- A retry that fails hands the recording straight back, so the next attempt can take it immediately
  rather than waiting out the reservation.
- The menu bar returns to its idle state only when nothing is left to retry; with recordings still
  waiting it says how many and keeps offering the next one.
- A person can discard one waiting recording from the card, with a confirmation that says it is
  deleted from this device and cannot be recovered — which is the only way to be rid of a Work
  recording the desk never accepted, because nothing expires those.
- Discarding one recording cancels only that recording's "Recording Saved" notice and leaves every
  other waiting recording untouched.
- The Diagnostics report says how many recordings are waiting alongside what it already said about the
  newest one.
- The Shortcuts lane finishes the recording it made rather than picking one out of the queue, because
  a hold taken by a background capture would outlive the kill it is protecting against.
