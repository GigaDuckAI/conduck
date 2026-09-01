# desk-vm — plan §A "VM loads ONLY the desk" (Codex #10b) + the repository's capture path onto `upsertDeskMaterial`. DONE: iOS test build + macOS build green, 74 targeted tests / 0 failures.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened** (I added zero user-facing strings and deleted none). Nothing under `docs/qa/desk-cloudkit/` touched.

Files changed: `ViewModels/WorkboardViewModel.swift` · `Services/Workboard/WorkboardLiveRepository.swift` · tests `WorkboardWorkspaceCaptureTests.swift`, `WorkboardMaterialBoardActionsTests.swift`, `WorkboardBoardProjectionTests.swift` · NEW `ConduckTests/WorkboardDeskViewModelTests.swift` · ONE 4-line call-site edit in `Views/Workboard/PersonalWorkbenchView.swift` (§Call-site touches — read it, it is outside the parenthetical you granted).
Files I own and did **not** change: `Models/WorkboardRecords.swift` (§4 explains why), `WorkboardPersistenceTests.swift`, `WorkboardLiveRepositorySupportTests.swift` (nothing in either is desk-dependent; no assertion weakened, none deleted).

---

## 1. `WorkboardViewModel` — the surface to code against

```swift
@Observable @MainActor
final class WorkboardViewModel {
    struct Dependencies {                      // NO closure names an owner any more
        var loadDesk: @MainActor () async throws -> WorkboardItemSnapshot?
        var importMaterial: @MainActor (Int64?, WorkboardMaterialImport,
                                        @escaping @Sendable (Double) -> Void) async throws -> WorkboardItemSnapshot
        var removeMaterial: @MainActor (Int64, UUID) async throws -> WorkboardItemSnapshot
        var replaceMaterial: @MainActor (Int64, UUID, WorkboardMaterialImport,
                                         @escaping @Sendable (Double) -> Void) async throws -> WorkboardItemSnapshot
        var openConversation: @MainActor (UUID) -> Void
        var openMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void
        var openGatewaySettings: @MainActor () -> Void
        var reorderMaterials: (@MainActor ([UUID], Int64) async throws -> WorkboardItemSnapshot)?
        var setMaterialCardSize: (@MainActor (UUID, WorkMaterialCardSize) async throws -> Void)?
    }
    init(dependencies: Dependencies)
}
```
`importMaterial`'s token is `Int64?` and is **nil exactly when the model holds no desk** — that is the create case. `expectedOwnerRevision: 0` is never sent (desk-upsert §Requests 1).

**Published state (exact):** `private(set) desk: WorkboardItemSnapshot?` · `isLoading` · `loadError` · `workspaceImportState` · `workspaceComposerDrafts` · `private(set) nonEmptyComposerDrafts` · `notice` · `workspaceStatus` · `private(set) isMutatingDesk`. `@ObservationIgnored`: `loadRequestedWhileLoading`, `deskMutationWaiters`.
**GONE:** `items` as storage, `selectedItemID`, `workspaceMutationItemID` (+ the `WorkspaceMutationWaiter` struct).

**Computed (the two view seams, see §5):** `items: [WorkboardItemSnapshot]` (0 or 1 element) · `selectedItem: WorkboardItemSnapshot?` (the desk **once it holds material**, else nil → empty-desk canvas) · `isCapturingIntoAnyWorkspace`.

**Methods (exact, all names unchanged from the purge state):** `item(withID:)` (resolves ONLY the desk; anything else → nil) · `workspaceComposerDraft(for:)` / `setWorkspaceComposerDraft(_:for:)` / `hasComposerDraft(for:)` · `load()` · `addWorkspaceThought(_:to:)` · `flushWorkspaceComposer(itemID:)` · `importWorkspaceMaterials(_:to:additionalFailureCount:announcesResult:)` · `presentWorkspaceImportReport(_:)` · `reattachWorkspaceMaterial(_:in:with:)` · `reorderMaterial` ×2 · `moveMaterial(_:direction:in:)` · `setMaterialCardSize(_:materialID:in:)` · `removeMaterialFromBoard(_:in:)` · `openMaterial(_:)` · `openGatewaySettings()`.
Private renames: `upsert(_:)` → `adopt(_:)` (same revision-guard semantics) · `acquireWorkspaceMutation()` / `releaseWorkspaceMutation()` now take no id · `applyMaterialOrder(_:)` / `applyMaterials(_:)` lost their `in itemID:`.

**New refusal (real behaviour change):** `importWorkspaceMaterialsUnlocked` guards `itemID == Constants.workboardDeskItemID` and returns an all-failed report otherwise. Capture aimed anywhere else is refused, never redirected — silently rewriting the target would hide a caller bug behind a card that appeared anyway. Covered by `testCaptureAimedAtAnyBoardButTheDeskIsRefusedWithoutReachingTheStore`.

**`WorkboardItemSnapshot` trimmed to** `id · title · objective · materials · revision` (+ `displayTitle`). Deleted: `state`, `isPinned`, `boardOrder`, `wasCapturedExternally` (your task list) **plus** `reviewBy` (views-core §Requests 1), `context`, `desiredResult`, `constraints`, `createdAt`, `modifiedAt` — each grepped to zero readers first; the only construction site was the repository, which I own. `title`/`objective`/`displayTitle` KEPT deliberately: `WorkboardDetailView:22,56` and `WorkboardCaptureCanvas:88` still read `displayTitle` (see §Requests 1 — it now renders **"Untitled brief"** for the desk).

**Unchanged and still live:** board arrange/resize/reorder, composer drafts + flush, capture progress + partial-success reporting, reattach, delete-material, notice/status presentation, tutorial state (it lives in `SettingsManager`, untouched).

## 2. `WorkboardLiveRepository` — the surface to code against

```swift
init(store: ConversationStore = .shared,
     captureInbox: WorkCaptureInbox = .shared,
     openConversation: @escaping @MainActor (UUID) -> Void,
     openMaterial: @escaping @MainActor (WorkboardMaterialSnapshot) -> Void,
     openGatewaySettings: @escaping @MainActor () -> Void)

func makeDependencies() -> WorkboardViewModel.Dependencies
@discardableResult func drainCaptures() async throws -> WorkCaptureDrainer.Report
static func revision(for date: Date) -> Int64
static func presentationKind(_ record: WorkMaterialRecord) -> WorkboardMaterialKind
static func materialName(_ record: WorkMaterialRecord) -> String
```
Everything else is private: `loadDesk()` · `snapshot(for:)` · `localPresentationThumbnails(for:)` · `materialSnapshot` · `presentationAvailability` · `materialDetail` · `importMaterial(_:expectedDeskRevision:onProgress:)` · `storageKind` · `reorderMaterials(_:expectedRevision:)` · `removeMaterial(_:expectedRevision:)` · `replaceMaterial(_:expectedRevision:with:onProgress:)`.

- **`settings` DROPPED** (decision you asked for). Its only readers died with `loadGateways`/`gatewayDetail`; nothing on a surviving path needs a `SettingsManager` — the storage policy is a pure function and the sync banner reads `CloudSyncMonitor`. The init parameter went with it; `PersonalWorkbenchView:712` used the default, so its construction site needed **no** edit.
- **`loadItems()` → `loadDesk() -> WorkboardItemSnapshot?`** — one `store.fetchWorkItem(id: Constants.workboardDeskItemID)`. Duplicate physical desk rows arrive already unioned (`deduplicatedWorkItems` + the `workItemID IN` material fetch); a legacy project row is never fetched at all.
- **`snapshots(for:isCompleteBoard:)` deleted**; `snapshot(for:)` is now non-throwing and always prunes the thumbnail cache. The `isCompleteBoard` flag existed because a partial projection must not prune — with one desk **every** projection is the whole board, so the flag had no false case left.
- **`importMaterial` routes the WHOLE path through `ConversationStore.upsertDeskMaterial`** — not just the first-capture arm. `createWorkItemWithInitialMaterial`, `addWorkMaterial` and `addWorkMaterialFile` now have **no caller in the repository**. Deltas: the draft carries no `sequence` (the op ranks inside its own transaction); the repository no longer pre-fetches the owner to compute a rank or to pre-check the revision (the op's CAS does it, `.staleRevision` → `.staleDraft`); `sourceFileByteSize:` is passed as `material.byteCount` (`Int64?`) instead of `?? -1`, which the op resolves identically; the created desk row gets **no derived title** (`WorkboardWorkspaceCaptureLogic.title(for:)` is no longer used for an item title).
- `removeMaterial` / `replaceMaterial` / `reorderMaterials` / the `setMaterialCardSize` closure now name `Constants.workboardDeskItemID` themselves.
- **Untouched, as instructed:** `presentationKind`, `materialName`, `materialDetail`, `presentationAvailability` (including foundation's `.syncedPending` fails-closed branch and the `workboard.material.syncPending` line), `localPresentationThumbnails`' decode-window machinery, `WorkboardLiveRepositoryError`'s five cases and their copy.

## 3. What the VM loads

Exactly one row: `Constants.workboardDeskItemID`. Nil until a capture creates it. A model-15 project row on a dev device stays in the store, keeps its title and its cards, and is unreachable from the view model — `item(withID: legacyID)` answers nil and `items` never contains it. Proven end-to-end (VM → repository → real `ConversationStore`) by `testOnlyTheDeskIsLoadedWhenALegacyProjectRowStillExists`, which also asserts the project row is still whole afterwards.

## 4. `WorkboardRecords.swift` — deliberately NOT edited

Every candidate whose last reader died is a member of `WorkItemRecord`, and `WorkItemRecord` is built in `ConversationStore+Workboard.swift`'s `StoredWorkItem.record(materials:)` — a file that is not mine and that another agent was editing this wave. Deleting a field there is a cross-file edit, not a call-site fix, so it is a Request (§Requests 4), not a deletion:
- `WorkItemRecord.boardOrder` — **zero readers** now (the repository's `boardOrder:` mapping was its last one). Written/cleared at `ConversationStore+Workboard.swift:1331-1335`, projected at `:1437,1451`.
- `WorkItemRecord.completedAt` — **zero readers** (projected at `:1438,1452`).
- `WorkItemRecord.state` — still read: `ConduckTests/ConversationStoreWorkCaptureTests.swift:69` (`XCTAssertEqual(item.state, .draft)`), a file I do not own. KEEP.
- `WorkItemContent.{dueAt, isPinned, desiredOutcome, constraints, preferredGatewayRef}` — unread by app code, but they are round-tripped columns for the project rows the plan preserves; `preferredGatewayRef` is asserted at `ConversationStoreWorkCaptureTests:68`. Recommend KEEP.
Foundation's additions (`WorkMaterialKind.audio`, `WorkMaterialAvailability.syncedPending`, `WorkMaterialBlobRecord` + `isComplete`) are intact — the file is byte-identical to what purge-core left.

## 5. Deviations, with reasons

1. **`items` and `selectedItem` survive as computed view seams.** `WorkboardView.swift` reads `viewModel.items.isEmpty` (twice) and `viewModel.selectedItem` (`:228,243,264`), and that file is in nobody's minimal-touch list this wave. Deleting them would have broken a file I may not edit, so the *state* died (no `selectedItemID`, no selection reconciliation in `load()`, no selection adoption on import) while the two accessors stayed, derived from `desk`. `selectedItem` is now "the desk once it holds material", which reproduces today's behaviour exactly: board when there are cards, capture canvas when there are none — including after the last card is deleted. **Rename both when WorkboardView is next opened (§Requests 2).**
2. **The per-item parameters on the VM's public methods stayed** (`to itemID:`, `in itemID:`). Dropping them is a ~14-site rework of `WorkboardCaptureCanvas`, which its owner reworks in a later wave; the *Dependencies* closures below the VM did lose them, so the owner id stops at the view boundary and never reaches the store from here. The VM checks the id rather than trusting it (§1).
3. **`WorkboardWorkspaceCaptureLogic.title(for:)` is now used only for note titles**, not for an item title. `noteTitle(for:)` and `normalizedThought` are unchanged; nothing was deleted.
4. **`Dependencies.openConversation` / `openGatewaySettings` kept** though nothing calls them (purge-core's deliberate keep, scout §4a). Not my call to reverse.
5. **`isCapturingIntoAnyWorkspace` keeps its name** even though "any workspace" is now stale vocabulary — renaming it is churn in `WorkboardCaptureCanvas` (3 sites) that belongs to its owner's wave. Its doc comment states the desk truth.

## Call-site touches

**`Views/Workboard/PersonalWorkbenchView.swift`, `routeWorkboardDeepLink(_:)` — ONE edit, 4 lines.** It read `model.workboardViewModel.selectedItemID = itemID`, a symbol I deleted. The deep link now routes to Work and loads; the payload's UUID is still validated (it proves the link names collected material) but nothing is selected:
```swift
guard let value = note.userInfo?[NotificationDeepLink.workItemIDKey] as? String,
      UUID(uuidString: value) != nil else { return }
model.router.destination = .work
Task { @MainActor in await model.workboardViewModel.load() }
```
**Flagging honestly:** your grant for that file said *"repository/VM construction sites only"*, and this is a VM **use** site. I did it anyway because the alternative was leaving the tree un-buildable or keeping a dead stored property alive; it is the smallest possible edit of the allowed *kind* ("remove a reference to a symbol you deleted") and it is exactly the retarget purge-core §Requests 3 asked the capture agent for. Revisit it if you disagree — nothing else in that file was opened, and the repository construction site at `:712` needed no change.

No other file outside my own was touched. `WorkboardDetailView.swift` and `WorkboardCaptureCanvas.swift` needed **nothing** — every member they call kept its name and signature.

## 6. Tests + counts

| File | Cases | Change |
|---|---:|---|
| `WorkboardDeskViewModelTests.swift` (**NEW**) | 5 | below |
| `WorkboardWorkspaceCaptureTests.swift` | 5 → **6** | rewritten to desk semantics, +1 case |
| `WorkboardMaterialBoardActionsTests.swift` | 12 → **12** | fixtures + seeding only |
| `WorkboardBoardProjectionTests.swift` | 1 → **1** | Dependencies shape + desk id |
| `WorkboardLiveRepositorySupportTests.swift` | 3 → **3** | untouched |
| `WorkboardPersistenceTests.swift` | 7 → **7** | untouched |

**Net for the orchestrator's iOS count: +6 executed.** No assertion was weakened or deleted anywhere; the one case whose subject changed was renamed, not dropped.

`WorkboardDeskViewModelTests` drives the REAL chain (view model → `WorkboardLiveRepository` → live `ConversationStore`), not a harness:
| Case | Holds |
|---|---|
| `testOnlyTheDeskIsLoadedWhenALegacyProjectRowStillExists` | a model-15 project row with a card is invisible before and after a capture, and still whole in the store |
| `testFirstCaptureCreatesTheDeskLazilyAtTheFixedIdentity` | no desk row before the first thought; after it, one row at the fixed id, empty title/objective, and `fetchWorkItems()` holds exactly that one board |
| `testASecondCaptureAppendsToTheSameDeskInsteadOfMintingAnother` | ranks `[0,1]`, revision advanced, still ONE board with 2 cards |
| `testRemovingTheLastCardLeavesTheDeskStandingAndReadyForTheNextCapture` | the desk row survives its last card, `selectedItem` goes nil (canvas), the next capture reuses the same row |
| `testTheBoardUnionsMaterialsFromEveryDuplicateDeskRow` | **two physical desk rows** seeded through a raw Core Data stack, then opened with `ConversationStore(storeURL:)`: one logical desk, both cards, and a capture on top keeps all three |

The duplicate-row fixture is why that test seeds a SQLite file directly: no API on the device can mint a second desk row (`createWorkItem` returns the existing row, `upsertDeskMaterial` adopts it, and the in-process claim serializes concurrent captures), so the CloudKit-only state has to be written by hand. It loads the compiled model from `Conversations.momd` (current version, so it does not pin a version number) and cleans its own directory in `tearDown`. This closes the gap desk-upsert §6 reported for material-without-owner-shaped states at the projection level.

Changes worth knowing in the two adapted harness files:
- `WorkboardMaterialBoardActionsTests`: every fixture is now `makeDesk(materials:revision:)` at the fixed id, and the board is seeded through `await viewModel.load()` (helper `makeViewModelShowingDesk`) instead of assigning `viewModel.items`. Two tests had to move their fault injection **after** seeding (`loadFails`, and the "another device moved a card" swap) so the seeding read still succeeds — the assertions are unchanged. `harness.loadCount` is zeroed after seeding, so `XCTAssertEqual(harness.loadCount, 1)` still means "one corrective read".
- `WorkboardWorkspaceCaptureTests`: the harness desk is now `WorkboardItemSnapshot?` and `importExpectedRevisions` is `[Int64?]`, so the create case is asserted as `nil` rather than `0` (`[nil, 1]` in the serialized-lane test). `testFirstThoughtOnAnEmptyBriefBecomesANoteAndLeavesTheObjectiveEmpty` → `testFirstThoughtOnTheEmptyDeskBecomesANoteAndLeavesTheDeskWithoutABrief` (same assertions, plus the nil-token one).

## 7. Gates run (exact lines)

Slug `desk-vm`, derivedData `~/Library/Caches/gigaduck-builds/desk-vm/DerivedData` (+ `DerivedDataMac`), every log written there and grepped — never judged from tail or exit code. No `-configuration` passed anywhere.

- iOS `build-for-testing`, sim `6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228` → `bft-2.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`. Zero warnings in any file I touched (grepped by filename).
- iOS `test-without-building`, twelve quoted `-only-testing:` flags → `test-2.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `ConversationStoreAtomicWorkCaptureTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.021 (0.022) seconds` |
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.462 (0.463) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.825 (2.827) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.142 (0.144) seconds` |
| `WorkboardBoardProjectionTests` | `Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.001) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.082 (0.084) seconds` |
| `WorkboardDeskViewModelTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.115 (0.117) seconds` |
| `WorkboardLiveRepositorySupportTests` | `Executed 3 tests, with 0 failures (0 unexpected) in 0.013 (0.014) seconds` |
| `WorkboardMaterialBoardActionsTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.025 (0.028) seconds` |
| `WorkboardModelMigrationTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.889 (0.890) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.041 (0.043) seconds` |
| `WorkboardWorkspaceCaptureTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.006 (0.008) seconds` |
| **total** | `Executed 74 tests, with 0 failures (0 unexpected) in 4.623 (4.642) seconds` |

- macOS `xcodebuild build -destination 'platform=macOS'` → `mac-1.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback needed**. (Insurance, not in my brief: the repository compiles for macOS and `PersonalWorkbenchView` has macOS-only branches.)
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 765 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`. (My new test builds a raw `NSPersistentStoreCoordinator`; the script still passes — it does not scan the test bundle.)
- `git diff --check` → clean. `git status` shows no `.xcstrings`, no `Identity-Override`, nothing under `docs/`.
- **Not run, stated plainly:** the full iOS suite and the watch suite (orchestrator's gate). The watch target compiles none of my files.
- Build cache removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-vm` — the logs above no longer exist; re-run if you need them.

Other agents' work (`CaptureWorkboardIntent`, `WorkCaptureDrainer`, the watch intent, `WorkboardDeskIdentityDriftTests`, `MacWorkbenchShellDriftGuardTests`, `WorkCaptureInboxLeaseTests`) was already in the tree during both of my builds, and both were green with it in.

---

## Catalog

**Keys I ADDED in source: NONE.** Every string in my code already existed; I minted no user-facing copy.

**Keys I found DEAD: NONE.** I deleted no `String(localized:)` / `LocalizedStringResource` literal. `workboard.item.untitled` is still referenced (`WorkboardItemSnapshot.displayTitle`) — see Requests 1 before any audit deletes it.

---

## Requests

1. **Copy pass (serial) — `workboard.item.untitled` is now the DESK's title, and it lies.** The desk row carries no title, so `displayTitle` falls through to *"Untitled brief"*, and `WorkboardDetailView:56` shows it as the navigation title while `WorkboardCaptureCanvas:88` puts it in `WorkboardCaptureDestination.existingWork(...)`. Plan §B already sanctions rewriting this key's copy — this is why. I could not fix it in a parallel wave (source and catalog must move together), and I did not invent a static fallback because plan §B assigns the desk's static "Work" title to the desk-detail agent.
2. **Desk-detail / view agent — two renames I could not make.** `WorkboardView.swift` is in nobody's touch list this wave, so the VM still answers to the old names at `:228,243` (`viewModel.items.isEmpty`) and `:264` (`viewModel.selectedItem`). When you repurpose `WorkboardDetailView` as the desk: read `viewModel.desk` directly (nil ⇒ show the capture canvas, non-nil with empty `materials` ⇒ also the canvas), drop the `itemID` parameter and the missing-item branch, then delete `items` and `selectedItem` from the view model — they exist only for those three lines. `WorkboardItemSnapshot.title`/`objective`/`displayTitle` die with the static "Work" title and the `WorkboardCaptureDestination` collapse; nothing else reads them.
3. **Capture-canvas agent — vocabulary, when you rework the file.** The VM still says `workspace` in `addWorkspaceThought`, `importWorkspaceMaterials`, `workspaceComposerDraft(for:)`, `isCapturingIntoAnyWorkspace`, `workspaceImportState`, `workspaceStatus`, and still takes `to itemID:` / `in itemID:` on every public method. All of it is desk-only now; the ids are checked, not trusted. Renaming those and dropping the parameters is a canvas-side rework, so it is yours — the view model will follow in one edit.
4. **Serial integration / store owner — `ConversationStore+Workboard.swift` cleanups my change unblocked:**
   - `createWorkItemWithInitialMaterial`, `addWorkMaterial`, `addWorkMaterialFile` and `insertWorkMaterial` have **no remaining app caller from the repository**. Once chat capture is retargeted (desk-upsert §Requests 2), delete them together with `WorkMaterialOwnerPolicy.createNew` and the three `ConversationStoreAtomicWorkCaptureTests` cases, exactly as desk-upsert scoped it.
   - `WorkItemRecord.boardOrder` and `WorkItemRecord.completedAt` are now projected but unread (§4). Dropping them means editing `StoredWorkItem` (`:1428-1452`) plus `WorkboardRecords.swift:112-113`; I own the latter but not the former, so I left both consistent rather than half-done.
5. **ByteSync agent:** the capture path you inherit is `WorkboardLiveRepository.importMaterial(_:expectedDeskRevision:onProgress:)` → `store.upsertDeskMaterial`. It passes `sourceFileByteSize: material.byteCount` and no `sequence`, and it is the ONLY app caller that supplies `expectedOwnerRevision`. `presentationAvailability`'s `.syncedPending` arm and `materialDetail`'s `workboard.material.syncPending` line are untouched and still where foundation left them. Note `WorkMaterialStoragePolicy` still has zero call sites — I did not wire it (foundation and desk-upsert both put that at `stageWorkMaterialBytes`, inside the store).
6. **Phase-5 test agent — still open from `test-compile.md` §Requests 2:** `WorkboardLiveRepository.presentationKind(_:)` / `.materialName(_:)` still have **zero** coverage. I own that file but left the gap to you rather than duplicate the table test your brief names; `WorkboardLiveRepositorySupportTests.swift` is the natural home and I changed nothing in it.
