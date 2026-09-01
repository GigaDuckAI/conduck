# fix-verify — the fix wave coheres. Full iOS suite `Executed 4810 tests, with 1 test skipped and 0 failures`.

No commits/pushes/stash/checkout. `Identity-Override.xcconfig` untouched. Nothing under
`docs/qa/desk-cloudkit/` touched. **No `.xcstrings` opened.** No mirror triplet touched. Nothing on
the audio/strings workflow's off-limits list opened for editing.

Files I changed, exactly two — both fix-owned:
- `Conduck/Conduck/Services/ConversationStore+Workboard.swift` (+25 / −5, three call sites)
- `Conduck/ConduckTests/WorkCaptureDrainerTests.swift` (one case rewritten; still 9 cases)

**HEADLINE FOR THE ORCHESTRATOR.** After resolving the two blocking cross-agent Requests the tree is
green on every gate I ran: iOS `** TEST BUILD SUCCEEDED **` (0 `error:`), the 14-class VERIFY set
`Executed 143 tests, with 0 failures`, the **FULL iOS suite `Executed 4810 tests, with 1 test skipped
and 0 failures (0 unexpected)`**, signed macOS `** BUILD SUCCEEDED **` (no `CODE_SIGNING_ALLOWED=NO`
fallback), `check-storage-seam.sh` / `check-folder-map.sh` / `git diff --check` all exit 0. **Every
failure the five fix agents recorded as "in flight, not mine" has cleared.** Watch suite not run
(§5).

---

## 1. Cross-agent Requests — what I resolved, and what I passed through

| Request | Status |
|---|---|
| **fix-vault #1** — store must call `confirmPublication` instead of `markReferenced` at three sites | **RESOLVED** (§2) |
| **fix-store #1** (BLOCKING) — `WorkCaptureDrainerTests.testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload` broken by design by fix-store's finding #2 | **RESOLVED** (§3) |
| **fix-seams #1** — run `WorkboardBlobSeamPlatformGuardTests` once the tree compiles | **RESOLVED** — `Executed 2 tests, with 0 failures` (§4) |
| **fix-seams #2 / fix-inbox #2** — `WorkboardMaterialKind.audio` missing, `WorkboardCaptureCanvas.swift:1170,:1632` not compiling | **RESOLVED by the audio workflow.** The tree compiles; 0 `error:` in both my builds |
| **fix-vault #5** — `WorkCaptureDrainerDurabilityTests` (2 failures) + `WorkboardLiveRepositorySupportTests` (3 failures) seen mid-wave | **RESOLVED** — all five pass now (full suite 0 failures) |
| **fix-store #5** — `WorkboardLiveRepository.swift:535-537` carries a half-false reattach comment | **NO LONGER HOLDS** — see §6 Refuted, the comment has already been rewritten to the correct truth |
| **fix-vault #2** — the drainer barrier inherits the vault check once #1 lands | **SATISFIED BY CONSTRUCTION**, no code needed (§2.3) |
| fix-vault #3/#4, fix-store #3/#4, fix-drainer #2/#3/#4, fix-seams #3/#4, fix-inbox #1 | **Standing constraints, nothing owed.** I violated none of them; all are restated in §7 for the integrator |
| **fix-store #2** — the residual publish/adopt/rollback interleaving | **PASSED THROUGH to Codex round 2** (§8.1) |
| fix-store #6, fix-drainer #5 | **PASSED THROUGH to the docs agent** (§8.4) |
| fix-drainer #6 | **PASSED THROUGH to the founder QA script** (§8.5) |

## 2. The vault↔store durable-verification hook (fix-vault #1)

`confirmPublication(of:expectedByteCount:) -> Bool` existed on `WorkAssetVault` with **zero
production callers**; the store still released the staging guard blind through `markReferenced`. So
the half of fix-vault's finding that proves a publication was never wired. Three sites in
`ConversationStore+Workboard.swift`, each `markReferenced(key)` → `confirmPublication(of: key)`, with
a `false` treated as a failed publication:

| Site | Symbol | Shape |
|---|---|---|
| 1 | `publishWorkMaterial` post-transaction block (the desk upsert) | `publicationIsDurable = await workAssetVault.confirmPublication(of: key)` in the keep-the-key arm; the `else` arm's `remove(key)` is untouched |
| 2 | `insertWorkMaterial` (`addWorkMaterial` / `addWorkMaterialFile`) | same, in the `inserted` arm |
| 3 | `replaceWorkMaterialPayloadFile` (reattach) | same, on `newKey` |

At each site the failure is raised as **`WorkboardStoreError.materialPayloadUnavailable`** — a
pre-existing case with `errorDescription == nil`, so no new user-facing copy and no catalog work.

### 2.1 Three deliberate ordering decisions

- **`postDidChange()` still fires before the throw** at sites 1 and 3. The row committed; the card is
  genuinely on the desk (reading `.unavailableOnThisDevice`), and suppressing the change
  notification would leave the board lying about its own contents while the error propagates.
- **The reattach still removes its old vault keys on a refused confirm.** The rows already point at
  the new leaf and the lane they left was cleared in that same save, so the old keys are named by
  nothing; keeping them would be orphan residue reclaimed later anyway. What the refusal changes is
  only that the reattach is *reported* failed.
- **`insertWorkMaterial` throws before its `fetchWorkMaterial` return**, so a caller never receives a
  `WorkMaterialRecord` for a publication that did not verify.

### 2.2 `expectedByteCount: nil` at all three sites — stated plainly, with the reason

fix-vault's Request explicitly sanctions this ("pass `expectedByteCount: nil` wherever the measured
size is not to hand — the readability check still runs"), and here it is not merely unavailable, it
would be **wrong**: `stageWorkMaterialBytes`' in-memory `.localVault` return is
`byteSize: declaredByteSize ?? measured`, and `addWorkMaterial`'s is
`draft.byteSize ?? payload.count`. Both can carry a CALLER'S CLAIM rather than the leaf's true
length, so passing them as `expectedByteCount` would turn a caller's wrong `byteSize` into a spurious
capture failure. Only the `storeFileStreaming` lanes are provably vault-measured, and they share
`insertWorkMaterial` with the declared-size lane.

**Consequence, said honestly: `expectedByteCount` still has no production caller.** The readability
half of the check is wired; the truncation half is not. Closing it properly means making the
`.localVault` `byteSize` the bytes actually written rather than the caller's claim — a semantic
change to a persisted column, outside "resolve the Requests minimally". **Open item for Codex round 2
(§8.2).**

### 2.3 Why this does not double up with fix-drainer's barrier

The drainer's `confirmDurablyImported` reads the desk once and consumes `hasPayload`, which for
`.localVault` already requires a present leaf. The store-side confirm is the check for **every other
surface** — first in-app capture, Chat→Work, `CaptureWorkboardIntent`, reattach — none of which passes
through the drainer. It adds no per-material `await` loop (one `confirmPublication` per capture, for
the single leaf that capture wrote), so plan §C's prohibition and fix-drainer's Request 3 both hold.

### 2.4 A refused publication is replay-repairable — I checked, it is not a dead end

`publishWorkMaterial`'s repair branch sets `repairLane = .localVault` when the existing row is
`.localVault` and `availability == .unavailableOnThisDevice`. That is exactly the state a refused
confirm leaves behind, so the redelivered capture restages the leaf and the card recovers. A card
stranded by this throw is repaired by the next replay, never permanently broken.

### 2.5 `markReferenced` is now test-only

It keeps its signature and meaning (release the guard without proving anything) and is still the
primitive seven `WorkAssetVaultTests` cases drive, but **no production path calls it any more**. I did
not delete it: it is fix-vault's file, and removing it would break that suite. Flagged in §8.3.

## 3. The drainer test (fix-store #1)

`testAPersistenceFailureReleasesTheClaimAndPreservesItsPayload` used `invalidMaterialOwner` — via an
`otherOwner` item plus a `collidingID` entry — purely as a way to force a mid-import failure through
the public API. fix-store's finding #2 makes the desk capture ADOPT a legacy-owned id instead of
refusing it, so the import now succeeds and the case failed 4× in fix-store's full run.

I applied fix-store's verified drop-in mechanism, unmodified:

- the `otherOwner` / `collidingID` fixture is replaced by a **second `.file` entry**
  (`payload-001.bin`, sequence 1, honest `byteCount`);
- its leaf is `chmod 000` after `publish(...)` and before `drainAvailableCaptures()`, restored to
  `0o644` in a `defer`;
- the `XCTAssertEqual(error as? WorkboardStoreError, .invalidMaterialOwner)` line is gone, with a
  comment saying why (which error the store raised is not the subject).

Why it works and why it is not vacuous: `WorkCaptureInbox`'s validator only STATS a leaf
(`attributesOfItem`), so a mode-0 regular file passes validation; the STORE is what reads the bytes,
and a 27-byte `.file` entry takes the `.syncedPayload` lane whose `Data(contentsOf:)` fails EACCES —
a mid-import failure with **no store seam and nothing a replay could mistake for a legitimate card**.

**Every other assertion is byte-for-byte the original**, and together they prove the failure really
was mid-import: `XCTFail` if the drain succeeds · `pendingCount == 1` · `desk.materials.map(\.id) ==
[imageID]` (the first card landed, the second did not — had validation rejected the envelope,
`unwrapDesk` would have thrown) · the queue's `payload-000.png` bytes byte-identical. **The case's
subject — a failed import releases the claim instead of consuming it, and the queue keeps the only
copy — is unchanged, and no assertion anywhere in the wave was weakened, narrowed or deleted by me.**

## 4. Gates — WHAT I ACTUALLY RAN

Slug `fix-verify`. DerivedData under `~/Library/Caches/gigaduck-builds/fix-verify/{DerivedData,DerivedDataMac}`,
every log written there and grepped for `: error: ` and the verdict strings, never judged from tail
or exit code. No `-configuration` passed anywhere. Sim `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF`.

- **iOS `build-for-testing`** → `bft-1.log`: `grep -c ': error: '` = **0**, `** TEST BUILD SUCCEEDED **`.
  **First attempt, no retry needed** — the other workflow's surface compiled cleanly.
- **VERIFY set, all 14 classes** (`test-1.log`, `** TEST EXECUTE SUCCEEDED **`, 143 tests total):

| Class | Result |
|---|---|
| `WorkAssetVaultTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.070 (0.074) seconds` |
| `WorkCaptureDrainerDurabilityTests` | `Executed 5 tests, with 0 failures (0 unexpected) in 0.135 (0.136) seconds` |
| `WorkCaptureDrainerTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.334 (0.336) seconds` |
| `WorkCaptureInboxLeaseTests` | `Executed 14 tests, with 0 failures (0 unexpected) in 0.053 (0.056) seconds` |
| `WorkCaptureInboxTests` | `Executed 30 tests, with 0 failures (0 unexpected) in 0.141 (0.146) seconds` |
| `WorkboardAvailabilityTests` | `Executed 9 tests, with 0 failures (0 unexpected) in 0.056 (0.058) seconds` |
| `WorkboardBlobGCTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.067 (0.068) seconds` |
| `WorkboardBlobPublicationTests` | `Executed 15 tests, with 0 failures (0 unexpected) in 0.134 (0.137) seconds` |
| `WorkboardBlobSeamPlatformGuardTests` | `Executed 2 tests, with 0 failures (0 unexpected) in 0.023 (0.023) seconds` |
| `WorkboardChatCaptureTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.055 (0.056) seconds` |
| `WorkboardDeskUpsertTests` | `Executed 11 tests, with 0 failures (0 unexpected) in 0.090 (0.092) seconds` |
| `WorkboardModelMigrationTests` | `Executed 6 tests, with 0 failures (0 unexpected) in 0.205 (0.206) seconds` |
| `WorkboardPersistenceTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.039 (0.040) seconds` |
| `WorkboardTwoStoreLoadTests` | `Executed 7 tests, with 0 failures (0 unexpected) in 0.244 (0.246) seconds` |

- **FULL iOS suite** (`ios-full-1.log`, `** TEST EXECUTE SUCCEEDED **`):
```
Test Suite 'All tests' passed at 2026-09-02 02:29:58.660.
	 Executed 4810 tests, with 1 test skipped and 0 failures (0 unexpected) in 66.074 (67.539) seconds
```
- **macOS build** `-destination 'platform=macOS'` → `mac-1.log`: 0 `error:`, `** BUILD SUCCEEDED **`.
  **Signed through the identity override; no `CODE_SIGNING_ALLOWED=NO` fallback needed.**
- `bash scripts/check-storage-seam.sh` → `✓ storage seam intact — 777 Swift files scanned…`, exit 0.
- `bash scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source directories, all mapped…`, exit 0.
- `git diff --check` → clean, exit 0.
- **Build caches removed at end of task**: `.claude/scripts/clean-build-cache.sh fix-verify` →
  `removed: fix-verify`. **The logs are gone with them**; re-run if you need them.

### The `: error: ` lines in `test-1.log` are runtime log noise, not failures

`test-1.log` contains two `CoreData: error: Failed to clone external data reference … .interim
doesn't exist` lines from `WorkboardModelMigrationTests`' external-storage round trip. The suite line
is `Executed 6 tests, with 0 failures`, the run verdict is `** TEST EXECUTE SUCCEEDED **`, and the
full-suite run reproduces them with 0 failures. Recording them so the gate is not surprised: they are
Core Data chatter during a store teardown, not a compile error and not an assertion.

### The skip count: 1, not the plan's 2 — environment, not a lost test

The single skip is
`GatewayAdapterBriefTests.testClipboardBriefRevisionPinMatchesPublishedContract`:
`Test skipped - No website source at …/.codex/worktrees/website/src/lib/adapter-contracts.ts`. Every
`XCTSkip` in the suite is environment-conditional (unsigned-build keychain, a missing sibling
checkout, a momd probe, a path derivation), so the plan's 2-skip baseline reflects a different
environment, not a case this wave deleted — the executed count went UP (4750 → 4810) with 0 failures
and no fix agent reported removing a case. **Flagged for the gate so `2 skips` is not read as a
regression when it comes back as 1** (§8.6).

## 5. What I did NOT verify

- **Watch suite: NOT RUN.** No watch sim was assigned to me, and neither file I touched compiles into
  the wrist (`ConversationStore+Workboard.swift` is not in the `ConduckWatch Watch App` membership
  exception set; `WorkCaptureDrainerTests.swift` is test-bundle only). fix-seams measured
  `Executed 231 tests, with 0 failures` on this tree, but the audio workflow has since edited
  `ConduckWatch Watch App/WorkboardCaptureIntent.swift` and the watch catalog — **so the watch gate
  is genuinely unproven at this commit and the orchestrator must run it.**
- **The `expectedByteCount` half of `confirmPublication`** — wired nowhere, by the deliberate choice
  in §2.2.
- **No dedicated regression test for the store→vault confirm wiring.** Making it deterministic
  requires the leaf to vanish BETWEEN the row's `context.save()` and the confirm, and there is no seam
  in the store for that window (fix-drainer's `importHoldForTesting` sits in the drainer, after
  `persist`). Everything I could write instead would be a race. What IS covered: the *false-negative*
  direction — every `.localVault` capture in the suite now runs through the confirm and the full run
  is 0 failures, so a spurious refusal would be caught; and
  `WorkCaptureDrainerDurabilityTests.testAMissingVaultLeafBlocksAcknowledgementAndKeepsTheQueueCopy`
  proves the adjacent end-to-end guarantee (missing leaf ⇒ no acknowledgement, queue copy kept).
  **Stated plainly: the refusal branch of the three new `guard`s is not exercised by any test.**
  §8.2 says what seam would close it.

## Refuted

**fix-store's Request 5 no longer holds.** It asks for `WorkboardLiveRepository.swift:535-537`'s
comment ("Reattachment replaces local bytes and metadata only… the board renders previews from the
vault", flagged half-false by blob-io.md §Requests 4) to be rewritten. Re-located by symbol: the
comment now lives at `Conduck/Conduck/Services/Workboard/WorkboardLiveRepository.swift:558-565`
inside `replaceMaterial`, and it has **already been rewritten to the correct two-store truth**:

```
// Reattachment replaces the payload and its metadata, and nothing
// else: no extract, no preview. The arriving bytes are new bytes,
// so the storage policy picks their lane afresh — within the
// ceiling they ride private CloudKit as a blob, above it they stay
// in the device-local vault — but a derived text extract or
// thumbnail would put READABLE file content on the material row
// itself, which is a different claim from the payload the person
// chose to attach.
```

No "device-local only" claim and no "previews from the vault" claim survives. **Nothing owed; I
changed no code for it.** (Someone in the integrate wave landed it — it is not my edit; my diff on
that file is empty.)

Nothing else was refuted: I re-checked every fix agent's own verification and found no claim that
fails against the current tree.

## 6. Refutations passed through from the fix agents

**None.** All five fix agents CONFIRMED every finding they were given; not one wrote a `## Refuted`
section. So Codex round 2 has no refutation to adjudicate from this wave — only the open items in §8.

## 7. What the next agent must know (the wave's standing constraints, consolidated)

Restating the "nobody undo this" requests in one place, because they now interlock:

1. **Do not re-narrow the desk capture's owner rule back to a refusal** (fix-store #3). Adoption is
   what makes an upgrade replay terminate. It also underwrites §3's rewritten drainer test.
2. **Do not drop `replaceWorkMaterialPayloadFile`'s all-rows loop back to `workMaterialRow(id:)`**
   (fix-store #4). Blob deletion there is scoped to the LOGICAL material id.
3. **Do not widen `reclaimUnreferenced` back into an unconditional sweep**, and do not "fix" a
   just-orphaned leaf surviving one reconcile pass (fix-vault #3).
4. **Do not widen `confirmDurablyImported` to a per-material probe**, and do not move `acknowledge`
   earlier (fix-drainer #3, #4).
5. **Do not tidy away the drainer's two defaulted `init` parameters** (`leaseHeartbeatInterval`,
   `now`) — the 5-minute horizon is untestable without them (fix-drainer #2).
6. **Do not sweep `_mountedStoresForTesting` into the `!os(watchOS)` payload guard**, and put any NEW
   blob-touching seam inside that guard plus `payloadSeams` (fix-seams #4.1, #4.2).
7. **Anything enumerating `processing/` must parse `<id>_<epoch>_<generation>`**, never assume
   `<id>` (fix-inbox §5).
8. **New, from me: do not put `confirmPublication` back to `markReferenced` at the three sites.** The
   whole point of fix-vault's cross-process staging marker is that a publication is *proved* before
   it is reported durable; a blind release re-opens the finding's second half.

## Catalog

**Keys I ADDED in source: NONE.** Both changes are headless — the failure path reuses the
pre-existing `WorkboardStoreError.materialPayloadUnavailable`, whose `errorDescription` is
deliberately `nil`. No `.xcstrings` file was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

## Requests

### 8.1 Codex round 2 — the one open adjudication from the wave
**fix-store §3, passed through verbatim.** Finding #1's object-scoped rollback closes the
interleaving the finding describes and leaves one adjacent one open: A publishes its blob, is
suspended before its material transaction; B runs whole, adopts A's row (`.alreadyPresent`, inserts
nothing) and commits its card; A resumes, loses the CAS, and rolls back **its own row** — the one B's
card names — leaving B's card `.syncedPending`. fix-store lists three narrower guards and why each is
worse, argues it is bounded (needs two processes or two concurrent reattaches) and recoverable (not
lossy: the drainer's barrier refuses to acknowledge, so a share capture is redelivered). The real fix
is a mechanism change — "an adopting caller must not depend on a row it did not write". **I did not
attempt it: it is larger than a Requests resolution and would rewrite the publication protocol.**

### 8.2 Codex round 2 / next wave — the untested refusal branch and the size half
Two linked gaps, both from §2:
- The three new `guard publicationIsDurable` branches have **no test**. The seam that would make one
  deterministic is a post-save / pre-confirm hold in `publishWorkMaterial` and `insertWorkMaterial`,
  modelled exactly on fix-drainer's `#if CONDUCK_TESTING importHoldForTesting`. That is a new
  production seam, which is why I did not add it under a "resolve minimally" mandate.
- `confirmPublication(expectedByteCount:)` has no production caller because the `.localVault`
  `byteSize` can be a CALLER'S CLAIM (`declaredByteSize ?? measured`,
  `draft.byteSize ?? payload.count`) rather than the leaf's true length. Closing it means making that
  column report the bytes actually written. Judge whether the truncation check is worth that
  semantic change.

### 8.3 Whoever owns `WorkAssetVault.swift` — `markReferenced` is now production-dead
Its only callers are seven lines in `WorkAssetVaultTests`. Either keep it as the explicit
"release without proving" primitive (and say so at the declaration) or retire it and move those tests
onto `confirmPublication`. **Do not simply delete it** — that suite is fix-vault's and it would go
red. Not urgent, not a defect; recorded so it is a decision rather than drift.

### 8.4 Docs agent — three facts are now settled by code
(a) A material a pre-desk build parked under a per-capture owner is **re-homed onto the desk** by an
explicit re-capture of that id; the owner row it came from is kept and never deleted. (b) A repeat of
a Chat → Work capture **republishes every attachment whose bytes the device still holds**, so a card
whose payload never landed is repaired rather than reported as already captured. (c) **A capture is
reported durable only once its bytes read back** — a complete blob row on the synced lane, a present
vault leaf on the local lane, nothing required of a metadata-only card; a share-inbox capture that
fails that check goes back into the queue rather than becoming a card with no bytes behind it.

### 8.5 Founder QA (Gate 2) — one item to add
fix-drainer #6, passed through: share a file **above 30 MB** (so it takes the device-local vault)
from another app while the device is busy, and confirm it appears on the desk exactly once and opens.
That exercises the vault lane's readability check, a drain long enough to need a lease renewal, and
now the store-side confirm as well. A capture that *disappears* from the share sheet without reaching
the desk is the failure these three slices exist to make impossible.

### 8.6 Orchestrator — three things before the gate
1. **Run the watch suite.** It is the one gate genuinely unproven at this commit (§5): fix-seams'
   `231 / 0` predates the audio workflow's edits to `ConduckWatch Watch App/WorkboardCaptureIntent.swift`
   and the watch catalog.
2. **Expect 1 skip, not the plan's 2** (§4). Environment-conditional, not a deleted case.
3. **iOS baseline is 4810 executed / 0 failures** with the whole wave in the tree. The fix wave's own
   deltas, for reconciliation: fix-inbox +5, fix-drainer +5, fix-vault +6, fix-store +6, fix-seams
   +2 = **+24**; I added none (the drainer case was rewritten in place, not added).

## Call-site touches

**Three**, all inside `ConversationStore+Workboard.swift` itself and all resolving fix-vault's
Request 1: `publishWorkMaterial`, `insertWorkMaterial`, `replaceWorkMaterialPayloadFile`. **No
signature anywhere changed** — `confirmPublication` is `@discardableResult` with a defaulted second
parameter, so no file outside the two I edited was opened.
