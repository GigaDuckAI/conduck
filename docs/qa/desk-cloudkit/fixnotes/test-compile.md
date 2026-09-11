# test-compile — make `ConduckTests` compile after the core purge. DONE, bundle builds and every named class is green.

Serial phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. `Localizable.xcstrings` NOT opened. Nothing under `docs/qa/desk-cloudkit/` touched. Only `Conduck/ConduckTests/` was edited.

**Important state note:** when I opened the tree the test surgery was ALREADY PRESENT in the working tree (files stamped 19:05–19:06, ~3 minutes before my session started; `purge-core.md` says it did not touch `ConduckTests`, so an earlier run of this same label landed the edits and stopped before verifying or writing a fixnote). I did not take that on trust: I re-derived the worklist from `purge-core.md` §8, re-grepped every deleted symbol against the whole test bundle, read every diff hunk to confirm no surviving assertion was weakened, and then ran the build and the tests myself. Everything below is what the tree now contains and what I verified.

---

## 1. Deleted whole (6 files, 41 cases)

Each verified by reading the pre-purge file and confirming EVERY top-level symbol it exercises is gone from source — not by filename.

| File | Cases | Subject (all deleted) |
|---|---:|---|
| `WorkBriefAssistantTests.swift` | 4 | `WorkBriefAssistant`, `…Availability`, `…Error` |
| `WorkBriefPromptBuilderTests.swift` | 10 | `WorkBriefPromptBuilder`, `WorkBriefMaterialPacket`, `WorkboardBriefingBuilder` — also DECLARED `WorkBriefFixtures` |
| `WorkItemStateResolverTests.swift` | 8 | `WorkItemStateResolver` |
| `WorkboardDispatchCoordinatorTests.swift` | 8 | `WorkboardDispatchCoordinator`, `…Request`, `…Error`, `WorkboardPromptComposer` |
| `WorkboardUploadJournalTests.swift` | 6 | `WorkboardUploadJournal`, `WorkboardUploadReclaiming` |
| `WorkboardOrderingTests.swift` | 5 | `WorkboardBoardOrdering`, `WorkboardPresentationLogic` |

`WorkBriefFixtures`: `grep -rn "WorkBriefFixtures" --include="*.swift" .` over the whole repo returns **nothing**. It died with its declaring file; no re-home was needed.

## 2. Split files — cases excised (33)

Only cases/helpers that referenced deleted symbols. No surviving assertion weakened, no unrelated assertion touched. Where a case name carried a dead clause the name was trimmed rather than the case dropped (one instance, marked).

| File | Excised case | Why |
|---|---|---|
| `ConversationStoreAtomicWorkCaptureTests.swift` | `testMovingBetweenPinCohortsClearsTheOldBoardRank` (+ its whole enclosing class `ConversationStoreWorkItemMutationTests` and its `revision(for:)` helper) | `WorkItemBoardReorder`, `WorkItemBoardPosition`, `reorderWorkItems`, `saveWorkItemDraft` |
| `ConversationStoreWorkCaptureTests.swift` | (no case) — one line: `XCTAssertTrue(item.dispatches.isEmpty)` | `WorkItemRecord.dispatches` deleted; the assertion is now structural, not vacuous coverage |
| `WorkCaptureDrainerTests.swift` | `testDoneTargetFallsBackUnlessThisCaptureHadAlreadyStartedAppending` + 3 `dispatches.isEmpty` lines | `store.completeWorkItem`, `.done` targeting, `WorkItemRecord.dispatches`. Header line "stale-target fallback" → "missing-target fallback" (present tense, the surviving behaviour) |
| `WorkboardBoardProjectionTests.swift` | `testStaleDispatchReceiptCannotOverwriteANewerLoadedSnapshot` · `testReceiptAtTheSameRevisionStillWins` · `testAnyOperationResultAtAnOlderRevisionIsDropped` · `testSearchMatchesTheStoredCorpusAcrossMaterialsAndReplies` · `testEmptinessProbeAgreesWithTheFullDerivationWithoutBuildingIt` · `testTypingDefersTheAppliedNeedleWhileClearingAppliesAtOnce` · `testNeighbourIndexAnswersExactlyWhatMovePlanningWould` · `testAbandoningAProvisionalCanvasClearsItsComposerFlag` (+ the `BoardGate` helper class) | `WorkboardDispatchReceipt`, `WorkboardRunSnapshot`, `WorkboardPresentationLogic`, `transition`, `dispatch`, `setState`, `visibleItems`, `updateSearchText`, `cancelProvisionalWorkspace` |
| `WorkboardLiveRepositorySupportTests.swift` | `testSearchReachesEveryBriefMaterialAndRunFieldRegardlessOfCase` · `testSearchCorpusOfAnEmptyBriefCarriesNoContent` | `WorkboardPresentationLogic.matches`, `WorkboardItemSnapshot.searchCorpus`, `WorkboardRunSnapshot` |
| `WorkboardMaterialBoardActionsTests.swift` | `testShapingTranscriptCarriesCollectedThoughtsAndStaysBounded` · `testAVoiceTranscriptIsANoteCardTheShapingSourceCanSee` · `testShapingTranscriptOfAThoughtOnlyBriefIsNotEmpty`; inside 2 surviving cases the `showEditor`/`editingDraft`/`lastSentRevision`/`hasChangesSinceLastSend` lines; in `makeViewModel` the 9 dead `Dependencies` closures | `WorkBriefShapingSource`, `WorkBriefFixtures`, `WorkboardEditDraft`, `WorkboardViewModel.Dependencies` reshaped |
| `WorkboardPersistenceTests.swift` | `testPrepareRevalidatesApprovedRevisionAndNeverMovesUpdatedAtBackward` · `testRecentWorkItemSummariesAreBoundedOpenAndModifiedFirst` · `testBriefFieldsBeyondTheSharedBoundAreRefusedNotTruncated` · `testDuplicateCopiesMaterialsToFreshIdentitiesAndDistinctVaultKeys` · `testDuplicateFailurePartWayThroughLeavesNoCardAndNoOrphanBytes` · `testAtomicPrepareIsIdempotentAndStateFollowsExactMessageStatus` · `testReviewAcknowledgementTargetsOneExactRunAndLeavesSiblingResultVisible` · `testWorkRunNeverClaimsReplyFromLaterOrdinaryTurn` · `testSentWorkRunStopsLookingForReplyAtNextUserTurn` · `testDeleteAllKeepsAnAlreadyTombstonedRunsOriginalRemovalDate` · `testResizingACardIsInvisibleToDivergenceAndToAnApprovedPreflight` · `testDuplicatingACardKeepsTheArrangementItWasGiven` · `testDeleteAllConversationsPreservesBriefMaterialsAndTombstonesRun` (RE-HOMED, see §3) | `WorkDispatchPreparation`, `WorkBriefSnapshot`, `WorkMaterialSnapshot`, `WorkboardMaterialVersion`, `prepareWorkDispatch`, `acknowledgeWorkDispatchReview`, `duplicateWorkItem`, `updateWorkItem`, `completeWorkItem`, `reopenWorkItem`, `fetchRecentWorkItemSummaries` |
| `WorkboardWorkspaceCaptureTests.swift` | `testNewWorkDoesNotPersistUntilFirstCapture` · `testReviewAndSendWithoutABriefRaisesAFocusRequestWithoutReachingPreflight` · `testEditorReviewAndSendWithoutAnObjectiveRaisesAFocusRequestWithoutReachingPreflight` · `testSmallTextFileCanUseTextOnlyGatewayWithoutSyncedExtract` · `testFailedFirstMaterialKeepsNewWorkProvisionalAndLeavesNoDraft` · `testLiveInvalidFirstMaterialDoesNotCreateAStoredOwner` · `testSuspendedSaveStillPersistsLaterKeystrokes` · `testRenamingAProjectWritesOnlyTheTitleThroughTheDraftStorePath` · `testRenamingToTheSameNameWritesNothing` · `testPinningAndUnpinningNeverTouchesTheBriefOrItsRevision` · `testPinningAnItemTheBoardNoLongerHoldsIsASilentRefusal` · `testRenamingAnItemTheBoardNoLongerHoldsReportsTheFailure`; **RENAMED not deleted:** `testLaterThoughtBecomesAChronologicalNoteWithoutDispatching` → `testLaterThoughtBecomesAChronologicalNote` (only its `harness.dispatchCount == 0` line went; every capture assertion is intact) | `beginWorkspace`, `provisionalWorkspaceID`, `showEditor`, `saveEditorNow`, `reviewEditorAndSend`, `reviewWorkspaceAndSend`, `requestRename`, `commitRename`, `setPinned`, `WorkboardGatewayChoice`, `WorkboardEditDraft` |

Surviving-case counts per split file: `WorkboardWorkspaceCaptureTests` 5 · `WorkboardPersistenceTests` 7 · `WorkboardBoardProjectionTests` 2 · `WorkboardMaterialBoardActionsTests` 12 · `WorkboardLiveRepositorySupportTests` 3 · `ConversationStoreAtomicWorkCaptureTests` 3 · `ConversationStoreWorkCaptureTests` 5 · `WorkCaptureDrainerTests` 5.

**Deviations from scout §6, all verified against post-purge source:**
- `WorkCaptureDrainerTests` (scout: "survives entirely") loses 1 case — `completeWorkItem` is deleted. Matches `purge-core.md` §8.
- `ConversationStoreWorkCaptureTests` (scout: "survives entirely") loses 1 line, 0 cases.
- `WorkboardLiveRepositorySupportTests` loses 2 cases, not the 3 scout predicted (3 survive, not 2): the batched-turn-lookup case at the old `:49` reads only `store.fetchMessages(conversationIDsByMessageID:)`, which is untouched.
- `WorkboardBoardProjectionTests` keeps 2 cases, not the 1 scout predicted: `testLaneOrderIsDerivedFromAttentionRank` reads only `WorkItemState.attentionOrder`/`.attentionRank`, both alive (see Requests #1 — they die with the view trim).

## 3. Re-homed invariant

`testDeleteAllConversationsPreservesBriefMaterialsAndTombstonesRun` → **`testDeleteAllConversationsPreservesWorkMaterials`**, same file (`WorkboardPersistenceTests.swift:57`). The surviving half is intact and slightly stronger: it now creates a real conversation + message, calls `deleteAll()`, and asserts BOTH that the conversation is gone and that `preserved.materials.map(\.id) == [material.id]` — the original inferred the Chat side from the dispatch tombstone, which no longer exists. Doc comment: "Erasing every conversation is a Chat operation. Collected material is the person's own desk and outlives it."

## 4. `ErrorSurfaceDriftGuardTests` — NOT touched, verified row by row

Only two registry rows name Workboard surfaces, and both surfaces are alive with their retry control intact:
- `Conduck/Views/Workboard/WorkboardView.swift` → `.notErrorDriven`; the load-retry control is at `WorkboardView.swift:344` (`"workboard.load.retry"`) inside the surviving `WorkboardDetailColumn` load-error branch.
- `Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift` → `.gated(tokens: ["isRetryable"])`; `WorkboardVoiceCaptureView.swift:195` still reads `error.isRetryable`.

No row pruned. Suite runs 7/7 green (§6). This confirms `purge-core.md` §8's delta against scout R3 rather than the scout.

## 5. No desk-semantics adaptation

Nothing was adapted to desk semantics, and no assertion was weakened to reach green. There is **no expected-semantics-shift failure to report** — every excised case had a *deleted* subject, so nothing was left compiling-but-wrong.

## 6. Gates run (exact lines)

Slug `desk-test-compile`, derivedData `~/Library/Caches/gigaduck-builds/desk-test-compile/DerivedData`, logs written there and grepped (not judged from tail or exit code). No `-configuration` passed anywhere.

**Build** — `xcodebuild build-for-testing -project …/Conduck.xcodeproj -scheme Conduck -destination 'platform=iOS Simulator,id=04DEF4F5-C144-4936-AEC3-A971B4FA9CDC'` → `bft-1.log`:
```
grep -c ': error: '  →  0
** TEST BUILD SUCCEEDED **
```

**Targeted tests** — one `test-without-building` run, 18 quoted `-only-testing:` flags → `test-1.log`. `** TEST EXECUTE SUCCEEDED **`, and per class:

| Class | Result |
|---|---|
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.029 (0.030) seconds` |
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.430 (0.431) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.915 (2.917) seconds` |
| `GatewayFixRouteLandingDriftGuardTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.098 (0.101) seconds` |
| `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 1.128 (1.129) seconds` |
| `WorkAssetVaultTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.067 (0.069) seconds` |
| `WorkCaptureDrainerTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.071 (0.073) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.142 (0.148) seconds` |
| `WorkCaptureRefreshCoordinatorTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 1.005 (1.007) seconds` |
| `WorkMaterialStoragePolicyTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.003 (0.004) seconds` |
| `WorkboardBoardProjectionTests` | `Executed 2 tests, with 0 failures (0 unexpected) in 0.001 (0.002) seconds` |
| `WorkboardLiveRepositorySupportTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.009 (0.010) seconds` |
| `WorkboardMaterialBoardActionsTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.018 (0.021) seconds` |
| `WorkboardMaterialPresentationTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds` |
| `WorkboardModelMigrationTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 1.317 (1.318) seconds` |
| `WorkboardMosaicEngineTests` | `Executed 26 tests, with 0 failures (0 unexpected) in 0.043 (0.048) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.045 (0.047) seconds` |
| `WorkboardWorkspaceCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.007 (0.008) seconds` |
| **total** | `Executed 152 tests, with 0 failures (0 unexpected) in 7.331 (7.370) seconds` |

**Toolbar / MainWindow / Workbench classes**: I grepped `ConduckTests/` for `MainWindow`, `Toolbar`, `toolbar`, `Workbench`, `principal`, `SectionControl`, `ToolbarItem`. **There is no toolbar-anchor or MainWindow test class.** The only hits are two source-path drift guards that scan `Conduck/Views/Conversation/MainWindowView.swift` as a string — `HeadlessRefusalLaneDriftGuardTests` and `GatewayFixRouteLandingDriftGuardTests`, both in `RemoteAgent/HeadlessRefusalLaneDriftGuardTests.swift`. Both are in the table above and both pass. The plan §B "existing toolbar tests" the shell rewrite must re-verify mid-workflow are these two path-scanning guards, nothing more.

**Extra run (not in my brief, worth correcting the record)** — `purge-core.md` §8 predicted `ShareTargetsSnapshotTests` and `ShareTargetsSnapshotWriterColorTests` would compile-but-FAIL on the now-empty `recentWorkItems`. They do **not**:
```
Test Suite 'ShareTargetsSnapshotTests' … Executed 9 tests, with 0 failures (0 unexpected) in 0.026 (0.028) seconds
Test Suite 'ShareTargetsSnapshotWriterColorTests' … Executed 8 tests, with 0 failures (0 unexpected) in 0.006 (0.015) seconds
** TEST EXECUTE SUCCEEDED **
```
They build snapshots directly rather than through `ShareTargetsSnapshotWriter.build()`, so the empty-list change does not reach them.

**FAILING TESTS: none.** Zero failures across the 169 cases I ran, unexpected or otherwise.

**Not run, stated plainly:** the FULL iOS suite and the watch suite. My brief was build-for-testing plus the named classes, and the full-suite gate is the orchestrator's. The bundle compiles clean, so a full run is safe to attempt. Predicted count for the orchestrator, UNVERIFIED: `grep -c "func test"` over `ConduckTests/` is now **4789**; minus the 109 macOS-guarded cases scout §6 measured at baseline that gives ≈**4680 executed**, against scout's predicted 4669 (the difference is foundation's 9 new cases plus the two files scout listed as surviving entirely that in fact lost 1 case each and the `WorkboardLiveRepositorySupportTests`/`WorkboardBoardProjectionTests` counts above). Treat 4680 as an estimate, not a gate value.

`git diff --check` → clean. Build cache removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-test-compile` (so `bft-1.log`, `test-1.log`, `test-2.log` no longer exist — re-run if you need them).

---

## Catalog

**Keys I ADDED in source: NONE.** I edited only `ConduckTests/`; no `String(localized:defaultValue:)` was added or removed, and `Localizable.xcstrings` was never opened.

**Keys I found DEAD: NONE new.** Test files do not own catalog keys, so my surgery contributes nothing to the bidirectional audit beyond what `purge-core.md` already listed.

---

## Requests

1. **View-trim agent (blocking for you):** `WorkboardBoardProjectionTests.testLaneOrderIsDerivedFromAttentionRank` asserts `WorkItemState.attentionOrder == [.review, .waiting, .draft, .done]` and that `attentionRank` is contiguous. Both live in the `extension WorkItemState` at `WorkboardComponents.swift:112-126`, which `purge-core.md` §Requests 2 puts on your delete table. When you delete that extension **delete this case too** — it is the only remaining consumer, and `WorkboardBoardProjectionTests` then holds one case (`testComposerFlagTracksNormalizedEmptinessRatherThanRawText`). Do not "fix" it by keeping the extension alive.
2. **Phase-5 test-surgery agent — real coverage gap opened by the purge:** `WorkboardLiveRepository.presentationKind(_:)` and `.materialName(_:)` SURVIVE (re-homed by purge-core) but now have **zero test coverage anywhere** — `grep -rn "presentationKind\|materialName" ConduckTests/` returns nothing. Their only cover was `WorkBriefPromptBuilderTests` (10 cases, deleted whole) and `WorkboardMaterialBoardActionsTests.testAVoiceTranscriptIsANoteCardTheShapingSourceCanSee` (excised — it also held the `.transcript → .note` mapping, which matters more now that `.audio` cards are coming in plan §D). I did not write replacements: my brief was compile-only and the plan §F new-test list does not name them. Please add a small direct table test over both functions, including foundation's `case .file, .audio: return .file` and the `.unknown → filename/hasPayload ? .file : .note` rule.
3. **Capture agent (plan §A):** three first-capture invariants died with `beginWorkspace`/`provisionalWorkspaceID` and have no equivalent left — `testNewWorkDoesNotPersistUntilFirstCapture`, `testFailedFirstMaterialKeepsNewWorkProvisionalAndLeavesNoDraft`, `testLiveInvalidFirstMaterialDoesNotCreateAStoredOwner` (that last one drove the live repository, not a harness: an invalid first material must leave NO stored owner row). The desk equivalent — a failed first capture must not leave a half-created desk row — belongs in your `upsertDeskMaterial` tests.
4. **Byte-sync agent:** `WorkboardPersistenceTests.testCaptureIdempotencyAndLocalMaterialPrivacy` still asserts `material.storageMode == .localVault` with the message *"file bytes stay off the CloudKit model, even when small"* for a 10-byte `.file`. That is the pre-policy truth and `WorkMaterialStoragePolicy.mode(kind:byteSize:)` will flip it to `.syncedPayload`. **Change the assertion when you wire the policy, and rewrite that message** — do not leave it as a stale claim. It is the one surviving assertion I could see that byte-sync must deliberately update, and I left it exactly as it was per "do not adapt to desk semantics yet".
5. **Orchestrator:** the full iOS suite and the watch suite are unrun by me (§6). Nothing in the watch target was touched by this slice, so `ConduckWatchSmokeTests` should still be 229/0.
