# fix2-vault — r2#4 + r2#7 CONFIRMED and fixed; adjudications (b) and (d) implemented. Contract C4 landed.

Parallel phase. No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened** (`git status --short -- '*.xcstrings'` is
empty). No mirror triplet touched. No pbxproj edit (no new files).

Files edited — exactly the two I own:
- `Conduck/Conduck/Services/Workboard/WorkAssetVault.swift` (+~120 / −~50)
- `Conduck/ConduckTests/WorkAssetVaultTests.swift` (15 → 19 cases)

**HEADLINE: green on the SHARED worktree.** iOS `** TEST BUILD SUCCEEDED **` (0 `error:`), the VERIFY
set `** TEST EXECUTE SUCCEEDED **` — `WorkAssetVaultTests` **19 executed / 0 failures** (was 15),
`WorkboardAvailabilityTests` 9/0, `WorkCaptureDrainerTests` 9/0 — and the **full iOS suite
`Executed 4849 tests, with 1 test skipped and 2 failures`**, where **both failures are
`WorkboardAudioCaptureTests`, fix2-recorder's in-flight file, and every storage-adjacent class passes**
(§6). Getting there took seven `build-for-testing` attempts: the first six failed only in files I do
not own (`WorkboardAudioCardView.swift`, then `InAppAudioRecorder.swift` / `ContentView.swift` /
`MenuBar/DictationService.swift`, then `WorkboardAudioCaptureTests.swift`), so I also verified my two
files in an isolated copy under my slug dir — that fallback run is kept in §6 as corroboration, but
the numbers that count are the shared-tree ones.

---

## 1. r2#4 — "a stat-able path is treated as readable payload". CONFIRMED, fixed.

**Verified against the current code before changing anything**, by tracing the call path rather than
the line numbers: `confirmPublication` proved a leaf with `attributesOfItem` only; `contains(_:)` and
`urls(for:)` both asked `fileManager.fileExists(atPath:)`. Every one of those succeeds on a regular
file that `open(2)` refuses — a mode-000 leaf, or one whose data protection this process cannot reach.
The consequence the finding names is real on the current tree: `urls(for:)` feeds
`availableLocalKeys` in `ConversationStore+Workboard.swift`'s batch projection, so such a card reads
`availableLocally`, and `confirmPublication` — now the store's durability gate at three sites (see
fix-verify §2) — returned **true** for it, which is what lets the drainer barrier acknowledge and drop
the queue's only other copy.

### The fix: one predicate, `readableByteCount(at:)`, and every serve decision asks it

`private func readableByteCount(at url: URL) -> Int64?` — a REGULAR file (`.isRegularFileKey`) that
opens through `FileHandle(forReadingFrom:)`; the handle is closed immediately without reading, so
proving a 250 MB leaf costs a file descriptor, not its bytes. It returns the leaf's measured length,
and **zero is a legitimate length** — a readable empty file is payload.

Adopted by, in the same meaning everywhere:

| Symbol | Change |
|---|---|
| `readableKeys(among keys: Set<String>) -> Set<String>` | NEW, the contract-C4 batch predicate |
| `contains(_:)` | `!readableKeys(among: [key]).isEmpty` — one key is the batch predicate with one member, deliberately, so a single card and a whole board cannot disagree about "available" |
| `urls(for:)` | `fileExists` → `readableByteCount(at:) != nil` |
| `url(for:)` | same. It is the single-key twin of `urls(for:)` and its result is handed to a payload reader (`loadWorkMaterialPayloadURL`); leaving it on `fileExists` would have re-opened the finding through one door |
| `confirmPublication(of:expectedByteCount:)` | present-but-unreadable now returns **false and KEEPS the guard** |

**`confirmPublication`'s three outcomes, stated exactly** (signature unchanged, per C4):
- leaf absent → releases the guard (nothing left to protect), returns false;
- leaf present but not readable, or readable and the wrong length → **keeps** the guard, returns false;
- readable and (when a size is given, `>= 0`) matching → releases the guard, returns true.

**Deliberately NOT adopted by reclamation.** `reclaimUnreferenced` still judges candidates by
existence. A leaf this process cannot open may be one another process can, and deleting it would
convert "unavailable here" into data loss. Stated at the declaration and in the file header so nobody
"tidies" the two predicates into one.

`data(for:)` and `snapshotFile(for:)` keep `fileExists` + the real read: reading IS the proof there,
and the read's own error is the honest one. Deviation from a strict "every path" reading, said plainly.

## 2. r2#7 — "an abandoned marker beside a permanently referenced leaf is never reconsidered". CONFIRMED, fixed.

Verified: the second loop of `reclaimUnreferenced` read
`guard leaves[key] == nil, !protectedKeys.contains(key) else { continue }`, and `protectedKeys =
keys.union(stagedKeys)`. A referenced leaf is present AND protected, so its marker failed **both**
conditions and could never be swept, however long its claim had been dead.

Fixed by making the marker's fate depend on the marker alone:

```swift
for (key, marker) in markers {
    guard !stagedKeys.contains(key) else { continue }
    guard isAbandonedStagingClaim(at: marker, now: now) else { continue }
    try? fileManager.removeItem(at: marker)
}
```

`stagedKeys` rather than `protectedKeys` is the guard, because only this process's live claims say
anything about who is mid-publication — the database key set does not. Removing a marker never touches
the payload beside it, and the returned count still counts payload leaves only, which is what keeps
every `XCTAssertEqual(reclaimed, 0/1)` in the five other classes meaningful.

Every existing guarantee is intact: markers still go down BEFORE the bytes, the 15-minute
`stagingHorizon` still protects a young leaf with no marker, an undecodable claim is still aged by its
file's mtime, and a future-dated claim is still respected.

## 3. Adjudication (b) — measured bytes from every write path. Done (contract C4).

`WorkAssetVault.StoredFile` is replaced by top-level **`WorkAssetVaultWrite { key, byteCount }`** —
the contract's name, at file scope so it does not stutter. `byteCount` is the length measured FROM DISK
after the bytes land, through the same `readableByteCount` predicate, so a write that cannot be
reopened and measured fails (`VaultError.writeFailed`, destination removed, guard released) instead of
handing back a key a row would promise bytes for.

**Exact signatures for fix2-store:**

```swift
struct WorkAssetVaultWrite: Sendable, Equatable { let key: String; let byteCount: Int64 }

func store(bytes data: Data, id: UUID = UUID(), suggestedExtension: String? = nil) throws -> WorkAssetVaultWrite
func storeFile(at sourceURL: URL, id: UUID = UUID(), suggestedExtension: String? = nil) throws -> WorkAssetVaultWrite
func storeFileStreaming(at: URL, id: UUID = UUID(), suggestedExtension: String? = nil,
                        expectedByteCount: Int64,
                        onProgress: @escaping @Sendable (Double) -> Void) async throws -> WorkAssetVaultWrite
func copy(key: String, id: UUID = UUID()) throws -> WorkAssetVaultWrite
func readableKeys(among keys: Set<String>) -> Set<String>
@discardableResult func confirmPublication(of key: String, expectedByteCount: Int64? = nil) -> Bool

// key-only form, to be deleted once the store adopts `store(bytes:)` — see Requests 1
func store(_ data: Data, id: UUID = UUID(), suggestedExtension: String? = nil) throws -> String
```

`storeFileStreaming` additionally requires `measured == copied` before reporting the copy complete, and
`onProgress(1)` now fires only after that check, so progress never reaches 1 for a copy that failed.
`copy(key:)` no longer falls back to `?? 0` — an unmeasurable duplicate is a failed write, not a
zero-length card.

### Deviation, stated plainly: the key-only `store(_:)` survives this wave

C4 says the store adopts the measured API in the serial wave, which would mean landing a
signature break on `ConversationStore+Workboard.swift:947` and `:1311` **and** on
`ConduckTests/WorkboardLiveRepositorySupportTests.swift:22-23` — four call sites in two files I do not
own, in a phase where six other agents need the tree to compile. Deliberately breaking their builds is
worse than one transitional method, so `store(_:)` stays as a one-line delegation to `store(bytes:)`
whose doc comment states the constraint: **a caller that records or confirms a byte size must take
`store(bytes:)`**. It has no other behaviour of its own. Requests 1 says exactly how to delete it.

All of my own tests were migrated onto `store(bytes:)`, so the key-only form's caller set is now
exactly those four sites.

## 4. Adjudication (d) — `markReferenced` RETIRED. Done.

`markReferenced(_:)` is **deleted**. It had no production caller (fix-verify §2.5 recorded that its
last three were moved to `confirmPublication`), and it released both guards without proving anything —
exactly the primitive whose survival makes the original durability defect easy to reintroduce. Its
seven call sites, all in `WorkAssetVaultTests`, moved onto `confirmPublication(of:)`, which releases
the guard on the same success and is `@discardableResult` so the call sites read the same. In
`testALeafStagedByAnotherProcessIsNeverReclaimed` the release is now also **asserted**
(`XCTAssertTrue(confirmed)`), which the old primitive could not express. `confirmPublication` is now
the ONLY way a guard is released after a write; that is stated at its declaration.

## 5. Regression tests — 4 new (15 → 19), and how each one proves its finding

| Case | Proves | Why it fails on the old code |
|---|---|---|
| `testAnUnreadableLeafIsNeitherServedNorConfirmable` | a `chmod 000` regular leaf is not `contains`, absent from `urls(for:)` and `readableKeys`, and **fails `confirmPublication`**; it is still on disk after a horizon-passing reclaim; restoring `0o644` makes both true again | measured counterfactual by construction: `attributesOfItem` succeeds on a mode-000 file, so old `confirmPublication` returned **true** and released the guard — with the leaf aged past `pastTheHorizon`, the following `reclaimUnreferenced` would then have returned 1 and deleted it. The new run asserts `false` / `0` / still-on-disk |
| `testAReadableEmptyLeafIsValidPayload` | a readable zero-byte leaf is contained, resolves, is in `readableKeys`, confirms against `expectedByteCount: 0`, and reads back as `Data()` | guards the over-fix: a readability check written as "has bytes" would fail every assertion here |
| `testAnAbandonedClaimBesideAReferencedLeafIsSweptWithoutItsPayload` | a stale claim (a legible `StagingClaim` naming another owner, `stagedAt` two horizons back) beside a leaf passed in `keeping:` is removed, `reclaimed == 0`, and the payload still reads back byte-for-byte | argument from the assertion + the old body: the old marker loop required `leaves[key] == nil`, and the leaf exists, so it `continue`d and the marker survived — `XCTAssertFalse(markerSurvives)` is exactly that branch |
| `testEveryWritePathReportsTheLengthItsLeafActuallyHolds` | `store(bytes:)`, `storeFile(at:)`, `storeFileStreaming`, `copy(key:)` each return a `byteCount` equal to the leaf's on-disk `.size` and to the payload length, and each confirms against its own returned value | contract test, not a counterfactual, and said so: two of those four returned no length at all before, so the case could not compile against the old API |

**One fixture correction worth recording**, because it is a trap for the next agent: backdating a
marker FILE does not age its claim — `isAbandonedStagingClaim` decodes the JSON first and only falls
back to the file's mtime when the bytes will not decode. My first run failed on exactly that
(`iso-test-1.log`, `Executed 19 tests, with 1 failure`). The fixture now writes a real
`WorkAssetVault.StagingClaim` with a stale `stagedAt` (helper `writeStaleClaim(at:)`), which is also the
more faithful shape of a process that died mid-publication.

No existing assertion was weakened, narrowed or deleted. The three fixtures fix-vault had aged stay
aged; the only edits to existing cases are `markReferenced` → `confirmPublication` and
`store(_:)` → `store(bytes:).key`.

## 6. Gates — WHAT I ACTUALLY RAN

Slug `fix2-vault`. Everything under `~/Library/Caches/gigaduck-builds/fix2-vault/`
(`DerivedData`, `DerivedDataIsolated`, `tree`, and every log), each log grepped for `': error: '` and
the verdict strings — never judged from tail or exit code. No `-configuration` passed anywhere. Sim
`E953B6D8-44F3-4595-9C24-29F3991C13FE`.

### Shared worktree — the runs that count

- **iOS `build-for-testing`** → `bft-7.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
- **VERIFY set**, `test-without-building`, one quoted `-only-testing` per class → `test-1.log`,
  `** TEST EXECUTE SUCCEEDED **`, `grep -c ': error: '` = 0:
```
Test Suite 'WorkAssetVaultTests' passed
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.288 (0.295) seconds
Test Suite 'WorkCaptureDrainerTests' passed
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.371 (0.374) seconds
Test Suite 'WorkboardAvailabilityTests' passed
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.119 (0.121) seconds
Test Suite 'Selected tests' passed
	 Executed 37 tests, with 0 failures (0 unexpected) in 0.778 (0.791) seconds
```
- **FULL iOS suite** → `ios-full-1.log`, `** TEST EXECUTE FAILED **`,
  `Executed 4849 tests, with 1 test skipped and 2 failures (0 unexpected) in 95.591 (109.861) seconds`.
  **Exactly one suite fails and it is not mine** — `WorkboardAudioCaptureTests`, fix2-recorder's
  in-flight file:
```
WorkboardAudioCaptureTests.swift:574: error: -[…testAPublicationFailureIsARetryableErrorRatherThanATextFallback] : failed - a capture with no card must not report success
WorkboardAudioCaptureTests.swift:614: error: -[…testAnAttachFailureHoldsTheWordsAndTheRetryFinishesTheSameCard] : failed - a card that never got its words must not report success
```
  The single skip is the environment-conditional
  `GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract` (no sibling website
  checkout), which fix-verify §4 already recorded as 1-not-2.
  **Every storage-adjacent class passes in that same run** — this is the measurement that matters for a
  stricter `contains` / `urls(for:)` / `url(for:)`, since a spurious refusal anywhere would surface as a
  card gone unavailable:
```
WorkAssetVaultTests                     Executed 19 tests, with 0 failures
WorkboardAvailabilityTests              Executed  9 tests, with 0 failures
WorkCaptureDrainerTests                 Executed  9 tests, with 0 failures
WorkCaptureDrainerDurabilityTests       Executed  8 tests, with 0 failures
WorkCaptureInboxTests                   Executed 30 tests, with 0 failures
WorkCaptureInboxLeaseTests              Executed 14 tests, with 0 failures
WorkboardBlobPublicationTests           Executed 15 tests, with 0 failures
WorkboardBlobGCTests                    Executed  6 tests, with 0 failures
WorkboardBlobSeamPlatformGuardTests     Executed  1 test,  with 0 failures
WorkboardDeskUpsertTests                Executed 11 tests, with 0 failures
WorkboardPersistenceTests               Executed  7 tests, with 0 failures
WorkboardTwoStoreLoadTests              Executed  7 tests, with 0 failures
WorkboardLiveRepositorySupportTests     Executed  5 tests, with 0 failures
WorkboardMaterialBoardActionsTests      Executed 12 tests, with 0 failures
ConversationStoreAtomicWorkCaptureTests Executed  3 tests, with 0 failures
ConversationStoreWorkCaptureTests       Executed  5 tests, with 0 failures
```

### The six earlier `build-for-testing` attempts, all failing OUTSIDE my files

| Log | Result | `grep -c ': error: '` | The errors |
|---|---|---|---|
| `bft-1.log` | `** TEST BUILD FAILED **` | 3 | `Views/Workboard/WorkboardAudioCardView.swift:215,216,217: error: call to main actor-isolated static method 'systemCaptureIsLive()' / 'activateSharedSession()' / 'releaseSharedSession()' in a synchronous nonisolated context` |
| `bft-2.log` (after ≥120 s) | `** TEST BUILD FAILED **` | 1 | `Services/InAppAudioRecorder.swift:533:20: error: binary operator '??' cannot be applied to operands of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome?' and 'Bool'` |
| `bft-3.log` | `** TEST BUILD FAILED **` | 1 | same line, unchanged |
| `bft-4.log` | `** TEST BUILD FAILED **` | 1 | same line, unchanged |
| `bft-5.log` | `** TEST BUILD FAILED **` | 6 | **app target now compiles**; all six in `ConduckTests/WorkboardAudioCaptureTests.swift:124,168,185,206,243,268: error: cannot convert value of type 'WorkVoiceCaptureCoordinator.WorkVoiceAttachOutcome' to expected argument type 'Bool'` |
| `bft-6.log` | `** TEST BUILD FAILED **` | 4 | `ConduckTests/WorkboardAudioCaptureTests.swift:129,171,187,495: error: 'async' call in an autoclosure that does not support concurrency` |
| `bft-7.log` | **`** TEST BUILD SUCCEEDED **`** | **0** | the recorder slice landed; everything above is the tree converging, not my code |

**Zero `error:` or `warning:` lines in any of the six mention either of my files.** `bft-5`/`bft-6`
matter most: the app target compiled clean with my API in it, which is the proof that
`ConversationStore+Workboard.swift` still builds unchanged against `WorkAssetVaultWrite` — the two
`storedFile.key` / `.byteCount` uses keep their property names, so C4's "the store adopts these in the
serial wave" costs the store nothing until it wants the measured size.

### Isolated copy — the fallback run, kept as corroboration

`~/Library/Caches/gigaduck-builds/fix2-vault/tree`, an `rsync` snapshot of the worktree taken after
`bft-5`, with **the foreign in-flight file patched IN THE COPY ONLY** so my code could be exercised:
`ConduckTests/WorkboardAudioCaptureTests.swift`, six assertions mechanically converted
`XCTAssert{True,False}(attached)` → `XCTAssert{Equal,NotEqual}(attached, .attached)`. Nothing else was
patched; my two files are byte-identical to the worktree's.

- `iso-bft-4.log` → `** TEST BUILD SUCCEEDED **`, `grep -c ': error: '` = **0**.
- `iso-test-2.log`, the VERIFY set, `test-without-building`, one quoted `-only-testing` per class →
  `** TEST EXECUTE SUCCEEDED **`, `grep -c ': error: '` = 0:
```
Test Suite 'WorkAssetVaultTests' passed
	 Executed 19 tests, with 0 failures (0 unexpected) in 0.107 (0.112) seconds
Test Suite 'WorkCaptureDrainerTests' passed
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.335 (0.337) seconds
Test Suite 'WorkboardAvailabilityTests' passed
	 Executed 9 tests, with 0 failures (0 unexpected) in 0.160 (0.162) seconds
Test Suite 'Selected tests' passed
	 Executed 37 tests, with 0 failures (0 unexpected) in 0.601 (0.611) seconds
```
- `iso-full-1.log`, **FULL iOS suite** → `** TEST EXECUTE FAILED **`,
  `Executed 4832 tests, with 11 tests skipped and 8 failures (0 unexpected) in 71.825 (74.695) seconds`.
  **Exactly two suites fail, neither mine, both fix2-recorder's in-flight work:**
  `WorkboardAudioCaptureTests` (6, of which the one at `:206` is an artifact of MY throwaway patch —
  an empty transcript legitimately answers `.attached`) and `STTKeyBlackoutLaneTests` (1, a source
  drift guard over `InAppAudioRecorder.swift`). Every storage-adjacent class passes in that same run:
```
WorkAssetVaultTests            Executed 19 tests, with 0 failures
WorkboardAvailabilityTests     Executed  9 tests, with 0 failures
WorkCaptureDrainerTests        Executed  9 tests, with 0 failures
WorkCaptureDrainerDurabilityTests Executed 8 tests, with 0 failures
WorkCaptureInboxTests          Executed 30 tests, with 0 failures
WorkCaptureInboxLeaseTests     Executed 14 tests, with 0 failures
WorkboardBlobPublicationTests  Executed 15 tests, with 0 failures
WorkboardBlobGCTests           Executed  6 tests, with 0 failures
WorkboardDeskUpsertTests       Executed 11 tests, with 0 failures
WorkboardPersistenceTests      Executed  7 tests, with 0 failures
WorkboardTwoStoreLoadTests     Executed  7 tests, with 0 failures
WorkboardLiveRepositorySupportTests Executed 5 tests, with 0 failures
WorkboardMaterialBoardActionsTests Executed 12 tests, with 0 failures
ConversationStoreAtomicWorkCaptureTests Executed 3 tests, with 0 failures
ConversationStoreWorkCaptureTests Executed 5 tests, with 0 failures
```
  That is the measurement that matters for a change to `contains` / `urls(for:)` / `url(for:)`: the
  stricter predicate did not turn any existing card unavailable anywhere in the suite.

### Hygiene, on the SHARED worktree

- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 778 Swift files scanned…`, exit 0.
- `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories…`, exit 0.
- `git diff --check` → clean, exit 0. `git status --short -- '*.xcstrings'` → empty.
- Build cache + isolated tree removed at end of task:
  `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh fix2-vault`. **The logs go
  with them** — re-run if the integrator needs them.

### What I did NOT verify, plainly

- **macOS build and the watch suite.** Outside my VERIFY, and no watch sim was assigned.
  `WorkAssetVault.swift` is wholly inside `#if !os(watchOS)` and I added no platform-conditional code
  beyond the file's existing `#if os(iOS)` protection blocks, but I did not prove either build myself.
- **`expectedByteCount` still has no production caller.** That is fix2-store's adoption (Requests 1);
  the vault side is now able to supply the number, which is the half C4 assigned to me.

## Guard verdicts

**None assigned.** My brief names no `t#N` item, and `codex-tests-findings.json` contains no finding or
drift-guard verdict for `WorkAssetVaultTests` or `WorkAssetVault.swift`. I converted, deleted and kept
nothing on that basis.

## Catalog

**Keys I ADDED in source: NONE.** This slice is headless — no user-facing copy, no `.xcstrings` opened.

**Keys I made DEAD: NONE.** I deleted no code that carried a string (`markReferenced` had none).

## Requests

1. **fix2-store (`ConversationStore+Workboard.swift`) — adopt the measured write, then delete the
   key-only form.** Two call sites:
   - `stageWorkMaterialBytes` (`:947`): `let vaultKey = try await workAssetVault.store(payload, …)`
     → `let write = try await workAssetVault.store(bytes: payload, …)`, then return
     `byteSize: write.byteCount` **instead of `declaredByteSize ?? measured`** and
     `vaultKey: write.key`. That is adjudication (b)'s actual defect: the persisted size is currently
     the caller's claim, which is why `confirmPublication(expectedByteCount:)` cannot be wired.
   - `addWorkMaterial` (`:1311`): `newVaultKey = try await workAssetVault.store(payload, …)` →
     `store(bytes:)`, and let the measured `byteCount` replace `draft.byteSize ?? payload.count` on
     the `.localVault` branch (the `.syncedPayload` branch already measures).
   Then pass that value at the three `confirmPublication(of:)` sites
   (`publishWorkMaterial`, `insertWorkMaterial`, `replaceWorkMaterialPayloadFile`) —
   `expectedByteCount:` is what closes fix-verify §8.2's truncation half.
   Finally **delete `func store(_ data: Data, …) -> String`** from the vault and update the two
   remaining callers in `ConduckTests/WorkboardLiveRepositorySupportTests.swift:22-23` to
   `store(bytes: …).key`. Nothing else calls it.
2. **fix2-store — `readableKeys(among:)` is the batch availability probe C4 promised.**
   `urls(for:)` already carries the same predicate, so the existing `availableLocalKeys` line needs no
   change; take `readableKeys` when you want the key set without the URLs, and never re-introduce a
   per-material `await vault.contains` loop (`WorkboardAvailabilityTests`'
   `testAvailabilityIsResolvedOncePerFetchRatherThanOncePerCard` is the guard).
3. **Nobody make reclamation ask for readability.** `reclaimUnreferenced` must keep judging by
   existence. Unreadable-here is not deletable — another process may open the same leaf, and the two
   predicates being different is the point, not an oversight. Equally, do not re-narrow the marker
   sweep back to `leaves[key] == nil` (that is r2#7) and do not widen its guard from `stagedKeys` back
   to `protectedKeys`.
4. **Serial integrator — the VERIFY command for this slice** is
   `-only-testing:ConduckTests/WorkAssetVaultTests` (**19 cases now, was 15; the iOS baseline gains
   +4**) plus `WorkboardAvailabilityTests` (9) and `WorkCaptureDrainerTests` (9). Measured green on the
   shared tree (§6). Shared-tree iOS baseline with my slice in it: **4849 executed, 1 skipped**.
5. **Whoever owns `WorkboardAudioCaptureTests.swift`**: its two full-suite failures
   (`:574` `testAPublicationFailureIsARetryableErrorRatherThanATextFallback`, `:614`
   `testAnAttachFailureHoldsTheWordsAndTheRetryFinishesTheSameCard`) were on the tree when I measured
   it and are not mine. Recorded so the gate is not surprised.
6. **`markReferenced` is gone** — if any slice still calls it, the call must become
   `confirmPublication(of:)` and its `false` must be treated as a failed publication, not ignored.

## Refuted

**Nothing.** Both findings and both adjudications held against the current code.
