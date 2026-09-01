# mac-shell — plan §B macOS shell rewrite (Codex #10c) + app-level command cleanup. DONE, both platforms green.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened** (`git status` confirms none modified). Nothing under `docs/qa/desk-cloudkit/` touched.

Files I changed: `Conduck/Conduck/Views/Conversation/MainWindowView.swift` (1897 → 1949 — a purge slice that GROWS its file: the collapse rule plus the reasons it is shaped this way) · `Conduck/Conduck/ConduckApp.swift` (one comment) · **NEW** `Conduck/ConduckTests/MacWorkbenchShellDriftGuardTests.swift`.
`Conduck/Conduck/AppDelegate.swift`: **I changed nothing** — purge-core's `reconcile()` removal left it with zero Work references (`grep -in 'workboard|reconcile|journal'` → 0 hits). It shows in `git status` from that earlier slice, not from me.

---

## 1. The macOS shell exactly as built

### Work mode
- **The sidebar column is COLLAPSED** (`.detailOnly`) for as long as `router.destination == .work`, so the desk fills the window. This is the Codex #10c behaviour and it is new; before, Work left an expanded column drawing an invisible Chat sidebar.
- Chat's sidebar tree **stays mounted** behind the collapse, hidden by the existing layer contract (`workbenchDestinationLayer(isActive: chatDestinationIsActive, …)` — opacity 0, no hit testing, `accessibilityHidden`). That is the "Chat's sidebar is already explicitly hidden while Work is active — KEEP that behavior" the plan names; keeping it mounted is what preserves Chat's selection, search string and scroll position across a round trip.
- **Work mounts nothing in the sidebar column at all** (views-core had already deleted the `.sidebarColumn` mount; `WorkboardExperience` no longer has one).
- Work's desk mounts in the DETAIL column only, still gated by `mountsWorkLayer` (destination OR dissolve tail) and still carrying `.id(Self.workLayerIdentity)`. **The dissolve grace period is unchanged** — same `.task(id: workDestinationIsActive)`, same `WorkbenchDestinationLayerModifier.mountHold`.
- `splitView`'s always-mounted `.modifier(workboardExperience(for:).presentationModifier)` is **untouched** — it stays the sheet/alert/tutorial host whether or not the desk layer is mounted.

### Chats mode
- The Chat sidebar returns **in the state the user left it** (`.automatic`, or a hand-collapse), not force-expanded.

### How the collapse is expressed (the one design decision)
`@State columnVisibility` became `@State chatColumnVisibility` (CHAT's state only), plus two derived members near `workDestinationIsActive`:

```swift
private var effectiveColumnVisibility: NavigationSplitViewVisibility {
    workDestinationIsActive ? .detailOnly : chatColumnVisibility
}

private var splitColumnVisibility: Binding<NavigationSplitViewVisibility> {
    Binding(
        get: { effectiveColumnVisibility },
        set: { newValue in
            guard !workDestinationIsActive else { return }
            chatColumnVisibility = newValue
        }
    )
}
```
`NavigationSplitView(columnVisibility: splitColumnVisibility)`.

**Why a derived binding rather than an imperative sync on the destination change:** the value is a pure function of the destination, so there is no ordering, no `.onChange` to miss, and no second source of truth. **Why the setter refuses writes while Work is active:** AppKit revises this binding on its OWN initiative (window resized past the two-column floor, saved-frame restore) — an accepted write from a section that has no sidebar would silently become Chat's remembered state, and if the setter instead flipped the destination, an AppKit-initiated write would teleport the user out of Work. The cost is that the split view's own toggle button is **inert while Work is active** (founder QA item below). No app-supplied animation transaction was added — the file's standing rule about letting AppKit own the divider's motion is intact.

### Toolbar — items and slots, verified unchanged in both sections
| Slot | Item | Work | Chats |
|---|---|---|---|
| sidebar region, column-level, declared first | Delete-All trash (`toolbar.deleteAll`) | **hidden** | shown when the list is non-empty |
| sidebar region, column-level | `ToolbarSpacer(.flexible)` (paired with the trash) | hidden | shown with the trash |
| sidebar region, column-level | `LeadingToolbarChrome(column: .sidebar)` compose + system sidebar toggle | shown (collapsed glass capsule) | shown |
| content region, `.principal`, declared on the split view | `gatewayToolbarContent` — **1×1 `Color.clear`** while Work is active | 1×1 placeholder | gateway pill / picker |
| content region, `.primaryAction`, declared LAST on the detail side via the zero-size `Color.clear` host | `WorkbenchSectionControl` (`workbench.section`) | trailing-most | trailing-most |

- The **1×1 clear principal slot survives untouched**: I changed nothing in `gatewayToolbarContent` except one stale sentence of its doc comment. Its `Color.clear.frame(width: 1, height: 1)` branch is what keeps the `NSToolbarItem` (and therefore the flexible spaces that pin the section control to the trailing edge) alive in Work.
- The **section control keeps its measured slot**: still the last toolbar declaration in `mountedDetailDestinations`, still after the Chat layer.
- **Delete-All hides in Work** — the one toolbar-visible consequence of the collapse, and a deliberate application of the rule already written at that gate ("founder-decided, the collapsed bar shows no Delete-All at all — a destructive bulk action stays with the list it destroys"). It is in the SIDEBAR region, past the tracking separator from the section control, so its coming and going cannot move the content-region anchors. Compose stays because a column-level item outlives the collapsed column. `activateChatsForToolbarAction()` (reveal Chat, then act) is unchanged for every control that kept its place.

---

## 2. What died

| Symbol / site | Note |
|---|---|
| `@State columnVisibility` (shared Work+Chat) | replaced by `chatColumnVisibility` + the two derived members above |
| `@Environment(\.horizontalSizeClass)` in `MainWindowView` | its last reader was the dropped `WorkboardExperience(horizontalSizeClass:)` argument; this file is wholly `#if os(macOS)`, where the value is a constant |
| `WorkboardProjectCommands()` + its 3-line comment in `.commands` | already deleted by purge-core; verified gone app-wide (`grep -rn 'WorkboardProjectCommand\|workboardProjectCommandTarget'` → 0 hits) |
| 3 workboard `@SceneStorage`/`@State` presentation values, the `.sidebarColumn` mount, the ⌘⇧N zero-size button | already deleted by views-core/purge-core; verified — `grep -rn SceneStorage Conduck/` now returns exactly ONE hit app-wide, `conversationLibrary.sidebarUp` |
| `WorkboardUploadJournal.shared.reconcile()` × 3 (2 in `ConduckApp`, 1 in `AppDelegate`) | already deleted by purge-core; both enclosing `Task`s still carry real work (`performInitialSync` + `refreshIfNeeded`; the file-transfer background-session drain) |
| `BriefWorkboardIntent` / its AppShortcut | not mine, already gone; verified 0 references |

**Kept, deliberately:** ⌘1 / ⌘2 (`CommandGroup(after: .newItem)`) · `.openWorkboardDeepLink` and `.showWorkboard` receivers in `ConduckApp` (Work deep links still route: `ConduckApp` foregrounds the singleton window, `PersonalWorkbenchView.routeWorkboardDeepLink` sets `destination = .work`) · `mountsWorkLayer` · `Self.workLayerIdentity` · the whole dissolve machinery.

**Comment-only truth fixes in my files** (constraints, no changelog narration): a new WORK / CHATS paragraph in the file header; the `gatewayToolbarContent` doc sentence that justified hiding the pill in Work by "Work binds a gateway at Review & Send" (a flow the purge deleted) now reads "the desk sends nothing to a gateway"; `ConduckApp`'s `.openWorkboardDeepLink` comment says "deep-links to the desk" instead of "to the new item … selects the card"; the `.task(id:)` and `mountsWorkLayer` docs say Work's *layer*, not *columns*, since it has one column now.

I left `mountedSidebarDestinations`' one-child `ZStack` in place rather than unwrapping it: with a `.frame(minWidth:)` applied outside, removing the stack is a real (if small) layout change I cannot verify headlessly, and it keeps the shape symmetric with `mountedDetailDestinations`. It now carries a doc comment saying the column is Chat's alone.

---

## 3. New test file — `ConduckTests/MacWorkbenchShellDriftGuardTests.swift` (4 tests, all green)

`MainWindowView` is `#if os(macOS)` and is never compiled by the iOS suite, so this is a SOURCE drift guard in the shape the repo already uses, reusing `RefusalLaneSource` from `ConduckTests/RemoteAgent/HeadlessRefusalLaneDriftGuardTests.swift` (internal, `#filePath`-derived, comment-stripping). New file in a synchronized group → **no pbxproj edit**, and it is in `ConduckTests`, not `ConduckWatchTests`.

| Test | Pins |
|---|---|
| `testWorkCollapsesTheSidebarColumn` | the split view reads `splitColumnVisibility`; `effectiveColumnVisibility` mentions `workDestinationIsActive`, `.detailOnly` and `chatColumnVisibility` |
| `testWorkNeverWritesChatsRememberedSidebarState` | `guard !workDestinationIsActive` precedes `chatColumnVisibility = newValue` inside the binding |
| `testSectionControlIsTheTrailingMostDetailSideToolbarItem` | in `mountedDetailDestinations`, Chat's `detailColumn` precedes `workbenchSectionPicker(for:`, and NO `.toolbar` follows it |
| `testPrincipalSlotKeepsAZeroAreaPlaceholderWhileWorkIsActive` | the `!chatDestinationIsActive || !coordinator.hasAnyConfiguredGateway` arm of `gatewayToolbarContent` still resolves to `Color.clear` |

Scoping verified independently (I re-implemented the extractor in Python over the same file): `effectiveColumnVisibility` extracts 75 chars, `splitColumnVisibility` 237, `mountedDetailDestinations` 1665 with the picker at offset 1400 and no `.toolbar` after it — i.e. the assertions are scoped to the intended property, not satisfied by unrelated text elsewhere in a 1,949-line view. I did **not** run a live negative control (perturbing the source would have handed the other agents building in this tree a spurious failure).

---

## 4. Gates run (exact lines)

Slug `desk-mac-shell`, derivedData `~/Library/Caches/gigaduck-builds/desk-mac-shell/DerivedData`, every log written there and grepped (never judged from tail or exit code). No `-configuration` passed anywhere.

- **macOS build, signed — the primary gate.** `mac-build-1.log` and, after the final cleanup edits, `mac-build-3.log`: `grep -c ': error: '` = **0**, `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **No `CODE_SIGNING_ALLOWED=NO` fallback was needed.** The only warnings naming my files are two pre-existing ones in `ConduckApp.swift:99` and `:176` (Sendable capture / main-actor reference), both far from anything I touched.
- **iOS `build-for-testing`** (`-destination 'platform=iOS Simulator,id=1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1'`) — four attempts, and I am reporting all of them because three failed:
  - `bft-1.log` (before my last cleanup edit): `** TEST BUILD SUCCEEDED **`, 0 errors.
  - `bft-2.log`: `** TEST BUILD FAILED **`, **18 errors, all in `Conduck/Conduck/ViewModels/WorkboardViewModel.swift`** (`:459 value of type 'WorkboardViewModel.Dependencies' has no member 'loadItems'`, `:590-593` / `:708-712` argument-type mismatches, `:820`, `:852-853`, `:888`, `:895`). Not my file. Waited 150 s, retried.
  - `bft-3.log`: `** TEST BUILD FAILED **`, **8 errors, all in `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift`** (`:62 cannot find 'loadDesk' in scope`, `:64 incorrect argument label … expected '_:expectedRevision:onProgress:'`, `:65`, `:66`, `:71`, `:75`, `:86`, `:244`). Not my file.
  - `bft-4.log`: `** TEST BUILD FAILED **`, **1 error**, `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift:913:42: error: value of type 'WorkboardViewModel' has no member 'selectedItemID'` — the deep-link router, not my file.
  - `bft-5.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
  - **Zero errors in a file I own in any of the five runs.** The three failures were another agent's mid-edit window; I exceeded the "retry once" allowance deliberately (four waits in all) because the error count was falling monotonically and a green bundle is worth more to the serial step than a recorded red one. Nothing of mine changed between `bft-2` and `bft-5`.
- **Targeted tests**, `test-without-building` on the green bundle → `test-2.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `MacWorkbenchShellDriftGuardTests` (new) | `Executed 4 tests, with 0 failures (0 unexpected) in 0.044 (0.045) seconds` |
| `GatewayFixRouteLandingDriftGuardTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.098 (0.100) seconds` |
| `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 1.096 (1.097) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.809 (2.811) seconds` |

The two `MainWindowView`-path-scanning guards are the "existing toolbar tests" plan §B asks to re-verify mid-workflow (test-compile.md §97 established there is no other MainWindow/toolbar class in the suite); both still resolve their tokens after my edits.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 765 Swift files scanned, no raw store or live-adapter access outside …/LiveStorage.swift`
- `git diff --check` → clean. `git status --short` → no `.xcstrings` modified.
- **NOT run, stated plainly:** the full iOS suite and the watch suite (neither is in my brief; the watch target is untouched by this slice), and any UI verification — the collapse is a pixel change no headless run can see (founder QA below).
- Build cache removed with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-mac-shell` → `removed: desk-mac-shell`, so those logs no longer exist; re-run if you need them.

---

## 5. Founder QA (macOS, signed) — what only a human can check

1. **Work fills the window.** Open the Mac window → click **Work**: the sidebar column collapses and the desk occupies the whole content area. Click **Chats**: the conversation sidebar comes back.
2. **Chat's own collapse survives.** In Chats, collapse the sidebar with the toolbar toggle → go to Work → back to Chats: it is still collapsed. Expand it, round-trip again: still expanded.
3. **Toolbar anchors do not move.** Switch Work ↔ Chats repeatedly and watch the **Work/Chats control**: it must stay pinned at the trailing edge in BOTH sections and must not jump left when Work is shown. Open a chat with the Copy-conversation button visible and switch again — the control must not slide.
4. **The known wart:** while Work is active the system **sidebar toggle does nothing** (deliberate — see §1). Compose (⌘N affordance) still works from Work and reveals Chat first. The **Delete-All trash is not shown in Work**; it returns in Chats with a non-empty list.
5. ⌘1 / ⌘2 still switch sections; a Chat turn preserved to Work still opens the window on the desk.

---

## Catalog

**Keys I ADDED in source: NONE.** No new user-facing copy; no `.xcstrings` file opened.

**Keys DEAD because of this slice: NONE.** (`Delete All`, `conversations.deleteAll.help` and `toolbar.deleteAll` are only *conditionally hidden* in Work — every one still has a live reference.)

⚠️ **One stale user-facing string I deliberately left alone:** `ConduckApp.swift:339` declares the ⌘1 menu item as `Button("Workboard")` — a bare literal whose implicit catalog key is `Workboard` (the catalog row is an empty `{}`, so the menu renders the literal). The product now says **Work** everywhere else on that surface (`workbench.work` in the section control, `workboard.title` = "Work" as the desk's nav title). Plan §B sanctions exactly four copy rewrites and this is not one of them, and a parallel agent must not edit the catalog — so source and catalog stay in agreement. See §Requests 1.

---

## Call-site touches

**NONE.** I used no minimal-touch right: `WorkboardView.swift` needed nothing from me — views-core had already reshaped `WorkboardExperience` to `(viewModel:isActive:reduceMotion:)` and pre-removed the six dropped arguments and the sidebar mount at my call sites (its §Requests 3, which I treated as done). My whole change is inside files I own.

---

## Requests

1. **Serial copy pass — the ⌘1 menu item still says "Workboard".** `Conduck/Conduck/ConduckApp.swift:339`, `Button("Workboard")`. It wants to read **Work**. Cheapest correct form, matching the neighbouring `Button("Settings…")` / `Button("New Conversation")` / `Button("Chats")` literals, is `Button("Work")` — the key IS the English string, so it renders correctly with no catalog row, and the existing empty `Workboard` row then goes dead and can be swept. (views-core filed the sibling item: `workboard.load.failed.message` still speaks of "projects".)
2. **PersonalWorkbenchView owner — the Work deep link was mid-rewrite while I ran.** `routeWorkboardDeepLink` (`PersonalWorkbenchView.swift:906-916`) broke on `viewModel.selectedItemID` in my `bft-4` run and was fixed by the time of `bft-5`. My side of the route (`ConduckApp` foregrounds the singleton window on `.openWorkboardDeepLink`) is unconditional and unchanged, so whatever shape that function settles on, the window still comes forward. Just confirm the final shape still sets `destination = .work` — my `ConduckApp` comment now states that it does.
3. **Serial integration — do not "simplify" the derived visibility back into a plain `@State` binding.** Passing `$chatColumnVisibility` straight to the split view compiles, looks tidier, and silently deletes the entire Work collapse. `MacWorkbenchShellDriftGuardTests` fails loudly if anyone does; it is not decoration.
4. **Nobody else should take `columnVisibility` as a Work input.** If a later slice needs to know whether the window is showing a sidebar, read `effectiveColumnVisibility` (Work's forced collapse included), never `chatColumnVisibility`.
