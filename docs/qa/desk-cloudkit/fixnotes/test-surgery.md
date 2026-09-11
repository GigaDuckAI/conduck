# test-surgery — phase-5 test bundle to current product truth. DONE. Full iOS suite 4758 / 1 skip / 0 failures.

Serial phase, alone in the tree. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No `.xcstrings` file opened** (§Catalog). Slug `desk-test-surgery` cleaned (`removed: desk-test-surgery`) — the logs no longer exist; every result line below is quoted verbatim from them before deletion.

I edited exactly FIVE files, all in `Conduck/ConduckTests/`, none of them a 2a agent's new file:
- `ConversationStoreAtomicWorkCaptureTests.swift`
- `WorkCaptureDrainerTests.swift`
- `WorkboardDeskUpsertTests.swift`
- `WorkboardPersistenceTests.swift`
- `WorkboardLiveRepositorySupportTests.swift`

`WorkboardTwoStoreLoadTests`, `WorkboardBlobPublicationTests`, `WorkboardBlobGCTests`, `WorkboardAvailabilityTests` were **not opened for editing** — only read and run.

**Headline: the four remaining failures were exactly the four blob-io §Requests 1 / availability §Requests 3 predicted, all of them the plan's intended lane flip, and all four are now fixed. Nothing else in the suite was red, and nothing new went red.** I found and fixed no additional failure, and I classified nothing as a product bug.

**State note the next agent needs:** the tree HEAD moved since integrate-a. `git log --oneline -3` is now `4165c74 refactor(workboard): one fixed desk…` / `6d46890 docs(workboard)…` / `136e088 feat(workboard): Conversations 16…`, so most of the earlier waves' files no longer show in `git status`. The uncommitted surface is now only the byte-sync/share slices plus my five files (full list in §5).

---

## 1. Every adaptation, with its why

### (a) `ConversationStoreAtomicWorkCaptureTests.testInitialMaterialPublishesOwnerAndPayloadTogether`

```diff
-        XCTAssertEqual(created.materials.first?.availability, .availableLocally)
+        XCTAssertEqual(created.materials.first?.availability, .synced,
+                       "a file within the sync ceiling rides private CloudKit")
```

**Why an adaptation and not a deletion:** the subject (`createWorkItemWithInitialMaterial`) is still declared and still runs; only the lane its 20-byte `.file` payload takes changed, because `WorkMaterialStoragePolicy.mode(kind:byteSize:)` now sends `0 < bytes ≤ 30 MiB` to the blob. The assertion is strengthened, not weakened: `.synced` is the strictly narrower claim (`.availableLocally` was also reachable from a metadata-only path; `.synced` is only reachable with a complete blob row behind the card). The `loadWorkMaterialPayload` round-trip two lines below is untouched and now proves the read comes back through the blob.

**NOT deleted despite integrate-a §Requests 4a.** That request wants the whole class gone with `createWorkItemWithInitialMaterial` and `WorkMaterialOwnerPolicy.createNew` — but that is a deletion inside `ConversationStore+Workboard.swift`, which I do not own. Deleting the tests first would leave a production function with zero coverage. Still owed; re-filed as §Requests 1.

### (b) `WorkCaptureDrainerTests.testTheNoteAndEveryAttachmentLandOnTheDeskTogether`

```diff
-        XCTAssertEqual(image.availability, .availableLocally)
+        XCTAssertEqual(image.availability, .synced)
```

plus the doc line gained the lane it now proves (blob-io's own suggestion, taken):

```
/// The note and every attachment are cards side by side, and the file's
/// bytes are readable from the desk once the queue copy is gone. A payload
/// this small is within the sync ceiling, so it rides private CloudKit
/// rather than staying in the device-local vault.
```

Same reasoning as (a). The `storedBytes == payload` line below already passed through the blob and is untouched.

### (c) `WorkboardDeskUpsertTests.testReplayRepairsACardWhoseVaultBytesAreGone` → **`…WhoseSyncedBytesAreGone`** (retargeted, NOT deleted)

blob-io's cheapest fix was "delete the case — `WorkboardBlobPublicationTests.testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt` is the same test on a payload that still takes that lane". I read that case in full and it is indeed a strict superset **except for one assertion**: `XCTAssertEqual(desk.materials.map(\.id), [draft.id])` — "after a repair the DESK still holds exactly one card". `WorkboardBlobPublicationTests` is a 2a file I may not edit, so deleting the desk case would have silently dropped that assertion from the suite. So I retargeted instead:

| Was | Now | Why |
|---|---|---|
| 19-byte `.file` publishes `.localVault`, `availability == .availableLocally` | `storageMode == .syncedPayload`, `availability == .synced`, **`XCTAssertNil(published.localVaultKey)`** | the premise died — a 19-byte capture is no longer a vault card. The added `localVaultKey` nil assertion is new coverage: the synced lane must stage nothing into the vault |
| damage by `workAssetVault.remove(key)` | damage by `_deleteWorkMaterialBlobRowsForTesting(materialID:)` | that seam exists precisely for this state (its own header: "the state the payload store's loss produces … the one state no publication path can reach") |
| `damaged.availability == .unavailableOnThisDevice` | `damaged.availability == .syncedPending` | availability.md's projection: a card claiming synced bytes with no complete blob is pending, not unavailable |
| `repaired.availability == .availableLocally` | `.synced`, message unchanged | same fact in the surviving lane |
| `repairedPayload == payload`, `rows.count == 1`, `desk.materials.map(\.id) == [draft.id]` | **untouched, verbatim** | the desk-level invariant this case uniquely carries |

The vault-lane replay repair is NOT lost by this move — `WorkboardBlobPublicationTests.testAPayloadAboveTheCeilingTakesTheVaultAndAReplayRestoresIt` asserts it end to end (`storageMode == .localVault`, blobs empty, remove key, `.unavailableOnThisDevice`, replay restores, `rows.count == 1`). The two cases now cover the two lanes rather than one lane twice, and the desk class costs no 30 MiB allocation.

Class doc header needed no edit: "The payload cases fix the repair boundary — bytes a row already claims are restored, bytes a row never claimed are refused" is still exactly what the two payload cases do.

### (d) `WorkboardPersistenceTests.testCaptureIdempotencyAndLocalMaterialPrivacy` — message only, assertion untouched

```diff
         XCTAssertEqual(material.storageMode, .localVault,
-                       "file bytes stay off the CloudKit model, even when small")
+                       "the non-desk owner mint stays on the device-local lane; "
+                       + "only a desk capture asks WorkMaterialStoragePolicy")
```

test-compile §Requests 4 flagged this message as a claim byte-sync would falsify; blob-io then kept `addWorkMaterial` off the policy on purpose, so the **assertion** stayed true and only the **message** went false. It asserted a product-wide truth ("file bytes stay off the CloudKit model, even when small") that byte sync ends. The new message states the actual constraint, which is the one blob-io wrote at the `addWorkMaterial` declaration ("the only way to mint a material under a NON-desk owner … it deliberately stays on the local lane"). Nothing was weakened — `.localVault` and `.availableLocally` are both still asserted, and `XCTAssertNil(material.textContent)` beside them is untouched.

### (e) `WorkboardLiveRepositorySupportTests` — +2 cases, the coverage gap test-compile §Requests 2 filed at me

`WorkboardLiveRepository.presentationKind(_:)` and `.materialName(_:)` survived the purge with **zero test coverage** (`grep -rn "presentationKind\|materialName" ConduckTests/` returned nothing). Their only cover had been `WorkBriefPromptBuilderTests` (deleted whole) and one excised `WorkboardMaterialBoardActionsTests` case. `presentationKind` now carries plan §D's `case .file, .audio: return .file`, so an untested mapping was about to decide how every voice card draws.

- `testPresentationKindNarrowsEveryStoredKindToACardShape` — a table over all six named `WorkMaterialKind`s, the three `.unknown` branches (nothing to open → `.note`; `filename` → `.file`; `hasPayload` → `.file`), and a **closure guard**: `Set(WorkMaterialKind.allCases.map { presentationKind(record(kind: $0)) }) == [.image, .file, .link, .note]`, so a seventh stored kind added without a card shape fails here.
- `testMaterialNameFallsBackFromTitleToFilenameToHostToKind` — title wins **and is emitted verbatim including padding** (the doc's "judged trimmed, emitted verbatim" rule, which nothing else pinned), whitespace-only title falls to filename, link falls to host, unparseable link falls to the kind noun, and the three kind nouns including `.audio → "File"` (a nameless recording is named by the shape it draws as, not by its stored kind).
- One `private static func record(kind:title:filename:urlString:hasPayload:)` helper: only the fields these two projections read carry values, everything else is the empty shape, so each case states exactly the input it depends on. Both cases are `@MainActor` (the repository is a `@MainActor final class`; precedent is `WorkboardAvailabilityTests`, which marks its whole class).

File header widened to name the two projections. No new file — `WorkboardLiveRepositorySupportTests` is the repository's own support-seam class, so no pbxproj question arises.

## 2. Deletions

**NONE.** I deleted no test case and no test file. Every failing assertion had a living subject, so every one was adapted.

## 3. The delete-all-preserves-Work-materials invariant — confirmed alive, in two homes

- `WorkboardPersistenceTests.testDeleteAllConversationsPreservesWorkMaterials` (test-compile's re-home) — real conversation + message, `deleteAll()`, then conversation nil AND `preserved.materials.map(\.id) == [material.id]`. **Executed 7 tests, 0 failures** in the class.
- `WorkboardBlobGCTests.testDeletingEveryConversationLeavesSyncedWorkPayloadsStanding` (blob-io) — the same shape through `upsertDeskMaterial`, then additionally `blobs.count == 1` and `loadWorkMaterialPayload == payload`. **Executed 6 tests, 0 failures.**

The pairing holds: the persistence case proves the material row survives an erase, the GC case proves its bytes do too. Neither needed an edit. `ConversationStore.deleteAll()` deletes no `WorkMaterial` row, so no blob is implicated and no paired-delete path runs — that is why the invariant is free rather than defended.

## 4. Exactly what I ran, and the exact result lines

derivedData `~/Library/Caches/gigaduck-builds/desk-test-surgery/DerivedData`, logs in that slug dir, grepped (never judged from tail or exit code). No `-configuration` passed anywhere. Sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228`. No simulator flake, no retry needed.

**iOS `build-for-testing`** → `ios-bft-1.log`:
```
grep -c ': error: '  →  0
27392:** TEST BUILD SUCCEEDED **
```
Zero warnings on any of my five files (`grep -E 'ConduckTests/(…my five…)\.swift.*warning:'` → no hits).

**Targeted sweep** (`ios-sweep-1.log`, `test-without-building`, 32 quoted `-only-testing:` flags) → `** TEST EXECUTE SUCCEEDED **`, total:
```
Executed 264 tests, with 0 failures (0 unexpected) in 7.500 (7.560) seconds
```

| Class | Result | Class | Result |
|---|---|---|---|
| ConversationStoreAtomicWorkCaptureTests | Executed 3, 0 failures | WorkboardAvailabilityTests | Executed 9, 0 failures |
| ConversationStoreReferencedStoredKeysTests | Executed 3, 0 failures | WorkboardBlobGCTests | Executed 6, 0 failures |
| ConversationStoreWorkCaptureTests | Executed 5, 0 failures | WorkboardBlobPublicationTests | Executed 12, 0 failures |
| ConversationsModelMigrationTests | Executed 20, 0 failures | WorkboardBoardProjectionTests | Executed 1, 0 failures |
| ErrorSurfaceDriftGuardTests | Executed 7, 0 failures | WorkboardChatCaptureTests | Executed 5, 0 failures |
| MacWorkbenchShellDriftGuardTests | Executed 4, 0 failures | WorkboardDeskIdentityDriftTests | Executed 2, 0 failures |
| ShareTargetFilterTests | Executed 9, 0 failures | WorkboardDeskSurfaceDriftGuardTests | Executed 4, 0 failures |
| ShareTargetsSnapshotTests | Executed 9, 0 failures | WorkboardDeskUpsertTests | Executed 10, 0 failures |
| ShareTargetsSnapshotWriterColorTests | Executed 7, 0 failures | WorkboardDeskViewModelTests | Executed 5, 0 failures |
| WorkAssetVaultTests | Executed 9, 0 failures | WorkboardLiveRepositorySupportTests | **Executed 5**, 0 failures |
| WorkCaptureDrainerTests | Executed 9, 0 failures | WorkboardMaterialBoardActionsTests | Executed 12, 0 failures |
| WorkCaptureInboxLeaseTests | Executed 9, 0 failures | WorkboardMaterialPresentationTests | Executed 4, 0 failures |
| WorkCaptureInboxTests | Executed 30, 0 failures | WorkboardModelMigrationTests | Executed 6, 0 failures |
| WorkCaptureRefreshCoordinatorTests | Executed 6, 0 failures | WorkboardMosaicEngineTests | Executed 26, 0 failures |
| WorkMaterialStoragePolicyTests | Executed 7, 0 failures | WorkboardPersistenceTests | Executed 7, 0 failures |
| WorkboardTwoStoreLoadTests | Executed 7, 0 failures | WorkboardWorkspaceCaptureTests | Executed 6, 0 failures |

`WorkboardLiveRepositorySupportTests` is 3 → 5 (my two new cases). Every other count is unchanged from what its author reported.

**FULL iOS suite** (`ios-full-1.log`, `test-without-building`, no `-only-testing`) → `** TEST EXECUTE SUCCEEDED **`:
```
Executed 4758 tests, with 1 test skipped and 0 failures (0 unexpected) in 64.806 (66.141) seconds
```
`grep -cE '\.swift:[0-9]+: error:'` → **0**. The one skip is `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`, exactly the skip integrate-a identified as the surviving one.

Arithmetic checks out: availability measured 4756 with 4 failures; I added 2 cases and deleted 0 → **4758**, and the 4 failures are gone. **The iOS gate value is 4758 executed / 1 skipped / 0 failures.**

**Log noise worth naming so nobody mistakes it for a failure:** `ios-sweep-1.log` and `ios-full-1.log` contain `CoreData: error: Failed to clone external data reference … .interim doesn't exist` lines emitted during `WorkboardModelMigrationTests` store teardown (both the `…-workboard-…_SUPPORT` and the `…-blobs_SUPPORT` external-data directories). They are Core Data's own logging around external-storage cleanup on a destroyed in-memory/SQLite store, **not** XCTest failures — the emitting class passed 6/6 and the anchored `\.swift:[0-9]+: error:` count is 0. Pre-existing shape (the two-store topology makes it appear twice instead of once).

**Gates:** `git diff --check` → clean, exit 0. `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 771 Swift files scanned…`, exit 0.

**NOT run, stated plainly:**
- **macOS build** — my VERIFY is iOS build-for-testing + the sweep, and I changed nothing outside `ConduckTests/`; but I did not prove the test bundle compiles for macOS, so if the gate runs a macOS test build, that is unverified by me. (The two `@MainActor` funcs I added and the `WorkboardLiveRepository` statics they call are all inside `#if !os(watchOS)`, so there is no platform-conditional risk I can see — but "I can see none" is not "I ran it".)
- **Watch suite** — no watch sim assigned and I touched no watch code. Still integrate-a §Requests 7's open gate item: `ConduckWatchSmokeTests` should be 231.
- **String catalogs / mirror triplets** — I opened no `.xcstrings` and no mirror; `git status --short -- '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift'` is empty.

## 5. Classification of everything still red

**Nothing is still red.** For the record, against the three buckets my brief names:

- **(a) fixed** — all four: `ConversationStoreAtomicWorkCaptureTests:41`, `WorkCaptureDrainerTests:119`, `WorkboardDeskUpsertTests:228` and `:229` (the latter two were the same case, now retargeted).
- **(b) genuine product bug** — none found. Every failure traced to a test stating the pre-byte-sync lane, which plan §C deliberately changes. No production behaviour disagreed with the plan.
- **(c) needs integrate-b's full-suite context** — none. I ran the full suite myself and it is 0 failures, so there is no deferred question. What integrate-b still owes is the WATCH suite and the macOS test build, neither of which I could run.

**Uncommitted surface at hand-off** (`git status --short`, complete):
```
 M Conduck/Conduck/Services/ConversationStore+Workboard.swift
 M Conduck/Conduck/Services/ConversationStore.swift
 M Conduck/Conduck/Services/ShareTargetsSnapshotWriter.swift
 M Conduck/Conduck/Services/Workboard/WorkAssetVault.swift
 M Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift
 M Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift
 M Conduck/ConduckShareExtension/{Localizable.xcstrings,ShareView.swift,ShareViewController.swift}
 M Conduck/ConduckShareExtensionMac/{Localizable.xcstrings,ShareView.swift,ShareViewController.swift}
 M Conduck/ConduckTests/ConversationStoreAtomicWorkCaptureTests.swift      ← mine
 M Conduck/ConduckTests/ShareTargetsSnapshotWriterColorTests.swift          (share-contract)
 M Conduck/ConduckTests/WorkCaptureDrainerTests.swift                      ← mine
 M Conduck/ConduckTests/WorkCaptureInboxTests.swift                         (share-contract)
 M Conduck/ConduckTests/WorkboardDeskUpsertTests.swift                     ← mine
 M Conduck/ConduckTests/WorkboardLiveRepositorySupportTests.swift          ← mine
 M Conduck/ConduckTests/WorkboardPersistenceTests.swift                    ← mine
?? Conduck/ConduckTests/{WorkboardAvailabilityTests,WorkboardBlobGCTests,WorkboardBlobPublicationTests,WorkboardTwoStoreLoadTests}.swift
```

## 6. Deviations from my brief, with reasons

1. **I ran the FULL iOS suite as well as the targeted sweep.** Not asked for, but every failure this wave produced was found by a full run and missed by targeted runs (integrate-a's model-version regression, blob-io's four). 66 seconds to turn "the classes I looked at are green" into a gate number.
2. **I retargeted `testReplayRepairsACardWhoseVaultBytesAreGone` rather than deleting it**, against blob-io's own recommendation. Reason in §1(c): deletion would have dropped the one assertion no other class makes, and I cannot add it to the 2a file that would otherwise carry it.
3. **I added two cases that fix no failure** (§1(e)). test-compile §Requests 2 addressed that gap to "phase-5 test-surgery agent", which is me, and the mapping it names is load-bearing for plan §D's audio cards.
4. **I did not delete `ConversationStoreAtomicWorkCaptureTests`** despite integrate-a §Requests 4a. The deletion it wants starts in a production file I do not own; taking the tests out first would leave the function uncovered. §Requests 1.
5. **No Codex consult.** The one genuinely debatable call was §1(c), and it turned on a fact I could check directly (what `WorkboardBlobPublicationTests` does and does not assert) rather than on judgement.

---

## Call-site touches

**NONE outside my own files.** No production symbol changed. The only production API my new cases reach — `WorkboardLiveRepository.presentationKind` / `.materialName` — were already `internal` before I arrived (availability widened `presentationAvailability`/`materialDetail`, not these two).

---

## Catalog

**Keys I ADDED in source: NONE.** My two new cases READ four existing keys through `String(localized:defaultValue:)` in order to compare against the repository's own output — `workboard.material.image` = `Image`, `workboard.material.file` = `File`, `workboard.material.link` = `Link`, `workboard.material.note` = `Note`. All four are already declared in `WorkboardLiveRepository.materialName` and already in the main catalog; a test reading a key is not a second declaration.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

**The strings phase must NOT treat `workboard.material.{image,file,link,note}` as dead-by-low-reference-count.** They now have a test reader as well as their production one, but the production one is the live declaration and always was.

---

## Requests

1. **Store owner (production files, NOT mine) — integrate-a §Requests 4a is still open and is now the only test-shaped debt left.** `createWorkItemWithInitialMaterial` + `WorkMaterialOwnerPolicy.createNew` + its branch inside `publishWorkMaterial` are production-dead (integrate-a verified: one declaration, three test callers, zero production callers). When they go, `ConversationStoreAtomicWorkCaptureTests` (3 cases, all green today) goes with them — **all three, not just the one I adapted**, since every one drives that function. Do not delete the tests first: they are that function's only coverage while it exists. Suite delta when it happens: **−3**, taking the iOS gate to 4755.
   integrate-a §Requests 4b (`addWorkMaterial`/`addWorkMaterialFile`/`insertWorkMaterial`/`createWorkItem`) is **settled and needs no further decision**: blob-io kept them as the test-only non-desk owner mint and said so at both declarations. My §1(d) message rewrite is the test side of that same decision. Treat 4b as closed.
2. **Whoever next opens `WorkboardLiveRepository.swift` — blob-io §Requests 4 is still unactioned.** The comment at the reattach site ("Reattachment replaces local bytes and metadata only. Persisting an extract or a preview here would copy user file content into private CloudKit…") is half false now: reattached bytes under the ceiling DO ride private CloudKit. The extract/preview half is still true and still enforced. I could not take it — production file.
3. **Strings/copy phase — availability §Requests 2 is still open and is now the most user-visible copy debt.** `sync.icloud.banner.{noAccount,restricted,quota}` say "your conversations", and the Work desk renders them verbatim.
4. **desk-vm / view owner — availability §Requests 1 is still open**, and it is the one place the suite and the UI disagree in spirit: a `.syncedPending` card is presented as `.unavailableOnThisDevice`, so the desk draws a "Reattach" affordance on a card whose own detail line reads "Waiting for iCloud…". `WorkboardAvailabilityTests.testACardClaimingSyncedBytesWithNoBlobIsPendingAndCannotBeOpened` pins the current (fail-closed, correct-but-confusing) behaviour; that one line is what to update if the `syncPending` case lands. **Do not treat my green sweep as evidence that this is fine** — it is evidence that it fails closed, which is a different claim.
5. **Orchestrator — gate numbers.** iOS: **4758 executed / 1 skipped / 0 failures** (not the plan's ~4664 and not 2 skips; the second skip died with `WorkBriefAssistantTests`, per integrate-a §5). Watch: **unrun by me and by every agent since desk-intents added 2 cases** — expected 231, still unverified, run it serially on `28AC563B-42C1-4E66-940D-77E63B07918B`. macOS: my slice is test-only and I did not run a macOS build; share-mac's signed `** BUILD SUCCEEDED **` is the most recent macOS evidence and it predates the byte-sync and availability slices, so the gate's macOS build is genuinely load-bearing, not a formality.
6. **Nobody re-assert `.availableLocally` for a small desk capture.** Three assertions now say `.synced` for a payload under `Constants.workboardSyncCeilingBytes` (§1a, §1b, §1c). The two remaining `.availableLocally` assertions on a small payload — `WorkboardPersistenceTests:46` and `ConversationStoreWorkCaptureTests:176` — are correct because they mint through `addWorkMaterial` / `captureMessageToWork`'s referenced-only lane, NOT through the desk policy. If someone wires those to the policy, those two flip and the messages must flip with them.
7. **Nobody delete `WorkboardDeskUpsertTests.testReplayRepairsACardWhoseSyncedBytesAreGone` as a duplicate of `WorkboardBlobPublicationTests`.** They now cover the two different lanes (synced vs over-ceiling vault) and only the desk one asserts that a repair leaves the DESK holding exactly one card. §1(c) is the reasoning; deleting either one loses a real property.
