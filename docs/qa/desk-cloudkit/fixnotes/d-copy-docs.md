# d-copy-docs — r4a#6 CONFIRMED and fixed; five settled facts folded into spec.md at ZERO word cost. Nothing refuted.

Label `d-copy-docs`. Slug `d-copy`. Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, watch sim
`28AC563B-42C1-4E66-940D-77E63B07918B`. No commits, pushes, stash, checkout, reset or index
operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched.
No `.pbxproj` edit. No mirror triplet touched. No file outside my ownership edited.

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · my five VERIFY classes
`Executed 83 tests, with 0 failures` · full watch suite `Executed 232 tests, with 0 failures` ·
signed macOS `** BUILD SUCCEEDED **` · **counterfactual MEASURED: 2 failures on the pre-fix catalog,
both of them the assertions this round adds, and no other case moved** · `wc -w spec.md` = **19827**,
identical to the baseline · all four catalogs parse, exactly **one row changed, none added, none
removed**.

Files changed — five, none new:

| File | Change |
|---|---|
| `Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift` | r4a#6: `privacyCopy`'s `workboard.voice.privacy` defaultValue, and the property's header comment rewritten to name the two promises the line may not make |
| `Conduck/Conduck/Localizable.xcstrings` | the same value, byte-identical, in lockstep |
| `Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift` | `aiDenialPhrases`; the key-specific case extended and renamed; class-header rule (3) |
| `docs/ai-context/spec.md` | the Work decision and the audio decision rewritten present-tense: five settled facts folded in, four falsehoods repaired, equal length cut inside the same two decisions (19827 → 19827 words) |
| `docs/ai-context/project-structure.md` | `Services/` row (the retry store's role changed to a queue) and `Services/Workboard/` row (the disposable-copy rule, re-homed out of spec.md) |

---

## 1. r4a#6 (minor, O-16) — "never to an AI" is false for several selectable providers. **CONFIRMED, fixed.**

**Verified against the current code by tracing the roster before touching anything**, not by reading
the finding. The sheet renders `workboard.voice.privacy` at
`WorkboardVoiceCaptureView.swift:266-278`; its recorder is `InAppAudioRecorder`, which hands the
clip to whichever provider `STTProvider.all` resolved. Read out of `STTProvider.swift` in the tree:

- `:170-176` — `/// OpenAI gpt-4o-transcribe` … `model: "gpt-4o-transcribe"`
- `:229-237` — `static let gemini = STTProvider(id: "gemini-3-1-flash-lite", … model: "gemini-3.5-transcribe"`
- plus a user-hosted OpenAI-compatible speech endpoint (`settings.stt.custom.connection.footer`:
  "Your own OpenAI-compatible server"), which can be anything the person points it at.

Two of the shipped choices ARE AI models and the third is arbitrary, so "never to an AI" was false —
and, worse than false, false in the direction that understates exposure, frequently to the *same
vendor already answering the person's chat*. The finding holds exactly as written.

### The fix — the boundary that actually holds, in the product's own words

Key kept. Source `defaultValue` and catalog `en` moved together and are byte-identical (verified by
regex extraction of the source literal against the parsed catalog row: **MATCH**, twice — once after
the edit and once after the counterfactual restore):

> Keeps the recording on your private desk and adds the words when they’re ready. The audio goes only
> to the speech provider you chose, and only to be turned into words — never into a conversation, and
> never through a server of ours.

Three deliberate choices in that sentence:

1. **"speech provider", not "transcription service"** — the finding's wording, taken in substance but
   not literally. "Speech provider" / "Speech-to-Text" is the product's OWN shipped vocabulary in
   every other place a person meets this concept (`settings.voice.section.speechToText`,
   `settings.voice.selector.stt`, `diagnostics.voice.setup.stt`, `settings.voice.list.footer`,
   `stt.error.appleSpeechLanguageUnsupported.recovery`, and the Watch's
   "Your speech provider sent an unexpected response"). A second name for one thing, minted on the
   one screen where the person is being told something uncomfortable, is worse copy than a familiar
   name. Recorded as a deviation, §Deviations 1.
2. **"and only to be turned into words"** carries the finding's "never becomes a chat or agent turn"
   in plain language. It is the honest form of the old claim: what Work guarantees is not that the
   destination is not an AI — it may be — but that the audio is used for transcription and for
   nothing else.
3. **"never through a server of ours"** is unchanged in substance and keeps the README's own phrase.
   It also had to avoid the word *sent*: this key is in `outboundHopKeys`, so the vocabulary rule
   scans its value RAW, and "sent"/"send" would trip it. "through" is the word that survives both
   rules.

The property's header comment now states both prohibitions and names the three providers, so the next
person to write this line has the evidence rather than the conclusion.

### Regression test — MEASURED red on the old value

`WorkboardCopyTruthGuardTests.testTheVoiceSheetNamesTheSpeechProviderAndDeniesNeitherTheHopNorTheAI`
(renamed from `…RatherThanPromisingInertness`; the old name described half the rule). Kept both
existing inertness assertions verbatim and added two:

- a scan against a new `aiDenialPhrases` list, whose doc comment carries the provider evidence;
- `XCTAssertTrue(lowered.contains("conversation"))` — having given up both denials, the line has to
  state the boundary that DOES hold, or the fix degrades to a deletion.

`aiDenialPhrases` is a phrase list, not a ban on the word "AI": the honest sentence must stay free to
mention the AI it is drawing a boundary against.

**Counterfactual, measured — not argued.** The guard reads the catalog from disk, so I swapped the
file rather than rebuilding a tree: the fixed catalog was backed up, the pre-fix one (`git show HEAD`,
byte-identical to it) put in its place, the class run, then restored and verified byte-identical by
`diff -q` **and** SHA-256 (`e453762611b6879e…` on both sides). No source, no test and no other file
was touched during the flip.

`cf-1.log` → `** TEST EXECUTE FAILED **`, `Executed 6 tests, with 2 failures (0 unexpected)`, verbatim:

```
WorkboardCopyTruthGuardTests.swift:193: … XCTAssertFalse failed - gpt-4o-transcribe, Gemini and a
custom OpenAI-compatible endpoint are all selectable speech providers and all of them are AI models,
so this line may not promise the recording never reaches one: … never to an AI, never to a server of ours.
WorkboardCopyTruthGuardTests.swift:204: … XCTAssertTrue failed - having given up both denials, the
line has to state the boundary that does hold … : … never to an AI, never to a server of ours.
```

**Exactly the two new assertions, and no pre-existing case moved** — the other five cases pass in the
same run, including `testNoWorkStringDescribesSendingDispatchingOrADraft`, which proves the new value
still clears the un-stripped vocabulary scan that c-copy-docs scoped to this key. Restored-state
re-run: `Executed 6 tests, with 0 failures`.

---

## 2. spec.md — five settled facts folded in, four falsehoods repaired, at ZERO word cost

`wc -w docs/ai-context/spec.md` = **19827 before, 19827 after.** Everything below is paid for inside
the same two decisions, per the one-file rule (a sentence belongs in spec.md only if it cannot be
confirmed by opening one file). Present tense, no changelog narration.

### The five facts, one sentence each

| Fact | Source | Where it now lives |
|---|---|---|
| (a) a capture the app fails to hand back is neither lost nor stranded — the ordinary recovery pass picks it up | c-drainer, via integrate-e §Requests 3 | Work decision: "…a claim the app cannot hand back is retaken by the ordinary recovery pass" |
| (b) one payload publication per material in flight at a time device-wide, app and headless intent included, through an App-Group advisory lock | c-store, via integrate-e §Requests 3 | Work decision: "One process imports a capture and one publishes a payload, app and headless intent alike, behind App-Group locks" |
| (c) a reattach releases the lane it leaves only after the new one is proved readable, so a refused reattach gives the previous payload back | c-store, via integrate-e §Requests 3 | Work decision, merged into the durability clause: "neither is durable, **or released**, until its bytes read back at the length written: a reattach frees the old lane only once the new one reads, so a refusal returns the previous payload" |
| (d) a synced card names the exact bytes it was published with; a device adopts a peer's upload only once some publication of those bytes completed | d-store §Settled facts | Work decision: "A card names the bytes it was published with, so a peer's upload serves it only after a completed publication of them" |
| (e) every pending capture keeps its own recording until it lands on a card or the person discards it; nothing expires a recording whose only copy is the retry | d-retry §Settled facts | Audio decision: "Each waiting capture is queued under its own identifier and keeps its recording; `PendingRetryMetadata.isExpired` reclaims a retryable transcription, never a recording that is a card's only copy" |

(c) is folded into the existing durability clause rather than stated beside it, because
prove-then-release is the same principle the clause already carries — one rule, said once, is what
keeps a reader from finding two.

### Four falsehoods repaired in the same pass, all inside my ownership

1. **`## Work is one desk, and nothing on it is sent` → `## Work is one desk, and nothing on it
   becomes a turn`.** The heading was the same false absolute the voice sheet made: a voice note's
   audio IS sent, to the speech provider. Safe to reword — `grep` over `*.md`/`*.swift`/`*.sh` finds
   no link or anchor to it anywhere outside `docs/qa/`, and `check-spec-cites.sh` still reports its
   one quoted citation (`GeminiSTTProvider.swift:38` → "A transcription provider speaks…") resolving.
2. **"no code path leads from it to an AI" → "to a gateway."** Same defect, zero words. The AI claim
   is unprovable — the person's speech provider may be an AI, and often the same vendor. The gateway
   claim is exactly what the desk enforces and is what `WorkboardCopyTruthGuardTests` guards.
3. **"There is no audio entity in the database, though the attachment entity would permit one" —
   REMOVED as now false.** Model 16's `WorkMaterialBlob` holds a voice note's bytes in the database.
   Replaced in place: "a Work voice note is a desk material **whose bytes ride the desk's own lane**
   instead."
4. **"Two paths deliberately hold a recording longer, both inside the app's own container **and both
   bounded**" — the bound is gone from one of them.** d-retry's `isExemptFromExpiry` means a Work
   capture whose card never landed is never reclaimed by the clock. "both bounded" cut; (e) states
   what is true.

### What paid for it, and where each cut went

| Cut from spec.md | Words | Why it is a legitimate cut |
|---|---|---|
| "GigaAction defaults to Chat for installed-shortcut compatibility" | 8 | Already stated in `project-structure.md`'s `Intents/` row ("Chat remains the migration-safe default"). One home per fact, per integrate-e's O-17 precedent. |
| "External surfaces get disposable copies, never the vault's authoritative URL." | 10 | **Re-homed, not deleted** — moved into `project-structure.md`'s `Services/Workboard/` row (§3). The mechanism is `WorkAssetVault.snapshotFile(for:id:)`, whose own doc comment covers the copy but not the prohibition, so the rule needed a document to live in; project-structure.md carries no word ceiling and is the folder's map. |
| "which is why a failed *send* has a turn in the store to retry from while a failed *transcription* has only the audio" | 23 | Duplicated verbatim in substance two sections later, under "## What one turn does": "A capture that failed *before* any turn existed — speech recognition never succeeded — is the exception, and is the reason the preserved-audio path above exists at all." |
| `PendingRetryMetadata.isExpired` "purged both lazily on read and eagerly at launch" | 9 | One-file: the two purge sites are in `PendingRetryStore.swift`. The clause that survives is the one the code cannot tell you — WHICH records the clock governs. |
| `AppleRelayPendingQueue.maxEntryCount` / `maxEntryAge` → `AppleRelayPendingQueue` | 5 | One-file: two constants in that file. The bound itself is still stated. |
| Compression, no claim dropped | ~30 | "on success and failure alike"→"success or failure"; "a sweeper at launch"→"a launch sweeper"; "before it knows whether anything failed —"→":" (the word *proactively* already carries it); "is a playable card made durable"→"is made durable and playable"; "in both directions at startup"→"both ways at startup"; "no sweep rule"→"no rule"; "three separate times"→"three times"; "a directory listing"→"a listing"; "This is exactly the kind of rule"→"— exactly the kind of rule"; "both easy to undo by accident"→"easily undone by accident". |

**Nothing was relocated to dodge the ceiling and no rejected alternative was deleted** — the two
prohibitions `check-spec-size.sh` names. Both surviving "smaller rules about audio on disk" keep their
full reasoning, including the three-times-made mistake and the logging trap.

**Spec-size guard is PRE-EXISTING FAILURE, unchanged and NOT fixed** (plan §E and §F both forbid it):
exit 1, `19827 words; the ceiling is 16900`, plus the same two unrelated decisions at 687/650 and
701/650. Both are outside Work and audio and I did not open them. **19827 = integrate-e's baseline
exactly.**

## 3. project-structure.md — two rows, both because a file's role changed

- **`Services/`** — the retry store stopped being a slot. Was "retry bookkeeping"; now "the queue of
  unfinished voice captures — keyed by capture, so a second arming never displaces the first, and each
  entry holds its own recording until it lands or the person discards it." That is d-retry's whole
  design change, at the folder level, without naming a type.
- **`Services/Workboard/`** — took the disposable-copy rule re-homed out of spec.md (above): "What a
  surface outside the app is handed is always a disposable copy, never the vault's own file."

**Deliberately NOT changed:** the same row's closing "no code in this folder reaches an AI" — checked,
not assumed: `grep -n 'STTClient\|STTKeyReadiness\|InAppAudioRecorder' Conduck/Conduck/Services/Workboard/*.swift`
returns **nothing**. The speech hop is driven from `Services/InAppAudioRecorder.swift`, one folder up.
Model 16's added `contentHash` column needs no row (a new model attribute does not, per my brief), and
`Views/Workboard/` did not change role — only one string inside it did.

---

## Catalog

**Keys I ADDED in source: NONE.** I mint no keys.

**Keys I made DEAD: NONE.** `workboard.voice.privacy` keeps its key; both halves moved together.

**Nothing was owed to me by wave D.** d-store, d-retry and d-stt each report "Keys ADDED: NONE / Keys
DEAD: NONE" and none of them opened a catalog. **Nothing to splice** — verified independently rather
than taken on their word: the bidirectional `workboard.*` audit over every `.swift` under
`Conduck/Conduck` reports `source-referenced = 147 · catalog rows = 147 · MISSING: [] ·
CATALOG-ONLY: []`, unchanged from integrate-e's 147/147/147.

**The "Discard recording" key was NOT minted** (d-retry §Requests 3 raised it). Nothing in source
declares it: `PendingRetryStore.clear()` still has zero production callers and the retry card offers
no dismiss. Minting a row no source references is exactly what this class's rule (4) and
`testEveryWorkCatalogRowIsReferencedInSource` exist to prevent, and a string is not the missing half
of that affordance — a call site is. Carried forward as §Requests 2.

**I edited exactly one `.xcstrings`**, the main app catalog, one value.
`git status --short -- '*.xcstrings'` lists only `Conduck/Conduck/Localizable.xcstrings`.

### Catalog dict diff — `json.load` + before/after against `git show HEAD:`, all four files

Every one parses. Top-level keys other than `strings` compare **equal** in all four.

| Catalog | keys before → after | added / removed / changed |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2245 → **2245** | +0, −0, **~1** |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 → 43 | none |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 → 42 | none |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 → 299 | none |

```
~ workboard.voice.privacy
    before: 'Keeps the recording on your private desk and adds the words when they’re ready. The audio
             goes only to the speech provider you chose — never to an AI, never to a server of ours.'
    after : 'Keeps the recording on your private desk and adds the words when they’re ready. The audio
             goes only to the speech provider you chose, and only to be turned into words — never into
             a conversation, and never through a server of ours.'
```

U+2019 apostrophe preserved. Nothing added anywhere, nothing removed anywhere.

---

## Decisions

1. **The key kept its name and its `outboundHopKeys` membership.** c-copy-docs' scoping is what makes
   the vocabulary scan read this value raw, and that is the mechanism that would catch a future
   "nothing is sent" creeping back. I widened what the key-specific case checks; I did not touch the
   scoping.
2. **`aiDenialPhrases` is a phrase list, not a ban on the word "AI".** The true sentence has to be
   free to mention the AI it is bounding. Six shapes, each the way a well-meaning writer would deny
   it; the doc comment carries the provider evidence so the list can be extended with cause.
3. **One positive assertion was added, not only prohibitions.** A guard made only of "may not say"
   rules is satisfied by deleting the sentence. `contains("conversation")` is what keeps the fix a
   fix rather than a retreat.
4. **(c) merged into the durability clause instead of standing beside it.** Prove-then-release is one
   rule; stating it twice is how a read path and a write path start disagreeing (d-store §Decisions 1
   made the same call in code).
5. **The disposable-copy rule was re-homed, not dropped.** Deleting a boundary to buy words for a new
   fact would be the worst trade in this task. `project-structure.md` has no ceiling and owns the
   folder it belongs to.
6. **No Codex consult.** The one genuinely hard call — whether the honest sentence should name the
   provider conditionally ("when a cloud provider is configured") — was already settled by
   c-copy-docs §r3a#3 against the same evidence: the sheet cannot see which provider is selected, so
   a conditional sentence needs a second source of truth on screen.

## Deviations

1. **"speech provider", where the finding says "transcription service".** Taken in substance, not
   literally, under the brief's "if a better mechanism exists inside your ownership, use it and say
   why": it is the product's own shipped word on every other surface (six catalog rows quoted in §1),
   and coining a synonym on the one screen delivering uncomfortable news is worse copy. The finding's
   three requirements are all met — one named destination, never a chat or agent turn, never a
   Conduck-operated server.
2. **I changed a spec `##` heading.** My brief scopes me to "Work + audio decisions"; a decision's
   heading is part of it, the heading carried the same falsehood as the string, and nothing links to
   it (checked). `check-spec-cites.sh` passes.
3. **Two spec sentences were CUT rather than reworded** (GigaAction default, disposable copies) and
   one was cut as a duplicate (the send-vs-transcription contrast). Each has a surviving home, named
   in §2. This is the "cut equal length in the same decisions" my brief requires, spent on the
   material that fails the one-file rule rather than on the newest sentences.
4. **I ran the signed macOS build, which is not in my VERIFY list.** It costs minutes, the tree was
   stable (I am the only editor), and it removes any doubt about a shared-target edit. Green.

---

## Gates — WHAT I ACTUALLY RAN

DerivedData under `~/Library/Caches/gigaduck-builds/d-copy/{DerivedData,DerivedDataMac,DerivedDataWatch}`,
every log written there and grepped for `': error: '` and for
`BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — **never judged from a tail or an
exit code**. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`, no throwaway tree
copy (the counterfactual is a file swap on the shared tree, restored and SHA-verified).

- **Simulator TCC checked FIRST**, per the brief:
  `sqlite3 …/2B6E0EAC…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0 (i.e. `.notDetermined`; no stale denial,
  nothing to reset). integrate-e §Requests 5's check, answered.
- **iOS `build-for-testing`** (sim `2B6E0EAC-…`) → `ios-bft-1.log`: `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, five quoted `-only-testing:` flags → `ios-test-1.log`:
  `** TEST EXECUTE SUCCEEDED **`, `Executed 83 tests, with 0 failures (0 unexpected) in 15.492
  (15.509) seconds`, `grep -cE '\.swift:[0-9]+: error: '` = **0**. Per class, from the suite lines:

| Class | Result line |
|---|---|
| `WorkboardCopyTruthGuardTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 12.068 (12.069) seconds` |
| `WorkCaptureInboxTests` | `Executed 29 tests, with 0 failures (0 unexpected) in 0.149 (0.154) seconds` |
| `CarPlayVoiceTimingContractTests` | `Executed 22 tests, with 0 failures (0 unexpected) in 0.054 (0.058) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.782 (2.784) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.438 (0.442) seconds` |

- **Counterfactual** → `cf-1.log`: `** TEST EXECUTE FAILED **`, `Executed 6 tests, with 2 failures
  (0 unexpected)`; both lines quoted verbatim in §1. Restore verified by `diff -q` (**RESTORE OK**)
  and matching SHA-256. Restored-state re-run → `ios-test-restored.log`: `Executed 6 tests, with 0
  failures (0 unexpected) in 12.370 (12.371) seconds`.
- **FULL watch suite** (`-scheme ConduckWatchTests`, sim `28AC563B-…`, `xcodebuild test`) →
  `watch-1.log`: `grep -c ': error: '` = **0**, `** TEST SUCCEEDED **`,
  `Executed 232 tests, with 0 failures (0 unexpected) in 9.464 (9.536) seconds`. **232 exactly**, the
  integrate-e baseline — wave D added no watch case and broke none.
- **macOS `build -destination 'platform=macOS'`** → `mac-1.log`: `grep -c ': error: '` = **0**,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed or used.**
- **Guard scripts**, from the worktree root:
  - `scripts/check-spec-cites.sh` → `✓ spec citations resolve — 798 Swift files scanned, 1 quoted section name(s), every one a live heading`, exit 0
  - `scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped, and every path the map names exists`, exit 0
  - `scripts/check-storage-seam.sh` → `✓ storage seam intact — 798 Swift files scanned, no raw store or live-adapter access outside …LiveStorage.swift`, exit 0
  - `scripts/check-spec-size.sh` → exit **1**, **PRE-EXISTING**: `✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.` plus `"Sending files and getting them back are two capabilities of one lane" 687 / 650` and `"Forgetting a gateway erases the credentials and keeps the colour tag" 701 / 650`. **`wc -w docs/ai-context/spec.md` = 19827, identical to the baseline. Do not read that exit code as mine.**
- **All four catalogs** `json.load` clean; dict diff in §Catalog; bidirectional `workboard.*` audit
  147/147/147, no missing row, no dead row.
- **`git diff --check`** → no output, exit 0. `git diff --cached --stat` → **empty**.
  `git status --short` for `*.pbxproj`, `Conduck/Configs` and `docs/qa` → **empty** on all three;
  for `*.xcstrings` → only the main catalog. My five files and nothing else.
- **Suite delta from this slice: 0.** `WorkboardCopyTruthGuardTests` stays at 6 cases — the two new
  assertions live inside an existing case, renamed. iOS total is unchanged by me.
- **Build caches and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh d-copy`, along with both
  counterfactual catalog copies. Re-run to reproduce.

### What I did NOT verify, plainly

- **The full iOS suite.** Not in my VERIFY; my production change is one string literal and comments,
  and my test change is inside one class, all five of whose neighbours in the VERIFY set are green.
  The gate still owes the full run for the wave.
- **No screen.** There is no UI-test target by decision. That the new sentence FITS the sheet's
  caption at the largest Dynamic Type size is a founder-QA item (§Founder QA 1) — it is 42 words
  against the old 33, on a `.font(.caption)` label inside a `ScrollView`.
- **Nothing about a real provider.** The finding is about what the copy claims, not about what any
  vendor does; no network call was made or needed.

---

## Requests

1. **Founder copy call — O-16(a) is superseded, not closed.** The voice sheet's privacy line is now
   the second attempt at the one sentence that tells a person where their recording goes, and it is
   the first honest one: it concedes the destination may be an AI. The founder's call is whether
   "and only to be turned into words — never into a conversation" reads as reassurance or as a
   confession. I chose the disclosing direction deliberately, twice (c-copy-docs did the same on the
   sending half). The other O-16 items (the three desk-banner sentences, the drop-overlay caption,
   the recovered-note title, the tutorial line and the large-file confirm) are untouched by me and
   still stand.
2. **Owner of the retry card / Settings — the "Discard recording" affordance still has no home, and
   d-retry's change makes it matter more.** With `isExemptFromExpiry`, a Work capture the desk never
   accepted keeps its bytes in the App Group **indefinitely**, and `PendingRetryStore.clear()` has
   zero production callers. I minted no string for it: a key with no call site is a dead catalog row
   this class's own rule (4) forbids, and the missing half is a button, not a sentence. When someone
   adds the call site, the string is one splice — tell me the key and I will do it in lockstep.
3. **Nobody re-add an AI denial to `workboard.voice.privacy`, in any language.** The English row is
   guarded; a translator "restoring" the crisper old sentence in another locale is not, and it would
   be the same false claim. The `aiDenialPhrases` doc comment carries the reason so a reviewer of a
   localisation PR has it.
4. **Nobody delete the positive half of the guard.** Two prohibitions and no requirement is a rule
   satisfied by deleting the sentence; `contains("conversation")` is what stops that.
5. **Integrator — the spec-size guard exits 1 and must be recorded as PRE-EXISTING** (plan §E and §F
   both say not to fix it). 19827 words, identical to integrate-d's and integrate-e's number. The two
   over-limit decisions are unrelated to Work and untouched.
6. **Integrator — the wave's five settled facts are now in a document** (§2), so integrate-e
   §Requests 3 and d-store's / d-retry's docs requests are CLOSED. No wave-D fixnote carries a docs
   request I have not taken.

## Refuted

**Nothing.** r4a#6 held exactly as written when traced against the provider roster before any edit —
`STTProvider.swift:170-176` and `:229-237` name two AI models among the selectable speech providers,
and the custom OpenAI-compatible endpoint is arbitrary. The design direction was implementable as
written, with one substitution recorded as a deviation (§Deviations 1: the product's own word
"speech provider" in place of "transcription service").

**One clause of the finding is UNDERSTATED rather than wrong**, and I say so in §1: the finding scopes
the falsehood to the voice sheet, but `spec.md` carried the identical absolute in two places — a
section heading ("nothing on it is sent") and a decision sentence ("no code path leads from it to an
AI"). Both are repaired here, at zero word cost.

---

## Founder QA — device-only checks this change needs

1. **The sentence fits, at the size a person actually uses.** Open Work → the microphone → the voice
   sheet, on the smallest iPhone you have, with Settings → Display & Brightness → Text Size pushed
   near the top and again with Accessibility → Larger Text on. The privacy line is 42 words where it
   was 33; it must stay readable and must not push the Record button off-screen (the sheet scrolls,
   so the failure to look for is a button you have to hunt for, not clipped text).
2. **Read it as a stranger would.** With Apple on-device speech selected, and again with a cloud
   provider selected, read the line aloud. It says the same thing in both configurations by design —
   the sheet cannot see which provider is active. The question for the founder is whether the
   unconditional sentence is honest in the on-device case rather than needlessly alarming.
3. **VoiceOver.** The line is a `Label` with a `lock.shield` glyph; confirm VoiceOver reads the whole
   sentence and does not stop at the dash.
4. **The docs claims that only two devices can show** — carried from d-store and c-store, now written
   into spec.md and therefore worth confirming rather than assuming: a refused reattach gives the
   card its previous payload back, and a peer's upload never becomes a card's payload before that
   card's own publication of those bytes completed. Both are in integrate-e's O-17 Gate-2 list.
5. **The queue claim spec.md now makes** — from d-retry: arm two failing captures (one Work, one
   Chat) in airplane mode, wait **over ten minutes**, reopen. Both must still be offered and both
   must finish. spec.md now says the ten-minute clock never reaches a recording that is a card's only
   copy; this is the check that it is true on a device.

---

## Settled facts — one sentence each, for whoever writes the next document

- A Work recording goes to exactly one destination, the speech provider the person selected, and it
  is used only to produce words — it never becomes part of a conversation and never passes through a
  server Conduck operates.
- Some of those selectable speech providers are themselves AI models (`gpt-4o-transcribe`, Gemini,
  and any user-hosted OpenAI-compatible endpoint), so no Conduck surface may promise that a recording
  never reaches an AI.
- What the Work desk actually guarantees is that nothing on it becomes a turn: there is no code path
  from the desk to a gateway.
- A voice note's bytes live in the database, in the payload store beside the desk, so "there is no
  audio entity" is no longer true of this app.
- A Work capture the desk never accepted keeps its recording without a time limit; the ten-minute
  budget governs retrying a transcription, not preserving a recording that is the only copy.
- The rule that an external surface is handed a disposable copy and never the vault's own file lives
  in `project-structure.md`'s `Services/Workboard/` row, not in `spec.md`.
