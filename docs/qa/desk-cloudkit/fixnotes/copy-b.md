# copy-b — Work copy truth, the four catalogs, spec.md. BOTH FINDINGS CONFIRMED AND FIXED. Nothing refuted.

Serial, alone in the tree. No commits/pushes/stash/checkout/reset. `Identity-Override.xcconfig` untouched.
Nothing under `docs/qa/desk-cloudkit/` touched. Mirror triplets untouched
(`git status --short -- '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift'` → 0 lines).
Slug `copy-b` cleaned (`removed: copy-b`).

**Files I changed (9):**

| File | What |
|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 8 values reworded · 6 rows added · 6 rows deleted. Raw-line splice; key count flat at 2242 |
| `Conduck/Conduck/Views/Workboard/WorkboardTutorialView.swift` | `workboard.tutorial.point.review` value + file header |
| `Conduck/Conduck/Services/ConversationStore+Workboard.swift` | `workboard.chatCapture.unavailable.detail` value |
| `Conduck/Conduck/Views/Workboard/WorkboardComponents.swift` | `workboard.material.large.confirm.message{,.one}` values |
| `Conduck/Conduck/Views/Workboard/PersonalWorkbenchView.swift` | `workboard.material.preview.unavailable` value |
| `Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift` | `workboard.material.remove.confirm.message` value |
| `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift` | `workboard.material.unavailableHere` value |
| `Conduck/Conduck/ViewModels/WorkboardViewModel.swift` | `workboard.voice.context` value (`WorkboardVoiceTarget.title`) + a doc comment stating the constraint |
| `docs/ai-context/spec.md` | the Work decision and the `**Audio**` line, rewritten |

**Files I added (1):** `Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift` (ConduckTests is a
synchronized group — no pbxproj edit; verified by the class actually executing, §Verification).

**Files I edited that I own only in lockstep (1):** `Conduck/ConduckTests/WorkboardAvailabilityTests.swift`
— its `reattachCopy` helper restates `workboard.material.unavailableHere`'s `defaultValue` verbatim
(`:73-77`); a value edit that skipped it would leave a source/catalog/test three-way disagreement. Value
only; no assertion touched.

The Watch catalog and the two share-extension catalogs were **opened and audited but not edited** — no key
I own lives in them (§Verification 3).

---

## Finding ui#2 — the tutorial promises every byte on every device — **CONFIRMED, FIXED**

**Verified against current code, not the report.** `WorkboardTutorialView.swift:92` carried
`workboard.tutorial.point.review` = *"Everything stays in your iCloud, on all your devices."* The claim is
false above the ceiling by a two-hop trace:
`WorkMaterialStoragePolicy.mode(kind:byteSize:)` (`Services/Workboard/WorkMaterialStoragePolicy.swift:28`)
returns `.localVault` for any `byteSize > Constants.workboardSyncCeilingBytes`
(`Utilities/Constants.swift:2114`, 30 MB), and the two-store split
(`ConversationStore.swift:1478-1503`, `#if os(watchOS) return [core]` else `[core, blobs]`) puts only
`WorkMaterialBlob` rows on CloudKit. A vault payload reaches another device only by an explicit reattach.
The file header repeated the same absolute claim (lines 6-9).

**Fixed** — key KEPT and reworded in place, per copy-truth's convention (the catalog is English-only, so
there is no stale translation to strand and a new key would retire a live one for nothing):

> `workboard.tutorial.point.review` = **`Cards sync through your own iCloud — very large files stay on the device that captured them.`**

Two clauses joined by an em dash, matching its siblings (`Collect anything — files, screenshots, links and
thoughts.` / `Drag cards to rearrange them, and resize the ones that matter most.`). It is precise about
which half syncs: the *card* always syncs (metadata + thumbnail are on the `Core` store); the *file* above
the ceiling does not.

**Deviation from the proposed fix, with why.** The report proposed "replace the review-named key with a new
sync-specific key". I kept the key. Renaming `…point.review` costs a catalog row pair and one source edit
and buys nothing a user can see — a key identifier is never user-facing — and copy-truth established the
reword-in-place convention for exactly this family. The finding's *evidence* (the copy is false) is what I
acted on.

**Header fixed too**, plus a new constraint comment naming the mechanism so the next editor cannot reword
it back by accident:

```
// The third line must stay inside `WorkMaterialStoragePolicy`'s truth: a payload
// over `Constants.workboardSyncCeilingBytes` is device-local behind a reattach,
// so the line names that lane rather than promising every byte on every device.
```

---

## Finding ui#3 — live Work strings still describe send / private-draft — **CONFIRMED, FIXED (6 rows)**

**Verified.** All five named keys held, plus one sibling the report told me to hunt for. I grepped every
`workboard.*` / `intent.workboardCapture.*` / `share.*` value in all four catalogs for
`send|sends|sending|sent|draft|brief|dispatch|project|workboard|workspace` and adjudicated every hit
(§"Hits I deliberately left" below).

| Key | Old | New | Source of record |
|---|---|---|---|
| `workboard.chatCapture.unavailable.detail` | `%@ could not be copied from this device. Reattach it in Work **if you need to send it**.` | `%@ could not be copied from this device. Reattach it in Work **to open it**.` | `ConversationStore+Workboard.swift:317` |
| `workboard.material.large.confirm.message.one` | `One large file (%@) **is stored only on this device** and may take a moment to copy **now or send later**.` | `One large file (%@) **stays on this device instead of syncing to your other devices**, and may take a moment to copy.` | `WorkboardComponents.swift:205` |
| `workboard.material.large.confirm.message` | `%1$lld large files (%2$@) **are stored only on this device** and may take a moment to copy **now or send later**.` | `%1$lld large files (%2$@) **stay on this device instead of syncing to your other devices**, and may take a moment to copy.` | `WorkboardComponents.swift:213` |
| `workboard.material.preview.unavailable` | `This material is not available on this device. Reattach it here **to open or send it**.` | `This material is not available on this device. Reattach it here **to open it**.` | `PersonalWorkbenchView.swift:613` |
| `workboard.material.remove.confirm.message` | `"%@" will be removed from **this private draft**.` | `"%@" will be removed from **your Work desk**.` | `WorkboardCaptureCanvas.swift:1135` |
| `workboard.material.unavailableHere` | `Reattach on this device **before sending**` | `Reattach on this device **to open**` | `WorkboardLiveRepository.swift:358` (+ `WorkboardAvailabilityTests.swift:76`) |

**The large-file copy is now a positive claim, and I checked it holds.** The alert fires at
`Constants.fileTransferSoftConfirmBytes` (100 MB, `Constants.swift:1732`), via
`WorkboardResolvedImportBatch.largeItemByteCounts` (`WorkboardCaptureCanvas.swift:1851-1866`). 100 MB is
strictly above the 30 MB sync ceiling, so **every** file that can raise this alert takes `.localVault` —
"stays on this device instead of syncing to your other devices" is true of every case that reaches it, not
merely most. Had the two thresholds been the other way round I would have had to hedge the sentence.

`workboard.material.unavailableHere` is a card's second line, sitting in a switch beside `Available on this
device` and `Waiting for iCloud…` (`WorkboardLiveRepository.materialDetail`). It keeps that register — a
short unpunctuated phrase — and now names the action the reattach actually unlocks.

**Guard test updated in the same edit:** `WorkboardAvailabilityTests.reattachCopy` mirrors the
`defaultValue`. No assertion was weakened; only the literal it restates moved. That suite is green (9/0).

### Also (a) — the voice sheet's navigation title

`workboard.voice.context` = *"Add context and thoughts"* titled a sheet that RECORDS: the recorder publishes
the compressed audio as a playable card *before* the speech hop
(`WorkboardVoiceCaptureView.swift` header; `WorkVoiceCaptureCoordinator`), so the sheet's product is a
recording and the words are written onto it afterwards.

> `workboard.voice.context` = **`Record a voice note`**

`WorkboardVoiceTarget.title` also gained a doc comment saying why the title names the act rather than the
text, since "Add context" reads perfectly plausible to a future editor.

### Hits I deliberately left, each with the reason

| Key | Value | Why it is TRUE |
|---|---|---|
| `workboard.menuBar.ask.help` | `Send this to your default AI gateway` | The **Chat** lane. `DictationPopoverView.swift:585-611` — this is the *Ask* button beside *Add to Work*; it really does reach the gateway. It carries a `workboard.` key only because both buttons share the quick-capture popover. Allow-listed by key in the new guard |
| `workboard.chatCapture.saved` · `workboard.menuBar.saved` · `workboard.workspace.thought.saved` · `…import.complete.message{,.one}` · `…import.partial.message` · `…add.hint` · `…drop.overlay.caption` | all contain *Nothing is/was sent* | The inertness PROMISE, which is the one thing Work is supposed to say about sending. Stripped before the vocabulary scan rather than allow-listed, so the rule still binds on the rest of each sentence |
| `intent.workboardCapture.description` | `…without sending it to an AI.` | Same promise, and Shortcut-facing identity. Out of the guard's `workboard.` scope, which is also why the guard cannot see its second (Watch) declaration |
| `workboard.chatCapture.remote.detail` | `%@ stays on your gateway. Open the original chat to retrieve it.` | A gateway-hosted chat file that Work never copied. True, and it describes Chat's storage, not a Work send |
| `share.*` in both extension catalogs | `Send now`, `Sending…`, `Send to` | The **Chat** half of the share sheet. `share.work.inert` = `Nothing is sent to AI` is the Work half |
| `sync.icloud.banner.*` | — | **Untouched by instruction** (plan §C reuses them; founder decision pending). Still says "your conversations" on the Work desk — copy-truth §Requests 1, unchanged |

---

## (b) `docs/ai-context/spec.md` — five facts folded in, file one word SMALLER than the baseline

**Word budget is the binding constraint and I met it: 19829 → 19827.** The two regions I own totalled 204
words before and total 200 after, so the facts are paid for by cuts inside the same two decisions and
nothing else in the file moved.

**The Work decision now reads:**

> Work is one desk per person, made by the first capture and never deleted. Every capture surface lands on
> it, and no code path leads from it to an AI. The Work/Chats shell preserves both sides' drafts;
> GigaAction defaults to Chat for installed-shortcut compatibility.
>
> The desk lives in the person's own private iCloud, bytes included: a payload within
> `Constants.workboardSyncCeilingBytes` rides CloudKit as a blob row, anything larger stays in the
> device-local vault behind a reattach, **and neither is durable until its bytes read back at the length
> written**. **One process imports a capture, renewing its claim throughout.** **A recapture repairs a
> bytes-less card and adopts one an older build parked under a per-capture owner when provenance and kind
> match.** A voice note, **in the app or from a Shortcut**, is a playable card made durable before the
> speech hop, so a failed transcription costs the words and never the recording. External surfaces get
> disposable copies, never the vault's authoritative URL. Deploy model 16 to production CloudKit before
> release.

**The audio line now reads:**

> **Audio** never enters a conversation and never syncs with one; a Work voice note is a desk material
> instead. There is no audio entity in the database, though the attachment entity would permit one.

**Fact-by-fact, against the fixnote that asked for it:**

| Fact | Requested by | Where it landed |
|---|---|---|
| a capture is durable only once its bytes read back | fix2-store §8(b), fix2-recorder §6 | `…and neither is durable until its bytes read back at the length written` |
| durable-readability barrier + lease renewal | fix2-drainer §6, fix2-inbox §6(a) | `One process imports a capture, renewing its claim throughout.` |
| Chat→Work replay repairs a payload-less card | fix2-store §8 | `A recapture repairs a bytes-less card…` |
| legacy-owner adoption on explicit recapture with provenance | fix2-store §8(a) | `…and adopts one an older build parked under a per-capture owner when provenance and kind match.` |
| the Shortcuts Work voice lane also retains the recording | fix2-voice-lanes §6 | `A voice note, in the app or from a Shortcut, …` |

**The 41 words I cut to pay for them, each with its reason.** Every cut is inside the same two decisions;
none is a rejected alternative, and nothing was relocated to another document.

1. `none has a gateway API: no code path leads from it to an AI` → `no code path leads from it to an AI`
   (−6). The second clause is strictly stronger than the first and states the same boundary.
2. `and reaches their other devices` (−5) after `rides CloudKit as its own blob row`, in a sentence that
   opens `The desk lives in the person's own private iCloud`. Twice-said.
3. `its own blob row` → `a blob row` (−1).
4. `preserves both sides' drafts while switching` → `preserves both sides' drafts` (−2); `GigaAction
   **still** defaults` → `GigaAction defaults` (−1). Present-tense end-state; "still" is a changelog word.
5. `A voice note is kept as a playable card, made durable…` → `A voice note … is a playable card made
   durable…` (−2).
6. `External preview, open and share surfaces` → `External surfaces` (−3). The rule is the same for all
   three, and each is confirmable in its own file.
7. The audio line's closing sentence, `A Work voice note is the one recording that is kept, a desk material
   rather than a conversation's audio.` (−18), folded into the opening clause as `; a Work voice note is a
   desk material instead.` The Work decision now carries the retention fact in full, so this was the same
   sentence twice, two sections apart.
8. `though note that is a property of the code rather than of the schema, since the attachment entity holds
   arbitrary bytes and a free-text media type` → `though the attachment entity would permit one` (−16, of
   which 3 are the final trim to land under the baseline). The warning survives — the schema does not stop
   you — and the mechanism is one file away.

No changelog narration: `grep -niE '\bwas\b|used to|no longer|previously|formerly|now uses'` over both
regions → **no matches**. `check-spec-cites.sh` is unaffected (I renamed no heading; the one quoted section
name in Swift is elsewhere).

**One deviation from "ONE sentence each", stated plainly.** Two of the five facts share a sentence
(`A recapture repairs a bytes-less card **and** adopts one…`), and the Shortcut fact is a clause rather
than a sentence. Written as five stand-alone sentences the fold costs ~100 words, and there are not 100
words of genuine redundancy in a 204-word pair of decisions — I would have had to delete a real decision to
pay for it. Compression was the smaller deviation.

**Judgement I want on the record.** Under `spec.md`'s own one-file rule ("a sentence belongs in this
document only if it CANNOT be confirmed by opening one file"), the recapture/adoption sentence is the
weakest of the five: both halves are confirmable by opening `ConversationStore+Workboard.swift`. I folded
it because my brief named it, but if the size guard is ever fought seriously, that is the sentence to
retire into that file's header comment first — and it is where I would have found the 22 words that let
the other facts breathe.

---

## Regression test

**New: `Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift`** — 4 tests, all executed by the real
`ConduckTests` target (`Executed 4 tests, with 0 failures`). It reads the shipped catalog **off disk**
rather than through `String(localized:)`, because the catalog's `en` value is what a user reads and it
beats a source `defaultValue:` at runtime — a guard that resolves the string proves nothing about the row
that ships.

| Test | Rule |
|---|---|
| `testNoWorkStringDescribesSendingDispatchingOrADraft` | No live `workboard.*` value contains `send/sends/sending/sent/draft(s)/brief(s)/briefing/dispatch(es/ed)`, after the inertness phrases (`nothing is/was/has been sent`) are removed and `workboard.menuBar.ask.help` (the Chat lane) is allow-listed |
| `testTheTutorialSyncLineNamesTheDeviceLocalLane` | `workboard.tutorial.point.review` mentions iCloud, and contains neither `everything` nor `all your devices` |
| `testEveryWorkKeyInSourceHasACatalogRow` | Every `"workboard.…"` literal in the app target has a catalog row (otherwise it renders from `defaultValue` and can never be translated) |
| `testEveryWorkCatalogRowIsReferencedInSource` | Every `workboard.*` catalog row is referenced by the app target (otherwise it outlives its surface) |

**How I know it would fail on the old code — measured counterfactual, not an argument.** I kept a
byte-copy of the pre-splice catalog and re-ran the four rules' exact logic against it with the *current*
source tree (my source edits changed values only, never a key, so the key sets are HEAD's):

```
--- (1) vocabulary failures on the OLD catalog:
   FAIL workboard.chatCapture.unavailable.detail ['send']
   FAIL workboard.material.large.confirm.message ['send']
   FAIL workboard.material.large.confirm.message.one ['send']
   FAIL workboard.material.preview.unavailable ['send']
   FAIL workboard.material.remove.confirm.message ['draft']
   FAIL workboard.material.unavailableHere ['sending']
--- (2) tutorial line on the OLD catalog:
   value: 'Everything stays in your iCloud, on all your devices.'
   contains 'everything': True   contains 'all your devices': True
--- (3) source key with no OLD catalog row: ['workboard.audio.busy', 'workboard.audio.cancelLoading',
    'workboard.audio.unavailableHere', 'workboard.material.preview.syncPending',
    'workboard.voice.error.deskWrite', 'workboard.voice.recordAgain']
--- (4) OLD catalog row no source references: ['workboard.material.addNote', 'workboard.material.note.body',
    'workboard.material.note.defaultName', 'workboard.material.note.footer', 'workboard.material.note.name',
    'workboard.material.note.title']
```

All four tests fail on the pre-edit catalog — rule (1) on exactly the six ui#3 rows, rule (2) on the ui#2
line, rules (3) and (4) on exactly the twelve rows this session's catalog work added and removed. The
guard is scoped to `workboard.*` deliberately: `intent.workboardCapture.description` legitimately says
"without sending it to an AI", and it is declared twice (app + Watch), which the one-target source scan
cannot see.

---

## Verification — exactly what I ran, and the exact lines

Slug `~/Library/Caches/gigaduck-builds/copy-b/`; every log written there and grepped for `: error: ` and
the verdict strings, never judged from tail or exit code. No `-configuration` passed anywhere. Cleaned at
the end (`removed: copy-b`), so the logs no longer exist.

**1. iOS build-for-testing**, sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, `ios-bft-1.log`:

```
** TEST BUILD SUCCEEDED **
```
`grep -c ': error: '` → **0**.

**2. Targeted iOS tests**, `test-without-building`, same sim, `ios-test-1.log`. Ten classes — the seven my
brief names, plus the three my diff can reach:

| Class | Result |
|---|---|
| `WorkCaptureInboxTests` | **Executed 30 tests, with 1 failure** — pre-existing, not mine, §Requests 1 |
| `CarPlayVoiceTimingContractTests` (reads the main catalog off disk) | Executed 22 tests, with 0 failures |
| `ErrorSurfaceDriftGuardTests` | Executed 7 tests, with 0 failures |
| `WorkboardDeskSurfaceDriftGuardTests` | Executed 4 tests, with 0 failures |
| `MacWorkbenchShellDriftGuardTests` | Executed 4 tests, with 0 failures |
| `WorkboardAudioCaptureTests` | Executed 19 tests, with 0 failures |
| `WorkboardAudioCardTests` | Executed 27 tests, with 0 failures |
| `WorkboardCopyTruthGuardTests` (**new**) | Executed 4 tests, with 0 failures |
| `WorkboardAvailabilityTests` (I edited its `reattachCopy`) | Executed 9 tests, with 0 failures |
| `WorkboardMaterialPresentationTests` (asserts the large-import message) | Executed 4 tests, with 0 failures |

Run total: `Executed 130 tests, with 1 failure (0 unexpected) in 16.084 seconds`. The single failure is
quoted verbatim in §Requests 1 and is the one fix2-inbox predicted; **no test crashed and no simulator
restart was needed**.

**3. Full watch suite**, `28AC563B-42C1-4E66-940D-77E63B07918B`, `watch-test-1.log`:

```
** TEST SUCCEEDED **
Executed 232 tests, with 0 failures (0 unexpected) in 9.689 (9.762) seconds
```
`grep -c ': error: '` → **0**. (copy-truth §Requests 4 asked for this after its Watch-catalog edits; it is
discharged. 232, up from the 231 fix-seams last recorded.)

**4. Guard scripts** — all three exit 0:

```
✓ spec citations resolve — 785 Swift files scanned, 1 quoted
  section name(s), every one a live heading in docs/ai-context/spec.md
✓ folder map current — 36 Swift source directories, all mapped,
  and every path the map names exists
✓ storage seam intact — 785 Swift files scanned, no raw store
  or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift
```

**5. Spec size guard — still failing, still PRE-EXISTING, and one word BETTER than the baseline:**

```
✗ docs/ai-context/spec.md is 19830 words; the ceiling is 16900.     ← my first draft, rejected
✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.     ← what I hand back
```
Baseline was **19829** (copy-truth §5). `wc -w docs/ai-context/spec.md` → **19827**. The two named
over-limit decisions (`Sending files…` 687/650, `Forgetting a gateway…` 701/650) are untouched by me and
unrelated to Work. I did not "fix" the pre-existing failure and I did not make it worse.

**6. `git diff --check`** → no output, exit 0.

**7. All four catalogs `json.load` clean, with counts:** main **2242**, Watch **299**,
`ConduckShareExtension` **43**, `ConduckShareExtensionMac` **42**. Only the main catalog was edited; its
count is FLAT (6 added, 6 removed).

**8. Bidirectional audit after the edit** (app target vs main catalog):
`source-only: []  catalog-only: []  both: 144`. And the eight reworded keys' catalog `en` values equal
their source `defaultValue` at every declaring site (including `WorkboardAvailabilityTests`), verified by
an automated extract-and-compare.

**macOS build: NOT RUN.** My brief names the iOS and watch destinations only and specifies no macOS step.
It stays an orchestrator gate item — and note that `MacWorkbenchShellDriftGuardTests` (4/0) is a source
guard, which is not the same thing as a compile.

---

## Catalog

**Keys I ADDED in source: NONE.** I minted no key. Every string I wrote replaces the value of a key that
already existed.

**Keys I ADDED to `Conduck/Conduck/Localizable.xcstrings` (6)** — every one is a key another agent added in
source and listed for me; each value is the source `defaultValue` **verbatim**, re-verified by grep against
the declaring file after the splice:

| Key = value | Declared at | From |
|---|---|---|
| `workboard.audio.busy` = `Audio is in use right now` | `WorkboardAudioCardView.swift:883` | fix2-audio-card |
| `workboard.audio.cancelLoading` = `Cancel Loading` | `WorkboardAudioCardView.swift:1159` | fix2-audio-card |
| `workboard.audio.unavailableHere` = `Not on this device` | `WorkboardAudioCardView.swift:978` | fix2-audio-card |
| `workboard.material.preview.syncPending` = `This material is still arriving from iCloud. It will open once it lands on this device.` | `PersonalWorkbenchView.swift:617` | fix2-canvas |
| `workboard.voice.error.deskWrite` = `Work couldn’t save this recording just now.` (curly apostrophe) | `WorkVoiceCaptureCoordinator.swift:52` | fix2-recorder |
| `workboard.voice.recordAgain` = `Record Again` | `WorkboardVoiceCaptureView.swift:231` | fix2-recorder |

**Keys I made DEAD: NONE.** I deleted no code carrying a string.

**Keys I REMOVED from the catalog (6)** — vm-collapse §5's list, each re-verified zero-reference across the
whole worktree minus `docs/` before deletion:

`workboard.material.addNote` · `workboard.material.note.title` · `workboard.material.note.body` ·
`workboard.material.note.name` · `workboard.material.note.footer` · `workboard.material.note.defaultName`

I did **not** touch `workboard.material.note` (the kind's noun, still referenced), `workboard.material.addLink`,
or any `workboard.material.link.*` / `workboard.workspace.*` key — vm-collapse's do-not-delete list holds.

**Keys whose VALUE I changed (8, main catalog only):** the six in ui#3's table, plus
`workboard.tutorial.point.review` (ui#2) and `workboard.voice.context` (item a). **Key count flat at 2242.**

**Catalog edit method, for the next editor.** Raw-line splice, never `json.dump`. Each block is located by
brace depth from its `    "key" : {` line; a value edit rewrites one `"value" :` line at its own indent; an
insertion is an 11-line block built to the file's shape (`extractionState: extracted_with_value`, one `en`
`stringUnit`, `state: new`) placed **above a NAMED anchor key** — never at a computed sort slot, per
copy-truth §5 (the file's head holds punctuation-first keys that no case-insensitive comparison
reproduces). Validated by `json.load` before and after and a full dict comparison asserting
`added == {6 expected}`, `removed == {6 expected}`, `changed == {8 expected}` and **zero value differences
on any untouched key** — all four assertions printed `True`. `git diff --numstat` reads `74 / 74`.

**One splice gotcha I hit and fixed:** two new keys shared one anchor
(`workboard.audio.busy` and `workboard.audio.cancelLoading` both above `workboard.audio.failed`), and
applying edits in descending line order reversed them. I swapped the two blocks in a second pass and
re-asserted `before == after` on the parsed dicts (`dicts identical after swap: True`). Sorted order now
reads busy → cancelLoading → failed. **If you insert two keys above one anchor, insert them in reverse.**

---

## Requests

1. **Integrator, BLOCKING for the gate — `WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication`
   fails, and it is not mine.** Exact line from my run:
   `WorkCaptureInboxTests.swift:308: error: … XCTUnwrap failed: expected non-nil value of type "Range<Index>"`.
   It is a source-drift guard looking for `try envelope.validateForPublication()` inside both appexes'
   `ShareViewController.swift`, and fix2-inbox moved that publication into `WorkCaptureDirectoryPublisher`.
   **fix2-inbox §Requests 1 already asked for this test to be DELETED** (superseded by
   `WorkCaptureSharePublisherTests` + `testBothShareExtensionsPublishThroughThePublisherRatherThanByHand`),
   taking the class 30 → 29. My diff touches neither appex nor that test. It is the only failure in 130
   executed iOS tests and in 232 watch tests.
2. **Founder copy pass — three lines are new since copy-truth §Requests 5 and are worth your eye.** The
   tutorial's third line (`Cards sync through your own iCloud — very large files stay on the device that
   captured them.`), the large-file confirm (`…stays on this device instead of syncing to your other
   devices…`), and the voice sheet's title (`Record a voice note`). The first two are the only places the
   product tells a user, in their own words, that the sync has a ceiling.
3. **`sync.icloud.banner.{noAccount,restricted,quotaExceeded}` remain the last false Work copy, and I was
   told not to touch them.** They say "your conversations" and `WorkboardCaptureCanvas.deskSyncBanner`
   renders them verbatim on a desk full of cards. This is now the **fifth** fixnote to raise it
   (availability §2, integrate-b §3, test-surgery §3, copy-truth §1). The founder decision is (a) widen the
   three, costing Chat its specific word, or (b) mint `workboard.sync.banner.*`, costing 3 keys and one
   edit in `WorkboardCaptureCanvas.swift`. My new vocabulary guard does **not** cover them — they are
   `sync.*`, not `workboard.*`.
4. **Nobody re-add `send`, `draft`, `brief` or `dispatch` to a `workboard.*` string.** copy-truth §Requests
   6 asked for this and said it was held by convention only. **It is now held by a test** —
   `WorkboardCopyTruthGuardTests.testNoWorkStringDescribesSendingDispatchingOrADraft`. If a Work string
   legitimately needs the word (a new Chat-lane control under a `workboard.` key), add it to
   `chatLaneKeys` with a comment, do not weaken the word list.
5. **Watch-catalog drift, PRE-EXISTING and outside my scope.**
   `ConduckWatch Watch App/Services/WatchRecordingService.swift:760` declares
   `watch.capture.defaultGatewayNotSetUp` = `"\(name) **isn't available**. Choose which AI new chats use, on
   your iPhone."`, while the Watch catalog row reads `"%@ **isn't set up**. …"`. The catalog wins at
   runtime, so the user sees "isn't set up" and the source lies to the next reader. Unmodified since
   `efa553e`; not a Work string; I left both halves alone. Whoever owns the Watch capture lane should pick
   one.
6. **`workboard.material.audio` = `Voice note` is now IN the main catalog**, so strings-audit §Requests 1
   option **(a)** was taken and its §Requests 8 ("deliberately NOT in the catalog") is spent. Nobody delete
   that row on a stale scout list — `WorkboardMaterialKind.audio.title` references it and the tree builds.
7. **Two source/catalog asymmetries are CORRECT and must not be "fixed":**
   `workboard.error.contentTooLong` (source `\(limit)`, catalog `%@`) and `workboard.workspace.drop.image`
   (source `\(index + 1).\(format.ext)`, catalog `%1$lld.%2$@`). Both are the formatted-literal convention
   strings-audit §Requests 5 warns about. My new bidirectional guard asserts key presence only, never value
   equality, precisely so it cannot be satisfied by breaking these.
8. **macOS build owed at the gate.** Not run by me (§Verification 8).

---

## Refuted

Empty. Both findings held on trace, and the sibling sweep the second finding asked for turned up one more
false string (`workboard.voice.context`, already named in my brief as item (a)) and six true ones I left
standing with reasons recorded above.
