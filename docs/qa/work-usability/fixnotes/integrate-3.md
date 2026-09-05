# integrate-3 — fix-wave integration (after the four Codex-round-2 fixers)

Integrator pass over the four round-2 fix slices (`shortcuts`, `watch`, `menubar`,
`carplay`), on top of `integrate-2`. Slug `fix2-int3`, caches under
`~/Library/Caches/gigaduck-builds/fix2-int3/`, cleaned with
`.claude/scripts/clean-build-cache.sh fix2-int3`. No `-configuration` flag anywhere; one
`xcodebuild` at a time; no simulator kill/retry was needed.

**Nothing needed an integrator edit.** The tree compiled on the FIRST iOS
`build-for-testing` with 0 errors and the FIRST macOS `build` with 0 errors, the full iOS
suite and the full watch suite were green on their first run, and all six guard scripts
exit 0. No cross-fixer conflict, no compile break, no test failure, no guard failure. **Zero
files changed by this pass** — this note records the verification, not a diff.

## What changed

None.

### Cross-fixer contention, checked on disk

- **Production files do not overlap.** `shortcuts` → `AddFilesToWorkIntent.swift`,
  `AppDelegate.swift`; `watch` → `Services/AppleSpeechRelayCoordinator.swift` (phone) plus
  three Watch-app files; `menubar` → `MenuBar/MenuBarCoordinator.swift`,
  `MenuBar/MenuBarController.swift`; `carplay` → `CarPlay/CarPlayRecordingService.swift`,
  `CarPlay/CarPlaySceneDelegate.swift`. Eight production files, four disjoint sets. Same for
  the nine test files.
- **`.xcstrings`, one writer each this round** (unlike round 1's three-way iOS contention):
  `menubar` added the single iOS row, `watch` added the two Watch rows. Both catalogs
  re-parsed after the merge; the additions are pure inserts, no existing row's value edited.
- **`carplay` reported hitting 4 errors in `shortcuts`'s in-flight `AddFilesToWorkIntent.swift`
  and waiting rather than editing it** — the correct move; the settled file builds clean here.

### Fixer-claimed test counts, reconciled against HEAD

Every claimed addition is present and nothing was silently dropped:

| File | HEAD → now |
|---|---|
| `WorkShortcutIntentsTests.swift` | 25 → 27 |
| `WorkCaptureFileCaptureTests.swift` | 9 → 10 |
| `WatchWorkRelayPhoneTests.swift` | 13 → 18 |
| `RelayReplyCacheTests.swift` | 9 → 10 |
| `MenuBarWorkCaptureStateTests.swift` | 26 → 28 |
| `MacMenuBarWorkShortcutDriftGuardTests.swift` | 12 → 13 |
| `CarPlayWorkNoteTests.swift` | 21 → 22 |
| `ConduckWatchSmokeTests.swift` | 21 → 23 |
| `WatchRelayQueueRetryabilityTests.swift` | 25 → 30 |

iOS +13 and watch +7 — exactly the suite deltas measured below, so no test was lost to a
merge. One apparent gap resolves cleanly: `shortcuts` names three new cases in
`WorkShortcutIntentsTests` but the file is +2, because
`testAnUnreadableSourceIsNotTheSameCaptureAsAnEmptyFile` was **replaced** by
`testAnUnreadableSourceRefusesTheCaptureInsteadOfNamingIt` — the all-zero unreadable
sentinel it pinned no longer exists, so pinning it would pin a removed behaviour. Name-set
diff confirms that is the only removal in the wave.

## Measured

Full runs, no `-only-testing`.

| Run | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: `, `** TEST BUILD SUCCEEDED **` |
| **iOS full suite** | `Executed 5336 tests, with 1 test skipped and 0 failures (0 unexpected) in 84.274s` — `Test Suite 'All tests' passed`, `** TEST EXECUTE SUCCEEDED **` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: `, `** BUILD SUCCEEDED **`, real signing through the identity override (`Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`) — no `CODE_SIGNING_ALLOWED=NO` fallback |
| **watchOS full suite** (`ConduckWatchTests`, sim `28AC563B`) | `Executed 269 tests, with 0 failures (0 unexpected) in 9.398s` — exit 0, **0** `: error: `, `** TEST SUCCEEDED **` |

**iOS 5,323 → 5,336 (+13)** and **watch 262 → 269 (+7)**.

The single iOS skip is the known environment one:
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract` — "No website
source at `…/.codex/worktrees/website/src/lib/adapter-contracts.ts`".

**Note on `grep -c ': error: '` for TEST logs.** The iOS full-suite log contains 1,887
`: error: ` lines and they are NOT compile errors — they are `CoreData: error:` runtime noise
from the deliberate negative fixtures (`Failed to stat path '/nonexistent-…/store.sqlite'`,
`Sandbox access to file-write-create denied`). That count is meaningful on BUILD logs only,
where it is 0 for both iOS and macOS. The suite verdict is the `Executed …` line above.

Each slice's headline regression test was confirmed to have RUN and PASSED in the full runs,
not merely to exist:

- `shortcuts` — `testASourceRewrittenAfterItsIdentityCannotPublishUnderTheEarlierCapture`,
  `testTheSnapshotFreezesTheBytesTheIdentityWasTakenOver`,
  `testAnUnreadableSourceRefusesTheCaptureInsteadOfNamingIt`,
  `testTheMacLifetimeOpensAWindowForARequestThatArrivedBeforeAnyExisted`
- `menubar` — `testTheWorkVoiceStartPinsThePopoverBeforeTheRecordingIsLive`,
  `testTheWorkVoiceSummonTakesThePopoverBeforeItShowsIt`,
  `testTheVoiceReceiptNamesItsSpeechProviderAndTheTypedNoteKeepsItsInertness`
- `carplay` — `testASilentStartupFailureEndsTheSessionAndThenDrivesTheSceneItself`
- `watch` — the seven new cases inside `WatchWorkRelayPhoneTests` (18/0),
  `RelayReplyCacheTests` (10/0), `WatchRelayQueueRetryabilityTests` and
  `ConduckWatchSmokeTests` in the 269-test watch run.

`WorkboardCopyTruthGuardTests`: **10 tests, 0 failures**, suite passed — the environmental
restart `menubar` saw in its own six-suite run did not recur here.

Frozen-contract suites all green in the same run: `RelayWireContractTests` (7/0),
`RelayWireSourceDriftGuardTests` (1/0), `WorkDeskWriteOwnershipDriftGuardTests`,
`WorkboardDeskSurfaceDriftGuardTests`, `WorkboardBlobSeamPlatformGuardTests`,
`HeadlessRefusalLaneDriftGuardTests`, `MacMenuBarWorkShortcutDriftGuardTests`,
`MacWorkbenchShellDriftGuardTests`, `ErrorSurfaceDriftGuardTests`,
`CarPlayVoiceTimingContractTests`, `TempScratchLeafDriftGuardTests`,
`LoggingPrivacyDriftGuardTests`.

## Guard scripts

Run from the worktree root, exit codes measured:

| Script | Exit | Note |
|---|---|---|
| `scripts/check-storage-seam.sh` | 0 | 835 Swift files, seam intact |
| `scripts/check-folder-map.sh` | 0 | 36 Swift source directories, all mapped |
| `scripts/check-spec-cites.sh` | 0 | every quoted section name is a live heading |
| `scripts/check-spec-size.sh` | 0 | 16,891 of 16,900 words, 39 decisions — unchanged from `integrate-2`, still **9 words of headroom** |
| `scripts/check-legal-copies.sh` | 0 | 3 files byte-identical |
| `scripts/add-spdx-headers.sh --check` | 0 | all tracked source files stamped |

This round added **no** new `.swift` file and made **no** `pbxproj` change, so `--check`'s
tracked-only walk leaves nothing to check by hand.

## Mirrors, wire and hygiene

- **Mirror triplets byte-identical** from `import Foundation` onward, verified by SHA-256:
  `WorkCaptureEnvelope.swift` (`45a26a6658c92401`), `WorkCaptureDirectoryPublisher.swift`
  (`777159cc94c1cd9a`), `ShareTargetsSnapshot.swift` (`a72a7d13d6f1e9ec`) across
  `Conduck/Conduck/…`, `ConduckShareExtension/`, `ConduckShareExtensionMac/`.
- **Both `Wire` enums: 14 literals, identical, unchanged.** The phone
  `AppleSpeechRelayCoordinator.swift` was edited by `watch` but its `enum Wire` block diffs
  **empty** against `HEAD`; the Watch copy of the file is untouched entirely. Literal-line
  diff between the two enums is empty (only the surrounding doc comments differ, as they
  always have). `result.work` and `result.text` were both already present — the watch fix
  spends the EXISTING keys, adding none.
- **All four `.xcstrings` parse as JSON with no duplicate keys** (checked at every nesting
  level, not just the top): iOS **2,296** · Watch **318** · `ConduckShareExtension` 43 ·
  `ConduckShareExtensionMac` 42. That is 2,295 → 2,296 (+1) and 316 → 318 (+2), matching the
  three new rows exactly.
- **Three new copy keys, all NEW keys with a production call site and a row**:
  `workboard.menuBar.voice.saved` → `MenuBarCoordinator.swift`;
  `watch.work.capture.savedWithoutWords` → `WatchWorkCaptureView.swift`;
  `watch.work.notification.savedWithoutWords` → `AppleRelayPendingQueue.swift`. No existing
  row's value was edited anywhere in the diff.
- `git diff --check` clean. No file deleted (`git diff --name-status HEAD` has no `D`), no
  stray untracked `.swift`, no untracked scratch left behind — the only untracked paths are
  the four `fix-r2-*.md` fixnotes, this `integrate-3.md`, and the six `codex-r2-*.json`
  verify files.
- **Frozen invariants re-checked at the seam**, not taken from the fixnotes: no
  `.xcdatamodeld`, no `pbxproj`, no envelope-schema file in the diff;
  `sendQuickTypedDraft`'s `guard compose.target == .chat` intact at
  `MenuBarCoordinator.swift:1800`. Every added string literal in production Swift was
  enumerated: `"result.text"`, `"End"`, `"failed"` and `"main"` appear only inside doc
  comments, and the one real new literal — `case .savedWithoutWords: return "withoutWords"`
  in `WatchWorkCaptureView.logLabel(for:)` — is a diagnostics label with a single occurrence
  in the whole Watch app, not a wire key.

## Nobody undo

Nothing added — this pass changed nothing. Every round-1 and round-2 "Nobody undo" stands as
written, including the four deliberate contradictions their authors argued explicitly in
their own fixnotes:

1. `shortcuts` R1 disproves **half** of b2's *"`file.fileURL` is handed over unread"* — the
   memory premise (streamed, `.data` only for URL-less files) is preserved; only its safety
   conclusion falls, and `fix-r2-shortcuts.md:62-66` names both premises and argues each.
2. `shortcuts` round-1's names-and-sizes entry, superseded by the streamed digest with the
   memory constraint kept.
3. `carplay` round-1's S1 superseding `e-carplay`'s "the attach is idempotent, no
   `stillOwnsCapture` needed" — still standing, and `codex-r2-cross` R5 flags that the
   handoff restored the disproven rationale. **Docs item, not mine to edit.**
4. `menubar` R1 explicitly did NOT extend the S7 close-hook guard's denylist: both close-hook
   bodies are byte-identical to round 1, verified in the diff.

No entry's premise was disproved without being argued in the owning fixnote.

## Open items (carried and new; none introduced by this pass)

- **`desk` R1 / cross S5 — Work images have no Share.** Founder's call, still open; the
  recommended shape and the reason it needs a new key (`workboard.material.share`, never
  `common.share`) are in `fix-r1-desk.md`.
- **`codex-r2-cross` R4** — the README's incorrect no-transfer promise. **Docs agent's file**;
  not touched here.
- **`codex-r2-cross` R5** — the handoff restored the ownership rationale `carplay` disproved.
  **Docs agent's file**; `carplay` messaged the docs pass with specifics.
- **`watch` closes handoff U-22** (a terminal transcription failure on a work relay told the
  wrist the wrong story) and answers `c1-phone-relay.md`'s open question 1. Both live in files
  the docs agent owns — U-22 should be struck.
- **Still open on the watch lane, and NOT this round's findings:** U-21 (an empty transcript
  on the OLD-phone words-only path parks the entry) and U-23 (a double capture-id collision
  has no exit).
- **`watch` side effect worth knowing:** an ordinary SUCCESS whose transcript is empty (a
  silent clip) now lands on "Saved to Work. Add the words on your iPhone." instead of a clean
  save line.
- **`shortcuts` cost:** peak scratch for a URL-backed file set roughly doubles (~1 GB at the
  512 MB ceiling) between the snapshot and the queue's copy; the lever is a MOVE entry point
  on `WorkCaptureInbox`, deliberately not taken because that publisher has three other
  callers. Capture ids differ from the previous build's for the same files — nothing has
  shipped and an older envelope drains under its own id, so no migration.
- **`check-spec-size.sh` still has 9 words of headroom.** It passes; the docs agent owns
  `spec.md`, so any further spec prose needs a trim elsewhere. Reported, not edited.
- **`integrate-1`'s d1/d2 HUD-precedence question** remains open and untouched.
- **Pre-existing Swift-6-mode warnings** unchanged and not a regression.

## Founder QA

`integrate-1` and `integrate-2`'s scripts still stand. The three highest-value additions from
this round, each a silent failure before:

1. **A file edited between two runs of Add-to-Work.** Run the shortcut over `memo.txt`
   containing "alpha"; while it is running (or immediately after), rewrite the file to
   "bravo". *Must be true:* the published card holds "alpha" — the bytes the id was taken
   over — and the rewritten file is a different capture, never a repoint of the first card.
   A file that cannot be read at all must now REFUSE with "couldn't be read", never land as a
   named empty card.
2. **A Work note dictated on the Mac with the app fully quit.** Trigger the Shortcuts voice
   note from a cold Mac. *Must be true:* a window opens by itself within about a second and
   the composer holds the words — no longer a note stranded until you open a window by hand.
   Then, on the menu bar: start ⌃⌘W voice and click away mid-startup — the popover must stay
   and the recording must begin; and the completion receipt must read "Added to Work. The
   words came from your speech provider.", while a TYPED quick note still reads "Added to
   Work. Nothing was sent."
3. **CarPlay with the microphone unavailable.** Start "Add to Work" in CarPlay with the mic
   blocked (another app holding it, or permission off). *Must be true:* the Listening modal
   dismisses itself and the picker comes back showing "Mic couldn't start" — previously the
   screen stuck on a dead session whose End button did nothing.
