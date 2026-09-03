# f-copy-docs — one key spliced, the published-Work discard rewritten and now GUARDED, four settled facts folded into spec.md at ZERO word cost. Nothing refuted.

Label `f-copy-docs`. Slug `f-copy-docs`. Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, watch sim
`28AC563B-42C1-4E66-940D-77E63B07918B`. No commits, pushes, stash, checkout, reset or index
operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched.
No `.pbxproj` edit. No mirror triplet touched (`git status` lists none of the three).

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · four VERIFY classes
`Executed 67 tests, with 0 failures` · full watch suite `Executed 232 tests, with 0 failures` ·
**two counterfactuals MEASURED**, 2 cases red on the pre-splice catalog and exactly 1 case red when
the published row is collapsed onto its sibling's sentence, with no other case moving in either ·
`wc -w spec.md` = **19827 before, 19827 after** · catalog **2251 → 2252 rows, +1, −0, ~0**; the
other three catalogs byte-untouched · three guard scripts exit 0, `check-spec-size.sh` exit 1
**pre-existing**.

Files changed — five, none new:

| File | Change |
|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | the one key f-finish declared, `pendingRetry.card.discard.confirm.body.published`, raw-line spliced |
| `Conduck/Conduck/Views/Components/PendingRetryCard.swift` | the published variant's `defaultValue` reworded in lockstep with the catalog row (`discardMessage`) — the only production line I touched |
| `Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift` | new rule (6): the published discard confirmation is guarded on the COMPLEMENT of rule (5) — six assertions plus a "the two rows differ" assertion |
| `docs/ai-context/spec.md` | four settled facts folded into the Work decision and the audio bullet, paid for inside those same two sections (19827 → 19827) |
| `docs/ai-context/project-structure.md` | `Services/` (claim by name, renewal, ownership before hand-off, sidecar authority) · `Services/Workboard/` (the drainer's verified retirement) |

---

## 1. The splice — what each f-* fixnote owed, and what it got

I read `## Catalog` in all five f-* notes before opening anything.

| Fixnote | Keys ADDED in source | Keys DEAD | Catalog opened by them |
|---|---|---|---|
| `f-arm` | none (four NEW call sites of the existing `pendingRetry.card.busy`) | none | no |
| `f-drainer` | none (`refusal.txt`'s body is forensic text nobody is shown) | none | no |
| `f-finish` | **one** — `pendingRetry.card.discard.confirm.body.published` | none | no |
| `f-queue` | none | none | no |
| `f-store` | none | none | no |

So exactly one row was owed, and **no row was made dead by wave F** — I removed none. Verified
independently rather than on their word: the bidirectional audit below found precisely that one
missing and nothing orphaned.

### Bidirectional audit — before and after, both prefixes

Every `.swift` under `Conduck/Conduck` concatenated; keys matched as full quoted literals.

```
BEFORE
workboard.       referenced=147  rows=147  MISSING=[]  CATALOG-ONLY=[]
pendingRetry.    referenced=9    rows=8    CATALOG-ONLY=[]
                 MISSING=['pendingRetry.card.discard.confirm.body.published']
AFTER
workboard.       referenced=147  rows=147  MISSING=[]  CATALOG-ONLY=[]
pendingRetry.    referenced=9    rows=9    MISSING=[]  CATALOG-ONLY=[]
```

`workboard.*` is 147/147/147, unchanged from integrate-e's, integrate-g's and e-copy-docs' number —
wave F added and killed no Work key. `pendingRetry.*` went 8 → 9 references and 8 → 9 rows: f-arm's
four new `pendingRetry.card.busy` call sites are re-uses of a row that already exists, which is why
the reference count moved by one and not by five.

### Catalog dict diff — `json.load` before/after, all four files

Top-level keys other than `strings` compare **equal**. Every one parses.

| Catalog | rows before → after | added / removed / changed |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2251 → **2252** | **+1**, −0, ~0 |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 → 43 | none |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 → 42 | none |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 → 299 | none |

Verbatim, the whole diff:

```
top-level equal outside strings: True
rows 2251 -> 2252
added: ['pendingRetry.card.discard.confirm.body.published']
removed: []
changed: []
+ pendingRetry.card.discard.confirm.body.published
    {"extractionState": "extracted_with_value", "localizations": {"en": {"stringUnit":
     {"state": "new", "value": "This removes only the copy kept for another try at transcribing
      it. The recording is already in Work and stays there."}}}}
```

Raw-line splice, inserted at line 7389 immediately after `pendingRetry.card.discard.confirm.body`'s
closing `},` and before `"pendingRetry.card.discard.confirm.title"` — the position the catalog's own
collation puts it in (a shorter key precedes its own longer prefix-mate, the precedent
e-copy-docs measured at `workboard.capture.discarded.message` / `…message.one`). Two-space indent
and the ` : ` separator match every neighbouring row. `git status --short -- '*.xcstrings'` lists
one file.

### Source `defaultValue:` == catalog `en`, byte-identical — verified, not asserted

A script re-extracted every `String(localized:defaultValue:)` and
`LocalizedStringResource(_:defaultValue:)` literal for the nine `pendingRetry.*` keys from source
(multi-line `"""` literals unwrapped through their `\` continuations, `\(intExpr)` normalised to
`%lld` the way extraction does) and compared to the catalog value:

```
MATCH    pendingRetry.card.busy  (6 call site(s))
MATCH    pendingRetry.card.count  (2 call site(s)) (plural row; compared to `other`)
MATCH    pendingRetry.card.discard  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.action  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.body  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.body.published  (1 call site(s))
MATCH    pendingRetry.card.discard.confirm.title  (1 call site(s))
MATCH    pendingRetry.headline  (1 call site(s))
MATCH    pendingRetry.headline.terminal  (1 call site(s))
call sites scanned: 15
ALL SOURCE defaultValue == CATALOG en (byte-identical): True
```

f-arm's six `pendingRetry.card.busy` sites (ContentView, DictationService, ConverseIntent ×2,
WorkboardVoiceCaptureView ×2) all carry the identical literal, as its fixnote said they would.

---

## 2. Copy pass — the published variant reordered nothing and rephrased two things

f-finish drafted: *"This removes the copy kept for another transcription attempt. The recording is
already in Work and stays there."* Shipped:

> This removes only the copy kept for another try at transcribing it. The recording is already in
> Work and stays there.

Three deliberate changes, all inside f-finish's two claims rather than to them:

- **"only" added.** The dialog's title is "Discard this recording?" — shared with the other state —
  so the first word of the body has to narrow what "discard" means here. Without *only*, "removes
  the copy" still reads as "removes the recording, which is a copy".
- **"another transcription attempt" → "another try at transcribing it".** The app's own phrase for
  a retryable failure is *another try*: `workboard.chatCapture.partial` ships "%lld attachments
  need another try." and `workboard.workspace.import.partial.title` ships "Some items need another
  try". "Transcription attempt" is a noun phrase from the fixnote, not from the product.
- **Sentence order kept as f-finish had it.** I drafted the reassurance first and rejected it: with
  the title asking "Discard this recording?", the body's first sentence has to answer *what the
  button does*, and the second the consequence — which is exactly the shape of the sibling row
  ("This deletes the recording from this device. It cannot be recovered.").

Register matches the sibling and the app's two other destructive-confirmation bodies — the delete-all
row (a bare-English-literal key: "This removes every conversation from this device and all your other
devices. This cannot be undone.") and `settings.usage.clear.message` ("This removes every usage
record… This cannot be undone."). Both open on **"This removes …"**, which is the shipped form this
sentence takes: flat sentences, second person implied, no contraction in the absolute, no
exclamation mark. Founder's final pass — §Requests 1.

**The claim is TRUE, traced rather than assumed.** `PendingRetryCard.discardMessage` selects this
row on `discardKeepsRecordingInWork`, and the card's one host computes that flag at
`ContentView.swift:1509` as `metadata.resolvedDestination == .work && metadata.publicationState ==
.published` — read off the entry the surface has already CLAIMED, so it describes the capture the
dialog is about and not "whatever is newest". The discard behind it is `PendingRetryStore.clear(claim)`,
which removes that entry's sidecar, audio and screenshot and touches no desk material: the card on the
desk and its payload row are untouched by the call. (The menu bar has no discard affordance at all —
`grep -n 'discard' MenuBar/DictationService.swift` finds only a comment and a `@discardableResult` —
so this row renders on iOS only, which is what §Founder QA 1 exercises.)

### Regression test — both counterfactuals MEASURED red

`WorkboardCopyTruthGuardTests` 8 → **9 cases**. New rule (6),
`testThePublishedDiscardConfirmationSaysTheRecordingStaysInWork`, is guarded on CLAIMS, never on
wording: it must name Work, must promise the recording stays (`stays` / `remains` / `still there`),
must name the *copy* it removes, must NOT say "cannot be recovered", "this device" or "delete", and
must differ from its sibling row. The class header now carries rule (6) and why it is the
complement of rule (5).

The guard reads the catalog from disk, so each counterfactual is a file swap on the shared tree
rather than a rebuilt copy; the fixed catalog was backed up and restored, `diff -q` **RESTORE OK**
and SHA-256 `fa2de9177568e7d0d2e35771644659cb7e88f54567b7d3772bab73c320dbc279` identical on both
sides. No source, no test and no other file moved during either flip.

**Counterfactual 1 — the pre-splice catalog** (`cf-1.log`): `** TEST EXECUTE FAILED **`,
`Executed 9 tests, with 2 failures (0 unexpected) in 13.618 (13.620) seconds`. Exactly two cases
red; the other seven passed in the same run:

```
…GuardTests.swift:314: error: -[…testEveryWorkKeyInSourceHasACatalogRow] : XCTAssertNotNil failed -
  pendingRetry.card.discard.confirm.body.published is referenced in the app target but has no
  catalog row — it would render from its defaultValue and could never be translated.
…GuardTests.swift:376: error: -[…testThePublishedDiscardConfirmationSaysTheRecordingStaysInWork] :
  XCTUnwrap failed: expected non-nil value of type "Any" - the published-capture discard
  confirmation has no catalog row
```

**Counterfactual 2 — the row present, but collapsed onto its sibling's sentence** (`cf-2.log`):
`Executed 9 tests, with 7 failures (0 unexpected) in 13.437 (13.439) seconds` — seven assertion
failures inside **exactly one case**, the new one, and no other case moved:

```
:384 XCTAssertTrue failed  - …naming where it still is is the whole reason this row exists apart
                             from its sibling: This deletes the recording from this device. It
                             cannot be recovered.
:389 XCTAssertTrue failed  - …a recording that is not going anywhere, so the sentence has to say so
:394 XCTAssertTrue failed  - …has to name [the second copy] rather than leave the person guessing
:400 XCTAssertFalse failed - this recording IS recoverable — it is a playable card on the desk
:405 XCTAssertFalse failed - …here the desk holds it and it syncs, so the claim does not transfer
:410 XCTAssertFalse failed - the recording is not deleted by this discard, only the queue's spare copy
:420 XCTAssertNotEqual failed: (…) is equal to (…) - the two states share one dialog and differ only
                             in this sentence
```

**How I know the new case is what proves the fix** rather than an unrelated change: counterfactual 1
isolates row PRESENCE (2 cases, one of them the pre-existing bidirectional rule), counterfactual 2
holds the row present and changes only its VALUE, and then exactly one case moves. That case did not
exist before this edit, so on the old code the false sentence would have shipped with a green class.

**f-finish's warning is honoured, and inverted.** Its `## Catalog` asked that if rule (5) is ever
widened to every `…confirm.body*` key it must exempt this row, "or better, assert the complement".
Rule (5) is keyed on the exact string `pendingRetry.card.discard.confirm.body` and does not walk a
prefix, so no exemption was needed; the complement is asserted instead.

---

## 3. spec.md — four settled facts folded in at ZERO word cost

`wc -w docs/ai-context/spec.md` = **19827 before, 19827 after** — integrate-d's, integrate-e's,
integrate-f's, integrate-g's and e-copy-docs' number exactly. Everything is paid for inside the two
sections I touched: `## Work is one desk, and nothing on it becomes a turn` and `## Data, secrets,
and what leaves the device`. Present tense, no changelog narration. Nothing was relocated to dodge
the ceiling and no rejected alternative was deleted — the two prohibitions `check-spec-size.sh`
names.

### The four facts my brief names, one sentence each

| Fact | Source | Where it now lives, verbatim |
|---|---|---|
| **Which rows a replay may repoint** | f-store | Work decision: "…and a recapture repairs a bytes-less card, though never one newer than the capture it replays — another device's file still arriving." |
| **Atomic terminal retirement** | f-drainer | Work decision: "…a second refusal is terminal: its directory is copied aside and verified byte for byte before the queue lets the original go." |
| **The lease — claim by id, renewal, ownership confirmed before hand-off** | f-arm + f-finish + f-queue | Audio bullet: "A surface reserves the capture it is finishing, by name where it made the recording, renews while it works, and confirms it still holds before handing the words on, so two surfaces never finish the same one; an unrenewed reservation lapses." |
| **Sidecar authority over the index** | f-queue | Audio bullet: "…so an interrupted arm or discard finishes rather than half-existing; that record outranks the index when they disagree, and one that cannot yet be read defers rather than guessing." |

Each was traced to the code before it was written down: `ConversationStore+Workboard.swift:736-740`
(`publicationDate = draft.createdAt`, `stamp <= publicationDate`) · `WorkCaptureDrainer.swift:557-650`
(`retireRefusedCapture`, stage → `holdsRetirement` verify → rename, acknowledge after) ·
`PendingRetryStore.swift:796/827/859` (`claim(id:duration:)`, `renew`, `confirmOwnership`) ·
`PendingRetryStore.swift:44-70` (the header's ARM / CLEAR orders and "THE SIDECAR IS AUTHORITATIVE").

### The three sentences round 6 changed, and the two it did not

- **"a second refusal is terminal and retires it, files intact"** was true but unfalsifiable — it
  claimed the outcome without the mechanism that makes it hold across a crash. f-drainer's staged
  copy + verify + rename is what makes "files intact" a property rather than a hope, so the sentence
  now carries it.
- **"A surface reserves the capture it is finishing for ten minutes"** was made INCOMPLETE by wave F
  in two ways: an arm-side lane addresses the capture it minted rather than the newest, and a
  reservation is now renewed rather than sized for the worst case. Both are in. The literal *ten
  minutes* came out — spec.md's own rule is that numbers are not written down, the figure lives in
  `PendingRetryStore`, and the budget it belongs to is stated one sentence later.
- **"its removal tombstoned before anything goes"** stays true and gained the authority rule beside
  it, because a reader who knows the write order still cannot tell which half wins on a disagreement.
- **`PendingRetryMetadata.isExpired` reclaims a retryable transcription, never a recording that is a
  card's only copy — so the card carries a confirmed discard as the only way out.** Checked against
  f-finish's state-aware discard and left standing: the clause is scoped to a recording that is a
  card's only copy, which is exactly the state where the discard is the only way out. The published
  case does not contradict it; it is a different capture.
- **`grep -n 'unrecoverable\|lease\|sidecar' docs/ai-context/spec.md` returns nothing in either
  section.** Neither word was ever in the document — "unrecoverable" appears nowhere, and the one
  near-miss (`unreclaimable`, in the scratch-file bullet) is about a sweeper prefix and is still
  true. There was no false sentence to fix beyond the three above; §Refuted 1 says so.

### What paid for it, and where each cut went

Twenty-six edits, all inside the two sections, none of them a claim.

| Cut | Words | Why it is a legitimate cut |
|---|---|---|
| "— exactly the kind of rule a well-meant \"let's add some logging here\" removes" | 14 | Meta-commentary on the rule's fragility, in a bulleted pair whose own heading already reads "Two smaller rules about audio on disk, **easily undone**". The rule and its reason (a timestamp listing discloses when someone was recording) both survive. |
| "inside the same encrypted mirror as the messages" | 9 | The sentence before it already says the record "travels with the conversations", and the clause after it says one value is "the only part **outside that mirror**". Three statements of one fact. |
| "so runs there are local-only by design" → "by design" moved onto the claim | 5 | Restates "Sync is off on the Simulator". The *by design* is the load-bearing half and it kept its place. |
| "and reads and writes the same file" → "against the same file" | 3 | The clause exists to say a second process shares the file; which verbs it uses is one file's business. |
| "which is why … is the wrong instinct here: degrading gracefully would mean" → "…is the wrong instinct: it would mean" | 3 | Pure compression; the instinct and its consequence both survive. |
| "One non-obvious threat to that guarantee:" → "One non-obvious threat:" | 3 | The guarantee is the immediately preceding paragraph. |
| "the transcript or failure code comes back over it" → "…returns" · "and it is never logged" → "and never logged" | 3 | Compression carrying no claim. |
| Ten single words: "database" (said twice), "directly", "can never"→"cannot", "genuinely" (the italic `*different*` carries it), "own" ×3 (the app's / the Watch's / the desk's), "original" metadata, "bundle" resource, "of" the dependency list, "to the model" on an inline copy already contrasted with a file server | 12 | Each is a word whose sentence means exactly the same without it. |
| "avoid deleting" → "spare" · "from the same shared directory" → "in the same…" | 1 | Compression. |
| "A voice note … is made durable and playable" → "is durable and playable" | 1 | *Durable* is the state being asserted; *made* adds nothing the verb does not. |

**Spec-size guard is a PRE-EXISTING FAILURE, unchanged and NOT fixed** (plan §E and §F both forbid
fixing it): exit **1**, `✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.` plus the
same two unrelated over-limit decisions, `"Sending files and getting them back are two capabilities
of one lane" 687 / 650` and `"Forgetting a gateway erases the credentials and keeps the colour tag"
701 / 650`. Both are outside Work and audio; I did not open either. **No new over-limit decision
appears** — the per-decision check counts `###` sections inside `## The decisions`, and the two
sections I edited are `##` sections after it, so neither is counted at all.

## 4. project-structure.md — two rows, each because a file's role changed

- **`Services/`** — the retry queue's claim gained an address form, a renewal and an ownership
  check, and the sidecar gained authority: "A surface claims one entry at a time — by name when it
  made the recording itself, newest-first when a person taps Retry — under a lease it renews while
  it works and confirms it still holds before handing the words on, so two of them cannot finish the
  same recording and a transcription that runs long cannot have its recording taken underneath it.
  An entry's record is written before its bytes and its removal is tombstoned before anything goes,
  so an arm or a discard interrupted by process death resolves on the next launch instead of
  half-existing; that record is the authority, and an index row disagreeing with it is rewritten
  from it rather than trusted."
- **`Services/Workboard/`** — the drainer took a second job: "…the drainer that empties the
  App-Group capture queue onto the desk **and retires a capture it can never turn into cards by
  copying the whole claimed directory aside and verifying the copy before the queue lets go of the
  original**…"

`PendingRetryLeaseRenewal.swift` is a NEW file in the already-mapped `Services/` folder, so the
folder map needed no new row and got none — the `Services/` row describes the renewal by role, which
is how that table is written. `scripts/check-folder-map.sh` passes: 36 Swift source directories, all
mapped, every path the map names exists. The "Where to start" table needed no change: its Work row
already routes to `ConversationStore+Workboard.swift` for "the repair a replayed capture needs",
which is still where the newer-row rule lives.

---

## Catalog

**Keys I ADDED in source: NONE.** I mint no keys; I splice the ones source already declares.

**Keys I ADDED to the catalog: one**, exactly as f-finish declared it:

```
pendingRetry.card.discard.confirm.body.published = "This removes only the copy kept for another try at transcribing it. The recording is already in Work and stays there."
```

**Keys I made DEAD: NONE.** No row was removed from any catalog; no source reference was deleted.
The bidirectional audit is 147/147 and 9/9 with an empty CATALOG-ONLY list on both prefixes.

**Catalogs opened: one.** `git status --short -- '*.xcstrings'` lists only
`Conduck/Conduck/Localizable.xcstrings`. The Watch and the two share extensions were read (to prove
none of these keys lives there — no `pendingRetry.` row in any of the three) and not written.

**One source string literal changed in lockstep:** the `defaultValue:` of
`pendingRetry.card.discard.confirm.body.published` in
`Conduck/Conduck/Views/Components/PendingRetryCard.swift` (`discardMessage`), §2. It is the only
production line I touched.

---

## Requests

1. **Founder copy call — the published-Work discard body.** "This removes only the copy kept for
   another try at transcribing it. The recording is already in Work and stays there." Two things to
   react to, not defects: (a) the dialog TITLE is shared with the destructive state and still reads
   "Discard this recording?", which the body's first sentence has to correct — a second title key is
   one splice plus a two-line source change if the founder wants "Discard the retry copy?"; (b) the
   register is the uncontracted one e-copy-docs matched to Delete All Conversations, while the retry
   card's headline contracts ("couldn't be sent"). The guard pins the claims, not the wording, so
   either is one splice.
2. **e-copy-docs §Requests 1 is still open and I did not close it.** The backlog count
   ("2 recordings waiting") is a caption on iOS and the whole popover sentence on macOS. Unchanged.
3. **e-copy-docs §Requests 3 / e-drainer §Requests 1 is still open and I did not close it.**
   `workboard.capture.discarded.message.one` ("Conduck couldn't read one shared item, so it wasn't
   added to your board.") is half true for a terminally refused capture — Conduck read it fine and
   its bytes are now a verified retirement in `refused/`. f-drainer's atomic retirement makes that
   sentence *more* wrong, not less, because the copy is now provably complete. Recommended wording
   to react to, not to ship, unchanged from e-copy-docs: **"Conduck couldn't add one shared item to
   your board."** It is a shipped Work string on `PersonalWorkbenchView.swift` and a founder call.
4. **`diagnostics.voice.pendingRetry.waiting` is still not minted, and correctly so** — nothing in
   source references it, and `testEveryWorkCatalogRowIsReferencedInSource` walks `pendingRetry.*` in
   that direction, so a row with no call site fails the build. Tell me the key and the call site in
   `DiagnosticsRunner` and it is one splice.
5. **Integrator — the spec-size guard exits 1 and must be recorded as PRE-EXISTING.** 19827 words,
   identical to integrate-d/e/f/g's number, with the same two unrelated over-limit decisions. Plan
   §E and §F both say not to fix it. Do not read that exit code as mine.
6. **Integrator — suite arithmetic.** `WorkboardCopyTruthGuardTests` 8 → **9** (+1). That is my
   whole delta; every other class I ran is at its recorded count (`ErrorSurfaceDriftGuardTests` 7,
   `WorkCaptureInboxTests` 29, `CarPlayVoiceTimingContractTests` 22). Watch **232**, unchanged.
7. **Nobody undo these** — each is pinned by a case measured red on a counterfactual:
   - The published row exists SEPARATELY. Collapsing the two discard bodies into one row is
     counterfactual 2, and whichever row survives puts a false sentence in front of one of the two
     people.
   - Rule (6) asserts the complement, never the wording. Do not "tighten" it into an equality check
     on my sentence — that pins one author's ear and the founder's copy pass would fail the build.
   - Rule (5) is keyed on the exact sibling key. If anyone widens it to a `…confirm.body` PREFIX it
     will start matching the published row and demand "cannot be recovered" of it, which is the
     exact falsehood rule (6) exists to stop.
8. **Whoever next adds a Work or retry string.** The splice is mechanical and reproducible: raw-line
   insert at the collation position, `json.load` before/after with a dict diff, and a re-extraction
   of every `defaultValue:` compared byte for byte to the catalog `en`. The plural row
   (`pendingRetry.card.count`) is compared on its `other` category, because a source `defaultValue:`
   cannot express a plural.

---

## Refuted

**Nothing.** Every fact the f-* notes carry held when traced against the code before I wrote it
down, and every design direction in my brief was implementable as written. Two clarifications rather
than refutations:

1. **"Fix any sentence in spec.md that the round-6 findings proved false" had almost no referent.**
   `grep -n 'unrecoverable\|lease\|sidecar' docs/ai-context/spec.md` returns **nothing** — none of
   the three words has ever been in the document. `deleted` appears in both sections and every
   instance is still true (a desk "never deleted", a payload row that goes "when … the card is
   deleted", a scratch file "deleted when the operation ends", a Watch clip "deleted the moment the
   phone claims it"). What round 6 changed was not a false claim but two INCOMPLETE ones — the
   reservation sentence and the retirement clause — and both are rewritten in §3 rather than
   patched.
2. **f-store's fact explicitly REPLACES a fact integrate-g carries under "the O-19 trade"**, and the
   replaced version was never in spec.md — e-copy-docs deliberately kept it out under the one-file
   rule. So what landed is f-store's corrected statement as a NEW claim ("though never one newer
   than the capture it replays"), not an edit to a wrong sentence. The superseded wording ("brings
   EVERY physical row … back onto them whenever any row disagrees") must not be reinstated by a
   later doc pass reading integrate-g rather than f-store.

---

## Founder QA — device-only checks this change needs

These ADD to d-retry's seven, e-queue's six, e-surfaces' eight and e-copy-docs' six, which all still
apply. Mine are all "read the words on the screen" checks; one of them needs a specific state.

1. **The state that shows the new sentence, which is the only one that matters.** Record a Work
   voice note from the desk's voice sheet with speech recognition guaranteed to fail (airplane mode
   with a cloud provider selected). The recording must appear as a playable card on the desk AND
   leave a retry card. Tap **Discard recording** on the retry card: the body must read *"This
   removes only the copy kept for another try at transcribing it. The recording is already in Work
   and stays there."* — and after confirming, **the card must still be on the desk and still play**.
   A body that says "cannot be recovered" here, or a card that disappears, is the bug this whole row
   exists to prevent.
2. **The other state, unchanged, for contrast.** A Chat voice capture that fails to transcribe has
   no desk card. Its discard must still read *"This deletes the recording from this device. It
   cannot be recovered."* Seeing both dialogs back to back is the fastest way to judge whether the
   two registers sit together.
3. **Read the published body aloud and decide on the title.** The dialog is titled "Discard this
   recording?" in both states. For the published one that title is answered rather than matched by
   the body; the question for the founder is whether that is acceptable or whether the title should
   change too (§Requests 1a).
4. **Dynamic Type on the longer body.** The published sentence is 21 words against the sibling's 11,
   on a system confirmation dialog. What to look for at the largest accessibility sizes is that
   "Discard" and "Cancel" are both still reachable.
5. **VoiceOver over the confirmation.** Both sentences should be read as one message; confirm the
   second sentence is not truncated, since it is the one carrying the reassurance.

---

## Settled facts

One sentence each; true of the code and the documents as they now stand.

- Discarding a waiting recording the desk has already accepted removes only the queue's second copy
  and leaves the playable card on the desk, so its confirmation is a separate catalog row that
  carries neither of the other row's claims.
- The copy guard pins that row on what it asserts — that the recording stays in Work, and what is
  actually removed — and on it differing from its sibling, never on its wording, so a founder copy
  pass can rewrite the sentence without failing the build.
- The destructive discard confirmation and the published one are the app's only pair of strings
  where the same button means two different things, and the state that selects between them is the
  capture's publication state, not the surface.
- A replay may bring a card's rows back onto its bytes only when those rows are not newer than the
  capture being replayed; a newer row is another device's file still on its way and is left to
  arrive on its own.
- A capture refused under both its own identifier and its escape identifier is retired by copying
  its whole directory aside and verifying the copy byte for byte before the queue lets the original
  go, so "files intact" is a property of the write order rather than of an intention.
- A surface reserves the capture it is finishing by name where it made the recording, renews the
  reservation while it works, and confirms it still holds before handing the words on, so two
  surfaces open at once never finish the same recording.
- The record kept beside a waiting recording outranks the queue's index when the two disagree, and
  a record that cannot yet be read defers its capture rather than being replaced by a guess.
- The ten-minute figure is out of `spec.md` and lives in `PendingRetryStore` alone, because
  `spec.md`'s own rule is that a constant's name is written down and its value is not.
- `spec.md` holds at 19827 words across five consecutive integrations; every fact added since
  integrate-d has been paid for inside the section that received it.
- The retry queue's claim, lease, renewal and sidecar authority are described in
  `project-structure.md`'s `Services/` row, and the drainer's verified retirement in its
  `Services/Workboard/` row.

---

## Gates — WHAT I ACTUALLY RAN

DerivedData under `~/Library/Caches/gigaduck-builds/f-copy-docs/{DerivedData,DerivedDataWatch}`,
every log written there and grepped for `': error: '` and for
`BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|Executed ` — **never judged from a tail or
an exit code**. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`, no throwaway
tree copy (both counterfactuals are file swaps on the shared tree, restored and SHA-verified).

- **Simulator TCC checked FIRST:**
  `sqlite3 …/2B6E0EAC…/data/Library/TCC/TCC.db "select service, client, auth_value from access where
  client='ai.gigaduck.AgentRelay';"` → **no rows**, exit 0 (`.notDetermined`; no stale denial,
  nothing to reset).
- **iOS `build-for-testing`** (sim `2B6E0EAC-…`) → `ios-bft-1.log`: `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`. Green on the first attempt.
- **iOS `test-without-building`**, four quoted `-only-testing:` flags → `ios-test-1.log`:
  `** TEST EXECUTE SUCCEEDED **`, `Executed 67 tests, with 0 failures (0 unexpected) in 15.956
  (15.970) seconds`, `grep -cE '\.swift:[0-9]+: error: '` = **0**. Per class, from the suite lines:

| Class | Result line |
|---|---|
| `WorkboardCopyTruthGuardTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 12.859 (12.861) seconds` |
| `WorkCaptureInboxTests` | `Executed 29 tests, with 0 failures (0 unexpected) in 0.149 (0.154) seconds` |
| `CarPlayVoiceTimingContractTests` | `Executed 22 tests, with 0 failures (0 unexpected) in 0.057 (0.062) seconds` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 2.890 (2.892) seconds` |

  **Every class in `grep -rl 'xcstrings' Conduck/ConduckTests` is in that list** — the four are
  exactly those. There is still no catalog-total-pinning test in the repo: nothing asserts a row
  count, so the +1 breaks no arithmetic.
- **Counterfactual 1** → `cf-1.log`: `** TEST EXECUTE FAILED **`, `Executed 9 tests, with 2 failures
  (0 unexpected) in 13.618 (13.620) seconds`; two CASES red, quoted verbatim in §2.
- **Counterfactual 2** → `cf-2.log`: `Executed 9 tests, with 7 failures (0 unexpected) in 13.437
  (13.439) seconds`; ONE case red, all seven assertions quoted in §2.
- **Restore verified** by `diff -q` (**RESTORE OK**) and matching SHA-256
  (`fa2de9177568e7d0d2e35771644659cb7e88f54567b7d3772bab73c320dbc279` on both sides).
- **Restored-state re-run** → `ios-test-restored.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 67 tests, with 0 failures (0 unexpected) in 15.979 (15.993) seconds`, the same four
  classes at the same counts. No install/launch flake in any run; `simctl shutdown all` was never
  needed and never issued.
- **FULL watch suite** (`-scheme ConduckWatchTests`, sim `28AC563B-…`, `xcodebuild test`) →
  `watch-1.log`: `grep -c ': error: '` = **0**, `** TEST SUCCEEDED **`,
  `Executed 232 tests, with 0 failures (0 unexpected) in 9.524 (9.607) seconds`. **232 exactly**,
  the expected baseline.
- **macOS: NOT run, and not owed.** My four files are a JSON catalog, one string literal, one iOS
  test class and two Markdown documents; nothing platform-conditional moved. The wave's macOS build
  is f-store's (`** BUILD SUCCEEDED **`, signed) and the integrator's.
- **Guard scripts**, from the worktree root:
  - `scripts/check-spec-cites.sh` → `✓ spec citations resolve — 808 Swift files scanned, 1 quoted
    section name(s), every one a live heading in docs/ai-context/spec.md`, exit **0**
  - `scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped,
    and every path the map names exists`, exit **0**
  - `scripts/check-storage-seam.sh` → `✓ storage seam intact — 808 Swift files scanned, no raw store
    or live-adapter access outside Conduck/Conduck/Services/Storage/LiveStorage.swift`, exit **0**
  - `scripts/check-spec-size.sh` → exit **1**, PRE-EXISTING, quoted in full in §3.
- `git diff --check` → clean, exit 0. `git status --short` for `*.pbxproj`, `Conduck/Configs`,
  `docs/qa` and the three mirror triplets → **empty** on all of them. All four `.xcstrings` files
  `json.load` cleanly (2252 / 43 / 42 / 299 rows).
- **Build caches and every log removed at end of task** with
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh f-copy-docs` →
  `removed: f-copy-docs`. Re-run to reproduce.

### What I did NOT verify, plainly

- **That the published body appears on a device.** `discardKeepsRecordingInWork` is set by the two
  hosts from a claimed entry's publication state; no unit test drives a SwiftUI confirmation dialog,
  and the guard proves the catalog row, not which row the view picks. §Founder QA 1 is the check.
- **The four other catalogs' translations.** Every row I touched is `en` only, `state: new`, exactly
  as the other 2251 are.
- **That my spec.md prose reads better rather than merely shorter.** Twenty-six cuts is a lot of ear
  in one pass; every one is listed in §3 so the integrator can reject any of them individually
  without disturbing the four facts.
