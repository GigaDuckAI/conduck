# integrate-2 — fix-wave integration (after the five round-1 fixers)

Integrator pass over the five Codex-round-1 fix slices (`desk`, `shortcuts`, `watch`,
`menubar`, `carplay`), on top of the surface wave integrated as `integrate-1`. Slug
`fix-int2`, caches under `~/Library/Caches/gigaduck-builds/fix-int2/`, cleaned with
`.claude/scripts/clean-build-cache.sh fix-int2`.

**Nothing needed an integrator edit.** The tree compiled on the FIRST iOS
`build-for-testing` with 0 errors and the FIRST macOS `build` with 0 errors, the full iOS
suite and the full watch suite were green on their first run, and all six guard scripts
exit 0. No cross-fixer conflict, no compile break, no test failure and no guard failure
survived to this pass, so **no file was changed here** — this note records the
verification, not a diff.

## What changed

None. Zero files edited by this pass.

Three concurrency situations the fixers reported were checked and are settled on disk:

- **`Localizable.xcstrings`, two writers.** `carplay` inserted
  `carplay.hint.captureStartFailed.detail.work`; `shortcuts` inserted
  `intent.workAddFiles.error.noteTooLong`; a claims edit renamed
  `intent.workRecordNote.{title,description}` → `intent.workVoiceNote.{…}`. All three are
  present, in different regions, in the file's shipped row shape. iOS catalog 2,293 →
  **2,295** keys (+2 new, 2 renamed in place). No dangling reference: `intent.workRecordNote`
  appears nowhere in Swift or in any catalog, and every new key has both a call site and a row.
- **`fix-shortcuts`'s duplicate dispatch.** The S2 shell wiring
  (`WorkVoiceCaptureLaunchRoute.isPending` / `revealWorkIfPending()`, plus one `.onAppear`
  each in `RootView.swift` and `ConduckApp.swift`) exists exactly once — one peek accessor,
  one reveal method, two call sites, no duplicated declaration.
- **`fix-menubar`'s second instance.** The reconciled state is what built and ran:
  `MenuBarComposeState.clearCommitted(_:aimedAt:)` has one definition and one production
  caller, `clearActive(ifStillEqualTo:)` is gone from both production and tests, and the S7
  guard `testNoPopoverCloseHookTouchesTheWorkComposition` is present once and green.

## Measured

Full runs, no `-only-testing`, no `-configuration` anywhere.

| Run | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: `, `** TEST BUILD SUCCEEDED **` |
| **iOS full suite** | `Executed 5323 tests, with 1 test skipped and 0 failures (0 unexpected) in 82.016s` — `Test Suite 'All tests' passed`, `** TEST EXECUTE SUCCEEDED **` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: `, `** BUILD SUCCEEDED **`, real signing through the identity override (`Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`) — **no `CODE_SIGNING_ALLOWED=NO` fallback was needed or used** |
| **watchOS full suite** (`ConduckWatchTests`, sim `28AC563B`) | `Executed 262 tests, with 0 failures (0 unexpected) in 9.356s` — exit 0, **0** `: error: `, `** TEST SUCCEEDED **` |

The single iOS skip is the known environment one:
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract` — "No website
source at `…/.codex/worktrees/website/src/lib/adapter-contracts.ts`".

**iOS 5,296 → 5,323 (+27)** and **watch 252 → 262 (+10)**, matching the five fixnotes'
own additions. Each slice's headline regression test was confirmed to have RUN and PASSED
in these full runs rather than merely to exist — `desk`
(`testTheBackfillDecodesTheBytesTheRepairedRowNamesNotTheCanonicalRows`,
`testAStaleReadableTapIsRefusedWhenTheDeskCardIsNoLongerReadable`,
`testBothPlatformsShrinkTheResidencyWindowUnderMemoryPressure`), `menubar`
(`testACommitConsumesTheSlotItTookTheWordsFromEvenAfterTheSurfaceIsReAimed`,
`testNoPopoverCloseHookTouchesTheWorkComposition`), `shortcuts`
(`testTwoFilesAlikeInNameAndSizeButNotInBytesAreDifferentCaptures`,
`testAnOversizedNoteIsRefusedAsANote`), `carplay`
(`testTheWordsAreNotWrittenUnlessThisProcessStillHoldsTheCapture`,
`testTheCompressedScratchCopyIsDeletedOnEveryExitThatNeverReachesTheSpeechHop`,
`testTheMicCouldNotStartHintIsRenderedInTheNoGatewayPickerToo`), `watch` (all ten, including
`testAnUnacknowledgedWorkEntryIsRetainedAfterEveryFailedAttempt` and
`testALateSettlementForAnotherCaptureLeavesTheDisplayedLineAlone`).
`WorkboardCopyTruthGuardTests`: **10 tests, 0 failures**, suite passed.

The iOS build finished in ~25 s with no `SwiftCompile` lines in its log — Xcode's shared
compilation cache, warm from the five fixers' own builds. Not taken on trust: the product
under test is proven current by the new test names above executing in that run.

## Guard scripts

Run from the worktree root, exit codes measured:

| Script | Exit | Note |
|---|---|---|
| `scripts/check-storage-seam.sh` | 0 | 835 Swift files, seam intact |
| `scripts/check-folder-map.sh` | 0 | 36 Swift source directories, all mapped |
| `scripts/check-spec-cites.sh` | 0 | every quoted section name is a live heading |
| `scripts/check-spec-size.sh` | 0 | **16,891 of 16,900 words**, 39 decisions — passes with **9 words of headroom** (see Open items) |
| `scripts/check-legal-copies.sh` | 0 | 3 files byte-identical |
| `scripts/add-spdx-headers.sh --check` | 0 | all tracked source files stamped |

`--check` walks tracked files only; this round added **no** new `.swift` file (and no
`pbxproj` change), so there is nothing untracked to check by hand.

## Mirrors and hygiene

- **Mirror triplets byte-identical** from `import Foundation` onward, verified by digest:
  `WorkCaptureEnvelope.swift`, `WorkCaptureDirectoryPublisher.swift`,
  `ShareTargetsSnapshot.swift` across `Conduck/Conduck/…`, `ConduckShareExtension/`,
  `ConduckShareExtensionMac/`.
- **All four `.xcstrings` parse as JSON**: iOS 2,295 · Watch 316 · `ConduckShareExtension`
  43 · `ConduckShareExtensionMac` 42.
- **Both `Wire` enums identical**: 14 literals, same digest, and neither
  `AppleSpeechRelayCoordinator.swift` was touched this round.
- `git diff --check` clean. No file deleted anywhere in the wave
  (`git diff --name-status HEAD` has no `D`), no stray untracked `.swift`.
- Frozen invariants re-checked at the seam, not just taken from the fixnotes: no envelope
  schema, no `.xcdatamodeld` and no wire string in the diff; `sendQuickTypedDraft`'s
  `guard compose.target == .chat` intact.

## Nobody undo

Nothing added — this pass changed nothing. Every "Nobody undo" from the five fix slices and
the eighteen surface fixnotes stands as written, including the two deliberate
contradictions their authors argued explicitly (`shortcuts` S1 folding a STREAMED digest
into the capture identity against b2's "never bytes", which protected memory and is kept;
`carplay` S1 superseding e-carplay's "the attach is idempotent, no `stillOwnsCapture`
needed", whose premise `applyWorkVoiceTranscript` falsifies).

## Open items (carried, none introduced here)

- **`desk` S3 — Work images have no Share.** Design change, founder's call; recommended
  shape and the reason a new key (`workboard.material.share`, never `common.share`) is in
  `fix-r1-desk.md`.
- **`shortcuts` S2 residual** — a fully-quit Mac whose scene observers install after
  `perform()` opens no window until one is opened by any means; closing it needs an
  `AppDelegate` hook.
- **`shortcuts` open item 2** — the content digest costs one extra sequential read of a set
  that may reach 512 MB; a cheaper identity for very large files is a founder trade, not a
  refactor.
- **`watch` open item** — a permanently-old iPhone can park a Work capture indefinitely
  (Work is exempt from both caps); the compensating bound stays `refusesNewWorkCapture` at
  ten, and an explicit wrist "discard" is a later slice.
- **`integrate-1`'s d1/d2 HUD-precedence question** is untouched and still open.
- **`check-spec-size.sh` has 9 words of headroom.** It passes, and the docs agent owns
  `spec.md` — reported, not edited. Any further spec prose needs a trim somewhere else.
- **Pre-existing Swift-6-mode warnings**, unchanged by this wave and not a regression: the
  macOS build reports 1,407 warnings across the app and its packages, among them
  `ConversationStore+Workboard.swift:2678` (`workThumbnailRepairDecodeWidth` accessed
  outside the actor), which `fix-r1-desk` observed and deliberately left finding-scoped. The
  iOS build reports none of them (warm compilation cache, nothing recompiled).

## Founder QA

`integrate-1`'s five integration-level steps still stand unchanged; each fix slice's own
fixnote carries its delta script. The two highest-value additions from this round, both
data-loss paths that were silent before:

1. **Same name, same size, different bytes.** Run the Add-to-Work shortcut over a
   `memo.txt` containing "alpha", then edit it to "bravo" (same length) and run again.
   *Must be true:* TWO cards, the first still holding "alpha". Run it a third time
   unchanged: still two cards (the repair).
2. **A Work relay that fails keeps the recording.** Record a Work note on the watch with the
   phone unreachable, then bring the phone back. *Must be true:* the wrist ends on "Saved on
   your watch. It reaches Work when your iPhone is nearby." and the card lands later — never
   a failure line with the recording gone. With two deferred captures, the open screen must
   only turn "Saved to Work." for ITS OWN capture.
