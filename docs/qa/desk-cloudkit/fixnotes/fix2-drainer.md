# fix2-drainer — r2#3 + adjudication (e) + t#2. Finding CONFIRMED and fixed; all three measured against counterfactual builds.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` in the worktree untouched.
**No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet touched.
No file outside my ownership list edited in the worktree.

Files I changed, exactly two — both mine:
- `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` (+214 / −87 across both files; this file ~+165)
- `Conduck/ConduckTests/WorkCaptureDrainerDurabilityTests.swift` (5 → 8 cases; one case rewritten in place)

`Conduck/ConduckTests/WorkCaptureDrainerTests.swift` is **unmodified** (`git status` shows it clean) — I added
nothing to it, weakened nothing in it, and all 9 cases still pass.

---

## 1. r2#3 — verified, then fixed

**VERDICT: CONFIRMED.** Re-located by symbol, not by the cited line. At the time of check
`withLeaseHeartbeat(for:_:)`'s loop body was literally `try? await inbox.refreshLease(claim, now: now())`
inside a `Task.detached`, with the comment "A refusal never stops the beat" naming `.staleClaim` explicitly
as a case it swallows. Tracing the call path confirmed every clause of the evidence:

| Claim in the finding | What the code did |
|---|---|
| `staleClaim` is discarded with `try?` | yes — the only `catch` was the `try?` |
| the detached task cannot cancel the body | yes — `defer { heartbeat.cancel() }` cancels the BEAT; the body ran in the drainer's own task and read no shared state |
| `persist` continues through later entries and Core Data saves | yes — the entry loop had no ownership or cancellation check between `upsertDeskMaterial` calls |
| ownership loss is noticed only at `acknowledge`/`release` | yes — and by then `requireLeaseOwnership` has already cleared `activeClaims`, so `release` refuses too and the failure is reported as `.staleClaim` **after** the extra cards were written |

Adjudication (e) is the same defect stated as a clock argument, and I take it as binding: the 60 s / 300 s /
900 s intervals are kept exactly as they are, and ownership loss is made terminal.

**Measured proof of the consequence** (isolated copy, §4 CF1): on the pre-fix behaviour the victim import
wrote **all three** of its materials after another process had taken the capture —
`XCTAssertEqual failed: ("[821AAD8B…, 5EC1BC60…, AD3DAA6E…]") is not equal to (…)`. That is the concurrent
import the finding describes, produced on demand.

Nothing refuted; `## Refuted` is empty.

## 2. The fix

### 2.1 A proven takeover is terminal, and it CANCELS

`withLeaseHeartbeat(for:_:)` is replaced by `importUnderRenewedLease(_:)`, a
`withThrowingTaskGroup` holding two children — the renewal beat and `persistAndAcknowledge(_:ownership:)` —
plus a shared terminal state, `private actor ImportOwnership` (file-scope, `#if !os(watchOS)` like the rest of
the file).

| Path | Behaviour |
|---|---|
| `refreshLease` throws `.staleClaim` | `ownership.recordLostClaim()`, beat returns. The group loop sees a stopped beat with a lost claim, calls `group.cancelAll()`, **awaits the import's unwind**, and throws `.staleClaim` |
| `refreshLease` throws anything else | swallowed, beat continues (`.filesystemFailure` is the only other case the inbox raises) |
| import returns a capture | `group.cancelAll()`, value returned; the group awaits the beat, so no renewal can outlive the drain |
| import throws | `group.next()` rethrows it unchanged — the original diagnosis is preserved |

**Why a task group rather than a flag plus a detached task.** Cancellation is the only thing that can
interrupt an import parked inside a store call, and only a structured child can be cancelled by its sibling's
outcome *and* by the caller's own cancellation. It also closes the reverse leak the finding does not name: a
detached beat outlives its `defer` by however long its in-flight `refreshLease` takes, whereas
`withThrowingTaskGroup` cannot return until the beat has ended. That property is now asserted
(`testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat`).

### 2.2 The checkpoints

`requireImportMayContinue(_:atMaterialBoundary:)` throws `.staleClaim` when the claim is proven lost, then
`try Task.checkCancellation()`. It runs:

- **before every material write** in `persist` — before the share note, and at the top of every entry
  iteration (the boundary is `materialIDs.count`, so it is a real write boundary, not a loop index);
- **before the durability barrier**, after the existing post-persist hold;
- and `drainAvailableCaptures` now checks cancellation before claiming the *next* capture, so a cancelled
  drain does not take a claim it could only give back.

### 2.3 A terminated import releases nothing and acknowledges nothing

`ImportOwnership.endImport() -> Bool` marks the import over and reports whether it still owns the claim.

- success path: `guard await ownership.endImport() else { throw .staleClaim }` **before** `acknowledge`;
- failure path: `if await ownership.endImport() { try? await inbox.release(claim) }` — a claim proven lost is
  never requeued, because requeueing a directory another acquisition holds hands away bytes it is reading.

`endImport()` also makes the terminal decision race-free at the *end* of an import: `recordLostClaim()` is
ignored once the import has ended, so the marker this drainer's own `acknowledge` just deleted can never be
read back by a late beat as somebody else's takeover and turn a successful drain into a thrown `.staleClaim`.
(Defence in depth only — `acknowledge` and `release` verify ownership inside the inbox as well.)

### 2.4 What I did NOT change

- The three intervals: `defaultLeaseHeartbeatInterval` 60 s, `staleClaimHorizon` 300 s, vault grace 900 s.
  Adjudication (e) says to retain them once loss is terminal.
- `drainAvailableCaptures()`'s signature, `Report`'s four fields, the two defaulted `init` parameters
  (fix-verify standing constraint 5), `confirmDurablyImported`'s one-fetch shape (constraint 4), and the
  position of `acknowledge` as the last statement of the import (constraint 4).
- `WorkCaptureInbox.swift` — not opened for editing. `refreshLease(_:now:)` needed no change; see `## Requests`.

## 3. The one new test seam

`#if CONDUCK_TESTING` `materialWriteHoldForTesting: (@Sendable (Int) async -> Void)?` +
`_setMaterialWriteHoldForTesting(_:)`, awaited by `requireImportMayContinue` at each material boundary, nil on
every production path, with a "WHY IT HAS TO EXIST" header in the existing precedent's shape.

It exists because **the interval the lease is for is inside `persist`** — t#2's finding. The pre-existing
`importHoldForTesting` fires *after* `persist`, i.e. after every byte of the capture is already stored, so it
cannot stage a takeover racing a slow byte import, and cannot stage cancellation reaching an import
mid-write. The argument is the number of materials already written, so a test parks at exactly one boundary
and nothing wider is exposed. The older hold is kept: the two barrier cases need the post-persist window.

## 4. Counterfactuals — MEASURED, in an isolated copy

The tree was copied to `~/Library/Caches/gigaduck-builds/fix2-drainer/tree` (the foreign, mid-edit
`WorkboardAudioCaptureTests.swift` parked there so the copy compiled; the copy's `Identity-Override.xcconfig`
symlink re-pointed at the same real file so the relative path still resolved). **Nothing in the worktree was
touched for this.** Three variants, each a one-file change to the copy's drainer, each rebuilt and run:

| Variant | What it restores | Result on my 8 cases |
|---|---|---|
| **CF1** — pre-fix behaviour: beat swallows every refusal, no boundary/barrier gates, no cancellation check, ungated `acknowledge`/`release` | exactly the code r2#3 describes | `Executed 8 tests, with 6 failures (0 unexpected)` — **`testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite`** and **`testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat`** fail; the other 6 pass |
| **CF2** — the beat renews nothing at all | a drainer with no lease heartbeat | `Executed 8 tests, with 10 failures (1 unexpected)` — **`testTheHeartbeatKeepsASlowByteImportOwnedPastTheStaleHorizon`** fails (`The claim's lease was never renewed while its import was still running`; `respectedLeaseCount 0 ≠ 1`; `releasedClaimCount 1 ≠ 0`; the second inbox's `claimNext` returns a Claim instead of nil) |
| **CF3** — every refusal ends the beat and the import | the over-correction the task warns against | `Executed 8 tests, with 3 failures (1 unexpected)` — **`testATransientRenewalFailureDoesNotStopTheImport`** fails (`the heartbeat stopped attempting renewals after a write failure`; `caught error: "staleClaim"`) |

CF1's failure lines for the two terminal cases, verbatim:

```
testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite] : XCTAssertTrue failed - a proven takeover cancels the import rather than being swallowed
testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite] : XCTAssertEqual failed: ("[821AAD8B…, 5EC1BC60…, AD3DAA6E…]") is not equal to (…)
testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat] : failed - A cancelled drain must not report an import it did not finish
testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat] : XCTAssertEqual failed: ("[B177D254…, 5C48DF2E…]") is not equal to (…)
testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat] : XCTAssertEqual failed: ("0") is not equal to ("1") - the capture goes back to the queue
testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat] : XCTAssertEqual failed: ("0") is not equal to ("1") - the card the cancelled import wrote makes the retry a replay
```

So every case is non-vacuous against the mechanism it names, and **no case fails merely because the seam is
absent** — the seam exists in all three variants.

### The 8 cases

| Case | Asserts | Counterfactual that reddens it |
|---|---|---|
| `testAPendingSyncedCardBlocks…` | unchanged (fix-drainer's barrier) | — |
| `testAMissingVaultLeafBlocks…` | unchanged | — |
| `testACaptureWithoutBytesStillAcknowledges` | unchanged | — |
| `testTheHeartbeatKeepsASlowByteImportOwnedPastTheStaleHorizon` | **rewritten for t#2**: the hold now sits INSIDE `persist`, between the note write and the entry whose payload the store still has to copy. Clock past the horizon there → a second inbox reports `respectedLeaseCount 1` / `releasedClaimCount 0`, its `claimNext` is nil, the directory survives; then the owner completes and **the bytes reach the desk** (`loadWorkMaterialPayload == payload`) | CF2 |
| `testTheHeartbeatIntervalLeavesRoomForMissedRenewals` | unchanged (pins 4 × interval < horizon) | — |
| `testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite` | **NEW.** Frozen clock = a suspended app; a second inbox reconciles at `horizon + 5`, requeues, and claims under its own generation. The drain throws `.staleClaim`; the gate records that it was CANCELLED; **the desk holds only the note** (the write in flight never happened); the new owner's claim is the only one in `processing/`, under a different name, with its manifest intact; `pendingCount == 0` — nothing was requeued out from under it | CF1 |
| `testATransientRenewalFailureDoesNotStopTheImport` | **NEW.** Claim directory `chmod 0500` mid-import: the lease stays READABLE (ownership never in doubt) and the renewal fails on its write. ≥3 further attempts are observed, the marker on disk is proved unmoved, the mode is restored, the clock advances, and a renewal lands ≥60 s newer — then the import completes and acknowledges | CF3 |
| `testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat` | **NEW (t#2's cancellation case).** `task.cancel()` mid-import → `CancellationError`, gate saw the cancellation, desk holds only the note, `processing/` empty, `pendingCount == 1`; **renewal-attempt count is unchanged across 300 ms after the drain returns**; and a fresh drainer recovers the capture as a replay | CF1 |

**How "no lease renewal after cancellation" is observed:** the injected `now` closure is read once per renewal
attempt and the drainer reads it nowhere else, so the test's clock counts attempts. A stable count after the
drain returns is a beat that has stopped. (With the task group it cannot be otherwise — the group cannot
return while a child lives — which is precisely the property being pinned against a future rewrite.)

## 5. Gates — WHAT I ACTUALLY RAN

Slug `fix2-drainer`, derivedData `~/Library/Caches/gigaduck-builds/fix2-drainer/{DerivedData,DerivedDataCF}`,
every log written there and grepped for `: error: ` and the verdict strings — never judged from tail or exit
code. No `-configuration` passed anywhere. Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`.

- **iOS `build-for-testing`** → `bft-5.log` (final): `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
  **Zero warnings in either of my files** (`grep -cE "(WorkCaptureDrainer|WorkCaptureDrainerDurabilityTests)\.swift:[0-9]+:[0-9]+: warning:"` = 0).
- **VERIFY set** (`test-2.log`, `** TEST EXECUTE SUCCEEDED **`, total
  `Executed 61 tests, with 0 failures (0 unexpected) in 0.845 (0.868) seconds`):

| Class | Result |
|---|---|
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures (0 unexpected) in 0.557 (0.560) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.091 (0.092) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.057 (0.070) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.140 (0.145) seconds` |

- `git diff --check` → clean, exit **0**. `bash scripts/check-storage-seam.sh` →
  `✓ storage seam intact — 780 Swift files scanned…`, exit **0**.
- **Suite delta: +3 iOS executed** (`WorkCaptureDrainerDurabilityTests` 5 → 8). No assertion anywhere was
  weakened, narrowed or deleted.
- Build caches removed at end of task: `.claude/scripts/clean-build-cache.sh fix2-drainer`. **The logs and the
  isolated copy go with them**; re-run if you need them.

### NOT run, stated plainly

- **macOS build, full iOS suite, watch suite.** My source file is `#if !os(watchOS)` and my test file is
  test-bundle only; neither contains platform-conditional code. But I did not prove the macOS build myself,
  and six other agents were editing the tree throughout, so a full-suite number from me would have been
  mostly theirs.
- I did not run the drift-guard or folder-map scripts (outside my VERIFY).

## 6. Parallel-phase blockage (not mine, recorded per protocol)

Builds 1–3 failed **only in files I do not own**. I waited and retried four times over ~13 minutes rather than
return unverified, and edited nothing to work around either:

```
Conduck/Conduck/Services/InAppAudioRecorder.swift:476,528,570,573,638,640,737,761: error: … (9 errors)
   e.g. cannot find 'failPendingWorkCapture' in scope
        binary operator '??' cannot be applied to operands of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome?' and 'Bool'
Conduck/ConduckTests/WorkboardAudioCaptureTests.swift:124,168,185,206,243,268: error:
        cannot convert value of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome' to expected argument type 'Bool'
```

Both cleared on their own — mid-edit states of the recorder/voice-lane slices adopting contract C1. Every
number in §5 comes from after they cleared. (In the meantime I proved my own files compile and pass in the
isolated copy, which is where the counterfactuals ran.)

---

## Guard verdicts

**None assigned.** The independent reviewer's 25 drift-guard verdicts name no test in either file I own, and
neither file contains a source-text drift guard. Nothing kept-with-reason, nothing converted, nothing deleted.

## Catalog

**Keys I ADDED in source: NONE.** This slice is entirely headless — a heartbeat, a terminal-state actor and
three checkpoints. `WorkCaptureInbox.InboxError.staleClaim` is a pre-existing error case with no user-facing
copy.

**Keys I made DEAD: NONE.** I deleted no code that referenced a key. The five keys this file owns are all
still live and still reachable: `workboard.capture.note` · `workboard.capture.sharedText` ·
`workboard.capture.image` · `workboard.capture.webPage` · `workboard.capture.file`.

**No `.xcstrings` file was opened.**

## Requests

1. **Whoever owns `WorkCaptureInbox.swift` — nothing is owed, but three facts are now load-bearing for me.**
   (a) `refreshLease(_:now:)`'s `.staleClaim` is now a **terminal signal a production caller acts on**, not a
   refusal that gets retried: it must be raised only for a proven loss of ownership (foreign lease, or the
   claim's own generation-scoped directory gone), never for a transient fault. `.filesystemFailure` is the
   right error for anything a retry could fix. (b) Conversely, a transient fault must not be reported as
   `.staleClaim`, or a busy device will abort valid imports. (c) The beat still relies on a refusal being
   cheap and side-effect-free; if `refreshLease` ever gains a destructive failure path, tell me.
2. **Serial integrator — do not tidy away the drainer's structured task group back into a detached task.**
   The group is what makes a takeover able to cancel an import parked inside a store write, and what
   guarantees no renewal outlives the drain. Both are asserted
   (`testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite`,
   `testCancellingADrainMidImportRequeuesTheClaimAndStopsTheHeartbeat`), and both were measured red against a
   detached-style variant.
3. **Nobody remove the checkpoint before a material write, or the `endImport()` gate on `acknowledge`/
   `release`.** Those three lines are the whole of adjudication (e): without them the 60 s / 300 s / 900 s
   clocks describe two owners of the same bytes.
4. **fix-verify's constraints 4 and 5 are intact and still needed** — `confirmDurablyImported` is still one
   fetch consuming `hasPayload`, `acknowledge` is still the last statement, and the two defaulted `init`
   parameters (`leaseHeartbeatInterval`, `now`) are now load-bearing for four cases rather than two. The
   injected `now` is additionally the *only* observation of a renewal ATTEMPT (as opposed to a renewal that
   landed); the transient-failure case reads it.
5. **Orchestrator — expect +3 on the iOS executed count** from this slice
   (`WorkCaptureDrainerDurabilityTests` 5 → 8). `WorkCaptureDrainerTests` stays at 9, `WorkCaptureInboxTests`
   at 30, `WorkCaptureInboxLeaseTests` at 14. Full iOS, watch and macOS unrun by me.
6. **Docs agent — one fact is now settled by code.** A capture is drained by exactly one process: while an
   import runs it keeps restating its claim, and if that claim is ever legitimately taken by another process
   (an app suspended long enough for the queue to declare it abandoned), the first import **stops where it
   is** — it writes no further card, consumes nothing, and puts nothing back. The capture is finished by
   whichever process holds it, once.
7. **Founder QA (Gate 2) — one item, extending fix-drainer's.** Share a large file from another app, then
   background/suspend the app long enough (>5 min) that the capture is reclaimed, and confirm the card appears
   **exactly once** on the desk with its bytes, not twice and not zero times. That is the user-visible shape of
   ownership loss being terminal.

## Refuted

Empty — the finding held in full, and adjudication (e) held with it.

## Call-site touches

**NONE.** `drainAvailableCaptures()` kept its signature and `Report` kept its four fields, so
`WorkboardLiveRepository.drainCaptures()` and `WorkCaptureRetryCoordinator.publish` needed no edit — neither
file was opened. All new parameters are internal to the drainer or defaulted.
