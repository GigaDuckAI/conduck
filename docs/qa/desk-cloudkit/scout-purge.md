# Workboard purge dependency graph

Worktree `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`, branch `feature/agent-workboard` @ 651a859. All paths below are relative to that root; prefix with it for absolute.

---

## 0. Orientation — three findings that reshape the plan

**(a) `WorkboardDetailView.swift` is already the new desk.** Its own header (`Conduck/Conduck/Views/Workboard/WorkboardDetailView.swift:6`) reads *"The desk. One project's board and nothing that competes with it."* Body = board + pinned composer + pane-wide drop, 93 lines. It is the highest-value survivor, not a delete — **REPURPOSE**, stripping `itemID` lookup (`:22`), the `focusedSceneValue` block (`:66-77`) and the missing-item branch (`:78-90`).

**(b) macOS does not mount `WorkboardView`.** `MainWindowView.swift:528-544` builds a `WorkboardExperience` and consumes its three pieces separately — `.sidebarColumn` (`:558`), `.detailColumn` (`:586`), `.presentationModifier` (`:321`). Deleting the sidebar column without reworking `MainWindowView` breaks the Mac build. This is the single largest surviving-caller item.

**(c) The single desk has no identity yet.** Nothing in the codebase creates a known/singleton `WorkItem`. Every capture surface either targets an explicit `targetWorkItemID` or creates a fresh row (`WorkCaptureDrainer.swift:207`, `CaptureWorkboardIntent.swift:62`, `ConversationStore+Workboard.swift:709`). The purge **requires a new "resolve-or-create the one desk item" seam** before the capture surfaces can retarget. See §8 R1.

---

## 1. DELETE-WHOLE

| File | LOC | Inbound refs from surviving code |
|---|---:|---|
| `Conduck/Conduck/Services/Workboard/WorkboardDispatchCoordinator.swift` | 655 | `WorkboardDispatchCoordinator.shared.dispatch` ← `PersonalWorkbenchView.swift:768` (only prod site) |
| `Conduck/Conduck/Services/Workboard/WorkBriefAssistant.swift` | 110 | `.availability` ← `PersonalWorkbenchView.swift:746`; `.shared.shape` ← `:752` |
| `Conduck/Conduck/Services/Workboard/WorkBriefPromptBuilder.swift` | 273 | `.build` ← `WorkboardDispatchCoordinator.swift:123` (dies), `WorkboardViewModel.swift:1013` (dies with `preflightPrompt`). Also defines `extension WorkBriefMaterialPacket` (`:61`) and consumes `WorkboardPromptComposer` |
| `Conduck/Conduck/Services/Workboard/WorkboardBriefingBuilder.swift` | 108 | `.build` ← `WorkboardViewModel.swift:758`, `BriefWorkboardIntent.swift:33` — both die |
| `Conduck/Conduck/Services/Workboard/WorkboardUploadJournal.swift` | 392 | **4 surviving call sites**: `ConduckApp.swift:445`, `ConduckApp.swift:645`, `AppDelegate.swift:212`, `PersonalWorkbenchView.swift:958` — all `await WorkboardUploadJournal.shared.reconcile()`. Plus dispatch-internal uses at `WorkboardDispatchCoordinator.swift:145,148,221,572,617,633` |
| `Conduck/Conduck/Views/Workboard/WorkboardBriefingView.swift` | 228 | `WorkboardView.swift:185` (sheet) |
| `Conduck/Conduck/Views/Workboard/WorkboardDispatchSheet.swift` | 612 | `WorkboardView.swift:181` (sheet) |
| `Conduck/Conduck/Intents/BriefWorkboardIntent.swift` | 47 | `AppShortcuts.swift:47` (`AppShortcut(intent:)`) |

**Production LOC deleted whole: 2,425.**

Not on this list, deliberately: `WorkItemStateResolver` lives *inside* `WorkboardRecords.swift:109-138` (not its own file) — see §2.

---

## 2. TRIM — files that survive minus symbols

### `Conduck/Conduck/Views/Workboard/WorkboardView.swift` (1317 → ~250)
The heaviest trim in the tree.

| Range | Symbol | Verdict |
|---|---|---|
| `12-39` | `WorkboardView` | REWORK — drops `showsOverview`/`emptyWorkspaceID`/`preferredCompactColumn`/`columnVisibility` (`:18-24`) |
| `48-113` | `WorkboardExperience` | REWORK — the `NavigationSplitView` (`:62-70`) collapses to one pane; `sidebarColumn` (`:82-90`) deleted, `detailColumn`/`presentationModifier` kept as values (MainWindowView depends on them) |
| `179-183` | preflight sheet | DELETE |
| `184-190` | briefing sheet | DELETE |
| `228-261` | duplicate/delete `confirmationDialog` | DELETE |
| `262-290` | rename `alert` | DELETE |
| `293-300` | `openItem` | DELETE |
| `307-321` | `WorkboardTutorialGate` | TRIM — `:315-319` drops `preflightItemID`/`briefing`/`confirmation`/`renameRequest`, keeps `notice` |
| `361-370` | `selectInitialWideItemIfNeeded` | DELETE (reads `$0.state != .done`, `attentionSort`) |
| `377-394` | `renameIsPresented` / `renameFieldText` | DELETE |
| `396-409` | `confirmationIsPresented`, `activeBriefingPresentation` | DELETE |
| `425-436` | `preflightIsPresented` | DELETE |
| `442-450` | `dismissTransientPresentations` | TRIM to `notice` only (`:446`) |
| `452-487` | `confirmationTitle`, `confirmationMessage` | DELETE |
| `490-504` | `openWorkboardItem` free function | DELETE |
| `508-785` | **`WorkboardSidebarColumn`** (search field, filter menu, state-lane `List`, swipe actions, `sidebarToolbar`, `sidebarFooter` incl. Brief My Work `:747-758`) | DELETE ENTIRELY (278 L) |
| `790-981` | `WorkboardDetailColumn` | TRIM HARD — `:801-834` loading/loadError kept; `:835-837` `WorkboardDetailView` dispatch kept; `:838-856` provisional branch + `overview` DELETE; `:859-921` `overview`/`emptyBoard` DELETE except the `workboard.empty.title` copy at `:896-899`; **`captureWorkspace` `:941-964` and `captureBar` `:966-980` SURVIVE — these are the desk** |
| `983-998` | `WorkboardSidebarSectionHeader` | DELETE |
| `1000-1046` | `WorkboardSidebarRow` | DELETE |
| `1052-1216` | `WorkboardProjectCanvas` (+ `projectShelf`, `newWorkCard`) | DELETE (165 L) |
| `1221-1258` | `WorkboardProjectDropRail` | DELETE |
| `1260-1317` | `WorkboardReorderCard` | DELETE |

Kept: tutorial sheet (`:144-149`), `workspaceStatus` toast (`:191-217` + `:208-217` timer), notice alert (`:218-227`), tutorial gate machinery (`:323-359`).

### `Conduck/Conduck/Views/Workboard/WorkboardComponents.swift` (1002 → ~560)

| Range | Symbol | Verdict |
|---|---|---|
| `18-25` | `WorkboardMetrics` | KEEP — 15 consumers incl. `WorkboardCaptureCanvas.swift:486,561,582,1477` |
| `27-42` | `UTType.conduckWorkboardCard` / `.conduckWorkboardMaterial` | TRIM — `.conduckWorkboardCard` (`:30`) dies with project drag; `.conduckWorkboardMaterial` (`:37`) survives |
| `44-52` | `WorkboardCardDragPayload` | DELETE — only consumers `WorkboardView.swift:1239,1288` + `WorkboardComponents.swift:302` |
| `55-62` | `WorkMaterialDragPayload` | KEEP — `WorkboardCaptureCanvas.swift:1180,1198,1246` |
| `66-127` | `extension WorkItemState` (`title`/`systemImage`/`tint`/`attentionTitle`/`attentionRank`/`attentionOrder`) | DELETE — the state machine's only presentation. Consumers: `WorkboardStateBadge:135,138,141`, `WorkboardView:595,989,1017`, `WorkboardBriefingView:161`, `WorkboardCard` — all die |
| `129-151` | `WorkboardStateBadge` | DELETE — **zero external references already** |
| `153-176` | `WorkboardSectionHeader` | DELETE — sole consumer `WorkboardBriefingView.swift:161` |
| `178-191` | `WorkboardProjectActionTitle` | DELETE |
| `198-225` | `workboardProjectActions(...)` | DELETE — consumers `WorkboardView.swift:677`, `WorkboardComponents.swift:979` |
| `227-457` | `WorkboardCard` | DELETE (231 L) — sole consumer `WorkboardView.swift:1270` |
| `458-483` | `View` ext (`workboardInlineNavigationTitle`, `workboardDesktopSheetFrame`) | KEEP — `PersonalWorkbenchView:1201`, `WorkboardTextMaterialSheet:106`, `WorkboardTutorialView:64` |
| `484-511` | `WorkboardSurface` | KEEP (only surviving consumer `WorkboardCaptureCanvas.swift:117`, inside the dying `.full` branch — **keep the type, it is the natural desk container**) |
| `512-539` | `WorkboardMaterialIcon` | KEEP — `WorkboardCaptureCanvas.swift:1632,1634` + tests |
| `540-669` | `WorkboardMaterialTile` | DELETE — **already dead**, zero instantiations anywhere |
| `670-710` | `WorkboardEmptyState` | KEEP — surviving consumer none after trim; **retain for the empty desk** (`WorkboardView:902` copy moves here) |
| `711-756` | `WorkboardAutosaveStatus` | DELETE — **already dead**, zero instantiations |
| `757-797` | `WorkboardMaterialRoute` | DELETE — **already dead**, zero references outside its own declaration |
| `798-880` | `WorkboardMaterialActions` | KEEP — `WorkboardCaptureCanvas.swift:438` |
| `881-939` | `WorkboardLargeImportConfirming` + `workboardLargeImportAlert` | KEEP — canvas `:196,872` |
| `941-1001` | `#if os(macOS)` `WorkboardProjectCommandTarget`, `WorkboardProjectCommandTargetKey`, `FocusedValues` ext, `WorkboardProjectCommands` | DELETE ENTIRE BLOCK (61 L) |

### `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` (1948 → ~1870)
Survives almost intact. Trim:
- `15-19` `WorkboardCaptureCanvasMode` → `.full` case DELETE (**never instantiated**: only `.sources` and `.composer` appear, at `WorkboardDetailView:34,46` and `WorkboardView:953,973`)
- `74`, `83` default `= .full` → change default
- `116-123` the `else if mode == .full` branch DELETE
- `421-435` `expandedComposer` DELETE (only `.full` used it)
- `545-576` `reviewAndSendButton` DELETE
- `650-664` `reviewAndSend()` DELETE — the last prod caller of `viewModel.reviewWorkspaceAndSend`
- `100-101` `isReviewing` / `reviewTask` state, and `260-265` in `dismissTransientCaptureUI` → DELETE
- `21-45` `WorkboardCaptureDestination` → collapses to one case (see §8 R5)
- `569-571` the `item.isReadyToSend` gate disappears with the button

### `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` (1244 → ~1130)
- `588-616` `WorkboardBriefingSpeaker` DELETE
- `740` `speaker` stored property, `744` construction, `845` assignment DELETE
- `745-764` the whole `shapingHandler` block DELETE
- `766-781` `WorkboardLiveRepository(...)` init → drop `dispatch:` (`:767-772`), `shapeDraft:` (`:778`), `readBriefingAloud:` (`:779`), `stopBriefingAloud:` (`:780`)
- `956-961` `reconcileDurableWorkStorage()` TRIM → drop `WorkboardUploadJournal.shared.reconcile()` (`:958`), keep `reconcileWorkAssetVault()` (`:959`)
- `971-981` `routeWorkboardDeepLink` → `:978` `selectedItemID = itemID` becomes a no-op; retarget or delete the deep link
- KEEP: `PersonalWorkbenchRouter` (`:320-575`), `WorkCaptureRefreshCoordinator` (`:627-730`), preview sheet plumbing, `WorkbenchSectionControl`, layer modifiers

### `Conduck/Conduck/Models/WorkboardRecords.swift` (802)
- `109-138` `WorkItemStateResolver` DELETE — callers `ConversationStore+Workboard.swift:1547,2141`, `WorkboardDispatchCoordinator.swift:485`
- `30-83` `WorkDispatchActivity`, `85-107` `WorkDispatchStateFacts`, `140-144` `WorkDispatchMessageFact`, `146-188` `WorkDispatchReplyCorrelation` → orphaned once the resolver goes
- `293-334` `WorkItemBoardPosition` / `WorkItemBoardReorder` DELETE (project reorder)
- `18-28` `WorkItemState` — **keep the enum** (Core Data column stays per the no-migration rule), delete only its presentation extension in Components
- `250-283` `WorkItemRecord` → `dispatches` (`:265`), `currentDispatchID` (`:263`), `latestDispatch` (`:268`), `unacknowledgedReplyCount` (`:272`), `unacknowledgedFailureCount` (`:276`) become unread
- `285-291` `WorkItemSummary` KEEP (share-sheet picker, conditional)

### `Conduck/Conduck/Intents/AppShortcuts.swift`
- `44-54` the `BriefWorkboardIntent` `AppShortcut` entry DELETE (2 phrases + shortTitle)
- `56-67` `CaptureWorkboardIntent` entry KEEP

### `Conduck/Conduck/ConduckApp.swift`
- `351-354` comment + `WorkboardProjectCommands()` DELETE
- `445`, `645` `await WorkboardUploadJournal.shared.reconcile()` DELETE
- `338-350` ⌘1 "Workboard" / ⌘2 "Chats" `CommandGroup` KEEP

### `Conduck/Conduck/AppDelegate.swift`
- `212` `await WorkboardUploadJournal.shared.reconcile()` DELETE (check whether the enclosing `Task`/function has other work)

### `Conduck/Conduck/Views/Conversation/MainWindowView.swift`
- `142-144` `@SceneStorage("workboard.showsOverview")`, `workboardEmptyWorkspaceID`, `workboardPreferredCompactColumn` → rework
- `528-544` `workboardExperience(for:)` → new signature
- `546-571` `mountedSidebarDestinations`: the `if let personalWorkbenchModel, mountsWorkLayer` block (`:557-569`) mounting `.sidebarColumn` DELETE; Chat's sidebar then owns that column unconditionally
- `584-607` `mountedDetailDestinations`: `.detailColumn` mount KEEP (`:586`); the zero-size ⌘⇧N New Work button (`:596-607`) DELETE
- `319-321` `.modifier(workboardExperience(...).presentationModifier)` KEEP
- `524-526` `mountsWorkLayer` KEEP

---

## 3. SURVIVING CALLERS — the retarget/removal work items

| # | Site | Call | Action |
|---|---|---|---|
| S1 | `PersonalWorkbenchView.swift:766-781` | repository init with 4 dying closures | Rewrite `WorkboardLiveRepository.init` signature |
| S2 | `PersonalWorkbenchView.swift:768` | `WorkboardDispatchCoordinator.shared.dispatch` | Delete |
| S3 | `PersonalWorkbenchView.swift:746,752` | `WorkBriefAssistant` | Delete |
| S4 | `PersonalWorkbenchView.swift:958` · `ConduckApp.swift:445,645` · `AppDelegate.swift:212` | `WorkboardUploadJournal.shared.reconcile()` | Delete 4 call sites |
| S5 | `ConduckApp.swift:354` | `WorkboardProjectCommands()` in `.commands` | Delete; ⌘E rename disappears |
| S6 | `WorkboardDetailView.swift:71-77` | `focusedSceneValue(\.workboardProjectCommandTarget, …)` | Delete — the **only** producer of that focused value |
| S7 | `AppShortcuts.swift:47` | `AppShortcut(intent: BriefWorkboardIntent())` | Delete entry. **Existing user Shortcuts referencing it break** — an App Intent removal is user-visible |
| S8 | `CaptureWorkboardIntent.swift:62` | `ConversationStore.shared.createWorkItem(...)` | **Retarget** to the one desk |
| S9 | `ConduckWatch Watch App/WorkboardCaptureIntent.swift` | `createInertWatchWorkboardCapture` writes a fresh `WorkItem` row | **Retarget**; watch target compiles no envelope, has its own literal bound (`:25`) |
| S10 | `ConduckShareExtension/ShareViewController.swift:136,140,453,469,644,779` + `…Mac/…:201,205,632,652,833,969` | `targetWorkItemID` threaded through the share flow | Collapse to the single desk; drop the picker UI (`ShareView.swift:374-405` iOS / `:371-402` mac) |
| S11 | `Services/ShareTargetsSnapshotWriter.swift:140-143,158-171` | `fetchRecentWorkItemSummaries` → `RecentWorkItem[]` | Becomes vestigial. **Byte-identical mirror rule applies** — see §8 R4 |
| S12 | `Views/Conversation/ConversationThreadView.swift:1375` | `captureMessageToWork` | KEEP; `:1442-1444` posts `.openWorkboardDeepLink` with `NotificationDeepLink.workItemIDKey` → deep link resolves to one desk |
| S13 | `MenuBar/MenuBarCoordinator.swift:1699,1708` | `WorkboardWorkspaceCaptureLogic.normalizedThought` → `WorkCaptureInbox.shared.publishAppCapture` | KEEP unchanged (already targetless) |
| S14 | `MenuBar/MenuBarController.swift:794-803,899` | Work menu item → `.showWorkboard` | KEEP |
| S15 | `Services/Workboard/WorkCaptureDrainer.swift:181-220` | `destination(for:)` — resolves `targetWorkItemID` or `createWorkItem` (`:207`) | **Retarget**: the fallback-create becomes resolve-the-desk |
| S16 | `MainWindowView.swift:557-569, 596-607` | sidebar column mount + ⌘⇧N | See §2 |
| S17 | `ContentView.swift:1614` · `MenuBar/DictationService.swift:322` | `workboard.capture.retry.voice.message` | KEEP |
| S18 | `Views/Conversation/AttachmentMenu.swift:192,197` | `workboard.material.addLink` | KEEP (Chat reuses a workboard key) |
| S19 | `Views/Conversation/ConversationListView.swift:344` | copy: *"Workboard briefs stay on your board"* | Copy rewrite |
| S20 | `Services/AgentDownloadScratch.swift:275-276` | sweeper prefixes `conduck-workboard-` (per-dispatch snapshots), `Conduck-Workboard-Preview` | First becomes dead-but-harmless; second KEEP |

Notification names (`PersonalWorkbenchView.swift:311-316`): `.showWorkboard`, `.showChats`, `.openPersonalAISettings`, `.openWorkboardDeepLink` — **all survive**. No notification name dies.

---

## 4. `WorkboardViewModel.swift` (2319 → ~1150)

### 4a. Dependencies closures (`:1042-1085`)

DIE (13): `loadGateways` `:1044` · `saveDraft` `:1045` · `saveDraftAsCopy` `:1046` · `deleteItem` `:1061` · `duplicateItem` `:1062` · `reorderItems` `:1063` · `setState` `:1064` · `acknowledgeRun` `:1065` · `dispatch` `:1066` · `shapeDraft` `:1070` · `readBriefingAloud` `:1071` · `stopBriefingAloud` `:1072` · `setPinned` `:1084`

SURVIVE (9): `loadItems` `:1043` · `importMaterial` `:1047` · `removeMaterial` `:1053` · `replaceMaterial` `:1054` · `openConversation` `:1067` · `openMaterial` `:1068` · `openGatewaySettings` `:1069` · `reorderMaterials` `:1077` · `setMaterialCardSize` `:1080`

### 4b. Published state

DIE: `gateways` `:1090` · `customGateways` `:1091` · `filter` `:1101` · `isReorderingBoard` `:1102` · `provisionalWorkspaceID` `:1107` · `editorPresented` `:1109` · `editingDraft` `:1110` · `editorIsSaving` `:1111` · `editorFocusRequest` `:1128` · `editorSuggestion` `:1129` · `editorConflict` `:1130` · `isShapingDraft` `:1131` · `preflightItemID` `:1133` · `selectedGatewayID` `:1134` · `excludedMaterialIDs` `:1135` · `isDispatching` `:1136` · `briefing` `:1138` · `isReadingBriefing` `:1139` · `confirmation` `:1142` · `renameRequest` `:1143` · `renameDraftTitle` `:1147` · `searchText`/`appliedSearchText` `:1097,1100` · `@ObservationIgnored lastSavedFingerprint` `:1149`, `editorWasPersisted` `:1150`, `searchDebounceTask` `:1153`

SURVIVE: `items` `:1089` (→ likely one item) · `isLoading` `:1092` · `loadError` `:1093` · `selectedItemID` `:1103` (→ the desk id) · `workspaceImportState` `:1112` · `workspaceMutationItemID` `:1116` · `workspaceComposerDrafts` `:1120` · `nonEmptyComposerDrafts` `:1125` · `notice` `:1140` · `workspaceStatus` `:1141` · `loadRequestedWhileLoading` `:1151` · `workspaceMutationWaiters` `:1152`

**Note:** the whole editor/shaping trio (`editorPresented`, `editingDraft`, `editorSuggestion`, `editorConflict`, `isShapingDraft`, `shapeEditorDraft`, `applyEditorSuggestion`, `resolveEditorConflict*`) has **zero production references** — only tests touch it. Confirmed by bidirectional grep. (The many `editorHasUnsavedChanges` hits across Settings views are `SettingsViewModel`'s unrelated property of the same name — a name collision, not workboard.)

### 4c. Methods

**DIE:** `updateSearchText` `:1182` · `visibleItems` `:1168` · `projectStripItems` `:1172` · `hasVisibleItems` `:1176` · `preflightItem` `:1202` · `selectedGateway` `:1207` · `editorHasUnsavedChanges` `:1211` · `canShapeDraft` `:1215` · `canReadBriefing` `:1216` · `beginWorkspace` `:1249` · `cancelProvisionalWorkspace` `:1255` · `showEditor` `:1300` · `consumeEditorFocusRequest` `:1314` · `saveEditorNow` `:1320` · `reviewEditorAndSend` `:1366` · `reviewWorkspaceAndSend` `:1418` · `shapeEditorDraft` `:1676` · `applyEditorSuggestion` `:1691` · `showPreflight` `:1703` · `selectGateway` `:1727` · `isMaterialSupported` `:1731` · `isMaterialIncluded` `:1735` · `setMaterial(_:included:)` `:1739` · `includedPreflightMaterialIDs` `:1748` · `preflightPrompt` `:1753` · `dispatchPreflight` `:1761` · `requestDelete` `:1796` · `requestDuplicate` `:1800` · `requestRename` `:1807` · `commitRename` `:1820` · `setPinned` `:1870` · `performConfirmation` `:1894` · `reorderItem` `:1921` · `moveItem` `:1937` · `performBoardReorder` `:1947` · `applyBoardPositions` `:2170` · `transition` `:2178` · `acknowledge` `:2190` · `openConversation(for:)` `:2209` · `presentBriefing` `:2222` · `openFromBriefing` `:2226` · `toggleBriefingSpeech` `:2231` · `refreshEditorAfterMaterialMutation` `:2265` · `resolveEditorConflictBySavingCopy` `:2276` · `resolveEditorConflictByReloading` `:2295`

**SURVIVE:** `load` `:1263` · `item(withID:)` `:1296` · `selectedItem` `:1197` · `isCapturingIntoAnyWorkspace` `:1221` · `workspaceComposerDraft` `:1225` · `setWorkspaceComposerDraft` `:1229` · `hasComposerDraft` `:1242` · `addWorkspaceThought` `:1383` · `addWorkspaceThoughtUnlocked` `:1392` · `flushWorkspaceComposer` `:1432` · `completeWorkspace` `:1442` *(check: uses `setState`)* · `importWorkspaceMaterials` `:1454` · `importWorkspaceMaterialsUnlocked` `:1470` · `presentWorkspaceImportReport` `:1559` · `presentWorkspaceCaptureFailure` `:1598` · `reattachWorkspaceMaterial` `:1612` · `acquireWorkspaceMutation` `:1652` · `releaseWorkspaceMutation` `:1665` · `reorderMaterial` ×2 `:1983,:2000` · `moveMaterial` `:2018` · `setMaterialCardSize` `:2036` · `removeMaterialFromBoard` `:2075` · `performMaterialReorder` `:2109` · `applyMaterialOrder` `:2151` · `applyMaterials` `:2165` · `openMaterial` `:2214` · `openGatewaySettings` `:2218` · `upsert` `:2251`

### 4d. Top-level types in this file

DIE: `WorkboardRunState` `:113` · `WorkboardRunSnapshot` `:146` · `WorkboardEditDraft` `:301` · `WorkboardGatewayCapability` `:374` · `WorkboardGatewayChoice` `:380` · `WorkboardDispatchRequest` `:485` · `WorkboardDispatchReceipt` `:516` · `WorkboardFilter` `:522` · `WorkboardBriefingSnapshot` `:565` · `WorkboardEditorConflict` `:631` · `WorkboardConfirmation` `:636` · `WorkboardRenameRequest` `:648` · `WorkboardBoardOrdering` `:789` · `WorkboardPromptComposer` `:993` · `WorkboardEditorFocusTarget` · `WorkBriefShapingSource` · `WorkboardVoiceTarget.objective` case `:576`

TRIM: `WorkboardItemSnapshot` `:198` → `runs` `:208`, `isPinned` `:209`, `boardOrder` `:214`, `lastSentRevision` `:216`, `state` `:206`, `isReadyToSend` die · `WorkboardPresentationLogic` `:655` → filter/search/attentionSort die, `items(in:from:)` dies

SURVIVE: `WorkboardMaterialKind` `:19` · `WorkboardMaterialAvailability` `:52` · `WorkboardMaterialSnapshot` `:60` · `WorkboardMaterialImport` `:448` · `WorkboardNotice` `:598` · `WorkboardTransientStatus` `:607` · `WorkboardWorkspaceImportState` `:612` · `WorkboardWorkspaceImportReport` `:624` · `WorkboardMaterialOrdering` `:856` · `WorkboardWorkspaceCaptureLogic` `:964` · `WorkboardMoveDirection` · `WorkboardReorderPlacement` *(materials only — check both users)*

---

## 5. STORE LAYER

### `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` (1042 → ~600)

DIE: `loadGateways` `:553` · `gatewayDetail` `:581` · `saveDraft` `:594` · `saveDraftAsCopy` `:634` · `duplicateItem` `:881` · `reorderItems` `:909` · `setState` `:921` · `dispatch` `:950` · stored `dispatchHandler` `:27`, `shapeDraftHandler` `:31`, `readBriefingHandler` `:32`, `stopBriefingHandler` `:33` · `resultMessages` `:202` (run replies) · `WorkboardLiveRepositoryError` cases `.gatewayUnavailable`/`.derivedState` (`:1016,1021`) · `extension WorkBriefMaterialPacket.Kind` `:1031`

SURVIVE: `makeDependencies` `:79` (trimmed) · `drainCaptures` `:159` · `loadItems` `:165` · `snapshots` `:176` · `localPresentationThumbnails` `:228` · `snapshot(for:)` `:317` (trim run projection) · `importMaterial` `:658` · `storageKind` `:779` · `reorderMaterials` `:790` · `removeMaterial` `:809` · `replaceMaterial` `:838`

### `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (2443 → ~1700)

Orphaned once dispatch/brief/projects UI is gone (deletion allowed — schema untouched):

| Function | Line | Remaining callers after purge |
|---|---:|---|
| `reorderWorkItems` | 123 | none (repo `:909` dies) |
| `saveWorkItemDraft` | 453 | none |
| `updateWorkItem` | 434 | none (repo ×2 die) |
| `acknowledgeWorkDispatchReview` | 542 | none |
| `duplicateWorkItem` | 577 | none |
| `deleteWorkItem` | 666 | none |
| `setWorkItemPinned` | 1146 | none |
| `captureWorkDispatch` | 1226 | none (only `WorkboardDispatchCoordinator`) |
| `prepareWorkDispatch` | 1358 | none (only `WorkboardDispatchCoordinator`) |
| `completeWorkItem` / `reopenWorkItem` / `setWorkItemCompletion` | 512/518/522 | only via `WorkboardViewModel.completeWorkspace` — decide whether "done" survives on a single desk |

Keep: `createWorkItem` `:34` · `fetchWorkItems` `:66` · `fetchWorkItem(id:)` `:108` · `fetchWorkItem(captureEnvelopeID:)` `:112` · `captureMessageToWork` `:242` · `createWorkItemWithInitialMaterial` `:709` · `addWorkMaterial` `:814` · `addWorkMaterialFile` `:854` · `insertWorkMaterial` `:886` · `replaceWorkMaterialPayloadFile` `:948` · `deleteWorkMaterial` `:1009` · `reorderWorkMaterials` `:1059` · `setWorkMaterialCardSize` `:1106` · `loadWorkMaterial*` `:1185,1190` · `localURLForWorkMaterial` `:1214` · `fetchWorkMaterial` `:1568` · `fetchWorkItems(…)` `:1582` · `reconcileWorkAssetVault` `:1736` · the three `_…ForTesting` probes `:2330,2355,2382`

Conditional: `fetchRecentWorkItemSummaries` `:75` — sole prod caller `ShareTargetsSnapshotWriter.swift:140`, dies iff the share picker dies.

Also: `WorkItemStateResolver.resolve` at `:1547` and `:2141` must be replaced with a constant.

Untouched by design: `ConversationStore.swift:2244,2301` `WorkDispatch` fetch requests in delete-all — the entity stays, tombstoning stays.

---

## 6. TESTS

Framework: **XCTest throughout**, both targets. No swift-testing, no `@Test(arguments:)` → no parameterized expansion. Baseline arithmetic verified independently: 4859 `func test` minus 109 macOS-guarded = **4750**, exact match. None of the workboard test files carries an `#if` guard.

### Dies entirely — 41 cases
| File | L | Cases |
|---|---:|---:|
| `ConduckTests/WorkBriefAssistantTests.swift` | 63 | 4 |
| `ConduckTests/WorkBriefPromptBuilderTests.swift` | 304 | 10 |
| `ConduckTests/WorkItemStateResolverTests.swift` | 139 | 8 |
| `ConduckTests/WorkboardDispatchCoordinatorTests.swift` | 369 | 8 |
| `ConduckTests/WorkboardUploadJournalTests.swift` | 357 | 6 |
| `ConduckTests/WorkboardOrderingTests.swift` | 194 | 5 |

### Splits — 40 cases die
| File | L | Total | Die | Stay |
|---|---:|---:|---:|---:|
| `WorkboardWorkspaceCaptureTests.swift` | 693 | 17 | 12 | 5 (`:118,132,256,278,350`) |
| `WorkboardPersistenceTests.swift` | 981 | 18 | 12 | 5 (`:83,721,831,873,913`) + 1 conditional (`:126`) |
| `WorkboardBoardProjectionTests.swift` | 345 | 10 | 9 | 1 (`:226` composer flag) |
| `WorkboardMaterialBoardActionsTests.swift` | 512 | 15 | 3 (`:352,392,419` — shaping) | 12 |
| `WorkboardLiveRepositorySupportTests.swift` | 152 | 5 | 3 (`:49,89,145`) | 2 (`:16,33`) |
| `ConversationStoreAtomicWorkCaptureTests.swift` | 161 | 4 | 1 (`:123` + its class `ConversationStoreWorkItemMutationTests` at `:122` and helper `:158`) | 3 |

Per-file deltas: WorkspaceCapture −12 · Persistence −12 (−13 conditional) · BoardProjection −9 · MaterialBoardActions −3 · LiveRepositorySupport −3 · ConversationStoreAtomicWorkCapture −1.

Notable re-home: `WorkboardPersistenceTests.swift:617` `testDeleteAllConversationsPreservesBriefMaterialsAndTombstonesRun` dies (builds `WorkDispatchPreparation`), but its **first half — "delete-all-conversations preserves Work materials" — is a surviving invariant with no other home.** Re-home it rather than losing it.

### Survive entirely
`WorkboardMosaicEngineTests` (547 L, 26) · `WorkCaptureInboxTests` (920 L, 30) · `WorkAssetVaultTests` (254 L, 9) · `WorkCaptureDrainerTests` (288 L, 6) · `WorkCaptureRefreshCoordinatorTests` (181 L, 6) · `ConversationStoreWorkCaptureTests` (224 L, 5) · `WorkboardMaterialPresentationTests` (78 L, 4) · `WorkboardModelMigrationTests` (264 L, 4) · `PendingRetryDestinationTests` (3) · `RemoteAgent/HeadlessRetryGuardSpanTests` (11) · `TempScratchSweeperTests` (11) · `ErrorSurfaceDriftGuardTests` (7) — **see §8 R3**

**Name collisions — all unrelated, all survive untouched:**
- `ConduckTests/GatewayAdapterBriefTests.swift` (292 L, 10) — locks `GatewayAdapterBriefView.clipboardBrief`, the Settings custom-lane escape hatch (raw `.md` URLs, `--check-adapter`, 285 s cap, 50 MiB floor, loopback-only bind). **Zero workboard references.**
- `ConduckTests/AtMostOnceDispatchInvariantTests.swift` (457 L, 9) — remote-agent parked-converse `InFlightTurnRegistry` / `ConverseCancelVerdict`. **Not workboard dispatch.**
- `ParkedConverseLaneDriftGuardTests.swift` (507 L, 14) — matches only the literal `"DispatchWorkItem"` in a timer-ban list.

### Predicted baseline
- **iOS: 4750 − 81 = 4669** executed, 0 fail, **2 skips unchanged** (neither skip is in a workboard file)
- If the share-sheet Work-destination picker also goes: **4664** (−5 more: `WorkCaptureInboxTests:173`, `WorkboardPersistenceTests:126`, `ShareTargetsSnapshotWriterColorTests:77,92`, `ShareTargetsSnapshotTests:130`)
- **watchOS: 229 → 229, delta 0.** `ConduckWatchSmokeTests` (103 L, 6): `:15,:24` are `WatchWorkboardCaptureText` normalize/oversize (pure capture); `:36` asserts `createInertWatchWorkboardCapture` writes one `WorkItem` and **zero** `WorkDispatch`/`Conversation`/`Message` rows — post-purge that becomes trivially true, not false.

### Test LOC
~2,290 deleted whole + ~1,700 excised from split files.

---

## 7. LOCALIZATION

Catalogs: main `Conduck/Conduck/Localizable.xcstrings` (**2397 keys** — note it sits at `Conduck/Conduck/`, *not* `Conduck/Conduck/Resources/`, which does not exist), `ConduckShareExtension/` (47), `ConduckShareExtensionMac/` (46), `ConduckWatch Watch App/` (299). `Conduck/LocalizationStaging/` excluded as non-source.

| Catalog | Candidates | **Dies** | Survives | Ambiguous |
|---|---:|---:|---:|---:|
| Main | 312 | **158** | 146 | 8 |
| Share iOS | 16 | **5** | 11 | 0 |
| Share macOS | 15 | **5** | 10 | 0 |
| Watch | 9 | **0** | 9 | 0 |

**Total zero-reference after purge: 163** (the 5 share keys are the same set duplicated across both extension catalogs — remove from both).

Candidate prefixes were derived from a prefix histogram of the catalog, not assumed: `workboard.*` (295), `workbench.*` (3), `intent.workboard*` (8), four bare-English literal keys (`Workboard`, `Add to Work`, `Add ${thought} to Work`, `Brief My Workboard`), two strays (`intent.converse.destination.work`, `menu.openWork`).

### Main catalog — project layer (62)
`workboard.action.rename` · `.action.duplicate` · `.action.delete` · `workboard.pin` · `workboard.unpin` · `workboard.rename.{title,prompt,message}` · `workboard.confirm.delete.{title,message,action}` · `workboard.confirm.duplicate.{title,message,action}` · `workboard.item.copyTitle` · `.item.pinned` · `.item.open.hint` · `.item.changedAfterSend` · `.item.accessibility.{latestRun,materials,materials.one,reviewBy}` · `.item.missing.{title,message}` · `workboard.projectShelf.{title,subtitle,pinned.title,pinned.subtitle,new.caption,new.hint}` · `workboard.overview.{title,hint}` · `workboard.newBrief` · `workboard.workspace.new.title` · `.workspace.captured` · `.workspace.sidebar.privacy` · `workboard.search.{prompt,private}` · `workboard.filter.{title,help,open,needsYou,waiting,drafts,changed,done,all}` · `workboard.empty.filtered.{title,message,action}` · `workboard.loading` · `workboard.load.failed.{title,message}` · `workboard.load.retry` · `workboard.group.{drafts,waiting,needsYou,done}` · `workboard.error.staleBoardOrder`

### Main catalog — AI/dispatch layer (96)
`intent.workboardBrief.{title,description}` · `Brief My Workboard` · `workboard.briefMe` · **briefing sheet (16)** `workboard.briefing.*` · **preflight sheet (33)** `workboard.preflight.*` · **dispatch errors (11)** `workboard.error.{alreadyStarted,fileServerRequired,fileTransferFailed,itemChanged,materialChanged,materialUnavailable,previewMismatch,unsupportedMaterial,gatewayUnavailable,derivedState}` · `workboard.{dispatch,shape}.failed.title` · `workboard.gateway.load.failed.title` · `workboard.review.acknowledge.failed.title` · `workboard.gateway.{configured.status,hosted,selfHosted,custom}` · **run state (7)** `workboard.run.*` · **item state (4)** `workboard.state.{draft,waiting,review,done}` · `workboard.editor.reviewAndSend` + `.hint` · `workboard.material.{included,omitted,unsupported.generic,unsupported.fileTransfer,item,accessibility.summary}` · `workboard.save.{saving,pending,saved,privateDraft,failed.title}` · `workboard.conflict.{copy,reload}.failed.title` · `workboard.voice.objective`

### Extension catalogs — 5 keys × 2 files
`share.work.section.destination` · `share.work.section.recent` · `share.work.new` · `share.work.new.detail` · `share.work.untitled`
(iOS `ShareView.swift:374-405`; macOS `ShareView.swift:371-402`.) Everything else `share.*` survives: `share.addToWork`, `.progress`, `share.mode.work`, `share.work.inert`, `share.work.error.*`, iOS-only `share.work.title`.

### Already dead *before* the purge (free wins)
`workboard.material.accessibility.summary` + tile `included`/`omitted`/`unsupported.generic` (host `WorkboardMaterialTile` never instantiated) · `workboard.save.{saving,pending,saved,privateDraft}` (host `WorkboardAutosaveStatus` never instantiated) · `workboard.save.failed.title` (only test caller) · `workboard.conflict.{copy,reload}.failed.title` (`editorConflict` written, never read by any view) · `workboard.voice.objective` (`WorkboardVoiceTarget.objective` never constructed — only `.context` at `WorkboardCaptureCanvas.swift:162`)

### Dynamic-key trap — checked, only one real case
No `workboard.*` key is composed at runtime; every one is a literal first argument to `LocalizedStringResource(_:defaultValue:)` or `String(localized:defaultValue:)`. The one macro-composed key is `Add ${thought} to Work` (App Intents `Summary("Add \(\.$thought) to Work")` at `CaptureWorkboardIntent.swift:38`, watch `:130`) — **zero literal grep hits by design, SURVIVES**. Do not delete on a "no references" signal.

### 8 ambiguous — human call
| Key | Why |
|---|---|
| `workboard.title` ("Work") | Both refs purge-set (`WorkboardView:658`, `WorkboardComponents:976`) but the desk still needs a nav title and the Mac window a Work menu name |
| `workboard.empty.title` | `WorkboardView:897`, *"Start with a thought, file or screenshot"* — desk copy living in project code; almost certainly the empty-desk headline |
| `workboard.action.failed.title` | 6 of 8 sites project-layer, but **`WorkboardViewModel.swift:2060` is card-resize and `:2140` is material reorder** → **SURVIVES** |
| `workboard.error.staleDraft` | `WorkboardLiveRepository:991` — CAS error still thrown on any desk write; copy says "brief". Keep key, rewrite string |
| `workboard.item.untitled` | `WorkboardViewModel:282`, `CaptureWorkboardIntent:60`, watch `:47` — surviving capture intents; copy word "brief" must change. Duplicated main↔watch |
| `workboard.voice.context` | `WorkboardViewModel:591` — the only live `WorkboardVoiceTarget` case; may fold into a plain label if the enum collapses |
| `workboard.tutorial.point.review` | `WorkboardTutorialView.swift:91` — *"Nothing is sent to an AI until you review it."* becomes **false**. Copy call, not a reference call |
| `workboard.chatCapture.{followUpObjective,longMessageObjective}` | `ConversationStore+Workboard.swift:282,291` — populate the item's `objective`. **Data-model decision** |

### Cross-catalog duplication
`Add to Work`, `Add ${thought} to Work`, `intent.workboardCapture.*` (6 keys), `workboard.item.untitled` all appear in **main + watch** and survive in both. The 5 `share.work.*` picker keys appear in **shareIOS + shareMac** and die in both. No key crosses main ↔ share catalogs.

### Notable survivors — do not delete
`workbench.chats`/`.work`/`.section` · `menu.openWork` (`MenuBarController.swift:796`) · literal `Workboard` (`ConduckApp.swift:339`, ⌘1) · `intent.converse.destination.work` · all `workboard.capture.*` · all `workboard.material.*` add/link/note/card-size/preview/reattach/remove · all `workboard.workspace.*` composer/drop/import · all `workboard.menuBar.*` · `workboard.action.moveEarlier`/`.moveLater` (**also** material cards at `WorkboardCaptureCanvas.swift:1539,1547,1580,1586`) · `workboard.material.large.confirm.*` · `workboard.error.{contentTooLong,emptyNote,invalidLink,missingPayload,itemMissing}` · `workboard.material.localOnly`/`.unavailableHere`

---

## 8. RISKS

**R1 — The desk has no identity (blocking design gap).** Nothing creates a singleton `WorkItem`. `WorkCaptureDrainer.swift:207`, `CaptureWorkboardIntent.swift:62` and `ConversationStore+Workboard.swift:709` all *create* rows; `WorkboardViewModel.beginWorkspace` `:1249` invents a provisional UUID that only persists on first capture. A "resolve-or-create the one desk" seam must land **before** any capture surface is retargeted, and it must be idempotent across the share extension, watch, Shortcuts and drainer — four processes.

**R2 — `WorkBriefFixtures` cross-file test hazard.** Declared `ConduckTests/WorkBriefPromptBuilderTests.swift:245` (`enum WorkBriefFixtures`, with `workItemID`, `timestamp`, `record(...)` `:249`, `previewSnapshot(_:)` `:289`). Consumed by the dying `WorkboardDispatchCoordinatorTests` (14 sites, L60–210) **and by `WorkboardMaterialBoardActionsTests.swift:393`**, inside `testAVoiceTranscriptIsANoteCardTheShapingSourceCanSee` — a case that dies, in a file that survives with 12 live cases. Delete the fixtures file without also removing L392–417 of `WorkboardMaterialBoardActionsTests` and the surviving file fails to compile, taking all 12 with it. This is the **only** cross-file helper hazard; every other file-scope helper in the workboard test set is `private` and dies cleanly with its file (`MockUploadReclaimer` `WorkboardUploadJournalTests:17`, `OneShot*FileManager` `WorkCaptureInboxTests:14,37`, `StubLargeImportConfirmation` `WorkboardMaterialPresentationTests:75`). `TestStores` (`ConduckTests/StorageTestSupport.swift:18`) is shared but workboard-neutral.

**R3 — `ErrorSurfaceDriftGuardTests` fails on a *stale* registry row, not just a missing one.** `ConduckTests/ErrorSurfaceDriftGuardTests.swift:337` `retrySurfaces` registers `"Conduck/Views/Workboard/WorkboardView.swift"` (`:425`) and `"…/WorkboardVoiceCaptureView.swift"` (`:428`). `testEveryRetryControlConsultsARetryabilityGate` builds `var stale = Set(retrySurfaces.keys)` (`:1630`), removes each path visited, and asserts `stale.isEmpty` (`:1725`). Renaming or deleting either view turns this red until the rows are pruned. Count unchanged (7); build-breaker if missed.

**R4 — Three-way envelope + snapshot mirrors.** `WorkCaptureEnvelope.swift` exists in three copies (main 366 L, iOS ext 361, mac ext 361) that must stay byte-identical from `import Foundation` onward — `WorkCaptureInboxTests` guards it. Same for `ShareTargetsSnapshot.swift` ×3: `ShareTargetsSnapshotTests.swift:252` `testAppexMirrorIsByteIdenticalToCanonicalBelowHeader` compares all three. Any `targetWorkItemID` or `RecentWorkItem` edit must land in **all three copies in the same commit**. Additionally `WorkCaptureInboxTests.swift:311` `testShareSurfacesUseDistinctWorkVocabularyAndAdaptivePrimaryActions` string-asserts the four `share.work.*` picker keys against both `ShareView.swift` files **and** both `.xcstrings` — dropping the picker means editing six files in lockstep.

**R5 — Types the capture path shares with dispatch.**
- `WorkboardCaptureDestination` (`WorkboardCaptureCanvas.swift:21`) has `.existingWork(String)` / `.newWork` — both collapse to one; 4 localized strings hang off it (`:26-68`).
- `WorkboardMoveDirection` and `WorkboardReorderPlacement` serve **both** project reorder (`WorkboardView.swift:1224,1293,1310,1315`) and material reorder (`WorkboardCaptureCanvas.swift`) — keep the enums, delete only the project users.
- `WorkboardItemSnapshot.isReadyToSend` gates `reviewAndSendButton` (`WorkboardCaptureCanvas.swift:570`) inside an otherwise-surviving file.
- `WorkboardMaterialComposerKind` (`WorkboardTextMaterialSheet.swift:12`) — **still needed**, `WorkboardCaptureCanvas.swift:97,227` are live.
- `WorkboardSurface` has exactly one consumer left (`WorkboardCaptureCanvas.swift:117`) and it is in the dying `.full` branch — keep the type as the desk container or it goes orphaned by accident.

**R6 — `scripts/check-storage-seam.sh` is safe but will hold a stale row.** `CONTAINER_ALLOWLIST[]` at `:112` names `Conduck/Conduck/Services/Workboard/WorkboardUploadJournal.swift`. The script builds `SWIFT_FILES` from `find` (`:51-53`) and the allowlist is skip-only (`:148-156`) — a deleted file produces no match and no failure. Prune `:110-112` for hygiene, not correctness. The `SWIFT_FILES < 100` guard (`:55`) is nowhere near being tripped.

**R7 — `WorkItemState` enum vs its presentation.** Keep `WorkboardRecords.swift:18-28` (Core Data column, no migration) but delete `WorkboardComponents.swift:66-127`. `WorkItemStateResolver` deletion at `WorkboardRecords.swift:109` forces a constant at `ConversationStore+Workboard.swift:1547` and `:2141` — pick the constant deliberately, since it is what every persisted row will read back as.

**R8 — `Constants.workboardTutorialSeenKey`** (`Utilities/Constants.swift:212`, read at `SettingsManager.swift:302,310`) survives and is App-Group-scoped. The tutorial itself survives, but `WorkboardTutorialView.swift:91` asserts a dispatch promise that stops being true.

**R9 — App Intent removal is user-visible.** Deleting `BriefWorkboardIntent` breaks any user-built Shortcut referencing it. `CaptureWorkboardIntent` and the watch `WorkboardCaptureIntent` must keep their identifiers stable across the retarget or existing Shortcuts break too.

**R10 — `AgentDownloadScratch.swift:275`** sweeps the `conduck-workboard-` prefix for per-dispatch file snapshots. Harmless once dispatch is gone, but it is the only remaining reader of that naming convention — leave it or clean it deliberately.
