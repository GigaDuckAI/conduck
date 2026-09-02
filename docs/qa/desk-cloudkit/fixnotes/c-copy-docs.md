# c-copy-docs — all four findings CONFIRMED and fixed; nothing refuted

Label `c-copy-docs`. Slug `c-copy`. Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`, watch sim
`28AC563B-42C1-4E66-940D-77E63B07918B`. No commits, pushes, stash, checkout, reset or index
operations. `Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched.
No `.pbxproj` edit. No mirror triplet touched. No file outside my ownership edited.

Files changed — five, none new:

| File | Change |
|---|---|
| `Conduck/Conduck/Views/Workboard/WorkboardVoiceCaptureView.swift` | r3a#3: `privacyCopy`'s `workboard.voice.privacy` defaultValue + a header comment on the property saying why the inertness promise may not stand there |
| `Conduck/Conduck/Localizable.xcstrings` | r3a#3 value in lockstep; r3a#8 splice of c-guards' three `workboard.sync.banner.*` rows |
| `Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift` | `outboundHopKeys` (stops stripping the promise for the voice key), `deskSyncBannerKeys`, two new tests, header rule (3) |
| `docs/ai-context/project-structure.md` | r3a#9 `Services/Workboard/` row; r3a#10 `Views/Workboard/` row |
| `docs/ai-context/spec.md` | the recovery fact folded into the Work decision, paid for inside the same decision (19827 → 19827 words) |

---

## r3a#3 — the voice sheet promised that nothing is sent — **CONFIRMED, fixed**

**Verified by tracing the call path, not by reading the finding.** `privacyCopy`
(`WorkboardVoiceCaptureView.swift`, at `workboard.voice.privacy`) rendered *"Keeps the recording on
your private desk and adds the words when they're ready. **Nothing is sent.**"* The sheet's recorder
is `InAppAudioRecorder`; after the phase-one publish it writes `capture.audio` to a temp URL and
hands that URL to the configured provider (`Services/InAppAudioRecorder.swift`, the
`if capture.transcript == nil` block → `STTKeyReadiness.resolve(presetID:snapshotKey:provider:…)` →
`STTClient`). `Services/STTClient.swift`'s own header names the vendors that table dispatches to —
"ElevenLabs `xi-api-key`", "Gemini `x-goog-api-key`", "Mistral 429 retried as OpenAI 429" — so on
every configuration except Apple's in-process engine the recording is uploaded. The claim was false.

**Fixed** — key kept, source `defaultValue` and catalog `en` value moved together and byte-identical
(verified by a regex extraction of the source literal against the catalog row: MATCH):

> Keeps the recording on your private desk and adds the words when they’re ready. The audio goes only
> to the speech provider you chose — never to an AI, never to a server of ours.

Why this shape rather than the finding's "when one is configured" phrasing: the sheet has no view of
which provider is selected (the snapshot is resolved inside the recorder, mid-capture), so a
conditional sentence would need a second source of truth on screen. One unconditional sentence that
is true in **both** configurations is stronger: with Apple on-device, "the speech provider you chose"
is the on-device engine and nothing else sees the audio; with a cloud vendor it names exactly the one
destination. It errs toward disclosing exposure rather than denying it, which is the safe direction
for a privacy line. "never to a server of ours" is the README's own phrase.

**The guard stops stripping the phrase for this key.** `inertnessPhrases` were removed from *every*
`workboard.*` value before the vocabulary scan, which is precisely why "Nothing is sent." sat
unguarded on this row. The strip is now gated on `outboundHopKeys` — a named set of the Work strings
whose lane HAS a destination, holding `workboard.voice.privacy` alone. Eight other rows
(`workboard.menuBar.saved`, `workboard.chatCapture.saved`, `workboard.workspace.thought.saved`,
`workboard.workspace.add.hint`, `workboard.workspace.drop.overlay.caption`, the two
`workboard.workspace.import.complete.message*` rows and `workboard.workspace.import.partial.message`)
keep the exemption: those lanes reach no provider at all, and stripping is what lets them keep saying
so. Deny-set rather than allow-set on purpose — the exemption is the norm, the destination is the
exception, and a new Work string with a hop has to be named here deliberately.

**Regression test** — `WorkboardCopyTruthGuardTests.testTheVoiceSheetNamesTheSpeechProviderRatherThanPromisingInertness`,
plus the un-stripped `testNoWorkStringDescribesSendingDispatchingOrADraft`. See §Counterfactuals: on
the pre-fix catalog these produce three of the seven measured failures.

## r3a#8 — the desk banner's three keys had no catalog rows — **CONFIRMED, fixed**

**Verified**: `WorkboardCaptureCanvas.deskSyncBanner` already routes through
`WorkboardSyncBannerPolicy.message(showsBanner:reason:)` (c-guards' source half of C7), which
declares `workboard.sync.banner.{noAccount,restricted,quotaExceeded}`. A bidirectional scan of the
app target against the catalog showed exactly those three keys referenced in source with **no** row
— they would have rendered from `defaultValue` and could never be translated. The shipped
`sync.icloud.banner.*` rows still say "your conversations" and are still rendered by Chat
(`ConversationListView` → `ICloudUnavailableBanner`), so nothing was widened and nothing went dead.
**This closes O-14** without costing Chat its specific word: option (b) of the founder call, at the
cost c-guards priced (3 keys, one edit — both already made).

**Fixed** — raw-line splice into `Conduck/Conduck/Localizable.xcstrings` at the ASCII sort slot
between `"workboard.menuBar.saved"` and `"workboard.title"`, block shape copied verbatim from the
neighbouring rows (`extractionState: extracted_with_value`, `localizations.en.stringUnit.state:
new`). No sort was computed and no other row moved: the dict diff below is exactly three additions.
Values are byte-identical to c-guards' source defaults, U+2019 apostrophes included (verified by
extraction, MATCH ×3).

**Regression test** — `testTheDeskSyncBannerSpeaksAboutCardsRatherThanConversations`, which asserts
per key that the row exists, names iCloud, says "card", and does **not** say "conversation". The
existing `testEveryWorkKeyInSourceHasACatalogRow` covers the presence half.

## r3a#9 — `project-structure.md` denied Work any network consequence — **CONFIRMED, fixed**

**Verified**: the `Services/Workboard/` row ended *"Nothing in this folder has a network dependency of
any kind, so collecting something can never send it."* — two sentences after the same row states that
bytes within `Constants.workboardSyncCeilingBytes` "ride the person's own private CloudKit and reach
their other devices". The row contradicted itself, and `spec.md`'s Work decision agrees with the
CloudKit half.

**Fixed** — the absolute claim is replaced by the boundary that actually holds:

> That mirror is the only place anything here goes: no code in this folder reaches an AI, and there is
> no server of ours for it to reach.

## r3a#10 — `project-structure.md` still claimed a typed-note sheet — **CONFIRMED, fixed**

**Verified**: `WorkboardTextMaterialSheet.swift`'s own header calls itself "a reference link, reached
from the capture composer's attach menu", and its single `kind:` argument is `.link`. The note route
is `WorkboardCaptureCanvas.addThought` → `WorkboardViewModel.addThought`, the pinned composer. The
map's "the sheets for a typed link or note" was two errors: a plural, and a note sheet.

**Fixed** — the `Views/Workboard/` row now names the composer as the only note route and the sheet as
link-only, and its closing sentence points at where a card's bytes are actually decided rather than
asserting the whole surface has no transport:

> …a composer pinned under them — which is the only route to a typed note — the link sheet reached
> from that composer's attach menu, … These views collect material and hold no transport of their
> own; where a card's bytes then live is decided in `Services/Workboard/`.

`scripts/check-folder-map.sh` passes with the new backticked path (it exists).

## spec.md — the recovery fact, folded at zero cost

c-recovery-core settled it: `WorkVoiceCaptureCoordinator.recover(_:transcript:store:)` returns
`.republishedAndAttached` when phase one never landed a card, and `.fallbackNotePublished` only on
`.recordingMissing` — the case c-lanes kept for *a person deleting the card while STT is in flight*
(O-11's declined republish). One sentence, appended to the Work decision's own voice-note sentence:

> …so a failed transcription costs the words and never the recording; **a retry republishes a
> recording whose first write failed and degrades one to a note only when its card is gone.**

**Paid for inside the same decision**, per the one-file rule (a sentence belongs in spec.md only if
it cannot be confirmed by opening one file):

- cut *"and adopts one an older build parked under a per-capture owner when provenance and kind
  match"* — the adoption rule is documented at length in `ConversationStore+Workboard.swift`'s own
  headers (the licence-to-adopt comment, `refuse`-an-adoption, and the provenance switch), which is
  where the one-file rule puts it. The durable half, *"a recapture repairs a bytes-less card"*,
  survives, merged into the preceding sentence. This is the sentence copy-b named as the weakest
  under that rule (O-16).
- cut *"as a blob row"* — a schema detail confirmable in the model file; the sentence's claim is
  "rides CloudKit".
- *"both sides' drafts"* → *"both drafts"*.

**Measured: 19827 words before, 19827 after.** `scripts/check-spec-size.sh` still fails on the
pre-existing whole-file ceiling (19827 / 16900) and on the same two unrelated decisions ("Sending
files and getting them back are two capabilities of one lane" 687/650; "Forgetting a gateway erases
the credentials and keeps the colour tag" 701/650). No section of mine is over its limit; the debt is
untouched, as plan §E requires.

---

## Counterfactuals — measured, not argued

The guard reads the catalog **from disk** at run time (`RefusalLaneSource.projectContainerURL` is
`#filePath`-derived), so a copied tree would still read the shared worktree's catalog unless it were
rebuilt there. Instead I swapped the catalog file itself, ran, and restored — the fixed file was
backed up first and `diff -q` confirmed byte-identical restoration after **each** run (`RESTORE OK`,
`RESTORE OK 2`). No source, no test and no other file was touched during either flip.

**CF-1, the exact pre-fix catalog** (old `workboard.voice.privacy` value, three banner rows absent) —
`Executed 6 tests, with 7 failures (0 unexpected)`, `** TEST EXECUTE FAILED **`:

| Test | Failure |
|---|---|
| `testNoWorkStringDescribesSendingDispatchingOrADraft` | `workboard.voice.privacy says sent: … Nothing is sent.` ← proves the un-stripping is load-bearing |
| `testTheVoiceSheetNamesTheSpeechProviderRatherThanPromisingInertness` | ×2 — the promise present, "speech provider" absent |
| `testTheDeskSyncBannerSpeaksAboutCardsRatherThanConversations` | `workboard.sync.banner.noAccount has no catalog row` |
| `testEveryWorkKeyInSourceHasACatalogRow` | ×3, one per missing `workboard.sync.banner.*` row |

**CF-2, the banner rows present but carrying the Chat sentences** ("your conversations") —
`Executed 1 test, with 6 failures (0 unexpected)`: two per key, the "has to name what the desk holds"
assertion and the "only the Chat rows may say conversations" assertion. This is the failure that
would fire if anyone ever "consolidates" the desk rows back onto `sync.icloud.banner.*`.

Restored state re-run: `Executed 6 tests, with 0 failures (0 unexpected)`,
`** TEST EXECUTE SUCCEEDED **`.

---

## Catalog dict diff — `json.load` + before/after, all four files

Every one of the four `.xcstrings` parses. Top-level keys other than `strings` compare equal in all
four. Key counts and the complete diff:

| Catalog | keys before → after | rows added / removed / changed |
|---|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2242 → **2245** | +3, −0, ~1 |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 → 43 | none |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 → 42 | none |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 → 299 | none |

```
+ workboard.sync.banner.noAccount     = 'iCloud is signed out — your cards won’t sync across your devices.'
+ workboard.sync.banner.quotaExceeded = 'Your iCloud storage is full — new cards can’t sync to your other devices.'
+ workboard.sync.banner.restricted    = 'iCloud is restricted on this device — your cards can’t sync.'
~ workboard.voice.privacy
    before: 'Keeps the recording on your private desk and adds the words when they’re ready. Nothing is sent.'
    after : 'Keeps the recording on your private desk and adds the words when they’re ready. The audio goes only to the speech provider you chose — never to an AI, never to a server of ours.'
```

Nothing removed anywhere. The bidirectional scan over the app target now reports **0 missing rows and
0 dead rows** for `workboard.*` (147 keys referenced in source).

---

## Catalog

**Keys I ADDED in source: NONE** — I mint no new keys. The three rows spliced were declared in source
by **c-guards** (`Views/Workboard/WorkboardSyncBannerPolicy.swift`); I only gave them catalog rows.

**Keys I made DEAD: NONE.** `workboard.voice.privacy` keeps its key and both halves moved together.
`sync.icloud.banner.{noAccount,restricted,quota,openSettings,dismiss}` all stay live — Chat renders
the three sentences, and both banners render the two buttons.

**I edited exactly one `.xcstrings`**, the main app catalog. The two share-extension catalogs and the
Watch catalog are byte-unchanged (`git status --short -- '*.xcstrings'` lists only
`Conduck/Conduck/Localizable.xcstrings`).

**Collected from the other `c-*` fixnotes, for the record:** c-drainer, c-lanes, c-recovery-core,
c-session and c-store each report "Keys I ADDED in source: NONE / Keys I made DEAD: NONE" and none of
them opened a catalog. c-guards' three keys are the whole of this phase's catalog debt, and it is now
paid. c-recovery-core's re-homed `workboard.voice.error.deskWrite` already has its row (it moved
between source symbols, not between keys) — confirmed present and referenced.

---

## Requests

1. **Founder copy pass — three lines are yours to rule on.** (a) The voice sheet's new privacy line
   above: it is the first place the product tells a person that their recording goes to a provider,
   and I chose an unconditional sentence over a conditional one for the reason given in §r3a#3. (b)
   The three desk banner sentences (c-guards wrote them; I only spliced them). (c) copy-b §Requests 2
   still stands on the tutorial line and the large-file confirm.
2. **`workboard.workspace.drop.overlay.caption` = "Files, photos, screenshots, links and text will be
   added here. Nothing is sent." is the next-weakest of the eight exempted rows.** Dropping a file
   reaches no provider, so the sentence is true in the vocabulary this product uses — but that
   overlay is also the surface a person is looking at while a payload gets mirrored to their iCloud,
   and the tutorial line is the only place the ceiling is explained. Not my finding and not my file
   (`WorkboardCaptureCanvas.swift`); flagged so it is a decision rather than an oversight.
3. **Nobody re-add `workboard.voice.privacy` to the strip.** The whole point of `outboundHopKeys` is
   that this key's value is scanned raw. A new Work string with an outbound hop belongs in that set
   too; a new Work string without one needs nothing.
4. **O-14 is CLOSED** (option b, minted keys) and can come off round 4's list. **O-16 shrank by one
   line**: the recapture/adoption sentence copy-b nominated is spent — the next cut has to come from
   somewhere else.
5. **Integrator — the guard scripts and the pre-existing spec-size failure.** `check-spec-cites.sh`,
   `check-folder-map.sh` and `check-storage-seam.sh` all pass; `check-spec-size.sh` exits **1** on
   the pre-existing debt and is expected to keep doing so (plan §E and §F both say not to fix it).
   Do not read that exit code as mine.
6. **macOS build owed at the gate.** Not run by me — my brief's verification list is iOS + watch, and
   nothing I touched is platform-specific (the one Swift source edit is a `defaultValue` string and a
   comment inside an existing `#if !os(watchOS)` view).

---

## Refuted

Empty. All four findings held against the current code.

---

## Guard verdicts

I converted one source-text guard and added none.

- **`WorkboardCopyTruthGuardTests.testNoWorkStringDescribesSendingDispatchingOrADraft` — KEPT, but
  its exemption is now scoped.** The blanket `inertnessPhrases` strip was the mechanism that hid
  r3a#3, so it survives only for keys not in `outboundHopKeys`. Measured: with the pre-fix value in
  place this test now fails (CF-1), where before it passed. No assertion was weakened and no key was
  removed from the scan — the scope narrowed in the direction of catching more.
- **`testTheVoiceSheetNamesTheSpeechProviderRatherThanPromisingInertness` — ADDED.** A key-specific
  copy-truth rule, checked on the raw value.
- **`testTheDeskSyncBannerSpeaksAboutCardsRatherThanConversations` — ADDED.** A key-specific rule
  over the three new rows.
- **Deleted or narrowed: none.** `testTheTutorialSyncLineNamesTheDeviceLocalLane`,
  `testEveryWorkKeyInSourceHasACatalogRow` and `testEveryWorkCatalogRowIsReferencedInSource` are
  untouched, and the class went 4 → 6 cases.
- The class header's rule list went from three rules to four; rule (3) states the two key-specific
  truths and the old (3) became (4). Constraint prose, no changelog narration.

---

## Gates — what I actually ran

DerivedData under `~/Library/Caches/gigaduck-builds/c-copy/{DerivedData,DerivedDataWatch}`, every log
written there and grepped for `': error: '` and the verdict strings — never judged from tail or exit
code alone. **No `-configuration` passed anywhere.** No `/tmp`, no bare `rm -rf`.

- **iOS `build-for-testing`** (sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`) → `ios-bft.log`:
  `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **iOS `test-without-building`**, five quoted `-only-testing:` flags → first attempt died in the
  launcher before any test case started (`Simulator device failed to launch ai.gigaduck.AgentRelay …
  Application failed preflight checks`, `ios-test.log`); retried once on the same sim, which reported
  itself already `Booted`. Second run, `ios-test-2.log`: `** TEST EXECUTE SUCCEEDED **`,
  `Executed 83 tests, with 0 failures (0 unexpected) in 15.481 (15.499) seconds`,
  `grep -cE '\.swift:[0-9]+: error: '` = **0**.

| Class | Result |
|---|---|
| `WorkboardCopyTruthGuardTests` (4 → **6** cases) | `Executed 6 tests, with 0 failures (0 unexpected)` |
| `WorkCaptureInboxTests` | `Executed 29 tests, with 0 failures (0 unexpected)` |
| `CarPlayVoiceTimingContractTests` | `Executed 22 tests, with 0 failures (0 unexpected)` |
| `ErrorSurfaceDriftGuardTests` | `Executed 7 tests, with 0 failures (0 unexpected)` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected)` |

`WorkCaptureInboxTests` is at **29**, so copy-b §Requests 1's blocking failure
(`testShareWritersValidateAndRollbackBeforeAtomicPublication`) is already gone from the tree — I did
not touch it and did not need to.

- **Full watch suite** (`ConduckWatchTests` scheme, sim `28AC563B-42C1-4E66-940D-77E63B07918B`) →
  `watch.log`: `** TEST SUCCEEDED **`,
  `Executed 232 tests, with 0 failures (0 unexpected) in 9.548 (9.628) seconds`,
  `grep -c ': error: '` = **0**.
- **Guard scripts**, from the worktree root:
  - `scripts/check-spec-cites.sh` → `✓ spec citations resolve — 795 Swift files scanned, 1 quoted section name(s), every one a live heading`
  - `scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped, and every path the map names exists`
  - `scripts/check-storage-seam.sh` → `✓ storage seam intact — 795 Swift files scanned, no raw store or live-adapter access outside …LiveStorage.swift`
  - `scripts/check-spec-size.sh` → exit **1**, PRE-EXISTING: `✗ docs/ai-context/spec.md is 19827 words; the ceiling is 16900.` plus the same two decisions at 687/650 and 701/650. **`wc -w docs/ai-context/spec.md` = 19827, identical to the baseline.**
- **`git diff --check`** → clean, exit 0.
- **Four catalogs** → all `json.load` cleanly; the dict diff is the table above.
- **macOS build** → not run (outside my verification list); see §Requests 6.

## Cleanup

`/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh c-copy` — run at end of task,
output `removed: c-copy`. Every log quoted above went with it, along with the two counterfactual
catalogs and the backup of the fixed one; re-run to reproduce. No bare `rm -rf`, no `/tmp`, no
throwaway tree copy (the counterfactuals were file swaps on the shared tree, each restored and
verified byte-identical in the same command).
