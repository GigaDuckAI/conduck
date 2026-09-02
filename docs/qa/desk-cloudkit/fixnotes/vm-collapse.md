# vm-collapse — ui#5 / ui#7 / ui#8 / ui#9 / ui#11 + t#8. All six CONFIRMED and fixed; nothing refuted. The stale-adoption counterfactual is MEASURED.

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `error:`) · my 10-class targeted set
`Executed 80 tests, with 0 failures` · **full iOS suite `Executed 4871 tests, with 1 test skipped and
1 failure`, and the one failure is the pre-existing share-writer guard fix2-store recorded** · signed
macOS `** BUILD SUCCEEDED **` (no `CODE_SIGNING_ALLOWED=NO` fallback) · **counterfactual: with the
`adopt` revision gate reverted, exactly the two new stale-result cases fail (4 assertions) and no
other case does.**

No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` opened**
(six dead keys listed under §Catalog, not deleted). No `.pbxproj` edit. No mirror triplet touched.
Nothing under `docs/qa/desk-cloudkit/` touched. Slug `vm-collapse`, sim `2B6E0EAC-…`.

Files changed (10) — 6 production, 4 tests:
- `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` (the bulk: −237/+…, one board, no board ids)
- `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift`
- `Conduck/Conduck/Views/Workboard/WorkboardComponents.swift`
- `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift`
- `Conduck/Conduck/Views/Workboard/WorkboardTextMaterialSheet.swift`
- `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` (router methods + the repository
  construction site only — fix2-canvas's `present` gate and preview naming untouched)
- tests: `WorkboardBoardProjectionTests` 1→**4** · `WorkboardWorkspaceCaptureTests` 6→**5** ·
  `WorkboardDeskViewModelTests` 5→5 · `WorkboardMaterialBoardActionsTests` 12→12

**Net for the orchestrator: +2 iOS executed** (4869 → **4871 measured**, 1 skip unchanged).

---

## 1. ui#7 — dead conversation / gateway-routing seams. CONFIRMED, removed end to end.

**Verified before editing**, by call path: `WorkboardLiveRepository` stored `openConversationHandler`
and `openGatewaySettingsHandler`, published both through `makeDependencies()`, and
`PersonalWorkbenchModel.init` wired them to `PersonalWorkbenchRouter.openConversation(_:)` /
`.openGatewaySettings()`. `grep` over `Conduck/Conduck/` for the two `Dependencies` members returned
the declaration and the repository's own closure and **nothing else** — no Work view, no intent, no
coordinator ever asked the view model to open a conversation or a gateway. `WorkboardViewModel`
carried a public `openGatewaySettings()` with zero callers; there was never a VM-level
`openConversation`.

**Deleted, in one chain:** `Dependencies.openConversation` · `Dependencies.openGatewaySettings` ·
`WorkboardViewModel.openGatewaySettings()` · the repository's two stored handlers and its two `init`
parameters · `PersonalWorkbenchRouter.openConversation(_:)` · `PersonalWorkbenchRouter.openGatewaySettings()`.
The repository's `init` now carries one handler and says why at its declaration: opening a card is
the only route out of the desk, so a door to anywhere else would have nothing behind it.

**Regression cover:** the compiler. Every removed symbol was a declaration with no reader, so the
regression is "a future re-introduction has to state a purpose"; there is no runtime behaviour to
assert. Four test files lost their `openConversation: { _ in }` / `openGatewaySettings: {}` rows
(§Call-site touches) — nothing they asserted depended on either.

**Consequence I did NOT chase, stated plainly (§Requests 1):** `router.openGatewaySettings()` was
the only poster of `.openPersonalAISettings`. The name and its four observers still exist and now
have no poster.

## 2. ui#8 — per-item workspace state in a one-desk model. CONFIRMED, collapsed.

**Verified:** composer drafts were `[UUID: String]` plus a `Set<UUID>` of non-empty ones; capture,
reattach, reorder, resize and removal each took `to itemID:` / `in itemID:`; and **every production
caller passed `Constants.workboardDeskItemID`** — `WorkboardCaptureCanvas` at 14 sites, and nothing
else calls them at all. Meanwhile the `Dependencies` closures below already named no owner, so the id
was carried across the view boundary only to be compared against a constant and dropped.

### What the view model is now

| Before | After |
|---|---|
| `workspaceComposerDrafts: [UUID: String]` + `nonEmptyComposerDrafts: Set<UUID>` | `private(set) composerDraft: String` + `private(set) hasComposerDraft: Bool`, written by `setComposerDraft(_:)` |
| `workspaceComposerDraft(for:)` / `setWorkspaceComposerDraft(_:for:)` / `hasComposerDraft(for:)` | `composerDraft` / `setComposerDraft(_:)` / `hasComposerDraft` |
| `item(withID:)` | **deleted** — callers read `desk` |
| `addWorkspaceThought(_:to:)` | `addThought(_:)` |
| `importWorkspaceMaterials(_:to:additionalFailureCount:announcesResult:)` | `importMaterials(_:additionalFailureCount:announcesResult:)` |
| `reattachWorkspaceMaterial(_:in:with:)` | `reattachMaterial(_:with:)` |
| `reorderMaterial(_:toInsertionIndex:in:)` · `reorderMaterial(_:relativeTo:placement:in:)` · `moveMaterial(_:direction:in:)` · `setMaterialCardSize(_:materialID:in:)` · `removeMaterialFromBoard(_:in:)` | same, **without `in:`** |
| `presentWorkspaceImportReport` / `presentWorkspaceCaptureFailure` / `acquireWorkspaceMutation` / `releaseWorkspaceMutation` / `performMaterialReorder(in:plan:)` | `presentImportReport` / `presentCaptureFailure` / `acquireDeskMutation` / `releaseDeskMutation` / `performMaterialReorder(plan:)` |
| `isCapturingIntoAnyWorkspace` | `isCapturingIntoDesk` (the literal "any workspace" the finding names) |
| `WorkboardWorkspaceImportState` (with `itemID`) · `WorkboardWorkspaceImportReport` | `WorkboardImportState` (**no `itemID`**) · `WorkboardImportReport` |
| `flushWorkspaceComposer(itemID:)` | **deleted** — see below |

**`flushComposer` deleted rather than collapsed.** After the rename I checked it had **zero callers
anywhere in the repo** (app, extensions, watch, tests — `grep` for both names returns only the
declaration). It is composer-draft-by-item state whose surface is gone; keeping a public
never-called mutation on the collapsed model would be the same shape as ui#5's un-fireable callback.
Stated here because no finding named it.

**`hasComposerDraft` kept and given its production reader.** The canvas's Add button computed
`cleanComposerText.isEmpty` — a second copy of the emptiness rule the model already states. It now
reads `!viewModel.hasComposerDraft`. Behaviour is identical by construction (both are
`normalizedThought(draft).isEmpty`), the rule is stated once, and the flag is written only when it
flips so a keystroke still does not invalidate the readers that only need emptiness — the reason the
old `Set<UUID>` existed, preserved.

**The refusal is now unrepresentable — so the refusal test is deleted, and here is which.**
`importWorkspaceMaterialsUnlocked` guarded `itemID == Constants.workboardDeskItemID` and returned an
all-failed report otherwise. With the parameter gone **a caller cannot express a non-desk target**:
there is no argument to pass, `addThought`/`importMaterials` name no board, and the id never reaches
the store. `WorkboardWorkspaceCaptureTests.testCaptureAimedAtAnyBoardButTheDeskIsRefusedWithoutReachingTheStore`
therefore asserted a state the type system now forbids, and it is **deleted** (the only test deleted
in this slice). Its sibling half — "a capture aimed elsewhere never reaches the store" — survives as
a compile-time fact, not an assertion.

**Assertions rewritten, one by one, and why each is still true:**

| Test | Was | Now |
|---|---|---|
| `WorkboardMaterialBoardActionsTests.testUnknownItemAndUnchangedOrderNeverReachTheStore` → renamed `…AnUnchangedOrderAndAnUnknownCardNeverReachTheStore` | `reorderMaterial(ids[0], toInsertionIndex: 0, in: UUID())` refused ("a board that is not the desk…") | `reorderMaterial(UUID(), toInsertionIndex: 0)` refused ("a card the desk does not hold…"). The unchanged-order half is untouched. The refusal it now states is the one that CAN still happen: the mosaic reports a slot for a card a sync just removed. |
| `WorkboardDeskViewModelTests.testOnlyTheDeskIsLoadedWhenALegacyProjectRowStillExists` | `XCTAssertNil(viewModel.item(withID: legacy.id))` ×2 | `viewModel.desk?.id == Constants.workboardDeskItemID` **and** `desk?.materials.map(\.name) == ["A thought that belongs on the desk"]` — the project's card is on no board this model loads. The store-side half (the project row and its card survive whole) is untouched. |
| `WorkboardBoardProjectionTests.testComposerFlagTracksNormalizedEmptinessRatherThanRawText` | keyed by `itemID` | keyed by nothing, **plus two new assertions** that the draft itself keeps the raw text — the property the old dictionary carried and the flag does not. |
| every `viewModel.item(withID: item.id)` in the board-actions and capture tests | — | `viewModel.desk`. Same value by definition of the deleted method. |

No assertion was weakened, skipped, or deleted for convenience; the one deletion is argued above.

## 3. ui#9 — `WorkboardSurface`. CONFIRMED dead, DELETED.

`grep -rn "WorkboardSurface"` over the whole worktree returned exactly one hit — its own declaration.
Deleted, together with `WorkboardMetrics.surfaceCornerRadius`, whose only two readers were inside it.
`AppColors.cardBackground` (52 other readers) and `AppColors.borderSubtle` (20) are untouched.

**Deviation from plan §B, deliberate and authorised by my brief.** Plan §B names `WorkboardSurface`
"the desk container". The shipped desk draws none: `WorkboardDetailView` renders the canvas full-pane
and `WorkboardCaptureCanvas`'s own comment states why ("the WHOLE pane is the drop target, and a
bordered surface would read as the one place a drop lands"). That reason is now in
`WorkboardComponents.swift`'s header so the next agent does not re-add one. Restorable from git.

## 4. ui#11 — the view model header's device claim. CONFIRMED false, rewritten.

The header said *"Nothing here leaves the device: every operation this model can perform writes to
the person's own private store."* The second clause is true and the first does not follow from it:
`ConversationStore`'s containers are `NSPersistentCloudKitContainer`s, so desk metadata already
mirrors, and after the blob work the eligible payload bytes do too. It now states the real boundary —
private stores whose desk metadata and eligible bytes ride the person's **private iCloud** to their
other devices, and **nothing sent to an AI or to a Conduck-operated server**: no transport of any
kind here, and no server of ours anywhere. It also states the one-board rule the collapse makes
structural (no operation takes a board id).

## 5. ui#5 — the Add-Note door. DECIDED: **the standalone note sheet is deleted.**

**The decision and its evidence, verified in code rather than from the finding's wording:**

1. **The pinned composer already yields a `.note` card.** `WorkboardCaptureCanvas.addThought()` →
   `WorkboardViewModel.addThought(_:)` → `addThoughtUnlocked` builds
   `WorkboardMaterialImport(kind: .note, name: WorkboardWorkspaceCaptureLogic.noteTitle(for: thought), textContent: thought)`
   and routes it through the ordinary import path. So the desk has a working note route on every
   surface that shows the composer — which is all of them.
2. **The sheet's note half had no door and could not be given one where the finding suggested.**
   `WorkboardMaterialActions` mounts `AttachmentMenu`, which offers library / camera / files / link
   and no note. `AttachmentMenu.swift` is Chat's component (`purpose:` distinguishes the mounts) and
   is **not mine**, so adding a note row there was out of scope by the brief's own instruction.
3. Therefore the sheet's note case was a **second door onto the same card**, reachable from nowhere,
   and the choice is delete-or-invent-a-second-route. Deleted.

**What went, exactly:** `WorkboardMaterialComposerKind` (whole enum — `.link`/`.note`) ·
`WorkboardMaterialActions.onAddNote` and the canvas closure that set `materialComposer = .note` ·
every `kind == .link ? … : …` branch in `WorkboardTextMaterialSheet` (it now composes one thing) ·
the canvas's `@State materialComposer` / `activeMaterialComposer` binding, replaced by
`showsLinkComposer` + `activeLinkComposerIsPresented` (the file's own `isPresented` + `.gated(by:)`
convention, as the voice sheet uses).

**What stayed:** the link route, unchanged in behaviour — same validation, same keys, same
`WorkboardMaterialImport`. The file and type keep their names (`WorkboardTextMaterialSheet`: a link
IS saved as text) and the header now states the constraint: the pinned composer is the desk's note
route, so this sheet offers no second one.

Six keys are now dead in source (§Catalog). Verified individually with the strings-audit method —
`grep` for the quoted literal across every `.swift`/`.plist`/`.strings`/`.stringsdict`/
`.intentdefinition`/`.json`/`.pbxproj`/`.storyboard`/`.xib`/`.h`/`.m` in the worktree minus `docs/`:
**0 files each**, catalog row only. `workboard.material.note` (the kind's noun, 3 refs),
`workboard.material.addLink` (3), `workboard.material.link.*`, `common.add`, `common.cancel` all stay
live — a naive "the note sheet died" sweep would kill some of them.

## 6. t#8 — the stale-result adoption tests, restored. **Counterfactual MEASURED.**

`WorkboardViewModel.adopt(_:)`'s `guard current.revision <= snapshot.revision` had no test left after
the purge. Three cases now hold it, in `WorkboardBoardProjectionTests` (one of the two homes my brief
names; it is the file about the board's derived surface, and its stub dependencies make the race
expressible without the live store):

| Case | Shape |
|---|---|
| `testARemovalResultOlderThanTheBoardIsDropped` | desk at revision 5; a removal SUSPENDS mid-flight (`MutationGate`); another device's card arrives and a `load()` takes the board to revision 9; the removal then answers with revision 6 → the board must still read revision 9 with both cards |
| `testAReorderResultOlderThanTheBoardIsDropped` | the same race on the drag lane, through the real optimistic-reorder path (the plan is applied locally first, so a wrongly-adopted late result reinstates an order the person no longer has) |
| `testAResultCarryingTheSameRevisionIsAdopted` | the separate equal-revision case the brief asks for: a removal answering at the board's own revision IS adopted, because both values describe one `updatedAt` and the operation's result is what it just wrote |

**How I know they would fail on the old code — MEASURED, not argued.** I replaced the guard with an
unconditional `desk = snapshot` in place, rebuilt (`** TEST BUILD SUCCEEDED **`, 0 errors) and ran
`WorkboardBoardProjectionTests` + `WorkboardMaterialBoardActionsTests`:
`Executed 16 tests, with 4 failures`, all four in the two stale cases, verbatim:

```
testARemovalResultOlderThanTheBoardIsDropped : XCTAssertEqual failed: ("Optional(6)") is not equal to ("Optional(9)") - a result built on an older desk never replaces a newer one
testARemovalResultOlderThanTheBoardIsDropped : XCTAssertEqual failed: ("Optional([])") is not equal to ("Optional(["Kept", "Arrived from another device"])") - adopting the late result would have thrown away the arriving card
testAReorderResultOlderThanTheBoardIsDropped : XCTAssertEqual failed: ("Optional(5)") is not equal to ("Optional(11)")
testAReorderResultOlderThanTheBoardIsDropped : XCTAssertEqual failed: ("Optional(["Second", "First"])") is not equal to ("Optional(["First", "Second", "Arrived from another device"])") - a late drag result never reinstates the board it was planned on
```

The equal-revision case and all 12 board-action cases passed on the reverted code, which is the
control: the two new cases fail *for the gate* and not because the harness is one-sided. The guard
was restored immediately, re-verified by reading it back, and every gate below was re-run after the
restore.

## Guard verdicts — `WorkboardDeskSurfaceDriftGuardTests`, all four KEPT as guards

The brief's verdict was "convert only those a small honest seam allows … the two that would need
SwiftUI view mounting stay as guards". I converted **none**, and here is the per-test reason. I would
rather say that plainly than manufacture a weaker behavioural test and delete a stronger guard.

| Test | Verdict | Why |
|---|---|---|
| `testTheDeskRendersTheFixedIdentityAndResolvesNoItem` | **KEEP** | Its subject is `WorkboardDetailView`'s `body` — a SwiftUI view with no test target to mount it (`AGENTS.md`: no UI-test target, by decision). Still true and now *stronger*: `item(withID:` cannot appear anywhere because the method no longer exists. |
| `testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer` | **KEEP** | Same file, same reason: what a `body` draws is not observable headlessly. |
| `testEveryWorkDeepLinkResolvesToTheDeskThroughTheRefreshCoordinator` | **KEEP** | The brief's suggested seam — "drive the deep-link router with **arbitrary payloads**" — no longer applies: `routeWorkboardDeepLink()` takes **no parameter** (the shell's `.onReceive` discards the notification), so payload-independence is a fact of the signature, not of discipline. What remains is two statements inside a `private func` on a `View` struct. Converting means moving the routing onto `PersonalWorkbenchModel` **and** injecting a store + inbox into `PersonalWorkbenchModel.init()`, because its real init builds `WorkboardLiveRepository(store: .shared)` — a live `NSPersistentCloudKitContainer` no unit test in this suite touches. That is a production API change to a file where my grant is call sites, in exchange for a flakier assertion than the guard's. Not a small honest seam. |
| `testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` | **KEEP** | It asserts an ABSENCE over a whole file (exactly one `workboardViewModel.load()` call site). A behavioural test can only show that one *particular* action loads once; it cannot show that no other path exists. The coordinator's own behaviour — visibility gate, serialization — is already covered behaviourally by `WorkCaptureRefreshCoordinatorTests` (6 cases, green), so the guard is holding the wiring, which is what a source guard is for. |

All four pass (`Executed 4 tests, with 0 failures`). `MacWorkbenchShellDriftGuardTests` — out of my
scope, untouched, and green in the full-suite run.

---

## Decisions

1. **`item(withID:)` deleted rather than kept as a convenience.** It existed to answer "is this id the
   desk?", which is the question the collapse deletes. Its two remaining callers now read `desk`.
2. **`hasComposerDraft` stored, not computed.** Deriving it from `composerDraft` would read the draft
   and invalidate its readers on every keystroke — the exact cost the old `Set<UUID>` avoided.
3. **`flushComposer()` deleted** (§2) — zero callers, and it was per-item composer state.
4. **The note sheet deleted rather than a note route added** (§5) — the composer is already the note
   route, and the alternative required editing Chat's shared `AttachmentMenu`.
5. **`WorkMaterialDragPayload.itemID` KEPT.** It looks like the same per-item vocabulary, but it is
   not view-model state: a drop payload is untrusted input from anywhere in the system, and
   `WorkboardCaptureCanvas.drop(_:at:)` compares it against `Constants.workboardDeskItemID` to prove
   the drag came from this desk. Removing it would remove a validity check, not a board id.
6. **No Codex consult.** Nothing here was a genuinely hard call; the two that looked like one (the
   Add-Note decision and the guard verdicts) were settled by reading the call paths and the seams.

## Deviations

- **`WorkboardWorkspaceCaptureTests.swift` is not on my owned-test list but I edited it** — it
  constructs `WorkboardViewModel.Dependencies` and calls five methods I collapsed, so the tree does
  not compile otherwise. Changes are mechanical (renames, dropped arguments) plus the one deletion
  argued in §2. Flagged rather than done quietly.
- **`WorkboardSurface` deleted against plan §B** (§3) — my brief authorises exactly this.
- **`workspaceStatus` keeps its name** (§Requests 2): it is not per-item state and its only readers
  outside the view model are three lines in `WorkboardView.swift`, which I do not own.
- **`WorkboardWorkspaceCaptureLogic` keeps its name.** It is pure capture logic (normalization, note
  titles) with no board identity in it, and renaming it would churn a file I do not own plus a test
  class name for no invariant.
- **`WorkboardLiveRepositorySupportTests` still calls `vault.store(_:suggestedExtension:)`** (the two
  callers fix2-store's §Requests 1 names). I own that test file but not `WorkAssetVault.swift`, and
  the request's point is to delete the vault method — half of it is not worth doing alone. §Requests 4.

## Gates — WHAT I ACTUALLY RAN

Slug `vm-collapse`. DerivedData under `~/Library/Caches/gigaduck-builds/vm-collapse/{DerivedData,
DerivedDataMac}`, every log written there and grepped for `': error: '` and the verdict strings —
never judged from tail or exit code. **No `-configuration` passed anywhere.** Sim
`2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`.

- **iOS `build-for-testing`** → `ios-bft-1.log` (first attempt, before the counterfactual) and
  `ios-bft-2.log` (final, after the guard was restored): `grep -c ': error: '` = **0** both times,
  `** TEST BUILD SUCCEEDED **` both times. **Zero warnings naming any of my ten files** on either
  platform (grepped by filename).
- **Targeted set**, `test-without-building`, one quoted `-only-testing:` flag per class →
  `ios-test-1.log`, `** TEST EXECUTE SUCCEEDED **`, `Executed 80 tests, with 0 failures (0 unexpected)
  in 0.793 (0.820) seconds`:

| Class | Result |
|---|---|
| `WorkboardBoardProjectionTests` | `Executed 4 tests, with 0 failures` (was 1) |
| `WorkboardDeskViewModelTests` | `Executed 5 tests, with 0 failures` |
| `WorkboardLiveRepositorySupportTests` | `Executed 5 tests, with 0 failures` |
| `WorkboardMaterialBoardActionsTests` | `Executed 12 tests, with 0 failures` |
| `WorkboardMaterialPresentationTests` | `Executed 4 tests, with 0 failures` |
| `WorkboardDeskSurfaceDriftGuardTests` | `Executed 4 tests, with 0 failures` |
| `WorkboardOpenPathTests` | `Executed 6 tests, with 0 failures` |
| `WorkboardWorkspaceCaptureTests` | `Executed 5 tests, with 0 failures` (was 6) |
| `WorkboardAudioCardTests` | `Executed 27 tests, with 0 failures` |
| `WorkboardChatCaptureTests` | `Executed 8 tests, with 0 failures` |

- **FULL iOS suite** (beyond my brief; run because renamed symbols can only be checked against
  source-text guards at runtime) → `ios-full-2.log`, `** TEST EXECUTE FAILED **`,
  `Executed 4871 tests, with 1 test skipped and 1 failure (0 unexpected) in 64.976 (66.377) seconds`.
  **The one failure is not mine**: `WorkCaptureInboxTests.swift:308:
  testShareWritersValidateAndRollbackBeforeAtomicPublication : XCTUnwrap failed` — the same
  pre-existing share-writer source guard fix2-store recorded, over the two `ShareViewController.swift`
  files, neither of which I touched. The skip is the environment-conditional
  `GatewayAdapterBriefTests` one. `ios-full-1.log` before it died with **no test case started**
  (`SBMainWorkspace … Busy ("Application failed preflight checks")`) — handled per the standing rule
  (`xcrun simctl shutdown all`, one retry via `test-without-building`), recorded rather than dropped.
- **Counterfactual** → `cf-bft.log` (0 errors, `** TEST BUILD SUCCEEDED **`) + `cf-test.log`
  (`Executed 16 tests, with 4 failures`), quoted in §6. Done by editing `adopt` in place and
  restoring it immediately; no tree copy was made and `git diff` of that function reads exactly as
  before (verified by reading the restored body back).
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log` (run after the restore): 0 `error:`,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 785 Swift files scanned…`, exit 0.
  `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories…`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short` for `*.xcstrings`, `*.pbxproj`,
  `Conduck/Configs`, `docs/qa` → **empty**.
- **NOT run, plainly:** the **watch suite**. No watch sim is assigned to me and none of my files
  reaches the watch target — the watch's membership-exception list from the `Conduck` folder names
  one `Views/` file (`Views/Conversation/MessageRowFormatters.swift`), `WorkboardLiveRepository.swift`
  is `#if !os(watchOS)`, and `WorkboardViewModel.swift` is app-target only. The iOS build compiled
  every target that could see my changes.
- **Build caches and every log removed** with `.claude/scripts/clean-build-cache.sh vm-collapse`
  (`removed: vm-collapse`), so the logs above no longer exist — re-run if you need them.

## Call-site touches

- `Views/Workboard/PersonalWorkbenchView.swift` — **two edits**: the `WorkboardLiveRepository(…)`
  construction site (three arguments → one) and the deletion of the router's two dead methods (which
  IS ui#7's fix, not a side effect). fix2-canvas's `present(_:)` policy gate, `previewFilename` and
  everything else in that file are untouched.
- `Views/Workboard/WorkboardCaptureCanvas.swift` — 20 call sites of the collapsed API plus the
  Add-Note wiring; fix2-canvas's `openMaterial` funnel through `WorkboardCardActionPolicy` and the
  audio card's `onOpen`/`onReattach` dispatch are untouched.
- `ConduckTests/WorkboardWorkspaceCaptureTests.swift` — outside my stated list; see §Deviations.

---

## Catalog

**Keys I ADDED in source: NONE.** I minted no user-facing copy; every string in my surviving code
already existed with its existing `defaultValue`.

**Keys I made DEAD (6)** — all from the standalone note composer (§5), all verified zero-reference
across the whole worktree minus `docs/` (catalog row only). Listed for the serial copy agent; **I
opened no `.xcstrings`**:

- `workboard.material.addNote` = `Add Note`
- `workboard.material.note.title` = `Standalone Note`
- `workboard.material.note.body` = `Note text`
- `workboard.material.note.name` = `Note title (optional)`
- `workboard.material.note.footer` = `Use a note when a thought should remain a separate, reusable material.`
- `workboard.material.note.defaultName` = `Note`

**Still referenced, do NOT delete on a stale scout row:** `workboard.material.note` (the kind's noun —
`WorkboardMaterialKind.note.title`, `WorkboardLiveRepository.materialName`, and a test) ·
`workboard.material.addLink` (2 × `AttachmentMenu`, 1 × the sheet's navigation title) ·
`workboard.material.link.{title,footer,name,url,url.label,invalid}` · `common.add` · `common.cancel` ·
every `workboard.workspace.*` key (the composer, the import report and the capture failure keep them —
only the METHOD names lost the word "workspace", never a key).

---

## Requests

1. **Whoever owns `ContentView.swift` + `MainWindowView.swift` — `.openPersonalAISettings` now has no
   poster.** Deleting `PersonalWorkbenchRouter.openGatewaySettings()` (ui#7's own fix) removed the
   only `NotificationCenter.default.post(name: .openPersonalAISettings…)` in the app. The name is
   still declared (`PersonalWorkbenchView.swift:314`, in a file I own only for call sites) and four
   observers still listen: `ContentView.swift:291` and `:675`, `PersonalWorkbenchView.swift:900`,
   `MainWindowView.swift:839`. I left all five alone deliberately — three of them are Chat-side files
   I do not own, and the route is one line from being live again if Settings ever wants it back.
   Either delete the name plus its four observers, or give it a poster.
2. **Whoever owns `WorkboardView.swift` — one rename finishes the vocabulary.**
   `WorkboardViewModel.workspaceStatus` is the last "workspace"-named member; it carries no board id,
   and its only readers outside the model are `WorkboardView.swift:96,112,113,115,117,119`. Rename to
   `transientStatus` (or `deskStatus`) in one edit; the model follows in one line.
3. **Nobody re-introduce a board id on this model.** `addThought`, `importMaterials`,
   `reattachMaterial`, both `reorderMaterial`s, `moveMaterial`, `setMaterialCardSize` and
   `removeMaterialFromBoard` take no board argument, and `item(withID:)` is gone. That is what makes
   "a capture aimed anywhere but the desk" unrepresentable rather than merely refused — the
   assertion that used to hold it is deleted (§2), so a re-added parameter would silently reopen it.
4. **Whoever owns `WorkAssetVault.swift` — fix2-store's §Requests 1 is still half-open.** The
   key-only `store(_ data:suggestedExtension:)` has exactly two callers left, both in
   `ConduckTests/WorkboardLiveRepositorySupportTests.swift:22-23` (a file I own). Change them to
   `store(bytes: …).key` in the same edit that deletes the vault method; I did not do half of it.
5. **Serial copy agent — six rows to sweep** (§Catalog). None of them renders anywhere today; all six
   are note-composer copy for a composer that no longer exists.
6. **Founder QA — three things a headless run cannot prove.** (a) The desk's paperclip menu offers
   photos / camera / files / **link** and no "Add Note"; typing in the composer and tapping the amber
   arrow must still produce a note card (that is now the only note route). (b) Adding a link still
   works end to end from that menu — same sheet, same validation, one field fewer. (c) The composer's
   arrow button must still enable/disable exactly as before as you type and clear whitespace (its
   emptiness test moved onto the view model).

## Refuted

**Nothing.** All five UI findings and the test-lens item held against the current tree when traced by
call path before any edit. The only qualification is ui#5's wording: the finding offers "delete the
sheet" as one option, and what I deleted is the sheet's NOTE half — the link half is reachable,
used, and untouched (§5).
