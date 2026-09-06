# fix-r4-watch-work-destination — Codex round 4 on the Watch Work destination

Source: the round-4 verification (8 findings). This lane owns W-R4-1/2/3/5/6 outright and
W-R4-4's phone half (`AppleSpeechRelayCoordinator` is a `*Relay*` file in
`Conduck/Conduck/Services`); W-R4-7 (`handoff.md`) and W-R4-8 (`README.md`) belong to the docs
lane. Design: `docs/qa/work-usability/design/watch-work-destination.md`.
Rounds 1–3: `fix-r{1,2,3}-watch-work-destination.md` — every "Nobody undo" list still binds;
nothing in them is reversed here.

| ID | Verdict |
|---|---|
| W-R4-1 (P1) | **NOT FIXED — remedy rejected on merit, third time.** Mechanism real; the prescribed park-and-ask is worse than the degradation. Made OBSERVABLE instead (below) |
| W-R4-2 (P1) | **FIXED** — a deferred dispatch owns the machine across its unminted window, without owning its mint |
| W-R4-3 (P1) | **FIXED** — a receipt that contradicts the entry's destination is refused, not resolved by sending |
| W-R4-4 (P2) | **FIXED** — the iPhone now parks the capture the wrist's receipt sends the person to it for, exactly as CarPlay's Work lane does |
| W-R4-5 (P2) | **FIXED** — the recovery is offered on the error the person is reading, not one screen later |
| W-R4-6 (P2) | **FIXED** — four negative controls, each red with its own fix removed and green with every other |
| W-R4-7 (P3) | **OUT OF SCOPE** — `handoff.md` (docs lane). One item ADDED for it, below |
| W-R4-8 (P3) | **OUT OF SCOPE** — `README.md` (docs lane) |

Files touched: `Conduck/ConduckWatch Watch App/Services/{WatchRecordingService,AppleRelayPendingQueue}.swift`,
`.../Views/WatchWorkCaptureView.swift`, `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift`,
`Conduck/ConduckWatchTests/{WatchCaptureGuardTests,WatchRelayQueueRetryabilityTests,ConduckWatchSmokeTests}.swift`,
`Conduck/ConduckTests/WatchWorkRelayRecoveryTests.swift` (new), `Conduck/ConduckTests/ErrorSurfaceDriftGuardTests.swift`
(one registry row the new control's own guard demands).
**No catalog rows, no wire changes, no copy changes.**

---

## W-R4-2 — an older reply released the machine under a live deferred hop · **FIXED**

Real, and the sharpest of the three: it costs a recording the person is in the middle of
making. `startDeferredConverseHop` occupies the machine SYNCHRONOUSLY (`.waiting`) but does
not mint until several awaits later, and it cleared `captureRequestID` on the way in — so for
that whole window the machine reads to `liveTurnOwns` as a RESTORED wait, whose reply the
takeover exists for. An older Chat reply landing there ran `clearInFlight` → `.idle`; a Work
capture started on that idle machine; the hop resumed and wrote `.waiting` over a live
recording; `stopRecording()` then refused to save it (`guard state == .recording`) and the
audio reached nothing at all.

**Fix.** The hop mints a request id OF ITS OWN before its first suspension and holds
`captureRequestID` with it, so `liveTurnOwns` answers false for anybody else's completion
across the window — the same answer it already gives a live capture that has not minted. Two
small things keep that from costing anything:

- `deferredHopRequestID` records which id is the hop's, and `recordMint` skips its stamp when
  the holder is that one. The mint stays adoptable by NO draft, which is the property
  `WatchDraftMintTests` has always asserted and still does.
- `captureRequestID` has a `didSet` that drops the deferred token whenever the request id is
  replaced. The pair cannot drift, and no clear site has to remember it.

Pinned by `testAnOlderChatReplyCannotReleaseTheMachineUnderADeferredDispatch`, which drives
the real hop and refuses `.idle` in its unminted window.

## W-R4-3 — a Work receipt on a chat-stamped entry still reached a gateway · **FIXED**

Real, and narrow: it needs the entry's destination to be missing or unrecognised (both read as
`.chat` by `Entry.captureDestination`) while the reply carries `result.work == true`, which the
iPhone writes from ONE line — `workSaved = workCardID != nil` — and therefore only for a
capture it published to the desk. The two readings cannot both be true, and `settlement`
resolved the disagreement by taking the arm that SENDS.

**Fix, in the shape the finding asked for: reject, do not reconcile.** A fifth settlement
case, `.receiptContradictsDestination`, returned for `.chat` + stamp; `applySettledSuccess`
answers `.destinationContradicted` BEFORE the claim, so nothing is consumed and the recording
stays exactly where it is. Both settlement paths render it as what it is: the queue logs
`queue.settle.destinationMismatch` and shows nothing (there is no true sentence — "saved to
Work" and "sent" each assert one half of the disagreement), and the live leg logs
`stt.relay.destinationMismatch` and reuses the DEFERRAL sentence it already has, which is the
one line that describes the state truthfully (nothing delivered, entry still queued).

Ordinary chat coverage is preserved by the stamp's absence, which is what a real chat reply
carries: `testAChatReplyStillClaimsAndDispatchesTheHop` now sends `workSaved: false` and still
dispatches. The refusal is pinned by `testAWorkReceiptOnAChatStampedEntryIsRefusedRatherThanSent`.

## W-R4-4 — the receipt promised an iPhone action that did not exist · **FIXED**

Real, and the code's own comment said so: "the sentence sends them to the one surface that can
add them". It could not. The wrist deletes its only queued copy on reading the
acknowledgement, and nothing on the phone held that capture afterwards.

**The remedy is the one the neighbouring lane already uses, not new wording.** CarPlay speaks
the IDENTICAL sentence for the identical state and it is TRUE there, because
`CarPlayRecordingService.secureWorkNote` arms a `.work` `PendingRetryStore` record before
speech runs at all — so the phone's retry card can finish the capture. This lane now parks the
same record, at the one moment it is owed: immediately before
`shipWorkRecordingAcknowledgement` on the settled-speech-failure path.

- The record's id is the DESK CARD's id, and `publicationState: .published` rides with it, so
  `ContentView.attemptPendingRetry` → `finishWorkRetry` ATTACHES the recovered words to the
  card already on the desk instead of resurrecting a second recording beside it.
- The clip is read once, for the phase-1 publication, and held for the request (~50 KB by
  wrist-side policy) — by the acknowledgement both transcribe arms and this scope's `defer`
  have deleted the file.
- Armed for EVERY settled verdict rather than the subset a user action can fix, matching
  CarPlay, because the receipt cannot say which kind it was and a capture that could have been
  rescued and was not costs the person their words.
- `PendingRetryMetadata.publishedWorkRetryTTL` (24 h) already exists for exactly this shape —
  a second copy of a recording that is already a card — so the queue stays bounded.

Best-effort and silent: the recording is on the desk either way, so a failed save changes
nothing the reply may claim. Pinned by `WatchWorkRelayRecoveryTests`, including the CALL SITE
(structural — driving `processRelayRequest` needs a paired session and a live provider).

**Deliberately NOT done: rewriting the sentence.** It is CarPlay's too, the wording lives in
two catalogs this lane does not own, and with the record parked it is now true on both surfaces.

## W-R4-5 — Done showed one failure twice · **FIXED**

Real for the retryable half (the microphone-denial half was closed in round 3). With audio
still on the wrist, Done skipped `dismissError()` — correctly, because that call DELETES the
preserved capture — cleared the outcome and popped, and the launchpad presented the identical
sentence with a better button.

**Fix, as prescribed: the offer moves to where the failure is read.** The end-of-capture button
is now one value — `MessageAction` — decided by the launchpad's own rule: `canRetry` picks Try
Again (stay on the screen, `retry()` re-runs the preserved capture through the same Work relay,
which this screen already renders) and Done otherwise. `perform(_:on:)` holds the service calls
so the button's real effect is reachable from a test, and `buttonLabel(showingRecorderError:
canRetry:)` reads the gate at the label site — which is also what `ErrorSurfaceDriftGuardTests`
requires of every Retry control, and where its new registry row points.

The file's rule 3 ("no retry affordance") is unchanged and now says which surface it governs:
the TERMINAL LINE, whose every outcome is already durable somewhere. A recorder error is not
one of those.

## W-R4-6 — helpers pinned, call sites not · **FIXED**

Four controls, one per unpinned site Codex named:

| Site | Control |
|---|---|
| The Done button's state change | `testTheDeadEndFailureIsActuallyEndedAndTheRetryableOneIsKept` drives `perform` against a real service |
| The queue → deferred-hop binding handoff | `testTheSettlementHandsTheDeferredHopWhicheverBindingTheEntryCarries`, through the new `deferredChatDispatch` seam |
| The phone's attachment-failure orchestration | `testTheRetryableAttachmentLeavesBeforeTheSuccessVerdictIsCached` (structural, the pattern this file already uses for isolation) |
| The `.work` lane guard in `handleBackgroundFailure` | `testAnUnmatchableFailureCannotReleaseALiveWorkSave` — a nil `conversationID` skips the ownership guard by design, so it is the only fixture the lane guard alone answers |

The seam is the one production addition: the defect at that call site is a DROPPED ARGUMENT,
and no pure helper can catch one — a helper that computes the binding is still passed, or not
passed, at the call. `liveDeferredChatDispatch` is the only production value.

## W-R4-1 — a legacy unbound entry drains against the current default · **NOT FIXED**

The mechanism is real and unchanged since round 3. The remedy is still rejected, and the
reasons are worth stating once more because this is its third appearance:

- **Parking cannot separate the two populations.** An entry with neither a pin nor a ref is
  either a chooser pick (default may be wrong) or a HEADLESS capture (default is exactly
  right), and nothing on the entry, or readable by this build, tells them apart. Parking
  punishes the second; delivering punishes the first.
- **The cost is asymmetric the other way.** Delivering puts the person's words in a visible
  thread, possibly at the wrong gateway. Parking delivers nothing, re-presents nothing, and
  ends at the 24 h chat cap with "A queued recording couldn't reach your iPhone and has
  expired." — which is not what happened.
- **The population is bounded and self-closing.** Only chat entries written by the previous
  build within 24 h of the upgrade and still undelivered can be in it; every entry this build
  writes carries a pin or a ref.
- **"Require an explicit gateway choice" is a new wrist surface** — a row, a state and copy —
  for a case that expires in a day.

What DID change: the guess is no longer invisible. `queue.complete` now carries the binding
SHAPE (`bound` / `addressed` — booleans, never the values), so the one combination that is a
deliberate degradation can be counted in the field instead of inferred.

## W-R4-7 / W-R4-8 — docs lane

Both stand as Codex describes them; neither file is this lane's. One item to ADD to the
`handoff.md` correction list while it is open: the Work capture screen's recorder error now
carries **Try Again** (preserved audio) or **Done** (nothing to retry) rather than Done alone,
and the retryable case no longer returns to the launchpad to be read a second time.

## Measured

| Run | Result |
|---|---|
| `xcodebuild test -scheme ConduckWatchTests` (watchOS sim `28AC563B…`) | **Executed 302 tests, 0 failures**, exit 0 (baseline 297 + 5) |
| `xcodebuild test -scheme Conduck` (iOS sim `04DEF…`), the ten Work/relay/retry/drift suites | **143 tests, 0 failures** |
| `add-spdx-headers.sh --check` · `check-folder-map.sh` · `check-spec-cites.sh` · `check-spec-size.sh` · `check-storage-seam.sh` · `git diff --check` | exit 0 each |

No new compiler warning in any file this round touched.

**Mutation runs — every fix has a test that goes red without it.** Watch pass: four source
mutations at once (the deferred hop's ownership token reverted to `captureRequestID = nil`;
the contradiction arm reverted to `.converseHop`; `entry.backendRef` dropped at the handover;
`dismissError()` deleted from the dead-end Done) failed exactly four cases and no others —
`testAnOlderChatReplyCannotReleaseTheMachineUnderADeferredDispatch`,
`testAWorkReceiptOnAChatStampedEntryIsRefusedRatherThanSent`,
`testTheSettlementHandsTheDeferredHopWhicheverBindingTheEntryCarries`,
`testTheDeadEndFailureIsActuallyEndedAndTheRetryableOneIsKept`. iOS pass: the retryable arm's
`return` deleted and the `preserveRelayedWorkWords` call deleted failed exactly
`testTheRetryableAttachmentLeavesBeforeTheSuccessVerdictIsCached` and
`testTheSettledAcknowledgementParksTheCaptureBeforeItShips`. All four sources restored from
byte-compared copies afterwards (`shasum` verified), and both string catalogs verified
unchanged by `shasum` across every build.

Two iOS runs lost a test to `Restarting after unexpected exit, crash, or test timeout` — a
different test each time, both green when re-run alone and in a smaller set. Environmental
(sibling agents driving the same simulator and the same process-global App-Group container),
not a product signal.

No `-configuration` flag; caches under `~/Library/Caches/gigaduck-builds/watch-fix{,-ios}`,
both cleaned with `clean-build-cache.sh`.

## Catalog requests

**None.** No string was added, changed or retired: the new button reuses the launchpad's own
`Try Again` literal, which is already a row in the watch catalog. The requests carried forward
from W-R2-7 still stand exactly as `fix-r2-watch-work-destination.md` lists them.

## Nobody undo (this round)

- **A deferred dispatch OWNS the machine from its first line.** `startDeferredConverseHop`
  writes `deferredHopRequestID` and `captureRequestID` together, before any await. Restoring
  `captureRequestID = nil` there re-opens W-R4-2 exactly: the machine goes idle under a live
  hop, a Work capture starts on it, and the hop's resumed `.waiting` strands that recording.
- **The deferred token is a FLAVOUR of the request id, not a second owner.** The `didSet` on
  `captureRequestID` is what keeps them from drifting; `recordMint` compares them so the
  deferred mint stays adoptable by no draft. Do not split the pair, and do not "simplify"
  `recordMint` back to a nil test.
- **The stamp is a second witness, consulted only to REFUSE.** `.receiptContradictsDestination`
  must stay a refusal that happens BEFORE the claim. Making it "decide" — either way — is how
  a private thought reaches a gateway, or a chat ask lands on the desk.
- **The settled acknowledgement parks the capture before it ships.** That reply is cached and
  the wrist deletes its clip on reading it, so the parking has to happen on this side of the
  door. Removing it makes the wrist's receipt — and CarPlay's identical one — a lie again.
- **`Try Again` on the Work error surface must not dismiss.** `dismissError()` deletes the
  preserved capture; the whole point of the arm is that the recording survives the offer.
- **`buttonLabel` reads `canRetry` itself.** Not decoration: `ErrorSurfaceDriftGuardTests`
  requires the declaration that draws a Retry control to name the gate, and a label computed
  one call away from the gate is how a button ends up saying Try Again over a dismiss.
- **`deferredChatDispatch`'s only production value is `liveDeferredChatDispatch`.** The seam
  exists to observe a dropped argument. A second production caller makes it a router, which is
  a different thing with different rules.
