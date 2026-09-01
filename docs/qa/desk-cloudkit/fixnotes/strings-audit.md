# strings-audit — plan §B bidirectional zero-reference audit. DONE (audit clean). **The tree I inherited does not build, and it is not mine — see §6.**

Serial, alone in the tree. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. Slug `desk-strings-audit` cleaned (`removed: desk-strings-audit`).

Headline numbers: main catalog **2402 → 2241** keys (**−169, +8**). Three other catalogs unchanged (43 / 42 / 299). After my edits the audit is clean in **both** directions in **all four** catalogs: zero Work-family keys with no source reference, zero source-referenced keys missing from their target's catalog.

---

## 1. What changed (file + symbol)

| File | Change |
|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | −169 keys (§2), +8 keys (§3). Raw-line splice, formatting preserved, `json.load`-validated. |
| `Conduck/Conduck/Views/Workboard/WorkboardComponents.swift` | Deleted `WorkboardMaterialRoute` (whole enum), `WorkboardMaterialActions.Presentation.row`, `cameraAvailable`, `rowRoutes`, the `.row` switch arm, `action(for:)`, `label(for:)`, `WorkboardMetrics.cardCornerRadius`, and the now-unused `#if os(iOS) import UIKit #endif`. Rewrote the `WorkboardMaterialActions` doc comment (present-tense constraint, no narration) and documented why `onAddNote` survives. **93 deletions, 8 insertions.** |

Nothing else is modified by me. `WorkboardSurface` **KEPT** (plan §B calls it the desk container; integrate-a §Requests 3 says the shipped desk draws no container — still a founder decision, still flagged, §Requests 2).

### `cameraAvailable` — one deletion beyond my brief's list, stated plainly
My brief named the `.row` arm, `rowRoutes`, `action(for:)`, `label(for:)`, `WorkboardMaterialRoute` and `cardCornerRadius`. `cameraAvailable` was read **only** by `rowRoutes`, so it died with it; `import UIKit` was read only by `cameraAvailable`. `AttachmentMenu` keeps its own independent `cameraAvailable` (`AttachmentMenu.swift:83`) and is unaffected.

### Two things I deliberately did NOT do in that file
- **`Presentation` still exists as a one-case enum and the `presentation:` parameter is still threaded.** Collapsing it means editing `WorkboardCaptureCanvas.swift:419`, which I do not own.
- **`onAddNote` is kept.** With `.row` gone, `AttachmentMenu` has no note route, so `onAddNote` now has no reachable trigger — meaning **the desk's "Add Note" composer is unreachable**. It was *already* unreachable before my edit (the single call site has always passed `.menu`); I did not create the gap and I did not entrench it by deleting the seam. Flagged as §Requests 3 because it is user-facing, not cosmetic.

## 2. The 169 deleted keys, by evidence class

Method, run over the **whole worktree minus `docs/`** (971 files: `.swift`, `.plist`, `.strings`, `.stringsdict`, `.intentdefinition`, `.json`, `.pbxproj`, `.xcstrings`, `.entitlements`, `.storyboard`, `.xib`, `.h`, `.m`, `.sh`, `.py`), matching the quoted literal `"<key>"` against full file text (so a key split across lines inside `String(localized: LocalizedStringResource(\n"key",` is still caught). I also swept for dynamically composed keys — `String(localized: "…\(…)")`, `LocalizedStringResource(<non-literal>)`, `"prefix." + x` — and found **no** constructed Work key anywhere.

**(a) 164 fixnote candidates — every one confirmed zero-reference** (purge-core 124 · views-core 27 · capture-canvas 6 · chat-capture 3 · desk-drainer 2 · desk-detail 2). Not one of the 164 had a reference in Swift, in a test, or in any non-Swift surface; their only occurrences repo-wide were the catalog row itself and the fixnote prose under `docs/`. Full list = the six fixnotes' `## Catalog` dead-key lists, unchanged.

**`common.settings` — cleared for deletion, with the checks views-core asked for.** It exists in **only** the main catalog (absent from both appex catalogs and from the Watch catalog), has zero references in the Watch target's Swift, zero in `ConduckWatch/` (the `ConduckWatchExtension` target), zero in either appex, and zero in every non-Swift file scanned. Deleted.

**(b) 4 keys retired with the dead `.row` code** — grep-live before my sweep, zero-reference after it, exactly the trap integrate-a §Requests 2 and integrate-b flagged:

| Key | en value | Was read by |
|---|---|---|
| `workboard.material.addPhotos` | `Photos` | `WorkboardMaterialRoute.title` |
| `workboard.material.addFiles` | `Files` | `WorkboardMaterialRoute.title` |
| `workboard.material.addLink.short` | `Link` | `WorkboardMaterialRoute.title` |
| `workboard.material.addNote.short` | `Note` | `WorkboardMaterialRoute.title` |

**Three keys in that same enum were NOT deleted** because they have live readers elsewhere, and a naive "the enum died" sweep would have killed them: `composer.attach.takePhoto` (2 refs, `AttachmentMenu.swift:148,153`), `workboard.material.addLink` (3 refs, `AttachmentMenu.swift:192,197` + `WorkboardTextMaterialSheet.swift:91`), `workboard.material.addNote` (1 ref, `WorkboardTextMaterialSheet.swift:92`).

**(c) 1 bare-English AppShortcut row** — `"Brief My Workboard"`. Evidence is git, not grep: at `651a859` it was the `shortTitle:` literal of the `BriefWorkboardIntent` `AppShortcut` (`AppShortcuts.swift:52`) that purge-core removed. Zero references now. The two phrases purge-core listed beside it (`Brief my Workboard in ${applicationName}`, `What needs me in ${applicationName}`) were **never catalog rows** — the main catalog carries no `${applicationName}` key at all — so there was nothing to delete.

### Traps honoured
- **`Add ${thought} to Work` SURVIVES.** Zero grep hits by design (macro-composed from `Summary("Add \(.$thought) to Work")`). Present in the main **and** Watch catalogs; the `…to Workboard` variant is absent from both. `WorkCaptureInboxTests.testBothCaptureIntentsNameWorkInTheirTitleAndTheirParameterSummary` guards this and passed.
- **Extension catalogs: nothing deleted.** Verified the five picker keys (`share.work.new`, `.new.detail`, `.section.destination`, `.section.recent`, `.untitled`) are already absent from **both** appex catalogs and that `share.work.desk.detail` is present in both — share-mac/share-ios did that work; I re-checked and touched nothing (integrate-b §Requests / share-mac §Requests 3).
- **Watch catalog: nothing deleted.** All 7 of its Work-family keys have live Watch-target references.

## 3. The 8 keys I ADDED (the backward direction, and it was not empty)

The backward sweep found **8 keys referenced in main-app source with no catalog row** — the ADDED sets that audio-card and audio-capture correctly deferred to the serial pass. I own the catalog, so I landed them. Each value copied verbatim from the `defaultValue:` the source declares and re-compared character-for-character after insertion (curly apostrophe in `couldn’t` included).

| Key | en value | Declared in |
|---|---|---|
| `workboard.audio.play` | `Play` | `WorkboardAudioCardView.swift:787` |
| `workboard.audio.pause` | `Pause` | `WorkboardAudioCardView.swift:786` |
| `workboard.audio.playing` | `Playing` | `WorkboardAudioCardView.swift:823` |
| `workboard.audio.paused` | `Paused` | `WorkboardAudioCardView.swift:828` |
| `workboard.audio.loading` | `Loading` | `WorkboardAudioCardView.swift:818` |
| `workboard.audio.failed` | `This recording couldn’t be played` | `WorkboardAudioCardView.swift:565,833` |
| `workboard.audio.position` | `%1$@ of %2$@` | `WorkboardAudioCardView.swift:550` |
| `workboard.voice.recording.untitled` | `Voice note` | `WorkVoiceCaptureCoordinator.swift:104` |

Placed alphabetically inside the sorted `workboard.*` block: the seven `workboard.audio.*` between `workboard.action.moveLater` and `workboard.briefing.clear`; `workboard.voice.recording.untitled` between `workboard.voice.privacy` and `workboard.voice.starting`. `workboard.audio.position` keeps both positional placeholders.

**Method (matters for the next catalog editor).** The file is Xcode-formatted (`"key" : {`, 4-space key indent, 6/8/10/12 for the nest) and its `workboard.*` block is case-insensitively sorted while the file as a whole is not. A `json.dump` would rewrite all 25k lines, so I did a **raw-line splice**: parse to find each key's exact line span by brace depth, drop those lines, insert new blocks built from a neighbour's shape (`extractionState: extracted_with_value`, one `en` `stringUnit`, `state: new`). Verified afterwards by loading the before/after JSON and asserting the after-dict equals `before − 169 + 8` **with zero value differences on any untouched key**. Do not be alarmed by `git diff --numstat` reading `234 / 2045` on the catalog: git realigns identical lines across the large deleted region, and the dict comparison proves no untouched entry moved or changed.

## 4. What I ran, and the exact result lines

Slug `~/Library/Caches/gigaduck-builds/desk-strings-audit/`, six logs, all grepped for `error:` and the verdict strings, all cleaned at the end.

**`ios-bft-1.log` — the tree AS I FOUND IT, before I edited anything:**
```
** TEST BUILD FAILED **
…/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
…/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```
Two errors, both in one file, neither related to anything I own. See §6.

**`ios-bft-5-final.log` — the tree I am HANDING BACK:** byte-identical verdict, the **same two errors and no others**. My edits introduce zero errors and remove zero errors.

**Because a red tree proves nothing about my diff, I ran a throwaway PROBE** (§5): I added the missing `WorkboardMaterialKind.audio` case and the four exhaustive-switch arms it forces, built, ran the full suite, then **reverted the probe byte-exactly**.

- `ios-bft-4-probe.log`: `** TEST BUILD SUCCEEDED **`, 0 `error:` lines. **So nothing anywhere in the app or test targets still references `WorkboardMaterialRoute`, `Presentation.row`, `rowRoutes`, `action(for:)`, `label(for:)` or `cardCornerRadius`.**
- `ios-test-1-probe.log`, full iOS suite (`test-without-building`, sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1`):
```
Executed 4798 tests, with 1 test skipped and 5 failures (0 unexpected) in 93.124 (98.114) seconds
```
Every string/catalog guard **passed**:

| Class | Result |
|---|---|
| `WorkCaptureInboxTests` (six-file lockstep + intent-summary catalog guard) | `Executed 30 tests, with 0 failures (0 unexpected)` |
| `CarPlayVoiceTimingContractTests` (reads `Conduck/Localizable.xcstrings`) | `Executed 22 tests, with 0 failures (0 unexpected)` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected)` |
| `WorkboardMaterialBoardActionsTests` | `Executed 12 tests, with 0 failures (0 unexpected)` |
| `WorkboardMaterialPresentationTests` | `Executed 4 tests, with 0 failures (0 unexpected)` |
| `WorkboardDeskSurfaceDriftGuardTests` | `Executed 4 tests, with 0 failures (0 unexpected)` |
| `MacWorkbenchShellDriftGuardTests` | `Executed 4 tests, with 0 failures (0 unexpected)` |

The 5 failures were **3 caused by my probe** (`WorkboardLiveRepositorySupportTests`, §6) and **2 assertion lines in one test that my probe cannot touch**: `WorkCaptureDrainerDurabilityTests.testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon` (`:233` "the claimed directory is never requeued underneath the drainer reading it", `:297` "The claim's lease was never renewed while its import was still running"). **That one is pre-existing and unattributable to me** — I changed no lease, drainer or inbox code.

**macOS build: NOT RUN.** My brief names only the iOS sim, and the tree cannot build on any platform until §6 is resolved. It stays an orchestrator gate item.

**Gates:** `git diff --check` clean. All four catalogs `json.load` clean (2241 / 43 / 42 / 299). Mirror triplets untouched — `git status --short` on `*WorkCaptureEnvelope.swift` and `*ShareTargetsSnapshot.swift` returns 0 lines.

## 5. The probe, and proof it left nothing behind

Files touched by the probe and then restored: `ViewModels/WorkboardViewModel.swift`, `Services/Workboard/WorkboardLiveRepository.swift`, `Views/Workboard/WorkboardComponents.swift` (restored from byte snapshots taken before the probe — `cmp` reports **IDENTICAL** for all three) and `Views/Workboard/PersonalWorkbenchView.swift` (one-line `case .file, .audio:` → `case .file:`, reverted by exact string replace; `git diff` now shows no row for it). A repo-wide grep confirms the only `.audio` occurrences left in those four files are the **two that pre-date me** (`WorkboardLiveRepository.swift:289,306`). `git status --short` is 19 entries, of which mine are exactly two: `Localizable.xcstrings` and `WorkboardComponents.swift`.

## 6. BLOCKER — the audio slice is unfinished, and nobody owns it

`WorkboardMaterialKind` (`ViewModels/WorkboardViewModel.swift:20`) has no `case audio`, but `WorkboardCaptureCanvas.swift:1170` (`material.kind == .audio`) and `:1632` (`case .image, .file, .audio:`) require one. audio-capture §Requests 1 assigned it to the card-UI agent; audio-card §Catalog answered "not mine to add, but owed by the enum case". **Both punted, so the tree has not compiled since the audio wave landed** — before I touched it.

**It is not the one-line fix both fixnotes imply.** My probe walked it out: adding `case audio` forces arms in **four** more places (`WorkboardMaterialIcon.tint`, `WorkboardLiveRepository.presentationKind` + `materialName` + `storageKind` + the `publishWorkMaterial` payload switch at `:399`, and `PersonalWorkbenchView.present(_:)` at `:389`) — and then it **fails three tests that assert the opposite design**:

```
WorkboardLiveRepositorySupportTests.swift:105: XCTAssertEqual failed: ("audio") is not equal to ("file")
   - a stored audio draws as a file card
WorkboardLiveRepositorySupportTests.swift:131: … - every stored kind resolves; a new one must be given a shape here
WorkboardLiveRepositorySupportTests.swift:176: XCTAssertEqual failed: ("Voice note") is not equal to ("File")
   - a nameless recording is named by the shape it draws as, not by its stored kind
```

So this is a **genuine cross-slice design disagreement**, not a missing enum case: the repository slice decided a stored `.audio` **narrows to the `.file` card shape**, while the audio-card slice built `WorkboardCaptureCanvas` around a **presentation-level `.audio` shape**. One of the two has to give, and both the test assertions and the card's own routing are load-bearing. That is a product/architecture call on files I do not own, at the wrong end of a strings audit, so I stopped and reported rather than guessing. §Requests 1 spells out both options.

## Catalog

**Keys I ADDED in source: NONE.** I wrote no new user-facing copy. My brief scopes me to the audit; the sanctioned copy rewrites (plan §B, §E) are still owed — §Requests 4.

**Keys I ADDED to `Conduck/Conduck/Localizable.xcstrings` (8):** the table in §3 — `workboard.audio.{play,pause,playing,paused,loading,failed,position}` and `workboard.voice.recording.untitled`. All eight are `key = defaultValue` copies of what SOURCE already declares; none is new copy.

**Keys I found DEAD and DELETED (169):** the 164 fixnote candidates + `workboard.material.{addPhotos,addFiles,addLink.short,addNote.short}` + `Brief My Workboard`. Evidence class per key in §2.

**Keys I found DEAD but did NOT delete: NONE in the Work family.** A full sweep of all 2402 pre-edit main-catalog keys found 370 with no reference outside `docs/`; **163 of those were Work-family and all 163 were already on my candidate list** — there was no Work-family dead key the six fixnotes had missed. The other ~206 are **pre-existing, non-Work debt and mostly FALSE positives**: they are interpolated literals whose catalog key is the formatted form (`%@ is answering…` ← `String(localized: "\(name) is answering…")`, `Downloading… %lld%%`, `Add %@ to your Watch`, …). **Nobody should run a blanket zero-reference deletion over this catalog** — that class of key looks dead to every grep and is live at runtime. §Requests 5.

**Catalog key counts, before → after:**

| Catalog | Before | After |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2402 | **2241** |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 | 43 (untouched) |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 | 42 (untouched) |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 | 299 (untouched) |

---

## Requests

1. **Orchestrator / audio owner — BLOCKING, nothing else can be gated until this lands (§6).** Decide which side of the `.audio` disagreement wins:
   - **(a) Presentation-level `.audio`** (what `WorkboardCaptureCanvas` was built for): add `case audio` to `WorkboardMaterialKind` with `title` → `LocalizedStringResource("workboard.material.audio", defaultValue: "Voice note")` and `systemImage` → `"waveform"`; add arms in `WorkboardMaterialIcon.tint` (`WorkboardComponents.swift:113` — `case .image, .note, .audio`), `WorkboardLiveRepository.presentationKind` (`:303`), `materialName` (`:328`), `storageKind` (`:470`), `publishWorkMaterial`'s payload switch (`:399` — `case .image, .file, .audio`), and `PersonalWorkbenchView.present(_:)` (`:389` — `case .file, .audio`). Then **rewrite the three `WorkboardLiveRepositorySupportTests` assertions** at `:105`, `:131`, `:176`, which currently encode the opposite contract — that is an assertion change a human must sanction, which is why I did not make it. **Then add `workboard.material.audio` = `Voice note` to the main catalog** (I did not add it: with no source reference it would be a brand-new dead key, which is exactly what I was sent to remove).
   - **(b) Keep `.audio → .file` narrowing** (what the tests assert): change `WorkboardCaptureCanvas.swift:1170` to route the audio card off something other than `material.kind` — the stored kind, or a snapshot flag — and drop `.audio` from `:1632`. No enum change, no test change, no new key.
   I verified (a) compiles and that (b) is untested by me.

2. **Founder decision, still open and now the only thing left in `WorkboardComponents.swift`: `WorkboardSurface`.** Zero consumers. Plan §B names it "the desk container"; the shipped desk draws no container. Adopt it or delete it — I kept it because the plan beats my judgement, and because a silent deletion would foreclose the plan's own design. This is the third fixnote to raise it (capture-canvas §Requests 1, integrate-a §Requests 3).

3. **Product / desk owner — "Add Note" has no reachable entry point on the desk.** `WorkboardMaterialActions` mounts `AttachmentMenu`, which offers photos / camera / files / link but **no note**; `onAddNote` is threaded from `WorkboardCaptureCanvas.swift:434` and never fired. The note composer (`WorkboardTextMaterialSheet` with `kind: .note`, plus `workboard.material.{addNote,note.title,note.body,note.name,note.footer}`) is live code with no door. Either add a note route to `AttachmentMenu` (`purpose: .work` already distinguishes the Work mount) or retire the note composer — it is not a strings decision either way.

4. **Copy phase — the sanctioned rewrites are ALL still owed.** I deleted keys; I rewrote no copy, because every one of these needs source and catalog moved together and several are outside plan §B's four. Consolidated so nothing is lost:
   - `workboard.load.failed.message` = *"Your **projects** stay private and unchanged. Try opening **them** again."* — false on a one-desk product (views-core, desk-detail §Requests 4, store-descriptions §Requests 4).
   - `workboard.item.untitled` = *"Untitled brief"* — the desk's own fallback title; must move in the catalog **and** in both intent sources at once (`Intents/CaptureWorkboardIntent.swift`, `ConduckWatch Watch App/WorkboardCaptureIntent.swift`), which hold byte-identical `defaultValue:` strings. Do **not** rename the key.
   - `intent.workboardCapture.confirmation` = *"Added to Workboard. Nothing was sent."* and `intent.workboardCapture.description` = *"Save a thought as a private **Workboard** draft…"* — same two-source lockstep, same do-not-rename rule (`intent.workboardCapture.*` is Shortcut-facing identity).
   - `ConduckApp.swift:339`, `Button("Workboard")` → `Button("Work")` (mac-shell §Requests 1). The bare literal **is** the key, so the existing empty `Workboard` catalog row goes dead the moment it changes — sweep it then. I left it: the row is live today.
   - `AppShortcuts.swift:50`, phrase `"Add a thought to my Workboard in \(.applicationName)"` — same retired noun, user-facing in Siri.
   - `sync.icloud.banner.{noAccount,restricted,quotaExceeded}` all say *"your conversations"* and the Work desk now renders them verbatim (availability §Requests 2, integrate-b §Requests 3). Widen the three or give the desk its own.
   - `workboard.voice.privacy` (*"…adds editable text to this private draft…"*) and `workboard.voice.stop` (*"Stop and Add Text"*) are false after two-phase audio capture; audio-capture §Requests 3 proposes new keys `workboard.voice.privacy.recording` / `workboard.voice.stop.save` rather than value rewrites — correct, since the catalog's en value wins at runtime.
   - `workboard.tutorial.point.review` — plan §E's sync-truth rewrite.
   **After any of these lands, re-run the audit**: a key whose only reader changes wording can go dead, and a new key must reach the catalog or it silently renders from `defaultValue`.

5. **Nobody run a blanket zero-reference sweep over `Localizable.xcstrings`.** ~206 non-Work keys have no grep reference and are nonetheless live: their catalog key is the *formatted* form of an interpolated literal (`"%@ is answering…"` ← `String(localized: "\(name) is answering…")`). The Work family is now clean; the rest of the catalog needs a formatter-aware tool, not grep, and is pre-existing debt outside this workflow.

6. **Pre-existing test failure for the ledger, not mine:** `WorkCaptureDrainerDurabilityTests.testTheHeartbeatKeepsALongImportOwnedPastTheStaleHorizon` fails on two assertions (`:233`, `:297`) about lease renewal under a long import. Observed under my probe run; I touched no lease, inbox or drainer code. Whoever owns `WorkCaptureDrainerDurabilityTests.swift` (untracked, so it arrived with a recent slice) should confirm whether it is a real regression or a timing-sensitive test.

7. **Watch-extension key with no catalog, pre-existing:** `ConduckWatch/RecordNoteIntent.swift` declares `"Capture a voice transcription with Conduck"`, but the `ConduckWatchExtension` target ships no `Localizable.xcstrings` (the only Watch catalog belongs to `ConduckWatch Watch App`). That file is unmodified since `efa553e`, so this is long-standing, not this workflow's. It renders from its default value; flagging it only because a bidirectional audit is where it becomes visible.

8. **`workboard.material.audio` is the one key deliberately NOT in the catalog.** It becomes owed the moment §Requests 1(a) is chosen, and stays permanently un-owed under 1(b). Do not add it speculatively.
