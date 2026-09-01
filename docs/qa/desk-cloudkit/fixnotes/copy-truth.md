# copy-truth — plan §E copy + docs truth. DONE. **The tree I inherited still does not build, and it is not mine — §5.**

Serial, alone in the tree. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. Mirror triplets untouched (`git status --short` on `*WorkCaptureEnvelope.swift` / `*ShareTargetsSnapshot.swift` = 0 lines). Slug `desk-copy-truth` cleaned (`removed: desk-copy-truth`).

Headline: **13 user-facing strings reworded** (11 keyed, source + catalog in lockstep; 2 bare-English literals whose key IS the string, so the row was replaced), **3 of them mirrored into the Watch catalog**, **9 source comments/headers rewritten to constraints-truth**, and the `spec.md` Work decision rewritten to the shipped end-state. Catalog key counts are UNCHANGED in all four catalogs (2241 / 299 / 43 / 42) — I deleted no key and minted no key.

---

## 1. Every reword: old → new (key kept unless stated)

### Keyed strings — source `defaultValue:` AND catalog `en` value moved together

| Key | Old | New | Source file(s) |
|---|---|---|---|
| `workboard.item.untitled` | `Untitled brief` | `Untitled note` | `Intents/CaptureWorkboardIntent.swift`, `ConduckWatch Watch App/WorkboardCaptureIntent.swift` (byte-identical in both) |
| `intent.workboardCapture.description` | `Save a thought as a private Workboard draft without sending it to an AI.` | `Save a thought to your private Work desk without sending it to an AI.` | both intent files, byte-identical |
| `intent.workboardCapture.confirmation` | `Added to Workboard. Nothing was sent.` | `Added to Work. Nothing was sent.` | both intent files, byte-identical |
| `workboard.error.staleDraft` | `This brief changed on another device. Reopen it to keep the latest version.` | `This card changed on another device. Reopen it to keep the latest version.` | `Services/Workboard/WorkboardLiveRepository.swift` |
| `workboard.error.itemMissing` | `This brief is no longer available.` | `This card is no longer available.` | `WorkboardLiveRepository.swift` — **beyond my named list, §3.1** |
| `workboard.error.contentTooLong` | `That brief is longer than %@ characters. Shorten it, then try again.` | `That text is longer than %@ characters. Shorten it, then try again.` | `Models/WorkboardRecords.swift` — **beyond my named list, §3.1** |
| `workboard.load.failed.message` | `Your projects stay private and unchanged. Try opening them again.` | `Your desk stays private and unchanged. Try opening it again.` | `Views/Workboard/WorkboardView.swift` |
| `workboard.material.link.footer` | `The gateway receives the address as text. Conduck does not fetch the page in the background.` | `The address is saved as text. Conduck does not fetch the page in the background.` | `Views/Workboard/WorkboardTextMaterialSheet.swift` |
| `workboard.tutorial.point.review` | `Nothing is sent to an AI until you review it.` | `Everything stays in your iCloud, on all your devices.` | `Views/Workboard/WorkboardTutorialView.swift` |
| `workboard.voice.privacy` | `Adds editable text to this private draft. It never sends the brief or chooses a gateway.` | `Keeps the recording on your private desk and adds the words when they’re ready. Nothing is sent.` | `Views/Workboard/WorkboardVoiceCaptureView.swift` — **beyond my named list, §3.2** |
| `workboard.voice.stop` | `Stop and Add Text` | `Stop and Save` | `WorkboardVoiceCaptureView.swift` — **beyond my named list, §3.2** |

`workboard.error.contentTooLong` is the one intentional source/catalog *asymmetry*: the source interpolates `\(limit)` and the catalog row stores the formatted `%@`. That is how the row already was; I preserved it.

### Bare-English literals — the string IS the key, so the row was replaced (delete + insert, count unchanged)

| Where | Old key/value | New key/value |
|---|---|---|
| `ConduckApp.swift`, `CommandGroup(after: .newItem)` | `Button("Workboard")` | `Button("Work")` |
| `Views/Conversation/ConversationListView.swift:344`, the Delete-All alert message | `This removes every conversation and its usage records from this device and all your other devices. **Workboard briefs stay on your board.** This cannot be undone.` | `…all your other devices. **Your Work desk and everything on it stay untouched.** This cannot be undone.` |

Both new rows are `{}` (no `localizations`), matching every other auto-extracted bare-English row. Both were inserted at their case-insensitive slot: `Work` between `Where does your AI live?` and `workbench.chats`; the alert sentence keeps the old one's exact position (it still sorts before `This removes every conversation from this device…`).

### `AppShortcuts.swift` — the CaptureWorkboardIntent entry's three bare-English entries

| Old | New |
|---|---|
| phrase `"Add a thought to my Workboard in \(.applicationName)"` | `"Add a thought to my Work desk in \(.applicationName)"` |
| phrase `"Prepare something in \(.applicationName)"` | `"Capture a thought in \(.applicationName)"` |
| `shortTitle: "Add to Work"` | unchanged in value; annotated `// xcstrings` like every sibling entry |

**No catalog work was needed and none was done**: the main catalog carries no `${applicationName}` key at all (strings-audit §2c established this), and `Add to Work` was already present. Verified after the edit that neither old phrase appears in any catalog.

### `workboard.workspace.*` family naming — DELIBERATELY NOT renamed

My brief conditions this on "if it still says workspace-of-many". It does not. Every one of the 16 `workboard.workspace.*` **values** already reads *Work* (`Add to Work`, `Drop into Work`, `Couldn’t add to Work`, `Added to Work. Nothing was sent.`, …); only the **key identifiers** carry the word, and a key identifier is never user-facing. Renaming them would touch `WorkboardCaptureCanvas.swift` and `WorkboardViewModel.swift` (files with an unresolved blocker in them, §5), churn 16 catalog rows, and buy nothing a user can see. Left as-is on purpose.

## 2. `spec.md` — the decisions I rewrote

Two edits, both **cuts-plus-replacement**, never an append. The heading changed too, because it named the dead pipeline.

**(a) The Work decision (was `## The Workboard prepares work before it becomes a conversation`, 171 words) → `## Work is one desk, and nothing on it is sent` (146 words).** Every one of these is gone from the prose: *Board → Brief → immutable dispatch snapshot → Conversation → Review*, "inspect the exact packet and choose a gateway", "only they dispatch or mark Done", "Share can create New Work or append idempotently to a recent open item", "a stale/Done target falls back honestly to a new draft", and "Deploy additive model 14". What it says now:

- Work is ONE desk per person, made by the first capture and never deleted; every capture surface lands on it; none has a gateway API and no code path leads from it to an AI.
- The Work/Chats shell still preserves both sides' drafts; GigaAction still defaults to Chat for installed-shortcut compatibility (both still true, both worth keeping).
- **Bytes sync.** A payload within `Constants.workboardSyncCeilingBytes` rides the person's private CloudKit as its own blob row and reaches their other devices; anything larger stays in the device-local vault behind a reattach. The number is NOT written — the constant's name is, per the file's own second prohibition.
- **A voice note is kept as a playable card**, made durable before the speech hop so a failed transcription costs the words and never the recording.
- External preview/open/share surfaces still get disposable copies, never the vault's authoritative URL.
- **Deploy model 16 to production CloudKit before release** (integrate-a §Requests 5 / §Requests 6: `ConversationsModelMigrationTests.testTheCurrentModelVersionIsV16` is now the guard). There was exactly one model pin in the whole file — `model 14` — and no `v15` line anywhere; grep for `model 1[456]` / `Conversations 1[456]` / `cardSize` now returns only the model-16 sentence.

**(b) `spec.md` "Audio" (the `:503` line).** `**Audio** never enters a conversation and never syncs.` → `…never enters a conversation and never syncs **with one**.` plus one clause: `A Work voice note is the one recording that is kept, a desk material rather than a conversation's audio.` The two bounded conversation-audio retention paths below it are untouched — they are still exactly true of Chat/Watch/headless audio, which is the only audio that paragraph governs.

**Present tense throughout; no was/now/previously; nothing added that a reader could confirm by opening one file.**

**Deliberately NOT added to `spec.md`** (store-descriptions §Requests 6): the two SQLite filenames and their configuration names. They fail the file's own one-file rule (`ConversationStore.swift`'s `storeDescriptions` states them) and the file is 2,929 words over its ceiling, so adding them would have made the guard worse for no boundary the prose does not already carry ("rides CloudKit as its own blob row" is the boundary).

## 3. Deviations from my named list, each with its reason

1. **`workboard.error.itemMissing` and `workboard.error.contentTooLong`** were not on my list. They sit in the same two error enums as `workboard.error.staleDraft` and used the same dead noun (*"This **brief** is no longer available"*, *"That **brief** is longer than…"*). Rewording one member of a switch and leaving its neighbours saying "brief" would have shipped an inconsistency, so I moved all three. Keys kept; both are `en`-only like everything else.
2. **`workboard.voice.privacy` and `workboard.voice.stop`** were audio-capture §Requests 3's, listed there under *new* keys `workboard.voice.privacy.recording` / `workboard.voice.stop.save`. **I reworded the existing keys in place instead.** audio-capture's stated reason for new keys was "rewriting a value in source alone changes nothing at runtime; the catalog's en value wins" — which is an argument for editing BOTH, and editing both is exactly my brief's rule. New keys would have retired two live keys and minted two more for no gain: the catalog is English-only (verified: the only language in all four catalogs is `en`), so there is no stale translation to strand. The old copy was false in the sharpest possible way — it told the user the recording is discarded and only text is kept, which two-phase capture reverses.
3. **`sync.icloud.banner.{noAccount,restricted,quota}` NOT touched.** availability §Requests 2 / integrate-b §Requests 3 / test-surgery §Requests 3 all flag that they say "your conversations" and the Work desk renders them verbatim. Widening them changes copy on the **Chat** surfaces too, where "your conversations" is the right and specific word; giving the desk its own three keys means editing `WorkboardCaptureCanvas.swift` (which does not compile today, §5) and minting three keys. Neither is a call I should make silently — §Requests 1.
4. **`workboard.voice.context` = "Add context and thoughts"** (the voice sheet's nav title for something that now records) left alone — audio-capture called it the founder's call and I agree; it is not false, only narrow.
5. **`intent.workboardCapture.error.empty` = "Say or type what you want to prepare first."** left alone. "Prepare" is brief-era phrasing but the sentence is not false, and `intent.workboardCapture.*` is Shortcut-facing identity where I'd rather change nothing that isn't wrong.
6. **Files edited that were not on my ownership list.** `workboard.load.failed.message`, `workboard.error.*`, `workboard.material.link.footer`, `workboard.voice.*` are all named (or entailed) by my task but live in `WorkboardView.swift`, `WorkboardLiveRepository.swift`, `WorkboardRecords.swift`, `WorkboardTextMaterialSheet.swift`, `WorkboardVoiceCaptureView.swift`. Because the catalog value wins at runtime, a reword that touched only the catalog would have left source and catalog disagreeing — the exact trap views-core §Requests 4 declined to create. I am serial and alone in the tree, so I moved both halves. **Every edit in those five files is a string value or a comment; no logic, no signature, no assertion.**

## 4. Source comments and headers rewritten to constraints-truth

Grepped for headers claiming the dead truths (`audio is not retained`, `bytes never leave the device`, brief/dispatch descriptions). Nine rewrites, all comment-only, all present-tense constraint statements with no narration:

| File | Symbol / place | What was false |
|---|---|---|
| `Views/Workboard/WorkboardTutorialView.swift` | file header | "nothing is sent until you review" → "everything stays in your own iCloud" |
| same | `points` doc comment | "gather, arrange, **send**" → "gather, arrange, **keep**" |
| `Views/Workboard/WorkboardVoiceCaptureView.swift` | file header | "voice-to-**brief** capture … only returns editable text to the draft. It can never dispatch a Workboard item." → the recorder publishes the recording as a playable card BEFORE the speech hop, so a failed transcription costs the words and never the audio; the transcript is written onto that same card |
| `Models/WorkboardRecords.swift` | `WorkMaterialDraft` doc | "File/image content stays in the device-local vault; only metadata enters the CloudKit-mirrored row" → the row carries metadata only and `WorkMaterialStoragePolicy` decides the lane, recorded in `storageMode` |
| same | `WorkItemContent` doc | "The editable fields of one **brief**" → the editable heading fields, which the desk leaves unwritten |
| same | `WorkMaterialCardSize` doc | "never part of a brief, a prompt, or a **dispatch snapshot**" → never part of the material's content |
| same | `WorkMaterialAvailability` doc + `syncedPending` | "shown before **dispatch**" → availability of a card's bytes; "cannot open, play or **dispatch**" → "cannot open or play" |
| `Views/Workboard/PersonalWorkbenchView.swift` | `makePreviewCopy` doc | "Work's revision and **immutable dispatch preflight**" → the desk's own revision |
| same | `refreshIfVisible` doc | "opening Work shows **projects**" → shows the cards already on the desk |
| `ViewModels/WorkboardViewModel.swift` | `WorkboardMaterialOrdering` doc | "inside one **project's** board … that **project's** materials" → on the desk / the desk's materials |

One non-comment change in that sweep, called out because it is a (rare) user-visible string: `PersonalWorkbenchView.makePreviewCopy`'s empty-name fallback `"Workboard material"` → `"Work material"`. It is the QuickLook/share title for a payload with no usable filename. Not localized (it never was), zero test references.

`WorkAssetVault.swift`'s header needed nothing — availability already rewrote it to the one-lane-of-two truth (integrate-b §Requests 2 confirms).

## 5. What I ran, and the exact result lines

Slug `~/Library/Caches/gigaduck-builds/desk-copy-truth/`; every log written there, grepped for `: error: ` and the verdict strings, never judged from tail or exit code. No `-configuration` passed anywhere. Cleaned at the end, so the logs no longer exist.

**`ios-bft-1.log` — the tree AS I FOUND IT, before I edited anything:**
```
** TEST BUILD FAILED **
…/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
…/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'
```

**`ios-bft-5-final.log` — the tree I am HANDING BACK:** byte-identical verdict, the **same two errors and no others** (`grep -c ': error: '` = 2). **My diff introduces zero errors and removes zero errors.** This is strings-audit §6's blocker, unchanged and still unowned — the `.audio` design disagreement between the repository slice (`.audio` narrows to the `.file` card shape, asserted by `WorkboardLiveRepositorySupportTests:105,131,176`) and the card slice (`WorkboardCaptureCanvas` routes on a presentation-level `.audio`).

**Because a red tree proves nothing about my diff, I ran the same throwaway PROBE strings-audit used** and reverted it byte-exactly.

Probe = `case audio` on `WorkboardMaterialKind` (+ its `title`/`systemImage` arms) and the four exhaustive-switch arms the compiler then demanded, found by iterating the build: `WorkboardMaterialIcon.tint`, `PersonalWorkbenchView.present(_:)` (`case .file, .audio`), and `WorkboardLiveRepository`'s `materialName`, `publishWorkMaterial` payload switch and `storageKind`.

- `ios-bft-4-probe.log`: `** TEST BUILD SUCCEEDED **`, 0 `: error: ` lines. **So every file I touched compiles, in both the app and the test targets.**
- `ios-test-1-probe.log`, `test-without-building`, sim `1DCDF41E-D223-48B4-AA8E-147B0A9E2CE1`: `** TEST EXECUTE SUCCEEDED **`
```
Executed 87 tests, with 0 failures (0 unexpected) in 4.141 (4.187) seconds
```
Per class, all `passed`:

| Class | Result | Class | Result |
|---|---|---|---|
| `WorkCaptureInboxTests` (six-file lockstep + intent title/summary catalog guard) | Executed 30, 0 failures | `WorkboardDeskIdentityDriftTests` | Executed 2, 0 failures |
| `CarPlayVoiceTimingContractTests` (reads the main catalog off disk) | Executed 22, 0 failures | `WorkboardDeskSurfaceDriftGuardTests` | Executed 4, 0 failures |
| `ErrorSurfaceDriftGuardTests` | Executed 7, 0 failures | `WorkboardMaterialBoardActionsTests` | Executed 12, 0 failures |
| `MacWorkbenchShellDriftGuardTests` | Executed 4, 0 failures | `WorkboardMaterialPresentationTests` | Executed 4, 0 failures |
| `WorkboardBlobSeamPlatformGuardTests` | Executed 2, 0 failures | | |

`WorkboardBlobSeamPlatformGuardTests` is fix-seams §Requests 1, discharged: **2 tests, 0 failures**, compiled and executed by the real ConduckTests target for the first time.

**Proof the probe left nothing behind.** The four probed files were byte-snapshotted *after* my own edits and restored from those snapshots; `cmp` reports IDENTICAL for all four. The only `.audio` occurrences left in them are the two that pre-date me (`WorkboardLiveRepository.swift:289,306`). `workboard.material.audio` was used by the probe and is **still absent from every catalog** — I minted no dead key (strings-audit §Requests 8 holds).

**macOS build: NOT RUN.** My brief names only the iOS sim, and the tree cannot build on any platform until §5's blocker is resolved. It stays an orchestrator gate item.

**Guard scripts:**

| Script | Result |
|---|---|
| `scripts/check-spec-cites.sh` | `✓ spec citations resolve — 777 Swift files scanned, 1 quoted section name(s), every one a live heading` — exit 0. The heading I renamed is not the cited one. |
| `scripts/check-folder-map.sh` | `✓ folder map current — 36 Swift source directories, all mapped` — exit 0 |
| `scripts/check-storage-seam.sh` | `✓ storage seam intact — 777 Swift files scanned` — exit 0 |
| `scripts/check-spec-size.sh` | **FAILS, PRE-EXISTING, and NOT made worse.** `✗ docs/ai-context/spec.md is 19829 words; the ceiling is 16900.` Baseline before my edits was **19830**; I hand back **19829** — one word under, having replaced 171 words of false prose with 146 true ones and spent 24 of the difference on the audio clause. The two over-limit decisions it also names (`Sending files and getting them back…` 687/650, `Forgetting a gateway…` 701/650) are untouched by me and unrelated to Work. |
| `git diff --check` | clean, exit 0 |

**Catalogs — all four `json.load` clean, key counts UNCHANGED:** main 2241, Watch 299, `ConduckShareExtension` 43, `ConduckShareExtensionMac` 42. Neither extension catalog was opened: neither carries any key I reworded (checked; their Work family is the `share.*` set share-ios/share-mac own).

**Bidirectional spot-check on the 11 keyed rewrites:** an automated sweep extracting every `"<key>", defaultValue: "…"` from all Swift under `Conduck/` and comparing to the catalog reports **source `defaultValue` == catalog `en` value for all 11, in the Watch catalog too**, with the single expected exception of `workboard.error.contentTooLong` (`\(limit)` vs `%@`, the pre-existing formatter convention).

**Catalog edit method** (matters for the next editor, and it is strings-audit's method with one fix): raw-line splice, never `json.dump` — the file is Xcode-formatted (4-space key indent, `"key" : {`) and a re-dump rewrites all 25k lines. The script locates each block by **brace depth from the key line**, edits only the `"value"` line, and validates by re-loading the JSON and asserting the result equals `before` with exactly the named deltas and **zero value differences on any untouched key**. `git diff --numstat` on the main catalog reads `242 / 2053`; that is strings-audit's uncommitted 169 deletions realigning, not my edit — the dict comparison is the proof. **The fix:** do NOT compute an insertion slot by case-insensitive comparison. This file's head holds a run of punctuation-first keys (`""`, `"…"`, `"[Image]"`, `"%@ is answering…"`) that no such comparison reproduces, so a computed slot lands at the TOP of the file. Name the anchor key you want to insert above.

## 6. What the next agent must know

1. **`spec.md` now pins model 16 and nothing else.** `testTheCurrentModelVersionIsV16` is the test-side guard; the spec sentence is the release-gate side. If anyone points the app back at 15 to dodge the CloudKit deployment, both fail.
2. **The spec-size guard has one word of headroom against its own pre-existing failure.** 19829 against a 19830 baseline. Any prose ADDED to `spec.md` from here makes a failing guard worse. Cut something of equal length or don't add.
3. **Do not "fix" `workboard.error.contentTooLong`'s source/catalog mismatch.** Source says `\(limit)`, catalog says `%@`. That is the formatted-literal convention strings-audit §Requests 5 warns about, and it is correct.
4. **Never delete the `Work` or the Delete-All-alert catalog rows on a zero-reference sweep.** They are bare-English literals: the key IS the `Text(...)` string, so a grep for `"Work" :` finds nothing useful and a grep for the alert sentence must match all 172 characters.
5. **`workboard.material.audio` is still deliberately absent from every catalog.** It becomes owed the moment §Requests 2's option (a) is chosen and stays permanently un-owed under (b). My probe used it and reverted it.
6. **The two intent files' `defaultValue:` strings are byte-identical again** for all three keys I moved. `WorkCaptureInboxTests.testBothCaptureIntentsNameWorkInTheirTitleAndTheirParameterSummary` covers the title and the summary but NOT the description or the confirmation — if you edit either, edit both files by hand.

## Catalog

**Keys I ADDED in source: NONE.** Every string I wrote replaces the value of a key that already existed, except the two bare-English literals in §1, whose catalog rows were replaced 1-for-1.

**Keys I ADDED to a catalog (2, both bare-English, both replacing a deleted row so the count is flat):**

| Catalog | Key = value |
|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | `Work` = `Work` (empty row, as every bare literal is) |
| `Conduck/Conduck/Localizable.xcstrings` | `This removes every conversation and its usage records from this device and all your other devices. Your Work desk and everything on it stay untouched. This cannot be undone.` (empty row) |

**Keys I found DEAD and DELETED (2), each because its own literal changed in source:**

| Key | Why dead |
|---|---|
| `Workboard` | `ConduckApp.swift`'s `Button("Workboard")` became `Button("Work")`; the bare literal IS the key |
| `This removes every conversation and its usage records from this device and all your other devices. Workboard briefs stay on your board. This cannot be undone.` | same — `ConversationListView.swift:344`'s literal changed |

**Keys whose VALUE I changed (11 in the main catalog, 3 of them also in the Watch catalog):** the table in §1. **Keys I found DEAD but did NOT delete: NONE.** **Key counts unchanged in all four catalogs.**

---

## Requests

1. **Founder / product — the desk's iCloud banner is the last false user-facing copy in Work, and I left it deliberately (§3.3).** `sync.icloud.banner.{noAccount,restricted,quota}` all say *"your conversations"*, and `WorkboardCaptureCanvas.deskSyncBanner` renders them verbatim on the Work desk, where the thing that will not sync is a card. Two options, both cheap, neither mine to pick: **(a)** widen the three to a noun true on both surfaces (costs Chat its specific word), or **(b)** mint `workboard.sync.banner.{noAccount,restricted,quota}` and point the desk at those (costs 3 keys and one edit in `WorkboardCaptureCanvas.swift`). This is the fourth fixnote to raise it (availability §Requests 2, integrate-b §Requests 3, test-surgery §Requests 3).
2. **Orchestrator / audio owner — strings-audit §Requests 1 is STILL the blocker and nothing downstream can be gated until it lands.** Same two errors, same file, unchanged since 01:19. I re-derived the full cascade: adding `case audio` to `WorkboardMaterialKind` forces arms in `WorkboardMaterialIcon.tint`, `PersonalWorkbenchView.present(_:)` and three switches in `WorkboardLiveRepository` (`materialName`, the `publishWorkMaterial` payload switch, `storageKind`) — then `WorkboardLiveRepositorySupportTests:105,131,176` fail, because they assert the opposite contract. That is a design decision plus an assertion rewrite a human must sanction.
3. **Whoever runs the gate — `WorkboardBlobSeamPlatformGuardTests` is discharged** (fix-seams §Requests 1): `Executed 2 tests, with 0 failures`, compiled and executed by the real target. The iOS baseline moves +2 as fix-seams predicted.
4. **Watch suite: NOT RUN by me** (no watch sim assigned; my brief names only the iOS sim). The Watch catalog changed (3 values) and `ConduckWatch Watch App/WorkboardCaptureIntent.swift` changed (3 `defaultValue:` strings + 2 comments). fix-seams last ran it green at 231/0 before those edits. Run it on `28AC563B-42C1-4E66-940D-77E63B07918B` before the gate.
5. **Founder copy pass — the four lines most worth a second look**, since the brief says the founder does the final pass: the tutorial's third line (`Everything stays in your iCloud, on all your devices.` — deliberately warm and one clause, matching its two siblings), the voice sheet's privacy caption, the Delete-All alert's new middle sentence, and the two Siri phrases in `AppShortcuts.swift`, which are the only strings here a user speaks out loud.
6. **Nobody re-add "brief", "project", "dispatch" or "review before sending" to Work copy or Work comments.** They are gone from every user-facing Work string and from ten source comments. There is no test guarding that — the vocabulary is held by convention only.
