# fix-r2-watch-work-destination — Codex round 2 on the Watch Work destination

Source: the round-2 verification of the Watch Work-destination lane (8 findings, of which
this lane owns W-R2-1/2/4/5 and the two still-open round-1 items W-R1-1/W-R1-3).
Design: `docs/qa/work-usability/design/watch-work-destination.md`.
Round 1: `fix-r1-watch-work-destination.md` (its "Nobody undo" list still binds, with one
premise corrected below).

| ID | Verdict |
|---|---|
| W-R2-1 (P1) | **FIXED** — the picked gateway is persisted on the queue entry and mints the deferred draft |
| W-R2-2 (P1) | **FIXED** — `handleBackgroundReply` matches the completion to the live turn before releasing the machine |
| W-R1-1 (P2) | **FIXED** — the colliding group's labels are resolved together, uniqueness verified, ordinal fallback |
| W-R1-3 (P2) | **FIXED** — both pin fixtures now enter Work from `.idle`, so `startWorkCapture`'s own clears are what they measure |
| W-R2-4 (P2) | **FIXED** — the deferred hop stamps `.chat`; a restored wait stamps it too |
| W-R2-5 (P2) | **FIXED (attachment half)** — phase 2 propagates a verdict instead of acknowledging a write that did not happen. The receipt-copy half is **out of this lane's ownership** (below) |
| W-R2-3 (P1) | **OUT OF SCOPE** — `AppDelegate.swift` / `InAppAudioRecorder.swift` belong to the Mac lane |
| W-R2-6 (P3) | **OUT OF SCOPE** — `README.md` |
| W-R2-7 (P3) | **OUT OF SCOPE** — catalogs; the requests are listed below |
| W-R2-8 (P3) | **OUT OF SCOPE** — `handoff.md` |

Files touched: `Conduck/ConduckWatch Watch App/Views/WatchNoteView.swift`,
`.../Services/WatchRecordingService.swift`, `.../Services/AppleRelayPendingQueue.swift`,
`.../Services/WatchSettingsReader.swift`, `Conduck/Conduck/Services/AppleSpeechRelayCoordinator.swift`,
`Conduck/ConduckWatchTests/{ConduckWatchSmokeTests,WatchCaptureGuardTests,WatchRelayQueueRetryabilityTests}.swift`,
`Conduck/ConduckTests/WatchWorkRelayPhoneTests.swift`. **No catalog rows.**

---

## W-R2-1 — a deferred ask reached the wrong gateway · **FIXED**

Real. A chooser row starts a `.new` draft: `startCapture(boundTo: .new(ref))` writes the ref
as the one-shot Ask hint and leaves `pendingConversationID` nil, so `runRelay` enqueued
`conversationID: nil` and the pick lived nowhere durable. `completeEntry` then called
`startDeferredConverseHop(boundTo: nil)`, which passes `consumeAskHint: false` — correctly, the
hint belongs to a live Ask — and the resolver fell through to the pointer / default arms. Words
spoken to A were delivered to B, possibly appended to an existing B thread.

**Fix, in the shape the finding asked for:** `AppleRelayPendingQueue.Entry` gains
`backendRef: String?` — additive Codable, written only for a chat entry with no pin, so every
other entry's serialized shape is byte-identical. `runRelay` stamps it by PEEKING the hint
(`WatchSettingsReader.peekPendingInAppNewConversationBackend()`, a new non-consuming read) —
peeking, because the live hop still owns the one-shot consumption. `completeEntry` passes
`entry.backendRef` as `startDeferredConverseHop(addressedTo:)`, threaded through
`startConverseHop(mintingInto:)` into a resolver branch that mints against that ref and sits
BEFORE the pointer branch, for the same reason the hint branch does: a pick is not a
continuation. The ref is read off the ENTRY only — never recovered from the current default
or from another capture's hint.

The new branch mirrors the default-mint arm exactly (`recordActiveConversation`, `recordMint`,
`stampsQuickPointer: true`) and differs in one thing, the ref, so nothing else about a deferred
drain moves. An unconfigured ref is left to `remoteAgentConfig(for:)`, as the LIVE Ask arm
leaves it — refusing a named gateway here would substitute the very default this branch exists
to avoid.

Pinned by `testADeferredAskMintsAgainstTheGatewayItWasAddressedTo` (service) and
`testADeferredChatEntryCarriesThePickedGatewayAndAWorkEntryCarriesNone` +
`testAnEntryWithNoAddressedGatewayKeepsItsOldSerializedShape` (queue).

## W-R2-2 — an old Chat reply released a live Work save · **FIXED**

Real. `handleBackgroundReply` accepted `.uploading` and then assigned `.idle`
unconditionally; only the marker clear was conversation-matched. A Work capture owns
`.uploading` for its whole relay leg, so an older Chat turn's reply handed the machine to the
next capture mid-save — and `runRelay`'s `recordingFileURL = nil` would then null the
replacement capture's handle, surfacing "Recording file not found" on a Stop the person had
just pressed.

**Fix:** match the TAKEOVER to the turn before mutating the machine, which the failure
counterpart (`handleBackgroundFailure`) has always done. Two ways a reply is somebody else's:
the machine is running the WORK lane (no gateway reply can be its completion), or it is
waiting on a DIFFERENT conversation (`inFlightConversationID`, which covers the composer pin
AND the minted draft). Either way the conversation-matched marker clear still runs and the
queue still gets its drain edge; only the state assignment is withheld.

Pinned by `testAnOlderChatReplyDoesNotReleaseALiveWorkSave`.

## W-R1-1 — three names, two identical labels · **FIXED**

Real, and the round-1 fix was the cause: it anchored each name on the collider it agreed with
LONGEST (`.max()`), which throws away the characters that carry the difference. "Frankfurt
production alpha one" / "…alpha two" / "Frankfurt production one" rendered "…one" / "…two" /
"…one".

**Fix:** `WatchGatewayLabel.visible` now resolves the WHOLE colliding group together, in
roster order, and hands back this ref's label. Each name opens at the EARLIEST character that
tells it from any name it collides with (`.min()`), so "alpha" survives; then a uniqueness
pass gives any residual duplicate — two gateways named identically, or divergent tails that
truncate to the same string — a bounded ordinal by roster position, cut to keep the shared
budget plus its one leading ellipsis. The three-name fixture now reads "…alpha one" /
"…alpha two" / "…one". The shared shortening policy is still untouched.

Pinned by `testTwoNamesThatDivergeLateStillDoNotBorrowAThirdNamesLabel` (Codex's exact
fixture, asserting uniqueness AND that the two "alpha" labels still contain "alpha") and
`testIdenticallyNamedGatewaysStillGetOneLabelEach` (the ordinal). Both halves mutation-proven
below.

## W-R1-3 — the pin fixtures still measured `dismissError` · **FIXED**

Real. Both fixtures entered Work from `.error`, where `startWorkCapture` runs `dismissError()`
first, so deleting `startWorkCapture`'s own pin clears left every case green.

**Fix, exactly as prescribed:** each fixture establishes its pin, then assigns
`service.state = .idle` (the observer does not touch pins), asserts the pin is STILL there,
and only then starts Work. From `.idle` the only clears left are `startWorkCapture`'s. No
private access and no new production seam. The state is the one production reaches when an
older turn's reply lands against a newer turn's marker — which W-R2-2's guard now narrows,
without making the fixture less real.

## W-R2-4 — a deferred Chat turn kept Work's stamp · **FIXED**

Real. `dismissError()` retains `captureDestination`, and `startDeferredConverseHop` takes the
machine without passing `startCapture` — the one entry point that stamps. A real gateway turn
then ran under the launchpad's "Saving to Work…" caption.

**Fix:** the deferred hop stamps `.chat` and clears `workCaptureOutcome` beside its existing
"OWN NOTHING" block. `restoreInFlightStateIfNeeded` stamps it too on the arm that restores
`.waiting`: only a gateway turn ever reaches `.waiting`, and with W-R2-2's guard in place a
stale `.work` there would also refuse the reply that ends the wait.

Pinned by `testADeferredChatTurnClearsAStaleWorkStamp`.

## W-R2-5 — phase 2 acknowledged a write that did not happen · **FIXED (attachment half)**

Real, and it is the sharper case that makes it a defect rather than a taste call:
`.recordingMissing` means the desk holds NOTHING for this capture, and the wrist deletes its
only copy of the clip the moment it reads the `workSaved` stamp.

**Fix:** `attachRelayedWorkTranscript` returns a `WorkTranscriptAttachment` verdict instead of
swallowing the answer. `.recordingMissing` and a thrown store refusal map to `.retryable`,
which travels back on the SAME `workPublicationFailure` code phase 1 uses — uncached, so the
wrist keeps its entry, keeps its clip, and re-fires the same requestID, which republishes
idempotently and tries the words again. `.notAudio` maps to `.settledWithoutWords` and ships
the existing wordless acknowledgement: every re-fire reproduces it identically, and looping on
an eviction-exempt entry would cost the person a queue slot for ever and buy nothing.

**Correcting a premise, not breaking a rule.** `c1-phone-relay.md`'s "Nobody undo" says
`attachRelayedWorkTranscript` does not throw on purpose, "because its failure cannot cost the
recording (already durable) or the words (already in the reply)". It still does not throw. But
the premise's first half is false for `.recordingMissing` — the recording is exactly what is
gone — which is why the verdict now reaches the caller.

Pinned by `testACardGoneBeforeItsTranscriptIsRetryableRatherThanAcknowledged` and
`testAnIdHeldByAnotherKindOfCardSettlesInsteadOfLoopingForever`. The structural guard
(`testBothTranscriptionFailureArmsAnswerAPublishedCaptureFirst`) is untouched: it reads the
range from the typed catch arm onward, and all of this sits above it.

**Not fixed, and named:** the settled-failure receipt "Saved to Work. Add the words on your
iPhone." is one string mirrored across three catalogs and four code sites, one of them
CarPlay's — a cross-lane copy change, not this lane's to make alone. It is also not plainly
false: the desk takes a typed capture (`WorkboardTextMaterialSheet`), so the sentence reads as
"write the note yourself", not necessarily "transcribe this card". The other half of the
finding — that no phone-side pending-retry entry is created — lives in `PendingRetryStore` and
the Work-voice recovery lane.

## Measured

| Run | Result |
|---|---|
| `xcodebuild test -scheme ConduckWatchTests` (watchOS sim `28AC563B…`) | **Executed 291 tests, 0 failures**, exit 0, `grep -c ': error: '` = 0 (baseline 284 + 7) |
| `xcodebuild test -scheme Conduck` (iOS sim `04DEF…`), `WatchWorkRelayPhoneTests` + `ErrorSurfaceDriftGuardTests` + `RelayWireContractTests` + `RelayWireSourceDriftGuardTests` + `RelayReplyCacheTests` + `WorkVoiceRecoveryTests` | **74 tests, 0 failures**, exit 0 |
| `scripts/add-spdx-headers.sh --check` · `check-folder-map.sh` · `check-spec-cites.sh` · `check-storage-seam.sh` · `git diff --check` | exit 0 each |

**Mutation runs — every fix has a test that goes red without it.** With six source mutations
applied at once (label `.min()`→`.max()`; `startWorkCapture`'s two pin clears deleted; the
resolver's addressed-gateway branch deleted; the Work half of the reply guard deleted; the
deferred hop's `.chat` stamp deleted; the enqueue's `backendRef` stamp deleted) the watch run
reported **6 failures** across exactly the six intended cases. Two further single-mutation
runs isolate the label halves: `.min()`→`.max()` alone fails
`testTwoNamesThatDivergeLateStillDoNotBorrowAThirdNamesLabel`; deleting the uniqueness pass
alone fails `testIdenticallyNamedGatewaysStillGetOneLabelEach`. On the phone, returning
`.attached` for every attachment answer fails both new relay cases. All sources restored from
byte-compared copies afterwards.

No `-configuration` flag; caches under `~/Library/Caches/gigaduck-builds/watch-fix{,-ios}`,
both cleaned with `clean-build-cache.sh`.

## Catalog requests (owner: the catalog owner for this phase)

`Conduck/ConduckWatch Watch App/Localizable.xcstrings` — this round adds and retires nothing
itself. Carried forward from W-R2-7, verified against the source:

| Action | Key | Default value |
|---|---|---|
| add | `workboard.voice.error.deskWrite` | `Work couldn’t save this recording just now.` |
| add | `workboard.voice.error.screenshotWrite` | `Work couldn’t save the screenshot just now.` |
| retire | `A queued recording couldn't reach your iPhone and has expired.` | — |
| retire | `Ask your personal AI to start one.` | — |
| retire | `Couldn't reach your personal AI. Try again.` | — |
| retire | `Couldn't read the reply from your personal AI.` | — |
| retire | `Reply from your personal AI` | — |

Both added keys come from the shared, watch-compiled `Conduck/Models/AppError.swift`
(:761, :767); they are present in `Conduck/Localizable.xcstrings` and absent from the watch's.
The five retirements have no remaining reference under `ConduckWatch Watch App/**` (grep by
literal, `*.swift`).

## Nobody undo (this round)

- **The picked gateway is read off the ENTRY, never recovered.** Not from
  `defaultBackendRef`, not from a live capture's hint, not from the pointer. An explicit
  choice that cannot be read back is not one this queue may guess at — guessing is the
  finding.
- **`runRelay` PEEKS the Ask hint; it must never consume or clear it.** The live hop consumes
  it one leg later. `peekPendingInAppNewConversationBackend()` exists for exactly this and has
  no other caller.
- **`Entry.backendRef` is written only for a chat entry with no pin.** A pin already names its
  conversation and a conversation names its own gateway; Work reaches no gateway at all. The
  additive shape is pinned by `testAnEntryWithNoAddressedGatewayKeepsItsOldSerializedShape`.
- **The addressed-gateway branch sits ABOVE the pointer branch.** Below it, the pointer would
  win and the pick would be a continuation of somebody else's thread — the bug in a new
  costume.
- **`handleBackgroundReply` matches the turn before it writes `state`.** The marker clear was
  never the protection; the state assignment was the hole. Both halves of the guard are load-
  bearing: the Work half for a live save, the conversation half for an older Chat turn.
- **Every path that reaches `.waiting` without `startCapture` stamps `.chat` itself.** Today
  that is the deferred hop and the wrist-drop restore. A new one that forgets both mislabels a
  gateway turn as a private save AND wedges its reply.
- **`WatchGatewayLabel` resolves the GROUP, not a name.** A per-name answer cannot be checked
  for uniqueness, which is how three names produced two labels. Keep the earliest-divergence
  rule (`.min()`) and the uniqueness pass together — the tests measure them separately, and
  each one alone leaves a real failure standing.
- **The pin fixtures enter Work from `.idle` on purpose.** From `.error` they measure
  `dismissError()` and pass with `startWorkCapture`'s own clears deleted. The precondition
  assertion after `state = .idle` is what keeps that honest.
- **Phase 2's verdict reaches the caller.** `attachRelayedWorkTranscript` still never throws,
  but it no longer swallows: a stamp the wrist deletes its only clip on may only be sent once
  the write has actually landed. `.notAudio` stays SETTLED — making it retryable loops an
  entry that never ages out.
