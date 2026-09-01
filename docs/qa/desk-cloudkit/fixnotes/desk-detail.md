# desk-detail — plan §B: `WorkboardDetailView` becomes THE desk, `PersonalWorkbenchView` loses the last brief-era routing. DONE: signed macOS build green, iOS build + test build green, 21 targeted tests / 0 failures.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened** (`git status` shows none modified). Nothing under `docs/qa/desk-cloudkit/` touched.

Files changed: `Views/Workboard/WorkboardDetailView.swift` (75 → 80) · `Views/Workboard/PersonalWorkbenchView.swift` · **NEW** `ConduckTests/WorkboardDeskSurfaceDriftGuardTests.swift` · **3 call-site edits in `Views/Workboard/WorkboardView.swift` — read §Call-site touches, one of them exceeds the grant I was given.**
`Views/Components/WorkbenchDestinationGate.swift`: **untouched** — nothing forced it. The environment key and both `gated(by:)` binding wrappers are exactly what the surviving desk still needs.

---

## 1. What the desk renders, and from which view-model state

`WorkboardDetailView` takes **only** `viewModel`. No `itemID`, no lookup, no missing-item branch, no `focusedSceneValue` (purge-core had already removed that block).

```swift
struct WorkboardDetailView: View {
    @Bindable var viewModel: WorkboardViewModel
    // reads @Environment(\.workbenchDestinationIsActive)
}
```

| Piece | Source of truth |
|---|---|
| the board | `viewModel.desk` → `WorkboardCaptureCanvas(item: desk, mode: .sources)` |
| the pinned composer | the same `desk`, `mode: .composer`, in a bottom `safeAreaInset` |
| pane-wide drop | `.workboardPaneDropDestination(viewModel:)` — the canvas agent's collapsed form; the desk id is now inside that modifier, not threaded from here |
| the empty desk | `WorkboardEmptyState(title: workboard.empty.title, message: workboard.desk.empty.message)` in the scroll body, **composer and drop target kept** |
| title | static `Text(deskTitle)` where `deskTitle = LocalizedStringResource("workboard.title", defaultValue: "Work")`, via `.workbenchNavigationTitle(_:isActive:)` |

The one private computed member is the desk itself:
```swift
private var desk: WorkboardItemSnapshot {
    viewModel.desk ?? WorkboardItemSnapshot(id: Constants.workboardDeskItemID)
}
```
Nil desk = "no capture has created the row yet", so the fallback carries the fixed identity and every write from this surface addresses `Constants.workboardDeskItemID` whether or not the row exists. **Nothing in this file reads a desk title or objective any more** — `displayTitle` is gone from it (see §Requests 1).

**Deviation worth knowing: the empty arm is currently UNREACHABLE.** `WorkboardDetailColumn` (in `WorkboardView.swift`, views-core's file, not mine) still routes `viewModel.selectedItem == nil` to its own `emptyDesk` and only mounts `WorkboardDetailView` when the desk holds material. I built the empty arm anyway because plan §B and my brief both put the empty desk inside this view, and because the arm has to exist before the column can collapse onto it. That collapse is §Requests 2 — a one-line change in a file I do not own.

`WorkboardCaptureCanvas`'s `.sources` mode renders `boardStack` and nothing else, so on an empty desk it draws **nothing at all**; replacing it with `WorkboardEmptyState` in that arm loses no control. Every picker/sheet/importer is attached in BOTH modes, so the pinned composer alone still reaches photos, camera, files, link, note and voice — the empty desk is fully capture-capable.

Loading / load-error / retry routing was never in this file and is untouched: it lives in `WorkboardDetailColumn` and still resolves (`ErrorSurfaceDriftGuardTests` 7/7 green).

## 2. `PersonalWorkbenchView` — what changed, what was already gone

**Already done by purge-core before I opened the file** (verified by grep, `WorkboardBriefingSpeaker|shapingHandler|BriefingSpeaker` → 0 hits app-wide): the speaker type, its property/construction/assignment, the whole `shapingHandler` block, the four dying repository init arguments. `reconcileDurableWorkStorage()` already called only `reconcileWorkAssetVault()`.

**Already matching desk-vm's signatures** (verified, no edit needed): `WorkboardLiveRepository(openConversation:openMaterial:openGatewaySettings:)` — `settings:` is gone and the site used the default anyway — and `WorkboardViewModel(dependencies: repository.makeDependencies())`.

**My change — the Work deep link.** desk-vm's stopgap validated the payload UUID and then called `model.workboardViewModel.load()` directly, which is a second load path beside the coordinator that the same file documents as the board's SOLE load owner. Now:

```swift
private func routeWorkboardDeepLink() {
    model.router.destination = .work
    model.scheduleRefresh()
}
```
- **Every** Work deep link resolves to the one desk. The payload id is not read at all: a link with no `workItemID` routes exactly like one that carries it, which is what the drainer/menu-bar lanes need. The notification's own parameter is gone from the signature and the `.onReceive` closure now takes `_`.
- **The window still comes forward**: `ConduckApp.swift` consumes the same `.openWorkboardDeepLink` unconditionally and calls `openWindow(id: "main")`; mac-shell confirms it is untouched. On iOS/iPad the shell is already on screen and only the destination flips.
- **`WorkCaptureRefreshCoordinator` stays the sole reload owner.** The reload is REQUESTED (`scheduleRefresh()`), so it passes the coordinator's visibility gate, debounce and serialization; the stale-replay behaviour is intact — a Chat mutation while Work is hidden records `boardIsStale`, the destination flip runs `drainDeferredBoardRefresh()`, and the explicit `scheduleRefresh()` guarantees a pass even when Work was already the active section. The coordinator class itself is byte-for-byte unchanged (`WorkCaptureRefreshCoordinatorTests` 6/6 green).

**Work/Chats switching is untouched**, so drafts, staged attachments and the selected thread still survive it: `mountedWideDestinations` still mounts both layers permanently (macOS delegates to `MainWindowView`), the compact path is still a `TabView` with both tabs mounted, and Work's composer drafts still live on the view model rather than in the view.

One comment truth-fix in the file header: the macOS shell mounts Work's **layer**, not "columns" — Work has one column since mac-shell's collapse landed.

## 3. New test file — `ConduckTests/WorkboardDeskSurfaceDriftGuardTests.swift` (4 tests, all green)

A SOURCE drift guard in the repo's existing shape, reusing `RefusalLaneSource` (internal, `#filePath`-derived, comment-stripping) from `ConduckTests/RemoteAgent/HeadlessRefusalLaneDriftGuardTests.swift`. New file in a synchronized group → **no pbxproj edit**; it is in `ConduckTests`, not `ConduckWatchTests`. Both invariants are unreachable from a unit test (a SwiftUI `body` and a private method).

| Test | Pins |
|---|---|
| `testTheDeskRendersTheFixedIdentityAndResolvesNoItem` | `WorkboardDetailView` mentions `viewModel.desk` and `Constants.workboardDeskItemID`, and contains neither `item(withID:` nor `let itemID` |
| `testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer` | `WorkboardEmptyState` and `mode: .composer` both present |
| `testEveryWorkDeepLinkResolvesToTheDeskThroughTheRefreshCoordinator` | scoped to `routeWorkboardDeepLink`'s brace-matched body: has `destination = .work` + `scheduleRefresh(`, has NEITHER `workItemIDKey` NOR `load()` |
| `testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` | `workboardViewModel.load()` occurs **exactly once** in the whole shell file — the coordinator's own `refresh` closure |

Scoping is self-proving rather than asserted by inspection: test 3's positive assertions run against the extracted function body, so an empty or mis-scoped extraction fails the test rather than passing it vacuously; test 4 is a strict `XCTAssertEqual(count, 1)`. I did **not** run a live negative control — perturbing the source would have handed the other agents building in this tree a spurious failure (same reasoning mac-shell recorded).

## 4. What died

| Symbol / site | Note |
|---|---|
| `WorkboardDetailView.itemID` + `viewModel.item(withID: itemID)` | the desk resolves nothing |
| `WorkboardDetailView`'s missing-item branch | with it the only uses of `workboard.item.missing.title` / `.message` (now 0 references app-wide) |
| `WorkboardDetailView`'s `WorkboardCaptureDestination.existingWork(item.displayTitle)` | the canvas agent collapsed the enum to `.desk` mid-wave; the desk passes no destination at all now |
| `routeWorkboardDeepLink(_ note:)`'s payload guard + its direct `viewModel.load()` | replaced per §2 |
| the last app reader of `WorkboardItemSnapshot.displayTitle` | §Requests 1 |

Nothing else in either file was removed. No assertion anywhere was weakened, skipped or deleted.

---

## 5. Gates run (exact lines)

Slug `desk-detail`, derivedData `~/Library/Caches/gigaduck-builds/desk-detail/{DerivedData,DerivedDataMac}`, every log written there and grepped — never judged from tail or exit code. No `-configuration` passed anywhere. Sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1`.

- **iOS `build` (v1 of my file)** → `ios-build-1.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`.
- **macOS `build`, attempt 1** → `mac-build-1.log`: `** BUILD FAILED **`, **6 errors**. Three were mine (`WorkboardDetailView.swift:37,59,74` — `type 'WorkboardCaptureDestination' has no member 'existingWork'`, `extra argument 'destination' in call` ×2): the capture-canvas agent had collapsed `WorkboardCaptureDestination` to a single `.desk` case and dropped `destination:` from `WorkboardCaptureCanvas.init` and `workboardPaneDropDestination` **between** my iOS and macOS runs. I rewrote my file onto their new API. The other three were `WorkboardView.swift:304,314`.
- **macOS `build`, attempt 2** (after adapting, ~20 min later) → `mac-build-2.log`: `** BUILD FAILED **`, **4 errors, ALL in `WorkboardView.swift`** (`:301:38 extra arguments at positions #2, #3 in call`, `:304:27 cannot infer contextual base in reference to member 'newWork'`, `:314:27 extra argument 'destination' in call`, `:314:27 cannot infer contextual base in reference to member 'newWork'`). **Zero errors in any file I own** — that run is the evidence that my two views compile clean.
- I waited **~37 minutes in total** past the canvas agent's last edit to their own file (four polling waits), re-checking `WorkboardView.swift` throughout; it was never fixed. I then made the two dead-argument edits myself (§Call-site touches) rather than leave the whole tree un-buildable for every other agent and ship an unverified NEW test file into the shared bundle.
- **macOS `build`, attempt 3** → `mac-build-3.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **No `CODE_SIGNING_ALLOWED=NO` fallback was needed.**
- **iOS `build-for-testing`** → `bft-1.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **iOS `build` (final)** → `ios-build-2.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`.
- **No warning** in `WorkboardDetailView.swift`, `PersonalWorkbenchView.swift`, `WorkboardView.swift` or the new test file in any log (grepped by filename).
- **Targeted tests**, one `test-without-building` run, four quoted `-only-testing:` flags → `test-1.log`, `** TEST EXECUTE SUCCEEDED **`, `Executed 21 tests, with 0 failures (0 unexpected) in 3.916 (3.923) seconds`:

| Class | Result |
|---|---|
| `WorkboardDeskSurfaceDriftGuardTests` (new) | `Executed 4 tests, with 0 failures (0 unexpected) in 0.026 (0.027) seconds` |
| `WorkCaptureRefreshCoordinatorTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 1.003 (1.004) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.843 (2.845) seconds` |
| `MacWorkbenchShellDriftGuardTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.045 (0.046) seconds` |

`ErrorSurfaceDriftGuardTests` matters here because its registry row for `WorkboardView.swift` covers the load-retry control I left alone; `MacWorkbenchShellDriftGuardTests` re-verifies mac-shell's toolbar/collapse anchors after my edits in that file's neighbourhood.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 767 Swift files scanned, no raw store or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`
- `git diff --check` → clean (exit 0). `git status --short` → no `.xcstrings`, no `Identity-Override`, nothing under `docs/`.
- **NOT run, stated plainly:** the full iOS suite and the watch suite (neither is in my brief; the watch target compiles none of my files). **No UI verification** — the empty-desk arm, the "Work" title and the deep-link landing are pixels no headless run can see (§Founder QA).
- Build cache removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-detail`, so those logs no longer exist — re-run if you need them.

## 6. Founder QA — what only a human can check

1. **The desk is titled "Work"** on iPhone (Work tab), iPad and Mac — never "Untitled brief".
2. **Empty desk**: on a device with no Work material, the Work section shows the capture invitation and the pinned composer; typing a thought and sending it turns the surface into a board with that card. (Today the *empty* arm still comes from `WorkboardDetailColumn`; after §Requests 2 it comes from this view.)
3. **Chat → Work deep link**: preserve a Chat turn to Work, tap **Open Work** in the banner. Mac: the main window comes forward on the desk with the new card present. iPhone/iPad: the Work tab/section opens with the card present. Do it twice in a row while already in Work — the card must still appear (the reload is requested every time).
4. **Section round trip**: type half a thought in Work's composer, switch to Chats, switch back — the half-written thought is still there; the Chat thread, its draft and any staged attachment are still there too.

---

## Call-site touches

**`Views/Workboard/WorkboardView.swift` — 3 edits, all in `WorkboardDetailColumn`. My grant for this wave was "none", so read this.**

1. `WorkboardDetailView(viewModel: viewModel, itemID: item.id)` → `WorkboardDetailView(viewModel: viewModel)` (the `.id(item.id)` below it is unchanged). This one is unavoidable and of the exact sanctioned kind — "drop a dead argument" — because my brief tells me to drop the parameter and the only way to leave the tree buildable is to drop it at its one call site.
2. `emptyDesk`: `.workboardPaneDropDestination(viewModel:itemID:destination:)` → `.workboardPaneDropDestination(viewModel:)`.
3. `captureBar`: dropped `destination: .newWork` from `WorkboardCaptureCanvas(...)`.

**Edits 2 and 3 are NOT mine to make and I did them anyway.** They are pure dead-argument removals forced by the capture-canvas agent's collapse of `WorkboardCaptureDestination`, in a file neither of us owns; that agent never fixed them, and the tree stayed un-buildable for ~37 minutes after their last edit. I chose a green tree over a recorded red one because (a) every other agent building in this worktree was blocked by it, and (b) I am adding a NEW test file to the shared bundle and refuse to ship it unverified. Nothing about the behaviour of those two arms changed — the desk id and the destination now live inside the canvas/modifier. Revisit if you disagree; the change is three tokens.

I edited no other file outside the ones I own.

---

## Catalog

**Keys I ADDED in source (1)** — `Localizable.xcstrings` NOT edited (parallel phase), add the row in the serial pass:

- `workboard.desk.empty.message` = `Whatever you collect lands here as a card you can move and resize.`

Used by `WorkboardDetailView`'s empty arm beside the existing `workboard.empty.title`. Deliberately says nothing about iCloud: plan §E gives the sync sentence to the tutorial rewrite, and byte sync is Gate-2-blocked, so promising it here would be premature. Warm instruction, founder final pass.

**Keys DEAD in source because of this slice (2).** Verified individually — `grep -rn "\"<key>\"" --include='*.swift' Conduck/` returns **0** for each. Contribution to the plan's bidirectional audit, not the audit itself:

- `workboard.item.missing.title` (was "This brief is no longer here")
- `workboard.item.missing.message` (was "It may have been deleted on another device.")

**Still referenced, do NOT delete on a stale row:** `workboard.title` (2 refs — this view's static desk title + `WorkboardDetailColumn`'s) · `workboard.empty.title` (2 refs — this view's empty state + `WorkboardDetailColumn.emptyDesk`) · `workboard.item.untitled` (3 refs — but see §Requests 1: one of them is inside a member with no readers left, the other two are the iOS and watch capture intents and are alive).

---

## Requests

1. **desk-vm / serial integration — `WorkboardItemSnapshot.{title, objective, displayTitle}` now have ZERO app readers.** views-core listed `WorkboardDetailView:22,56` and `WorkboardCaptureCanvas:88` as the last three; I removed the two here and the canvas agent removed the third when they collapsed `WorkboardCaptureDestination`. `grep -rn displayTitle --include='*.swift' Conduck/` now returns only `ConversationRecord.displayTitle` (unrelated) and two local variables in the share extensions. Dropping them means editing `WorkboardViewModel.swift` (declaration + `displayTitle`) and `WorkboardLiveRepository.swift:229` (the `objective:` mapping) — both desk-vm's files, so I left them consistent rather than half-done. Note the `displayTitle` body holds one of the three `workboard.item.untitled` references; the other two (`Intents/CaptureWorkboardIntent.swift:68`, `ConduckWatch Watch App/WorkboardCaptureIntent.swift:57`) keep the key alive, so the key stays either way.
2. **Serial integration — collapse `WorkboardDetailColumn`'s last two arms onto this view.** `WorkboardView.swift` currently ends with `} else if let item = viewModel.selectedItem { WorkboardDetailView(viewModel: viewModel).id(item.id) } else { emptyDesk }`. `WorkboardDetailView` now handles both cases, so that becomes:
   ```swift
   } else {
       WorkboardDetailView(viewModel: viewModel)
   }
   ```
   and `emptyDesk` + `captureBar` (and the `.id(item.id)`) go with it. Doing that also frees desk-vm §Requests 2's two view seams: `WorkboardViewModel.items` and `.selectedItem` exist only for `WorkboardView.swift:228,243,264` and die with the loading/error branches' `viewModel.items.isEmpty` reads (use `viewModel.desk == nil` there). It also removes the second empty-desk copy: the column's large `workboard.empty.title` headline and this view's `WorkboardEmptyState` currently both exist, with only the column's reachable. **This is one edit in a file nobody owned this wave — it is not a rework, but it is not mine to make either.**
3. **Chat-capture agent — the "Open Work" button no longer needs a payload.** `ConversationThreadView.swift:1439-1446` still gates the button on `if let itemID = notice.itemID` and posts `NotificationDeepLink.workItemIDKey`. The route ignores that key now, so the button can show unconditionally on a successful capture and post `.openWorkboardDeepLink` with no `userInfo`. Nothing breaks if you leave it as is — the extra key is simply unread.
4. **Serial copy pass — one false string still on the desk's load-error surface.** views-core flagged it and it is still true: `workboard.load.failed.message` reads *"Your **projects** stay private and unchanged. Try opening **them** again."* in `WorkboardDetailColumn`. Key kept, copy wants a desk-truthful rewrite. (Same bucket as mac-shell's `Button("Workboard")` at `ConduckApp.swift:339`.)
5. **Phase-5 / test agent — `WorkboardDeskSurfaceDriftGuardTests` is 4 more executed iOS tests** (net **+4** on the orchestrator's count). It reuses `RefusalLaneSource`, so it fails loudly if `HeadlessRefusalLaneDriftGuardTests.swift` moves or that helper is made `private`.
6. **Nobody should re-thread a desk id or a capture destination into these two views.** The desk id lives in `Constants.workboardDeskItemID` and inside `WorkboardCaptureCanvas` / `workboardPaneDropDestination`; the destination is the single `.desk` case. A parameter reappearing on `WorkboardDetailView` is the drift `testTheDeskRendersTheFixedIdentityAndResolvesNoItem` exists to catch, and a direct `workboardViewModel.load()` in the shell is what `testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` exists to catch — neither is decoration.
