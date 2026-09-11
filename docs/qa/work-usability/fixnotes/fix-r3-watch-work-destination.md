# fix-r3-watch-work-destination — Codex round 3 on the Watch Work destination

Source: the round-3 verification (10 findings). This lane owns W-R3-1/2/3/5/7/8; W-R3-4
(`InAppAudioRecorder`/`AppDelegate`), W-R3-9 (`handoff.md`) and W-R3-10 (`README.md`) belong to
other lanes, and W-R3-6's two prescribed remedies both land outside this lane's files.
Design: `docs/qa/work-usability/design/watch-work-destination.md`.
Rounds 1–2: `fix-r1-watch-work-destination.md`, `fix-r2-watch-work-destination.md` — both
"Nobody undo" lists still bind; nothing in them is reversed here.

| ID | Verdict |
|---|---|
| W-R3-1 (P1) | **FIXED** — ownership, not just the pin, decides a takeover; the dead marker is dropped without touching the live capture |
| W-R3-2 (P1) | **FIXED** — the failure callback got the reply callback's lane guard and the same ownership match |
| W-R3-3 (P1) | **PARTLY FIXED** — a legacy replay no longer lands in the pointer's thread; the lost gateway is unrecoverable and the prescribed remedy is a worse defect (below) |
| W-R3-5 (P2) | **FIXED** — labels are resolved and verified across the COMPLETE roster |
| W-R3-7 (P2) | **FIXED** — the tautological pin assertion is gone and the fixture says why |
| W-R3-8 (P2) | **FIXED** — Done ends the recorder error it just showed, unless there is audio left to retry |
| W-R3-4 (P1) | **OUT OF SCOPE** — Mac lane (`InAppAudioRecorder.swift`) |
| W-R3-6 (P2) | **OUT OF SCOPE, both halves** — `PendingRetryStore` (voice-recovery lane) and the CarPlay + catalog copy mirror |
| W-R3-9 (P3) | **OUT OF SCOPE** — `handoff.md` |
| W-R3-10 (P3) | **OUT OF SCOPE** — `README.md` |

Files touched: `Conduck/ConduckWatch Watch App/Services/WatchRecordingService.swift`,
`.../Views/WatchNoteView.swift`, `.../Views/WatchWorkCaptureView.swift`,
`Conduck/ConduckWatchTests/{WatchCaptureGuardTests,ConduckWatchSmokeTests}.swift`.
**No catalog rows, no wire changes, no phone-side changes.**

---

## W-R3-1 — an old reply stripped a new, unminted Ask of its gateway · **FIXED**

Real, and reachable through two doors rather than one. `handleBackgroundReply` matched the
takeover on `inFlightConversationID`, which is nil for a `.new` draft until the hop mints —
so on the relaunch sequence Codex describes (an older turn's marker persisted, Ask pressed
during the restore fetch, gateway B picked) the older turn's reply passed the guard. The
second door is worse and needed no race at all: the `else` branch above it (state `.arming` /
`.recording`, i.e. the person is still speaking) reached the same destructive clear.

Both halves of the damage were in one call. `clearInFlight(forConversation:)` matches the
persisted marker and then runs the FULL reset — pins, one-shot Ask hint, `captureRequestID`,
`captureSource`. A marker match is not ownership, so an older turn's completion was taking a
newer capture's state down with it: the pick lived only in the hint until the hop consumed it,
so the words resolved through the DEFAULT gateway, and the released `captureRequestID` let a
second capture start on top of a live upload.

**Fix, in the shape the finding asked for.** Two small things beside the existing ones:

- `liveTurnOwns(_:)` — a pin answers exactly; with NO pin, `captureRequestID` separates the
  two very different machines that look alike. Nobody holding it ⇒ a restored wait (the
  wrist dropped, or the process relaunched and `restoreInFlightStateIfNeeded` rebuilt the
  thinking view from the marker alone), whose reply this is. A capture request holding it ⇒ a
  live capture that has minted nothing, so it has no reply and no failure of its own.
- `forgetPersistedInFlight(forConversation:)` — drops the three App-Group marker keys and
  NOTHING else. Every "this completion is somebody else's" branch in both handlers uses it;
  `clearInFlight(forConversation:)` is now reserved for the completion the live machine owns.

Pinned by `testAnOlderChatReplyDoesNotStripANewUnmintedAskOfItsGateway`, which asserts all
three: the machine stays `.uploading`, the hint still names the picked gateway, and the dead
turn's marker is still gone.

## W-R3-2 — an older Chat failure released a live Work save · **FIXED**

Real. `handleBackgroundFailure` had the conversation half of the match and neither the lane
half nor the ownership half: it compared `pendingConversationID` only, so a live Work save
(no pin, ever) and a live unminted Ask (no pin yet) both read an older turn's failure as their
own and went to `.error`.

**Fix:** the same two guards the reply path now carries, in the same order — the `.work` lane
first, then `liveTurnOwns`. The nil-`conversationID` takeover is deliberately KEPT for the
chat lane: it is the only thing that unsticks a wedged `.uploading` machine. It is safe to
refuse it for Work, and that is a fact about the pipeline rather than a hope — Work forces the
iPhone relay (`processRecording`'s `needsiPhoneRelay`), so it reaches neither the
background-STT failure funnel nor `armUploadingWatchdog`, which are the only two callers that
pass nil.

Pinned by `testAnOlderChatFailureDoesNotReleaseALiveWorkSave` (the direct counterpart of
round 2's reply case) and `testAnOlderChatFailureDoesNotReleaseANewUnmintedAsk`.

## W-R3-3 — a legacy queue entry drains against the current default · **PARTLY FIXED**

The mechanism is real and the version skew is real: `main` already ships the Ask chooser
(`WatchNoteView.beginInAppAsk`, 2+ gateways) and already writes the pick to the one-shot hint
only, while its `AppleRelayPendingQueue.Entry` has no `backendRef`. So an entry enqueued by a
shipped build carries neither field, and `completeEntry` passes both nil.

**What was fixed.** Such an entry does tell us one thing for certain: the capture was
ALWAYS-NEW. Every capture that continues a thread pins it (`.existing` sets
`pendingConversationID`, which the entry persists), so an unbound entry is either an Ask
chooser pick or a headless `.new` — both always-new. The resolver's POINTER arm was
re-deciding that minutes later and could append the words to whatever thread the pointer
happens to hold, which is a second wrong answer on top of the gateway one. That arm is now
gated on `consumeAskHint` — the flag that already means "this is a LIVE hop, not a replay"
(`startDeferredConverseHop` is its only false caller) — so a replay mints, as the capture
intended. Pinned by
`testALegacyUnboundDeferredAskMintsInsteadOfContinuingTheActiveThread`.

**What was NOT fixed, and why the prescribed remedy is worse than the defect.** "Retain
unbound legacy entries and require an EXPLICIT destination before dispatch" would strand every
one of them, and on the shipped build the unbound shape is ALSO how a headless capture and a
single-gateway Ask are recorded — the common case, not the rare one. A retained entry is not
quietly parked either: it is never claimed, so every drain re-fires it to the phone for another
(billed, BYO-key) transcription, and it ends at the age cap with the eviction notice "A queued
recording couldn't reach your iPhone and has expired." — which is the opposite of what
happened. Against that, delivering it is exactly the answer the build that created it would
have given: `main`'s own `completeEntry` passes `boundTo: nil` and resolves the same way. The
pick was never written down, and this queue's standing rule is that a choice which cannot be
read back is not one to guess at — so the honest degradation is "a new chat on the default
gateway", not "silently never delivered". Going forward the skew closes by itself: every
entry this build writes carries a pin or a ref, and legacy blobs age out at the chat cap.

## W-R3-5 — three names, two identical labels (again) · **FIXED**

Real. Round 2 resolved the colliding GROUP together, and a name whose short form is not a
truncation never joins a group — so a custom literally named "…alpha" returned early and
collided with the disambiguated label the group produced for "Frankfurt production alpha".

**Fix:** `WatchGatewayLabel.visible` now resolves the WHOLE custom roster (`rosterLabels`) and
hands back this ref's answer. Pass 1 is round 2's earliest-divergence rule, unchanged, applied
to each cut name against the names it collides with. Pass 2 — the fix — runs the uniqueness
check over EVERY label, the untouched short forms included, before handing out bounded
ordinals. Built-ins are not on the custom roster and are returned verbatim, as before; the
shared shortening policy is still untouched.

Pinned by `testAShortNameThatAlreadyReadsLikeADisambiguatedLabelStillGetsItsOwnRow` (Codex's
exact fixture, with both controls: the pair genuinely collapses, and the third name is
genuinely left alone by the shortener).

## W-R3-7 — the original fixture still carried a tautology · **FIXED**

Real: `testAWorkPickAfterAnAbandonedGatewayDraftInheritsNothing` starts from an idle machine,
so its `XCTAssertNil(inFlightConversationID)` began and ended nil and stayed green with
`startWorkCapture`'s pin clears deleted. Taken as prescribed, second option: the assertion is
gone and the case is scoped to what it genuinely owns — the stale hint and the "Work mints
nothing" floor — with a line in its doc comment saying why no pin assertion may come back. The
two dedicated fixtures round 2 corrected are untouched and remain the pin's coverage.

## W-R3-8 — Done dismissed the screen, not the failure · **FIXED**

Real. `messageView` is shared by the terminal line and the recorder error, and its Done
cleared only `workCaptureOutcome` — which is this screen's line, not the service's state. So
`WatchNoteView`'s root error view re-presented the identical sentence the moment the screen
popped.

**Fix:** the error case passes `dismissesRecorderError: true`, and Done calls `dismissError()`
through the pure `WatchWorkCaptureView.doneDismissesRecorderError(showingRecorderError:canRetry:)`.
The `canRetry` half is not decoration: `dismissError()` deletes the preserved capture, so a
failure that still has audio on the wrist (a compression / prepare-for-iPhone failure) keeps
its second showing — where the launchpad's button says **Try Again** rather than the same dead
end. A failure with nothing to retry is read once. Pinned by
`testDoneEndsARecorderErrorUnlessThereIsStillSomethingToRetry` (four-row truth table).

## W-R3-6 — the settled-failure receipt · **OUT OF SCOPE, both halves**

The mechanism is confirmed: `acknowledgesRecording(after:)` is `shouldCacheVerdict(for:)`, so a
settled `.sttMissingAPIKey` ships the wordless acknowledgement and no phone-side retry entry is
created anywhere. Both prescribed remedies land outside this lane:

- **Create a `.work` recovery entry before acknowledging** — `PendingRetryStore` and the Work
  voice-recovery lane own that surface.
- **Change the receipt wording** — one sentence at four code sites, one of them CarPlay's
  (`CarPlayRecordingService.swift:1825`), plus three catalog keys. Round 2 already ruled it a
  cross-lane copy change; nothing about it has moved.

The third option — reclassifying a missing key as retryable — is explicitly rejected rather
than deferred: `acknowledgesRecording` is the cache's admission question on purpose, a Work
entry never ages out, and a permanently missing key would then hold a queue slot for ever and
refuse new Work captures at the cap.

## Measured

| Run | Result |
|---|---|
| `xcodebuild test -scheme ConduckWatchTests` (watchOS sim `28AC563B…`) | **Executed 297 tests, 0 failures**, exit 0, no `: error: ` (baseline 291 + 6) |
| `xcodebuild test -scheme Conduck` (iOS sim `04DEF…`), `ErrorSurfaceDriftGuardTests` + `WatchWorkRelayPhoneTests` + `WorkboardCopyTruthGuardTests` | **36 tests, 0 failures**, exit 0 |
| `add-spdx-headers.sh --check` · `check-folder-map.sh` · `check-spec-cites.sh` · `check-spec-size.sh` · `check-storage-seam.sh` · `git diff --check` | exit 0 each |

No new compiler warning in any file this round touched (the watch build's warning set is
unchanged and lives in files this round did not open).

**Mutation runs — every fix has a test that goes red without it.** Pass A applied five source
mutations at once (`liveTurnOwns` reverted to "no pin ⇒ ours"; the `.work` guard deleted from
`handleBackgroundFailure`; the pointer arm re-opened to replays; the label's untouched-short-form
early return restored; `doneDismissesRecorderError` reduced to `showingRecorderError`) and the
watch run reported failures in exactly the six intended cases:
`testAnOlderChatReplyDoesNotStripANewUnmintedAskOfItsGateway`,
`testAnOlderChatFailureDoesNotReleaseALiveWorkSave`,
`testAnOlderChatFailureDoesNotReleaseANewUnmintedAsk`,
`testALegacyUnboundDeferredAskMintsInsteadOfContinuingTheActiveThread`,
`testAShortNameThatAlreadyReadsLikeADisambiguatedLabelStillGetsItsOwnRow`,
`testDoneEndsARecorderErrorUnlessThereIsStillSomethingToRetry`. Pass B isolates the marker
half on its own — restoring `clearInFlight(forConversation:)` in the reply's refusal branch,
with `liveTurnOwns` intact, fails
`testAnOlderChatReplyDoesNotStripANewUnmintedAskOfItsGateway` alone (1 failure / 297). All
sources restored from byte-compared copies afterwards (`shasum` verified).

No `-configuration` flag; caches under `~/Library/Caches/gigaduck-builds/watch-fix{,-ios}`,
both cleaned with `clean-build-cache.sh`.

## Catalog requests

**None this round.** No string was added, changed or retired. The requests carried forward
from W-R2-7 still stand exactly as `fix-r2-watch-work-destination.md` lists them.

## Named limits (not claims)

- **A deferred hop's own await window is still unowned.** `startDeferredConverseHop` sets
  `captureRequestID = nil` by design (its mint must be adoptable by nobody), so between its
  synchronous `.waiting` and its mint, `liveTurnOwns` answers true for any conversation —
  unchanged from before this round, and the marker guard covers the common case because the
  hop overwrites the marker with its own.
- **The gateway a legacy queue entry was addressed to is gone.** Nothing on the entry, and
  nothing this build may read, can recover it. See W-R3-3.

## Nobody undo (this round)

- **A marker match is not ownership.** `forgetPersistedInFlight(forConversation:)` exists so a
  dead turn's marker can go WITHOUT the live capture's pins, hint and request id going with
  it. Reaching for `clearInFlight(forConversation:)` in a "somebody else's completion" branch
  re-opens W-R3-1 exactly.
- **`liveTurnOwns` is the takeover test in BOTH handlers.** The pin alone cannot answer for a
  Work save (never pinned) or an Ask that has not minted (not yet pinned), and those are the
  two machines an older turn's completion was released.
- **The `.work` lane guard is separate from the turn guard, in both handlers.** The turn guard
  happens to cover Work today; keeping the lane test explicit is what makes a private save's
  immunity readable at the call site rather than derived.
- **`handleBackgroundFailure` keeps its nil-`conversationID` takeover for CHAT.** It is the
  only thing that unsticks a wedged `.uploading` machine. Do not "tidy" it into the turn
  guard.
- **A REPLAY never reads the pointer.** The deferred hop replays a decision made at capture
  time; re-deciding it minutes later is how an always-new capture ends up appended to a
  stranger's thread. The gate is `consumeAskHint`, which already distinguishes live from
  replay — keep the two rules together, and do not add a second false caller without meaning
  both.
- **`WatchGatewayLabel` verifies uniqueness over the WHOLE roster, untouched labels included.**
  A per-group answer cannot see a name that already reads like the label it produces. Keep
  `rosterLabels`' two passes together: pass 1 alone loses the third-name case, pass 2 alone
  loses the characters that carry the difference.
- **Done's `canRetry` half is load-bearing.** `dismissError()` deletes the preserved capture,
  so dismissing unconditionally would throw away a recording the launchpad's Try Again could
  still save.
