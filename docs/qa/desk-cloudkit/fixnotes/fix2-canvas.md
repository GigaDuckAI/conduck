# fix2-canvas — ui#1, ui#6, audio#7, t#4. All four CONFIRMED and fixed. **Every gate GREEN.**

iOS `** TEST BUILD SUCCEEDED **` (0 `error:`) · targeted set `Executed 22 tests, with 0 failures`
(mine 6/0) · signed macOS `** BUILD SUCCEEDED **`, no `CODE_SIGNING_ALLOWED=NO` fallback.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No
`.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No mirror triplet touched.

Files I changed — four, all mine:
- `Conduck/Conduck/Views/Workboard/WorkboardCardActionPolicy.swift` — **NEW**, 93 lines (the policy).
- `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` — the tap funnel, the card dispatch,
  and `WorkboardSourceCard`'s tile / menu / VoiceOver actions.
- `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` — the router's `present` gate and the
  preview copy's filename ONLY. Its handler wiring is untouched, as briefed.
- `Conduck/ConduckTests/WorkboardOpenPathTests.swift` — **NEW**, 6 cases.

Both new files are in synchronized groups (`Views/Workboard`, `ConduckTests`) — compiled and ran with
**no pbxproj edit**. Neither reaches the watch: the watch target's membership-exception list from the
`Conduck` folder names exactly one `Views/` file (`Views/Conversation/MessageRowFormatters.swift`),
so nothing of mine compiles on the wrist.

---

## 1. ui#1 — a `.syncPending` card followed the Open path. **CONFIRMED, fixed in two places.**

Verified against the tree before changing anything, by tracing the call path rather than trusting the
finding's wording:

- `WorkboardCaptureCanvas.openMaterial` read `if material.availability == .unavailableOnThisDevice`
  and sent **everything else** — `.syncPending` included — to `viewModel.openMaterial`, which is the
  repository's injected `openMaterial` closure, which is `PersonalWorkbenchModel.init`'s
  `Task { await router.present(material) }`. One funnel, and no gate anywhere on it.
- `PersonalWorkbenchRouter.present` switched on `kind` alone. For a pending IMAGE:
  `localURLForWorkMaterial` returns nil (it answers only `storageMode == .localVault` —
  `ConversationStore+Workboard.swift : localURLForWorkMaterial`), `loadWorkMaterialPayload` returns
  nil (no complete blob), and the arm falls through to **`?? material.thumbnailData`** — so the card's
  thumbnail was presented as the material. For a pending FILE or recording the same nil throws
  `WorkbenchPreviewError.unavailable`, whose copy reads *"…Reattach it here to open or send it."* — a
  repair instruction for bytes that need no repair and cannot be repaired by hand.

**Fix.** The decision moved into one pure type, `WorkboardCardActionPolicy`, and every surface asks it:

| Availability | Permitted | Tile's tap |
|---|---|---|
| `.available` / `.localOnly` | `.open`, `.play` | open |
| `.unavailableOnThisDevice` | `.reattach` | reattach |
| `.syncPending` | — (empty) | **nothing: the card is not a control** |

- `openMaterial` is now `WorkboardCardActionPolicy.performPrimaryAction(for:open:reattach:)`. A
  waiting card reaches neither the preview router nor the file importer.
- `PersonalWorkbenchRouter.present` opens with
  `guard WorkboardCardActionPolicy.allows(.open, when: material.availability)`, **inside** the `do`
  block so the refusal surfaces as the existing `previewNotice` rather than as silence. That guard is
  the boundary the brief asks for: open, preview, share (`ShareLink` on the preview URL) and play
  (Quick Look / `Link`) are all downstream of this ONE presenter — `materialPresentation` has no other
  writer in the app (`grep` over `Conduck/Conduck/` returns only this file) — so no future caller can
  bypass the canvas.
- The refusal's copy now matches the state: `WorkbenchPreviewError` gained a `.syncPending` case, so a
  waiting card is never told to reattach. **One new key** (§Catalog).

**Deliberate:** the `.image` arm's `?? thumbnailData` fallback is untouched. With the guard in front of
it, it is reachable only for a card the store says is readable whose payload read came back nil — a
race, not a state — and removing it would be a behaviour change outside the finding.

## 2. ui#6 + audio#7 — the audio card's Open and Reattach seams. **CONFIRMED, fixed via C2.**

When I read it, `card(for:at:)`'s audio arm passed only `onSetSize` / `onMoveEarlier` / `onMoveLater` /
`onRemove`, so `WorkboardAudioCardView` had no reattach action behind its action-sounding "Reattach"
chip and no Open row at all. fix2-audio-card landed the C2 API during the wave (`var onOpen`,
`var onReattach`, declared after `loadPayload`); the canvas now passes **both, unconditionally, for
every audio card**, which is what turns their `showsOpenAction(availability:hasOpenAction:)` and
`chip(for:hasReattachAction:)` on. Their `.syncPending` chip stays a non-action, which agrees with the
policy exactly.

audio#7's second half — the extensionless preview file — is fixed at the naming site rather than by
special-casing audio. `PersonalWorkbenchRouter.previewFilename(displayName:mimeType:)` gives a preview
copy the extension its **stored mime type** claims whenever the card's name does not already name a
type. A recording's name is a title ("Voice note", or the transcript's first line), and Quick Look,
`ShareLink` and every receiving app decide what a file is from the extension alone.

Two decisions inside it, both deliberate and both measured:
- **A trailing fragment counts as an extension only when the system can name a non-dynamic type for
  it.** "Meeting v1.2" ends in `.2`, which describes nothing; treating it as an extension would leave
  the payload's own type unstated. Measured: `UTType(filenameExtension: "2")?.isDynamic == true`,
  `"csv" → false`.
- **The mechanism is `UTType(mimeType:)?.preferredFilenameExtension`, not a hardcoded `m4a`.** On this
  OS `audio/mp4` resolves to `public.mpeg-4-audio`, whose preferred extension is **`mp4`**, not `m4a`
  (measured, twice). That is an extension the mime type itself claims
  (`tags[.filenameExtension] == ["mp4", "mpg4"]`), it resolves to `public.mpeg-4` which conforms to
  `public.audiovisual-content`, and Quick Look plays it — so the defect (an extensionless file handed
  to Quick Look and the share sheet) is gone. Getting the literal `.m4a` means carrying the STORED
  filename (`voice-note.m4a`, written by `WorkVoiceCaptureCoordinator.publishRecording`) onto
  `WorkboardMaterialSnapshot`, which is `WorkboardLiveRepository` + the snapshot type — files I do not
  own. §Requests 3.
- The local-URL branch is untouched: `makePreviewCopy` already falls back to the real file's own
  extension, and the vault key carries it (`WorkAssetVault.makeKey(id:suggestedExtension:)`).

## 3. t#4 — the card-action policy, and what the source card stopped doing unconditionally

The test-lens finding is right about the source card: `WorkboardSourceCard` wrapped its whole tile in
`Button(action: onOpen)` and opened its menu with an unconditional Open row, for every availability
state. Both are now policy-gated, by the same function the canvas and the router use:

| Site | Before | After |
|---|---|---|
| tile | always `Button(action: onOpen)` | `if let primaryAction { Button(action:) { tile } } else { tile }` — the audio card's own precedent, so a waiting card carries no button trait, no dead activation and no `.disabled` dimming, while its arrange actions stay reachable |
| menu Open row | unconditional | `if let openAction` |
| menu Reattach row | `if let onReattach` (the CANVAS decided by availability at the call site) | `if let reattachAction` — the card asks the policy |
| VoiceOver Reattach action | `if let onReattach` | `if let reattachAction` |
| board dispatch | `onReattach: material.availability == .unavailableOnThisDevice ? {…} : nil` | passes both seams unconditionally; the card gates |

Moving the availability test **out** of the call site is the point: a board that pre-filters and a card
that also decides are two copies of one rule, and two copies are how a tile and its menu start
disagreeing about the same card.

`.play` is in the vocabulary but is never a tile's verb — an audio card owns its transport and asks
`allows(.play, when:)` for permission. That is why `primaryAction(for:)` is derived from the permitted
set rather than being a second switch, and why `performPrimaryAction` takes only `open` and `reattach`.

The card's waiting STATUS is untouched and still visible on the now-inert tile: `previewText` for an
image/file card is `material.detail`, which `WorkboardLiveRepository.materialDetail` fills with
"Waiting for iCloud…" for `.syncedPending`, beside the `icloud.and.arrow.down` glyph and the same
phrase in the accessibility summary.

## 4. The tests (new file, 6 cases) and how each proves the old code wrong

`Conduck/ConduckTests/WorkboardOpenPathTests.swift`.

| Case | What it proves | Why it failed on the old code |
|---|---|---|
| `testEveryAvailabilityStateMapsToItsOwnActionSet` | the four states → `[open, play]` / `[open, play]` / `[reattach]` / `[]`, plus `primaryAction` and `allows(.play,…)` | the policy did not exist; the rule was spelled at four call sites, none of which could be asked |
| `testASyncPendingCardInvokesNeitherOpenPlayNorReattach` | spies on both closures: a waiting card runs neither | the old funnel's `else` branch ran `open` for `.syncPending` — `XCTAssertEqual(opened, 0)` would have read 1 |
| `testAReadableCardOnlyOpensAndAMissingOneOnlyRepairs` | the other three states, positively | — (guards the fix against over-refusal) |
| `testTheRouterRefusesACardWhoseBytesAreNotReadableHere` | **behavioural, through the real router**: a pending image WITH a thumbnail presents nothing and explains itself; a missing file presents nothing; **the two explanations differ** | old code committed `.image(thumbnailData)` for the pending card, so `XCTAssertNil(router.materialPresentation)` would have failed outright; and both states produced the identical reattach sentence, so `XCTAssertNotEqual` would have failed too |
| `testTheRouterStillPresentsAReadableCard` | the gate refuses states, not materials — a readable note still presents, with its own text | positive control: a refuse-everything guard passes every assertion above and fails this one |
| `testAPreviewCopyIsNamedWithAnExtensionItsBytesActuallyClaim` | a recording's preview filename carries an extension the mime type's own tag list claims, resolving to audiovisual content; a named file keeps its extension; a version-suffixed title still gets one; no mime type invents nothing | old code called `safePreviewFilename("Voice note")` = `"Voice note"` — `pathExtension` empty, so the first assertion fails |

**How I know, stated plainly:** these are arguments from the assertions against the code I read and
quoted in §1–§3, **not a measured counterfactual.** I did not build a reverted copy: the shared tree
was red on foreign files for most of my window (§5), and the two router cases would, on the old code,
have run `ConversationStore.shared` — a live store no other unit test in the suite touches. Each row
above names the exact old value the assertion would have seen.

Deliberately NOT asserted: the exact wording of either refusal. The defect is that a waiting card was
shown the *reattach* sentence, and `XCTAssertNotEqual(pendingMessage, missingMessage)` catches that in
both directions; pinning the copy would declare a catalog key at a second source site during a
parallel phase whose catalogs belong to the serial copy agent.

## 5. Gates — what I actually ran, and the exact result lines

Slug `fix2-canvas`. DerivedData under `~/Library/Caches/gigaduck-builds/fix2-canvas/{DerivedData,DerivedDataMac}`,
every log written there and grepped for `': error: '` and the verdict strings — never judged from tail
or exit code. No `-configuration` passed anywhere. Sim `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`.

**A. iOS `build-for-testing` — GREEN on the fifth attempt** (`ios-bft-5.log`):
`grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`, `exit=0`. **Zero warnings in any of my
four files** (`grep -cE "(WorkboardCaptureCanvas|WorkboardCardActionPolicy|PersonalWorkbenchView|WorkboardOpenPathTests)\.swift:[0-9]+:[0-9]+: warning"` = 0).

Attempts 1–4 failed **only in files I do not own**, each a different agent mid-edit; I waited and
retried per the parallel-phase rule rather than touching anything of theirs. Verbatim:

| Log | Foreign error(s) |
|---|---|
| `ios-bft-1.log` | `Services/InAppAudioRecorder.swift:533:20: error: binary operator '??' cannot be applied to operands of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome?' and 'Bool'` |
| `ios-bft-2.log` | same file `:357:53 has no member 'completeCapture'` + `:635:20` the `??` one |
| `ios-bft-3.log` | 6 × `ConduckTests/WorkboardAudioCaptureTests.swift` (`:124,:168,:185,:206,:243,:268`) `cannot convert value of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome' to expected argument type 'Bool'` — **the app target itself compiled in this run**, my files included |
| `ios-bft-4.log` + `mac-2.log` | `Intents/ConverseIntent.swift:257:42: error: type 'ConverseIntent' has no member 'compressForWork'` |

**B. Targeted tests — 22 executed, 0 failures** (`ios-test-1.log`, `test-without-building`, one quoted
`-only-testing:` flag per class), `** TEST EXECUTE SUCCEEDED **`:

| Class | Result line |
|---|---|
| `WorkboardOpenPathTests` (new) | `Executed 6 tests, with 0 failures (0 unexpected) in 0.008 (0.011) seconds` |
| `WorkboardMaterialPresentationTests` | `Executed 4 tests, with 0 failures (0 unexpected) in 0.005 (0.006) seconds` |
| `WorkboardMaterialBoardActionsTests` | `Executed 12 tests, with 0 failures (0 unexpected) in 0.024 (0.027) seconds` |
| total | `Executed 22 tests, with 0 failures (0 unexpected) in 0.037 (0.047) seconds` |

**C. macOS build, signed** (`mac-3.log`, `-destination 'platform=macOS'`): `grep -c ': error: '` = **0**,
`** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`. **Signed
through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.** Zero warnings in my
files there either.

**D. Hygiene.** `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 780 Swift files
scanned…`, exit 0. `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source
directories, all mapped…`, exit 0. `git diff --check` → clean, exit 0. `git status --short` for
`Conduck/Configs`, `docs/qa`, `Conduck.xcodeproj` and any `.xcstrings` → **empty**.

**E. NOT run, plainly:** the full iOS suite and the watch suite. Neither is in my brief (which names
build-for-testing, three targeted classes and the macOS build), no watch sim is assigned to me, and
nothing I wrote compiles into the watch target. Build caches removed at the end with
`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh fix2-canvas`, so **the logs
above no longer exist** — re-run if you need them.

## 6. Guard verdicts

**None assigned.** My brief names t#4 only, and no `drift_guard_verdicts` row in
`codex-tests-findings.json` names a test in my ownership — I converted nothing and kept nothing that
was not mine to judge.

Three existing source guards read files I edited, and all three still hold (checked, not assumed):
`WorkboardAvailabilityTests.testTheDeskBannerReadsAccountStateRatherThanTheLastSyncEvent` over
`WorkboardCaptureCanvas.swift` (I touched neither the banner nor `recentSyncEventLines`), and
`WorkboardDeskSurfaceDriftGuardTests`' two over `PersonalWorkbenchView.swift`
(`routeWorkboardDeepLink` untouched; I added no second `workboardViewModel.load()`).

---

## Catalog

**Keys I ADDED in source (1)** — `key = defaultValue`, one source site, in
`PersonalWorkbenchView.swift` (`WorkbenchPreviewError.syncPending`), main app catalog:

- `workboard.material.preview.syncPending` = `This material is still arriving from iCloud. It will open once it lands on this device.`

**Keys I made DEAD: NONE.** Every key the source card and its menu carried is still reachable —
`workboard.material.open` and `workboard.material.reattach.action` became conditional rows rather than
unconditional ones, and each still has a state that shows it.

**Reused, do NOT delete on a stale scout row:** `workboard.material.preview.unavailable` (still the
copy for `.unavailableOnThisDevice`) · `workboard.material.open` · `workboard.material.reattach.action`
· `workboard.material.syncPending` (the chip the now-inert card still shows).

---

## Requests

1. **fix2-audio-card (or the serial integrator) — route `WorkboardAudioCardPresentation` through the
   policy, so availability is decided in exactly one place.** Three one-line changes in
   `WorkboardAudioCardView.swift`, all behaviour-preserving today:
   - `showsOpenAction(availability:hasOpenAction:)`: `availability.isAvailable && hasOpenAction` →
     `WorkboardCardActionPolicy.allows(.open, when: availability) && hasOpenAction`.
   - `isPlayable`: `material.availability.isAvailable` →
     `WorkboardCardActionPolicy.allows(.play, when: material.availability)`.
   - `chip(for:hasReattachAction:)`'s `.unavailableOnThisDevice` arm: gate the `.reattach` answer on
     `WorkboardCardActionPolicy.allows(.reattach, when: availability) && hasReattachAction`.
   Why: `isAvailable` and the policy agree today by construction, but they are two statements of one
   rule. The next availability state (a partial download, say) has to be decided once, and the
   exhaustive switch in `WorkboardCardActionPolicy.actions(for:)` is what makes that unavoidable.
   **The canvas already passes `onOpen` and `onReattach` for every audio card**, so nothing else is
   needed on my side, and your `.syncPending` chip already agrees with the policy.
2. **Serial copy agent — one new key to splice** (§Catalog):
   `workboard.material.preview.syncPending`. Until then it renders from its `defaultValue`, which is
   correct English but invisible to the catalog. The sentence is mine, written to sit beside
   `workboard.material.preview.unavailable` and to promise nothing about when — a founder copy call if
   they want one.
3. **Whoever owns `WorkboardLiveRepository` / `WorkboardMaterialSnapshot` — carry the stored filename
   onto the snapshot and the preview copy gets the recording's real `.m4a`.** Today the snapshot has
   `name` (a title) and `mimeType`, so the extension is derived from the mime type — correct and
   playable, but `audio/mp4` prefers `mp4`. `WorkMaterial.filename` already holds `voice-note.m4a` on
   the row. Not urgent, not a defect.
4. **Serial integrator — the availability GLYPH/TINT/LABEL mapping is still duplicated** between
   `WorkboardSourceCard` (`availabilityGlyphName` / `availabilityGlyphTint` / `availabilityLabel`) and
   `WorkboardAudioCardView`'s chip. audio-card §Requests 4 raised it first; this wave shared the ACTION
   rule and deliberately left the copy rule alone (it is presentation, in two files, one not mine). A
   `WorkboardAvailabilityChip` in `WorkboardComponents.swift` consumed by both would close it.
5. **Nobody put the availability test back at a call site.** The board hands both seams to both cards
   unconditionally and the CARD asks the policy; the router asks it again at its own boundary. A call
   site that pre-filters by availability is a second copy of the rule and reintroduces exactly the
   ui#1 shape — one surface offering what another refuses.
6. **Nobody let `present` open bytes the policy refuses.** The guard is the first statement in its
   `do` block precisely so a new `kind` arm added below it inherits the refusal instead of having to
   remember it.

## Refuted

**Nothing.** All three UI findings and the test-lens item held against the current code; each is traced
in §1–§3 to the line that made it true.
