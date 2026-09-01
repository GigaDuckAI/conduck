# views-core — plan §B view purge for `WorkboardView.swift` + `WorkboardComponents.swift`. DONE, both platforms build green.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened** (`git status` confirms none modified). Nothing under `docs/qa/desk-cloudkit/` touched.

Line counts: `WorkboardView.swift` **431 → 321** · `WorkboardComponents.swift` **892 → 358**.

---

## 1. `WorkboardView.swift` — trim conformance per symbol

Scout §2 anchors re-located by symbol, not line number. purge-core had already removed the preflight/briefing sheets, the confirmation dialog, the rename alert, `openItem`, `selectInitialWideItemIfNeeded`, `confirmationTitle/Message`, `openWorkboardItem`, `WorkboardSidebarSectionHeader`, `WorkboardSidebarRow`, `WorkboardProjectCanvas`, `WorkboardProjectDropRail`, `WorkboardReorderCard`. This slice finishes the file.

| Symbol | Verdict | Note |
|---|---|---|
| `WorkboardSidebarColumn` | **DELETED** (the purge-core stub) | with it: the nav-title-only `List`, its Settings row, and its four now-unused stored properties (`showsOverview`, `preferredCompactColumn`, `isActive`, `showsSidebarToolbar`) |
| `WorkboardExperience.sidebarColumn` | **DELETED** | |
| `WorkboardExperience` `NavigationSplitView` | **REPLACED by `NavigationStack { detailColumn }`** | see §4 — load-bearing, founder-QA item |
| `WorkboardExperience.{showsOverview, emptyWorkspaceID, preferredCompactColumn, columnVisibility, showsSidebarToolbar, horizontalSizeClass}` | **DELETED** | new init is `(viewModel:isActive:reduceMotion:)` |
| `WorkboardExperience.{detailColumn, presentationModifier}` | **KEPT as values** | MainWindowView consumes both |
| `WorkboardPresentationModifier.{showsOverview, emptyWorkspaceID, preferredCompactColumn, horizontalSizeClass}` | **DELETED** | `horizontalSizeClass` was already unread after purge-core |
| `WorkboardPresentationModifier` `.onChange(of: viewModel.selectedItemID)` | **DELETED** | it only rotated `emptyWorkspaceID` and drove `showsOverview` / `preferredCompactColumn` — all three gone |
| tutorial sheet + gate machinery, `workspaceStatus` toast + its 2.6 s timer, notice alert, `dismissTransientPresentations` | **KEPT verbatim** | this modifier stays the owner of every surviving presentation |
| `WorkboardDetailColumn.{showsOverview, emptyWorkspaceID, preferredCompactColumn}` | **DELETED** | now `(viewModel:isActive:)` |
| `WorkboardDetailColumn` loading / load-error branches | **KEPT** | the retry control (`workboard.load.retry` inside `WorkboardEmptyState`) is intact — `ErrorSurfaceDriftGuardTests` still green, 7/7 |
| `WorkboardDetailColumn` `captureWorkspace(id:title:)` / `captureBar(itemID:destination:)` | **collapsed into `emptyDesk` / `captureBar`** | no parameters; both key on `Constants.workboardDeskItemID` |
| `WorkboardView.{showsOverview, emptyWorkspaceID, preferredCompactColumn, columnVisibility, horizontalSizeClass}` | **DELETED** | body is now three arguments |

### Desk identity — I retargeted the empty arm (deviation, deliberate)
purge-core §Requests 3 pointed the *capture* agent at `WorkboardDetailColumn`'s final `else` and its rotating `@State emptyWorkspaceID`. That state lived in a file **I own**, and removing the host hand-off (my task) leaves nothing to thread it from, so I did the retarget here rather than leave a private rotating UUID behind:

```swift
WorkboardItemSnapshot(id: Constants.workboardDeskItemID)   // desk-before-first-material canvas
viewModel.item(withID: Constants.workboardDeskItemID)      // capture bar
.workboardPaneDropDestination(viewModel:, itemID: Constants.workboardDeskItemID, destination: .newWork)
```
`destination: .newWork` is unchanged — collapsing `WorkboardCaptureDestination` is capture-canvas's item.

### Static "Work" title
`WorkboardDetailColumn.deskTitle` is a private static `LocalizedStringResource("workboard.title", defaultValue: "Work")` applied via `.workbenchNavigationTitle(_:isActive:)` on the loading branch, the load-error branch and the empty desk. **Nothing in this file displays the desk row's title or objective.** The large in-canvas headline is still `workboard.empty.title`. (`workboard.title` used to be the sidebar's title; the sidebar is gone, so the key moved here and stays alive.)

I did **not** rewrite `workboard.load.failed.message` ("Your **projects** stay private and unchanged…") even though it is now false product language — plan §B names exactly four sanctioned copy rewrites and this is not one, and in a parallel phase I cannot update the catalog to match. See §Requests 4.

---

## 2. `WorkboardComponents.swift` — trim conformance per symbol

| Symbol | Verdict |
|---|---|
| `WorkboardMetrics` | KEEP (whole enum — see §Requests 5 for `cardCornerRadius`) |
| `UTType.conduckWorkboardCard` | **DELETED** |
| `UTType.conduckWorkboardMaterial` | KEEP |
| `WorkboardCardDragPayload` | **DELETED** |
| `WorkMaterialDragPayload` | KEEP |
| `extension WorkItemState` (`title`/`systemImage`/`tint`/`attentionTitle`/`attentionRank`/`attentionOrder`) | **DELETED whole** |
| `WorkboardStateBadge` | **DELETED** |
| `WorkboardSectionHeader` | **DELETED** |
| `WorkboardProjectActionTitle` | **DELETED** |
| `workboardProjectActions(...)` | **DELETED** |
| `WorkboardCard` | **DELETED** |
| `View.workboardInlineNavigationTitle` / `.workboardDesktopSheetFrame` | KEEP |
| `WorkboardSurface` | KEEP — the desk container |
| `WorkboardMaterialIcon` | KEEP |
| `WorkboardMaterialTile` | **DELETED** (was already dead) |
| `WorkboardEmptyState` | KEEP |
| `WorkboardAutosaveStatus` | **DELETED** (was already dead) |
| `WorkboardMaterialRoute` | **KEPT — scout §2 is WRONG here** |
| `WorkboardMaterialActions` | KEEP |
| `WorkboardLargeImportConfirming` + `workboardLargeImportAlert` | KEEP |
| trailing `#if os(macOS)` command block | already deleted by purge-core |

**Deviation, scout §2 `757-797 WorkboardMaterialRoute DELETE — already dead`:** it is dead *outside its own file* only. `WorkboardMaterialActions` (a KEEP row two lines below it) reads `WorkboardMaterialRoute.allCases` in `rowRoutes` and switches on it in `action(for:)` / `label(for:)`. Deleting it would break the surviving add-material control. Kept, unchanged.

File header rewritten to the surviving contents (present tense, no changelog narration).

---

## 3. Surviving public surface — code against this

### `WorkboardView.swift`
```swift
struct WorkboardView: View {
    @Bindable var viewModel: WorkboardViewModel        // reads @Environment workbenchDestinationIsActive + accessibilityReduceMotion
}

struct WorkboardExperience: View {
    @Bindable var viewModel: WorkboardViewModel
    let isActive: Bool
    let reduceMotion: Bool
    var body: some View                                 // NavigationStack { detailColumn } + .environment + .modifier(presentationModifier)
    var detailColumn: WorkboardDetailColumn
    var presentationModifier: WorkboardPresentationModifier
}

struct WorkboardPresentationModifier: ViewModifier {
    let viewModel: WorkboardViewModel
    let isActive: Bool
    let reduceMotion: Bool
}

struct WorkboardDetailColumn: View {
    @Bindable var viewModel: WorkboardViewModel
    let isActive: Bool
}
```
Everything else in the file is `private`.

### `WorkboardComponents.swift`
```swift
enum WorkboardMetrics { contentMaxWidth, cardCornerRadius, surfaceCornerRadius, standardSpacing, generousSpacing, touchTarget }
extension UTType { static let conduckWorkboardMaterial }
nonisolated struct WorkMaterialDragPayload: Codable, Hashable, Sendable, Transferable { let itemID: UUID; let materialID: UUID }
extension View { func workboardInlineNavigationTitle() -> some View
                 func workboardDesktopSheetFrame(minWidth:minHeight:) -> some View
                 func workboardLargeImportAlert<Item: WorkboardLargeImportConfirming>(item:onConfirm:onCancel:) -> some View }
struct WorkboardSurface<Content: View>: View { init(@ViewBuilder content: () -> Content) }
enum WorkboardMaterialIcon { static func symbol(for: WorkboardMaterialSnapshot) -> String
                             static func tint(for: WorkboardMaterialSnapshot) -> Color }
struct WorkboardEmptyState: View { let title, message: LocalizedStringResource
                                   var actionTitle: LocalizedStringResource?; var action: (() -> Void)? }
enum WorkboardMaterialRoute: String, CaseIterable, Identifiable { photos, camera, files, link, note; var title; var systemImage }
struct WorkboardMaterialActions: View { enum Presentation { menu, row }
                                        presentation, onPickPhotos, onTakePhoto, onPickFiles, onAddLink, onAddNote,
                                        iconPointSize = 22, iconFrame = WorkboardMetrics.touchTarget }
protocol WorkboardLargeImportConfirming: Identifiable { var largeItemByteCounts: [Int64] { get } }
extension WorkboardLargeImportConfirming { var largeImportMessage: String }
```
No `WorkboardMoveDirection` / `WorkboardReorderPlacement` reference exists in either of my files (they live in `WorkboardViewModel.swift` and their material users are untouched).

---

## 4. NavigationStack instead of NavigationSplitView — the one judgement call

`WorkboardExperience.body` is the STANDALONE iPhone/iPad path only (`PersonalWorkbenchView` mounts `WorkboardView` in a compact `Tab` and in the regular-width `ZStack`); macOS never uses it, it consumes `.detailColumn` + `.presentationModifier` directly. With the sidebar gone a `NavigationSplitView` has nothing to put in its first column, so the pane is now `NavigationStack { detailColumn }`.

**Why a navigation container had to stay** (do not "simplify" it away): `PersonalWorkbenchView.mountedWideDestinations` applies `.toolbar { sectionToolbar }` to `WorkboardView(...)` from OUTSIDE, and its own comment says each iPad layer must own its navigation container or the section control renders nowhere. `NavigationStack` is a navigation container the same way `NavigationSplitView` was, so the anchor is preserved by construction — but this is a **pixel change I cannot verify headlessly**. Founder QA: on **iPad** (regular width) open Work and confirm the Work/Chats section control still appears in the navigation bar; on **iPhone** confirm the Work tab opens straight onto the desk (no sidebar step) with the title "Work".

The macOS toolbar anchors are untouched by this change: MainWindowView's persistent split view still owns them.

---

## 5. Call-site touches (minimal-touch rights)

**`Views/Conversation/MainWindowView.swift`** — three edits, all "remove a reference to a symbol I deleted":
1. deleted the three Work-only presentation properties + their 3-line comment: `@SceneStorage("workboard.showsOverview") workboardShowsOverview`, `@State workboardEmptyWorkspaceID`, `@State workboardPreferredCompactColumn`. **The `workboard.showsOverview` `@SceneStorage` key is gone from the app.** The shared `columnVisibility` (Chat's) is untouched.
2. `workboardExperience(for:)` now builds `WorkboardExperience(viewModel:isActive:reduceMotion:)` — dropped the four bindings, `showsSidebarToolbar:` and `horizontalSizeClass:` (and the `showsSidebarToolbar` comment about Work's New Work affordances, which named a canvas that no longer exists).
3. `mountedSidebarDestinations`: deleted the `if let personalWorkbenchModel, mountsWorkLayer { …sidebarColumn… }` mount. Chat's sidebar now owns that column unconditionally — which is the direction plan §B Codex #10c specifies, but the rest of that rewrite is mac-shell's.
`mountsWorkLayer`, `Self.workLayerIdentity`, `workboardExperience(for:)`, the `.detailColumn` mount and the `.presentationModifier` application are all still live and untouched.

**`ConduckTests/WorkboardBoardProjectionTests.swift`** — deleted `testLaneOrderIsDerivedFromAttentionRank` + its `// MARK: - Lane order` header, and trimmed the file header's second clause. This was `test-compile.md` §Requests 1, addressed to me and marked blocking: it was the only consumer of `WorkItemState.attentionOrder`/`.attentionRank`, which died with the presentation extension. The class now holds one case, `testComposerFlagTracksNormalizedEmptinessRatherThanRawText` (1/1 green). No other assertion touched; nothing weakened.

I edited no other file. `PersonalWorkbenchView.swift`, `WorkboardDetailView.swift`, `WorkboardCaptureCanvas.swift`, `ConduckApp.swift`: **untouched** — they needed nothing from me.

---

## 6. Gates run (exact lines)

Slug `desk-views-core`, derivedData `~/Library/Caches/gigaduck-builds/desk-views-core/DerivedData`, every log written there and grepped (never judged from tail or exit code). No `-configuration` passed anywhere.

- **iOS build** (`-destination 'platform=iOS Simulator,id=1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1'`) → `ios-build-1.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`. No new warning in either of my files (the only `never used` warnings in the log are pre-existing, in `CarPlayConverseUploader.swift` and `CarPlaySceneDelegate.swift`).
- **macOS build** (`-destination 'platform=macOS'`) → `mac-build-1.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback was needed**.
- **`build-for-testing`, attempt 1** → `bft-1.log`: `** TEST BUILD FAILED **`, 11 errors, **all 11 in `ConduckTests/WorkCaptureInboxLeaseTests.swift`** (a file I do not own — the plan §A inbox-lease agent's, mid-edit), every one `error: 'await' in an autoclosure that does not support concurrency` at `:94,144,171,188,201,213,216,245,260,295,303`. Zero errors in any file of mine. Per the parallel-phase rule I waited and retried once.
- **`build-for-testing`, attempt 2** → `bft-2.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`. The other agent's file had landed; nothing of mine changed between attempts.
- **Targeted tests** — one `test-without-building` run, six quoted `-only-testing:` flags → `test-1.log`. `** TEST EXECUTE SUCCEEDED **`, `Executed 53 tests, with 0 failures (0 unexpected) in 4.253 (4.273) seconds`:

| Class | Result |
|---|---|
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.925 (2.927) seconds` |
| `GatewayFixRouteLandingDriftGuardTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.101 (0.103) seconds` |
| `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 1.141 (1.142) seconds` |
| `WorkboardBoardProjectionTests` | `Executed 1 test, with 0 failures (0 unexpected) in 0.001 (0.002) seconds` |
| `WorkboardMaterialPresentationTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.006 (0.012) seconds` |
| `WorkboardMosaicEngineTests` | `Executed 26 tests, with 0 failures (0 unexpected) in 0.080 (0.085) seconds` |

`ErrorSurfaceDriftGuardTests` is the one that matters for this slice: its registry row for `Conduck/Views/Workboard/WorkboardView.swift` still resolves and the load-retry control survived the trim. **No registry row pruned.**

- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 761 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`
- `git diff --check` → clean.
- **NOT run, stated plainly:** the full iOS suite and the watch suite. Neither is in my brief and the tree is being edited by other agents; the watch target is untouched by this slice.
- Build cache removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-views-core`, so those logs no longer exist — re-run if you need them.

---

## Catalog

**Keys I ADDED in source: NONE.** Every key in my surviving code already existed. `workboard.title = "Work"` changed *location* (sidebar → desk navigation title), not value.

**Keys DEAD in source because of this slice (27).** Verified individually: `grep -rn "\"<key>\"" --include='*.swift' Conduck/` returns 0 for each. Contribution to the plan's bidirectional audit, not the audit itself — re-verify before deleting.

`workboard.state.draft` · `workboard.state.waiting` · `workboard.state.review` · `workboard.state.done` · `workboard.group.drafts` · `workboard.group.waiting` · `workboard.group.needsYou` · `workboard.group.done` · `workboard.action.rename` · `workboard.action.duplicate` · `workboard.action.delete` · `workboard.pin` · `workboard.unpin` · `workboard.item.pinned` · `workboard.item.open.hint` · `workboard.item.accessibility.materials` · `workboard.item.accessibility.materials.one` · `workboard.item.accessibility.reviewBy` · `workboard.material.unsupported.generic` · `workboard.material.included` · `workboard.material.omitted` · `workboard.material.accessibility.summary` · `workboard.save.saving` · `workboard.save.pending` · `workboard.save.saved` · `workboard.save.privateDraft` · **`common.settings`**

⚠️ **`common.settings` — check before deleting.** It went to zero references in the MAIN app's Swift sources when the sidebar stub's Settings row died, but it is a `common.*` key: confirm it is not reached from a share-extension catalog, the watch target, or a non-Swift surface before removing the row.

**Still referenced, do NOT delete on a stale scout row:** `workboard.title` (desk nav title + the ⌘1 menu) · `workboard.empty.title` · `workboard.loading` · `workboard.load.failed.title` · `workboard.load.failed.message` · `workboard.load.retry` · `common.ok` · `workboard.action.moveEarlier` / `workboard.action.moveLater` (2 refs each, in `WorkboardCaptureCanvas`'s material reorder — they were also in `WorkboardCard`, so a naive "the card died" sweep would wrongly kill them) · every `workboard.material.add*` / `composer.attach.takePhoto` / `workboard.material.large.confirm.*` key in `WorkboardMaterialRoute` + `workboardLargeImportAlert`.

---

## Requests

1. **desk-vm (`WorkboardViewModel.swift`) — snapshot fields that lost their last reader.** purge-core §3 kept these four deliberately, saying the view agent would free them. They are now free; I do not own that file:
   - `WorkboardItemSnapshot.state` — zero readers anywhere (`WorkItemState` the enum stays: the Core Data column and `StoredWorkItem.record(materials:)`'s constant `.draft` still need it; only the *presentation* extension died).
   - `WorkboardItemSnapshot.isPinned` — zero readers.
   - `WorkboardItemSnapshot.boardOrder` — zero readers.
   - `WorkboardItemSnapshot.reviewBy` — zero readers (its only two were `WorkboardCard`'s footer and a11y summary).
   - `WorkboardItemSnapshot.wasCapturedExternally` — the only remaining mention is `WorkboardLiveRepository.swift:268` writing it; nothing reads it.
   - `WorkboardItemSnapshot.displayTitle` / `.objective` still have readers: `WorkboardDetailView.swift:22,56` and `WorkboardCaptureCanvas.swift:88`, all via `WorkboardCaptureDestination.existingWork(item.displayTitle)`. They go only when desk-detail lands its static title and capture-canvas collapses the destination — do not delete them on my account.
2. **desk-upsert (`WorkboardRecords.swift`)** — I did not touch it, as instructed. Nothing I deleted removes a reader of anything declared there except through §Requests 1's snapshot fields.
3. **mac-shell (`MainWindowView.swift`) — what it must STOP consuming:** `WorkboardExperience` now takes only `(viewModel:isActive:reduceMotion:)`, exposes only `.detailColumn` and `.presentationModifier`, and has **no `sidebarColumn`**. I already removed the three `@SceneStorage`/`@State` Work presentation properties, the six dropped init arguments, and the sidebar mount (§5) so the build stays green — treat those as done, not as your remaining work. Still yours: whether `mountedSidebarDestinations` should collapse further now that only Chat's sidebar mounts there, whether `mountsWorkLayer` / `workLayerIdentity` still earn their keep on the detail side alone, and the Work-mode-collapses-the-sidebar behaviour of Codex #10c. The measured toolbar anchors are untouched by me.
4. **copy/docs agent — one false string I deliberately left alone:** `workboard.load.failed.message` still reads *"Your **projects** stay private and unchanged. Try opening **them** again."* on the desk's load-error surface. Plan §B lists four sanctioned copy rewrites and this is not one of them, and a parallel agent must not edit the catalog, so I left source and catalog in agreement. It wants a desk-truthful rewrite in the serial copy pass (key kept).
5. **serial integration — `WorkboardMetrics.cardCornerRadius` is now unread** (it was the project card's radius). I kept the enum whole per the scout's KEEP row rather than start a conflict over one line in a parallel wave; delete it in the serial pass if capture-canvas has not claimed it for material cards by then.
6. **inbox-lease agent (FYI, no action):** your `ConduckTests/WorkCaptureInboxLeaseTests.swift` was mid-flight during my first `build-for-testing` with 11 `'await' in an autoclosure` errors (§6). It compiled clean on my retry, so this is a record of the window, not a live defect.
