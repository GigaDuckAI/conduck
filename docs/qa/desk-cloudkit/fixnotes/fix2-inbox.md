# fix2-inbox — t#3 + t#10. Both CONFIRMED and fixed; both measured against counterfactual builds.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` in the worktree untouched.
**No `.xcstrings` file opened.** Nothing under `docs/qa/desk-cloudkit/` touched. **No existing mirror
triplet touched** (`git status --short -- '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift'` is
empty). No pbxproj edit. No file outside my ownership list edited.

Files I changed — six, all mine or new:

| File | Change |
|---|---|
| `Conduck/Conduck/Services/WorkCaptureDirectoryPublisher.swift` | **NEW** (canonical copy of a new mirror triplet) |
| `Conduck/ConduckShareExtension/WorkCaptureDirectoryPublisher.swift` | **NEW** (mirror) |
| `Conduck/ConduckShareExtensionMac/WorkCaptureDirectoryPublisher.swift` | **NEW** (mirror) |
| `Conduck/ConduckShareExtension/ShareViewController.swift` | Work writer publishes through the publisher |
| `Conduck/ConduckShareExtensionMac/ShareViewController.swift` | same, identically shaped |
| `Conduck/Conduck/Services/WorkCaptureInbox.swift` | `publishAppCapture` adopts the same transaction; injectable claim-generation factory |
| `Conduck/ConduckTests/WorkCaptureSharePublisherTests.swift` | **NEW**, 7 cases |
| `Conduck/ConduckTests/WorkCaptureInboxLeaseTests.swift` | 14 → 15 cases |

---

## 1. t#3 — the two share-writer publication tests prove token order, not behaviour

**VERDICT: CONFIRMED.** Re-located by symbol. `WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication`
(`:297` at the time of check) read each appex's source and asserted four substrings —
`try envelope.validateForPublication()` before `try fm.moveItem(at: tmp, to: published)`, plus
`if !didPublish` and `try? fm.removeItem(at: tmp)`. Every clause of the finding's evidence held:

| Claim | What was true |
|---|---|
| dead code or comments satisfy it | yes — the assertions are `String.contains`; a commented-out publish body passes |
| an honest extraction breaks it | yes, demonstrated: my extraction removes both anchor tokens and the test now fails on `XCTUnwrap` of the `validateForPublication` range |
| no test injects validation or filesystem failures and inspects the directories | yes — nothing in the suite drove a share publication at all; `WorkCaptureInboxTests` only ever *reads* directories a fixture wrote by hand |

Nothing refuted.

### 1.1 The mechanism I chose, and why

**A new mirrored triplet `WorkCaptureDirectoryPublisher.swift`** — main app + both appexes, byte-identical
from `import Foundation` onward — exactly the pattern `WorkCaptureEnvelope.swift` and
`ShareTargetsSnapshot.swift` already set, and the pattern the reviewer's own `keep` verdict on
`testThreeCrossProcessEnvelopeCopiesAreIdenticalBelowImport` endorses.

Why not the alternatives:

- **Adding an appex source to the ConduckTests target** would need a `PBXFileSystemSynchronizedBuildFileExceptionSet`
  membership edit to `project.pbxproj`, and it cannot work anyway: both appexes would then declare the same
  type names in one module.
- **A publisher living only in the two appexes** is untestable for the same reason — no test bundle can link
  an appex.
- So the coverage reaches both extensions in three steps, stated in the test file's header: the failure paths
  are driven against the main-app copy through an injected filesystem · the three copies are proved
  byte-identical below `import Foundation` · each appex's Work writer is proved to delegate to that
  transaction and to publish nothing by hand.

**The app copy is live code, not a stub for the mirror.** `WorkCaptureInbox.publishAppCapture` now publishes
through the same transaction, so the in-app quick capture, the iOS share and the macOS share all use one
publication shape. That is a deliberate widening of my minimal-touch scope inside a file I own; it is what
makes the tested copy the shipped copy in every process rather than only in the two I cannot link.

### 1.2 The transaction (file + symbol)

| Symbol | What it is |
|---|---|
| `protocol WorkCaptureFileSystem` | four operations: `createDirectory` · `writeProtected` · `moveItem` · `removeItem`. The seam that makes the failure paths reachable |
| `struct WorkCaptureFileManagerFileSystem` | production impl; `[.atomic, .completeFileProtection]` on every write, injectable `FileManager` so an actor's own instance is used |
| `struct WorkCaptureDirectoryPublisher` | `inboxURL` + `fileSystem`; `stagingURL(named:)` / `publishedURL(for:)` / `beginStaging(named:)` / `commit(_:staging:)` / `discard(_:)` |
| `WorkCaptureDirectoryPublisher.Failure` | `.manifestTooLarge` · `.envelopeNamesADestination` |

`commit` is the whole invariant in one place: refuse a targeted envelope → `validateForPublication()` →
encode → manifest bound → write `manifest.json` → ONE `moveItem` into the queue. **Any throw discards the
staging directory before rethrowing**, so a refused capture never waits for a sweep while a copy of the
person's private bytes sits on disk. The callers keep a `defer` for the earlier window (provider loading),
which `discard` also owns.

`name` is the caller's on `beginStaging` because uniqueness is the caller's concern: a share mints a fresh
capture id, while `publishAppCapture`'s id is caller-owned and replayable and therefore needs the
`<id>-<UUID>` discriminator it already used.

### 1.3 The `targetWorkItemID` guard — a source grep replaced by an invariant

The deleted test's fourth assertion (share-contract's deliberate addition) was `source.contains("targetWorkItemID: nil")`.
`commit` now **refuses** any envelope naming a destination, so a targeted share is impossible rather than
merely unwritten by today's appexes — Work is one desk and the drainer has nothing to resolve a target
against. The source assertion is kept as well, scoped to each appex's Work writer: it stops an appex ever
*building* one and shipping a share that always fails. Both are in the new file.

### 1.4 Deviations, with why

1. **`publishAppCapture` adopted the transaction** (§1.1). Semantics preserved exactly: a
   `PublicationValidationFailure` still propagates unchanged (`testEmptyAppCaptureFailsWithoutPublishingPartialDirectory`
   still asserts `.emptyCapture`), a manifest over the bound and every I/O fault still resolve to
   `InboxError.filesystemFailure` after the same "another process won the race" re-check, and the staging
   directory still carries its `<id>-<UUID>` discriminator. Validation now runs *after* the staging directory
   is opened rather than before; the directory is removed on the refusal, so nothing observable changed.
2. **The publisher's types are `nonisolated`** (`nonisolated struct`, `nonisolated` protocol requirements).
   The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; without it every call from the inbox
   actor warned "call to main actor-isolated …". `nonisolated struct` is the established idiom here
   (`ShareTargetsSnapshot`, `WatchWorkboardCapture`).
3. **`WorkCaptureFileManagerFileSystem` is `@unchecked Sendable`** with a one-line justification at the
   stored property: `FileManager`'s file operations are safe across threads and the wrapper adds no mutable
   state. Without it the protocol's `Sendable` requirement cannot be met while still injecting the actor's
   own `FileManager`.
4. **No new user-facing copy**, so no catalog work.

## 2. t#10 — the acquisition suite never forces a generated claim-directory collision

**VERDICT: CONFIRMED.** `claimNext` built its generation as a literal `UUID()`, so
`Self.isDestinationExistsError(error) → continue` was unreachable from any test: no fixture can pre-create a
path whose name contains a UUID the actor has not minted yet. Traced the branch by hand and found it
*correct* — a taken destination is treated as an ordinary claim race — but wholly unexercised.

**Fix**: `init(baseURL:fileManager:makeGeneration:)` gained a defaulted `@Sendable () -> UUID` factory
(production default `{ UUID() }`; the `shared` initializer passes the same). An init parameter rather than
`#if CONDUCK_TESTING`, because the initializer it sits on already exists solely for an isolated directory,
and a defaulted parameter is narrower than a compile-time seam. Its doc comment says why it exists.

## 3. Tests

### 3.1 New: `WorkCaptureSharePublisherTests` (7 cases)

| Case | Asserts |
|---|---|
| `testAStagedCaptureIsPublishedByOneAtomicRename` | the published directory IS the staged one (staging gone, payload bytes identical, manifest decodes to the same id/note/entries, `targetWorkItemID` nil) |
| `testARefusedEnvelopeIsNotPublishedAndTakesItsStagedBytesWithIt` | **validation failure**: `.emptyCapture` thrown, nothing in the queue, staged bytes removed |
| `testAStagingWriteThatCannotLandPublishesNothing` | **temporary-write failure** (injected `writeProtected` fault): throws, nothing published, staging removed |
| `testADestinationAlreadyTakenLeavesTheExistingCaptureUntouched` | **destination collision**: throws, the occupied directory keeps its own single file and byte content, staging removed |
| `testAnEnvelopeNamingAWorkDestinationCannotBePublished` | `.envelopeNamesADestination`; nothing published |
| `testThreeCrossProcessPublisherCopiesAreIdenticalBelowImport` | the three copies are byte-identical below `import Foundation`, and the publisher's restated `manifestFilename` equals `WorkCaptureInbox.manifestFilename` |
| `testBothShareExtensionsPublishThroughThePublisherRatherThanByHand` | for BOTH appexes, inside the `writeWorkCaptureEnvelope` slice only: contains `publisher.commit(envelope, staging: tmp)` and `publisher.discard(tmp)`, contains **no** `moveItem(at: tmp`, and builds `targetWorkItemID: nil` |

### 3.2 New: `WorkCaptureInboxLeaseTests.testAnOccupiedAcquisitionPathRefusesTheClaimAndTouchesNeitherDirectory`

Scripted generations aim the claiming rename at a pre-created `processing/<id>_<epoch>_<G1>` holding a
sentinel `manifest.json`. `claimNext` returns **nil**; the decoy keeps its single file and its exact bytes;
the pending capture keeps `["manifest.json", "payload-000.pdf"]`; `pendingCount == 1`. The next call mints a
different generation, claims normally, and its lease names this instance and that generation — with the
decoy still sitting beside it (`claimedURLs(for:).count == 2`).

### 3.3 Counterfactuals — MEASURED, in an isolated copy

Tree copied to `~/Library/Caches/gigaduck-builds/fix2-inbox/tree` (its `Identity-Override.xcconfig` symlink
re-pointed at the same real file so the relative path resolved). **Nothing in the worktree was touched for
this.** Two variants, each rebuilt (`** TEST BUILD SUCCEEDED **`, 0 `error:`) and run:

**CF1 — `commit` does not discard on failure, and does not refuse a targeted envelope**
(`cf-test-1.log`, `** TEST EXECUTE FAILED **`): `Executed 7 tests, with 7 failures (0 unexpected)`. Five of
the seven cases redden, and exactly the five the mutations concern:

```
testADestinationAlreadyTakenLeavesTheExistingCaptureUntouched] : XCTAssertFalse failed
testAnEnvelopeNamingAWorkDestinationCannotBePublished] : XCTAssertThrowsError failed: did not throw an error
testAnEnvelopeNamingAWorkDestinationCannotBePublished] : XCTAssertFalse failed
testARefusedEnvelopeIsNotPublishedAndTakesItsStagedBytesWithIt] : XCTAssertFalse failed - A refused transaction removes its copy of private bytes rather than waiting for a sweep
testAStagingWriteThatCannotLandPublishesNothing] : XCTAssertFalse failed
testThreeCrossProcessPublisherCopiesAreIdenticalBelowImport] : XCTAssertEqual failed  (×2 — only the app copy was mutated, so the mirror guard bites too)
```
`testAStagedCaptureIsPublishedByOneAtomicRename` and `testBothShareExtensionsPublishThroughThePublisher…`
stayed green, correctly: neither mutation touches them.

**CF2 — the publisher restored; `claimNext` no longer treats a taken destination as a race**
(`cf-test-2.log`, `** TEST EXECUTE FAILED **`): `WorkCaptureInboxLeaseTests Executed 15 tests, with 1
failure` — **only** the new case —
`testAnOccupiedAcquisitionPathRefusesTheClaimAndTouchesNeitherDirectory] : failed: caught error: "filesystemFailure"`;
`WorkCaptureSharePublisherTests Executed 7 tests, with 0 failures`.

**Honesty about "fails on the old code":** neither new class *compiles* against the pre-fix tree — one needs
a type that did not exist, the other a parameter that did not exist. That is inherent to a fix whose content
is a new seam, which is why the counterfactuals above mutate the mechanism instead. No case is vacuous
against the behaviour it names.

## 4. Gates — WHAT I ACTUALLY RAN

Slug `fix2-inbox`. DerivedData under `~/Library/Caches/gigaduck-builds/fix2-inbox/{DerivedData,DerivedDataMac,DerivedDataCF}`,
every log written there and grepped for `: error: ` and the verdict strings — never judged from tail or exit
code. **No `-configuration` passed anywhere.** Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`.

- **iOS `build-for-testing`** → `bft-5.log` (final, after the tree settled): `grep -c ': error: '` = **0**,
  `** TEST BUILD SUCCEEDED **`. **`ConduckShareExtension` compiled in the same run** (24 build lines in that
  target, including `Compiling WorkCaptureDirectoryPublisher.swift … in target 'ConduckShareExtension'`).
- **Zero warnings in any file I own** (`grep -cE '(WorkCaptureInbox|WorkCaptureDirectoryPublisher|WorkCaptureSharePublisherTests|ShareViewController)\.swift:[0-9]+:[0-9]+: warning:'` = 0).
  The two warnings in `WorkCaptureInboxLeaseTests.swift:33,60` ("converting non-Sendable function value…") are
  **pre-existing** — those two lines are byte-identical to `HEAD`, verified with `git show`.
- **Targeted run** (`test-3.log`, `test-without-building`, one quoted `-only-testing` flag per class):

| Class | Result |
|---|---|
| `WorkCaptureSharePublisherTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.014 (0.015) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.058 (0.061) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 1 failure (0 unexpected) in 0.919 (0.926) seconds` — the superseded guard, §Requests 1 |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.075 (0.077) seconds` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 8 tests, with 0 failures (0 unexpected) in 0.530 (0.532) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.118 (0.120) seconds` |
| `ConversationStoreWorkCaptureTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.488 (0.490) seconds` |
| `WorkboardAudioCaptureTests` | `Executed 19 tests, with 0 failures (0 unexpected) in 0.124 (0.128) seconds` |
| total | `Executed 107 tests, with 1 failure (0 unexpected) in 2.325 (2.349) seconds` |

  An earlier run (`test-2.log`) also passed `ErrorSurfaceDriftGuardTests 7/0`, `ShareTargetsSnapshotTests 9/0`,
  `ShareTargetsSnapshotWriterColorTests 7/0`, `WorkCaptureRefreshCoordinatorTests 6/0`.
- **macOS signed build** `-destination 'platform=macOS'` → `mac-1.log`: 0 anchored `.swift:…: error:`,
  `** BUILD SUCCEEDED **`, `Signing Identity: "Apple Development: Peter Krueck (Z4PNDLZK98)"`, **signed
  through the identity override — no `CODE_SIGNING_ALLOWED=NO` fallback needed**. `ConduckShareExtensionMac`
  built (86 lines in that target, including its `WorkCaptureDirectoryPublisher.swift`) and
  `Conduck.app/Contents/PlugIns/ConduckShareExtensionMac.appex` is present. `mac-2.log` re-ran it on the
  final tree: `** BUILD SUCCEEDED **`, 0 errors.
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 785 Swift files scanned…`, exit 0.
- `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped…`, exit 0.
  (The three new files land in directories the map already names; no pbxproj edit was needed — all four
  groups are `PBXFileSystemSynchronizedRootGroup`s, verified in `project.pbxproj`, and
  `git status --short -- Conduck/Conduck.xcodeproj` is empty.)
- `git diff --check` → clean, exit 0.
- `git status --short -- '*.xcstrings' '*WorkCaptureEnvelope.swift' '*ShareTargetsSnapshot.swift' 'Conduck/Configs' 'Conduck/Conduck.xcodeproj' 'docs/qa'` → **empty**.
- Build caches removed at end of task: `.claude/scripts/clean-build-cache.sh fix2-inbox` → `removed: fix2-inbox`.
  **The logs and the isolated copy go with them**; re-run if you need them.

### NOT run, stated plainly

- **Full iOS suite and watch suite.** Neither is in my VERIFY, and six agents were editing the tree, so a
  full-suite number from me would have been mostly theirs. Nothing I touched compiles into the watch target
  (`WorkCaptureInbox.swift` and the new publisher are not in the `ConduckWatch Watch App`
  `membershipExceptions` list — checked in `project.pbxproj`; the appexes are separate targets entirely).
- I did not exercise a real share sheet. Share extensions cannot be driven headlessly; what is proved is that
  both appexes compile, both embed, and both delegate to a transaction whose every failure path is tested.

### Parallel-phase blockage (not mine, recorded per protocol)

Builds 2 and 3 failed **only in fix2-store's files** — `ConversationStore+Workboard.swift:2652` ("unexpected
`}` in conditional compilation block") and then `ConversationStoreAtomicWorkCaptureTests.swift:20,39,59,99`
("no member `createWorkItemWithInitialMaterial`"). Waited 125 s between attempts, edited nothing, and both
cleared on their own. Similarly, `test-2.log` showed `WorkboardDeskUpsertTests` `Executed 11 tests, with 2
failures` (`invalidMaterialOwner` at `:318` and `:384`) against a mid-edit store — that class is **14/0** in
the final `test-3.log`. Every number in §4 is from after those cleared.

---

## Guard verdicts

**`WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication` — rated `convert`.
CONVERTED.** Its subject (validate-before-publish, rollback, atomic publication) is now four behavioural
cases against an injected filesystem, and its `targetWorkItemID: nil` clause is now enforced by the
transaction itself. The test's own anchors no longer exist in either appex, so it fails on my tree; deleting
it is §Requests 1.

**One source guard deliberately KEPT — `testBothShareExtensionsPublishThroughThePublisherRatherThanByHand`.**
Its claim is not "these tokens appear in this order" but "this extension delegates to the tested transaction
and publishes nothing by hand", which is the only thing that ties the behavioural coverage to a target no
test bundle can link. It is scoped to the `writeWorkCaptureEnvelope` slice (the Send-now path keeps its own
rename), and it carries a negative assertion, so dead code containing `publisher.commit` alongside a live
hand-rolled rename fails it. Converting it further would need the appex compiled into a test target, which
the duplicate-type-name constraint forbids.

No other guard in my files was rated, and neither new test file contains a source-text drift guard beyond the
two above (the mirror-identity guard is the same shape the reviewer rated `keep` for `WorkCaptureEnvelope`).

## Catalog

**Keys I ADDED in source: NONE.** This slice is entirely headless — a filesystem transaction, a generation
factory, and tests. The appexes' user-facing failure mapping is unchanged (`ShareError.captureTooLarge` /
`.emptyCapture` still reach the same `WorkboardCommitFailure` cases and the same existing strings).

**Keys I made DEAD: NONE.** I deleted no code carrying a string.

**No `.xcstrings` file was opened.**

## Requests

1. **Integrator (BLOCKING for the gate) — delete `WorkCaptureInboxTests.testShareWritersValidateAndRollbackBeforeAtomicPublication`**
   (`Conduck/ConduckTests/WorkCaptureInboxTests.swift:297`). It is the guard the reviewer rated `convert`, it
   is superseded in full by `WorkCaptureSharePublisherTests`, and it fails on my tree
   (`WorkCaptureInboxTests.swift:308: XCTUnwrap failed: expected non-nil value of type "Range<Index>"` —
   `try envelope.validateForPublication()` no longer appears in either appex). **Do not "repair" it by
   re-pointing the substrings**: the invariant it guarded now lives in a tested transaction, and its
   `targetWorkItemID: nil` clause is carried by `testBothShareExtensionsPublishThroughThePublisherRatherThanByHand`
   plus the publisher's own refusal. Deleting it takes `WorkCaptureInboxTests` 30 → **29**.
2. **Nobody re-inline the publication.** `commit` is one transaction on purpose: refuse → validate → manifest
   → ONE rename, with the staged bytes removed on every refusal. Splitting it back into the appexes puts a
   copy of the person's private content on disk with no test able to see whether it is cleaned up, which is
   exactly what t#3 found. Three copies must move together — the byte-identity guard is
   `WorkCaptureSharePublisherTests.testThreeCrossProcessPublisherCopiesAreIdenticalBelowImport`.
3. **Nobody remove `WorkCaptureDirectoryPublisher.Failure.envelopeNamesADestination`.** It is what makes a
   targeted Work capture impossible rather than merely absent from today's appexes. If a future feature
   genuinely needs a destination again, that guard is the deliberate speed bump — and the envelope field is
   still there waiting.
4. **fix2-store / whoever owns `ConversationStore+Workboard.swift`: nothing owed.** I did not open it. My only
   app-side change is inside `WorkCaptureInbox.publishAppCapture`, whose signature, error types and
   idempotency contract are unchanged.
5. **fix2-drainer: nothing owed.** `claimNext(now:)`, `acknowledge`, `release`, `refreshLease(_:now:)`,
   `reconcile(now:)` and `ReconciliationReport` all kept their exact signatures and semantics.
   `refreshLease`'s `.staleClaim` is still raised only for a proven loss of ownership; I added no failure
   path to it. The new `makeGeneration` parameter is defaulted and internal to the inbox.
6. **Docs agent — two facts, if a doc describes the queue.** (a) Every inert Work capture — in-app quick
   capture, iOS share, macOS share — is published by the same transaction: bytes are staged in a private
   directory, and one rename makes the whole capture visible at once; a refusal at any step removes the
   staged copy rather than leaving it for a sweep. (b) No share can name a Work destination: the publisher
   refuses an envelope that does. `project-structure.md`'s folder map needs no change (the folder-map script
   passes) — but if it lists the mirrored files by name anywhere, `WorkCaptureDirectoryPublisher.swift` is now
   a third three-way mirror beside `WorkCaptureEnvelope.swift` and `ShareTargetsSnapshot.swift`.
7. **Orchestrator — suite arithmetic.** `WorkCaptureSharePublisherTests` **+7** ·
   `WorkCaptureInboxLeaseTests` 14 → 15 **+1** · `WorkCaptureInboxTests` 30 → **29** once §Requests 1 lands
   (**−1**). Net from this slice: **+7**. Full iOS, watch and (beyond `mac-1`/`mac-2`) any further macOS gate
   unrun by me.
8. **Founder QA (Gate 2) — one item.** Share a file from another app twice in quick succession using the same
   share sheet, and confirm the desk shows it once. Then share something the extension must refuse (an empty
   capture: no note, no attachment) and confirm the share sheet reports the failure and the desk gains
   nothing. The second half is the path that used to be guarded only by a source grep.

## Refuted

Empty — both findings held in full.

## Call-site touches

**NONE outside my ownership.** `workCaptureTmpDir(for:)` in each appex now delegates to the publisher and
kept its signature, so `commitToWork`'s error-path cleanup needed no edit. `publishAppCapture` kept its two
signatures, its return type and its error types, so no intent, coordinator or drainer call site was opened.
