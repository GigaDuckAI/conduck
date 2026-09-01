# desk-intents — plan §A intents retarget + desk-UUID drift guard (Codex #10e)

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. **No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. No pbxproj edit (both new/edited files sit in synchronized groups; the watch test file already existed).

Files edited — exactly the four I own:
- `Conduck/Conduck/Intents/CaptureWorkboardIntent.swift`
- `Conduck/ConduckWatch Watch App/WorkboardCaptureIntent.swift`
- `Conduck/ConduckWatchTests/ConduckWatchSmokeTests.swift`
- `Conduck/ConduckTests/WorkboardDeskIdentityDriftTests.swift` (NEW)

---

## 1. iOS `CaptureWorkboardIntent` — retargeted to the desk

**Before:** `ConversationStore.shared.createWorkItem(WorkItemDraft(content: WorkItemContent(title:objective:)))` — every Siri/Shortcut run minted a fresh project row and put the person's words in a WorkItem *objective*.

**Now:** one note material on the desk, through the authoritative op:

```swift
let record = try await ConversationStore.shared.upsertDeskMaterial(
    WorkMaterialDraft(
        kind: .note,
        title: title,
        textContent: normalized,
        storageMode: .metadataOnly,
        sourceDevice: SourceDevice.current
    )
)
return .result(value: record.title, dialog: IntentDialog(stringLiteral: confirmation))
```

**Identifiers STABLE — nothing an installed Shortcut binds to moved:** type name `CaptureWorkboardIntent`; `static var title` = `intent.workboardCapture.title`; `IntentDescription` = `intent.workboardCapture.description`; `supportedModes = [.background]`; the single `@Parameter var thought` with `intent.workboardCapture.thought`; `parameterSummary` still `Summary("Add \(\.$thought) to Work")` (the macro-composed key plan §B protects); the `AppShortcuts.swift` entry untouched (I did not open that file). The returned `value` is still a `String` and still the card's title, so a chained Shortcut keeps working.

**Unchanged behaviour kept verbatim:** CRLF/CR normalisation + trim, empty refusal, the `WorkCaptureEnvelope.maximumNoteCharacters` refuse-don't-truncate bound, the first-non-empty-line ≤72-char title with the `workboard.item.untitled` fallback, and the `CaptureWorkboardIntentError` cases and their three keys.

**Decisions:**
- **Material id is minted per run (`UUID()` default), not derived from the text.** There was no material-id derivation here before (the old lane minted a WorkItem id), so nothing installed can depend on one. Two runs carrying the same words are two cards the person asked for; deriving an id from the text would silently swallow the second. The id is still what `upsertDeskMaterial` keys idempotency on, so a retry of one invocation cannot double-post. Comment states this at the call site.
- **No `sequence` passed.** The op decides rank inside its write transaction (desk-upsert.md §2); a headless lane has no honest rank.
- **No `expectedOwnerRevision`.** Per desk-upsert.md, headless callers pass nil — a CAS refusal here would drop a capture the person already made.
- **`storageMode: .metadataOnly` stated explicitly** (matches the drainer/chat note drafts even though the draft's own default would arrive at the same value with `payload == nil`).
- **`sourceDevice: SourceDevice.current`** — same as `ConverseIntent`, so the card carries provenance like every other capture.

---

## 2. Watch `WorkboardCaptureIntent` — fetch-desk-then-upsert in ONE context

`ConversationStore.createInertWatchWorkboardCapture(_:id:createdAt:)` is **renamed and rewritten** as `ConversationStore.upsertDeskMaterial(_ capture: WatchWorkboardCapture, id: UUID = UUID(), createdAt: Date = Date()) -> String`. Same name as the app op deliberately (different parameter type; the app's extension is not in this target, so there is no overload to be ambiguous with). Its only two callers were my own files.

Everything happens inside ONE `context.perform` on one `newWriteContext()`:
1. fetch `WorkItem` by the desk id (`updatedAt` DESC, `fetchLimit 1` — the same ordering `workItemRow(id:in:)` uses, so several physical CloudKit rows resolve the same way as on the phone); create it if absent with **only** `id`/`createdAt`/`updatedAt` — title/objective/context/constraints stay nil columns.
2. fetch `WorkMaterial` by `draft` id; if present, return its title unchanged (and save only when this call had just created the desk row — a material can arrive from CloudKit before its owner).
3. otherwise read the append rank (`workItemID == desk`, `sequence` DESC, limit 1, `+1`), insert the `WorkMaterial`, advance the desk's `updatedAt`, `save()` once.
`postDidChange()` fires after the transaction, as before.

Row written: `kind "note"` · `title` · `caption ""` · `textContent` = the thought · `byteSize 0` · `sequence` · `storageMode "metadataOnly"` · `sourceDevice "watch"` (the wrist's existing literal, cf. `WatchAudioUploader.swift:1270`) · `createdAt`/`updatedAt`. `cardSize` is deliberately left nil — `WorkMaterialCardSize.storedValue` makes `standard` the absent value.

**Kept:** the intent's identifiers (identical to the iOS list above), `WatchWorkboardCapture`, `WatchWorkboardCaptureText.prepare` with the **16 000-character cap** and its mirror comment, `WatchWorkboardCaptureError` and all four string keys.

**Restated-literal accounting.** The entity/column names and the `kind`/`storageMode` raw values are restated on the wrist because `WorkboardRecords.swift` and `ConversationStore+Workboard.swift` are not members of that target; the file header names `WorkboardRecords.swift` as canonical for the raw values. `WorkCaptureEnvelope.maximumNoteCharacters` keeps its existing mirror.

### DEVIATION (deliberate, Codex-confirmed): the desk id is NOT mirrored as a watch literal

**The watch reads `Constants.workboardDeskItemID` directly.** Plan §A and my brief call for a mirrored literal plus a literal-vs-literal drift guard, on the stated ground that the watch target cannot reach the canonical value. **That ground is false.** `Conduck.xcodeproj/project.pbxproj`, in *"Exceptions for \"Conduck\" folder in \"ConduckWatch Watch App\" target"*, lists `Utilities/Constants.swift` among its `membershipExceptions` — Constants.swift IS compiled into the watch app target, the desk-id declaration sits inside no `#if` guard, and watch code already reads the type (`WatchAudioUploader.swift:25` → `Constants.identityNamespace`; `ConduckWatchSmokeTests`' `OfficialIdentityWatchLockTests` too). What the watch genuinely cannot reach is `ConversationStore+Workboard.swift` — which is why the raw Core Data logic is duplicated, and only that.

The repo's own precedent agrees: `ConduckTests/RelayWireSourceDriftGuardTests.swift` exists *because* that enum is unshareable, and its header says to retire the guard "when the two copies are replaced by one shared-constants source — at which point drift becomes impossible." For the desk id that shared source already exists.

I spent my one Codex consult on exactly this call (`codex exec --sandbox read-only`, read-only, it re-verified the pbxproj itself). Verdict, verbatim: *"**Choose B.** The plan's rationale is factually wrong… No watchOS, AppIntents, or Core Data constraint makes a literal preferable. `perform()` is ordinary async Swift code, and Core Data accepts runtime UUID values. Use `Constants.workboardDeskItemID` directly. Make the guard require that reference and reject the canonical UUID string in the Watch file."*

The guard was written to that shape, so the drift the plan feared is now **impossible rather than merely detected**. Measured today: `grep -ril "DE5C0000-0000-4000-A000-000000000001"` over `Conduck/`, `ConduckWatch Watch App/`, `ConduckTests/`, `ConduckWatchTests/` returns exactly one file — `Conduck/Utilities/Constants.swift`.

---

## 3. `WorkboardDeskIdentityDriftTests` (NEW, iOS, 2 cases)

`Conduck/ConduckTests/WorkboardDeskIdentityDriftTests.swift`, house pattern from `RelayWireSourceDriftGuardTests` — sources read off disk via `#filePath` so it is independent of the runner's cwd.

| Case | Asserts |
|---|---|
| `testTheDeskIdentityLiteralExistsOnlyInConstants` | `Constants.swift` on disk contains `Constants.workboardDeskItemID.uuidString`, and of every `.swift` file under `Conduck/` **and** `ConduckWatch Watch App/`, the set that contains that string (case-insensitively) is exactly `["Constants.swift"]` |
| `testTheWatchCaptureIntentNamesTheCanonicalDeskConstant` | the watch capture intent source contains `Constants.workboardDeskItemID` and contains no `UUID(uuidString:` |

Non-vacuous by construction: case 1 fails if the enumeration finds nothing, and it passed while finding `Constants.swift`. The test file itself never spells the UUID out — it compares against the runtime value — so it cannot become its own false positive.

## 4. Watch smoke assertions (in the EXISTING `ConduckWatchSmokeTests.swift`, no new watch file)

`testWorkboardCapturePersistsOnlyAnInertBrief` is **rewritten, not weakened**, as `testWorkboardCapturePersistsOnlyAnInertNoteOnTheDesk`: the old assertions (`WorkItem.title == capture.title`, `objective == capture.objective`) asserted the *pre-desk* truth and are now false by design. It still asserts zero `WorkDispatch`/`Conversation`/`Message` and adds: exactly one `WorkItem`, its `id == Constants.workboardDeskItemID`, its `title`/`objective`/`preferredGatewayRef` all **nil**, and exactly one `WorkMaterial` carrying `workItemID == desk`, `kind "note"`, the title, the thought in `textContent`, `storageMode "metadataOnly"`, `sequence 0`, `sourceDevice "watch"`.

Two new cases:
- `testSecondWatchCaptureAppendsToTheSameDeskInsteadOfCreatingASecondOne` — two captures → ONE `WorkItem` at the fixed id, two materials in insertion order with sequences `[0, 1]`, both owned by the desk.
- `testReplayingOneWatchCaptureReturnsTheSameCardWithoutASecondRow` — the same material id replayed with different text returns the FIRST card's title and leaves 1 item / 1 material.

**Watch suite delta: +2 cases** (3 where there was 1).

---

## 5. Gates run — exact lines

Slug `desk-intents`, derivedData `~/Library/Caches/gigaduck-builds/desk-intents/DerivedData`, every log written there and grepped (never judged from tail or exit code). No `-configuration` passed anywhere.

- **iOS `build-for-testing`**, sim `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC` → `bft-1.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, three quoted `-only-testing:` flags → `test-1.log`, `** TEST EXECUTE SUCCEEDED **`:

| Class | Result |
|---|---|
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.428 (0.429) seconds` |
| `WorkboardDeskIdentityDriftTests` | `Executed 2 tests, with 0 failures (0 unexpected) in 0.888 (0.888) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 10 tests, with 0 failures (0 unexpected) in 0.080 (0.082) seconds` |
| **total** | `Executed 17 tests, with 0 failures (0 unexpected) in 1.396 (1.400) seconds` |

- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 764 Swift files scanned, no raw store or live-adapter access outside …LiveStorage.swift`.
- `git diff --check` → clean.
- **iOS suite delta: +2 cases** (`WorkboardDeskIdentityDriftTests`). New file in the `ConduckTests` synchronized group; it compiled and ran with **no pbxproj edit**.

### Watch

- **`ConduckWatchTests` scheme, full watch suite**, sim `28AC563B-42C1-4E66-940D-77E63B07918B` → `watch-test-1.log`: `grep -c ': error: '` = **0**, `** TEST SUCCEEDED **`, `Executed 231 tests, with 0 failures (0 unexpected) in 9.412 (9.486) seconds`. Baseline was 229 → **+2, as predicted**. `Test Suite 'ConduckWatchSmokeTests' passed` — `Executed 6 tests, with 0 failures (0 unexpected) in 0.017 (0.018) seconds`, and each desk case named individually in the log: `testWorkboardCapturePersistsOnlyAnInertNoteOnTheDesk]' passed (0.004 seconds)` · `testSecondWatchCaptureAppendsToTheSameDeskInsteadOfCreatingASecondOne]' passed (0.005 seconds)` · `testReplayingOneWatchCaptureReturnsTheSameCardWithoutASecondRow]' passed (0.005 seconds)`. This scheme does **not** build the iOS app target, which is why it ran clean.

### The one gate I could NOT get green — and it is not mine

- **`xcodebuild build -scheme 'ConduckWatch Watch App'`** on the same watch sim → `** BUILD FAILED **`, **20 `: error:` lines, every one of them in `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift`** (`:61`, `:62`, `:65-67`, `:74-75`, `:80-83`, `:92-93`, `:100`, `:251`). That scheme also builds the `Conduck` iOS target, which is where they come from. The signature error is:

  `WorkboardLiveRepository.swift:61:40: error: incorrect argument label in call (have 'loadItems:importMaterial:removeMaterial:replaceMaterial:openConversation:openMaterial:openGatewaySettings:reorderMaterials:setMaterialCardSize:', expected 'loadDesk:importMaterial:…')`

  followed by an arity/type cascade (`cannot convert value of type 'Int64' to expected argument type 'UUID'`, `'@concurrent @Sendable (Int64, UUID, UUID) …' to '@MainActor @Sendable (Int64, UUID) …'`, and `:251:30: error: extra arguments at positions #4, #5, #6, #7, #8, #10, #11, #12, #13, #15 in call`) — a half-landed `WorkboardViewModel.Dependencies` rename in another agent's file.

  Per the parallel-phase rule I waited 130 s and retried once (`watch-build-2.log`): **identical, same 20 errors, same file, zero errors anywhere else**. I did not touch that file. Evidence that my own watch code is fine: in the FIRST watch build the `ConduckWatch Watch App` target compiled `WorkboardCaptureIntent.swift` for **both** arm64 and x86_64 with **zero errors** (`SwiftCompile normal arm64 … WorkboardCaptureIntent.swift (in target 'ConduckWatch Watch App' from project 'Conduck')`), and the watch test bundle then built and ran the full suite green. The retry was incremental, so the watch target was not recompiled in it.

  My iOS `build-for-testing` (19:48) was green **before** those edits landed; the failures first appear at 19:52. Serial integration owns this.

- Build cache removed at end of task: `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh desk-intents`. The four logs (`bft-1.log`, `test-1.log`, `watch-build-1.log`, `watch-build-2.log`, `watch-test-1.log`) no longer exist — re-run if you need them.

---

## Call-site touches

**NONE.** I edited no file outside the four I own. `AppShortcuts.swift`, `WatchAppShortcuts.swift`, `Constants.swift`, `ConversationStore+Workboard.swift` and `WorkboardRecords.swift` were read but never opened for edit.

---

## Catalog

**Keys I ADDED in source: NONE.** Both intents were retargeted without new user-facing copy; every string they emit is a key that already existed.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key. `workboard.item.untitled` is still reached from BOTH intents (it is the empty-first-line title fallback), so the post-purge audit must keep it.

**Copy that is now product-false but which I deliberately did not touch** (parallel phase = no `.xcstrings` edit, and plan §B sanctions exactly four copy rewrites, none of them these). Default values in source still read:
- `intent.workboardCapture.description` = "Save a thought as a private Workboard draft without sending it to an AI." — it is no longer a *draft* and "Workboard" is the retired word.
- `intent.workboardCapture.confirmation` = "Added to Workboard. Nothing was sent." — same word; the second sentence is still exactly true and worth keeping.
- `workboard.item.untitled` = "Untitled brief" — plan §B already lists this key for rewrite; it now titles a *card*, not a brief.
Both intents carry these three keys identically (iOS + watch), so a rewrite must change SOURCE default values in both files and the catalog entry in one step.

---

## Requests

1. **Copy / catalog agent (serial phase):** rewrite the three keys listed just above in `Localizable.xcstrings` **and** in both intent sources at once — `Conduck/Conduck/Intents/CaptureWorkboardIntent.swift` and `Conduck/ConduckWatch Watch App/WorkboardCaptureIntent.swift` hold byte-identical `defaultValue:` strings for `intent.workboardCapture.{description,confirmation}` and for `workboard.item.untitled`. Do NOT rename the keys: `intent.workboardCapture.*` is Shortcut-facing identity.
2. **foundation / whoever owns `Constants.swift`:** the doc comment on `workboardDeskItemID` says *"The Watch target mirrors this literal locally (it does not compile the store extension); a drift-guard test compares the two."* That is now false in its first clause and misleading in its second — the watch reads this very constant, and `WorkboardDeskIdentityDriftTests` asserts that no copy exists anywhere. Suggested replacement for those two sentences: *"`Constants.swift` is a member of the Watch target too, so every surface reads this value rather than a copy; `WorkboardDeskIdentityDriftTests` fails if the literal is ever restated outside this file."* I did not edit `Constants.swift` — it is not mine.
3. **Orchestrator:** plan §A's "Mirrored as a literal into the Watch target" is refuted by the project file (see §2 deviation). The drift guard exists and is stronger than the planned one; nothing else in §A depends on the mirror. Codex was consulted and concurred. `docs/qa/desk-cloudkit/plan.md` is off-limits to me, so the correction lives only here.
4. **`WorkboardLiveRepository.swift` owner (retarget agent):** at the time of my watch build that file did not compile — 20 `: error:` lines, all in it, all shaped like a half-landed `Dependencies` rename (`incorrect argument label in call (have 'loadItems:…', expected 'loadDesk:…')`, plus a cascade of arity/type mismatches at `:61-100` and `:251`). It is mid-edit, not broken by me; my iOS `build-for-testing` was green minutes earlier and the watch app target itself compiled my file with zero errors in the same run. Full list in §5.
5. **Test-count bookkeeping:** iOS **+2** (`WorkboardDeskIdentityDriftTests`), watch **+2** (smoke file 1 → 3 Workboard cases). `createInertWatchWorkboardCapture` no longer exists — nothing outside my files called it.
6. **Anyone adding a Workboard surface to the watch:** `ConversationStore.upsertDeskMaterial(_ capture:id:createdAt:)` in `ConduckWatch Watch App/WorkboardCaptureIntent.swift` is the wrist's only desk write and mirrors the app op's contract for the note shape. A future watch voice→Work lane (plan: out of scope) should extend it rather than open a second raw-Core-Data path.
