# fix-r2-carplay-work-destination — Codex round 2 on the CarPlay Work destination

Source: `docs/qa/work-usability/verify/codex-r2-carplay-work-destination.md` (13 findings).
Round 1: `fixnotes/fix-r1-carplay-work-destination.md`. Design:
`docs/qa/work-usability/design/carplay-work-destination.md`.

| ID | Verdict |
|---|---|
| CP-R2-02 (P2) | **FIXED** — `CarPlayConverseUploader` claim retention + `startConverseHop` post-mint gate |
| CP-R2-03 (P2) | **FIXED** — `processRecording`, both staleness checks unscoped from the destination |
| CP-R2-04 (P2) | **FIXED** — `startListening` startup generation + arming-slot hand-on |
| CP-R2-05 (P2) | **FIXED** — `CarPlaySceneDelegate.presentationGeneration` |
| CP-R2-11 (P2) | **FIXED** — `terminalizeAbandonedUserTurn` (refutes R1's "deliberately not fixed") |
| CP-R2-12 (P2) | **PARTLY FIXED** — the named mutation closed, three executable negative controls added, eleven mutation runs recorded; the scene races stay source-scanned (why below) |
| CP-R2-01 (P1) | **SKIPPED** — out of ownership; the CarPlay half is refuted with API evidence |
| CP-R2-06/07/08/09/10 (P2) | **FORWARDED** — recorder / relay / phone-desk / Mac-quit ownership |
| CP-R2-13 (P3) | **FORWARDED** — `handoff.md` belongs to the docs pass |

Files touched: `Conduck/Conduck/CarPlay/CarPlayRecordingService.swift`,
`Conduck/Conduck/CarPlay/CarPlayConverseUploader.swift`,
`Conduck/Conduck/CarPlay/CarPlaySceneDelegate.swift`,
`Conduck/ConduckTests/CarPlayWorkNoteTests.swift`,
`Conduck/ConduckTests/CarPlayAttemptCancellationOutcomeTests.swift`,
`Conduck/ConduckTests/CarPlayVoiceTimingContractTests.swift`. **No catalog rows** — every
fix is a guard or a store flip, and none of them adds a sentence anyone reads or hears.

---

## CP-R2-02 — a cancelled chat could dispatch after a newer turn pruned its claim · **FIXED**

Two suspensions sit between the token mint and the wire (the file-lane revalidation and
`BackgroundFileTransfer.mintOutboxKey`), and both consumers of `pendingDispatchCancels`
pruned by token order: `markCancelClaim` dropped everything below the token it deposited,
`consumeCancelClaim` dropped everything below the token it cleared. Token order is not
evidence of termination — an abandoned chat sits suspended across exactly those two awaits —
so a newer turn reaching its own recheck first cleared the older turn's claim, and the older
task resumed to find nothing standing in front of it and uploaded the transcript the driver
had ended the session on.

**Fix, both halves the finding names.**

1. **Retention.** Neither consumer touches another turn's mark. `consumeCancelClaim` removes
   exactly its own; `markCancelClaim` inserts and then trims by AGE (`cancelClaimCeiling`,
   32 — the lowest tokens go first, because tokens are monotonic process-wide). Age says
   nothing about liveness, which is the point: it is the only bound that cannot mistake a
   suspended turn for a finished one. The leftovers pruning existed for — `endSession`
   marking a turn that had already completed — cost nothing, because a spent token can never
   name a future turn.
2. **Listen ownership after the post-token suspensions.** `startConverseHop` re-asks
   `isCurrentListen(attemptID)` after the file-lane revalidation and after the outbox mint,
   which is the last gate before `uploadConverse`. The revalidation is hoisted out of its
   `guard let` for the same reason R1 hoisted the two gateway snapshots: a check placed after
   the refusal never runs on the refusing path.

## CP-R2-03 — an earlier chat's STT refusal could end a Work session · **FIXED**

`endRefusalBelowFork` takes its CHAT arm whenever `workCapture` is nil, and that arm is
`endSession(speak:)` — which ends whatever session is live, not the one that raised the
refusal. The staleness check after `STTKeyReadiness.resolve` was scoped
`if workCapture != nil`, so it protected the lane that could already answer for itself and
left the other one holding the knife: chat A suspends in the key question, the driver ends it
and taps "Add to Work", A resumes with `.notConfigured` and speaks "Add your STT key" into
B's session, deleting B's partial recording.

**Fix:** both post-suspension checks in `processRecording` are unscoped. The one after
`AudioCompressor.compress` moved ABOVE the Work fork (it was inside `if destination == .work`
and is now the shared statement), and the one after the key verdict became a plain
`guard isCurrentListen(attemptID)`. The work fork's own copy was deleted as provably
redundant — no suspension separates it from the shared check now immediately above it.
The `workUploadHandedToSTT` defer still removes the Work lane's scratch copy on these exits.

## CP-R2-04 — a superseded listen startup could commit onto, or end, its replacement · **FIXED**

`isArmingListen` is a PROCESS latch, not a session one, and that is what lets a startup and
its replacement come apart: End lands while startup A is suspended in `detector.start()` or
the engine retry, the driver taps "Add to Work", and B's `startListening` is turned away at
that latch. A then resumes into a session that never asked for it. `guard sessionActive`
answers "is SOME session live" and so said yes — committing a running engine whose detector
callbacks carry A's invalidated attempt id (B's speech never endpoints, so the driver talks
into a microphone that only the max-duration timer will stop), or, on the failure arm, ending
B outright and painting the "Mic couldn't start" hint over a note that was recording fine.

**Fix:** `let attemptID = listenAttemptID` is taken immediately after the lineage bump, above
every suspension, and every resumed path asks `isCurrentListen(attemptID)` instead of the bare
flag — the cold-start settle, the `detector.start()` catch, the engine-retry failure, and the
commit. Superseded paths route through `handOnArmingSlotAfterAbandonedStartup()`, which
re-arms once the latch clears if a live session is still sitting idle — otherwise the
replacement keeps a session with End on the screen and a microphone that was never started.
It cannot spin: it refuses unless a session is live AND idle, and every lineage bump comes
from a real session or listen change.

## CP-R2-05 — a stale present completion cleared the flag over a live modal · **FIXED**

R1 closed the refusal path (`dismissModalLeftOverBy`) but not the completion's own state
writes. Presentation A is pending, a backgrounding cancels its start, the driver returns and
starts Work B on the SAME controller; A's delayed failure callback passes the controller
check and clears `isVoicePresented` — so B has a live modal behind a flag reading "nothing
presented", which lets a later state change present a second time and makes
`ensureVoiceDismissed` return at End without dismissing.

**Fix:** `presentationGeneration`, bumped by a `didSet` on `isVoicePresented` itself. The
`didSet` rather than a bump at each site is deliberate: the flag is written from eight places
(connect, resign-active, the become-active reconciliation, disconnect, `templateDidDisappear`,
both halves of `ensureVoicePresented`, `ensureVoiceDismissed`) and a ninth added later would
silently opt out. `ensureVoicePresented` takes the generation AFTER the write that owns its
presentation and re-checks it in the completion ABOVE both arms — the failure arm writes
presentation state, and the success arm activates a voice state on a template it may no
longer own. An obsolete completion answers `false`, which is honest: this presentation is not
the one on screen, so nothing may begin behind it, and the caller's refusal dismisses only a
modal that belongs to nobody.

**Scoped to the PRESENT completion.** The dismiss completion's overtaken-guard pair
(`!isVoicePresented && sessionActive != true`) is R1's and is left alone: adding a generation
there would make a dismiss overtaken by an unrelated flag write skip
`deactivateAudioSession()`, and the car radio staying muted is a worse failure than the one
it would close.

## CP-R2-11 — a cancelled turn left its user row reading `sending` · **FIXED**, and R1's refusal is withdrawn

R1 recorded this as a deliberate residual on the grounds that closing it "means a store write
on a dead session, which is worse." That reasoning does not survive contact with the write in
question. `ConversationStore.markPendingUserTurn(messageID:to:)` is addressed by message id
and its predicate is `id == ? AND role == "user" AND status == "sending"` — it cannot reach a
replacement session's fields, a sibling in-flight turn, or a turn that already resolved. It is
also the exact write the uploader's own pre-dispatch cancel arm already performs, so the lane
was inconsistent with itself rather than principled. Meanwhile the cost of not writing is real:
`sending` has one writer, so a hop that exits above `uploadConverse` creates no task and
nothing ever flips the row — the phone renders an unresolved send with no Retry until the
next launch's sweep, which is a repair and not a settlement.

**Fix:** `terminalizeAbandonedUserTurn(_:)`, called from every abandonment exit below the
append, and from the catch-all ABOVE its staleness fork so the spoken arm leaves a Retry chip
as surely as the silent one. `failed` is the honest terminal — there is no `cancelled` send
state, and `failed` is what puts the Retry chip in the iPhone thread. The
`catch is CancellationError` arm is untouched: the uploader already flipped that turn.

## CP-R2-12 — the guards admitted their own mutations · **PARTLY FIXED**

**The named hole is closed.** `testTheWordsAreParked…` searched for `isCurrentListen(` from
`stillOwnsCapture` forward, and the ownership-refusal arm carries its own copy — so deleting
the check on the SUCCESSFUL path (the one standing in front of the desk write) still passed.
The guard now brace-matches the refusal arm (`endOfBlock(openingAt:in:)`) and asserts the
check between the arm's close and `VoiceState.saving`. Verified red against that exact
deletion.

**Three executable negative controls added**, over the one mechanism in this lane that is
pure: `CarPlayCancelClaimLifetimeTests` now stages the overlapping-turn scenario through the
real `markCancelClaim` / `consumeCancelClaim` — an older suspended turn's claim must survive a
newer turn's recheck, and a newer turn's cancellation. Both are red against the pruning form.
Two existing cases in that class changed meaning with the design and were rewritten rather
than deleted: an orphaned mark is now RETAINED (and is asserted to cost nothing), and the
bound is `cancelClaimCeiling` rather than one.

**Still source-scanned, and honestly out of reach here:** competing scene starts, End during
presentation, stale same-controller callbacks, a startup resuming into a replacement session,
and an earlier chat's refusal ending a Work note. Every one of those needs a live
`CPInterfaceController` and a real `CarPlayRecordingService` with an audio engine; the
authoritative suite runs on an iOS Simulator with no CarPlay scene. R1 said protocol-ising the
interface controller and the recording service across the whole scene is a design change, not
a fix, and that is still true. What changed is the guards' strength: each now asserts the
executable branch AND its exit, and each was run against the mutation it claims to stop.

**Eleven mutation runs, all red** (source guards read the worktree file at run time, so these
need no rebuild):

| Mutation | Caught by |
|---|---|
| STT preflight rescoped to `if workCapture != nil, !isCurrentListen(…)` | `testTheStalenessChecksAroundTheSpeechPreflightCoverBothDestinations` |
| commit guard back to `guard sessionActive` | `testASupersededListenStartupNeitherCommitsNorReports` + `testACommitNeverLandsOnADeadSession` |
| `detector.start()` catch's generation check deleted | `testASupersededListenStartupNeitherCommitsNorReports` |
| `handOnArmingSlotAfterAbandonedStartup()` calls deleted | `testASupersededListenStartupNeitherCommitsNorReports` |
| a settling hop exit reverted to `else { return }` | `testEverySuspensionInTheChatHopIsFollowedByAStalenessCheck` |
| post-mint gate deleted | `testEverySuspensionInTheChatHopIsFollowedByAStalenessCheck` |
| successful-path ownership check deleted (the named hole) | `testTheWordsAreParkedBeforeTheyAreWritten…` |
| present-completion generation guard deleted | `testAPresentCompletionActsOnlyForItsOwnPresentation` |
| `didSet` on `isVoicePresented` removed | `testAPresentCompletionActsOnlyForItsOwnPresentation` |
| catch-all settlement moved BELOW its staleness fork | `testEverySuspensionInTheChatHopIsFollowedByAStalenessCheck` |
| `consumeCancelClaim` / `markCancelClaim` restored to pruning | the two new overlapping-turn cases (execution) |

## CP-R2-01 — out of ownership; the CarPlay half is refuted

The intents are the shortcuts lane's files. The CarPlay observation is separately
non-actionable: `CPListItem.handler` (`CarPlaySceneDelegate.makeWorkNoteItem`) receives no
provenance, and CarPlay publishes no API that distinguishes a physical row tap from an OS
voice-control invocation of the same row — so "foreground presentation does not prove
attendance" is true and unfixable, not a defect to close. R1's substantive point stands: the
founder's stated boundary is *"nothing on the desk ever becomes a gateway turn"*, which every
one of these paths keeps.

---

## Nobody undo (adds to `e-carplay.md`, `fix-r1-carplay.md`, `fix-r2-carplay.md`, `fix-r1-carplay-work-destination.md`)

- **No consumer of `pendingDispatchCancels` may drop another turn's mark.** Token order is
  not evidence that the older turn terminated — two suspensions separate the mint from the
  wire, so the claim a newer turn would prune is usually the one still standing in front of
  an abandoned upload. The bound is `cancelClaimCeiling` (age), and age is the only bound
  that cannot mistake a suspended turn for a finished one.
- **`isCurrentListen(attemptID)` after the post-mint suspensions in `startConverseHop`, and
  the file-lane revalidation stays hoisted out of its `guard let`.** Below the mint the token
  is non-zero, but the uploader can only answer for the claim standing when its own recheck
  runs; only the listen lineage covers the gap.
- **Every abandonment exit below the user-turn append settles that row.** `sending` has ONE
  writer, so an exit above `uploadConverse` leaves an unresolved send with no Retry until the
  next launch sweep. The catch-all settles ABOVE its staleness fork — the spoken arm needs the
  chip as much as the silent one. Do NOT reinstate R1's "a store write on a dead session is
  worse": the write is by message id under a `role == user AND status == sending` predicate
  and cannot reach any other session's rows.
- **The two staleness checks in `processRecording` are NOT scoped to the destination.**
  `endRefusalBelowFork`'s chat arm ends whatever session is live, so scoping the check to
  `workCapture != nil` protects the lane that could already protect itself and leaves the
  other one able to kill a Work note.
- **`startListening` captures `attemptID` before its first suspension and asks
  `isCurrentListen` on every resumed path — never the bare `sessionActive`.** A session that
  REPLACED this startup is live too; the bare flag commits an engine onto it whose detector
  callbacks carry an invalidated id, so the driver's speech never endpoints.
- **A superseded startup calls `handOnArmingSlotAfterAbandonedStartup()`.** `isArmingListen`
  is a process latch: the replacement was already turned away at it and nothing else re-arms.
  It must stay a `Task` (the `defer` clearing the latch has not run yet) and must keep its
  `sessionActive, state == .idle` guard (else it is a listen nobody asked for).
- **`presentationGeneration` is bumped by a `didSet` on `isVoicePresented`, not at call
  sites, and the present completion checks it ABOVE both arms.** Both arms write presentation
  state; a per-site bump is opted out of by the next write somebody adds.
- **The dismiss completion keeps its `!isVoicePresented && sessionActive != true` pair and
  takes NO generation.** A generation there would let a dismiss overtaken by an unrelated flag
  write skip `deactivateAudioSession()`, and a car radio that stays muted is worse than the
  race it would close.
- **`endOfBlock(openingAt:in:)` is how a guard skips a refusal arm.** A forward search from
  the branch's condition finds the arm's own copy of the check and keeps passing while the
  one on the successful path is deleted — which is exactly how the ownership guard admitted
  its own mutation.

---

## Measured

| Run | Result |
|---|---|
| `build-for-testing` (iOS sim, scheme Conduck) | 0 errors (first attempt hit 1 error in the watch lane's in-flight `AppleRelayPendingQueue.swift`; retried, clean) |
| 11 test classes that compile against or scan the CarPlay sources | **120 tests, 0 failures** — `CarPlayWorkNoteTests` 30 (27 before this round), `CarPlayCancelClaimLifetimeTests` 8 (was 5), `CarPlayVoiceTimingContractTests` 22, `CarPlayAttemptCancellationOutcomeTests` 4, `STTKeyBlackoutLaneTests` 11, `HeadlessRefusalLaneDriftGuardTests` 5 |
| Mutation runs | 11 mutations, 11 red (table above) |

## Forwarded, with the reason each is not mine

- **CP-R2-06** (phone/CarPlay microphone arbitration, `InAppAudioRecorder` + `AudioRecorder`)
  and **CP-R2-09** (a lost recorder reservation writing a transcript anyway) — the recorder
  and the retry store. One ownership gate spanning phone and CarPlay starts is the right
  shape; CarPlay's side is `beginSession` / `beginWorkNote`, both of which already funnel
  through `startListening`, so a lease taken there would be a small call.
- **CP-R2-07** (a Watch Work acknowledgement retiring the recovery path) — the relay.
- **CP-R2-08** (a foreground phone never discovering a CarPlay-created retry) — `ContentView`.
  Worth naming for the founder: this is the one that makes CarPlay's spoken *"Add the words on
  your iPhone"* point at nothing until a lifecycle refresh, so it is the most user-visible of
  the forwarded set.
- **CP-R2-10** (the Mac quit deadline) — `AppDelegate`, the Mac lane.
- **CP-R2-13** (QA script + the entitlement key, `handoff.md`) — the docs pass. The
  entitlement half is checkable and correct as Codex states it: the project declares
  `com.apple.developer.carplay-voice-based-conversation`
  (`Conduck/Conduck/Conduck-Official.entitlements`), not `carplay-communication`.
