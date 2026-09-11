# capture-canvas — plan §B capture-canvas trim + §A composer retarget. DONE; my file builds green on both platforms, the SHARED tree does not (4 errors in `WorkboardView.swift`, a file I do not own — §5A, exact patch in §Requests 3).

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched.

Files changed: `Views/Workboard/WorkboardCaptureCanvas.swift` — **the only file I edited.** 1885 → **1861** lines (1948 at `651a859`; purge-core took it to 1885).
Files I own and did NOT change: `WorkboardTextMaterialSheet.swift` (nothing in it targets an item — it hands a `WorkboardMaterialImport` back through `onAdd`; see §Requests 4 for one false string in it), `WorkboardVoiceCaptureView.swift` (not forced; plan §D's audio agent owns that path).
No test file names any symbol of mine: `grep -rn 'WorkboardCaptureCanvas\|WorkboardCaptureDestination\|AttachmentMenuPurpose' Conduck/ConduckTests/` → **0 hits**. There were no owned test classes to run.

---

## 1. Capture entry points and what each targets now

Every write below names `Constants.workboardDeskItemID` **literally**. The `item:` snapshot the host passes is now read for two things only — the cards to draw and the count a photo name numbers from — never for an identity. That is deliberate: on the desk-before-its-first-material canvas the host passes a placeholder snapshot, and a capture must land on the identity the first card will land on, not on whatever the placeholder happens to carry.

| Entry point | Symbol | Targets |
|---|---|---|
| Composer save (typed thought) | `addThought()` → `viewModel.addWorkspaceThought(_:to:)` | desk id |
| Composer draft read/write | `composerText`, `composerTextBinding` → `workspaceComposerDraft(for:)` / `setWorkspaceComposerDraft(_:for:)` | desk id |
| Voice hand-off | `.sheet(isPresented: activeVoiceCaptureIsPresented)` `onTranscript` → `setWorkspaceComposerDraft` | desk id (still a composer draft; audio-card capture is plan §D, not here) |
| Text / link sheet | `.sheet(item: activeMaterialComposer)` → `importWorkspaceMaterials(_:to:)` | desk id |
| Photo picker (12-image cap kept) | `importPhotos(_:)` → `importResolvedBatch(_:)` | desk id |
| Camera (iOS) | `importCameraPhoto(_:)` → `importResolvedBatch(_:)` | desk id |
| File importer | `handleFileImport(_:)` → `importResolvedBatch(_:)` | desk id |
| Reattach / replace | `reattach(_:from:)` → `reattachWorkspaceMaterial(_:in:with:)` | desk id |
| Pane-wide drag/drop | `WorkboardPaneDropModifier.importResolvedBatch(_:)` | desk id |
| Import progress chip | `importProgress` compares `workspaceImportState.itemID` | desk id |
| Board arrange (drag, Move Earlier/Later, card size, remove) | `WorkboardMaterialBoard.drop/move/setSize/remove`, and the `WorkMaterialDragPayload` it mints | desk id |

Large-import confirmation, the security-scope bookkeeping, the drop timeout/reclaim machinery and the partial-success report are untouched.

## 2. What died

| Symbol | Verdict |
|---|---|
| `WorkboardCaptureCanvasMode.full` | **DELETED** (never instantiated). `mode` is now a non-defaulted `let` — a host says which half it wants |
| `expandedComposer` | **DELETED** (its only host was `.full`) |
| the `.full` body branch | **DELETED** — with it the last `WorkboardSurface` consumer in the app (§Requests 1) |
| `WorkboardCaptureDestination.existingWork(String)` / `.newWork` | **DELETED** → one case `desk`, title-free copy |
| `WorkboardCaptureCanvas.destination` parameter + the custom-init default `?? .existingWork(item.displayTitle)` | **DELETED** — `private let destination = .desk` states it instead |
| `workboardPaneDropDestination(viewModel:itemID:destination:)` | → **`workboardPaneDropDestination(viewModel:)`**; the modifier's `itemID` and `destination` stored properties are gone |
| `WorkboardPaneDropModifier`'s `.onChange(of: itemID) { cancelDropWork() }` | **DELETED** — with one desk the id never changes, so the trigger could not fire. `.onDisappear` and the `workbenchDestinationIsActive` change still cancel a drop in flight |
| `WorkboardCaptureDestination` visibility | now **`private`** (file-scope): a host does not pick a destination, which is what stops a second one creeping back |

`reviewAndSend`, `reviewAndSendButton`, `isReviewing`/`reviewTask` and the `isReadyToSend` gate were already gone (purge-core); nothing of them remained to remove.

**Kept exactly as they were, per brief:** Chat's paperclip / filled-mic / filled-arrow geometry (`composerCard`, `compactComposerRow`, `CaptureCircleButton`, `composerCardChrome()`, `composerReadableWidth()`), the Work-scoped attach menu (`WorkboardMaterialActions(presentation: .menu)` → `AttachmentMenu(purpose: .work)` — never Chat's file-transfer setup item), the 12-image `maxSelectionCount`, `workboardLargeImportAlert`, and the privacy hint/status copy (`workboard.workspace.add.hint`, `workboard.workspace.thought.saved`). The availability chip/badge area is untouched — no `syncedPending` chip pre-built.

## 3. Deviations, with reasons

1. **The destination collapse is source-breaking for hosts, by construction.** `.existingWork(String)` and `.newWork` were spelled at three call sites in two files I do not own. No collapse can keep them compiling — a single case cannot answer to two old spellings without a shim that re-introduces the vocabulary the plan deletes. So the type collapsed and the hosts must drop two arguments (§Requests 3 has the exact patch). The desk-detail agent adapted `WorkboardDetailView.swift` mid-wave on its own; `WorkboardView.swift` was still on the old spelling at my first build (§5).
2. **Three new string keys rather than reused stale ones.** Neither surviving spelling fits a title-free desk: `…prompt.new` says "Start a new work item…", `…drop.overlay.new` says "Drop to create New Work", and both `.existing` variants interpolate a title that no longer exists. I did not rewrite live copy — I retired six keys and minted three (§Catalog). The caption's WORDS are carried over verbatim from `…overlay.existing.caption`; only its key changed, so the strings phase moves a translation rather than writing one.
3. **`item:` stays a parameter** even though only `materials` and `materials.count` are read from it. Passing a `[WorkboardMaterialSnapshot]` instead would be a host-signature change in files I do not own, for no behaviour.
4. **VM vocabulary left alone** (desk-vm §Requests 3). Renaming `addWorkspaceThought` / `importWorkspaceMaterials` / `workspaceComposerDraft(for:)` / `isCapturingIntoAnyWorkspace` / `workspaceImportState` / `workspaceStatus` and dropping their `to itemID:` / `in itemID:` parameters is an edit of `WorkboardViewModel.swift`, which I do not own this wave (minimal-touch rights: none). My side is ready for it: every call passes the desk constant, so the parameters can be deleted in one pass. §Requests 2.

## 4. Call-site touches

**NONE.** I edited exactly one file. Everything that would have been a call-site touch is a Request below.

## 5. Gates run (exact lines)

Slug `desk-capture-canvas`, all derivedData + logs under `~/Library/Caches/gigaduck-builds/desk-capture-canvas/`, every log grepped for `': error: '` and `BUILD SUCCEEDED|BUILD FAILED|TEST BUILD …` — never judged from tail or exit code. No `-configuration` passed anywhere.

**A. Shared worktree — both builds FAIL, all 4 errors in a file I do not own.**

- iOS (`-destination 'platform=iOS Simulator,id=6C3FB33E-D89F-4D1E-9F0D-3FAC0C089228'`) → `ios-build-1.log`: `grep -c ': error: '` = **4**, `** BUILD FAILED **`.
- macOS (`-destination 'platform=macOS'`) → `mac-build-1.log`: `grep -c ': error: '` = **4**, `** BUILD FAILED **`. Same four, so the failure is platform-independent.

The four, verbatim and identical in both logs:
```
Conduck/Conduck/Views/Workboard/WorkboardView.swift:301:38: error: extra arguments at positions #2, #3 in call
Conduck/Conduck/Views/Workboard/WorkboardView.swift:304:27: error: cannot infer contextual base in reference to member 'newWork'
Conduck/Conduck/Views/Workboard/WorkboardView.swift:314:27: error: extra argument 'destination' in call
Conduck/Conduck/Views/Workboard/WorkboardView.swift:314:27: error: cannot infer contextual base in reference to member 'newWork'
```
**Zero errors and zero warnings in any file of mine**, on either platform (`grep -n 'WorkboardCaptureCanvas.swift.*warning'` → no output in both logs). Per the parallel-phase rule I waited past 120 s and rebuilt (the macOS run above was after the wait); `WorkboardView.swift` was unchanged since 20:12 and still on the old spelling at 20:24. `WorkboardDetailView.swift` — the other host — adapted itself to the new API mid-wave at 20:14 and compiles clean. §Requests 3 is the exact two-hunk patch.

**B. Isolated verification copy — both builds GREEN.** Because "it fails in someone else's file" is not evidence that MY file is correct, I verified it without touching the shared tree: `cp -R` of the worktree into `…/desk-capture-canvas/verify/fake/.codex/worktrees/tree`, with `…/verify/fake/Conduck-Private` symlinked to the real `Conduck-Private` so the repo's own relative `Identity-Override.xcconfig` symlink resolves to the real file. **Nothing in the shared worktree and nothing in `Conduck-Private` was written**; the only edit in the copy is §Requests 3's two-hunk patch to `WorkboardView.swift`. The whole `verify/` tree died with the slug directory.

- iOS build of the copy → `verify-ios.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`.
- macOS build of the copy → `verify-mac.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`. Signed through the identity override; **no `CODE_SIGNING_ALLOWED=NO` fallback was needed**.
- No warning in `WorkboardCaptureCanvas.swift` in either log.
- `build-for-testing` of the copy → `verify-bft.log`: `** TEST BUILD FAILED **`, `grep -c ': error: '` = **3**, all three in `ConduckTests/WorkboardChatCaptureTests.swift` (`:36,:72,:172`, each `error: 'async' call in an autoclosure that does not support concurrency`) — an untracked file another agent was writing when I took the copy, not a file of mine and not reachable from my change. **Stated plainly: I did not get a green test-bundle build, and I ran no tests.** No test in the repo names `WorkboardCaptureCanvas`, `WorkboardCaptureDestination`, `workboardPaneDropDestination` or `AttachmentMenuPurpose` (grep over `ConduckTests/` + `ConduckWatchTests/` → 0 hits), so there was no owned class to run.

**C. Hygiene.** `git diff --check` → clean. `git status` shows no `.xcstrings`, no `Identity-Override.xcconfig`, nothing under `docs/`. I ran no full iOS suite and no watch suite — neither is in my brief, and the watch target compiles none of my files. Build cache removed at the end with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-capture-canvas`, so the logs above no longer exist — re-run if you need them.

---

## Catalog

**Keys I ADDED in source (3)** — `key = defaultValue`, all in `WorkboardCaptureDestination`, main app catalog:

- `workboard.workspace.composer.prompt` = `Add to Work…`
- `workboard.workspace.drop.overlay.title` = `Drop into Work`
- `workboard.workspace.drop.overlay.caption` = `Files, photos, screenshots, links and text will be added here. Nothing is sent.`

None of the three exists in `Conduck/Conduck/Localizable.xcstrings` yet (checked by JSON load, read-only). The catalog is English-only (`sourceLanguage: en`, no other localizations), so retiring the six keys below costs no translation.

**Keys DEAD in source because of this slice (6).** Each verified individually: `grep -rn "\"<key>\"" --include='*.swift' Conduck/` returns **0**.

`workboard.workspace.composer.prompt.existing` · `workboard.workspace.composer.prompt.new` · `workboard.workspace.drop.overlay.existing` · `workboard.workspace.drop.overlay.existing.caption` · `workboard.workspace.drop.overlay.new` · `workboard.workspace.drop.overlay.new.caption`

**Still referenced from my file, do NOT delete on a stale scout row:** `workboard.workspace.attach` · `workboard.workspace.add` · `workboard.workspace.add.hint` · `workboard.workspace.thought.saved` · `workboard.workspace.import.progress` · `workboard.workspace.drop.image` · `workboard.voice.capture` · `workboard.material.importing` · `workboard.material.photo.defaultName` · `workboard.material.file.failed.title` · `workboard.material.remove.confirm.title` / `.remove.confirm.message` / `.remove.action` · `workboard.material.card.more` / `.card.size` / `.card.size.{small,standard,large}` / `.card.size.*.action` / `.card.position` · `workboard.material.open` · `workboard.material.reattach.action` / `.reattach.short` · `workboard.material.localOnly` · `workboard.action.moveEarlier` / `workboard.action.moveLater` · `composer.camera.deniedTitle` / `.deniedMessage` / `.openSettings` / `.cancel` · `common.cancel`.

---

## Requests

1. **`WorkboardComponents.swift` (views-core / serial) — `WorkboardSurface` now has ZERO consumers.** Its last one in the app was the `.full` branch I deleted (`git grep WorkboardSurface HEAD` shows the others were `WorkboardBriefingView` + `WorkboardDispatchSheet`, both deleted by purge-core). Plan §B calls `WorkboardSurface` "the desk container", but the desk that shipped this wave (`WorkboardDetailView` + `WorkboardView.emptyDesk`) deliberately draws NO container so the whole pane reads as the drop target. So either the desk adopts it or it dies — it cannot stay as-is. Same file, unrelated to me but found while checking: `WorkboardMaterialActions(presentation: .row)` has **zero call sites in the whole repo, including at HEAD** — with it `rowRoutes`, `action(for:)`, `label(for:)`, `Presentation.row` and all of `WorkboardMaterialRoute` are dead (views-core kept `WorkboardMaterialRoute` *because* `.row` reads it; that reason does not hold). Only `presentation: .menu` is live, from my `attachmentMenu`.
2. **`WorkboardViewModel.swift` (desk-vm's file) — the vocabulary rename is unblocked.** Every capture call from my file now passes `Constants.workboardDeskItemID` literally, so `to itemID:` / `in itemID:` can be deleted from `addWorkspaceThought`, `importWorkspaceMaterials`, `reattachWorkspaceMaterial`, `reorderMaterial`, `moveMaterial`, `setMaterialCardSize`, `removeMaterialFromBoard`, `workspaceComposerDraft(for:)`, `setWorkspaceComposerDraft(_:for:)` in one pass; my side needs a mechanical argument removal, no logic change. Same for the `workspace*` → `desk*` renames and `isCapturingIntoAnyWorkspace`. Keep the VM's non-desk refusal (`testCaptureAimedAtAnyBoardButTheDeskIsRefusedWithoutReachingTheStore`) meaningful: if the parameters go, that guard's subject goes with them — decide deliberately, do not delete the test silently.
3. **`WorkboardView.swift` (views-core's file / serial integration) — 4 build errors, EXACT patch.** This is the only thing standing between the tree and a green build; `WorkboardDetailView.swift` already adapted itself mid-wave. Both hunks are pure argument deletions:
   ```swift
   // :301-305  emptyDesk
   .workboardPaneDropDestination(viewModel: viewModel)     // was (viewModel:itemID:destination:)

   // :309-315  captureBar
   WorkboardCaptureCanvas(
       viewModel: viewModel,
       item: viewModel.item(withID: Constants.workboardDeskItemID)
           ?? WorkboardItemSnapshot(id: Constants.workboardDeskItemID),
       mode: .composer                                     // drop `destination: .newWork`
   )
   ```
4. **Copy pass (serial) — two false strings I deliberately left alone**, both outside the four rewrites plan §B sanctions, and a parallel agent must not move the catalog:
   - `workboard.material.link.footer` (`WorkboardTextMaterialSheet.swift`, a file I own) still reads *"The gateway receives the address as text. Conduck does not fetch the page in the background."* There is no gateway on any surviving Work path — the first sentence is false, the second is still true and worth keeping.
   - Key names, not copy: the three keys I minted sit in the `workboard.workspace.*` family whose vocabulary ("workspace") the desk retires. Renaming the family is a catalog-wide job for the serial pass, not a parallel one.
5. **Strings phase — add the three new keys to `Conduck/Conduck/Localizable.xcstrings`** (see §Catalog) and retire the six dead ones. Until then the three render from their `defaultValue`, which is correct English but invisible to the catalog. `workboard.item.untitled` picked up one more reason to die: nothing in my file reads `WorkboardItemSnapshot.displayTitle` any more (it was the destination's title source), and `WorkboardDetailView` stopped reading it this wave too — desk-vm §Requests 1 and views-core §Requests 1 both point at the same key.
6. **Plan §D audio agent — `WorkboardVoiceCaptureView.swift` is untouched and the hand-off is unchanged**: the sheet's `onTranscript` still writes a composer DRAFT (`setWorkspaceComposerDraft`, now keyed on the desk id) and the material is minted later by `addThought()`. Your two-phase capture replaces that seam; nothing in my slice pre-empts it. `WorkboardVoiceTarget.objective` (in `WorkboardViewModel.swift:194`) is still never constructed — only `.context` at my sheet — so `workboard.voice.objective` stays dead, as purge-core reported.
7. **ByteSync agent — the availability chip area is untouched, as briefed.** `WorkboardSourceCard.availabilityGlyph` / `availabilityLabel` still handle exactly `.localOnly` and `.unavailableOnThisDevice`; `previewText` still switches on four `WorkboardMaterialKind` cases. A `.syncedPending` chip and an `.audio` kind are both additive there.
