# purge-core — plan §B core purge (scout-purge §1, §4, §5). DONE, app builds green on both platforms.

Serial phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. `Localizable.xcstrings` NOT edited (I added zero new keys; deletion belongs to the post-purge bidirectional audit). Every Foundation addition from `foundation.md` is intact and verified (see §Foundation preserved).

**Test bundle is RED by design** — I did not touch `ConduckTests`. §Test fallout below is your map.

---

## 1. Ordered step 1 — `WorkBriefMaterialPacket` re-home (Codex #10a), done FIRST

`WorkboardLiveRepository.swift` — `presentationKind(_:)` and `materialName(_:)` are now **self-contained**, byte-for-byte the same decisions the packet made:

- `presentationKind(_:)` inlines the old `WorkBriefMaterialPacket.packetKind(for:)` switch verbatim, including foundation's `case .file, .audio: return .file` and the `.unknown → filename != nil || hasPayload ? .file : .note` rule.
- `materialName(_:)` inlines the old `.label(for:kind:)` ladder verbatim (title → filename → URL host → kind noun, `workboard.material.{image,file,link,note}` unchanged).
- The `private extension WorkBriefMaterialPacket.Kind { presentationKind }` bridge at the file tail is gone (it existed only to translate between the two kind enums).

Both stay `static` + internal so tests drive the real mapping. `WorkboardMaterialKind` has exactly 4 cases, so the switch is exhaustive without a default.

---

## 2. Deleted whole (files)

| File | Note |
|---|---|
| `Conduck/Conduck/Services/Workboard/WorkboardDispatchCoordinator.swift` | also carried `WorkboardRevision`, `WorkboardDispatchResult`, `WorkboardDispatchError` |
| `Conduck/Conduck/Services/Workboard/WorkBriefAssistant.swift` | |
| `Conduck/Conduck/Services/Workboard/WorkBriefPromptBuilder.swift` | `WorkBriefMaterialPacket`, `WorkBriefPrompt*` |
| `Conduck/Conduck/Services/Workboard/WorkboardBriefingBuilder.swift` | `WorkboardBriefingFacts` |
| `Conduck/Conduck/Services/Workboard/WorkboardUploadJournal.swift` | 4 `reconcile()` call sites removed |
| `Conduck/Conduck/Intents/BriefWorkboardIntent.swift` | + its `AppShortcuts.swift` entry (2 phrases + `shortTitle "Brief My Workboard"`) |
| `Conduck/Conduck/Views/Workboard/WorkboardBriefingView.swift` | |
| `Conduck/Conduck/Views/Workboard/WorkboardDispatchSheet.swift` | |

**`WorkboardRevision` was RE-HOMED, not deleted** → now `Conduck/Conduck/Models/WorkboardRecords.swift` (top of file, above `// MARK: - Human-visible state`). It was declared inside the dispatch coordinator; `WorkboardLiveRepository.revision(for:)` and several tests still need it. Same body, same bit-pattern semantics.

---

## 3. `WorkboardViewModel.swift` (2319 → 984)

### Top-level types DELETED
`WorkboardRunState` · `WorkboardRunSnapshot` · `WorkboardEditDraft` · `WorkboardGatewayCapability` · `WorkboardGatewayChoice` · `WorkboardDispatchRequest` · `WorkboardDispatchReceipt` · `WorkboardFilter` · `WorkboardBriefingSnapshot` · `WorkboardEditorConflict` · `WorkboardConfirmation` · `WorkboardRenameRequest` · `WorkboardPresentationLogic` (**whole enum** — every member was filter/search/attentionSort/briefing) · `WorkboardBoardOrdering` · `WorkboardEditorFocusTarget` · `WorkBriefShapingSource` · `WorkboardPromptComposer` · `private extension WorkboardMaterialSnapshot { packetKind }` · `WorkboardVoiceTarget.objective` case (enum kept, `.context` only).

### SURVIVE unchanged
`WorkboardMaterialKind` · `WorkboardMaterialAvailability` · `WorkboardMaterialSnapshot` · `WorkboardMaterialImport` · `WorkboardVoiceTarget` · `WorkboardNotice` · `WorkboardTransientStatus` · `WorkboardWorkspaceImportState` · `WorkboardWorkspaceImportReport` · `WorkboardReorderPlacement` · `WorkboardMoveDirection` · `WorkboardMaterialOrdering` · `WorkboardWorkspaceCaptureLogic`.

### `WorkboardItemSnapshot` — DELIBERATE DEVIATION from scout §4d
Deleted: `runs`, `latestRun`, `lastSentRevision`, `hasChangesSinceLastSend`, `isReadyToSend`, `searchCorpus` (+ the `runText` half of the corpus join).
**KEPT (scout said delete): `state`, `isPinned`, `boardOrder`, `wasCapturedExternally`.**
Why: their only consumers are `WorkboardCard` / `workboardProjectActions` / `WorkboardStateBadge` / `extension WorkItemState` in `WorkboardComponents.swift`, all of which are on the NEXT agent's DELETE-ENTIRELY table. Deleting the fields now would have forced me to do that whole view trim. They are inert carried data — `state` is a constant `.draft` from the store (see §5). **Next view agent: drop these four with the components trim.**

### New `Dependencies` shape (exact)
```swift
struct Dependencies {
    var loadItems: @MainActor () async throws -> [WorkboardItemSnapshot]
    var importMaterial: @MainActor (UUID, Int64, WorkboardMaterialImport,
                                    @escaping @Sendable (Double) -> Void) async throws -> WorkboardItemSnapshot
    var removeMaterial: @MainActor (UUID, Int64, UUID) async throws -> WorkboardItemSnapshot
    var replaceMaterial: @MainActor (UUID, Int64, UUID, WorkboardMaterialImport,
                                     @escaping @Sendable (Double) -> Void) async throws -> WorkboardItemSnapshot
    var openConversation: @MainActor (UUID) -> Void
    var openMaterial: @MainActor (WorkboardMaterialSnapshot) -> Void
    var openGatewaySettings: @MainActor () -> Void
    var reorderMaterials: (@MainActor (UUID, [UUID], Int64) async throws -> WorkboardItemSnapshot)?
    var setMaterialCardSize: (@MainActor (UUID, UUID, WorkMaterialCardSize) async throws -> Void)?
}
```
Gone (13): `loadGateways` `saveDraft` `saveDraftAsCopy` `deleteItem` `duplicateItem` `reorderItems` `setState` `acknowledgeRun` `dispatch` `shapeDraft` `readBriefingAloud` `stopBriefingAloud` `setPinned`.
`openConversation` SURVIVES as a closure (scout §4a) even though the VM method that called it died — it is wired but currently unused.

### Published state — surviving set (exact)
`items` · `isLoading` · `loadError` · `selectedItemID` · `workspaceImportState` · `workspaceMutationItemID` · `workspaceComposerDrafts` · `nonEmptyComposerDrafts` · `notice` · `workspaceStatus` · `@ObservationIgnored loadRequestedWhileLoading`, `workspaceMutationWaiters`.
Deleted: `gateways` `customGateways` `searchText` `appliedSearchText` `filter` `isReorderingBoard` `provisionalWorkspaceID` `editorPresented` `editingDraft` `editorIsSaving` `editorFocusRequest` `editorSuggestion` `editorConflict` `isShapingDraft` `preflightItemID` `selectedGatewayID` `excludedMaterialIDs` `isDispatching` `briefing` `isReadingBriefing` `confirmation` `renameRequest` `renameDraftTitle` `lastSavedFingerprint` `editorWasPersisted` `searchDebounceTask` `searchDebounce`.

### Methods — surviving set (exact)
`selectedItem` · `isCapturingIntoAnyWorkspace` · `workspaceComposerDraft(for:)` · `setWorkspaceComposerDraft(_:for:)` · `hasComposerDraft(for:)` · `load()` · `item(withID:)` · `addWorkspaceThought(_:to:)` · `addWorkspaceThoughtUnlocked` · `flushWorkspaceComposer(itemID:)` · `importWorkspaceMaterials(...)` · `importWorkspaceMaterialsUnlocked(...)` · `presentWorkspaceImportReport` · `presentWorkspaceCaptureFailure` · `reattachWorkspaceMaterial(_:in:with:)` · `acquireWorkspaceMutation` · `releaseWorkspaceMutation` · `reorderMaterial` ×2 · `moveMaterial` · `setMaterialCardSize` · `removeMaterialFromBoard` · `performMaterialReorder` · `applyMaterialOrder` · `applyMaterials` · `openMaterial` · `openGatewaySettings` · `upsert`.
Deleted (per scout §4c) incl. `completeWorkspace`, `transition`, `acknowledge`, `openConversation(for:)`, `presentBriefing`, `openFromBriefing`, `toggleBriefingSpeech`, `refreshEditorAfterMaterialMutation` (its two call sites inside `removeMaterialFromBoard` / `performMaterialReorder` were removed), `resolveEditorConflict*`, `applyBoardPositions`, `reorderItem`, `moveItem`, `performBoardReorder`, `setPinned`, `performConfirmation`, `requestDelete/Duplicate/Rename`, `commitRename`, `visibleItems`, `projectStripItems`, `hasVisibleItems`, `updateSearchText`, `beginWorkspace`, `cancelProvisionalWorkspace`, `showEditor`, `consumeEditorFocusRequest`, `saveEditorNow`, `reviewEditorAndSend`, `reviewWorkspaceAndSend`, `shapeEditorDraft`, `applyEditorSuggestion`, `showPreflight`, `selectGateway`, `isMaterialSupported/Included`, `setMaterial(_:included:)`, `includedPreflightMaterialIDs`, `preflightPrompt`, `dispatchPreflight`, `preflightItem`, `selectedGateway`, `editorHasUnsavedChanges`, `canShapeDraft`, `canReadBriefing`.

`load()` no longer races a gateway roster — it is now a single `items = try await dependencies.loadItems()`.
`importWorkspaceMaterialsUnlocked` no longer clears `provisionalWorkspaceID` on first persist; it just adopts `selectedItemID`.

---

## 4. `WorkboardLiveRepository.swift` (1050 → 656)

### NEW init signature (exact)
```swift
init(
    store: ConversationStore = .shared,
    settings: SettingsManager = .shared,
    captureInbox: WorkCaptureInbox = .shared,
    openConversation: @escaping @MainActor (UUID) -> Void,
    openMaterial: @escaping @MainActor (WorkboardMaterialSnapshot) -> Void,
    openGatewaySettings: @escaping @MainActor () -> Void
)
```
`typealias DispatchHandler` and the stored `dispatchHandler` / `shapeDraftHandler` / `readBriefingHandler` / `stopBriefingHandler` are gone.
⚠️ **`private let settings: SettingsManager` is now UNREAD** — its only readers were `loadGateways`/`gatewayDetail`. I kept the parameter because the task specified dropping exactly the four handlers. Byte-sync/capture agent: reuse it or drop it deliberately.

### Deleted members
`loadGateways` · `gatewayDetail` · `saveDraft` · `saveDraftAsCopy` · `duplicateItem` · `reorderItems` · `setState` · `dispatch` · `resultMessages` · `runSnapshot` · `safeFailureMessage`.
`snapshots(for:isCompleteBoard:)` no longer batches messages; `static snapshot(for:localThumbnails:)` lost the `messagesByID:` parameter and the `runs` / `latestStartedDispatch` derivation.

### `WorkboardLiveRepositoryError` cases now
`itemNotFound` · `staleDraft` · `missingPayload` · `invalidLink` · `emptyNote`.
Deleted: `.staleBoardOrder` (only thrower was `reorderItems`), `.derivedState`, `.gatewayUnavailable`.

### SURVIVE
`makeDependencies` · `drainCaptures` · `loadItems` · `snapshots` · `localPresentationThumbnails` · `snapshot(for:)` · `revision(for:)` · `presentationKind` · `materialName` · `materialDetail` · `presentationAvailability` · `importMaterial` · `storageKind` · `reorderMaterials` · `removeMaterial` · `replaceMaterial`.
**Foundation's `.syncedPending` branches in `presentationAvailability` (fails closed) and `materialDetail` (`workboard.material.syncPending`) are untouched.**

---

## 5. `ConversationStore+Workboard.swift` (2443 → ~1293) and `WorkboardRecords.swift` (802 → ~430)

### Store functions DELETED
`fetchRecentWorkItemSummaries` · `reorderWorkItems` · `updateWorkItem` · `saveWorkItemDraft` · `completeWorkItem` · `reopenWorkItem` · `setWorkItemCompletion` · `acknowledgeWorkDispatchReview` · `duplicateWorkItem` · `deleteWorkItem` · `setWorkItemPinned` · `captureWorkDispatch` · `prepareWorkDispatch`.
Private helpers deleted with them: `workDispatchRow` · `conversationRow` · `messageRow` · `workAttachments` · both `workDispatchActivity` overloads · `workSnapshotEncoder` · `workSnapshotDecoder` · `StoredWorkboard.dispatches/.messages` · `StoredDispatchCapture` · `StoredDispatchMaterial` · `StoredWorkDispatch` · `StoredWorkMessage`.

### `WorkItemStateResolver` is gone; state is a CONSTANT (plan-sanctioned)
`StoredWorkItem.record(materials:)` (was `record(materials:dispatches:)`) now returns `state: .draft` with the comment *"Work is one desk of collected material with no lifecycle to derive; the column stays only so a row written by an older build still round-trips."* Both former resolver call sites are gone (the second lived inside `prepareWorkDispatch`).

### `WorkboardRecords.swift` deletions
`WorkDispatchActivity` · `WorkDispatchStateFacts` · `WorkItemStateResolver` · `WorkDispatchMessageFact` · `WorkDispatchReplyCorrelation` · `WorkItemBoardPosition` · `WorkItemBoardReorder` · `WorkboardMaterialVersion` · `CapturedWorkMaterial` · `CapturedWorkDispatch` · `WorkMaterialSnapshot` · `WorkBriefSnapshot` · `WorkDispatchRecord` · `WorkDispatchPreparation` · `PreparedWorkDispatch` (+ its `// MARK: - Immutable dispatch snapshot`).
`WorkItemRecord` lost `dispatches`, `currentDispatchID`, `latestDispatch`, `unacknowledgedReplyCount`, `unacknowledgedFailureCount`. **Deviation:** the scout only said `currentDispatchID` "becomes unread"; I deleted it (and its `StoredWorkItem` read) because a dispatch id that points at a type that no longer exists is not data, it is a dangling reference. The Core Data COLUMN is untouched.
`WorkboardStoreError`: deleted `.dispatchNotFound`, `.snapshotEncodingFailed`. **Kept `.materialPayloadUnavailable`** though nothing throws it now (byte-sync may want it).
`WorkItemState` KEPT (all four cases, column unchanged). `WorkItemSummary` KEPT (see §Requests, share agent).

### SURVIVING store API that plan §A's `upsertDeskMaterial` must build on
| Symbol | Line (post-purge) | Shape |
|---|---:|---|
| `createWorkItem(_:)` | 33 | `(WorkItemDraft = .init()) async throws -> WorkItemRecord`; throws `.identifierCollision` on a colliding id |
| `fetchWorkItems()` | 65 | whole board |
| `fetchWorkItem(id:)` | 69 | `-> WorkItemRecord?` |
| `fetchWorkItem(captureEnvelopeID:)` | 73 | `-> WorkItemRecord?` |
| `captureMessageToWork(_:conversationID:)` | 81 | Chat→Work; claims-guarded, idempotent on `message.id` |
| **`createWorkItemWithInitialMaterial(_:material:sourceFileURL:sourceFileByteSize:onProgress:)`** | 283 | ONE Core Data save publishes owner + first material; guarded by `workInitialMaterialClaims`; **this is the throw-on-existing branch plan §A says to refactor, not patch** |
| `addWorkMaterial(_:to:expectedOwnerRevision:)` | 388 | returns the EXISTING material when `draft.id` already exists (owner-checked) — the idempotency seed for the upsert |
| `addWorkMaterialFile(_:from:byteSize:to:expectedOwnerRevision:onProgress:)` | 428 | same existing-row shortcut |
| `insertWorkMaterial(...)` (private) | 460 | the shared write |
| `replaceWorkMaterialPayloadFile(...)` | 522 | reattach path |
| `deleteWorkMaterial(...)` | 583 | **blob paired-delete (plan §C) hangs here** |
| `reorderWorkMaterials(itemID:orderedMaterialIDs:expectedOwnerRevision:)` | 633 | |
| `setWorkMaterialCardSize(...)` | 680 | revision-neutral |
| `loadWorkMaterial(id:)` / `loadWorkMaterialPayload(id:)` | 714 / 719 | `.syncedPayload` still reads the `payload` column — **byte-sync agent rewrites this to the blob read** |
| `localURLForWorkMaterial(id:)` | 743 | |
| `fetchWorkMaterial(id:)` (private) | 753 | one row + one `await vault.contains` — one of the two per-row awaits plan §C says to batch |
| `fetchWorkItems(itemID:captureEnvelopeID:)` (private) | 767 | the projection; the `workItemID IN` material fetch + per-key `await vault.contains` loop is at ~805-815 |
| `deduplicatedWorkItems` / `deduplicatedWorkMaterials` | 821 / 838 | **unchanged — plan §A's "no dedup pass" relies on these** |
| `reconcileWorkAssetVault(...)` | 867 | |
| `StoredWorkItem.record(materials:)` | 1105 | constant `.draft` |
| **`StoredWorkMaterial.record(availableLocalKeys:)`** | **1173** | the MaterialRow projection. foundation.md pointed at `:2202-2237`; **it is now `:1173`**. The `case .syncedPayload: availability = .synced` branch is at `:1178-1180` and `hasPayload` at `:1197` — unchanged, still the exact spot foundation's `.syncedPending` work lands. |
| the three `_…ForTesting` probes | 1223 / 1248 / 1275 | inside `#if CONDUCK_TESTING` |

---

## 6. Call-site removals in files I do not own (step 5 + step 7)

Minimal where possible; where a type referenced ≥1 deleted symbol in nearly every line AND is on the next agent's DELETE-ENTIRELY table, I deleted the type rather than leaving nonsense. All of these are listed so nobody re-searches for them.

**`ConduckApp.swift`** — 2 `WorkboardUploadJournal.shared.reconcile()` sites; `WorkboardProjectCommands()` + its 3-line comment in `.commands` (⌘E rename menu is gone). ⌘1 "Workboard" / ⌘2 "Chats" KEPT.
**`AppDelegate.swift`** — 1 `reconcile()` site (enclosing `Task` still does `performInitialSync` + `refreshIfNeeded`).
**`PersonalWorkbenchView.swift`** — `WorkboardBriefingSpeaker` type, the `speaker` property/construction/assignment, the whole `shapingHandler` block, the four dying repository init args; `reconcileDurableWorkStorage()` now only calls `reconcileWorkAssetVault()`. `PersonalWorkbenchRouter`, `WorkCaptureRefreshCoordinator`, preview plumbing, `WorkbenchSectionControl`, the 4 notification names — all KEPT. `routeWorkboardDeepLink` KEPT unchanged (still sets `selectedItemID` from the payload — capture agent retargets it).
**`WorkboardView.swift` (1317 → 431)** — presentation modifier lost the preflight sheet, the briefing sheet, the confirmation dialog, the rename alert, `openItem`, `selectInitialWideItemIfNeeded` + its two `onChange`, `hasAppliedInitialSelection`, `renameIsPresented`, `renameFieldText`, `confirmationIsPresented`, `activeBriefingPresentation`, `preflightIsPresented`, `confirmationTitle`, `confirmationMessage`; `tutorialGate.isBlocked` is now `notice != nil` only; `dismissTransientPresentations` clears `notice` only; the free function `openWorkboardItem` is gone. **`WorkboardSidebarColumn` is now a STUB** (nav title + one Settings row) — it kept its type and its four stored properties so `WorkboardExperience.sidebarColumn` and `MainWindowView`'s mount still compile. Deleted whole: `WorkboardSidebarSectionHeader`, `WorkboardSidebarRow`, `WorkboardProjectCanvas`, `WorkboardProjectDropRail`, `WorkboardReorderCard`. `WorkboardDetailColumn` lost `overview`, `emptyBoard`, `openItem`, `beginNewWorkspace` and the provisional branch; its `else` arm is now the **desk-before-first-material** canvas keyed on `emptyWorkspaceID` with `workboard.empty.title` (this is the arm plan §A retargets to `Constants.workboardDeskItemID`). Loading + load-error branches and `captureWorkspace`/`captureBar` KEPT.
**`WorkboardComponents.swift`** — inside `WorkboardCard`: the `latestRun` status row, the `latestRun` a11y line, the `hasChangesSinceLastSend` badge + a11y line, and the `runTint(_:)` helper. Deleted the entire trailing `#if os(macOS)` block (`WorkboardProjectCommandTarget`, `WorkboardProjectCommandTargetKey`, the `FocusedValues` extension, `WorkboardProjectCommands`) — it called four deleted VM methods. Everything else in that file is UNTOUCHED and still on your trim table.
**`WorkboardCaptureCanvas.swift`** — `isReviewing` / `reviewTask` state, their three guard sites, `reviewAndSendButton`, `reviewAndSend()`, and the `ViewThatFits` row in `expandedComposer` that hosted the button. `.full` mode, `WorkboardCaptureDestination`, everything else UNTOUCHED.
**`WorkboardDetailView.swift`** — the `#if os(macOS)` `focusedSceneValue(\.workboardProjectCommandTarget, …)` block (S6; it was the only producer). `itemID` lookup and the missing-item branch KEPT (yours).
**`MainWindowView.swift`** — the zero-size ⌘⇧N New Work button only (it called `beginWorkspace`). The 3 `@SceneStorage` keys, `workboardExperience(for:)`, both column mounts, `mountsWorkLayer`, the `.presentationModifier` and the toolbar anchors are UNTOUCHED — **the macOS shell rewrite (plan §B Codex #10c) is still entirely yours.**
**`ShareTargetsSnapshotWriter.swift`** — `build()` now sets `let recentWorkItems: [ShareTargetsSnapshot.RecentWorkItem] = []` with a comment naming the one-desk reason. `makeRecentWorkItems` and `maximumRecentWorkItems` are LEFT IN PLACE but now have no production caller. **The three `ShareTargetsSnapshot.swift` mirrors were NOT touched.**
**`scripts/check-storage-seam.sh`** — removed the `WorkboardUploadJournal.swift` `CONTAINER_ALLOWLIST` row + its 2-line comment (R6). Script still passes: 766 files.
**`AppShortcuts.swift`** — the `BriefWorkboardIntent` `AppShortcut` entry. `CaptureWorkboardIntent` entry unchanged (identifier stable, R9).

File headers I rewrote because they asserted a layer that no longer exists (present tense, no changelog narration): `WorkboardViewModel.swift`, `WorkboardLiveRepository.swift`, `ConversationStore+Workboard.swift`, `WorkboardRecords.swift`, `WorkboardView.swift`, `WorkboardDetailView.swift`, `WorkboardComponents.swift`, `WorkboardCaptureCanvas.swift`, `PersonalWorkbenchView.swift`. Same for ~10 in-file doc comments that named preflight/dispatch/the editor.

**NOT touched, as instructed:** watch target, both share extensions, `WorkCaptureInbox`, `WorkCaptureDrainer`, `CaptureWorkboardIntent`, `WorkAssetVault`, `WorkCaptureEnvelope`/`ShareTargetsSnapshot` mirrors, `AgentDownloadScratch` (R10 left alone), `Localizable.xcstrings`, the xcdatamodeld.

---

## 7. Foundation preserved (verified by grep after the purge)

`Constants.workboardDeskItemID` (`Constants.swift:2102`) · `Constants.workboardSyncCeilingBytes` (`:2112`) · `WorkMaterialStoragePolicy.swift` (untouched, still zero call sites) · `WorkMaterialKind.audio` (`WorkboardRecords.swift:149`) · `WorkMaterialAvailability.syncedPending` (`:215`) · `WorkMaterialBlobRecord` + `isComplete` (`:368`) · `workboard.material.syncPending` (`WorkboardLiveRepository.swift:380`) · `Conversations 16` + `.xccurrentversion` (`git status` shows the model dir clean) · `Localizable.xcstrings` clean in `git status`.
The two one-line enum-case additions foundation made in `WorkBriefPromptBuilder.swift` / `WorkboardDispatchCoordinator.swift` died with those files, exactly as foundation predicted; the `.file, .audio` mapping is preserved in the re-homed `presentationKind`.

---

## 8. Test fallout — the next agent's compile map (I did NOT touch `ConduckTests`)

**Delete whole (every top-level symbol they exercise is gone):**
`WorkBriefAssistantTests.swift` · `WorkBriefPromptBuilderTests.swift` (also declares `WorkBriefFixtures` — R2) · `WorkItemStateResolverTests.swift` · `WorkboardDispatchCoordinatorTests.swift` · `WorkboardUploadJournalTests.swift` · `WorkboardOrderingTests.swift`.

**Split (file survives, cases die) — deleted symbols each one references:**
| File | Deleted symbols it touches |
|---|---|
| `WorkboardWorkspaceCaptureTests.swift` | `Dependencies.{loadGateways,saveDraft,saveDraftAsCopy,deleteItem,duplicateItem,reorderItems,setState,acknowledgeRun,dispatch,setPinned}` · `WorkboardEditDraft` · `WorkboardGatewayChoice` · `beginWorkspace` · `provisionalWorkspaceID` · `showEditor` · `saveEditorNow` · `reviewEditorAndSend` · `reviewWorkspaceAndSend` · `requestRename` · `commitRename` · `reorderItem` · `setPinned` · `editingDraft` · `.runs` · `lastSentRevision` · `hasChangesSinceLastSend` |
| `WorkboardPersistenceTests.swift` | `WorkDispatchPreparation` · `WorkBriefSnapshot` · `WorkMaterialSnapshot` · `WorkboardMaterialVersion` · `prepareWorkDispatch` · `acknowledgeWorkDispatchReview` · `duplicateWorkItem` · `deleteWorkItem` · `updateWorkItem` · `completeWorkItem` · `reopenWorkItem` · `fetchRecentWorkItemSummaries` (`:146,151,153`). `WorkboardRevision` still resolves (re-homed). **Re-home the "delete-all preserves Work materials" half of `:617` per plan §F.** |
| `WorkboardBoardProjectionTests.swift` | `WorkboardFilter` · `WorkboardGatewayChoice` · `WorkboardDispatchReceipt` · `WorkboardRunSnapshot` · `WorkboardPresentationLogic` · `WorkboardBoardOrdering` · `dispatchPreflight` · `visibleItems` · `projectStripItems` · `updateSearchText` · `searchCorpus` · `beginWorkspace` · `cancelProvisionalWorkspace` · `loadGateways` · `saveDraftAsCopy` |
| `WorkboardMaterialBoardActionsTests.swift` | `WorkBriefFixtures` (`:392-417`, R2) · `WorkBriefShapingSource` · `WorkboardEditDraft` · `showEditor` · `editingDraft` · `lastSentRevision` · `hasChangesSinceLastSend` · `loadGateways` · `saveDraftAsCopy` · `reorderItem` |
| `WorkboardLiveRepositorySupportTests.swift` | `WorkboardRunSnapshot` · `WorkboardPresentationLogic` · `searchCorpus` |
| `ConversationStoreAtomicWorkCaptureTests.swift` | `WorkItemBoardPosition` · `WorkItemBoardReorder` · `reorderWorkItems` · `saveWorkItemDraft` |
| `WorkCaptureDrainerTests.swift` | `store.completeWorkItem` at `:147` and `:183` — **not on the scout's split list; it will not compile** |
| `ConversationStoreWorkCaptureTests.swift` | `XCTAssertTrue(item.dispatches.isEmpty)` at `:70` — **not on the scout's list; it will not compile** (the assertion is now vacuous — delete the line) |

**Behavioural (compiles, will FAIL):** `ShareTargetsSnapshotTests.swift` and `ShareTargetsSnapshotWriterColorTests.swift` — any case asserting a populated `recentWorkItems` now sees `[]`. `ShareTargetsSnapshotWriterColorTests:74` only *mentions* `fetchRecentWorkItemSummaries` in a comment.

**`ErrorSurfaceDriftGuardTests` — NO pruning needed (delta vs scout R3):** both registry rows still name live files (`WorkboardView.swift`, `WorkboardVoiceCaptureView.swift`) and both retry controls survive (the load-retry `WorkboardEmptyState` is still in `WorkboardDetailColumn`). Leave the rows alone unless the next view agent deletes one of those files.

**`ConduckWatchSmokeTests`** — untouched by me; `:36`'s "writes one `WorkItem` and zero `WorkDispatch`/`Conversation`/`Message` rows" is now trivially true, not false.

---

## Catalog

**Keys I ADDED in source: NONE.** I did not open `Localizable.xcstrings`.

**Keys now DEAD in source because of this purge (124, computed by diffing every `String(localized:"…")` / `LocalizedStringResource("…")` literal in non-test `Conduck/` sources against `HEAD`).** This is a *contribution to* the plan's bidirectional audit, not the audit itself — re-verify before deleting, and note the macro-composed `Add ${thought} to Work` is NOT in this list and must never be deleted on a no-reference signal.

`intent.workboardBrief.description` · `intent.workboardBrief.title` · `workboard.briefMe` · `workboard.briefing.clear` · `workboard.briefing.clear.message` · `workboard.briefing.clear.title` · `workboard.briefing.heading` · `workboard.briefing.item.accessibility` · `workboard.briefing.item.hint` · `workboard.briefing.nothingOpen` · `workboard.briefing.private` · `workboard.briefing.readAloud` · `workboard.briefing.spoken.draft` · `workboard.briefing.spoken.failure` · `workboard.briefing.spoken.reply` · `workboard.briefing.spoken.waiting` · `workboard.briefing.stopReading` · `workboard.briefing.title` · `workboard.briefing.update.format` · `workboard.confirm.delete.action` · `workboard.confirm.delete.message` · `workboard.confirm.delete.title` · `workboard.confirm.duplicate.action` · `workboard.confirm.duplicate.message` · `workboard.confirm.duplicate.title` · `workboard.conflict.copy.failed.title` · `workboard.conflict.reload.failed.title` · `workboard.dispatch.failed.title` · `workboard.editor.reviewAndSend` · `workboard.editor.reviewAndSend.hint` · `workboard.empty.filtered.action` · `workboard.empty.filtered.message` · `workboard.empty.filtered.title` · `workboard.error.alreadyStarted` · `workboard.error.derivedState` · `workboard.error.fileServerRequired` · `workboard.error.fileTransferFailed` · `workboard.error.gatewayUnavailable` · `workboard.error.itemChanged` · `workboard.error.materialChanged` · `workboard.error.materialUnavailable` · `workboard.error.previewMismatch` · `workboard.error.staleBoardOrder` · `workboard.error.unsupportedMaterial` · `workboard.filter.all` · `workboard.filter.changed` · `workboard.filter.done` · `workboard.filter.drafts` · `workboard.filter.help` · `workboard.filter.needsYou` · `workboard.filter.open` · `workboard.filter.title` · `workboard.filter.waiting` · `workboard.gateway.configured.status` · `workboard.gateway.custom` · `workboard.gateway.hosted` · `workboard.gateway.load.failed.title` · `workboard.gateway.selfHosted` · `workboard.item.accessibility.latestRun` · `workboard.item.changedAfterSend` · `workboard.item.copyTitle` · `workboard.material.item` · `workboard.material.unsupported.fileTransfer` · `workboard.newBrief` · `workboard.overview.hint` · `workboard.overview.title` · `workboard.preflight.compatibility.images` · `workboard.preflight.compatibility.title` · `workboard.preflight.compatibility.unavailable` · `workboard.preflight.compatibility.unavailable.one` · `workboard.preflight.compatibility.unsupported` · `workboard.preflight.compatibility.unsupported.one` · `workboard.preflight.eyebrow` · `workboard.preflight.gateway.accessibility` · `workboard.preflight.gateway.caption` · `workboard.preflight.gateway.configure` · `workboard.preflight.gateway.empty` · `workboard.preflight.gateway.notSelected` · `workboard.preflight.gateway.selected` · `workboard.preflight.gateway.title` · `workboard.preflight.intro` · `workboard.preflight.material.accessibility` · `workboard.preflight.materials.caption` · `workboard.preflight.materials.title` · `workboard.preflight.missing.message` · `workboard.preflight.missing.title` · `workboard.preflight.promise.binding` · `workboard.preflight.promise.done` · `workboard.preflight.promise.reviewBy` · `workboard.preflight.promise.snapshot` · `workboard.preflight.prompt.caption` · `workboard.preflight.prompt.title` · `workboard.preflight.send` · `workboard.preflight.send.chooseFirst` · `workboard.preflight.send.hint` · `workboard.preflight.sendTo` · `workboard.preflight.sending` · `workboard.preflight.sendingTo` · `workboard.preflight.title` · `workboard.projectShelf.new.caption` · `workboard.projectShelf.new.hint` · `workboard.projectShelf.pinned.subtitle` · `workboard.projectShelf.pinned.title` · `workboard.projectShelf.subtitle` · `workboard.projectShelf.title` · `workboard.rename.message` · `workboard.rename.prompt` · `workboard.rename.title` · `workboard.review.acknowledge.failed.title` · `workboard.run.cancelled` · `workboard.run.conversationRemoved` · `workboard.run.failed` · `workboard.run.failed.generic` · `workboard.run.replied` · `workboard.run.sending` · `workboard.run.waiting` · `workboard.save.failed.title` · `workboard.search.private` · `workboard.search.prompt` · `workboard.shape.failed.title` · `workboard.voice.objective` · `workboard.workspace.captured` · `workboard.workspace.new.title` · `workboard.workspace.sidebar.privacy`

Plus the AppShortcuts bare-English entries extracted from `BriefWorkboardIntent`'s removed `AppShortcut`: `"Brief My Workboard"`, `"Brief my Workboard in ${applicationName}"`, `"What needs me in ${applicationName}"`.

**STILL REFERENCED — do not delete on a stale scout row:** `workboard.title` (sidebar stub + the ⌘1 menu) · `workboard.empty.title` (the desk-before-first-material headline, moved into `WorkboardDetailColumn`) · `workboard.action.failed.title` · `workboard.error.staleDraft` · `workboard.item.untitled` · `workboard.voice.context` · `workboard.material.{image,file,link,note,localOnly,unavailableHere,syncPending}` · `workboard.loading` · `workboard.load.failed.{title,message}` · `workboard.load.retry` · `workboard.action.{rename,duplicate,delete}` / `workboard.pin` / `workboard.unpin` / `workboard.item.pinned` / `workboard.item.accessibility.{materials,materials.one,reviewBy}` / `workboard.item.open.hint` (all still referenced by `WorkboardCard` / `WorkboardProjectActionTitle`, which the NEXT view agent deletes — re-run the audit after that trim).

---

## Requests

1. **Test agent (next):** §8 is your map. Nothing in `ConduckTests` was touched. Two files are NOT on the scout's split list but will not compile: `WorkCaptureDrainerTests.swift` (`completeWorkItem` ×2) and `ConversationStoreWorkCaptureTests.swift` (`item.dispatches`). Predicted counts in scout §6 do not account for those two.
2. **View-trim agent:** `WorkboardSidebarColumn` is a stub with four now-unused stored properties; `WorkboardExperience` still hands the host `showsOverview` / `emptyWorkspaceID` / `preferredCompactColumn` / `columnVisibility`; `MainWindowView` still mounts `.sidebarColumn` and still owns the 3 `@SceneStorage` keys. The macOS shell rewrite (Codex #10c: Work = collapsed sidebar column, Chats = Chat sidebar returns) is untouched and still yours, as is the whole `WorkboardComponents` table and the `WorkboardCaptureCanvas` `.full` / `WorkboardCaptureDestination` collapse. Please also drop `WorkboardItemSnapshot.{state,isPinned,boardOrder}` when `WorkboardCard`/`WorkboardStateBadge`/`extension WorkItemState` go.
3. **Capture agent (plan §A):** the desk-before-first-material arm is `WorkboardDetailColumn`'s final `else`, keyed on the rotating `@State emptyWorkspaceID` — that is the id to replace with `Constants.workboardDeskItemID`. `PersonalWorkbenchView.routeWorkboardDeepLink` still resolves an arbitrary `workItemID`. `WorkboardViewModel` no longer has `beginWorkspace` / `provisionalWorkspaceID`, so there is no provisional lane left to reconcile.
4. **Share agent:** `ShareTargetsSnapshotWriter.build()` now publishes an empty `recentWorkItems` (I deleted `fetchRecentWorkItemSummaries`, as instructed). `makeRecentWorkItems` and `WorkItemSummary` survive with no production caller — delete them with the picker. The six-file lockstep (`ShareView.swift` ×2, both extension `.xcstrings`, `WorkCaptureInboxTests:311`, `ShareTargetsSnapshotTests:252`) and the three `ShareTargetsSnapshot.swift` mirrors are untouched.
5. **Byte-sync agent:** `loadWorkMaterialPayload` (`:719`) still reads the `payload` column for `.syncedPayload`; the per-row `await workAssetVault.contains` loops survive at `fetchWorkMaterial` (`:753`) and inside `fetchWorkItems` (~`:805-815`). `WorkboardLiveRepository`'s `settings` property is now unread — take it or drop it.
6. **Docs agent:** `spec.md` still describes the dispatch/brief/preflight layer and Workboard lifecycle states as live. Nothing here is only a copy change: `WorkItemState` is now a constant `.draft`, `WorkDispatch` has no Swift representation, and `WorkboardUploadJournal` is gone.

---

## Gates run (exact lines)

- iOS `xcodebuild build` (iPhone 17 Pro `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`, no `-configuration`, derivedData `~/Library/Caches/gigaduck-builds/desk-purge-core/DerivedData`) → **`** BUILD SUCCEEDED **`**, `grep -c ': error: '` = **0**. Products confirm `Conduck.app` + `PlugIns/ConduckShareExtension.appex` + `Watch/ConduckWatch Watch App.app` all built.
- macOS `xcodebuild build -destination 'platform=macOS'` → **`** BUILD SUCCEEDED **`**, `grep -c ': error: '` = **0**. Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback was needed.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 766 Swift files scanned, no raw store or live-adapter access…`
- `git diff --check` → clean.
- **Tests: NOT RUN.** The test bundle cannot compile until the §8 surgery lands; running `xcodebuild test` now would only reprint the §8 list as compile errors. No test file was edited, no assertion was weakened or deleted.
- Logs were written to `~/Library/Caches/gigaduck-builds/desk-purge-core/{ios-build-final,mac-build-final}.log` and grepped there; that slug dir has since been removed via `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-purge-core` (`removed: desk-purge-core`), so the logs no longer exist — re-run the two builds if you need them.
