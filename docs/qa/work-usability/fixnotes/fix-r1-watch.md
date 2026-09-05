# fix-r1-watch — Codex R1 findings on the Watch → Work slice

Slice `watch` (c1/c2/c3 wrist half). Three findings, all VERIFIED against the
source and all FIXED. One root cause behind S1 and S2: failure handling on the
wrist was destination-blind, so a Work capture — whose queued audio is the ONLY
copy in existence until the iPhone acknowledges it — was claimed (and therefore
DELETED) on exactly the verdicts the phone half sends expecting it to be kept.

## S1 — live publication failures delete the only recording — **fixed**

**Verified, not refutable.** The phone's phase-1 refusal is
`AppleSpeechRelayCoordinator.workPublicationFailure = .workDeskWriteFailed`
(code 78), retryable *by construction*, and its own doc comment says the wrist
"leaves the entry queued … and keeps the only copy" by way of
`AppleRelayPendingQueue.leavesEntryQueued`. But the LIVE continuation never asks
that predicate: `runRelay`'s catch recognised `.sttProviderUnreachable` and
`.sttKeyUnreadable` by name and fell through to a generic arm that claims. The
phone's own `defer` deletes its temp audio on that path, so after the claim the
recording existed nowhere.

**What changed** — `ConduckWatch Watch App/Services/WatchRecordingService.swift`:
`runRelay(audioFileURL:originalFileURL:providerID:destination:)`'s catch opens
with a Work arm that logs `stt.relay.work.requeued`, calls
`finishWorkCapture(.deferredToPhone)` and returns. Nothing below it runs for
Work, so no failed attempt can reach a claim. Chat's arms are untouched and in
their original order.

Deliberately NOT routed through `surfaceRelayVerdict(_:destination:deferred:)`
even though its `.work` arm is the identical call: `STTKeyBlackoutLaneTests`
(iOS, not mine to edit) counts exactly two `deferred: true` literals inside
`runRelay` — the timeout and the blackout. Calling `finishWorkCapture` directly
keeps that count at two and the blackout arm ahead of `stt.prep.failed`, both
verified green.

**Test:** `WatchRelayQueueRetryabilityTests.testAFailedWorkRelayKeepsTheRecordingAndShowsTheDeferralLine`
— drives the real `runRelay` through the `relayTranscribe` seam against the real
queue for `.workDeskWriteFailed` (retryable) AND `.appleSpeechModelNotInstalled`
(terminal): the entry is still peekable, its audio file still exists, depth is
`baseline + 1`, the outcome is `.deferredToPhone`, the machine is `.idle`.
Negative control `testAFailedChatRelayStillClaimsItsEntry` proves the same drive
still claims for chat and lands `.error`.

## S2 — terminal replies from older phones destroy Work captures — **fixed**

**Verified.** `reconcile` and `drain` both decided through
`leavesEntryQueued(after:)` alone, which reads `AppError.isRetryable` and knows
nothing about destination; the claim in each terminal arm deletes the entry and
its audio. An iPhone predating Work has no Work branch at all (it publishes
nothing and deletes its own temp file), so its terminal code 18 took the wrist's
last copy with it.

**What changed** — `ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift`:

- `leavesEntryQueued(after:destination:)` — the SAME function, now with
  `destination: WatchCaptureDestination = .chat`. `.work` retains after any
  failure; `.chat` returns the taxonomy's answer, byte-identically. The default
  argument is what keeps every existing chat call (and every existing chat
  assertion) spelled exactly as before.
- New `sameBytesCanStillSucceed(after:)` holds the `isRetryable` reading, so
  retention and the DRAIN'S HALT are two questions again. That split is
  load-bearing: a retryable verdict is the iPhone saying it can serve no relay
  right now (stop the drain — entries behind buy the same answer), while a Work
  entry retained on a *terminal* verdict says nothing about the entries behind
  it, and stopping there would wedge them **permanently**, since Work is exempt
  from both caps. `drain` therefore `continue`s on that case and still `return`s
  on the retryable one.
- `reconcile` peeks the entry (`peekEntry`) for its persisted destination before
  deciding — claiming is the only other way to see an entry, and by then the
  audio is gone.

**Nobody-undo compliance.** c2's "Nobody needs to add a `leavesEntryQueued(after:`
call site: the source guard counts exactly two" is respected literally: the
predicate gained a parameter rather than an overload, both dispatch sites still
spell it `leavesEntryQueued(after: error, destination: …)`, and
`testBothDispatchPathsClassifyThroughThePredicate` is **byte-for-byte unchanged
and green** (still exactly 2, still no `case .sttProviderUnreachable`). Every
other c2/c3 "Nobody undo" entry is untouched: the wire stamp is `.work`-only,
`result.work` absent still reads false, write-then-claim ordering is unchanged,
`completeEntry` was not restructured, no new `WatchRecordingState` case, the
namespace is frozen, `retireSupersededRelay` stays chat-only for the discard
counter, and the capture screen still has no Retry.

**Tests:** `testAnUnacknowledgedWorkEntryIsRetainedAfterEveryFailedAttempt`
(five verdicts across both sides of the taxonomy, each asserted for `.work` AND
re-asserted for `.chat` against `error.isRetryable`),
`testAnUnrecognisedThrowStillKeepsAWorkEntry`,
`testOnlyAVerdictAboutThePhoneItselfHaltsTheDrain`, plus two source guards for
the paths that have no runtime seam (`drain`/`reconcile` need an activated
`WCSession` and a paired iPhone): `testBothDispatchPathsAskAboutTheEntrysDestination`
and `testTheDrainStopsOnlyOnAVerdictAboutThePhoneItself`.

## S3 — a late acknowledgement marks a different capture as saved — **fixed**

**Verified.** `noteWorkCaptureSettled(_:)` assigned `workCaptureOutcome`
unconditionally, and the view rendered that shared value; its `requestID` was
log-only. Work entries are exempt from both caps, so several deferred captures
coexist by design and the one that settles is routinely not the one on screen.

**What changed** — both halves of the correlation:

- `WatchRecordingService`: new `private(set) var workCaptureID: UUID?` (the route
  nonce the outcome belongs to, stamped at the top of `startWorkCapture` before
  its first exit so refusals carry it too) and `private(set) var
  workRelayRequestID: String?` (the claim token that capture was queued under,
  written in `runRelay` for `.work`). `clearWorkCaptureOutcome()` drops both.
  `noteWorkCaptureSettled(_:requestID:)` applies the settlement only when the
  token names the displayed capture; a mismatch logs `work.settled.elsewhere`
  and returns. The banner is unaffected — `finishWorkEntry` posts it before this
  call, so a sibling still tells the person it landed.
- `AppleRelayPendingQueue.finishWorkEntry` passes `entry.requestID`.
- `WatchWorkCaptureView`: a private `outcome` accessor returns the service's
  outcome only while `workCaptureID == requestID`; `body`, `isCapturing` and
  `announceOutcomeIfNeeded` all read it. `.onChange` still observes the raw
  property (it is the trigger, not the source of truth).

**Tests:** `testALateSettlementForAnotherCaptureLeavesTheDisplayedLineAlone`
(drives a real deferred Work capture, then feeds a foreign token, a nil token
and finally the capture's own token — the line only moves on the last),
`WatchWorkOutcomeOwnershipTests.testASettlementAppliesOnlyToTheCaptureItNames`,
and `testTheCaptureScreenRendersOnlyItsOwnOutcome` (source guard: the SwiftUI
body has no runtime seam; pins the scope check and that exactly two raw reads of
`workCaptureOutcome` remain).

## Catalog rows

**None.** No `.xcstrings` file was opened. The retained-failure line reuses the
existing `watch.work.capture.deferred` ("Saved on your watch. It reaches Work
when your iPhone is nearby."), which is the true sentence for it: the recording
is on the wrist and the next delivery attempt carries it.

## Files changed

| File | Symbols |
|---|---|
| `Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift` | `workCaptureID`, `workRelayRequestID`, `startWorkCapture(requestID:)`, `clearWorkCaptureOutcome()`, `noteWorkCaptureSettled(_:requestID:)`, `runRelay(…)` |
| `Conduck/ConduckWatch Watch App/Services/AppleRelayPendingQueue.swift` | `leavesEntryQueued(after:destination:)`, `sameBytesCanStillSucceed(after:)`, `reconcile(requestID:outcome:)`, `drain()`, `finishWorkEntry(_:settlement:)` |
| `Conduck/ConduckWatch Watch App/Views/WatchWorkCaptureView.swift` | `WatchWorkCaptureView.outcome`, `isCapturing`, `body`, `announceOutcomeIfNeeded()` |
| `Conduck/ConduckWatchTests/WatchRelayQueueRetryabilityTests.swift` | +10 tests (§1c, §1d, two source guards, new `WatchWorkOutcomeOwnershipTests`) |

`AppleSpeechRelayCoordinator.swift` (watch) was NOT opened — no wire change was
needed, and both `Wire` enums stay at their 14 identical literals.
`ConduckWatchSmokeTests.swift` was not touched. No `.xcdatamodeld`, no envelope
schema, no new watch test FILE (so no pbxproj edit).

## Measured

| Run | Result |
|---|---|
| `xcodebuild test -scheme ConduckWatchTests` (watchOS sim `28AC563B…`) | **Executed 262 tests, with 0 failures**, exit 0, `grep -c ': error: '` = **0** (baseline 252 + 10) |
| `xcodebuild build-for-testing -scheme Conduck` (iOS sim `04DEF…`) | exit 0, **0** `: error: ` |
| iOS `STTKeyBlackoutLaneTests` + `RelayWireSourceDriftGuardTests` + `RelayWireContractTests` + `WatchWorkRelayPhoneTests` + `LoggingPrivacyDriftGuardTests` | **36 tests, 0 failures** |
| `scripts/add-spdx-headers.sh --check` | exit 0 |

No `-configuration` flag anywhere; caches under
`~/Library/Caches/gigaduck-builds/fix-watch/`, cleaned with
`clean-build-cache.sh fix-watch`.

## Open items

- **A permanently-old iPhone can park a Work capture forever.** With S2 fixed,
  a terminal verdict on a Work entry retains it, and Work entries never age out;
  the compensating bound stays `refusesNewWorkCapture` (at ten queued Work
  captures the eleventh is refused with "Work is waiting for your iPhone"). That
  is the deliberate trade — a wedged queue is recoverable by updating the phone,
  a deleted recording is not — and it extends c2's existing open question about
  an empty transcript parking an entry. A founder call on ever discarding an
  undeliverable Work capture (an explicit "discard" affordance on the wrist)
  belongs to a later slice; nothing here deletes one silently.
- **`reconcile`/`drain` remain source-guarded rather than runtime-tested.** Both
  need an activated `WCSession`, the singleton's disk-touching `init` and a
  paired iPhone, which is why the file's existing §3 guard exists; the two new
  guards follow that precedent. The live leg (S1) IS driven end to end.

## Founder QA — the two failure paths that now behave

Both need the wrist and the phone on this build.

1. **The phone's desk write fails mid-capture** (hard to force deliberately —
   worth knowing the shape): a Work capture whose phone-side publication is
   refused now ends on "Saved on your watch. It reaches Work when your iPhone is
   nearby.", and the card appears once the retry succeeds. It must NEVER end on
   a failure line with the recording gone.
2. **Two deferred captures, one settles.** Phone off. Record Work capture A,
   tap Done. Record Work capture B and LEAVE its deferred screen open. Bring the
   phone back. *Must be true:* a "Saved to Work." notification arrives for A,
   and B's screen still reads "Saved on your watch…" until B itself lands — then
   it flips. *Failure to report:* B's screen turning green while B's card is not
   yet on the desk.
