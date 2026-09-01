# inbox-lease — plan §A "Cross-process inbox ownership (Codex #2)". DONE, gates green.

Scope kept to exactly the two owned files. No .xcstrings edit (no user-facing copy added). No envelope/snapshot mirror touched. No git ops.

## What changed

**1. `Conduck/Conduck/Services/WorkCaptureInbox.swift`** (+181 / −16) — a filesystem claim lease makes ownership legible across processes; every pre-existing guarantee (atomic move, claim token, exact-containment validation, bounded validation, best-effort reconcile) is intact.

| Symbol | Change |
|---|---|
| file header | states the lease + the "acknowledgement is never self-issued" rule |
| `static let leaseFilename` | **`"claim-lease.json"`** — not dot-prefixed (a hidden file would read as the very smuggling `isSafeLeaf` exists to stop) |
| `static let staleClaimHorizon` | **`5 * 60` s** (see rationale below) |
| `struct ClaimLease: Codable, Equatable, Sendable` | `owner: UUID` + `refreshedAt: Date`; JSON, `dateEncodingStrategy = .secondsSince1970` both ways |
| `nonisolated let ownerID = UUID()` | per-INSTANCE, minted in the stored-property initializer so both `init`s get it. A relaunched process therefore never mistakes its predecessor's lease for its own — the horizon is the only cross-process liveness signal a plain file can carry |
| `ReconciliationReport.respectedLeaseCount` | new, **defaulted to 0 in `init`** so the existing `.init(releasedClaimCount:removedTemporaryCount:collisionCount:)` comparison in `WorkCaptureInboxTests:848` still compiles |
| `claimNext(now: Date = Date())` | new defaulted param (drainer call site unchanged). Writes the lease **immediately after the claiming move, BEFORE `validateEnvelope`** — the directory is never visible in `processing/` without an owner, so it cannot be requeued underneath a claim that is still validating. A lease-write failure **aborts the claim** (`preserveClaimedDirectory` + `.filesystemFailure`): draining without a lease would leave the directory free for any other process to requeue mid-import |
| `acknowledge` / `release` | `requireActive` (unchanged) **then** `requireLeaseOwnership` |
| `refreshLease(_:now:)` | new; `requireActive` + `requireLeaseOwnership` + rewrite the marker. For a drain that legitimately outlives the horizon |
| `reconcile(now:)` | the `where activeClaims[id] == nil` loop now also requires `isAbandonedClaim(at:now:)`; a live foreign lease increments `respectedLeaseCount` and is skipped. Requeue path calls `removeLease(in: source)` first |
| `validateEnvelope` | `allowedNames` = declared payload leaves ∪ `{manifest.json, claim-lease.json}` |
| `isSafeLeaf` | rejects `leaseFilename` as it already rejects `manifestFilename` |
| `preserveClaimedDirectory` / `release` | strip the marker before moving back, so a requeued capture is byte-for-byte the shape its publisher wrote |
| new private helpers | `isAbandonedClaim`, `requireLeaseOwnership`, `LeaseState`, `leaseURL`, `writeLease`, `leaseState`, `removeLease` (all `fileManager`-routed, so the tests' injected `FileManager` subclasses still bite) |

**2. `Conduck/ConduckTests/WorkCaptureInboxLeaseTests.swift`** (NEW, 9 tests) — took the "one new file" option rather than growing the 920-line existing class. SPDX + purpose header present; `ConduckTests` is a synchronized group, so **no pbxproj edit** (confirmed: the file compiled and ran without touching `project.pbxproj`).

## Decisions (and why)

- **Horizon = 5 minutes.** The cost is asymmetric. Too short → two processes drain one directory and the second one's `acknowledge` **deletes payload files the first is still reading**; too long → a crash-stranded capture is invisible until it expires (never lost: `reconcile` runs at every drain). A bounded envelope persists in seconds, so 5 min is ~50× the realistic drain while bounding post-crash invisibility to one recovery window instead of the 1-hour temp horizon. `refreshLease` is the escape hatch for a drain that genuinely needs longer, so the horizon never has to be widened for a slow path.
- **Comparison is `>=` horizon** (a lease exactly at the horizon IS requeued), and a **future-dated** lease (clock skew) is respected until the clock catches up — skew must never license two concurrent drains.
- **Same-owner short-circuit:** a lease naming THIS instance on a directory not in `activeClaims` is stale by definition and requeues immediately, no horizon wait.
- **Missing marker on a stranded directory = abandoned, requeued at once** — no build can leave a claimed directory without one, so its absence predates the lease or was left by reconcile itself.
- **`requireLeaseOwnership` fail-safe split:** a *readable* lease naming another owner, or an *absent* lease while the directory still exists, throws `.staleClaim` and drops the local `activeClaims` entry (a takeover happened). A *corrupt/unreadable* lease does NOT (corruption is not evidence of a takeover — a thief writes a readable lease of its own); it falls back to the file's mtime for aging so the horizon can still expire it.
- **File protection on the marker is `.completeFileProtectionUntilFirstUserAuthentication`, deliberately weaker than the payloads' `.completeFileProtection`.** It carries no user content, and a marker another awake process cannot read would read as a false takeover on a locked device.
- **`claim-lease.json` is now a reserved leaf**, so a published envelope declaring it is rejected `.unsafeRelativePath` (test). Undeclared bytes smuggled under that name are destroyed by the claim's own atomic overwrite *before* validation, which is why widening `allowedNames` admits nothing.
- Drainer behaviour on a stolen claim (unchanged file, stated for the next agent): `persist` succeeds, `acknowledge` throws `.staleClaim`, the `catch` calls `release` which also throws and is swallowed by `try?`, and the drain surfaces the error. The capture is not lost — the thief imported it, and deterministic material ids make the replay idempotent.

## Acknowledgement seam (for the byte-sync / drainer agent)

`WorkCaptureInbox.acknowledge(_:)` sits alone under `// MARK: - Acknowledgement seam` and is documented as THE queue's only deletion of imported bytes. **The inbox never reaches it on its own** — grep confirms `acknowledge` has exactly one production caller, `WorkCaptureDrainer.drainAvailableCaptures` (`WorkCaptureDrainer.swift`, right after `persist(claim)`).

Plan §C write order lands as: **(1)** blob row durable → **(2)** material row `.syncedPayload` → **(3)** `inbox.acknowledge(claim)`. So the drainer agent must keep `acknowledge` as the LAST statement after the blob is readable, not merely after the material save returns. Signature is unchanged on purpose (I do not own the drainer); if you want the durability precondition enforced by the type system rather than by this note, ask for it in a later wave — I did not invent a witness parameter that would have forced an edit to a file I do not own. `refreshLease(_:now:)` is available if a large-blob write can approach 5 minutes.

## Tests + counts

Everything below is `test-without-building` on sim `5C851D88-959C-445E-ACC8-A4C6ADB2876C`, derivedData `~/Library/Caches/gigaduck-builds/desk-inbox-lease/DerivedData`.

- iOS `build-for-testing` (no `-configuration`): **`** TEST BUILD SUCCEEDED **`**, zero `error:` lines. (First attempt failed only on my own test file: `'await' in an autoclosure that does not support concurrency` — `XCTUnwrap` takes an autoclosure, so every `try await` is hoisted to its own `let`, matching the existing class's style.)
- Targeted run, `-only-testing:ConduckTests/WorkCaptureInboxTests` + `…/WorkCaptureInboxLeaseTests` + `…/WorkCaptureDrainerTests`:
  - `Test Suite 'WorkCaptureDrainerTests' passed` — `Executed 5 tests, with 0 failures (0 unexpected) in 0.061 (0.062) seconds`
  - `Test Suite 'WorkCaptureInboxLeaseTests' passed` — `Executed 9 tests, with 0 failures (0 unexpected) in 0.040 (0.042) seconds`
  - `Test Suite 'WorkCaptureInboxTests' passed` — `Executed 30 tests, with 0 failures (0 unexpected) in 0.160 (0.167) seconds`
  - total `Executed 44 tests, with 0 failures (0 unexpected) in 0.261 (0.272) seconds` · `** TEST EXECUTE SUCCEEDED **`
- **Suite count: +9 iOS tests** (the pre-existing 30 inbox + 5 drainer tests are untouched; no assertion anywhere was weakened or deleted).

The 9 new tests: lease names the claiming instance + is the only file a claim adds · a payload may not impersonate the marker · a live foreign claim is not requeued inside the horizon (`respectedLeaseCount == 1`, the intruder's `claimNext` returns nil, the owner still completes) · a refreshed lease survives a horizon that would have expired it · a lease at/over the horizon IS requeued and returns to the publisher's exact shape, then the intruder's own lease covers it · the stale owner can neither acknowledge nor release the stolen claim (`.staleClaim` both, the intruder's directory survives, the intruder acknowledges) · crash simulation (instance dropped mid-claim; a later instance requeues nothing before the horizon and recovers the published bytes after it) · a marker-less stranded directory requeues at once · release leaves no marker and the capture re-claims cleanly.

- `git diff --check` clean. `clean-build-cache.sh desk-inbox-lease` run → `removed: desk-inbox-lease`.
- **NOT run** (outside my VERIFY): macOS build, full iOS suite, watch suite, `check-storage-seam.sh`. My changes are pure Foundation with no platform-conditional code, but I did not prove the macOS build myself.

## Catalog

No string keys added — this slice adds no user-facing copy. No dead keys found.

## Requests

- **Drainer agent (`WorkCaptureDrainer.swift`)**: keep `inbox.acknowledge(claim)` as the last step after the blob AND material rows are readable (plan §C write order). Nothing needs to change today — `claimNext()` / `acknowledge(_:)` / `release(_:)` / `reconcile()` all kept their existing signatures via defaulted `now:` params.
- **Nobody needs to mirror `leaseFilename` into the share extensions** — extensions only publish, never claim, so `ShareViewController`'s independently reconstructed inbox constants (`directoryName`, `manifest.json`, the Darwin name) stay exactly as they are. Do not add a fourth mirror.
- **Integration agent:** `ReconciliationReport` gained `respectedLeaseCount` (defaulted). If any later code compares whole reports, a live foreign lease now shows up there rather than as a silent zero.

## Call-site touches

None. I edited no file outside the two I own.
