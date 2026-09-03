# e-drainer — r5s#2 CONFIRMED and fixed. K1 landed. Counterfactual MEASURED.

Parallel phase. No commits/pushes/stash/checkout, no index operations.
`Conduck/Configs/Identity-Override.xcconfig` untouched. **No `.xcstrings` opened**, no `.pbxproj`
edit, no mirror triplet touched, nothing under `docs/qa/desk-cloudkit/` touched. No file outside my
ownership list edited.

**Files changed — 2 production (1 new), 2 tests (1 new):**

| File | Change |
|---|---|
| `Conduck/Conduck/Services/Workboard/WorkMaterialCollisionEscape.swift` | **NEW** — K1, the derived escape id |
| `Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift` | escape-once on refusal · terminal retirement into `refused/` · `ImportOutcome` |
| `Conduck/ConduckTests/WorkCaptureDrainerCollisionTests.swift` | 1 → **3** cases, the old one rewritten (its asserted behaviour is what r5s#2 overturns) |
| `Conduck/ConduckTests/WorkMaterialCollisionEscapeTests.swift` | **NEW** — 4 cases, the derivation pinned |

`WorkCaptureDrainerTests` (10) and `WorkCaptureDrainerDurabilityTests` (8) are mine and were **not
edited**: nothing in them needed changing and both stay green. **Net iOS executed: +6.**

**HEADLINE.** iOS `** TEST BUILD SUCCEEDED **` (0 `: error: `) · targeted 9-class set
`Executed 96 tests, with 0 failures` · wider 17-class Work set `Executed 176 tests, with 0 failures` ·
signed macOS `** BUILD SUCCEEDED **` (3 `CodeSign` steps) · watchOS `** TEST BUILD SUCCEEDED **` ·
**counterfactual: all 3 collision cases fail on a tree with only the escape reverted, each on
`caught error: "invalidMaterialOwner"`, and the namespace pin fails on a one-hex-digit namespace
change** (§4).

---

## 1. r5s#2 — verified against the current code, then fixed

**VERDICT: CONFIRMED.** Re-located by symbol, not by the cited line. Every clause held:

| Claim in the finding | What the code did (HEAD f794856 + wave-E tree) |
|---|---|
| the kind gate refuses a share capture | `ConversationStore+Workboard.swift` — the pre-staging `if let existing, existing.kind != draft.kind { throw .invalidMaterialOwner }`, and `Self.requireMatchingKind(materialRows:kind:)` inside the transaction |
| `persistAndAcknowledge` releases and rethrows | its `catch` did `if await ownership.endImport() { try? await inbox.release(claim) }; throw error` — the entry goes back to `<base>/<envelopeID>/` **unchanged** |
| the next drain claims the unchanged entry again | `claimNext` is oldest-first over `pendingEnvelopeIDs()`; nothing about the entry has changed, so it refuses identically |
| …and stops the drain before later captures | `drainAvailableCaptures`'s `while true` loop has no catch: the throw exits the loop, so **every capture queued behind it never lands either**, on this drain and on every later one |
| `WorkCaptureDrainerCollisionTests:91-103` verifies only refusal + preservation | it asserted `XCTFail` unless the drain threw, then that the payload was still on disk. Nothing asserted a terminal disposition, and nothing asserted a later capture drained |

Two things the finding does not say that the trace added, and that shaped the fix:

1. **It is not only the kind gate.** `requireAdoptable` throws the *same* `invalidMaterialOwner` when a
   foreign owner row holds the id and the envelope's provenance cannot account for it. That refusal is
   just as permanent and blocks the drain the same way, so the escape treats both. See §3.1.
2. **Nothing is staged before the first refusal.** The pre-staging check fires ahead of
   `stageWorkMaterialBytes`, and the transaction-level refusal is followed by
   `if let key = staged?.vaultKey { try? await workAssetVault.remove(key) }` plus `deleteBlobRow`. And
   `WorkAssetVault.storeFileStreaming` **copies** (`FileHandle` read → write), it does not move. So the
   queue file the escape re-reads is byte-for-byte what the person shared. That is what makes a retry
   under a second id safe rather than a second chance at half-consumed bytes.

## 2. The fix

### 2.1 K1 — `WorkMaterialCollisionEscape` (new file, exactly to contract)

`static func materialID(forCapture captureID: UUID) -> UUID`, UUIDv5 (SHA-1) over its OWN
compile-time namespace literal `C0111DE0-0000-4000-A000-000000000001` — not the fallback-note
namespace (`DE5C0F00-…`), not the screenshot namespace (`5C7E0000-…`), not the desk id
(`DE5C0000-…`). The meaning is stated **verbatim** at the declaration:

> the id a capture's bytes land under when the capture's own id already names a card of another kind;
> a pure function of the capture id so every process and every retry derives the same card

and the declaration also states the terminal rule: "THERE IS NO SECOND ESCAPE."

Plain Foundation + CryptoKit, no platform guard. **Measured:** the file is *not* a member of
`ConduckWatch Watch App` — the target's `membershipExceptions` list in `project.pbxproj` is an
inclusion list and names no `Services/Workboard/` path — so no pbxproj edit was needed and none was
made. It is nonetheless free of anything the wrist cannot compile, per the brief, so joining that
target later costs nothing.

### 2.2 Escape once, in the drainer

`WorkCaptureDrainer.upsertEscapingCollision(_:sourceFileURL:sourceFileByteSize:legacyProvenance:)`
now wraps every one of the three `store.upsertDeskMaterial` call sites in `persist` (the share note
and both entry lanes). On `invalidMaterialOwner` it republishes the SAME draft under
`Self.escaping(draft)` — every field carried across verbatim, only the id derived — and a second
`invalidMaterialOwner` throws `TerminalCollision(materialID:escapeID:)`, a private error type whose
existence is the "never a third id" rule made structural rather than remembered.

The escaped record's id goes into `PersistedCapture.materialIDs` / `payloadBearingIDs` by the same
line that already recorded it, so **the remapped card and its bytes pass the existing durability
barrier before anything is acknowledged** — `confirmDurablyImported` reads the escaped card back and
demands `hasPayload` on it, exactly as the finding requires. No new barrier, no barrier weakened.

### 2.3 A double collision is terminal, and non-blocking

The drainer had **no** terminal disposition of its own: the only one in the system is
`WorkCaptureInbox.claimNext`'s `invalidEnvelope` branch, which **deletes** the directory. The finding
forbids deleting bytes, so the fix is the `refused/` sibling it names.

- `persistAndAcknowledge` gains `catch let collision as TerminalCollision`, placed **before** the
  generic catch so the release-and-rethrow path is untouched for every other error. It takes
  `ownership.endImport()` first (a claim proven lost is still terminal-by-takeover and touches
  nothing), then `retireRefusedCapture`, then `inbox.acknowledge`, and returns `.refused`.
- `retireRefusedCapture` copies the WHOLE claimed directory to `<inbox root>/refused/<envelopeID>/`
  **before** the acknowledgement, drops the copied lease, and writes a one-line `refusal.txt` naming
  both ids. If the copy or the reason write fails, the claim is released instead and the error
  surfaces — the queue keeps the bytes until they are provably somewhere else.
- `refused/` is invisible to the inbox by construction, which is stated at the constant:
  `pendingEnvelopeIDs()` counts only **UUID-named** children of the root (`childEnvelopeIDs` does
  `UUID(uuidString:)` on the leaf), and `reconcile` walks only `processing/` and `tmp/`.
- `persistAndAcknowledge` / `importUnderRenewedLease` now return a private `ImportOutcome`
  (`.published(PersistedCapture)` / `.refused`), and `drainAvailableCaptures` switches on it and
  **continues the loop** on a refusal. That is the whole "does not block later captures" half.

**Report:** a retirement increments the existing `invalidCaptureCount` rather than a new field. That
IS "the way the drainer disposes of a permanently unimportable entry today" — the disposition a
malformed envelope already gets — and it is the only one that reaches a person: `PersonalWorkbenchView`
already turns `invalidCaptureCount > 0` into "Conduck couldn't read one shared item, so it wasn't
added to your board." A new field would have been silent, because the surface that would read it is
not mine. The field's doc comment now states both sources. See §Requests 1 for the copy that should
follow.

### 2.4 What I did NOT change

`drainAvailableCaptures()`'s signature, `Report`'s four field names and its `Equatable`/`empty`,
`persist`'s ordering and its checkpoints, `confirmDurablyImported`'s one-fetch shape, the heartbeat
task group, `ImportOwnership`, the two `#if CONDUCK_TESTING` hold seams, `legacyProvenance`, and
every `WorkCaptureInbox` API. `WorkboardLiveRepository.drainCaptures()`,
`WorkCaptureRetryCoordinator` and `WorkVoiceScreenshotCoordinator` needed no edit and none of those
files was opened. **No assertion anywhere was weakened, narrowed or deleted.**

## 3. Decisions

### 3.1 The escape fires on ANY `invalidMaterialOwner`, not only the kind gate

The store raises one error case for two permanent refusals: a card of another KIND at that id, and a
foreign owner row the envelope's provenance cannot account for. I cannot distinguish them without a
new error case in `WorkboardRecords.swift`, which is not mine — and I am satisfied the wider treatment
is not merely acceptable but *intended*. `requireAdoptable`'s own comment says its job is to stop a
capture "re-homing — and, carrying bytes, replacing the payload of — a card that merely shares its
identifier". The escape does neither: it writes a NEW card at a derived id and leaves the foreign row
untouched. It is the safe disposition that refusal was protecting, so the two fit together.

The one cost, stated plainly: if a foreign row would later have been merged or re-homed by CloudKit,
a plain retry might eventually have succeeded under the ORIGINAL id, and the escape spends that
possibility to end the block now. The card is the person's file either way, and the escape id is
stable, so nothing is lost but the id. Blocking every capture behind it while waiting for a merge
that may never come is the worse trade.

### 3.2 A partially published capture keeps the cards it published

The share note publishes before the entries, so a capture whose entry is doubly refused has already
put its note on the desk. That card stays; only the queue entry is retired. Deleting a card the desk
accepted to make a retirement look tidy is a worse act than leaving it, and the test pins it.

### 3.3 The retirement is named for the ENVELOPE, not the acquisition

First draft used the claim directory's name (`<envelopeID>_<epoch>_<generation>`), which is unique per
acquisition. Changed to `<envelopeID>`: if the acknowledgement after a retirement fails transiently,
the entry returns to the queue and is refused again next drain, and an acquisition-scoped name would
write a SECOND copy of the same bytes each time. Envelope-scoped makes the retirement idempotent, and
two captures cannot share the name because the queue refuses a publication under an id it already
holds.

### 3.4 One count, not two

Covered in §2.3. A `refusedCaptureCount` nobody reads would leave the person with no signal that their
share vanished from the queue, which is worse than a slightly imprecise sentence.

## 4. Counterfactuals — MEASURED, in an isolated copy

Throwaway tree at `~/Library/Caches/gigaduck-builds/e-drainer/cf/tree` (copied whole, cleaned with the
slug at the end).

**CF1 — the escape reverted.** `upsertEscapingCollision` reduced to a direct pass-through to
`store.upsertDeskMaterial` (no escape, no `TerminalCollision`); everything else — including
`ImportOutcome`, the retirement path and all four new tests — left in place. `** TEST BUILD SUCCEEDED **`,
then:

```
Test Suite 'WorkCaptureDrainerCollisionTests' failed
	 Executed 3 tests, with 3 failures (3 unexpected) in 1.121 (1.122) seconds
…testACaptureCollidingWithACardOfAnotherKindLandsUnderItsEscapeID] : failed: caught error: "invalidMaterialOwner"
…testAReplayOfACollidedCaptureRepairsTheSameEscapedCard] : failed: caught error: "invalidMaterialOwner"
…testACaptureRefusedUnderBothIdsIsRetiredWithItsBytesAndDoesNotBlockTheDrain] : failed: caught error: "invalidMaterialOwner"
```

All three fail at the drain call itself — the finding's defect reproduced exactly: the drain throws,
so the capture behind it is never reached.

**CF2 — the namespace changed by one hex digit** (`…0001` → `…0002`), on top of CF1:

```
Test Suite 'WorkMaterialCollisionEscapeTests'
	 Executed 4 tests, with 1 failure (0 unexpected)
…testOneCaptureIdDerivesOnePinnedEscapeId] : XCTAssertEqual failed:
  ("Optional(07881DD1-E290-57E7-B824-514A5788549D)") is not equal to
  ("Optional(BAB27C0C-E2D6-5517-BC2A-74D5949AB973)")
  - the escape namespace is part of the on-disk contract, not an implementation detail
```

The pin holds the namespace, which is the point: a silent namespace change would orphan every escaped
card already written and let the next replay publish a second copy of it.

**One honest note from CF1, NOT mine.** In the CF1 run
`WorkCaptureDrainerDurabilityTests.testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite`
also failed once, with `caught error: "CancellationError()"`. I re-ran that class alone on the same
counterfactual tree **twice**: `Executed 8 tests, with 0 failures` both times. It also passed in every
run on my tree (three separate runs). It is a pre-existing timing flake in c-drainer's takeover work,
surfaced by load, not by anything in this slice. Recorded, not fixed — it is not my file's case to
weaken or to re-time.

## 5. The four regression tests, and how each proves the old code wrong

`WorkCaptureDrainerCollisionTests` (1 → 3; the original case is rewritten because its asserted
behaviour — bytes left queued for ever — is exactly what r5s#2 overturns):

1. **`testACaptureCollidingWithACardOfAnotherKindLandsUnderItsEscapeID`** — a synced `.image` card at
   `sharedID`, then a `.file` capture claiming `sharedID`, and a second capture published behind it.
   One drain: no throw, `invalidCaptureCount == 0`, `imported + replayed == 2`; the file card is on the
   desk under `WorkMaterialCollisionEscape.materialID(forCapture: sharedID)` and
   `loadWorkMaterialPayload` returns its own bytes; the image card is untouched (kind, title,
   `.synced`, and its payload still its own); both notes are on the desk, so the capture behind the
   collision drained in the SAME pass; the queue is empty, no copy of `payload-000.bin` survives, and
   no `refused/` was created. *Old code:* `caught error: "invalidMaterialOwner"` at the drain.
2. **`testAReplayOfACollidedCaptureRepairsTheSameEscapedCard`** — the same envelope published and
   drained again through a SECOND `WorkCaptureInbox` and a SECOND `WorkCaptureDrainer` over one
   directory and one store (the app/intent-process shape). The desk's material id set is byte-identical
   to the first pass and there is still exactly one `.file` card. This is the "pure function ⇒
   idempotent across processes" assertion the finding asks for, at the drainer level. *Old code:* same
   throw.
3. **`testACaptureRefusedUnderBothIdsIsRetiredWithItsBytesAndDoesNotBlockTheDrain`** — image cards at
   BOTH `sharedID` and its escape id. One drain: `invalidCaptureCount == 1`, `imported + replayed == 1`
   (the capture behind it landed), no `.file` card, both image cards untouched, the note the refused
   capture had already published still on the desk; `pendingCount() == 0` and nothing left under
   `processing/`; and **the bytes are in `refused/`** — exactly one copy of `payload-000.bin`, the
   directory named for the envelope, carrying `manifest.json`, carrying a `refusal.txt` that names both
   ids, and NOT carrying the claim lease. *Old code:* same throw, and the entry back in the queue.

`WorkMaterialCollisionEscapeTests` (new, 4): the pinned literal for one fixed input; purity (8 repeats
equal, 64 distinct inputs → 64 distinct outputs); disjointness from the capture id, the desk id, the
screenshot derivation, the fallback-note derivation, and from the escape of the escape; and the
version-5 + standard-variant bits.

## 6. Gates — WHAT I ACTUALLY RAN

Slug `e-drainer`, everything under `~/Library/Caches/gigaduck-builds/e-drainer/`, every log written
to a file and grepped. `.claude/scripts/clean-build-cache.sh e-drainer` run at the end →
`removed: e-drainer`.

| Gate | Command | Result line |
|---|---|---|
| iOS build-for-testing | `build-for-testing … -destination 'platform=iOS Simulator,id=5C851D88-959C-445E-ACC8-A4C6ADB2876C'` | `** TEST BUILD SUCCEEDED **`, `grep -E ': error: '` → 0 |
| targeted (9 classes) | `test-without-building` + one `-only-testing` per class: Collision, MaterialCollisionEscape, Drainer, DrainerDurability, DrainerTakeover, DeskUpsert, ChatCapture, InboxTests, InboxLease | `Executed 96 tests, with 0 failures (0 unexpected)`, `** TEST EXECUTE SUCCEEDED **` |
| wider Work set (17 classes) | as above + AssetVault, RefreshCoordinator, SharePublisher, Persistence, LiveRepositorySupport, PublicationLock, Availability, BlobPublication | `Executed 176 tests, with 0 failures (0 unexpected)` |
| signed macOS | `build … -destination 'platform=macOS'` | `** BUILD SUCCEEDED **`, 3 `CodeSign` steps, 0 `: error: ` |
| watchOS | `build-for-testing -scheme ConduckWatchTests -destination 'platform=watchOS Simulator,id=28AC563B-…'` | `** TEST BUILD SUCCEEDED **` |
| guards | `check-storage-seam.sh` · `check-folder-map.sh` · `check-legal-copies.sh` · `check-spec-cites.sh` | all `exit=0`; seam `✓ 802 Swift files scanned`, map `✓ 36 Swift source directories, all mapped` |
| whitespace | `git diff --check` | `exit=0`, no output |

Per-class counts in the targeted run: Collision 3 · Durability 8 · Takeover 1 · Drainer 10 · InboxLease
17 · Inbox 29 · CollisionEscape 4 · ChatCapture 8 · DeskUpsert 16.

### NOT run, stated plainly

- **Full iOS suite.** Not run by me — the tree was being edited by other agents throughout
  (`ConversationStore+Workboard.swift`, `PendingRetryStore.swift` and three test files changed under me
  mid-session). A full-suite number from this tree would describe a moment nobody will ship. The
  orchestrator's gate run is the one that counts.
- **watch test EXECUTION.** Build only; I added no watch-facing code.
- **Simulator TCC check.** Not needed: nothing in my slice records audio, and no audio class was run.
- **Any device QA.** See §Founder QA.

## Catalog

**Keys I ADDED in source: NONE.** The one new string in this slice is `refusal.txt`'s body, which is
forensic text written into the App Group and never displayed to anyone — a localized key there would be
a lie about who reads it.

**Keys I made DEAD: NONE.** I deleted no code carrying a string. The five keys the drainer owns are all
still live: `workboard.capture.note` · `workboard.capture.sharedText` · `workboard.capture.image` ·
`workboard.capture.webPage` · `workboard.capture.file`.

**No `.xcstrings` file was opened.**

## Requests

1. **Copy owner / whoever owns `PersonalWorkbenchView.swift`.** `invalidCaptureCount` now also carries
   a capture the desk refused twice, and for that one the existing sentence —
   `workboard.capture.discarded.message.one`, "Conduck couldn't read one shared item, so it wasn't
   added to your board." — is half true: it was not added, but Conduck read it fine and its file still
   exists. If a truer sentence is wanted it needs to cover both sources without promising the person a
   way to reach `refused/` (there is none, by design). **I did not mint a key**, because the referent
   would have been in a file I do not own and `testEveryWorkCatalogRowIsReferencedInSource` would fail
   on an unreferenced row.
2. **Whoever owns `WorkCaptureInbox.swift` (c-drainer's territory).** Two facts are now load-bearing
   for me, and both are properties the inbox already has rather than favours I am asking for:
   (a) `pendingEnvelopeIDs()` must keep counting only **UUID-named** children of the root — a sweep or
   an enumeration that stopped filtering on `UUID(uuidString:)` would start claiming `refused/`;
   (b) `reconcile` must keep walking only `processing/` and `tmp/`. If either ever widens, the
   retirement needs a home outside the inbox root and I want to know.
3. **d-store / whoever owns `WorkboardRecords.swift`.** Nothing owed. But if a future round wants the
   escape narrowed to the KIND collision alone, that needs `invalidMaterialOwner` split into two cases
   (kind collision vs. unprovable owner). §3.1 argues the wide treatment is correct, so this is an
   option, not a debt.
4. **e-recover (K4).** Your invalidMaterialOwner retry uses the same
   `WorkMaterialCollisionEscape.materialID(forCapture:)` I added, over the same namespace — so a
   capture that escaped in the recovery lane and one that escaped in the drain lane land on the SAME
   card. That is intended (it is what makes the two lanes idempotent against each other), and the
   pinned literal in `WorkMaterialCollisionEscapeTests` guards it for both of us. If you need a
   different id for a different meaning, mint a namespace of your own rather than reusing this one.
5. **Orchestrator — suite arithmetic.** `WorkCaptureDrainerCollisionTests` 1 → **3** (+2) ·
   `WorkMaterialCollisionEscapeTests` **+4** (new class). **Net +6 iOS executed.**
   `WorkCaptureDrainerTests` stays at 10, `WorkCaptureDrainerDurabilityTests` at 8.
6. **Orchestrator — the pre-existing flake.** `WorkCaptureDrainerDurabilityTests.`
   `testAProvenTakeoverStopsTheImportBeforeItsNextMaterialWrite` failed once under parallel load with
   `CancellationError()` and passed on three subsequent runs (twice on the counterfactual tree, and in
   every run on the working tree). Not mine to re-time; if the gate run shows it again, the honest fix
   is a longer window, not a weaker assertion.

## Refuted

**Empty.** r5s#2 held in full, including the clause about the existing test verifying only refusal and
preservation. The design directions in the brief — K1's shape, the escape-once rule, the terminal
second refusal, and the `refused/` sibling — were all implementable as written; the only judgement the
brief left open ("find that path; if none exists…") resolved to *none exists that preserves bytes*,
so the `refused/` fallback it names is what I built.

## Founder QA

Device-only, none reachable by a unit test. Both need a genuine id collision, which cannot be staged on
a device without a debug build that mints one — so treat these as **read-the-code confirmations plus one
observable**, not as steps to perform:

1. **The observable that matters, and it is a non-event.** Share several files in a row from another
   app while Work already holds cards. Every share must appear. Before this change, ONE capture that
   could not publish would have stopped every share queued behind it — silently, with no card and no
   message — until the app was reinstalled. There is nothing new to see; what you are confirming is
   that the queue never stalls.
2. **If you ever see "Conduck couldn't read one shared item, so it wasn't added to your board"** after
   a share that plainly was readable, that is a retirement rather than a malformed envelope. The file
   still exists on the device, in the app's App Group container under
   `WorkCaptureInbox/refused/<envelope-uuid>/`, with a `refusal.txt` naming the two ids. There is no UI
   for it by design; it is there so nothing a person shared is destroyed by a refusal. Worth one
   look in the container if it ever fires, because in a working build it should never fire.

## Settled facts

One sentence each; true of the code as it now stands.

- A capture whose material id already names a card of another kind is not requeued for ever: its card is
  published once more under a derived escape id, so the person's file lands on the desk and the queue
  moves on.
- The escape id is a pure function of the colliding id (UUIDv5 over a namespace of its own), so two
  processes draining one queue file and any later replay all repair the same card instead of adding a
  second one.
- There is exactly one escape: a refusal of the escape id too is terminal, and the drainer never derives
  a third id.
- A capture that can never become cards is retired rather than requeued — its whole claimed directory is
  copied to `refused/` beside the queue, with a one-line reason, before the queue entry is
  acknowledged — so no shared file is ever deleted by a refusal.
- A terminal refusal never blocks the queue: the drain counts it as a capture that did not arrive and
  goes straight on to the captures behind it in the same pass.
- Nothing sweeps or claims `refused/`: it is not a UUID-named child of the inbox root, and reconciliation
  walks only `processing/` and `tmp/`.
- A capture that had already published some of its cards before a terminal refusal keeps them; retiring
  the queue entry never un-publishes a card the desk accepted.
