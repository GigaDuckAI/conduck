# f6-guards — cross-cutting guards

## What changed

**NEW `Conduck/ConduckTests/WorkDeskWriteOwnershipDriftGuardTests.swift`** — source guard, modelled on
`RefusalLaneSource` (reads app sources off disk via `#filePath`, comments stripped, whitespace squeezed
so a wrapped call and a one-line call read identically).

| Symbol | What it asserts |
|---|---|
| `testOnlyTheWorkboardStoreFileInsertsADeskEntityInTheAppTarget` | Walks EVERY `.swift` under `Conduck/Conduck` (app target only). Any file with a `WorkMaterial`/`WorkItem` insertion site must be `Services/ConversationStore+Workboard.swift`. |
| `testTheDoorStillInsertsBothDeskEntities` | Non-vacuity: the door still inserts both entities, so a rename cannot make the scan pass by asserting nothing. |
| `testTheIsolatedStoreSeamIsExemptedByItsCallShapeAndStillRefusesTheRealStore` | The ONE exemption: `ConversationStore.swift`'s `_writeMaterialAndBlobForTesting` seam, matched by its exact squeezed call shape (exactly one occurrence), plus — outside that call — no other insertion site in that file, the exempt call lives inside that function, and that function still carries `guard isIsolatedTestStore`. |
| `testOnlyTheWatchCaptureIntentInsertsADeskEntityOnTheWrist` | Separate walk of `ConduckWatch Watch App`: its only desk writer is `WorkboardCaptureIntent.swift` (and there must be exactly one). |
| `testTheDetectorRecognisesEveryInsertShapeAndIgnoresProseAndFetches` / `testTheWindowDoesNotReachPastTheCallItIsScanning` | Controls for the detector itself: one-line and wrapped `insertNewObject`, the two-statement `NSEntityDescription.entity(forEntityName:)` + `NSManagedObject(entity:)` route, a generated `WorkMaterial(context:)` subclass init; and it does NOT fire on `NSFetchRequest(entityName:)`, on `"WorkMaterialBlob"`, or on a comment describing an insert. |

**`Conduck/ConduckTests/WorkboardCopyTruthGuardTests.swift`** — ADDED rule (7) only; the six existing rules
are untouched. New: `testNoIntentTitleOrDescriptionNamesAPlatform`, statics `intentIdentitySuffixes`
(`.title`, `.description`) and `platformWords`; header comment gained a rule-(7) paragraph and its count line.
The rule reads the shipped catalog through the file's existing `catalogStrings()` / `englishValue(_:)` loader and
fails any `intent.*` row ending `.title`/`.description` whose English value contains a platform word
(`iphone(s) · ipad(s) · ipados · mac(s) · macos · watch(es) · watchos · carplay`), matched word-ish
(letter-run split, exact word compare — so "watch out" IS flagged, "machine" is not). It also asserts it
scanned ≥ 3 rows, so a key-shape rename cannot silently empty it.

**No shipped key violates the rule today — no allowlist was needed and none exists.** The three `intent.*`
identity rows in the shipped catalog are `intent.workboardCapture.title` ("Add to Work"), `intent.workboardCapture.description`,
`intent.converse.description`, plus `intent.converse.destination*` (out of scope: parameter values).

## New API

None. Both files are test-only; nothing outside `ConduckTests` calls into them.

Useful to other agents (same target, `internal`):

- `WorkDeskWriteOwnershipDriftGuardTests` — no callable surface; every helper is `private`.
- `containerPath(_:)` (private) exists because `RefusalLaneSource` addresses files from the PROJECT
  CONTAINER (`Conduck/Services/…`) while the tree walk keys them relative to one target directory
  (`Services/…`). Mixing the two spellings throws `missingFile` instead of asserting anything — it cost one
  red run here.
- Unchanged and still the shared reader: `RefusalLaneSource.projectContainerURL`,
  `RefusalLaneSource.rawSource(at:)`, `RefusalLaneSource.source(at:)`,
  `RefusalLaneSource.stripComments(_:)`, `RefusalLaneSource.body(ofFunction:in:path:)`.

## New strings

None. Guards only — no user-facing copy was added.

## Tests

Measured from the run logs (`~/Library/Caches/gigaduck-builds/work-f6/`):

- `ConduckTests/WorkDeskWriteOwnershipDriftGuardTests` — **Executed 6 tests, with 0 failures** (1.701s). All six are new.
- `ConduckTests/WorkboardCopyTruthGuardTests` — **Executed 10 tests, with 0 failures** (13.112s); 9 pre-existing + 1 new (`testNoIntentTitleOrDescriptionNamesAPlatform`).
- Combined run: **Executed 16 tests, with 0 failures (0 unexpected)**.

Build: `xcodebuild build-for-testing` (iOS Simulator 04DEF4F5, no `-configuration`) — exit 0, `grep -c ': error: '` = **0**.

## Requests

1. **Slice B (Shortcuts) — your new intent identity keys are now enforced.** `AddFilesToWorkIntent` and
   `RecordWorkNoteIntent` must declare title and description as `intent.<name>.title` /
   `intent.<name>.description` keys (not bare-English literals — the rule is catalog-keyed and a bare literal
   walks past it), and neither value may contain a platform word. "Add Files to Work" / "Record a Note to
   Work" both pass as written in the plan.
2. **Serial copy agent** — when you write the `intent.*` rows into `Localizable.xcstrings`, keep every
   `.title`/`.description` value platform-free. `workboard.*` UI copy is unaffected (rule (7) is scoped to
   `intent.*` identity rows only; the wrist's UI strings may keep saying iPhone).
3. **Slice C (Watch)** — if the wrist gains any new desk write, it must live in
   `ConduckWatch Watch App/WorkboardCaptureIntent.swift`; a new file there turns
   `testOnlyTheWatchCaptureIntentInsertsADeskEntityOnTheWrist` red. Same for the phone: every new capture
   surface goes through `upsertDeskMaterial`, never its own insert.

## Nobody undo

- **The exemption is a CALL, not a file.** `ConversationStore.swift` is exempted only for the exact squeezed
  text of the seam's `insertNewObject` call. Do not "simplify" this to a filename allowlist — that hands a
  5,000-line store blanket permission to grow a second desk writer, which is the whole failure this guard
  exists to prevent. If the seam is reformatted, re-read it and update `exemptSeamCall` to the new shape.
- **The 160-character window and the closing quote in `entityLiterals`.** The quote is what keeps
  `"WorkMaterialBlob"` (a different entity in a different store, inserted beside the material in the seam)
  from being flagged; the window is what keeps one statement's entity literal from being credited to the
  previous statement's insert. `testTheWindowDoesNotReachPastTheCallItIsScanning` fails if the window grows.
- **`NSEntityDescription.entity(forEntityName:` is deliberately in `insertionVerbs`** although it inserts
  nothing by itself: it is the first half of the two-statement `NSManagedObject(entity:insertInto:)` route,
  where the entity name is nowhere near the insert. Removing it opens that route.
- **Rule (7)'s word set is exact-match, not substring.** Do not replace it with
  `value.contains("mac")` — "machine" would go red and a noisy guard gets deleted. Do not relax it to
  ignore "watch" in prose either; a one-word rewrite is cheaper than the false claim.
- **Rule (7)'s `scanned >= 3` floor** is what stops a key-shape rename from turning the rule into a no-op.

## Open questions

1. Rule (7) cannot see an intent title written as a bare-English literal
   (`static var title: LocalizedStringResource = "…"`, as `ConverseIntent` and `CheckNetworkIntent` do
   today) — those rows key on the sentence itself and carry no `intent.` prefix. A source-side scan of
   `Intents/*.swift` for `static var title` literals would close it; it was left out of this slice because it
   needs a literal parser and the wave's new intents are all prefixed-key.
2. The ownership guard scans directories, not target membership. A file placed under `Conduck/Conduck` but
   excluded from the app target would still be scanned (strict direction — a false failure someone reads),
   and a file living outside both directories but compiled into a target would not be seen at all. The
   share extensions are unscanned for the same reason the plan does not name them: neither mounts the store.
