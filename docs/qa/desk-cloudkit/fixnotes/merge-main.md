# Merge `main` into `feature/agent-workboard` — fixnote

Worktree: `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard`
`HEAD` = `09bc5a1` (feature/agent-workboard) · `main` = `b649c83` · merge-base `53b08d3`
State handed back: **merge STAGED, uncommitted** (`MERGE_HEAD` = `b649c836a9cd9338c09a9245a38d1e079505a4b7`).

Pre-merge `git status --short` was empty. `git merge --no-ff --no-commit main` produced **exactly the three expected content conflicts** and no others:

```
CONFLICT (content): Merge conflict in Conduck/Conduck/Services/ShareTargetsSnapshotWriter.swift
CONFLICT (content): Merge conflict in Conduck/Conduck/Views/Conversation/MainWindowView.swift
CONFLICT (content): Merge conflict in docs/ai-context/spec.md
```

---

## Conflicts

### (a) `Conduck/Conduck/Services/ShareTargetsSnapshotWriter.swift` — 2 hunks

**Hunk 1 (type doc comment).** Main's paragraph verbatim, plus one sentence for the branch's stale-skip behaviour:

```swift
/// Builds + atomically writes the App-Group `share-targets.json` the appex
/// picker reads. An `actor`, but actor isolation alone does NOT serialize
/// concurrent triggers (`.conversationsDidChange` + `.settingsDidChangeRemotely`
/// firing near-simultaneously): actors are REENTRANT across `await`, and
/// `regenerate()` suspends. It therefore coalesces explicitly — one build in
/// flight plus one trailing build — which both bounds the store reads a burst
/// can start and stops an older build committing over a newer one. A build that
/// a newer trigger has already made stale is discarded unwritten, so only the
/// trailing pass publishes.
```

**Hunk 2 (`regenerate()` body).** Main's structure verbatim (`isRegenerating` / `regenerationPending`, the `defer` with its comment, the `repeat … while`), with the branch's one behaviour folded in as a `guard` before `write(snapshot)`:

```swift
        if isRegenerating {
            regenerationPending = true
            return
        }
        isRegenerating = true
        // `defer` rather than a trailing assignment: today nothing in the loop
        // can exit early, but one future `guard`/`try` would strand the flag set
        // forever, and every later call would then return at the check above —
        // the appex's `share-targets.json` frozen for the process lifetime, with
        // no error anywhere. Structural beats a comment.
        defer { isRegenerating = false }
        repeat {
            regenerationPending = false
            let snapshot = await buildSnapshot()

            // Another trigger arrived during the awaits: this projection is
            // already stale, so skip publishing it and build the one coalesced
            // follow-up instead. `continue` in a `repeat`-`while` jumps to the
            // condition, which is true here, so that follow-up build runs.
            guard !regenerationPending else { continue }
            write(snapshot)
        } while regenerationPending
```

**Dead-flag cleanup.** The auto-merge left BOTH flag pairs declared. The branch's `regenerationIsRunning` / `regenerationWasRequested` (and their doc comment) were removed; exactly one pair remains:

```
70:    private var isRegenerating = false
71:    private var regenerationPending = false
```

`git grep 'regenerationIsRunning\|regenerationWasRequested'` over the whole repo returns **no hits**, so nothing else referenced them.

### (b) `Conduck/Conduck/Views/Conversation/MainWindowView.swift` — 3 hunks

**Hunk 1 (:116) — both declarations kept**, branch first, each with its own comment: `@State private var footerAppIcon = highResAppIcon(size: 32)` then `@Environment(\.appearsActive) private var appearsActive`.

**Hunk 2 (:805) — both modifier blocks kept**, branch first. The branch's `.onChange(of: workbenchDestinationIsActive)` is closed with its own `}`, then main's two blocks follow with their comments:

```swift
        .onChange(of: workbenchDestinationIsActive) { _, isActive in
            guard !isActive else { return }
            …
            cancelDropWork()
        }
        // Presence dot lifecycle. …
        .task(id: presenceRef) {
            if let ref = presenceRef { GatewayPresenceMonitor.shared.observe(ref) }
        }
        // The Mac's foreground arm. …
        .onChange(of: appearsActive) { _, isActive in
            guard isActive, let ref = presenceRef else { return }
            GatewayPresenceMonitor.shared.observe(ref)
        }
```

**Hunk 3 (:1079) — branch's gate, main's content.** `gatewayToolbarContent` keeps the branch's doc comment (Work gate + the WHY-never-`EmptyView` paragraph) with one appended sentence on the dot's placement, and the branch's gate; the else-branch renders main's `HStack`. Main's `gatewayControl` property is kept, and the inlined copy of that `Group` was deleted from the branch's old else-branch, so the control body exists exactly once:

```swift
    /// The presence dot sits BESIDE the control, not inside its label: only
    /// one of the three controls is a pill it could live inside, so parked
    /// outside it holds the SAME position whichever branch renders, and it
    /// stays its own accessibility element instead of being folded into a
    /// control's label where that control's own label would replace it.
    @ViewBuilder
    private var gatewayToolbarContent: some View {
        if !chatDestinationIsActive || !coordinator.hasAnyConfiguredGateway {
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityHidden(true)
        } else {
            HStack(spacing: 6) {
                GatewayPresenceDot(ref: presenceRef, diameter: 6)
                gatewayControl
            }
        }
    }

    /// The three-way control itself (picker / clone pill / read-only label),
    /// dot-free — see `gatewayToolbarContent` for why the dot is not in here.
    @ViewBuilder
    private var gatewayControl: some View {
        Group {
            …
        }
    }
```

`presenceRef` survived the auto-merge — declared once at line 1058 (`private var presenceRef: RemoteAgentRef? {`). Main's declaration did not need to be re-taken. `GatewayPresenceDot` and `gatewayControl` are each referenced exactly once (lines 1105, 1106) and `gatewayControl` declared once (1114).

### (c) `docs/ai-context/spec.md` — **3** hunks (the brief predicted 2; see Deviations)

All three resolved to **HEAD (the branch) verbatim**. Justification per hunk, from a three-way read against the merge-base:

| Hunk | Branch side | Main side | Base | Resolution |
|---|---|---|---|---|
| :473 | condensed "What the user has already read" paragraph + condensed Secrets sentence | paragraph deleted; Secrets sentence **identical to base** | both present | HEAD — main made no edit here, it only deleted; the branch's condensed wording is the only intentional change |
| :483 | keychain-trap sentence, Identity line, Audio sentence ending "…rides the desk's lane." | trap + Identity deleted; Audio = "There is no audio entity in the database at all — though note that is a property of the code rather than of the schema, since the attachment entity holds arbitrary bytes and a free-text media type." | trap/Identity/Audio present | HEAD |
| :498 | "Two smaller rules about audio on disk" bullets + condensed Outbound paragraph | bullets absent; Outbound **identical to base** | bullets present | HEAD |

**Main's Audio tail was DROPPED, not folded in.** Its claim is conditioned on "there is no audio entity in the database at all", which is false on this branch: model 16 (`Conversations 16.xcdatamodel/contents`, and `Conduck/Conduck/Models/WorkboardRecords.swift`) holds audio bytes in `WorkMaterialBlob`. The tail explains *why the absence is a code property rather than a schema property* — with the absence itself untrue here, the explanation states nothing that survives on the branch, so it was dropped per the brief's "otherwise drop it".

**Sweeper-bullets provenance, as instructed.** `git log --oneline -S 'Scratch files must carry a filename prefix' main`:

```
62caa33 docs: clear the public-source launch gates
68b2cbb docs(conduck): rewrite the architecture docs as decisions, not description
```

`git show main:docs/ai-context/spec.md | grep 'filename prefix the sweeper'` → **ABSENT**; main's only remaining "sweeper" mention is the summary line at its line 473. So main **deleted the text outright rather than moving it** — the deleting commit is **`62caa33` "docs: clear the public-source launch gates"** (its spec.md hunk is `92 +------` , i.e. a 92-line trim), and the removed line appears there as `-- **Scratch files must carry a filename prefix the sweeper recognises.** …`. Per the brief, the branch's bullets were kept: `TempScratchSweeperTests.swift` and `WatchTempScratchSweeperTests.swift` exist on **both** sides.

**No words were added to `spec.md` by the resolution** — every conflicted region took an existing side verbatim.

No conflict markers remain anywhere: `git grep -n '^<<<<<<<\|^>>>>>>>' -- .` → `clean`.

---

## Checks

(filled in below)

### 1. String catalogs

All four catalogs parse with `python3 json.load`:

| Catalog | Rows |
|---|---|
| `Conduck/Conduck/Localizable.xcstrings` | 2273 |
| `Conduck/ConduckShareExtension/Localizable.xcstrings` | 43 |
| `Conduck/ConduckShareExtensionMac/Localizable.xcstrings` | 42 |
| `Conduck/ConduckWatch Watch App/Localizable.xcstrings` | 299 |

Bidirectional `workboard.*` audit (keys matched by `"workboard\.[a-zA-Z0-9_.]+"` across `Conduck/Conduck/**/*.swift` vs catalog rows):

```
referenced (unique workboard.* keys in Conduck/Conduck/**/*.swift): 147
catalog rows (workboard.*): 147
missing (referenced, no catalog row): 0 []
catalog-only (row, never referenced): 0 []
```

**147 referenced / 147 rows / 0 missing / 0 catalog-only** — unchanged by the merge.

### 2. Mirror triplets

SHA-256 of each file from `import Foundation` onward — all three triplets identical across their three copies:

```
ShareTargetsSnapshot.swift:          3 copies, IDENTICAL  sha256=a72a7d13d6f1e9ec
WorkCaptureEnvelope.swift:           3 copies, IDENTICAL  sha256=45a26a6658c92401
WorkCaptureDirectoryPublisher.swift: 3 copies, IDENTICAL  sha256=777159cc94c1cd9a
```

`git diff --stat 53b08d3 main` over those nine paths is empty — **main touched none of them**, as expected.

### 3. Model files

`git diff --stat 651a859 -- 'Conduck/Conduck/Models/*.xcdatamodeld/*'`:

```
 .../Conversations.xcdatamodeld/.xccurrentversion   |   2 +-
 .../Conversations 16.xcdatamodel/contents          | 167 +++++++++++++++++++++
 2 files changed, 168 insertions(+), 1 deletion(-)
```

Only model 16 and `.xccurrentversion` differ; **v15 is byte-identical**. Main touched no model file.

### 4. Build cache

`~/Library/Caches/gigaduck-builds/merge-main` used for every `-derivedDataPath` (3.5G at peak), then `clean-build-cache.sh merge-main` → `removed: merge-main`, `cleanup exit=0`. No `rm -rf` was run.

### 5. iOS — simulator `2B6E0EAC-CA91-48DD-B5A4-47F4BE20E3FF` (iPhone 17)

**TCC check first**, as instructed:

```
sqlite3 …/2B6E0EAC…/data/Library/TCC/TCC.db "select service, client, auth_value from access where client='ai.gigaduck.AgentRelay'"
→ (no rows)
```

Zero rows, so no `auth_value 0` and **no privacy reset was needed**.

`build-for-testing` (no `-configuration` passed): `** TEST BUILD SUCCEEDED **`, **0** `: error:` lines (2220 `: warning:` lines, pre-existing).

`test-without-building`, full suite, single run, no simulator launch failure and no retry needed:

```
	 Executed 5146 tests, with 1 test skipped and 0 failures (0 unexpected) in 82.773 (84.236) seconds
Test Suite 'All tests' passed at 2026-09-03 16:05:21.265.
** TEST EXECUTE SUCCEEDED **
```

**Delta reconciled: 5050 → 5146 = +96**, and the +96 is fully accounted for by main's test classes. Per-class, from the run log:

| Class | Branch (source count) | Merged (executed) | Delta |
|---|---|---|---|
| `GatewayPresenceMonitorTests` (new) | 0 | 20 | +20 |
| `OpenRouterOAuthTests` (new) | 0 | 34 | +34 |
| `SettingsViewModelOpenRouterOAuthTests` (new) | 0 | 18 | +18 |
| `OpenRouterAttributionTests` (new) | 0 | 12 | +12 |
| `FileServerClientTests` (extended) | 98 | 101 | +3 |
| `OutboxNegativeControlTests` (extended) | 22 | 25 | +3 |
| `UnnamedOutputFolderRowTests` (extended) | 22 | 28 | +6 |
| **Total** | **142** | **238** | **+96** |

5050 + 96 = 5146. Exact match, so the merge added and lost no other test.

The one skip is the expected environment skip:

```
GatewayAdapterBriefTests.swift:263: -[ConduckTests.GatewayAdapterBriefTests testClipboardBriefRevisionPinMatchesPublishedContract] : Test skipped - No website source at …/.codex/worktrees/website/src/lib/adapter-contracts.ts — the clipboard brief's pin (revision 1.10) was NOT verified against the published contract.
```

The `ShareTargets*` classes touched by conflict (a) both pass:

```
Test Suite 'ShareTargetsSnapshotTests' passed —  Executed 9 tests, with 0 failures (0 unexpected) in 0.008 (0.009) seconds
Test Suite 'ShareTargetsSnapshotWriterColorTests' passed —  Executed 7 tests, with 0 failures (0 unexpected) in 0.005 (0.007) seconds
```

The iOS test log carries 1872 `: error:` lines. **None are build or test failures** — every one is CoreData runtime logging from negative-path tests (`CoreData: error: Failed to stat path '/nonexistent-…/store.sqlite'`, `Sandbox access to file-write-create denied`). Compiler-shaped errors (`^/….swift:N:N: error:`) count **0**, and `XCTAssert`/`failed -` count **0**.

### 6. Watch — simulator `28AC563B-42C1-4E66-940D-77E63B07918B`, run serially after iOS

```
	 Executed 232 tests, with 0 failures (0 unexpected) in 9.461 (9.545) seconds
Test Suite 'All tests' passed at 2026-09-03 16:06:35.638.
** TEST SUCCEEDED **
```

**232 — no delta.** `git diff --stat 53b08d3 main -- 'Conduck/ConduckWatchTests/*'` is empty, and `f44b8f5 chore(watch): extract Gemini STT error strings into the catalog` changed exactly one file (`ConduckWatch Watch App/Localizable.xcstrings`, +22 rows) and added no test. 0 `: error:` lines.

### 7. Signed macOS build

```
** BUILD SUCCEEDED **
```

0 `: error:` lines. Signed for real, not ad-hoc:

```
CodeSign …/Build/Products/Debug/Conduck.app (in target 'Conduck' from project 'Conduck')
    Signing Identity:     "Apple Development: Peter Krueck (Z4PNDLZK98)"
```

### 8. Guard scripts + staged diff

| Script | Exit | Output |
|---|---|---|
| `scripts/check-storage-seam.sh` | 0 | `✓ storage seam intact — 817 Swift files scanned, no raw store or live-adapter access outside …/LiveStorage.swift` |
| `scripts/check-folder-map.sh` | 0 | `✓ folder map current — 36 Swift source directories, all mapped, and every path the map names exists` |
| `scripts/check-spec-cites.sh` | 0 | `✓ spec citations resolve — 817 Swift files scanned, 1 quoted section name(s), every one a live heading in docs/ai-context/spec.md` |
| `scripts/check-spec-size.sh` | **0** | `✓ docs/ai-context/spec.md within budget — 16423 words of 16900, 39 decisions, largest unexempt one 596 of 650 ("What the app hands over by itself is a policy about opening, not a safety boundary")` |

`git diff --cached --check` → clean. Re-run after all four builds: still clean, no unstaged and no untracked files.

**Spec word count: 16,423** (branch tip was 19,827; main is 16,075). The merge is under budget because main's `62caa33` trim auto-merged; the conflict resolutions themselves added **zero** words.

---

## Failures

**None.** No test failed on any platform, no build failed, no guard script failed, and no fix was needed under rule 9.

---

## Deviations

1. **`docs/ai-context/spec.md` had THREE conflict hunks, not the two the brief predicted.** The extra one is the earliest (`:473`): the branch's condensed "What the user has already read" paragraph plus its condensed Secrets sentence, against main having deleted the paragraph. Main's Secrets sentence there is **byte-identical to the merge-base**, so main made no edit in that hunk at all — it only deleted. Resolved to HEAD, consistent with the brief's rule for the two hunks it did specify. Flagging it because it was not in the brief's resolution table.
2. **`scripts/check-spec-size.sh` now exits 0, not the pre-existing 1.** Main's spec trim (`62caa33`, −92 lines in `spec.md`) brought the file to 16,423 words against a 16,900 budget. The brief expected exit 1; the merge fixed it. No action taken.
3. **Main deleted the sweeper bullets outright** (`62caa33`) rather than moving them, and its spec has no replacement text anywhere. Per the brief's branch, the branch's bullets were kept. Reported here rather than silently resolved.
4. **Main's Audio tail sentence was dropped rather than folded in** — see the reasoning in Conflicts (c). This is the brief's own "otherwise drop it" branch, recorded because it is a judgement the brief asked to have explained.
5. The iOS `** TEST` banner reads `** TEST EXECUTE SUCCEEDED **`, which is what `test-without-building` emits; there is no `** TEST SUCCEEDED **` line in that log. The watch run, a plain `xcodebuild test`, does emit `** TEST SUCCEEDED **`.

Nothing was committed, pushed, rebased, stashed or reset. `Conduck/Configs/Identity-Override.xcconfig` was not touched (still the Aug 28 symlink to `Conduck-Private/Configs/`, still gitignored via `.gitignore:40`). `Conduck/Configs/Identity.xcconfig` merged normally, +4 lines from main.

---

## Requests

1. **No test covers the coalescing loop itself.** The only `ShareTargets*` classes are `ShareTargetsSnapshotTests` (9, the contract) and `ShareTargetsSnapshotWriterColorTests` (7, the hex helper). The behaviour preserved in conflict (a) — a stale projection is built and then deliberately not written — has **no direct test on either side of the merge**, so the resolution is verified by review and compilation, not by a red/green signal. Worth a test that drives `regenerate()` re-entrantly and asserts the older snapshot never reaches `write`.
2. **The presence dot on macOS is untested and unseen.** `GatewayPresenceMonitorTests` (20 tests) covers the monitor, but the Mac wiring the merge produced — `.task(id: presenceRef)` plus the `appearsActive` foreground arm now sitting alongside the branch's `workbenchDestinationIsActive` teardown, and the dot rendering beside `gatewayControl` inside the branch's Work gate — is view code no unit test reaches. Founder QA on macOS: with a gateway configured, confirm the dot appears left of the title-bar gateway control in Chats, is absent in Work (the zero-area placeholder must keep the Chats/Work control pinned to the trailing edge), and re-probes when the window is brought forward.
