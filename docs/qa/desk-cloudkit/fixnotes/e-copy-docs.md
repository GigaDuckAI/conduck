# e-copy-docs — six keys spliced (one of them corrected to a plural), five settled facts folded into spec.md at ZERO word cost, two project-structure rows. Nothing refuted.

Label `e-copy-docs`. Slug `e-copy-docs`. Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, watch sim
`28AC563B-42C1-4E66-940D-77E63B07918B`. No commits, pushes, stash, checkout, reset or index
operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched.
No `.pbxproj` edit. No mirror triplet touched (`git status` lists none of the three).

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · six VERIFY classes
`Executed 76 tests, with 0 failures` · full watch suite `Executed 232 tests, with 0 failures` ·
**two counterfactuals MEASURED**, 3 cases red on the pre-splice catalog and exactly 1 case red on a
singular-only count row, with no other case moving in either · `wc -w spec.md` = **19827 before,
19827 after** · catalog **2245 → 2251 rows, +6, −0, ~0**; the other three catalogs byte-untouched.

Files changed — five, none new:

| File | Change |
|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | the six `pendingRetry.card.*` keys e-surfaces declared, raw-line spliced; `pendingRetry.card.count` carries plural variations |
| `Conduck/Conduck/Views/Components/PendingRetryCard.swift` | one word in the discard confirmation's `defaultValue`, in lockstep with the catalog row (`can't` → `cannot`) |
| `Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift` | rule (4) widened to `pendingRetry.*`; new rule (5) — two cases: the discard confirmation's two required claims, and the count row's plural categories |
| `docs/ai-context/spec.md` | Work decision + the audio paragraphs of "Data, secrets…" rewritten present-tense: five settled facts folded in, one inaccurate bound corrected, equal length cut inside the same two decisions (19827 → 19827) |
| `docs/ai-context/project-structure.md` | `Services/` (claim, lease, per-entry durability) · `Services/Workboard/` (the escape identifier) · `Views/Workboard/` (the shell's two drafts, re-homed out of spec.md) · "Landing something on the Work desk" (names `WorkMaterialCollisionEscape.swift`) |

---

## 1. The splice — what each e-* fixnote owed, and what it got

I read `## Catalog` in all five e-* notes before opening anything.

| Fixnote | Keys ADDED | Keys DEAD | Catalog opened |
|---|---|---|---|
| `e-drainer` | none (the `refusal.txt` body is forensic text nobody reads) | none | no |
| `e-queue` | none | none | no |
| `e-recover` | none | none | no |
| `e-store` | none | none | no |
| `e-surfaces` | **six** | none | no |

So exactly six rows were owed, and **no row was made dead by wave E** — I removed none. Verified
independently rather than on their word: the bidirectional audit below found precisely those six
missing and nothing orphaned.

### Bidirectional audit — before and after, both prefixes

Every `.swift` under `Conduck/Conduck` concatenated; keys matched as full quoted literals.

```
BEFORE
workboard.       declared/referenced=147  rows=147  MISSING=[]  CATALOG-ONLY=[]
pendingRetry.    declared/referenced=8    rows=2    CATALOG-ONLY=[]
                 MISSING=['pendingRetry.card.busy', 'pendingRetry.card.count',
                          'pendingRetry.card.discard', 'pendingRetry.card.discard.confirm.action',
                          'pendingRetry.card.discard.confirm.body',
                          'pendingRetry.card.discard.confirm.title']
AFTER
workboard.       declared/referenced=147  rows=147  MISSING=[]  CATALOG-ONLY=[]
pendingRetry.    declared/referenced=8    rows=8    MISSING=[]  CATALOG-ONLY=[]
```

`workboard.*` is 147/147/147, unchanged from integrate-e's and d-copy-docs' number — wave E added and
killed no Work key.

### Catalog dict diff — `json.load` before/after, all four files

Top-level keys other than `strings` compare **equal**. Every one parses.

| Catalog | rows before → after | added / removed / changed |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2245 → **2251** | **+6**, −0, ~0 |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 → 43 | none |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 → 42 | none |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 → 299 | none |

```
+ pendingRetry.card.busy
    {"extractionState": "extracted_with_value", "localizations": {"en": {"stringUnit":
     {"state": "new", "value": "This recording is already being finished. Try again in a moment."}}}}
+ pendingRetry.card.count
    {"extractionState": "extracted_with_value", "localizations": {"en": {"variations": {"plural":
     {"one":   {"stringUnit": {"state": "new", "value": "%lld recording waiting"}},
      "other": {"stringUnit": {"state": "new", "value": "%lld recordings waiting"}}}}}}}
+ pendingRetry.card.discard
    {"extractionState": "extracted_with_value", "localizations": {"en": {"stringUnit":
     {"state": "new", "value": "Discard recording"}}}}
+ pendingRetry.card.discard.confirm.action
    {"extractionState": "extracted_with_value", "localizations": {"en": {"stringUnit":
     {"state": "new", "value": "Discard"}}}}
+ pendingRetry.card.discard.confirm.body
    {"extractionState": "extracted_with_value", "localizations": {"en": {"stringUnit":
     {"state": "new", "value": "This deletes the recording from this device. It cannot be recovered."}}}}
+ pendingRetry.card.discard.confirm.title
    {"extractionState": "extracted_with_value", "localizations": {"en": {"stringUnit":
     {"state": "new", "value": "Discard this recording?"}}}}
```

Raw-line splice, inserted at line 7322 immediately before `"pendingRetry.headline"` — the position
the catalog's own collation puts them in (`…card.busy` … `…card.discard.confirm.title` all precede
`…headline`, and a shorter key precedes its own longer prefix-mate, as
`workboard.capture.discarded.message` precedes `…message.one` at `:21789-21800`). Two-space indent
and the ` : ` separator match every neighbouring row.

### Source `defaultValue:` == catalog `en`, byte-identical — verified, not asserted

A script re-extracted every `String(localized:defaultValue:)` literal for the six keys from source
(multi-line `"""` literals unwrapped through their `\` continuations, `\(intExpr)` normalised to
`%lld` the way extraction does) and compared to the catalog value — the plural row's `other`
category being the one that must match the source form:

```
MATCH    pendingRetry.card.busy  (2 call site(s))
MATCH    pendingRetry.card.count  (2 call site(s))
MATCH    pendingRetry.card.discard  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.action  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.body  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.title  (1 call site(s))
call sites scanned: 8
ALL SOURCE defaultValue == CATALOG en (byte-identical): True
```

The two double-referenced keys (`busy`, `count`) carry the identical literal in both files, as
e-surfaces said they would.

---

## 2. Copy pass — one correction of substance, one of style

### (a) `pendingRetry.card.count` needed plural variations. This is a rendering DEFECT, not taste.

e-surfaces drafted one value, `"%lld recordings waiting"`, and its own comment on the iOS card is
right that the card renders it only above one (`PendingRetryCard.swift:97`, `if pendingCount > 1`).
But the key has a **second** call site, and that one has no such gate:
`MenuBar/DictationService.swift:491-511`, `settleAfterFinishing`, sits inside
`guard pendingRetryCount > 0 else { … state = .idle … }` — so the smallest count that reaches the
sentence on macOS is **one**, and a single-value row ships **"1 recordings waiting"** to a Mac user.

Fixed in the catalog alone, which is where plural rules belong: `one` = `%lld recording waiting`,
`other` = `%lld recordings waiting`, the same shape the catalog already uses at
`settings.usage.detail.threads.files` (`%lld file` / `%lld files`). The source `defaultValue:` cannot
express a plural and is left exactly as e-surfaces wrote it — at runtime the catalog row wins, and
the interpolated `Int` drives the category. No source edit, no lockstep to break.

### (b) `pendingRetry.card.discard.confirm.body` — `can't` → `cannot`, source and catalog together

The app has exactly one other destructive-confirmation body, and it reads
*"This removes every conversation from this device and all your other devices. **This cannot be
undone.**"* Two flat sentences, the second an uncontracted absolute. The retry card's discard is the
same class of dialog — it deletes bytes nothing will ever reclaim — so it takes the same register:

> This deletes the recording from this device. It cannot be recovered.

Both required claims survive verbatim: *this device*, and *cannot be recovered*. The apostrophe was
not the reason (measured: 335 catalog rows carry an ASCII apostrophe against 16 with U+2019, so
`can't` would have been in-convention); the register was. One word, changed in the source literal
and the catalog row in the same edit.

### (c) The other four, and the sixth key: kept as e-surfaces wrote them

- `pendingRetry.card.discard` = "Discard recording" — the shape of `composer.attach.remove`
  ("Remove attachment").
- `pendingRetry.card.discard.confirm.title` = "Discard this recording?" — the shape of
  `workboard.material.remove.confirm.title` ("Remove this material?").
- `pendingRetry.card.discard.confirm.action` = "Discard" — already the app's word at
  `popover.capture.discard` and `settings.editor.discard.confirm`.
- `pendingRetry.card.busy` = "This recording is already being finished. Try again in a moment." —
  deliberately agent-less, because the holder may be a Shortcut rather than another window.
- The cancel is `common.cancel`, reused, not minted.

The count's fragment form ("2 recordings waiting") is a founder call rather than a defect — see
§Requests 1.

### Regression tests — both MEASURED red, on two separate counterfactuals

`WorkboardCopyTruthGuardTests` 6 → **8 cases**. The guard reads the catalog from disk, so each
counterfactual is a file swap on the shared tree rather than a rebuilt copy; the fixed catalog was
backed up and restored, `diff -q` **RESTORE OK** and SHA-256 `59eeed7194376c0e…` identical on both
sides. No source, no test and no other file moved during either flip.

**Counterfactual 1 — the pre-splice catalog** (`cf-1.log`): `** TEST EXECUTE FAILED **`,
`Executed 8 tests, with 8 failures (0 unexpected)`. Three CASES red, the eight being assertion
failures inside them; the other five cases passed in the same run:

```
testEveryWorkKeyInSourceHasACatalogRow                        (×6, one per missing row)
  :308: XCTAssertNotNil failed - pendingRetry.card.busy is referenced in the app target but has
        no catalog row — it would render from its defaultValue and could never be translated.
testTheBacklogCountRowCarriesPluralVariations
  :368: XCTUnwrap failed … - the backlog count has no catalog row
testTheDiscardConfirmationSaysWhereTheRecordingIsAndThatItIsGone
  :340: XCTUnwrap failed … - the discard confirmation has no catalog row
```

**Counterfactual 2 — the six rows present, but `pendingRetry.card.count` as e-surfaces' single
value** (`cf-2.log`): `Executed 8 tests, with 1 failure (0 unexpected)` — **exactly one case**, and
it is the plural one:

```
:367: XCTUnwrap failed: expected non-nil value of type "Dictionary<String, String>" -
      pendingRetry.card.count renders a number and must carry plural variations —
      MenuBar/DictationService.swift renders it at a count of one.
```

That is the isolation that proves (a) is a real fix rather than a preference: nothing else in the
class moves.

**How I know the widened rule (4) is what caught the missing rows** rather than an unrelated
change: rule (4) was `workboard.*`-only before this edit, and all six missing keys are
`pendingRetry.*`. On the pre-splice catalog with the pre-splice guard the class was green — that is
d-copy-docs' recorded `Executed 6 tests, with 0 failures`.

**What the guard deliberately does NOT do:** `pendingRetry.*` is excluded from rule (1), the
vocabulary scan. Those keys are legitimately allowed to say *sent* — `pendingRetry.headline` is
"Your last recording couldn't be sent." and the queue behind it holds Chat captures, where a send is
exactly what failed. Widening rule (1) would have made a true sentence fail. The class header now
states that split and why.

The discard case accepts `cannot be recovered` **or** `can't be recovered`: my §2(b) change is a
register call, and pinning the contraction would be a test written to match one author's ear rather
than to protect a claim. What it protects is the two claims — the device, and the finality.

---

## 3. spec.md — five settled facts folded in, one inaccurate bound corrected, at ZERO word cost

`wc -w docs/ai-context/spec.md` = **19827 before, 19827 after** — integrate-e's, d-copy-docs' and
integrate-f's number exactly. Everything is paid for inside the two decisions I touched: the Work
decision (`## Work is one desk, and nothing on it becomes a turn`, 228 → 272 words) and the audio
paragraphs' home (`## Data, secrets, and what leaves the device`, 989 → 945). **+44 / −44.** Present
tense, no changelog narration.

### The five facts my brief names, one sentence each

| Fact | Source | Where it now lives, verbatim |
|---|---|---|
| **The corrected duplicate-blob bound** | e-store r5s#4 | Work decision: "…and a publication dying before its card strands a payload row nothing may sweep, since the two are indistinguishable; the row goes when the card's bytes are replaced or the card is deleted" |
| **The collision-escape rule** | e-drainer + e-recover | Work decision: "A capture whose identifier already names a card of another kind is republished under one escape identifier derived from it, so every process and replay repairs the same card; a second refusal is terminal and retires it, files intact." |
| **Per-entry queue durability (armed sidecar / tombstone)** | e-queue K3 | Audio bullet: "…its record written before its bytes and its removal tombstoned before anything goes, so an interrupted arm or discard finishes rather than half-existing" |
| **The lease** | e-queue K2 + e-surfaces K5 | Audio bullet: "A surface reserves the capture it is finishing for ten minutes, so two open surfaces never take the same recording; a reservation nobody completes lapses." |
| **The discard affordance** | e-surfaces K5 | Audio bullet, hung on the sentence that creates the need: "`PendingRetryMetadata.isExpired` reclaims a retryable transcription, never a recording that is a card's only copy — which is why the card carries a confirmed discard as the only way out." |

**On "replace any 'bounded' claim that is inaccurate":** the inaccurate sentence integrate-f carries
under O-20 — *"Two blob rows carrying identical bytes for one card are a normal, bounded state"* —
is in a fixnote, not in spec.md. `grep -n 'bound' docs/ai-context/spec.md` returns eleven lines and
**none of them is about blobs**; d-copy-docs had already cut the one nearby "both bounded" (from the
audio paragraph). So there was nothing to replace, and e-store's corrected statement goes in as a
new claim: the bound is *persistence*, not a count — one row per publication that dies between the
bytes and the card, held until the card's bytes are replaced or the card is deleted, and no sweep
may take them because a stranded attempt is indistinguishable from a peer's upload that arrived
ahead of the card naming it.

### Facts I deliberately did NOT put in spec.md

- **e-store's synced-row repair** ("a replay carrying a card's bytes brings every row of that card
  back onto them whenever any row disagrees"). Not named in my brief, and it is confirmable by
  opening `ConversationStore+Workboard.swift` — the one-file rule `check-spec-size.sh` prints on
  every failure. It is preserved under §Settled facts here instead. The user-visible consequence
  that DOES span files (a card cannot stay "Waiting for iCloud…" on the device holding the file) is
  already implied by the Work decision's "a recapture repairs a bytes-less card".
- **e-drainer's `refused/` retirement location.** The decision ("retired, files intact") is in;
  the directory name is one file's business.

### What paid for it, and where each cut went

Nothing was relocated to dodge the ceiling and no rejected alternative was deleted — the two
prohibitions `check-spec-size.sh` names.

| Cut | Words | Why it is a legitimate cut |
|---|---|---|
| Work decision: "so a failed transcription costs the words and never the recording" | 11 | Said again 77 lines later in the audio bullet it belongs to ("keeps its recording so the user can retry rather than repeat themselves"). One home per fact. |
| Work decision: "a reattach frees the old lane only once the new one reads, so a refusal returns the previous payload" → "so a refused reattach returns the previous payload" | 11 | Pure compression; prove-then-release is already carried by "neither is durable **or released** until its bytes read back at the length written", which is the clause d-copy-docs merged it into. |
| Work decision: "The Work/Chats shell preserves both drafts." | 7 | **Re-homed, not deleted** — `project-structure.md`'s `Views/Workboard/` row now says the shell "keeps both drafts alive across a switch between the two". It is a property of one folder's views and project-structure.md carries no ceiling. |
| "Data, secrets": "and so do the secrets named below" | 7 | Said twice more in the same section — the `**Secrets.**` paragraph ("arrive over the phone-to-watch relay") and the paragraph after it ("the phone hands the active speech key and gateway token to the paired Watch over the device-to-device relay"). |
| "Data, secrets": the gloss on the unread cutoff, "— the moment before which nothing counts as unread —" | 11 | Its own `###` decision explains it in full 140 lines earlier ("One account-wide cutover keeps imported history from arriving unread": "It is a single value in the key-value store…"). What this section owes is the LOCATION claim, which survives. |
| Audio bullet: "it arms on the speech-to-text hop, not the gateway hop" | 11 | That asymmetry is an entire `###` decision of its own ("The gateway hop never retries by itself; speech recognition does"). |
| "Data, secrets": "There is one non-obvious threat to that guarantee." folded into the next sentence; "as transitive dependencies" → "transitively"; "which is why the avoidance is written down instead of assumed" | 20 | The last is meta-justification for writing the paragraph down, in a document whose whole purpose is writing things down. Every claim about the call graph survives. |
| Compression carrying no claim | ~40 | "the phone is the one transcribing"→"the phone transcribes"; "held on the wrist only until"→"held only until"; "for itself"→"itself"; "so simulator runs are"→"so runs there are"; "the app's own sandbox"→"the app's sandbox"; "has already been shown"→"was shown"; "and are easy to forget"→"and easy to forget"; "never logged and never appears in"→"never logged or shown in"; "shows to another"→"shows another"; "Note a platform trap"→"A platform trap"; "both need a file"→"need a file"; "is written to scratch storage and deleted"→"goes to scratch storage and is deleted"; "a clip the user has already spoken"→"a clip already spoken"; "three times, which is why a test scans"→"three times, so a test scans"; "easily undone by accident"→"easily undone"; "Apple's own on-device speech-model download"→"the on-device speech-model download"; "where a gateway has one, its file server"→"a gateway's file server where it has one"; "rather than reaching out to fetch one"→"rather than fetching one"; "the user's own private iCloud" kept everywhere it is a privacy claim. |

**Spec-size guard is a PRE-EXISTING FAILURE, unchanged and NOT fixed** (plan §E and §F both forbid
fixing it): exit **1**, `✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.` plus the
same two unrelated decisions, `"Sending files and getting them back are two capabilities of one
lane" 687 / 650` and `"Forgetting a gateway erases the credentials and keeps the colour tag"
701 / 650`. Both are outside Work and audio and I did not open them. **No new over-limit decision
appears** — the Work decision is 272 words and the per-decision check counts `###` sections, of
which I touched none.

## 4. project-structure.md — four rows, each because a file's or folder's role changed

- **`Services/`** — the retry queue gained an owner-per-attempt and a crash protocol: "A surface
  claims one entry at a time under a ten-minute lease, so two of them cannot finish the same
  recording; an entry's record is written before its bytes and its removal is tombstoned before
  anything goes, so an arm or a discard interrupted by process death resolves on the next launch
  instead of half-existing."
- **`Services/Workboard/`** — took the escape derivation, described by role rather than filename
  (the folder rows deliberately do not list files): "the derivation of the one escape identifier a
  capture's bytes land under when the capture's own identifier already names a card of another
  kind".
- **`Views/Workboard/`** — took the shell's two-draft rule re-homed out of spec.md.
- **"Landing something on the Work desk from a new surface"** (the "Where to start" table, which
  DOES name files) — `Conduck/Conduck/Services/Workboard/WorkMaterialCollisionEscape.swift` beside
  the write it protects, with the reason a lane must derive rather than mint: "which is what makes
  two processes and any later replay repair the same card".

`scripts/check-folder-map.sh` passes — 36 Swift source directories, all mapped, every path the map
names exists; `WorkMaterialCollisionEscape.swift` is a new file in an already-mapped folder, so the
folder map needed no new row and got none.

---

## Catalog

**Keys I ADDED in source: NONE.** I mint no keys; I splice the ones source already declares.

**Keys I ADDED to the catalog: the six e-surfaces declared**, listed with their exact rows in §1.
Five carry a single `en` value; `pendingRetry.card.count` carries plural variations (§2a).

**Keys I made DEAD: NONE.** No row was removed from any catalog; no source reference was deleted.

**Catalogs opened: one.** `git status --short -- '*.xcstrings'` lists only
`Conduck/Conduck/Localizable.xcstrings`. The Watch and the two share extensions were read (to prove
none of these keys lives there — `grep -rn 'pendingRetry\.'` over all three: no hits) and not
written.

**One source string literal changed in lockstep:** `pendingRetry.card.discard.confirm.body` in
`Conduck/Conduck/Views/Components/PendingRetryCard.swift`, `can't` → `cannot` (§2b). It is the only
production line I touched in wave E's files.

---

## Requests

1. **Founder copy call — the backlog count is a fragment, deliberately, and it renders in two very
   different places.** "2 recordings waiting" is a caption under the iOS card's Retry button and,
   on macOS, the whole message of the menu-bar popover's error state. It reads fine as a caption and
   slightly terse as a popover sentence. The alternative — "2 recordings waiting to retry." — is a
   two-file source edit (`PendingRetryCard.swift` + `MenuBar/DictationService.swift`, which must
   stay identical) plus the catalog row, so it is one splice whenever the founder wants it. I did
   not make the call unilaterally because the fragment is not wrong, only plain.
2. **Founder copy call — the discard confirmation is now uncontracted** ("It cannot be recovered"),
   matching the delete-all-conversations dialog, where every other pendingRetry sentence contracts
   ("couldn't be sent"). If the founder prefers the contraction throughout, it is one word in two
   files and the guard accepts both forms by design.
3. **e-drainer §Requests 1 is NOT closed and I did not close it.** `workboard.capture.discarded.
   message.one` ("Conduck couldn't read one shared item, so it wasn't added to your board.") is now
   half true for a terminally refused capture: Conduck read it fine and its file still exists in
   `refused/`. A truer sentence has to cover both sources without promising a way to reach
   `refused/`, which there is not. That is a rewrite of a shipped Work string on a surface
   (`PersonalWorkbenchView.swift`) nobody in wave E owns, and it is a founder copy call, not a
   splice. **Recommended wording to react to, not to ship:** "Conduck couldn't add one shared item
   to your board." — true of both causes, promises nothing.
4. **e-surfaces §Requests 4 — `diagnostics.voice.pendingRetry.waiting`.** Still not minted, and
   correctly so: nothing in source references it, and
   `testEveryWorkCatalogRowIsReferencedInSource` would fail on a row with no call site. Note the
   guard now walks `pendingRetry.*` in that direction too, so a future agent that mints this key
   **must** land the `if` in `DiagnosticsRunner` in the same edit. Tell me the key and the call site
   and it is one splice.
5. **Integrator — the spec-size guard exits 1 and must be recorded as PRE-EXISTING.** 19827 words,
   identical to integrate-d's, integrate-e's and integrate-f's number, with the same two unrelated
   over-limit decisions. Plan §E and §F both say not to fix it. Do not read that exit code as mine.
6. **Integrator — suite arithmetic.** `WorkboardCopyTruthGuardTests` 6 → **8** (+2). That is my
   whole delta; every other class I ran is at its recorded count
   (`ErrorSurfaceDriftGuardTests` 7, `WorkCaptureInboxTests` 29, `CarPlayVoiceTimingContractTests`
   22, `WorkboardDeskSurfaceDriftGuardTests` 1, `PendingRetrySurfaceHandoffTests` 9). Watch **232**,
   unchanged.
7. **Nobody undo these** — each is pinned by a case measured red on a counterfactual:
   - Rule (4) walks BOTH prefixes. Narrowing it back to `workboard.*` is counterfactual 1 exactly,
     and it is what let six referenced keys ship with no row.
   - `pendingRetry.card.count` keeps plural variations. Flattening it to one value is
     counterfactual 2, and it renders "1 recordings waiting" on a Mac.
   - `pendingRetry.*` stays OUT of rule (1). Those rows may say *sent*, because the queue behind
     them holds Chat captures and a send is what failed.
   - The discard confirmation keeps both claims — the device and the finality. A dialog with only
     "are you sure?" asks a question the person cannot answer.
   - The two-word test names are not decoration: the discard case is the ONLY guard on the app's one
     destructive Work affordance.
8. **Whoever next widens the guard.** `catalogPrefixes` is the single place rule (4)'s scope lives,
   and `workKeys(in:prefix:)` now takes its prefix explicitly (a `Self.keyPrefix` default argument
   does not compile: *covariant 'Self' type cannot be referenced from a default argument
   expression*). Add a prefix there and both directions follow.

---

## Refuted

**Nothing.** Every fact the e-* notes carry held when traced against the code before I wrote it
down, and every design direction in my brief was implementable as written. Two clarifications rather
than refutations:

1. **"Replace any 'bounded' claim that is inaccurate" had no referent in spec.md.** The inaccurate
   sentence lives in `integrate-f.md`'s O-20 list; `grep -n 'bound' docs/ai-context/spec.md` shows
   eleven matches and none is about blob rows. d-copy-docs had already removed the neighbouring
   "both bounded" from the audio paragraph. e-store's corrected statement therefore went in as a new
   claim rather than as a replacement. §3 says so at the point it matters.
2. **e-surfaces' six keys were declared correctly, but one of them was under-specified**, and the
   defect is real rather than stylistic: the count key's second call site
   (`MenuBar/DictationService.swift:491-511`) has no `> 1` gate, so a single-value row ships
   "1 recordings waiting". Fixed in the catalog, which is where a plural rule belongs, with no
   source change — and measured red as counterfactual 2. This is a correction to a sibling's
   declaration, not a refutation of a finding.

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven, e-queue's six and e-surfaces' eight, which all still apply. Mine are
all "read the words on the screen" checks; none needs a staged failure.

1. **The count, at exactly one, on the Mac.** e-surfaces' §Founder QA 2 already has you park two
   recordings and retry from the menu bar. When the first succeeds and one is left, the popover must
   say **"1 recording waiting"** — singular. "1 recordings waiting" means the plural row did not
   ship, and it is the one thing about this change a person would actually notice.
2. **The count, at two and above, on the iPhone card.** "2 recordings waiting". The card does not
   render the line at one (the headline already says a recording is waiting), so the singular
   category is macOS-only in practice — but it exists for both.
3. **Read the discard dialog aloud.** Title "Discard this recording?", body "This deletes the
   recording from this device. It cannot be recovered.", buttons "Discard" and "Cancel". The
   question for the founder is register: this is the second-most consequential dialog in the app
   after Delete All Conversations, and it is deliberately written in that dialog's uncontracted
   voice rather than in the retry card's chattier one ("Your last recording couldn't be sent.").
4. **The busy sentence, on both surfaces.** "This recording is already being finished. Try again in
   a moment." It names no holder on purpose — the holder may be a Shortcut running in another
   process, and naming a window would be wrong there.
5. **Dynamic Type on the confirmation.** The body is 12 words on a system dialog, so this is a
   glance rather than a test; what to look for is the "Discard" and "Cancel" buttons still both
   reachable at the largest accessibility sizes.
6. **VoiceOver over the count line.** It is a plain caption with no accessibility label of its own;
   confirm it is read at all, and read as "2 recordings waiting" rather than as a bare number.

---

## Settled facts

One sentence each; true of the code and the documents as they now stand.

- The retry card's five sentences and the menu bar's backlog sentence are one set of six catalog
  rows, and the count row is the only one carrying a plural rule — the singular is reachable on the
  Mac, where the menu bar names the backlog at any size from one upward.
- A source `defaultValue:` cannot express a plural; the catalog row can, it wins at runtime, and the
  two are still byte-identical because the source form is the row's `other` category.
- The Work copy guard now walks both `workboard.*` and `pendingRetry.*` in both directions, so a key
  referenced with no row and a row nobody references both fail the build on either prefix.
- `pendingRetry.*` is deliberately exempt from the guard's vocabulary rule: the queue behind those
  strings holds Chat captures, where a failed *send* is exactly what happened.
- The discard confirmation is guarded on two claims rather than on its wording — that the recording
  is on this device, and that it does not come back — because a confirmation that asserts neither is
  a dialog the person cannot answer.
- A capture whose identifier already names a card of another kind is republished under one escape
  identifier derived from it, so every process and every replay repairs the same card, and a second
  refusal is terminal and retires the capture with its files intact.
- A publication that dies between saving a card's bytes and saving the card strands one payload row,
  which persists until the card's bytes are replaced or the card is deleted; no sweep may remove it,
  because a stranded attempt is indistinguishable from a peer's upload that arrived ahead of the
  card naming it.
- Each waiting capture writes its record before its bytes and commits the queue last, and a removal
  writes a tombstone before it takes anything away, so an interrupted arm or discard finishes on the
  next launch rather than half-existing.
- A retry surface reserves the capture it is finishing for ten minutes, so two surfaces open at once
  never take the same recording, and a reservation nobody completes lapses.
- Nothing reclaims a Work recording the desk never accepted, which is why the retry card carries a
  confirmed discard — it is the only way to be rid of one.
- A replay that carries a card's bytes brings every physical row of that card back onto them
  whenever any row disagrees, so a merge cannot leave a card waiting for iCloud on the device that
  holds the file (e-store's fact; kept here rather than in spec.md, because it is confirmable by
  opening `ConversationStore+Workboard.swift`).
- The rule that the Work/Chats shell keeps both drafts alive across a switch lives in
  `project-structure.md`'s `Views/Workboard/` row, not in `spec.md`.
- `spec.md` holds at 19827 words across four consecutive integrations; every fact added since
  integrate-d has been paid for inside the decision that received it.

---

## Gates — WHAT I ACTUALLY RAN

DerivedData under `~/Library/Caches/gigaduck-builds/e-copy-docs/{DerivedData,DerivedDataWatch}`,
every log written there and grepped for `': error: '` and for
`BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — **never judged from a tail or
an exit code**. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`, no throwaway
tree copy (both counterfactuals are file swaps on the shared tree, restored and SHA-verified).

- **Simulator TCC checked FIRST:**
  `sqlite3 …/2B6E0EAC…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0 (`.notDetermined`; no stale denial,
  nothing to reset).
- **iOS `build-for-testing`** (sim `2B6E0EAC-…`) → `ios-bft-2.log`: `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`. The first attempt (`ios-bft-1.log`) failed with **one** error,
  `WorkboardCopyTruthGuardTests.swift:388:63: error: covariant 'Self' type cannot be referenced from
  a default argument expression` — my own, from a `prefix: String = Self.keyPrefix` default. Fixed
  by taking the prefix explicitly at the one call site; reported here rather than quietly.
- **iOS `test-without-building`**, six quoted `-only-testing:` flags → `ios-test-1.log`:
  `** TEST EXECUTE SUCCEEDED **`, `Executed 76 tests, with 0 failures (0 unexpected) in 17.709
  (17.726) seconds`, `grep -cE '\.swift:[0-9]+: error: '` = **0**. Per class, from the suite lines:

| Class | Result line |
|---|---|
| `WorkboardCopyTruthGuardTests` | `Executed 8 tests, with 0 failures (0 unexpected) in 12.934 (12.935) seconds` |
| `WorkCaptureInboxTests` | `Executed 29 tests, with 0 failures (0 unexpected) in 0.164 (0.170) seconds` |
| `CarPlayVoiceTimingContractTests` | `Executed 22 tests, with 0 failures (0 unexpected) in 0.052 (0.057) seconds` |
| `PendingRetrySurfaceHandoffTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 1.654 (1.656) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.897 (2.898) seconds` |
| `WorkboardDeskSurfaceDriftGuardTests` | `Executed 1 test, with 0 failures (0 unexpected) in 0.008 (0.009) seconds` |

  **Every class in `grep -l 'xcstrings' Conduck/ConduckTests` is in that list** — the four are
  `WorkboardCopyTruthGuardTests`, `ErrorSurfaceDriftGuardTests`, `WorkCaptureInboxTests`,
  `CarPlayVoiceTimingContractTests`. There is no catalog-total-pinning test in the repo: nothing
  asserts a row count, so the +6 breaks no arithmetic.
- **Counterfactual 1** → `cf-1.log`: `** TEST EXECUTE FAILED **`, `Executed 8 tests, with 8 failures
  (0 unexpected) in 13.327 (13.329) seconds`; three CASES red, named and quoted in §2.
- **Counterfactual 2** → `cf-2.log`: `Executed 8 tests, with 1 failure (0 unexpected) in 13.177
  (13.180) seconds`; one CASE red, quoted in §2.
- **Restore verified** by `diff -q` (**RESTORE OK**) and matching SHA-256
  (`59eeed7194376c0e8a90055d9942fe758d1b96d6a092166e6a0fe874b7315983` on both sides).
- **Restored-state re-run.** The first attempt (`ios-test-restored.log`) died before any test case
  started: `Failed to install or launch the test runner … Application failed preflight checks`
  (`FBSOpenApplicationErrorDomain Code=6`, reason `Busy`). Per the brief, `xcrun simctl shutdown all`
  then ONE retry via `test-without-building` → `ios-test-restored-2.log`: `** TEST EXECUTE
  SUCCEEDED **`, `Executed 76 tests, with 0 failures (0 unexpected) in 17.578 (17.594) seconds`, the
  same six classes at the same counts. Not a repeat, so not real.
- **FULL watch suite** (`-scheme ConduckWatchTests`, sim `28AC563B-…`, `xcodebuild test`) →
  `watch-1.log`: `grep -c ': error: '` = **0**, `** TEST SUCCEEDED **`,
  `Executed 232 tests, with 0 failures (0 unexpected) in 9.435 (9.509) seconds`. **232 exactly**,
  the integrate-e/d-copy-docs baseline.
- **Guard scripts**, from the worktree root:
  - `scripts/check-spec-cites.sh` → `✓ spec citations resolve — 803 Swift files scanned, 1 quoted
    section name(s), every one a live heading in docs/ai-context/spec.md`, exit **0**
  - `scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped,
    and every path the map names exists`, exit **0**
  - `scripts/check-storage-seam.sh` → `✓ storage seam intact — 803 Swift files scanned, no raw store
    or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`, exit **0**
  - `scripts/check-spec-size.sh` → exit **1**, **PRE-EXISTING**, quoted in full in §3.
- **All four catalogs** `json.load` clean; dict diff in §1; bidirectional audit
  `workboard.` 147/147 and `pendingRetry.` 8/8, no missing row, no dead row.
- **`git diff --check`** → no output, exit 0. `git diff --cached --stat` → **empty**.
  `git status --short` for `'*.pbxproj'`, `Conduck/Configs` and `docs/qa` → **empty** on all three;
  for `'*.xcstrings'` → only `Conduck/Conduck/Localizable.xcstrings`. No mirror-triplet file appears
  in `git status` at all.
- **Suite delta from this slice: +2 iOS** (`WorkboardCopyTruthGuardTests` 6 → 8), 0 watch.
- **Build caches and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh e-copy-docs`, along with
  both counterfactual catalog copies. Re-run to reproduce.

### What I did NOT verify, plainly

- **The full iOS suite.** Not in my VERIFY. My production change is one word in one string literal;
  my test change is inside one class; the catalog change adds rows and removes none, and no test in
  the repo pins a catalog total. The gate still owes the full run for the wave.
- **The macOS build.** Not in my VERIFY and, unlike d-copy-docs, I had no shared-target source edit
  worth the minutes — `PendingRetryCard.swift` compiles into both, and its one changed word is
  inside a string literal that the iOS build already compiled.
- **No screen.** There is no UI-test target by decision. That "1 recording waiting" actually renders
  singular on a Mac is §Founder QA 1; a unit test can prove the catalog carries the categories and
  nothing more.
- **Nothing about a translation.** The six rows are `en` only, state `new`. Whether a translator
  gets the plural categories right in another locale is outside anything here.
