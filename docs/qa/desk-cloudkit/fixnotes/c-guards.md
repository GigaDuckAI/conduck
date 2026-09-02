# c-guards — GUARD-body (3 conversions), O-6, C7 / r3a#8. All confirmed and done. **Counterfactual MEASURED.**

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `error:`) · my 12-class targeted set
`Executed 77 tests, with 0 failures` · signed macOS `** BUILD SUCCEEDED **`
(`Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`, **no `CODE_SIGNING_ALLOWED=NO`
fallback**) · **counterfactual measured in an isolated tree copy: with the three fixes reverted,
exactly 5 of my new cases fail (15 assertions) and every control passes.**

No commits/pushes/stash/checkout/index ops. `Identity-Override.xcconfig` untouched (the throwaway
copy's symlink was re-pointed inside my slug dir; the worktree's was never opened). **No `.xcstrings`
opened.** No `.pbxproj` edit. No mirror triplet touched. Nothing under `docs/qa/desk-cloudkit/`
touched. Slug `c-guards`, sim `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`.

Files changed — **10**: 6 production edits, 3 NEW production files, 3 test files (one new).

| File : symbol | What |
|---|---|
| `Views/Workboard/WorkboardDeskPresentation.swift` | **NEW** — the desk surface as a resolved value |
| `Views/Workboard/WorkboardDeepLinkRoute.swift` | **NEW** — the Work deep link's landing, as a testable owner |
| `Views/Workboard/WorkboardSyncBannerPolicy.swift` | **NEW** — contract **C7**: the policy + `WorkboardSyncBanner` |
| `Views/Workboard/WorkboardView.swift` : `WorkboardDetailColumn.body` | switches over the presentation |
| `Views/Workboard/WorkboardDetailView.swift` : `body` | renders the resolved `Desk` (no id, no `??`) |
| `Views/Workboard/WorkboardCaptureCanvas.swift` : `deskSyncBanner` | renders through the policy |
| `Views/Workboard/PersonalWorkbenchView.swift` : `.openWorkboardDeepLink` receiver, `workboardDeepLinkRoute`, `Notification.Name` | deep-link owner extracted; O-6 name + observer deleted |
| `Views/Conversation/MainWindowView.swift` : `.openPersonalAISettings` receiver, `presentPersonalAISettings()` | O-6 |
| `ContentView.swift` : two `.openPersonalAISettings` receivers | O-6 |
| tests: `WorkboardDeskPresentationTests` **NEW 6** · `WorkboardAvailabilityTests` 9→**10** · `WorkboardDeskSurfaceDriftGuardTests` 4→**1** |

**Net for the orchestrator: +4 iOS executed.**

---

## 1. Adjudication GUARD-body — three guards converted, one kept (it is not mine to convert)

I did NOT invent a seam per test. Two seams carry all three conversions, and each has a production
reader that is not a test.

### 1.1 `WorkboardDeskPresentation` — the seam for the two desk-body guards

**Verified first, by reading the two bodies.** `WorkboardDetailColumn.body` chose between loading /
load-failed / desk from `(isLoading, loadError, desk)`; `WorkboardDetailView.body` then chose between
the empty state and the canvas from `viewModel.desk ?? WorkboardItemSnapshot(id: Constants.workboardDeskItemID)`.
Two views, one decision, split across a file boundary — which is exactly why the old guard had to
grep for `item(withID:` and `let itemID` in one of them and `WorkboardEmptyState` in the other.

`WorkboardDeskPresentation.resolve(isLoading:loadError:desk:)` now takes that whole decision. It is a
pure function over three values, its four cases are the four surfaces, and **`WorkboardDetailColumn`
switches over it exhaustively** — so this is not a test-only accessor: the compiler makes a new
surface impossible to add without answering for it. `WorkboardDetailView` lost its `viewModel.desk`
read and takes the resolved `Desk` instead, so it now has no expression that could name a board at
all.

**Behaviour is unchanged, term by term.** Old: `if isLoading && desk == nil` → loading;
`else if loadError != nil && desk == nil` → failed; else → detail with the `??` fallback. New:
`guard let desk else { isLoading → .loading; loadError → .loadFailed; else → .desk(fixed identity) }`;
non-nil desk → `.desk`. Same partition, same order.

**What the two guards asserted, and where each clause went:**

| Old assertion | Successor |
|---|---|
| `source.contains("viewModel.desk")` | `resolve` takes the desk as its third argument; the column passes `viewModel.desk` and nothing else can reach it |
| `source.contains("Constants.workboardDeskItemID")` | `testTheDeskBeforeItsFirstCardIsStillTheDeskAtTheFixedIdentity` reads the id back off the resolved value |
| `XCTAssertFalse(contains("item(withID:"))` | the method does not exist (vm-collapse deleted it) and `resolve` has no id parameter to give one |
| `XCTAssertFalse(contains("let itemID"))` | `WorkboardDetailView` has no `viewModel.desk` read and no id-shaped local left |
| `contains("WorkboardEmptyState")` | `board == .invitation` for an empty desk, asserted in two cases |
| `contains("mode: .composer")` | see the honest limit below |

**The honest limit, stated rather than papered over.** The composer's *mounting* is structural: it is
an unconditional `safeAreaInset` inside `WorkboardDetailView`, which the column mounts only in the
`.desk` case. I deliberately did NOT add a `showsPinnedComposer` flag to the presentation to make
that assertable — nothing would read it but the test, and my brief forbids a seam that exists for one
test. What I assert instead is the distinction that decides it:
`testAnEmptyDeskAndAFailedLoadAreDifferentSurfaces` holds that an empty desk resolves to `.desk`
(the composer arm) and a failed load to `.loadFailed` (no composer), and
`testTheDeskBeforeItsFirstCardIsStillTheDeskAtTheFixedIdentity` holds that the composer's target on
that empty desk is the fixed identity. Collapsing the two arms — the way the first capture actually
becomes unreachable — fails both. A pure rename of the composer's modifier would not, and the old
grep would have caught that; I am trading that one string for a decision the compiler now polices.

### 1.2 `WorkboardDeepLinkRoute` — the seam for the deep-link guard

vm-collapse kept this guard with a specific objection: converting it means moving routing onto
`PersonalWorkbenchModel`, whose real `init()` builds `WorkboardLiveRepository(store: .shared)` — a
live `NSPersistentCloudKitContainer`. **That objection is exactly right about the model and exactly
what the route does not need.** The routing touches two things: `PersonalWorkbenchRouter` (a plain
`@Observable` class with no store) and one call into the refresh coordinator. So the owner takes
those two and nothing else:

```swift
WorkboardDeepLinkRoute(router: PersonalWorkbenchRouter, scheduleRefresh: @MainActor () -> Void)
    .open()   // router.destination = .work ; scheduleRefresh()
```

The shell builds one from `model.router` and `model.scheduleRefresh` at the receiver. **No live store
is constructed anywhere in the test** — the adjudication's own condition.

| Old assertion | Successor |
|---|---|
| `route.contains("destination = .work")` | `testAWorkDeepLinkRevealsTheDeskAndAsksForTheReload` reads `router.destination` |
| `route.contains("scheduleRefresh(")` | same case counts the closure |
| `XCTAssertFalse(route.contains("workItemIDKey"))` | `open()` takes **no parameter** — payload-independence is the signature, not discipline |
| `XCTAssertFalse(route.contains("load()"))` | `testTheDeepLinksReloadLandsBecauseTheDeskWasRevealedFirst` drives the **real** `WorkCaptureRefreshCoordinator` and shows the pass arriving through its gate |

That second case is the one worth reading. It establishes, in its middle block, that the real
coordinator **defers** a reload requested while Work is hidden (schedule, sleep 150 ms, `XCTFail` in
the refresh closure, count unchanged at 1) — and only then shows the link's own pass landing (count
2). So "the reload goes through the coordinator, and the desk is revealed first" is proven by the
coordinator's own behaviour rather than asserted about source text. The absence half — that no
*second* load path exists — is the guard I kept (§1.3).

### 1.3 `testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` — KEPT (GUARD-absence, per adjudication)

Untouched, still 1/1 green. It is an ABSENCE over a whole file. `WorkboardDeskSurfaceDriftGuardTests`
now holds only this one case and its header was rewritten to describe only it (present tense, no
narration), pointing at `WorkboardDeskPresentationTests` for what the deep link does.

### 1.4 GUARD-appex / the other GUARD-absence rows — touched nothing

`WorkCaptureSharePublisherTests.testBothShareExtensionsPublishThroughThePublisherRatherThanByHand`,
`WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` — not opened.
The retry-surface guard is c-lanes'; not opened.

## 2. Adjudication O-6 — the dead notification. CONFIRMED dead, deleted.

**Verified before deleting, both halves.**

1. **No poster.** `grep -rn openPersonalAISettings` over every `.swift`/`.plist`/`.json`/`.m`/`.h` in
   the worktree returned the name's declaration and the four `onReceive` observers and **nothing
   else** — no `NotificationCenter.default.post(name: .openPersonalAISettings`, and no post of the
   raw string `"openPersonalAISettings"` either.
2. **Chat's route still stands, on BOTH roots**, which is what the adjudication asked me to check
   before deleting. macOS: `MainWindowView.openPersonalAISettingsFromNotice()` keeps its two live
   callers — `consumeGatewayFixRoute()` (`:1347`) and the banner callback
   `onOpenPersonalAI: { openPersonalAISettingsFromNotice() }` (`:1498`) — plus ordinary Settings
   navigation at `:714` and `:1883`. iOS: `ContentView.openPersonalAIFromNotice()` is wired into
   `ConversationLibraryView`'s `onOpenPersonalAIFromNotice` (`:215`) and the inline banner (`:489`),
   with two further `SettingsRoute(category: .personalAI)` routes at `:808`/`:942`. The deleted
   observers were the only unreachable ones.

Deleted: `Notification.Name.openPersonalAISettings` · `ContentView.swift` ×2 observers (the iPad arm
and the `#if os(iOS)` phone arm) · `PersonalWorkbenchView.swift` ×1 · `MainWindowView.swift` ×1.

**Regression cover: the compiler.** Every deletion is of a declaration or of a subscriber to a
notification nothing sends. There is no runtime behaviour left to assert — the observers were
unreachable, so a test that "proves" they are gone can only re-grep, which is the instrument this
slice is retiring. Re-introduction has to state a poster.

## 3. C7 + r3a#8 — the desk's iCloud banner. CONFIRMED, minted.

**Verified:** `deskSyncBanner` passed `CloudSyncMonitor.Reason` straight to `ICloudUnavailableBanner`,
which renders `reason.bannerMessage` — `CloudSyncMonitor.swift:55-71`, three sentences all naming
*conversations*, on a surface showing cards.

`WorkboardSyncBannerPolicy` now owns both halves of the notice:

- `message(showsBanner:reason:) -> LocalizedStringResource?` — the SHOW decision. Its only inputs are
  the monitor's account state and the sticky per-outage dismissal, so a sync EVENT cannot reach it.
  (That is the reasoning the old source guard was pinning; it now holds by the function's signature.)
- `message(for: CloudSyncMonitor.Reason) -> LocalizedStringResource` — the three desk keys.

**Deviation, and why (see §Requests 1).** C7 says the canvas renders through the policy. Rendering
desk copy through `ICloudUnavailableBanner` needs a `message:` parameter on it, and
`Views/Components/ICloudUnavailableBanner.swift` is **not a file I own** — so I did not open it. The
desk therefore draws `WorkboardSyncBanner`, in my own new file: same glyph, same
`glassCardBackground(borderColor: AppColors.sunsetOrange.opacity(0.4))`, same
`openICloudSystemSettings()` button, same dismiss button and the same two shared keys
(`sync.icloud.banner.openSettings`, `sync.icloud.banner.dismiss`), differing only in taking its
sentence instead of deriving one. It is a 35-line wrapper, not a second policy, and §Requests 1 names
the three-line change that collapses the two into one banner. Chat's `sync.icloud.banner.*` are
untouched and still rendered by `ConversationListView`.

## 4. The tests, and how each proves the old code wrong — **MEASURED**

New file `Conduck/ConduckTests/WorkboardDeskPresentationTests.swift` (6 cases); two cases replacing
the banner source guard in `WorkboardAvailabilityTests.swift`.

I made a throwaway copy of the tree at `~/Library/Caches/gigaduck-builds/c-guards/cf-tree`, reverted
all three fixes in it, built (`** TEST BUILD SUCCEEDED **`, 0 `error:`) and ran the three classes:
`Executed 17 tests, with 15 failures`. The reverts were:

1. `resolve`'s desk-with-no-row arm → `.loadFailed(message: "")` (the "an absent row is a missing
   board" drift the two desk guards existed to prevent);
2. `WorkboardSyncBannerPolicy.message(for:)` → `reason.bannerMessage` (**literally the pre-fix
   behaviour**, since that is what `ICloudUnavailableBanner` rendered);
3. `WorkboardDeepLinkRoute.open()` → `scheduleRefresh()` with the reveal dropped.

**Exactly five cases failed, and the controls passed** (`cf-test2.log`, verbatim case list):

| Case | Verdict on reverted code | Quoted failure |
|---|---|---|
| `testTheDeskBeforeItsFirstCardIsStillTheDeskAtTheFixedIdentity` | **failed** | `failed - a desk with no row yet must still resolve to the desk surface` |
| `testAnEmptyDeskAndAFailedLoadAreDifferentSurfaces` | **failed** | `XCTAssertEqual failed: ("loadFailed(message: "")") is not equal to ("desk(…Desk(item: …(id: DE5C0000-0000-4000-A000-000000000001 …), board: …invitation))")` |
| `testAWorkDeepLinkRevealsTheDeskAndAsksForTheReload` | **failed** | `XCTAssertEqual failed: ("chats") is not equal to ("work")` |
| `testTheDeepLinksReloadLandsBecauseTheDeskWasRevealedFirst` | **failed** (3 assertions) | `Asynchronous wait failed: Exceeded timeout of 2 seconds, with unfulfilled expectations: "the deep link's pass".` · `("1") is not equal to ("2")` · `("chats") is not equal to ("work")` |
| `testTheDeskBannerNamesCardsRatherThanConversations` | **failed** (9 assertions) | `XCTAssertFalse failed - the desk's noAccount banner still talks about conversations: iCloud is signed out — your conversations won't sync across your devices.` (and the restricted / quotaExceeded twins) |
| `testADeskCarryingCardsDrawsTheBoardRatherThanTheInvitation` | passed | positive control — the revert only touches the absent-row arm |
| `testAWarmBoardSurvivesBothAReloadAndAFailedReload` | passed | positive control |
| `testTheDeskBannerShowsOnlyForAnAccountStateThePersonCanFix` | passed | control — the SHOW decision is a separate rule from the copy |
| `testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` | passed | control — the kept guard is unaffected |
| the other 8 `WorkboardAvailabilityTests` cases | passed | control — the harness is not one-sided |

Two things I want on the record about that run. The banner case is a **true pre-fix counterfactual**
(revert 2 restores the exact sentence the shipped desk showed). The presentation and deep-link cases
are **drift counterfactuals**: those two behaviours were already correct, and what the wave asked me
to change is the instrument holding them — so what I measured is that the new instrument bites where
the old one did. And inside the deep-link case, the middle block did NOT `XCTFail` on the reverted
build, which is the evidence that the deferral demonstration held and the failure was specifically
the link's own pass never landing.

The worktree itself was never mutated for the counterfactual — the copy is a separate tree under my
slug dir, removed with the build caches (§Gates).

## 5. Decisions

1. **One presentation type for all four surfaces, not one for the desk body alone.** The load and
   load-failure arms are what make "an empty desk keeps the composer" a real distinction rather than
   a tautology — the failed load is the surface that legitimately has no composer.
2. **No `showsPinnedComposer` flag.** Stated in §1.1: it would have exactly one reader, the test.
3. **`WorkboardDeepLinkRoute` takes the router and a closure, not `PersonalWorkbenchModel`.** The
   model's `init()` builds a live store; the routing needs neither the store nor the model.
4. **`WorkboardSyncBanner` rather than editing `ICloudUnavailableBanner`.** File ownership, §3;
   the collapse is §Requests 1.
5. **`presentPersonalAISettings()` deleted with its only caller.** Deleting the observer left a
   private method with zero callers — the same unreachable debris O-6 is about. Flagged in
   §Deviations because my brief says "one deletion each".
6. **`testEachActionableAccountReasonSaysSomethingDifferent` left alone.** It is about Chat's copy
   remaining distinct, and the desk's own distinctness is asserted in my new case. Not my test to
   re-aim.
7. **No Codex consult.** The one hard call (the shared banner) was settled by the ownership rule, not
   by design uncertainty.

## 6. Deviations

- **`ContentView.swift` gets TWO deletions, not "one deletion each".** My brief says one each; the
  adjudication says four observers across three files, and the file genuinely has two (`:291` iPad
  arm, `:675` phone arm). I deleted both — one would have left a live subscriber to a name I removed,
  which does not compile.
- **`presentPersonalAISettings()` deleted** (§Decisions 5) — beyond the literal "observers only"
  grant on `MainWindowView.swift`.
- **A second banner view exists this wave** (§3, §Requests 1). Behaviour and chrome are identical;
  only the sentence differs.
- **`WorkboardDetailView`'s signature changed** (gained `desk:`). Its only construction site is
  `WorkboardView.swift:273`, which I own.

## 7. Gates — what I actually ran, and the exact lines

Slug `c-guards`. DerivedData under `~/Library/Caches/gigaduck-builds/c-guards/{DerivedData,
DerivedDataMac,DerivedDataCF}`; every log written there and grepped for `': error: '` and the verdict
strings — never judged from tail or exit code. **No `-configuration` passed anywhere.**

- **iOS `build-for-testing`** → `ios-bft-1.log` and `ios-bft-2.log` (final, on the merged tree):
  `grep -c ': error: '` = **0** both times, `** TEST BUILD SUCCEEDED **` both times. **Zero warnings
  naming any of my ten files** on either platform (grepped by filename).
- **Targeted set, final run** → `ios-test-6.log`, `test-without-building`, one quoted `-only-testing:`
  flag per class, `** TEST EXECUTE SUCCEEDED **`,
  `Executed 77 tests, with 0 failures (0 unexpected) in 7.869 (7.898) seconds`:

| Class | Result | Δ |
|---|---|---|
| `WorkboardDeskPresentationTests` (**new**) | `Executed 6 tests, with 0 failures` | +6 |
| `WorkboardAvailabilityTests` | `Executed 10 tests, with 0 failures` | +1 |
| `WorkboardDeskSurfaceDriftGuardTests` | `Executed 1 test, with 0 failures` | −3 |
| `WorkboardDeskViewModelTests` | `Executed 5 tests, with 0 failures` | 0 |
| `WorkboardOpenPathTests` | `Executed 6 tests, with 0 failures` | 0 |
| `MacWorkbenchShellDriftGuardTests` | `Executed 4 tests, with 0 failures` | 0 |
| `WorkCaptureRefreshCoordinatorTests` | `Executed 6 tests, with 0 failures` | 0 |
| `CloudSyncMonitorTests` | `Executed 6 tests, with 0 failures` | 0 |
| `HeadlessRefusalLaneDriftGuardTests` | `Executed 5 tests, with 0 failures` | 0 |
| `GatewayFixRouteLandingDriftGuardTests` | `Executed 10 tests, with 0 failures` | 0 |
| `STTKeyBlackoutLaneTests` | `Executed 11 tests, with 0 failures` | 0 |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures` | 0 |

  The last six are **beyond my brief, run deliberately**: `MacWorkbenchShellDriftGuardTests`,
  `HeadlessRefusalLaneDriftGuardTests`, `GatewayFixRouteLandingDriftGuardTests`,
  `STTKeyBlackoutLaneTests` and `ErrorSurfaceDriftGuardTests` all read `MainWindowView.swift` or
  `ContentView.swift` as TEXT, so my two deletions there could have moved an anchor or a count
  (`GatewayFixRouteLandingDriftGuardTests` counts `showingSettings = false` occurrences —
  `presentPersonalAISettings` set it to `true`, so the count is unchanged; verified by the run, not
  only by reading). `WorkboardAudioCaptureTests` (19/0) and `WorkboardVoiceLaneTests` (12/0) were
  green in an earlier pass of the same set (`ios-test-2.log`, `Executed 75 tests, with 0 failures`).
- **Counterfactual** → `cf-bft-try1.log` (`** TEST BUILD SUCCEEDED **`, 0 `error:`) + `cf-test2.log`
  (`Executed 17 tests, with 15 failures`), quoted case by case in §4.
- **macOS `build -destination 'platform=macOS'`** → `mac-2.log` (final): 0 `error:`,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 794 Swift files scanned…`, exit 0.
  `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories…`, exit 0.
- `git diff --check` → no output, exit 0. `git status --short` for `*.xcstrings`,
  `Conduck/Conduck.xcodeproj`, `Conduck/Configs`, `docs/qa` → **empty**.
- **Simulator trouble, recorded rather than hidden.** Three consecutive runs died with
  `Simulator device failed to launch ai.gigaduck.AgentRelay … Busy ("Application failed preflight
  checks")` and, once, `Mach error -308 … server died`, with **no test case ever started**. Handled
  per the standing rule (`xcrun simctl shutdown all`, retry), and when that did not clear it, by
  `xcrun simctl uninstall 04DEF4F5… ai.gigaduck.AgentRelay` — the counterfactual copy had installed a
  differently-signed build under the same bundle id. The next run was clean (`ios-test-6.log`).
  **Note for other agents: my `simctl shutdown all` may have interrupted a run of yours around
  21:54–21:56; that is on me.**
- **NOT run, plainly:** the full iOS suite and the **watch suite**. No watch sim is assigned to me and
  nothing I wrote reaches the watch target — the watch's membership exception from the `Conduck`
  folder names exactly one `Views/` file (`Views/Conversation/MessageRowFormatters.swift`), and
  `WorkboardSyncBannerPolicy.swift` is additionally fenced `#if !os(watchOS)` because it names
  `CloudSyncMonitor`, which is iOS/macOS-only.
- **Build caches, the counterfactual tree and every log removed** with
  `.claude/scripts/clean-build-cache.sh c-guards` — so the logs quoted above no longer exist; re-run
  if you need them.

---

## Catalog

**Keys I ADDED in source (3)** — `key = defaultValue`, one source site each, in
`Views/Workboard/WorkboardSyncBannerPolicy.swift`, main app catalog. Apostrophes are U+2019 (’),
matching the shipped `sync.icloud.banner.*` rows:

- `workboard.sync.banner.noAccount` = `iCloud is signed out — your cards won’t sync across your devices.`
- `workboard.sync.banner.restricted` = `iCloud is restricted on this device — your cards can’t sync.`
- `workboard.sync.banner.quotaExceeded` = `Your iCloud storage is full — new cards can’t sync to your other devices.`

**Keys I made DEAD: NONE.** `sync.icloud.banner.{noAccount,restricted,quota}` are still rendered by
Chat (`ConversationListView.swift:320` → `ICloudUnavailableBanner` → `reason.bannerMessage`), and
`sync.icloud.banner.openSettings` / `sync.icloud.banner.dismiss` are rendered by **both** banners.
Nothing I deleted carried a string: the four `.openPersonalAISettings` observers and
`presentPersonalAISettings()` set routes, not copy.

**Do NOT delete on a stale scout row:** every `sync.icloud.*` key · `workboard.title` ·
`workboard.empty.title` · `workboard.desk.empty.message` · `workboard.load.failed.{title,message}` ·
`workboard.load.retry` · `workboard.loading` — all still rendered, several of them from lines I moved
between arms of a `switch`.

---

## Requests

1. **Serial integrator (or whoever owns `Views/Components/ICloudUnavailableBanner.swift`) — collapse
   the two banners into one.** Three lines, behaviour-preserving:
   - give `ICloudUnavailableBanner` a `let message: LocalizedStringResource` beside `reason` (or in
     place of it) and render that instead of `reason.bannerMessage`;
   - `ConversationListView.swift:320` passes `reason.bannerMessage`;
   - `WorkboardCaptureCanvas.deskSyncBanner` passes the policy's message, and
     `WorkboardSyncBanner` in `WorkboardSyncBannerPolicy.swift` is **deleted** (it exists only because
     the shared banner derives its own sentence, and that file is not mine this wave).
   Why it matters: the chrome is currently stated twice. `WorkboardSyncBannerPolicy` is the durable
   half and should survive the collapse — it owns the desk's copy and the show decision.
2. **Serial copy agent — three new keys to splice** (§Catalog). Until then they render from their
   `defaultValues`, which are correct English but invisible to the catalog. They close **O-14** on the
   "mint desk-specific keys" side, per r3a#8; Chat's three are untouched, so nothing needs widening.
3. **Whoever writes the wave's `Requests`/open-item ledger — O-6 is CLOSED**, and O-14 is closed on
   the desk side pending the catalog splice.
4. **Nobody give `WorkboardDeskPresentation` an id parameter.** `resolve` takes `(isLoading,
   loadError, desk)` and hands out `Constants.workboardDeskItemID` when there is no row. An id
   argument would make "point the desk at another board" representable again — which is precisely
   what the two deleted source guards were holding, and the behavioural successors assert the
   consequence, not the parameter list.
5. **Nobody re-add a `load()` to `PersonalWorkbenchView.swift`.** The surviving source guard counts
   `workboardViewModel.load()` occurrences and expects exactly one (the coordinator's `refresh`
   closure). The deep link now goes through `WorkboardDeepLinkRoute`, which calls
   `model.scheduleRefresh()`.
6. **Founder QA — three things a headless run cannot prove.** (a) On a device signed OUT of iCloud
   (or with the `-ConduckQAForceICloudUnavailable` QA argument), open Work: the banner must read
   *"…your cards won't sync…"*, and dismissing it there must also dismiss it on the conversation list
   (one outage, one dismissal). (b) Work still opens from its deep link — a Shortcut / notification
   that reveals Work — and the board is current when it appears. (c) Personal AI still opens from the
   Chat banner's button on **both** iOS and macOS (the deleted notification had no poster, but this
   is the route it looked like it served).

## Refuted

**Nothing.** The one finding (r3a#8) and both adjudications (GUARD-body, O-6) held against the
current tree when traced by call path before any edit: the desk banner really did render Chat's
`reason.bannerMessage`, `.openPersonalAISettings` really had zero posters and four live observers,
and the two desk guards really were greps over two `body`s that a single resolved value can replace.
The only narrowing is the composer clause in §1.1, and it is stated there as a narrowing rather than
a refusal.

## Guard verdicts

| Test | Verdict | Evidence |
|---|---|---|
| `WorkboardDeskSurfaceDriftGuardTests.testTheDeskRendersTheFixedIdentityAndResolvesNoItem` | **CONVERTED, then DELETED** | successor: `WorkboardDeskPresentationTests.testTheDeskBeforeItsFirstCardIsStillTheDeskAtTheFixedIdentity` (+ `testADeskCarryingCardsDrawsTheBoardRatherThanTheInvitation`). Fails on the reverted code — measured, §4. Deleted only after the successor was green. |
| `…testTheEmptyDeskShowsTheEmptyStateAndKeepsTheComposer` | **CONVERTED, then DELETED** | successor: `testAnEmptyDeskAndAFailedLoadAreDifferentSurfaces` (+ the invitation half of the case above). Measured, §4. Honest limit on the composer's *mounting* stated in §1.1. |
| `…testEveryWorkDeepLinkResolvesToTheDeskThroughTheRefreshCoordinator` | **CONVERTED, then DELETED** | successors: `testAWorkDeepLinkRevealsTheDeskAndAsksForTheReload` and `testTheDeepLinksReloadLandsBecauseTheDeskWasRevealedFirst`, the second driving the real `WorkCaptureRefreshCoordinator` with no store anywhere. Both fail on the reverted code — measured, §4. |
| `…testTheRefreshCoordinatorIsTheOnlyBoardLoadOwner` | **KEPT** | GUARD-absence, per adjudication. An absence over a whole file; untouched, 1/1 green. The file's header now describes this case alone. |
| `WorkboardAvailabilityTests.testTheDeskBannerReadsAccountStateRatherThanTheLastSyncEvent` | **CONVERTED, then DELETED** | successors: `testTheDeskBannerShowsOnlyForAnAccountStateThePersonCanFix` (the show decision, whose only inputs are account state and the dismissal — so "not the last sync event" is now the signature) and `testTheDeskBannerNamesCardsRatherThanConversations` (the copy, which fails on the pre-fix behaviour — measured, §4). |
| `WorkboardAvailabilityTests.testTheAvailabilityProjectionNeverNamesThePayloadColumn` | **KEPT**, untouched | not mine; it is the projected-columns absence guard fix2-store already adjudicated `keep`. |
| `WorkCaptureSharePublisherTests.testBothShareExtensionsPublishThroughThePublisherRatherThanByHand` · `WorkboardBlobSeamPlatformGuardTests.testThePayloadSeamsAreCompiledOutOfTheWatchBuild` | **KEPT**, not opened | GUARD-appex / GUARD-absence, per adjudication. |
| `WorkboardAudioCaptureTests.testEveryRetrySurfaceRepairsTheRecordingBeforeItPublishes` | not mine | c-lanes'. Not opened; green in `ios-test-2.log` (19/0). |
| `MacWorkbenchShellDriftGuardTests` (4 cases) | **KEPT**, not opened | they read `MainWindowView.swift`, which I edited; all four still pass (4/0, §7) — checked, not assumed. |
