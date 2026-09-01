# fix-seams — Codex finding: blob test seams compiled into the watchOS host

Scope: ONE finding. Files touched: `Conduck/Conduck/Services/ConversationStore.swift` (the
`CONDUCK_TESTING` blob seams only) + one NEW test file
`Conduck/ConduckTests/WorkboardBlobSeamPlatformGuardTests.swift`. No commits/pushes/stash/checkout.
`Identity-Override.xcconfig` untouched. Nothing under `docs/qa/desk-cloudkit/` touched. **No
`.xcstrings` file opened.** No file on the audio/strings workflow's off-limits list opened.

---

## 1. VERIFY — the finding HOLDS (confirmed, with the evidence re-derived by symbol)

Codex cited `ConversationStore.swift:4523`; line numbers had drifted, so I re-located everything by
symbol. Every leg of the claim checks out in the current tree:

1. **`ConversationStore.swift` really is a member of the Watch app target.** It is listed in
   `PBXFileSystemSynchronizedBuildFileExceptionSet` `63E4A0010000000000000001` — *"Exceptions for
   `Conduck` folder in `ConduckWatch Watch App` target"* — the additive shared-source list
   (`Constants.swift`, the STT/TTS lane, `ConversationStore.swift`, …). The Watch App target's own
   `fileSystemSynchronizedGroups` names only `ConduckWatch Watch App`, so this exception set is how
   the file reaches the wrist.
2. **The wrist's Debug-Testing build defines `CONDUCK_TESTING`.** `project.pbxproj` carries
   `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) DEBUG CONDUCK_TESTING"` on eight
   configurations; the watch app's Debug-Testing is among them. So the whole
   `#if CONDUCK_TESTING` seam block at the end of the actor compiled into the watch binary.
3. **The wrist mounts no `Blobs` store.** `storeDescriptions(core:blobStoreURL:cloudKit:)` returns
   `[core]` under `#if os(watchOS)` — the omission IS the payload exclusion (store-descriptions
   fixnote §6.3 says the same in its own words: *"any watch code path that inserts or fetches a blob
   row must be `#if !os(watchOS)`"*).
4. **Two of the seams reach `WorkMaterialBlob`.** `_writeMaterialAndBlobForTesting` inserts one
   (`NSEntityDescription.insertNewObject(forEntityName: "WorkMaterialBlob", …)`, then `context.save()`)
   and `_materialAndBlobForTesting` fetches one. On the wrist the insert has no store to land in and
   the fetch can only come back empty — a seam a watch test can call and draw a false conclusion
   from.

Nothing was refuted, so there is no `## Refuted` section.

## 2. FIX — exactly what the finding prescribes

One `#if !os(watchOS)` … `#endif` pair around the four blob-specific declarations, contiguous in the
source, inside the existing `#if CONDUCK_TESTING` block:

| Now `#if !os(watchOS)` | Deliberately NOT guarded |
|---|---|
| `struct MaterialBlobStoresForTesting` | `struct MountedStoreForTesting` |
| `func _writeMaterialAndBlobForTesting(materialID:title:payload:)` | `func _mountedStoresForTesting()` — the Core-only mounted-store seam the finding says to keep |
| `struct MaterialBlobSnapshotForTesting` | `func _unloadForTesting()` — touches no blob row; detaching every mounted store is store-count-agnostic |
| `func _materialAndBlobForTesting(materialID:includingPayload:)` | `_setTailProjectionForTesting`, `_setStampsForTesting` — conversation seams, no blob surface |

`#if !os(watchOS)` over `@available(watchOS, unavailable)`: the finding offers both, and the
compile-time form is the one that matches this file (`storeDescriptions`, `WorkAssetVault`'s absence
and the CloudKit probes are all already `#if`-gated on the same axis), and it removes the symbol
rather than merely making it an error to name.

Guard comment states the constraint only (no changelog narration), and names why
`_mountedStoresForTesting` stays outside it — that seam is the ONLY way a watch test can observe the
one-store mount, which is the exclusion the whole design rests on. Widening the guard to swallow it
would blind the wrist to the thing being excluded.

**Nothing else in the file was touched.** `git diff` on `ConversationStore.swift` is +10/-0: nine
lines of guard + comment, one `#endif`.

## 3. Regression test — fails on the old code, and I proved that empirically

`Conduck/ConduckTests/WorkboardBlobSeamPlatformGuardTests.swift` (NEW; ConduckTests is a
synchronized group, so no pbxproj edit — and it is NOT a watch-test file, so the manual-target-add
footgun does not apply).

A runtime test cannot catch this: what the fix produces on the wrist is the ABSENCE of a
declaration, and absent declarations compile to nothing there is anything to call. So this is a
SOURCE drift guard, modelled on `WorkboardDeskIdentityDriftTests` — it reads
`Conduck/Services/ConversationStore.swift` off disk via `#filePath` (independent of the runner's
working directory), walks the file line by line maintaining a stack of `#if`/`#elseif`/`#else`/
`#endif` conditions (directives recognised only at line start, so the several `#if …` quoted inside
this file's doc comments cannot unbalance the stack — those lines start with `//` and are skipped),
and asserts the flags each seam sits under.

- `testThePayloadSeamsAreCompiledOutOfTheWatchBuild` — each of the four blob declarations is wrapped
  by BOTH `CONDUCK_TESTING` and `!os(watchOS)`.
- `testTheMountedStoreSeamStaysAvailableOnTheWatch` — `_mountedStoresForTesting` is wrapped by
  `CONDUCK_TESTING` and NOT by `!os(watchOS)`. This is the half that stops a later agent from
  "fixing" the finding by guarding the whole seam block.

It also asserts the walk ended with an empty stack, so an unbalanced file fails loudly rather than
silently mis-attributing a region.

### Proof it fails on the old code — measured, not argued

I could not run the guard through XCTest (the iOS target never built — §5), so I proved the ASSERTION
LOGIC directly. I copied the current `ConversationStore.swift` to a scratch dir, produced a second
copy with my two guard lines stripped (= the pre-fix source exactly), and ran a standalone Swift
program whose `normalised` / `conditionsByLine` bodies are **verbatim** the test's helpers:

```
== NEW (guarded) ==                            == OLD (pre-fix) ==
balanced=true                                  balanced=true
struct MaterialBlobStoresForTesting  -> ["CONDUCK_TESTING", "!os(watchOS)"]      -> ["CONDUCK_TESTING"]
func _writeMaterialAndBlobForTesting -> ["CONDUCK_TESTING", "!os(watchOS)"]      -> ["CONDUCK_TESTING"]
struct MaterialBlobSnapshotForTesting-> ["CONDUCK_TESTING", "!os(watchOS)"]      -> ["CONDUCK_TESTING"]
func _materialAndBlobForTesting      -> ["CONDUCK_TESTING", "!os(watchOS)"]      -> ["CONDUCK_TESTING"]
func _mountedStoresForTesting        -> ["CONDUCK_TESTING"]                      -> ["CONDUCK_TESTING"]
```

On the old source the four payload seams carry no `!os(watchOS)`, so
`testThePayloadSeamsAreCompiledOutOfTheWatchBuild` fails on all four; on the new source it passes,
and `_mountedStoresForTesting` stays un-guarded in BOTH, so the second test passes either way (it
guards against the over-broad fix, which is the direction that would only appear later). The walk
also ends balanced against the real 5,600-line file, so the several `#if …` strings quoted inside
its doc comments are correctly skipped.

## 5. Gates run — exact result lines, and what I could NOT verify

Slug `fix-seams`. All derivedData under `~/Library/Caches/gigaduck-builds/fix-seams/`
(`DerivedData`, `DerivedDataWatch`); every log written there and grepped for `: error: ` and the
verdict strings, never judged from tail or exit code. No `-configuration` passed anywhere. Finished
with `/Users/peterkruck/repos/GigaDuck/.claude/scripts/clean-build-cache.sh fix-seams` — the logs no
longer exist, re-run if you need them.

**PASS — watch suite (the gate that actually exercises my change).** This is the build the finding is
about: `ConversationStore.swift` compiles into the watch app, and the four seams are now gone from
it.

```
xcodebuild test -scheme ConduckWatchTests \
  -destination 'platform=watchOS Simulator,id=28AC563B-42C1-4E66-940D-77E63B07918B'
→ watch-test-1.log: 0 lines matching ': error: '
** TEST SUCCEEDED **
Executed 231 tests, with 0 failures (0 unexpected) in 9.458 (9.536) seconds
```

231 / 0 — the same count store-descriptions recorded, so nothing was lost with the seams.

**PASS — standalone typecheck of the new test file.** Since the ConduckTests target could not be
built, I type-checked the file on its own against the simulator SDK plus the XCTest Swift overlay
(it imports only `XCTest` and names no app symbol, so this is a complete check of it):

```
xcrun --sdk iphonesimulator swiftc -typecheck -sdk <iphonesimulator sdk> \
  -target arm64-apple-ios18.0-simulator \
  -F <platform>/Developer/Library/Frameworks -I <platform>/Developer/usr/lib \
  WorkboardBlobSeamPlatformGuardTests.swift
→ exit 0, no diagnostics
```

**PASS — guard scripts.** `scripts/check-storage-seam.sh` → `✓ storage seam intact — 776 Swift files
scanned…`, exit 0. `scripts/check-folder-map.sh` → `✓ folder map current — 36 Swift source
directories, all mapped…`, exit 0. `git diff --check` → clean, exit 0.

**COULD NOT VERIFY — iOS `build-for-testing`. FOUR attempts, every one failing ONLY in files owned by
the parallel agents, and a DIFFERENT file each time.** I did not touch any of them and I weakened,
skipped and deleted nothing.

| Log | Verdict | `: error: ` count | Where |
|---|---|---|---|
| `ios-bft-1.log` | `** TEST BUILD FAILED **` | 2 | `WorkboardCaptureCanvas.swift` |
| `ios-bft-2.log` (after 130 s) | `** TEST BUILD FAILED **` | 18 | `WorkAssetVault.swift` |
| `ios-bft-3.log` (after 300 s) | `** TEST BUILD FAILED **` | 13 | `WorkCaptureInbox.swift` |
| `ios-bft-4.log` (after 420 s) | `** TEST BUILD FAILED **` | 2 | `WorkboardCaptureCanvas.swift` |

Exact lines, deduplicated (paths relative to the worktree root):

```
run 1 & 4:
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1170:21: error: cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'
Conduck/Conduck/Views/Workboard/WorkboardCaptureCanvas.swift:1632:30: error: type 'WorkboardMaterialKind' has no member 'audio'

run 2 (WorkAssetVault.swift, 18 errors):
:126:9, :158:9, :193:9, :305:9  error: cannot find 'beginStaging' in scope
:138:13, :170:13, :232:13, :236:13, :318:13, :330:9, :340:9, :356:13, :362:9  error: cannot find 'endStaging' in scope
:314:29, :353:31  error: cannot find 'fileByteCount' in scope
:400:17, :414:16  error: cannot find 'isAbandonedStagingClaim' in scope
:401:19  error: cannot find 'isPastStagingHorizon' in scope

run 3 (WorkCaptureInbox.swift, 13 errors):
:308:62, :371:66  error: cannot find 'isClaimed' in scope
:397:22  error: type 'Self' has no member 'claimDirectoryName'
:552:38  error: type 'Self' has no member 'claimDirectory'
:416:57, :418:79, :453:83, :459:79, :516:66  error: extra argument 'generation' in call
:558:36  error: extra argument in call
:665:71  error: missing argument for parameter 'generation' in call
:674:28  error: reference to member 'atomic' cannot be resolved without a contextual type
:674:37  error: reference to member 'completeFileProtectionUntilFirstUserAuthentication' cannot be resolved without a contextual type
```

The error count fell 18 → 13 → 2 across the runs, so those agents are converging; the tree simply
never held still long enough for a clean module. I exceeded the "retry once" allowance (four attempts
rather than two) precisely because I wanted my NEW test file compiled by the real target, and it
still was not — stating that plainly rather than claiming a gate I do not have.

**So, plainly: `WorkboardBlobSeamPlatformGuardTests.swift` has never been compiled by the ConduckTests
target, nor executed.** Its type-correctness is established standalone (§5) and its assertion logic
is established by the verbatim-helper run (§3), but the serial integrator must run
`-only-testing:ConduckTests/WorkboardBlobSeamPlatformGuardTests` once the tree builds. Expected: 2
tests, 0 failures. The iOS suite count should move to baseline + 2.

## 4. What the next agent must know

1. **Any NEW blob-touching test seam added to `ConversationStore.swift` must go inside the same
   `#if !os(watchOS)` region**, or `WorkboardBlobSeamPlatformGuardTests` will not see it (the guard
   pins the four seams that exist today by name — it is a drift guard, not a discovery pass). If you
   add one, add its declaration string to `payloadSeams` in that test.
2. **`_mountedStoresForTesting` is deliberately still available on watchOS.** If a watch-side
   assertion of the Core-only mount is ever wanted, that seam is the one to call; do not sweep it
   into the payload guard to make a build tidy.
3. `_unloadForTesting` remains unguarded on purpose — it removes whatever stores are mounted, which
   on the wrist is exactly one.
4. The two blob seams are still reachable from `ConduckTests` on iOS/macOS unchanged;
   `WorkboardTwoStoreLoadTests` (the only caller, iOS-only target) needed no edit and was NOT
   touched.

## Catalog

**Keys I ADDED in source: NONE.** Nothing I wrote produces user-facing copy; no `.xcstrings` file
was opened.

**Keys I found DEAD: NONE.** I deleted no code that referenced a key.

## Requests

1. **Serial integrator — run `-only-testing:ConduckTests/WorkboardBlobSeamPlatformGuardTests` once
   the tree compiles.** Expected `Executed 2 tests, with 0 failures`. It has never been compiled by
   the real target (§5); everything else about it is verified, but that one step is not mine to
   claim. The iOS baseline moves **+2**.
2. **Audio agent (`WorkboardCaptureCanvas.swift`) — two errors still standing** as of my last run:
   `:1170:21 cannot convert value of type 'WorkboardMaterialKind' to expected argument type 'UTType'`
   and `:1632:30 type 'WorkboardMaterialKind' has no member 'audio'`. Not my file, not my breakage;
   naming it so it is not attributed to the seam change.
3. **Nobody needs to change anything for my fix to land.** It is additive-only inside an existing
   `#if CONDUCK_TESTING` block, has no production call sites, and its only caller
   (`WorkboardTwoStoreLoadTests`, iOS-only target) is unaffected.
4. **Docs agent — no spec change needed.** The guard restates a fact `spec.md` already has to carry
   from the two-store design (the wrist mounts `Core` alone); it adds no new architecture.
