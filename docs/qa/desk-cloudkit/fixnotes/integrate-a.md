# integrate-a — phase-4 serial integration. DONE. Both platforms green, full iOS suite 4723 / 0 failures / 1 skip.

Serial phase, alone in the tree. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. Slug `desk-integrate-a` cleaned at the end.

**Headline: the ten parallel slices had already landed compatibly.** The tree was ALREADY green on both platforms and on all 23 targeted classes before I edited anything (`ios-bft-1.log`: `** TEST BUILD SUCCEEDED **`; `mac-build-1.log`: `** BUILD SUCCEEDED **`; `ios-test-1.log`: `Executed 180 tests, with 0 failures`). There was NO cross-slice compile breakage to fix. The `WorkboardView.swift` patch that capture-canvas §Requests 3 and chat-capture §Requests 1 both filed as BLOCKING had already been applied by desk-detail mid-wave (desk-detail §Call-site touches, edits 2 and 3). I verified that and did not re-apply it.

So my work was: the requests nobody could make in a parallel wave, the catalog, and one real regression the full suite exposed.

---

## 1. What changed (file + symbol)

| File | Change | Whose Request |
|---|---|---|
| `Conduck/Conduck/Views/Workboard/WorkboardView.swift` | `WorkboardDetailColumn.body`: the last two arms collapsed to a single `else { WorkboardDetailView(viewModel: viewModel) }`. Deleted `emptyDesk` and `captureBar` and the `.id(item.id)`. The loading and load-error guards now read `viewModel.desk == nil` instead of `viewModel.items.isEmpty`. | desk-detail §Requests 2 (+ desk-vm §Requests 2) |
| `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` | Deleted `WorkboardViewModel.items` and `.selectedItem` (zero app readers after the collapse). Deleted `WorkboardItemSnapshot.displayTitle` (zero readers anywhere). Rewrote the `WorkboardItemSnapshot` doc comment, which claimed `title`/`objective` "exist only for the surfaces that still ask a board what it is called" — no such surface exists. | desk-vm §Requests 2, desk-detail §Requests 1, views-core §Requests 1 |
| `Conduck/ConduckTests/WorkboardDeskViewModelTests.swift` | 5 call sites moved off the two deleted VM members. Detail in §3 — no assertion's meaning was lost. | consequence of the above |
| `Conduck/Conduck/Utilities/Constants.swift` | Doc comment on `workboardDeskItemID`: the sentence claiming the Watch mirrors the literal locally was false (`Constants.swift` is a Watch-target member). Replaced with desk-intents' suggested wording verbatim. No code change. | desk-intents §Requests 2 |
| `Conduck/Conduck/Localizable.xcstrings` | +4 keys, additive only (§Catalog). | capture-canvas §Requests 5, desk-detail §Catalog |
| `Conduck/ConduckTests/ConversationsModelMigrationTests.swift` | `testTheCurrentModelVersionIsV15` → `…IsV16`, asserted value `"Conversations 15"` → `"Conversations 16"`, its doc line v15 → v16, and `testEveryShippedModelVersionIsStillInTheBundle`'s loop `2...15` → `2...16`. | real regression, §4 |

Nothing else was edited. `WorkboardDetailView.swift`, `WorkboardCaptureCanvas.swift`, `WorkboardComponents.swift`, `ConversationStore+Workboard.swift`, `WorkboardLiveRepository.swift`, `MainWindowView.swift`, `ConduckApp.swift`, both intents, the watch target, the mirrors and the three non-main catalogs were left exactly as the parallel wave left them.

## 2. Decisions on the Requests I did NOT apply (each with its reason)

These are all real and all still owed — they are listed again in §Requests so the next agent inherits them, not lost.

1. **`createWorkItemWithInitialMaterial` + `WorkMaterialOwnerPolicy.createNew` + the 3 `ConversationStoreAtomicWorkCaptureTests` cases** (desk-upsert §Requests 1, desk-vm §Requests 4). I VERIFIED the precondition is met: `WorkboardLiveRepository.importMaterial` now ends in `store.upsertDeskMaterial`, and `createWorkItemWithInitialMaterial` has exactly one declaration and three test callers, no production caller. **Deferred deliberately.** Removing `.createNew` is not a function deletion — it deletes a branch from inside `publishWorkMaterial`, the ONE write path every desk capture now takes (owner resolution, the identifier-collision guards, `createdOwner`), and it deletes a whole test class. Re-cutting that path at the integration gate, on the strength of a test-deletion I would also have to authorise, is exactly the "re-architect" my brief forbids and it is phase-5's kind of work. The plan (§A) requires the *routing* to be subsumed, which it is; it does not require the corpse gone this wave.
2. **`addWorkMaterial` / `addWorkMaterialFile` / `insertWorkMaterial` / `createWorkItem` retirement** (desk-upsert §Requests 2, chat-capture §Requests 2, desk-vm §Requests 4). Confirmed zero app callers. **Kept as test-only owner mints.** chat-capture's own note is the reason: `WorkboardPersistenceTests` (7), `WorkAssetVaultTests` (6), `WorkCaptureDrainerTests`, `WorkboardDeskUpsertTests`, `WorkCaptureInboxTests` and `WorkboardDeskViewModelTests` build boards with them, and several deliberately need a NON-desk owner (`invalidMaterialOwner`, the legacy-project-row cases) that `upsertDeskMaterial` cannot mint. chat-capture explicitly offers "keep `createWorkItem` as the test-only owner mint and say so at the declaration" — I did not even add that doc line, because it belongs with whoever decides, not with me.
3. **`WorkboardSurface` (zero consumers) and `WorkboardMaterialActions.Presentation.row` + `rowRoutes` + `action(for:)` + `label(for:)` + `WorkboardMaterialRoute`** (capture-canvas §Requests 1). Both verified dead: `WorkboardSurface` appears only at its own declaration; `WorkboardMaterialActions` has ONE call site, `WorkboardCaptureCanvas.attachmentMenu`, `presentation: .menu`. **Deferred.** Plan §B names `WorkboardSurface` as "the desk container" — an explicit KEEP — while the desk that shipped deliberately draws no container; that is a founder-visible design question (adopt it, or accept a bare pane), not an integration call, and the plan beats my judgement. Deleting `WorkboardMaterialRoute` would silently retire ~6 more `workboard.material.add*` keys, which is the strings phase's audit to make, not mine to pre-empt. **The strings phase MUST NOT treat those keys as live**: they are referenced only from unreachable code (§Requests 2).
4. **`WorkboardMetrics.cardCornerRadius`** (views-core §Requests 5) — still unread; capture-canvas did not claim it. One line, deferred with the same WorkboardComponents sweep so the file is opened once.
5. **`WorkboardItemSnapshot.title` / `.objective`** (desk-detail §Requests 1). NOT deleted, unlike `displayTitle`. They have live readers — `WorkboardDeskViewModelTests:87` and `WorkboardWorkspaceCaptureTests:114` assert `desk.objective == ""`, which IS plan §A's "title/objective nil forever" invariant. Deleting the fields deletes that invariant's only expression. I retargeted the doc comment to say so instead. (views-core §Requests 1's other five — `state`, `isPinned`, `boardOrder`, `reviewBy`, `wasCapturedExternally` — were ALREADY gone when I arrived; `isPinned`/`boardOrder` grep hits that remain are `WorkItemContent`/`WorkItemRecord` in the store layer, a different type.)
6. **Every copy rewrite** — mac-shell §Requests 1 (`Button("Workboard")` → `Button("Work")` at `ConduckApp.swift:339`), views-core §Requests 4 / desk-detail §Requests 4 (`workboard.load.failed.message` still says "projects"), capture-canvas §Requests 4 (`workboard.material.link.footer`'s dead gateway sentence; the `workboard.workspace.*` family name), desk-intents §Requests 1 (`intent.workboardCapture.{description,confirmation}` + `workboard.item.untitled` = "Untitled brief", which must move in source AND catalog in one step, in BOTH intent files). **All deferred to the strings/copy phase**, which owns source+catalog lockstep. My brief scopes me to the ADDED keys.
7. **`ConversationThreadView` "Open Work" payload** (desk-detail §Requests 3, chat-capture §Requests 4) — the `workItemIDKey` the route now ignores. Both authors say nothing breaks. Deferred; it is cosmetic and `WorkboardDeskSurfaceDriftGuardTests` already forbids the route from reading it.
8. **`WorkItemRecord.boardOrder` / `.completedAt` projected-but-unread** (desk-vm §Requests 4) — needs `StoredWorkItem` + `WorkboardRecords.swift` in one edit; store-layer cleanup, no integration value, deferred.
9. **ByteSync-addressed requests** (desk-drainer §1, desk-upsert §3, desk-vm §5, capture-canvas §7, test-compile §4) — not mine; byte sync has not landed. Left verbatim for that agent.
10. **inbox-lease's three requests** need no action by design (drainer already acknowledges last; no fourth mirror; `respectedLeaseCount` is defaulted). Confirmed, nothing done.

**No two requests actually conflicted.** The nearest thing was capture-canvas §1 ("`WorkboardSurface` must die or be adopted") against plan §B ("`WorkboardSurface` = desk container"); the plan decided, and the decision is "keep, unresolved, flagged" (§2.3).

## 3. The five test-site rewrites, verbatim (no assertion weakened)

`WorkboardDeskViewModelTests.swift`, forced by deleting `items`/`selectedItem`:

| Was | Now | Why nothing is lost |
|---|---|---|
| `XCTAssertTrue(viewModel.items.isEmpty)` | *(line removed)* | The line above it is `XCTAssertNil(viewModel.desk, "the desk row does not exist yet, and a project is not one")`. `items` was `desk.map { [$0] } ?? []`, so the two assertions were the same fact twice. |
| `XCTAssertEqual(viewModel.items.map(\.id), [Constants.workboardDeskItemID])` | *(line removed)* | The line above it is `XCTAssertEqual(viewModel.desk?.id, Constants.workboardDeskItemID)` — same fact. |
| `XCTAssertNil(viewModel.selectedItem, "an empty desk is the capture canvas, not a board with nothing on it")` | `XCTAssertTrue(viewModel.desk?.materials.isEmpty == true, "an empty desk is the capture canvas, not a board with nothing on it")` | `selectedItem` was `desk` gated on non-empty materials; the message is carried over unchanged. The behaviour it named now lives in `WorkboardDetailView`'s empty arm, which `WorkboardDeskSurfaceDriftGuardTests.testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer` guards. |
| `XCTAssertEqual(viewModel.items.count, 1, "duplicate physical rows project as one logical desk")` | `XCTAssertEqual(desk.id, Constants.workboardDeskItemID, "duplicate physical rows project as one logical desk")` | `desk` is a single Optional, so "count 1" could not fail independently; the merge's real content is the materials union asserted three lines below, untouched. |
| `XCTAssertEqual(viewModel.items.count, 1)` | `XCTAssertEqual(viewModel.desk?.id, Constants.workboardDeskItemID)` | same. |

The class still runs **5 tests, 0 failures**.

## 4. The one real regression, and its fix

The **targeted** classes were green throughout, so I ran the FULL iOS suite as well. It found one failure, which no targeted class covers:

```
ConversationsModelMigrationTests.swift:1674: error: -[ConduckTests.ConversationsModelMigrationTests testTheCurrentModelVersionIsV15] :
XCTAssertEqual failed: ("Optional("Conversations 16")") is not equal to ("Optional("Conversations 15")")
```

Cause: **the foundation slice's model 16 (commit `136e088`) landed without updating the guard that pins the app's current model version.** Classification: **(b) a real regression I fixed.** The fix is faithful, not a weakening — the test's whole purpose is "the app opens the CURRENT model", and plan §C makes that model 16. I also extended `testEveryShippedModelVersionIsStillInTheBundle`'s loop from `2...15` to `2...16`, so version 16 is now covered by the never-drop-a-shipped-model guard too (it was passing only because it never looked at 16). No other assertion in that file was touched.

**Nothing was classified (a) or (c): no expected-failure was pending, and there is no unfixed regression.**

## 5. Numbers — exactly what I ran

Slug `~/Library/Caches/gigaduck-builds/desk-integrate-a/`, every log kept there until the clean-up.

**Builds (final state, after every edit):**
- iOS `build-for-testing`, sim `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC` → `** TEST BUILD SUCCEEDED **` (`ios-bft-3.log`), 0 `error:` lines.
- macOS `build`, `-destination 'platform=macOS'`, signed through the identity override, no `CODE_SIGNING_ALLOWED=NO` needed → `** BUILD SUCCEEDED **` (`mac-build-3.log`), 0 `error:` lines.

**Full iOS suite** (`ios-full-2.log`, `test-without-building`): `** TEST EXECUTE SUCCEEDED **`
```
Executed 4723 tests, with 1 test skipped and 0 failures (0 unexpected) in 62.409 (63.892) seconds
```
The pre-fix run (`ios-full-1.log`) was `Executed 4723 tests, with 1 test skipped and 1 failure`.

**Skip count is 1, not the plan's 2 — explained, not a loss.** The missing skip lived in `WorkBriefAssistantTests.swift`, which purge-core deleted whole (`git show 651a859:…/WorkBriefAssistantTests.swift | grep -c XCTSkip` = 1; every other deleted test file = 0). The surviving skip is `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`.

**Targeted classes** (`ios-test-4.log`, `** TEST EXECUTE SUCCEEDED **`, `Executed 180 tests, with 0 failures (0 unexpected)`), per class:

| Class | Result | Class | Result |
|---|---|---|---|
| ConversationStoreAtomicWorkCaptureTests | Executed 3, 0 failures | WorkboardBoardProjectionTests | Executed 1, 0 failures |
| ConversationStoreWorkCaptureTests | Executed 5, 0 failures | WorkboardChatCaptureTests | Executed 5, 0 failures |
| ErrorSurfaceDriftGuardTests | Executed 7, 0 failures | WorkboardDeskIdentityDriftTests | Executed 2, 0 failures |
| MacWorkbenchShellDriftGuardTests | Executed 4, 0 failures | WorkboardDeskSurfaceDriftGuardTests | Executed 4, 0 failures |
| WorkAssetVaultTests | Executed 9, 0 failures | WorkboardDeskUpsertTests | Executed 10, 0 failures |
| WorkCaptureDrainerTests | Executed 9, 0 failures | WorkboardDeskViewModelTests | Executed 5, 0 failures |
| WorkCaptureInboxLeaseTests | Executed 9, 0 failures | WorkboardLiveRepositorySupportTests | Executed 3, 0 failures |
| WorkCaptureInboxTests | Executed 30, 0 failures | WorkboardMaterialBoardActionsTests | Executed 12, 0 failures |
| WorkCaptureRefreshCoordinatorTests | Executed 6, 0 failures | WorkboardMaterialPresentationTests | Executed 4, 0 failures |
| WorkMaterialStoragePolicyTests | Executed 7, 0 failures | WorkboardModelMigrationTests | Executed 6, 0 failures |
| WorkboardMosaicEngineTests | Executed 26, 0 failures | WorkboardPersistenceTests | Executed 7, 0 failures |
| WorkboardWorkspaceCaptureTests | Executed 6, 0 failures | | |

There is no `WorkCaptureDrainerDeskTests` class — desk-drainer put its 4 new cases inside `WorkCaptureDrainerTests` (5 → 9, as it predicted). There is no toolbar/MainWindow class beyond `MacWorkbenchShellDriftGuardTests` (the only ConduckTests file containing "Toolbar").

**One infrastructure flake, reported for honesty:** the first attempt at the final targeted run died with `Simulator device failed to launch ai.gigaduck.AgentRelay … "Application failed preflight checks"` (`ios-test-3.log`, `** TEST EXECUTE FAILED **`) immediately after the full-suite run. `xcrun simctl shutdown all` + one retry gave the clean `ios-test-4.log` above. No test case ever started in the failed attempt; nothing was masked.

**Watch suite: NOT RUN.** No watch simulator was assigned to me and my brief names only the iOS sim. `ConduckWatchSmokeTests.swift` is modified (desk-intents, +2 Workboard cases) and the watch target compiles inside the macOS/iOS scheme builds, but the watch suite itself is unverified by me — it stays an orchestrator gate item.

## 6. Gates

- `scripts/check-storage-seam.sh` → `✓ storage seam intact — 767 Swift files scanned`, exit 0.
- `git diff --check` → clean, exit 0.
- All four catalogs `json.load` clean: main 2402 keys · ConduckShareExtension 47 · ConduckShareExtensionMac 46 · Watch 299. A source-vs-catalog sweep of each target's own Swift files reports **0 missing keys** in all four.
- **Mirror triplets: unchanged and correct.** No mirror file is modified (`git status` on `*WorkCaptureEnvelope.swift` / `*ShareTargetsSnapshot.swift` is empty). Their SHAs differ across the three copies, but that is the standing convention, not drift — each copy carries its own target-specific header and the contract is "byte-identical from `import Foundation` onward", which `WorkCaptureInboxTests` (30/30 green) guards.
- `git status --short`: **everything is inside the expected surface.** Full list is Workboard/Work* sources and tests, the six new test files, `Localizable.xcstrings`, `scripts/check-storage-seam.sh`, `AppShortcuts.swift`, `ConduckApp.swift`, `AppDelegate.swift`, `ConversationThreadView.swift`, `MainWindowView.swift`, `PersonalWorkbenchView.swift`, `ConversationStore+Workboard.swift`, `ShareTargetsSnapshotWriter.swift`, the watch intent + `ConduckWatchSmokeTests.swift`. **Two entries worth naming because your list does not:** `Conduck/Conduck/Utilities/Constants.swift` (my doc-comment-only edit — it holds `workboardDeskItemID`) and `Conduck/ConduckTests/ConversationsModelMigrationTests.swift` (§4). Neither is a surprise, both are mine.

## Catalog

**Keys I ADDED to `Conduck/Conduck/Localizable.xcstrings` (4)** — exactly the ADDED sets from capture-canvas §Catalog (3) and desk-detail §Catalog (1), copied from the `defaultValue:` the SOURCE declares, verified string-for-string against the source after insertion:

| Key | en value | Declared in |
|---|---|---|
| `workboard.workspace.composer.prompt` | `Add to Work…` | `WorkboardCaptureCanvas.swift`, `WorkboardCaptureDestination.composerPrompt` |
| `workboard.workspace.drop.overlay.title` | `Drop into Work` | `WorkboardCaptureCanvas.swift`, `…dropTitle` |
| `workboard.workspace.drop.overlay.caption` | `Files, photos, screenshots, links and text will be added here. Nothing is sent.` | `WorkboardCaptureCanvas.swift`, `…dropCaption` |
| `workboard.desk.empty.message` | `Whatever you collect lands here as a card you can move and resize.` | `WorkboardDetailView.swift`, the empty arm |

Method: raw-text insertion, NOT `json.dump` — the file is Xcode-formatted (`"key" : {`, 2-space indent, family-local alphabetical order) and a re-dump would rewrite all 22k lines. Each entry copies a neighbour's shape exactly (`extractionState: extracted_with_value`, one `en` `stringUnit`, `state: new`) and was placed at its alphabetical position in the `workboard.*` block. `git diff --stat` on the catalog: **44 insertions, 0 deletions.** Re-validated with `python3 json.load` (2402 keys).

An independent sweep confirms these were the ONLY four: extracting every `String(localized:"…")` / `LocalizedStringResource("…")` key from `Conduck/Conduck/**.swift` (1742 keys) and differencing against the catalog returned exactly these four before the edit and **zero** after.

**Keys I found DEAD because of my own edits (1):** none newly, but one reference COUNT dropped — deleting `WorkboardItemSnapshot.displayTitle` removed one of the three `workboard.item.untitled` references. The key **stays alive**: `Intents/CaptureWorkboardIntent.swift` and `ConduckWatch Watch App/WorkboardCaptureIntent.swift` still reach it. Its default value is still the false `"Untitled brief"` (see §2.6).

**I DELETED NO KEY.** Per my brief, the bidirectional audit is the strings phase's. The dead-key lists from purge-core (124), views-core (27), capture-canvas (6), chat-capture (3), desk-drainer (2) and desk-detail (2) are all still in the catalog, untouched.

---

## Requests

1. **Strings/copy phase — the ADDED keys are in, the DEAD ones are all still there.** Your bidirectional audit runs against a catalog of 2402 keys of which ~164 are candidates from six fixnotes. Re-verify each; several lists were written before later slices moved things.
2. **Strings phase — DO NOT trust a live-reference signal for these.** `workboard.material.add*` (the `WorkboardMaterialRoute` titles) and the keys inside `WorkboardMaterialActions`'s `.row` arm ARE referenced in source, but only from code that nothing reaches: `WorkboardMaterialActions` has exactly one call site and it passes `presentation: .menu`. They are dead in behaviour and live in grep. Resolve them together with §Requests 3, not separately. Same trap in reverse: `Add ${thought} to Work` is macro-composed and has zero grep hits BY DESIGN — never delete it.
3. **Whoever opens `WorkboardComponents.swift` next (view/cleanup phase) — one sweep, four items, all verified dead by me:** `WorkboardSurface` (zero consumers; plan §B calls it the desk container but the shipped desk draws no container — **this needs a founder-visible decision: adopt it or delete it**), `WorkboardMaterialActions.Presentation.row` + `rowRoutes` + `action(for:)` + `label(for:)`, `WorkboardMaterialRoute` (only those read it), `WorkboardMetrics.cardCornerRadius`. If `.row` goes, `Presentation` collapses to one case and the parameter should go with it.
4. **Store owner / phase-5 test surgery — the two store cleanups are unblocked and precisely scoped (§2.1, §2.2).** (a) `createWorkItemWithInitialMaterial` + `WorkMaterialOwnerPolicy.createNew` + its branch inside `publishWorkMaterial` + the 3 `ConversationStoreAtomicWorkCaptureTests` cases — production-dead, verified. (b) `addWorkMaterial` / `addWorkMaterialFile` / `insertWorkMaterial` / `createWorkItem` — production-dead but load-bearing for ~20 test fixtures, several of which NEED a non-desk owner. Decide (b) explicitly: retire and rewrite the fixtures, or keep and say so at the declaration. Do not half-do it.
5. **Docs agent — `spec.md` now has a THIRD false statement beyond plan §E's two.** The model version: the app opens `Conversations 16`, and `ConversationsModelMigrationTests.testTheCurrentModelVersionIsV16` is the guard that says so. Check for a spec/doc line still pinning v15.
6. **Orchestrator — the release-gate ledger.** Plan §G item 1 (deploy model 16 to CloudKit Production) is now load-bearing in the test suite, not just the plan: `testTheCurrentModelVersionIsV16` will fail loudly if anyone points the app back at 15 to dodge that deployment.
7. **Orchestrator — watch suite unrun by me (§5).** `ConduckWatchSmokeTests` gained 2 cases (desk-intents) and should be 231, but I could not verify it: no watch sim was assigned. Run it serially on `28AC563B-42C1-4E66-940D-77E63B07918B` before the gate.
8. **Orchestrator — the plan's skip count needs correcting to 1, not 2** (§5), and the iOS baseline is now **4723 executed** (plan §F predicted ~4664 before the new classes).
9. **Nobody re-add `WorkboardViewModel.items` or `.selectedItem`.** They existed only to feed three lines in `WorkboardView.swift` that no longer exist. A view that wants "is there anything on the desk" reads `viewModel.desk` (nil = no row yet) and `desk.materials.isEmpty` (row, no cards) — which is exactly what `WorkboardDetailView` does, and what `WorkboardDeskSurfaceDriftGuardTests` guards.
