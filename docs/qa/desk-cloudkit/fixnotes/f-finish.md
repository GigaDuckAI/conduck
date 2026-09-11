# f-finish — a reservation is now EXTENDED while a surface works and CHECKED before anything irreversible, and the discard is bound to the recording its question was asked about. All three findings CONFIRMED and fixed; nothing refuted.

Slug `f-finish`. Sim `C26F4ECE-16AC-40B7-8D6A-BBF82B5BBA5D`. No commits, pushes, stash, checkout, reset
or index operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/`
touched. **No `.xcstrings` opened.** No `.pbxproj` edit. No mirror triplet touched. No file outside my
ownership edited — `git status --short` at end of task lists my six plus nine that belong to the
arm-side f-agent (`Intents/ConverseIntent.swift`, `Services/InAppAudioRecorder.swift`,
`Services/PendingRetryGuard.swift`, `Services/PendingRetryStore.swift`,
`Services/ConversationStore+Workboard.swift`, `Services/Workboard/WorkCaptureDrainer.swift`,
`Views/Workboard/WorkboardVoiceCaptureView.swift`, four of their test files), none of which I opened.

Files changed — six, of which two are new:

| File | Change |
|---|---|
| `Conduck/Conduck/ContentView.swift` | the provider hop wrapped in `PendingRetryLeaseRenewal.whileRenewing`; `finishPendingRetry` returns the clear's answer and cancels the notice only on a true one; the Chat hand-off gated on it; `finishWorkRetry` confirms ownership BEFORE the desk write; the discard split into `offerPendingRetryDiscard` (reserve, then ask) / `discardPendingRetry` (delete exactly that) / `releasePendingRetryDiscard` (cancel); `pendingRetryDiscard` + `confirmingPendingRetryDiscard` state; `pendingRetryDiscardKeepsRecording`; one `pendingRetryBusyMessage` |
| `Conduck/Conduck/MenuBar/DictationService.swift` | the same four: renewal around the provider hop, `settleAfterFinishing` returns the clear's answer and gates the `onTranscript` hand-off, `finishWorkRetry` confirms ownership first, one `pendingRetryBusyMessage`. One stale comment corrected (O-3 is closed in `DictationPopoverView`) |
| `Conduck/Conduck/Views/Components/PendingRetryCard.swift` | the confirmation is HOST-raised (`@Binding confirmingDiscard`) and state-aware (`discardKeepsRecordingInWork` → `discardMessage`); `onDiscardConfirmed` / `onDiscardCancelled` |
| `Conduck/Conduck/Services/PendingRetryLeaseRenewal.swift` | **NEW** — the scoped renewal |
| `Conduck/ConduckTests/PendingRetryOwnershipHandoffTests.swift` | **NEW**, 9 cases |
| `Conduck/ConduckTests/PendingRetrySurfaceHandoffTests.swift` | assertions only: the discard's two halves (`offerPendingRetryDiscard` reserves and raises; `discardPendingRetry` acts on the reservation and must NOT re-select). **The census allowlist is untouched** — it is the integrator's (L5) |

`MenuBar/DictationPopoverView.swift`, `ViewModels/DiagnosticsRunner.swift`, `DiagnosticsFocusTests` and
`RemoteAgentRecoveryCopyLaneTests` are mine and are **unchanged** — reasons under §Decisions 6. All four
pass unchanged.

---

## Findings

### r6a#2 (major, surface half) — no surface renewed its reservation, and both ignored a false clear. CONFIRMED, fixed.

**Verified first, by call path, at the anchors given.** `ContentView.swift:1742` was
`_ = await PendingRetryStore.shared.clear(claim)` — the answer discarded — followed unconditionally by
`PendingRetryGuard.cancelDeferredNotification(for: claim.id)`; `:1633` was
`_ = await sendTurn(recoveredTranscript)` reached straight after `await finishPendingRetry(claim)` with
nothing between them. `MenuBar/DictationService.swift:489` and `:365` are the byte-for-byte twins
(`settleAfterFinishing` discarding the clear, then `onTranscript(trimmed)`). And nothing renewed:
`grep -rn 'PendingRetryStore.shared.renew\|confirmOwnership' Conduck/Conduck` over production returned
**nothing** — f-queue landed `renew`/`confirmOwnership` and recorded in its own §Requests 2 that no
surface calls either.

The window is real and is bounded by numbers already in the tree: `PendingRetryStore.claimLeaseDuration`
is **600 s**, while `STTClient` allows a custom request **300 s** and attempts it **three times**. So a
retry on the connection that parked the recording in the first place can outlive its hold; the store
then lets the next asker take the capture, and the original surface finished by handing words to the
Chat lane and cancelling the deferred notice of a recording it no longer owned — a second message the
person never dictated twice, and a "Recording Saved" notice retired out from under the surface that is
still working.

**Fix = L2 + L3, at every one of the four points L3 names.**
- **L2, renewal.** New `PendingRetryLeaseRenewal.whileRenewing(_:in:every:operation:)` wraps the
  provider round trip on both surfaces. It is SCOPED rather than start/stop: the renewal task is
  cancelled in a `defer`, so a return, a throw and a cancellation all stop it with nothing for the
  caller to remember — the same duty the release of the reservation itself was got wrong on once
  already. Interval **120 s**, which is L2's floor.
- **L3, ownership.** The Chat hand-off on both surfaces is now behind
  `guard await finishPendingRetry(claim) else` / `guard await settleAfterFinishing(claim) else` — the
  clear's own answer, which L3 accepts in place of `confirmOwnership` and which is strictly stronger
  because the check and the retirement are one atomic operation under the cross-process lock. The desk
  write is behind `confirmOwnership(claim)`, placed BEFORE `WorkVoiceCaptureCoordinator.recover` rather
  than after it, because the recovery IS the hand-off on that lane. The **notification cancellation**
  moved inside `if retired`. A false answer shows `pendingRetry.card.busy` and does nothing else.

**Regression tests** (`PendingRetryOwnershipHandoffTests`, all new):
- `testAHolderThatKeepsWorkingKeepsItsReservationAheadOfTheClock` — behavioural, over a real store: the
  sidecar's `expiresAt` after the work is strictly later than the one the claim was granted. CF `:77`
  `("…11:55:04 +0000") is not greater than ("…")`.
- `testTheRenewalStopsWithTheWorkItWasProtecting` — its opposite half, and the control that keeps the
  first honest: after the call returns, ten intervals pass and `expiresAt` does not move. CF `:106`
  `XCTAssertEqual failed: ("…11:57:22 +0000") is not equal to ("…")`.
- `testTheCardRenewsWhileItWorksAndChecksOwnershipBeforeItHandsTheWordsOn` and
  `testTheMenuBarRenewsWhileItWorksAndChecksOwnershipBeforeItHandsTheWordsOn` — the source half, which
  is the half that actually broke, scoped per function and ORDERED: the gate before
  `sendTurn`/`onTranscript`, `confirmOwnership` before `recover(`, and the cancellation inside
  `if retired`. Each of the four statements measured red on the mutation that removes it (CF
  `:252 :257 :270 :284` and `:302 :306 :318 :332`).
- `testAnOvertakenHolderIsRefusedTheClearItWouldHaveActedOn` — the store answer the gate consumes: an
  overtaken holder gets `false` from both `confirmOwnership` and `clear`, and the capture and its
  recording are left for the surface that owns them.
- `testAnOvertakenHolderCannotExtendTheReservationThatReplacedIt` — a straggling renewal cannot move
  somebody else's horizon; the token and the expiry both belong to the surface that took the capture.

### r6a#4 (major) — the Discard confirmation promised finality it could not deliver for a published Work capture. CONFIRMED, fixed.

**Verified:** `PendingRetryCard.swift:163` rendered ONE body,
`pendingRetry.card.discard.confirm.body` — "This deletes the recording from this device. It cannot be
recovered." — for every waiting capture. But `PendingRetryMetadata.isExemptFromExpiry`
(`PendingRetryStore.swift:226`) reads `resolvedDestination == .work && publicationState != .published`,
i.e. a Work entry that DID publish is an ordinary expiring entry whose recording is already a playable
card on the desk; the queue is holding a second copy purely so the words can be tried again. For that
person the sentence is false in the direction that stops them tidying up.

**Fix.** The card's confirmation body is chosen by `discardKeepsRecordingInWork`, and the host decides
it from the record's own verdict — `resolvedDestination == .work && publicationState == .published`,
the exact complement of the exemption rule, so the two cannot drift. New source key
`pendingRetry.card.discard.confirm.body.published` (§Catalog); the existing key survives verbatim for
the unpublished and Chat cases, where the recording really is the only copy.

**The verb did NOT change, so no action-label key was minted** (the finding's "+ a matching action
label *if* the verb changes"). What is discarded is the *waiting recording* in both cases, which is
literally true; the body carries the whole difference. And the card's BUTTON label cannot be
state-aware at all: it is drawn before any reservation exists, so nothing on screen knows which capture
the next tap will take. §Requests 2 has the three-key variant if the founder wants the verb split.

**Regression test.** `testTheDiscardConfirmationIsStateAwareAboutWhatItActuallyDeletes` — the card
carries BOTH keys and gates on the flag, and the host's rule is the collapsed
`return metadata.resolvedDestination == .work && metadata.publicationState == .published`. CF `:353`
(the published key gone) and `:360` (the host's rule flattened to `false`).

### r6a#7 (minor) — Discard re-selected out of the queue at confirmation time. CONFIRMED, fixed.

**Verified:** `ContentView.swift:1764` was `guard let claim = await PendingRetryStore.shared.claimNext()`
INSIDE `discardPendingRetry()`, reached from the card's `confirmationDialog` action — i.e. after the
person had answered. Both halves of the finding hold. `claimNext` answers "the newest capture nobody has
reserved", so with the newest held elsewhere it hands back an older one; and when everything is held it
returns nil, which the old body treated as "refresh and return" — a confirmed destructive action that
silently did nothing.

**Fix.** The reservation is taken when the BUTTON is tapped and held across the question:
`offerPendingRetryDiscard()` reserves, stores the claim in `pendingRetryDiscard`, and only then raises
`confirmingPendingRetryDiscard`; the card's dialog is host-presented (`@Binding`), so it can only ever
be answered about a capture this surface holds. Confirm → `clear(claim)` on exactly that claim. Cancel →
`release(claim)`, so cancelling costs the next tap nothing. A refusal at tap time shows
`pendingRetry.card.busy` and asks nothing.

**Deviation from the letter, stated: `claimNext()` at tap, not `claim(id:)`.** See §Deviations 1 — the
host has no way to learn a capture's id without reserving it, and the accessor that would give it one
is in a file I do not own. Reserving first is what the brief's mechanism was for (an exact capture, no
TOCTOU under the dialog) and it delivers that in full; §Requests 1 names the twelve-line accessor that
would also make the card's Troubleshoot chip name the same capture the buttons act on.

**Regression tests.**
- `testTheDiscardDeletesTheRecordingItsQuestionWasAskedAbout` — behavioural: reserve, then a NEWER
  capture arrives while the dialog is up, then confirm. The reserved one goes; the newcomer is intact,
  byte-identical and claimable. On a confirm-time selection the newcomer is what `claimNext` returns,
  so the old shape deletes a recording the person has never seen.
- `testADiscardThatCannotReserveDeletesNothing` — one capture, held elsewhere: nothing to reserve,
  count still 1, the recording still on disk.
- `PendingRetrySurfaceHandoffTests.testTheCardSelectsReservesAndCountsThroughTheClaimAPI` (assertions
  updated) — `offerPendingRetryDiscard` reserves and raises the confirmation, and `discardPendingRetry`
  acts on `pendingRetryDiscard` and may NOT call `claimNext()`. CF: `failed: caught error: "No
  `func offerPendingRetryDiscard` in Conduck/ContentView.swift"`.

---

## How I know the tests bite — MEASURED, not argued

A counterfactual copy of the tree under `~/Library/Caches/gigaduck-builds/f-finish/cf-tree` (rsync,
`.git` excluded), with only the mechanisms the findings name reverted. **Three passes**, because several
cases are controls on opposite halves of the same mechanism and cannot all be red at once, and because
a `try XCTUnwrap` that fails aborts the rest of its case (integrate-g's O-21 residue, met here in
practice).

| Mutation | What it restores |
|---|---|
| M1 | the deferred notice is cancelled on a refused clear (both surfaces) |
| M2 | the iOS Chat lane sends the transcript after a clear whose answer it ignored |
| M3 | neither surface wraps the provider hop; `whileRenewing` runs the operation and renews nothing |
| M4 | the desk write is attempted with no ownership check (both surfaces) |
| M5 | the macOS Chat lane hands `onTranscript` the words after an ignored clear |
| M6 | the discard selects at confirmation time again (`claimNext` inside `discardPendingRetry`) |
| M7 | one confirmation sentence for every destination |
| M9 | the renewal is never cancelled (`defer` removed) |

**Pass 1** (M1–M7), `cf-test-1.log` — `** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` = 0:

```
** TEST EXECUTE FAILED **
	 Executed 9 tests, with 7 failures (0 unexpected) in 2.622 (2.624) seconds   ← PendingRetryOwnershipHandoffTests
	 Executed 9 tests, with 3 failures (1 unexpected) in 1.726 (1.728) seconds   ← PendingRetrySurfaceHandoffTests
```

| Case | First failure on the counterfactual |
|---|---|
| `testAHolderThatKeepsWorkingKeepsItsReservationAheadOfTheClock` | `:77 ("2026-09-03 11:55:04 +0000") is not greater than (…)` |
| `testTheCardRenewsWhileItWorksAndChecksOwnershipBeforeItHandsTheWordsOn` | `:252` the renewal wrapper gone, then `:257 XCTUnwrap failed` — the Chat gate gone |
| `testTheMenuBarRenewsWhileItWorksAndChecksOwnershipBeforeItHandsTheWordsOn` | `:302`, then `:306 XCTUnwrap failed` |
| `testTheDiscardConfirmationIsStateAwareAboutWhatItActuallyDeletes` | `:353` the published key gone, `:360` the host's rule gone |
| `PendingRetrySurfaceHandoffTests.testTheCardSelectsReservesAndCountsThroughTheClaimAPI` | `caught error: "No `func offerPendingRetryDiscard` in Conduck/ContentView.swift"` |

**Pass 2** (M4 + M1 + M9 only; the renewal and the Chat gates restored so the later assertions are
reached), `cf-test-3.log` — `Executed 9 tests, with 3 failures (0 unexpected)`:

```
:270  XCTUnwrap failed — The desk write is attempted on behalf of a capture this surface may no longer hold.
:318  XCTUnwrap failed — the same, menu bar
:106  XCTAssertEqual failed: ("2026-09-03 11:57:22 +0000") is not equal to (…)  ← the renewal outlived the work
```

**Pass 3** (M1 alone), `cf-test-5.log` — `Executed 9 tests, with 2 failures (0 unexpected)`:

```
:284  XCTAssertTrue failed — the notice is cancelled on a clear that was refused (card)
:332  XCTAssertTrue failed — the same, menu bar
```

**5 of my 9 new cases went red**, each on the mechanism it names, and one existing case
(`testTheCardSelectsReservesAndCountsThroughTheClaimAPI`) went red on M6. The four that stay green are
the controls, and they are green **by design**, not by omission:
`testAnOvertakenHolderCannotExtendTheReservationThatReplacedIt` and
`testAnOvertakenHolderIsRefusedTheClearItWouldHaveActedOn` measure the STORE's token discipline
(f-queue's, unmutated) — they are the input my gates consume; `testTheDiscardDeletesTheRecordingItsQuestionWasAskedAbout`
and `testADiscardThatCannotReserveDeletesNothing` measure the SEQUENCE, which the source guard is what
pins to the surface.

One foreign file had to be removed from the CF tree to make it compile — `ArmSideReservationTests.swift`,
the arm-side agent's new file, caught mid-edit by the rsync (`type 'Self' has no member 'squeezed'` ×6).
It is not mine and no case of mine touches it. Recorded rather than hidden. The CF tree went with the
build cache at end of task.

---

## Decisions

1. **The renewal is a SCOPED call, not a start/stop pair.** `whileRenewing(claim) { … }` cancels the
   renewal in a `defer`, so "stops renewing on any exit" (L2) is structural rather than a duty each
   exit has to remember. The alternative — a `start()`/`stop()` on each surface — is the exact shape
   r5a#5 got wrong with the release, on the same two functions.
2. **A new production file rather than the same fifteen lines in two surfaces.** `DictationService` is
   `#if os(macOS)`; `ContentView` is the cross-platform root. There is no owned file both can share, so
   the alternatives were duplication or declaring a service type inside a SwiftUI view. The file is
   also what makes the renewal TESTABLE at all — `every:` and `in:` are plain default arguments (no
   `#if CONDUCK_TESTING` seam), and the two behavioural cases drive a real store over a real directory.
3. **The clear's answer IS the ownership check on the Chat lanes.** L3 offers `confirmOwnership` OR
   `clear(claim)`; the clear is strictly stronger here because the check and the retirement happen
   inside one `withExclusiveLock`, so nothing can overtake the reservation between them. On the Work
   lane the hand-off is the recovery itself, so that one takes `confirmOwnership` BEFORE it.
4. **A refused clear AFTER a successful desk write is not reported as a failure.** `finishWorkRetry`
   confirms ownership before publishing; if the clear is then refused, the card is on the desk and the
   surface that overtook this one will retire the entry. Painting "already being finished" over a
   publication that just succeeded would be a lie in the other direction. The count refresh still runs.
5. **The discard reserves at TAP, and the dialog is host-presented.** Reserving at confirm time cannot
   bind the question to a capture, and reserving at tap while leaving the dialog card-local cannot
   withhold the dialog when the reservation is refused. The `@Binding` is what lets the card stay dumb
   and the host stay the only thing that knows which capture is at stake — which is also what makes
   r6a#4's state-aware body possible at all: nothing else on screen knows the entry.
6. **`DictationPopoverView` and `DiagnosticsRunner` untouched.** O-3 is already closed —
   `DictationPopoverView.swift:1327` reads `service.pendingRetryCount > 0`, so the busy `.error` state
   both surfaces now settle into DOES draw its Retry button; I verified that before assuming it. O-9
   (`diagnostics.voice.pendingRetry.waiting`) needs a catalog row in the same edit as its `if`, which a
   parallel phase forbids — it stays open, correctly. `DiagnosticsFocusTests` and
   `RemoteAgentRecoveryCopyLaneTests` assert nothing about the retry queue; being listed as mine gave me
   the right to change them, not a reason to.
7. **One stale comment corrected in `settleAfterFinishing`.** It told the next reader the popover gates
   its Retry on `lastError?.shouldPreserveForRetry` and that a Shortcuts-armed capture leaves the button
   withheld. That stopped being true when O-3 landed, and a comment that misdescribes the gate is how
   somebody "fixes" it back.
8. **No Codex consult.** The one genuinely hard call (§Deviations 1) is an ownership question, not a
   technical one.

## Deviations

1. **r6a#7 says "Discard uses `claim(id:)` on THAT id". It uses `claimNext()` at tap time instead, and
   the id it binds to is the one that answer carries.** The reason is checkable: the host has no way to
   learn a queued capture's id without reserving it. The store's whole metadata-only surface is
   `pendingCount()`, `hasPending()`, `pendingErrorCode()` and `diagnosticSnapshot()` — measured, by
   listing every `func` in `PendingRetryStore.swift` — and not one returns an id; `load()` does, and is
   the operation this whole wave exists to retire. Adding the accessor is ~12 lines in a file f-queue
   owns and my brief tells me to code against as implemented, so §Requests 1 rather than a foreign edit.
   What the chosen shape delivers is r6a#7's substance in full: one exact capture, reserved before the
   question, deleted after it, with a busy refusal instead of silence. What it does NOT deliver is the
   sliver where the card's Troubleshoot chip (which reads the NEWEST capture) can describe a capture the
   buttons cannot take, because another surface holds it — and note the card's Retry has always had the
   same binding, so Retry and Discard act on the same recording as each other either way.
2. **One new key, not four.** §Findings r6a#4 explains the verb test and why the card's button label
   cannot be state-aware. §Requests 2 has the alternative.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/f-finish/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from a tail
or an exit code. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`. The one throwaway
tree copy lived under the slug dir and went with it.

- **Simulator TCC checked BEFORE trusting any run:**
  `sqlite3 …/C26F4ECE…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → `kTCCServiceUbiquity|ai.gigaduck.AgentRelay|2`, exit 0. **No `0`
  row**, so no stale denial.
- **iOS `build-for-testing`** → `ios-bft-5.log` (final, on the tree as it stands with the arm-side
  agent's changes in it): `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, twelve quoted `-only-testing:` flags → `test-2.log`:
  ```
  ** TEST EXECUTE FAILED **
	 Executed 159 tests, with 3 failures (0 unexpected) in 22.202 (22.243) seconds
  ```
  **The three failures are TWO cases, and neither is mine to close** (both detailed below).

  | Class | Result line |
  |---|---|
  | `PendingRetryOwnershipHandoffTests` (**new**) | `Executed 9 tests, with 0 failures (0 unexpected) in 1.758 (1.760) seconds` |
  | `PendingRetrySurfaceHandoffTests` | `Executed 9 tests, with 2 failures (0 unexpected) in 2.342 (2.345) seconds` — **both in the census case, which is L5/the integrator's** |
  | `WorkboardCopyTruthGuardTests` | `Executed 8 tests, with 1 failure (0 unexpected) in 13.099 (13.101) seconds` — **the new copy key, which is the serial copy agent's splice** |
  | `DiagnosticsFocusTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.012 (0.013) seconds` (unchanged, not edited) |
  | `RemoteAgentRecoveryCopyLaneTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.009 (0.012) seconds` (unchanged, not edited) |
  | `PendingRetryQueueTests` | `Executed 17 tests, with 0 failures (0 unexpected) in 0.011 (0.018) seconds` |
  | `PendingRetryDurabilityTests` | `Executed 26 tests, with 0 failures (0 unexpected) in 0.094 (0.099) seconds` |
  | `PendingRetryLeaseTests` | `Executed 13 tests, with 0 failures (0 unexpected) in 0.046 (0.050) seconds` |
  | `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 1.725 (1.727) seconds` |
  | `HeadlessRetryGuardSpanTests` | `Executed 13 tests, with 0 failures (0 unexpected) in 0.058 (0.061) seconds` |
  | `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.820 (2.822) seconds` |
  | `WorkVoiceRecoveryTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.228 (0.234) seconds` |

  Beyond the classes my brief names I ran `PendingRetryLeaseTests` (the store half of r6a#2),
  `ErrorSurfaceDriftGuardTests` (the card is a registered retry surface in it) and `WorkVoiceRecoveryTests`
  (my `finishWorkRetry` edits sit either side of `recover`).

  **The two failures, exactly:**
  ```
  PendingRetrySurfaceHandoffTests.swift:283: XCTAssertEqual failed: ("[]") is not equal to
    ("["Conduck/Services/PendingRetryGuard.swift", "Conduck/Services/InAppAudioRecorder.swift"]")
    — `clear(ifCurrentID:` …
  PendingRetrySurfaceHandoffTests.swift:283: XCTAssertEqual failed: ("[]") is not equal to
    ("["Conduck/Intents/ConverseIntent.swift"]") — `recordPublicationState(id:` …
  WorkboardCopyTruthGuardTests.swift:308: XCTAssertNotNil failed -
    pendingRetry.card.discard.confirm.body.published is referenced in the app target but has no
    catalog row …
  ```
  The first two are the census reading **empty where the allowlist still names three files** — i.e. the
  arm-side agent has finished L5's migration and the allowlist must now be emptied. My ownership is
  "assertions only — the census allowlist is the integrator's", so I left it exactly as it is; it is
  ONE edit (delete the three rows, keep the empty sets) and the class goes green. The third is my new
  copy key with no catalog row, which is precisely what a parallel phase produces: §Catalog.
- **macOS `build -destination 'platform=macOS'`** → `mac-2.log`: `grep -c ': error: '` = **0**, and:
  ```
  ** BUILD SUCCEEDED **
      Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
  ```
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.** All
  four of my production files compile there.
- **`bash scripts/check-storage-seam.sh`** → `✓ storage seam intact — 808 Swift files scanned…`, exit 0.
  **`bash scripts/check-folder-map.sh`** → `✓ folder map current — 36 Swift source directories, all
  mapped` (both new files are in already-mapped folders, so no map row was needed and none was added).
- **`git diff --check`** → no output, exit 0. Both new files: **0 tab lines, 0 trailing-whitespace
  lines**, each opens with `// SPDX-License-Identifier: Apache-2.0` + a header comment.
  `git status --short` for `*.xcstrings`, `*.pbxproj`, `Conduck/Conduck/Configs` and `docs/qa` →
  **empty**.
- **Warnings: ZERO added, on either platform.** In my four production files and my two test files the
  only warnings anywhere are the two pre-existing ones at `DictationService.swift:891`
  (`startDisplayTimer`'s captured `self`) — the same class and the same count e-surfaces recorded, at
  code I did not modify. One warning I DID introduce was measured and removed before the final build:
  `PendingRetryLeaseRenewal.interval` needed `nonisolated` because it is a default argument evaluated
  outside any actor.
- **Suite delta from this slice: +9** (`PendingRetryOwnershipHandoffTests` NEW 9; every other class I
  ran is at its own agent's recorded count). **The watch target compiles none of my files** —
  `PendingRetryOwnershipHandoffTests` and `PendingRetryLeaseRenewal` appear nowhere in
  `project.pbxproj`, and `PendingRetry` appears nowhere in that file at all, so no `membershipExceptions`
  list can name them; the synchronized groups cover both. **No `.pbxproj` edit was needed or made.**
- **One run died before any test case started** (`cf-test-2.log`, and again `cf-test-4.log`):
  `Simulator device failed to launch com.example.Conduck … Busy ("Application failed preflight
  checks")`, no `Executed` line at all. Both were on the COUNTERFACTUAL tree (whose bundle id is the
  public placeholder). Each was retried once with no change to the tree and went green
  (`cf-test-3.log`, `cf-test-5.log`). I did NOT run `simctl shutdown all`: another f-agent is on this
  machine and it would have killed their in-flight run.
- **NOT run, plainly: the full iOS suite and the watch suite.** Neither is in my brief, no watch sim is
  assigned, and the arm-side agent was editing this tree throughout — nine of their files are modified
  in `git status` at end of task, so a full run would report their in-flight state as mine.
- Build cache removed at end of task with `.claude/scripts/clean-build-cache.sh f-finish` →
  `removed: f-finish`; every log quoted above went with it, and so did the counterfactual tree.

## What I did NOT verify, plainly

- **No UI, no screen, no device.** The host-raised confirmation, the state-aware sentence, the busy
  line on both surfaces and the discard's cancel path are all founder-QA items below. A source guard
  proves the statements are there; it cannot prove the dialog appears where it should or that
  VoiceOver reads it sensibly.
- **The renewal has never run against a real slow provider.** The cases drive it at a 50 ms interval
  against a real store; the production interval is 120 s and only a genuinely long transcription
  exercises it end to end (Founder QA 1).
- **Two PROCESSES contending on a reservation are still untested** (O-5). My cases drive the real
  `flock` from one process.
- **A dialog dismissed WITHOUT an answer** (a deep link arriving, a scene change) is handled by
  releasing the stale reservation on the next tap rather than at the moment of dismissal — reasoned,
  not measured, because it needs a live SwiftUI presentation. Worst case is one reservation held for
  its horizon; the release-on-next-tap is what stops it compounding. Founder QA 5.
- **I ran no other agent's counterfactual and did not re-run theirs.**

---

## Catalog

**Keys ADDED in source: ONE. No `.xcstrings` file was opened — the serial copy agent splices it.**

```
pendingRetry.card.discard.confirm.body.published = "This removes the copy kept for another transcription attempt. The recording is already in Work and stays there."
```

Notes for the splice:
- ONE call site: `Conduck/Conduck/Views/Components/PendingRetryCard.swift`, `discardMessage`. The source
  literal is a multi-line `"""` with a `\` continuation; the extracted value is the single two-sentence
  string above.
- It is the SIBLING of `pendingRetry.card.discard.confirm.body`, which is unchanged and still carries
  both claims `WorkboardCopyTruthGuardTests` requires (*this device*, *cannot be recovered*). The new
  row deliberately carries NEITHER of those claims — that is the whole point of it — so if the guard's
  rule (5) is ever widened to walk every `…confirm.body*` key it must exempt this one, or better,
  assert the complement: that the published row does NOT say the recording is gone.
- Register matched to its sibling: two flat sentences, second person implied, no contraction in the
  absolute, no exclamation mark. Founder's final pass.
- **Reused, not added:** `pendingRetry.card.busy` (now referenced from `ContentView.swift` and
  `MenuBar/DictationService.swift` once each, via one `pendingRetryBusyMessage` per file, same default
  value as e-surfaces spliced), `pendingRetry.card.discard`, `pendingRetry.card.discard.confirm.title`,
  `pendingRetry.card.discard.confirm.action`, `pendingRetry.card.count`, `common.cancel` — all unchanged.

**Keys made DEAD: NONE.** No string-bearing branch was deleted; every existing key on both surfaces
still has its call site.

---

## Requests

1. **Owner of `Services/PendingRetryStore.swift` — one metadata-only accessor, and r6a#7's last sliver
   closes.** Everything the card shows about WHICH recording is waiting comes from
   `pendingErrorCode()`, which answers for the newest capture including one another surface holds;
   everything the card DOES goes through `claimNext()`, which answers for the newest UNRESERVED one.
   The two can name different captures. Neither `pendingErrorCode()`, `pendingCount()`, `hasPending()`
   nor `diagnosticSnapshot()` returns an id (measured: every `func` in the file), so the host cannot
   bind the card to a capture without reserving it. The edit:
   ```swift
   /// The newest waiting capture's id and arming code, metadata only — the two
   /// things the retry card renders about WHICH recording is waiting.
   func pendingSummary() async -> (id: UUID, lastErrorCode: Int?)?
   ```
   With it, `refreshPendingRetryState()` learns the id, the Troubleshoot chip and the two buttons name
   the same capture, and the discard can address it with `claim(id:)` exactly as r6a#7 specifies. It
   supersedes `pendingErrorCode()`, whose only two callers are `ContentView.refreshPendingRetryState`
   and `DictationService.settleAfterFinishing` — both mine, both one line.
2. **Founder copy call — whether Discard's VERB should change for a published Work capture.** Today the
   button is "Discard recording", the title "Discard this recording?", the action "Discard", and only
   the body differs. The alternative reads the whole dialog as "Stop retrying this recording?" /
   "Stop retrying", which is more precise and costs three more keys
   (`pendingRetry.card.discard.confirm.title.published`, `…action.published`, and
   `pendingRetry.card.discard.published` for the button). I did NOT take it unilaterally for two
   reasons: the card's button is drawn before any capture is reserved, so it can never be state-aware,
   and a button labelled "Discard recording" leading to a dialog titled "Stop retrying" is its own kind
   of confusing. One splice whenever the founder decides.
3. **Integrator — the census allowlist is now STALE and its case is RED** (L5). The arm-side agent has
   migrated all three lanes; the scan finds zero callers where
   `PendingRetrySurfaceHandoffTests.testNoProductionCallerRemainsOnTheSupersededQueueOperations`
   still expects `PendingRetryGuard.swift` + `InAppAudioRecorder.swift` (for `clear(ifCurrentID:`) and
   `ConverseIntent.swift` (for `recordPublicationState(id:`). Empty all three sets in one edit — the
   sets, not the rows: the needles must stay, because an EMPTY expectation is what fails when a new
   legacy caller appears. My ownership is assertions only, so I left it exactly as it is.
4. **Integrator — `WorkboardCopyTruthGuardTests.testEveryWorkKeyInSourceHasACatalogRow` is RED on my
   new key** and goes green with the §Catalog splice. It is not a regression and it is not the guard
   being wrong: that guard exists to make exactly this omission impossible to ship.
5. **Nobody undo these** — each is pinned by a case measured red on a counterfactual:
   - **The provider hop runs inside `whileRenewing`, and the renewal is cancelled in a `defer`.**
     Removing the wrapper loses the recording on a long transcription; removing the `defer` leaves a
     task holding a capture nobody is finishing.
   - **The transcript hand-off is BEHIND the clear's own answer** on both surfaces, and the desk write
     is behind `confirmOwnership` placed BEFORE `recover`. Moving either check after the act it guards
     is the same defect written differently.
   - **The deferred notice is cancelled only on a TRUE clear.** Cancelling unconditionally retires the
     notice of a recording another surface is still working on.
   - **The discard reserves at TAP and the dialog is host-raised.** Selecting at confirmation time
     deletes a recording the person has never seen; raising the dialog without a reservation asks a
     question that cannot be honoured.
   - **The confirmation's two bodies, and the host's `.work && .published` rule.** The rule is the
     exact complement of `isExemptFromExpiry`; loosening it tells a Chat user their words are safe
     somewhere they are not.

---

## Refuted

**None.** All three findings were traced against the current tree by call path before any code changed,
and all three hold exactly at the anchors quoted. The decided design directions (L2, L3, and r6a#4's
state-aware confirmation) were implementable as specified. The one place the letter moved is recorded
as §Deviations 1 rather than a refusal — `claimNext()` at tap instead of `claim(id:)`, forced by the
store having no metadata-only id accessor and by that file not being mine — and it delivers r6a#7's
substance in full, with §Requests 1 naming the twelve lines that would also close the cosmetic sliver.

One qualification, stated as such: **L2 says "every surface that transcribes renews", and two do.** The
Work voice sheet (`WorkboardVoiceCaptureView` → `InAppAudioRecorder`) transcribes too, and whether it
holds a renewable reservation at all is the arm-side agent's slice, not mine — I did not open either
file. If it now claims by id, it wants the same `whileRenewing` wrapper around its own provider hop, and
the type is there for it.

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven, e-queue's six, e-surfaces' eight and f-queue's five, which all still apply.

1. **A transcription longer than ten minutes, on the surface doing it.** Point Settings → Voice at a
   custom STT endpoint that stalls (or run on a deliberately terrible connection), park a recording, and
   press Retry. Let it run past ten minutes. When it finally answers, the words must land — before this
   change the reservation lapsed at ten minutes and the capture could be taken by anything that asked.
   Nothing may appear twice, and the card must not have quietly emptied while the spinner was up.
2. **Two surfaces, one recording, on the Mac — the losing one must SAY so.** With one capture waiting,
   start the menu-bar Retry, let it run, then press the main window's retry. The second must show
   **"This recording is already being finished. Try again in a moment."** and must still draw a Retry
   button (it is a retryable state). Never two cards, never two messages in the thread.
3. **Discard while another surface holds the only waiting recording.** Same setup: with the menu bar
   mid-retry, tap **Discard recording** in the main window. **No confirmation dialog may appear at
   all** — the busy line shows instead, and nothing is deleted. This is the half that used to fail
   silently.
4. **Discard a published Work recording, and read the dialog.** Record a Work voice note that reaches
   the desk but whose transcription fails (turn the network off *after* the card appears). Tap Discard:
   the confirmation must say the retry copy is removed and **the recording stays in Work** — it must NOT
   say it cannot be recovered. Confirm, then check the desk: the audio card is still there and still
   plays.
5. **Cancel the confirmation, then retry immediately.** Tap Discard, tap **Cancel**, then tap **Retry**
   at once. Retry must start straight away — if it says "already being finished", the cancel is not
   releasing its reservation and that is a bug in this change.
6. **Discard, then leave the dialog by a side door.** Tap Discard and, while the dialog is up, open a
   reply notification (or switch apps and come back). Then tap Discard again: the confirmation must
   appear normally. It must not report the recording as busy.
7. **The backlog after a refused hand-off.** With two recordings waiting, retry one on each surface at
   roughly the same time. Exactly one message may reach the thread per recording, and the count on the
   card must end at zero with no card left standing.

---

## Settled facts — one sentence each, for whoever writes the docs

- While a retry surface is waiting for the words, it keeps asking to hold on to the recording, so a
  transcription that takes far longer than usual cannot have its recording taken by another window or
  deleted on the clock.
- The moment the work stops — it finished, it failed, or the person left — the surface stops asking,
  so a recording is never held by something that is no longer working on it.
- Before a surface sends the words it recognised, cancels the "Recording Saved" notice, or shows
  success, it checks that the recording is still its own; if another surface took over, it says so and
  does nothing else, which is why the same words can never be sent twice.
- Nothing is written to Work on behalf of a recording the surface no longer holds — the check happens
  before the write, not after it.
- Tapping Discard reserves the recording first and asks the question second, so the recording deleted is
  the recording the person was looking at, even if another one arrives while the confirmation is up.
- When every waiting recording is being finished elsewhere, Discard shows the busy line and asks no
  question at all, rather than confirming a deletion it cannot perform.
- Cancelling the Discard confirmation gives the recording straight back, so the next attempt — here or
  in another window — can start immediately.
- The Discard confirmation says what is actually lost: for a recording the desk has already accepted it
  removes only the copy kept for another transcription attempt and says the recording stays in Work,
  and only for a recording that exists nowhere else does it say it cannot be recovered.
