# integrate-1 — surface-wave integration

Integrator pass after the nine surface slices (`a2`, `a3`, `b2`, `c1`, `c2`, `c3`, `d1`,
`d2`, `e`) and the two serial copy agents (`copy-ios`, `copy-watch`). The tree compiled
on the FIRST iOS `build-for-testing` with **0 errors** — no cross-slice compile conflict
survived to this pass. Two edits were needed: one re-anchored guard and one mechanical
wiring request. Nothing else was touched, and no slice's mechanism was simplified,
relaxed or reshaped.

## What changed

- **`Conduck/ConduckTests/STTKeyBlackoutLaneTests.swift`** —
  `testTheWristRelayDefersABlackoutInsteadOfClaimingTheQueueEntry` re-anchored from the
  raw flag assignment onto the arms that ASK for the deferral shape plus the helper that
  writes the flag. It now asserts (a) the blackout arm carries `deferred: true`, (b)
  `runRelay`'s body contains exactly two `deferred: true` call sites — the reply-wait
  timeout and the blackout — and (c) `surfaceRelayVerdict`'s own body still contains
  `lastErrorIsRelayDeferral = true`.
  **Reason:** c2's restructure funnels every relay verdict through
  `surfaceRelayVerdict(_:destination:deferred:)`, because the Work lane has no `.error`
  state to borrow and must not enter one. The flag is therefore written once, in the
  funnel, and counting the assignment inside `runRelay` measured the funnel rather than
  the arms — the guard read 0 and failed. This is the re-anchor c1's request 2/4 and the
  brief both name as the sanctioned alternative; c2's fixnote documents the move as
  deliberate. The assertion was NOT deleted: invariant I6 (a blackout never deletes
  queued wrist audio) is still proved end to end, now in two links instead of one.
- **`Conduck/Conduck/MenuBar/MenuBarController.swift`** — `handleShortcutPress`'s
  text-mode arm calls `coordinator.closeWorkOnlyCompose()` before `showPopover()` /
  `dismissPopover()`.
  **Reason:** d2's REQUEST to d1, mechanical and one line. ⌘⇧1 is Chat's door, so it
  leaves the Work-only surface as a NAVIGATION — `closeWorkOnlyCompose` returns to Chat
  without touching what is written, so the Work composition stays parked with its aim and
  is never offered to Chat's Return.

## New API

None — integration only.

## New strings

None. Both catalogs were closed by the two copy agents before this pass; no `.xcstrings`
file was opened here. Final key counts: iOS `Localizable.xcstrings` 2,293 · Watch
`Localizable.xcstrings` 316 · `ConduckShareExtension` 43 · `ConduckShareExtensionMac` 42.
All four parse as JSON.

## Tests

Full suites, no `-only-testing`, no `-configuration`, all under
`~/Library/Caches/gigaduck-builds/work-int1/`.

| Run | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| **iOS full suite** | `Executed 5296 tests, with 1 test skipped and 0 failures (0 unexpected) in 86.063 (88.257) seconds` — `Test Suite 'All tests' passed`, `** TEST EXECUTE SUCCEEDED **` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` — real signing through the identity override (`Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`), no `CODE_SIGNING_ALLOWED=NO` fallback |
| **watchOS full suite** (`ConduckWatchTests`, sim `28AC563B`) | `Executed 252 tests, with 0 failures (0 unexpected) in 9.545 (9.632) seconds` — exit 0, **0** `: error: ` |

The single skip is the known environment one:
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract` — "No
website source at `…/.codex/worktrees/website/src/lib/adapter-contracts.ts`".

Watch count **252 vs the 232 baseline**: +10 from c2 (`WatchRelayQueueRetryabilityTests`
7 → 15, `ConduckWatchSmokeTests` 7 → 9) and +10 from c3's UI assertions. Both slices
report the same 252, and it reproduces here.

The first full iOS run (before the two edits above) was
`Executed 5296 tests, with 1 test skipped and 1 failure` — that one failure was the STT
guard, and it is the only failure the whole wave produced. The eight
`WorkboardCopyTruthGuardTests` failures the brief flagged as KNOWN RED were already
closed by `copy-ios` and did not reappear.

## Guard scripts

Run from the worktree root, exit codes measured:

| Script | Exit | Note |
|---|---|---|
| `scripts/check-storage-seam.sh` | 0 | 835 Swift files, seam intact |
| `scripts/check-folder-map.sh` | 0 | 36 Swift source directories, all mapped — the wave's new files landed in folders that already carry a row |
| `scripts/check-spec-cites.sh` | 0 | every quoted section name is a live heading |
| `scripts/check-spec-size.sh` | 0 | **16,649 of 16,900 words**, 39 decisions — unchanged, so the docs pass still has 251 words of headroom |
| `scripts/check-legal-copies.sh` | 0 | 3 files byte-identical |
| `scripts/add-spdx-headers.sh --check` | 0 | all tracked files stamped |

`--check` only walks TRACKED files, so the eleven new untracked `.swift` files were
checked by hand: every one opens `// SPDX-License-Identifier: Apache-2.0`, a blank line,
then its `// Conduck…` header block.

## Mirrors and hygiene

- **Mirror triplets identical** from `import Foundation` onward, all three ways:
  `WorkCaptureEnvelope.swift`, `WorkCaptureDirectoryPublisher.swift` and
  `ShareTargetsSnapshot.swift` across `Conduck/Conduck/…`, `ConduckShareExtension/` and
  `ConduckShareExtensionMac/`.
- `git diff --check` clean.
- The stray scaffold `MenuBar/MenuBarCoordinator+WorkContract.swift` is gone, and no
  `WatchWorkCaptureContract.swift` stub survives in the Watch target — so the duplicate
  declarations that c1 and b2 both filed as the macOS blocker are resolved, and the macOS
  build above is the trustworthy result they asked for.
- Gateway containment spot-check: no Work surface file
  (`Views/Workboard/`, both new intents, `WatchWorkCaptureView.swift`) mentions
  `startConverseHop`, `startDeferredConverseHop` or `handleQuickSend`.

## Requests

Applied here (small and mechanical):

- **d2 → d1**: `closeWorkOnlyCompose()` in the ⌘⇧1 text-mode arm. Done, above.

Left open — design-level, or owned by an agent still to run:

- **d1 → d2**: a Work capture parked in its retryable-error state keeps
  `workCaptureIsActive == true`, so the Work HUD outranks the popover indefinitely and
  would hide a live chat capture's own HUD. Either the Work HUD yields to a live chat
  capture, or the desk's Try Again gets a smaller surface than a full-height HUD. Both
  fixnotes list the current behaviour under **Nobody undo** (d2 forbids narrowing
  `workCaptureIsActive`; d1 forbids widening the Ask stand-down gate), so this is a
  founder decision, not an integrator edit.
- **a3 → founder**: images no longer offer Share anywhere — Quick Look supplies the system
  share for files and recordings, but the gallery is not a Quick Look surface. If Share
  should return for pictures, its home is the card's context menu in
  `WorkboardCaptureCanvas.swift` and it needs a NEW key (`common.share` was removed as an
  orphan; do not resurrect it).
- **b2 → nobody in this wave**: `TempScratchSweeper.ownedPrefixes` claims
  `conduck-workboard-intake-` only because `conduck-workboard-` is a prefix of it. A
  dedicated entry would read better and touches `AgentDownloadScratch.swift` plus
  `TempScratchSweeperTests`.
- **d2 → whoever next opens `WorkboardVoiceCaptureView.swift`**: route its
  `statusCopy` / `accessibilityStatusMessage` mapping through
  `MenuBarWorkVoiceStatus.resolve` so one recorder state cannot grow two sentences.
  `MenuBarWorkCaptureStateTests.testTheStatusKeysAreTheOnesTheDeskSheetAlreadyRenders` is
  the tripwire until then.
- **Docs pass** (the docs agent owns `spec.md`; nothing here edited it): spec line 298's
  "On CarPlay there is no such place" is now false for the Work lane and must be split by
  lane, not deleted — CarPlay's Work capture preserves through `PendingRetryStore` while
  its Chat lane still preserves nothing. Also outstanding: §Where the surfaces differ
  (CarPlay Work row, Watch relay-for-Work, the Mac ⌃⌘W HUD and Work-only compose state),
  the README per-surface Work row, `project-structure.md`'s three new source files
  (`Intents/AddFilesToWorkIntent.swift`, `Intents/RecordWorkNoteIntent.swift`,
  `Views/Workboard/WorkVoiceCaptureLaunchRoute.swift`), and the truncated
  `/// Pin or unpin one project…` doc comment above `loadWorkMaterial(id:)` in
  `ConversationStore+Workboard.swift`, which documents a function that is not there.
  `check-spec-size.sh` has 251 words of headroom.

## Nobody undo

Every "Nobody undo" from the eighteen fixnotes still stands and was honoured — nothing was
collapsed, inlined or narrowed in this pass. Added here:

- **`STTKeyBlackoutLaneTests`'s deferral check is now a two-link chain, and both links are
  load-bearing.** The `deferred: true` count proves the two arms still ask for the
  deferral shape; the `surfaceRelayVerdict` assertion proves the ask still reaches
  `lastErrorIsRelayDeferral`. Deleting either link leaves the other asserting nothing —
  a funnel nobody calls, or two call sites into a funnel that no longer sets the flag. If
  the funnel is ever inlined back into `runRelay`, restore the original
  `lastErrorIsRelayDeferral = true` count of 2 rather than dropping the check.
- **`closeWorkOnlyCompose()` on ⌘⇧1, never `discardWorkOnlyCompose()`.** The two are
  opposite promises: this call site is a navigation, and losing words to a navigation is
  the exact failure the aim-with-the-words design exists to prevent.

## Founder QA

Each slice's fixnote carries its own script; these are the integration-level checks that
no single slice could run. Build and install this branch on the phone, the Mac and the
watch.

1. **The wave did not move Chat.** On the Mac, ⌘⇧1 in text mode, type a sentence, Return.
   On iPhone, a normal Ask. On the watch, Ask with the phone out of range, then bring it
   back.
   *Must be true:* all three behave exactly as they did before this branch — the Mac
   sentence reaches the chosen gateway, the wrist shows "Sent to iPhone. Your transcript
   will arrive when it reconnects." and then the transcript notification and the reply.
   *Failure to watch for:* anything from these three landing on the Work desk.
2. **⌘⇧1 over a parked Work composition (the edit above).** Press ⌃⌘W in TEXT input mode,
   type a private sentence, do NOT save, click outside to dismiss the popover. Now press
   ⌘⇧1.
   *Must be true:* the popover comes back on the **Chat** surface with the Chat draft,
   Ask visible, and the Return key sends to Chat. Press ⌃⌘W again.
   *Must be true:* the Work surface returns with the private sentence still there, header
   "Add to Work", no Ask affordance.
   *Failure — the one that matters:* the private sentence appearing in the Chat compose
   field, or Return on the Chat surface sending it to a gateway.
3. **Nothing on the desk reaches a gateway.** Do one capture on every new door: Mac ⌃⌘W
   (voice and text), the watch's Save to Work, CarPlay's "Add to Work", the two new
   Shortcuts actions, and the share sheet.
   *Must be true:* each produces a card on the desk and the Conversations list is
   completely unchanged — no new thread, no new turn in an existing one.
4. **The Work HUD versus a live chat capture (the one open item).** On the Mac, start a
   ⌃⌘W voice capture, let it fail its transcript so it sits on Try Again, then press ⌘⇧1
   and speak.
   *Known behaviour, not a bug to report unless you dislike it:* the chat recording DOES
   start and its own HUD is hidden behind the Work HUD until you finish the Work capture.
   This is the open design question above — your call on which one should yield.
5. **The catalogs.** Change the system language to German and open: the desk, the Mac
   popover's Work surface, the watch's Save to Work screen, the CarPlay picker.
   *Must be true:* nothing shows a raw key (`workboard.menuBar.…`). English text in a
   German UI is expected for the new rows and is not a failure; a bare dotted key is.
   The three spoken CarPlay lines are deliberately English-only, matching the "Talk to you
   later." baseline.

## Open questions

- The d1/d2 HUD-precedence question above is the only cross-slice behaviour this pass
  found and deliberately did not decide.
- Carried forward, unresolved and out of this wave: `sourceDevice` on a capture recovered
  through `PendingRetryStore` reads as the RECOVERING device, because the retry metadata
  carries no `sourceDevice` field. The wrist and the car stamp correctly on the happy
  path; a recovered one will say phone.
- Also carried forward: f3's deliberate flicker — a gallery page released under memory
  pressure at 6x briefly shows a magnified thumbnail before the original re-decodes.
