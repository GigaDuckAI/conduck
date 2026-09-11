# Desk + CloudKit Byte Sync — FINAL Binding Plan (Codex-reviewed: SOUND WITH CHANGES; all 12 changes folded in)

Worktree `/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard` (IS the Conduck app repo; app code `Conduck/Conduck/`, tests `Conduck/ConduckTests/`). Branch `feature/agent-workboard` @ `651a859`, clean. Baseline gates: iOS 4750 executed / 0 fail / 2 skips; watch 229 / 0; signed macOS + iOS builds green.

Inputs: `scout-purge.md`, `scout-storage.md`, `scout-capture.md`, Codex review (`codex-desk-review.md`, verdict at EOF). Where this plan and a scout report disagree, this plan wins; where silent, the scout maps are authoritative.

## Product intent (founder-locked)
1. Work = ONE desk. No projects UI, no AI/dispatch/brief layer in code (git preserves history; Core Data entities stay — projects may return).
2. Users drop/arrange/resize voice notes, text, screenshots, files. Capture from every existing surface lands on the desk.
3. Everything syncs via CloudKit to the user's private iCloud — metadata already does; BYTES must now sync too. No company backend; "Data Not Collected" stays true.
4. Voice notes become playable AUDIO cards (bytes kept + synced), not transcript-only.

## A. Single-desk identity (binding)
- **Fixed compile-time UUID**: `Constants.workboardDeskItemID = UUID(uuidString: "DE5C0000-0000-4000-A000-000000000001")!` (QA-mode literal precedent). Mirrored as a literal into the Watch target with a comment naming Constants as canonical, plus a **source drift-guard test** that greps both literals for equality (Codex #10e).
- **No dedup/merge/prune pass.** `deduplicatedWorkItems` + `workItemID IN` material fetch already union materials across duplicate physical desk rows (`+Workboard.swift:1690-1729`, `:1606`). Never delete a desk row; `deleteWorkItem` dies in the purge.
- **Lazy creation on first capture.** The provisional-canvas UI survives as "desk before first material" with the rotating `emptyWorkspaceID` replaced by the fixed desk id.
- **ONE authoritative store op (Codex #1)**: new `ConversationStore.upsertDeskMaterial(...)` — in a single write-context call: ensure the desk row exists (create if absent), then idempotent material handling — same-id material exists → return it (repairing missing blob bytes if the caller carries them, see C-protocol); else insert. ALL surfaces route through it: first in-app capture (repository `importMaterial` initial path), Chat→Work, `CaptureWorkboardIntent`, drainer. `createWorkItemWithInitialMaterial`'s throw-on-existing branch is subsumed — refactor, don't merely patch the branch. The Watch mirrors the same fetch-desk-then-upsert logic locally in one context (raw Core Data; store extension file is not in the watch target).
- **VM loads ONLY the desk** (Codex #10b): the one-desk view model fetches by the fixed id — legacy model-15 project rows on dev devices must not surface (they stay in the store, invisible; projects may return later).
- **Desk row fields**: title/objective nil forever; nothing displays them. `workboard.chatCapture.{followUpObjective,longMessageObjective}` writers die.
- **Retarget map** (scout-capture §1, all 10 surfaces):
  - Composer/drop/pickers/text-sheet: desk id where `emptyWorkspaceID`/`item.id` flowed.
  - Chat→Work (`captureMessageToWork`): append via the upsert op, `message.id` stays the MATERIAL id for replay; no item mint, no objective inference; deep link resolves to the desk.
  - Drainer: resolve-the-desk via upsert op (`captureEnvelopeID: nil`); replay = deterministic material ids + upsert idempotency; `.done`-target/fallback branches + target-unavailable banner die. **Every envelope's note becomes a material, including the first targetless capture** — the current `appendsToExistingItem == true` gate would silently drop it (Codex #2).
  - **Cross-process inbox ownership (Codex #2)**: `WorkCaptureInbox.reconcile()`'s process-local `activeClaims` can requeue a directory another process is draining (app vs headless intent process). Add a filesystem lease / stale-claim horizon; test two independent inbox+drainer instances against one directory. Do NOT acknowledge a claim until the material (and blob when bytes ≤ ceiling) are durably readable (ties into C-protocol).
  - `CaptureWorkboardIntent` + watch intent: retarget to desk, identifiers STABLE. Watch: fetch-desk-then-upsert, 16k cap kept; its new assertions go INTO the existing `ConduckWatchSmokeTests.swift` (a new watch test file needs a manual target add — avoid it, Codex #11).
  - Menu-bar/GigaAction envelopes stay targetless; drainer resolves.
- CAS: only the VM's serialized path passes `expectedOwnerRevision`; drainer/upsert stays `nil`.

## B. Purge (scout-purge §1–§5 = the map; binding deltas)
- Delete-whole 8 files (2,425 LOC) + call sites: dispatch coordinator, WorkBriefAssistant, WorkBriefPromptBuilder, WorkboardBriefingBuilder, WorkboardUploadJournal (+4 `reconcile()` sites), WorkboardBriefingView, WorkboardDispatchSheet, BriefWorkboardIntent (+AppShortcuts entry; user-Shortcut breakage accepted — unshipped).
- **`WorkBriefMaterialPacket` re-home FIRST (Codex #10a)**: surviving repository mapping calls it at `WorkboardLiveRepository.swift:415`; move the material-kind/name mapping to a surviving home before deleting `WorkBriefPromptBuilder.swift`.
- `WorkboardDetailView` REPURPOSED as the desk (drop itemID lookup / focusedSceneValue / missing-item branch); `WorkboardSurface` = desk container; `WorkboardEmptyState` kept for the empty desk. Desk title = static "Work".
- `WorkboardView.swift` 1317→~250 per trim table; `WorkboardExperience` collapses; keep `.detailColumn` + `.presentationModifier` values (MainWindowView consumes them).
- **macOS shell rewrite specified (Codex #10c)**: Chat's sidebar is explicitly hidden while Work is active (`MainWindowView.swift:547`) — KEEP that behavior: Work mode = sidebar column collapsed/empty, desk fills the window; Chats mode = Chat sidebar returns. Work's own sidebar mount, ⌘⇧N button, 3 workboard `@SceneStorage` keys die. The measured toolbar-anchor stability (trailing-most section control, 1×1 clear principal slot) must survive — verify by macOS build + the existing toolbar tests mid-workflow, not only at the gate.
- VM/repository/store trims per scout §4–§5; `completeWorkspace` + completion/reopen fns die; `WorkItemStateResolver` dies, call sites read constant `.draft` (deliberate); `fetchRecentWorkItemSummaries` dies with the share picker.
- Known build-breakers handled in-wave: `WorkBriefFixtures` (+`WorkboardMaterialBoardActionsTests.swift:392-417`) · `ErrorSurfaceDriftGuardTests` registry rows (prune only rows whose surface died — DetailColumn load-retry + VoiceCaptureView survive) · `WorkboardMoveDirection`/`WorkboardReorderPlacement` keep material users.
- **Storage-seam allowlist**: remove the deleted `WorkboardUploadJournal.swift` row (hygiene, Codex #10d).
- Strings: ~163 candidate keys, but deletion governed by the bidirectional zero-reference audit AFTER the purge, not the scout list verbatim (its `workboard.load.*` rows are wrong — the loading/retry branch survives). Macro-composed `Add ${thought} to Work` SURVIVES (zero grep hits by design). Copy rewrites (keys kept): `workboard.item.untitled`, `workboard.error.staleDraft`, `ConversationListView.swift:344`, tutorial line 3 (§E).

## C. Byte sync — Shape B, `WorkMaterialBlob` (binding)
Why B: board projection realizes whole rows (`StoredWorkMaterial.init` touches `thumbnailData`; faulting is object-level) — payload-on-WorkMaterial loads every byte on every refresh. Storage scout + Codex both picked B.
- **Model `Conversations 16`** (never edit 15 — it exists on the founder's dev devices). New entity `WorkMaterialBlob`: `materialID` UUID · `payload` Binary external-storage · `byteSize` Int64 · `contentHash` String · `createdAt`/`updatedAt` Date. All optional, nil defaults, NO relationships, NO uniqueness constraints. Configurations `Core` (all pre-existing entities) + `Blobs` (blob only). v15→v16 schema-delta + SQLite round-trip tests per harness. **Registration: model 15 landed with NO pbxproj edit (synchronized group covers the xcdatamodeld) — do the same and PROVE the compiled `.momd` contains 16; only touch the project file if that proof fails** (Codex #11).
- **Watch exclusion via two stores, feasibility-gated in TWO parts (Codex #3)**:
  - **Gate 1 — headless, in-workflow (blocking)**: local harness proving (i) a default-configuration v15 store opens under named `Core` configuration in v16 with lightweight migration, rows intact; (ii) production-like two-SQLite topology: CRUD across both stores, reopen, migration re-run. These assertions land as real repo tests.
  - **Gate 2 — signed-device, FOUNDER QA (release-blocking, not workflow-blocking)**: real-CloudKit export/import across both stores, record-zone behavior, delete/reinstall reimport, actual watch exclusion, and the headless App Intent topology (TN3164 warns about multiple `NSPersistentCloudKitContainer` instances on one store across processes — pre-existing surface here, doubled by the second store). Ship a written checklist in the founder QA script; byte sync does not reach a release build without Gate 2.
  - **Fallback if Gate 1 refutes two-store (Codex #4)**: byte sync is BLOCKED this round — desk + purge + audio still ship with `.localVault` everywhere ("wrist gets every blob" is NOT an acceptable fallback: the ceiling bounds one material, not the aggregate). Another exclusion design would be a new session.
- **Policy authority**: `WorkMaterialStoragePolicy.mode(kind:byteSize:)` replaces the five duplicated `.localVault` decisions. **Ceiling = 30 MB** (`Constants.workboardSyncCeilingBytes`, tunable; deliberately below the only published (archived, 50 MB) figure; raise only on real-device evidence — Codex #8). `.localVault` + reattach stays first-class (share cap 256 MB). **Memory test**: assigning a large `Data` to the external-storage attribute must not blow peak memory — measure at the ceiling size.
- **`.syncedPayload` redefined** (no legacy rows exist): bytes live in the blob row; `WorkMaterial.payload` column stays unwritten. `loadWorkMaterialPayload(.syncedPayload)` reads the newest COMPLETE blob by `materialID`. Vault serves `.localVault` only — no double-write.
- **Crash-repairable publication protocol (Codex #5)** — two stores never commit atomically. Write order: (1) blob row saved durably FIRST, (2) material row with `.syncedPayload` second, (3) inbox claim acknowledged only after both are readable. Replay (the upsert op) repairs every partial state: blob-without-material (insert material) · material-`.syncedPayload`-without-blob (re-stage bytes if caller has them, else surface `.syncedPending`) · duplicate blobs (newest complete wins) · replayed material with mismatching hash/size (replace blob, paired) · `.localVault`↔`.syncedPayload` transition during reattach. Injected-failure tests between each step.
- **Blob GC = paired deletion ONLY (Codex #6)**: deleting a material deletes its blobs in the same logical operation. NO orphan sweep — CloudKit can import blob-before-material, and a sweep would export deletion of valid data. Orphaned blobs from crashes are accepted residue (rare; bounded); document at the deletion site.
- **Availability proves completeness (Codex #7)**: ONE batch fetch projecting `materialID` + `byteSize` + `contentHash` + `updatedAt` (never `payload`); a material is available iff a complete blob row (non-nil hash + size) exists; `.syncedPending` otherwise → "Waiting for iCloud…" chip, NON-available for opening/playback. Desk banner reads `CloudSyncMonitor.shared` (existing localized noAccount/restricted/quotaExceeded). FIX the per-material `await vault.contains` loops (`:1648-1651`, `:1575-1578`) with batch resolution (deadlock-precedent shape).
- Thumbnails unchanged (bounded, already synced) — cards render before blobs arrive.
- Sim/no-entitlement/QA stores: plain `NSPersistentContainer`, bytes stay local; no special-casing. Storage-seam script unaffected.
- `WorkAssetVault.swift` header (device-local stance, lines 6-14) rewritten to the new truth (Codex #12).

## D. Voice notes → audio cards — two-phase capture (Codex #9)
- Phase 1 (at `InAppAudioRecorder.swift:307-314`, before the STT hop): mint a STABLE material id, durably COPY the compressed file (16 kHz AAC, ≤15 MB) into the storage path (blob/vault per policy), and INSERT the audio card immediately — `kind: .audio` (String column, no model change), title placeholder via capture logic, no transcript yet. Never move/retain the temp URL (three `defer`s own it).
- Phase 2 (transcript arrives ~`:474` / STT completion): UPDATE the same material's `textContent` (+ caption/title). STT failure leaves a playable untranscribed card — audio is never lost to a transcription error.
- **Work voice retry path** (`ContentView.swift:1554` republishes transcript+screenshot): must repair/attach the SAME audio material by its stable id — never degrade to a note, never duplicate.
- Card UI: play/pause + progress + transcript caption; `AVAudioPlayer(data:)` per SpeechPlayer pattern (own small player). A11y labels. Chat voice untouched; watch voice→Work lane stays out of scope.

## E. Tutorial + copy + docs truth
- Tutorial survives; line 3 (`workboard.tutorial.point.review`) rewritten to the sync truth (collect · arrange · "stays in your iCloud, on all your devices" spirit; warm instruction; founder final pass).
- New strings (main catalog): syncedPending chip, desk banner hookup, audio card labels, rewritten keys.
- **spec.md truth (Codex #12)**: `docs/ai-context/spec.md:430` (Work file bytes device-local) and `:503` (audio not retained) become false — rewrite those decisions present-tense (and any source headers repeating them). Do NOT fix the pre-existing spec-size guard failure (19,830/16,900) — record it as pre-existing; cut nothing else.

## F. Tests + gate
- Purge per scout §6 (predicted ~4664 iOS incl. share picker, watch 229, 2 skips unchanged) + re-home the delete-all-preserves-materials invariant.
- NEW tests: v15→v16 ×2 · Gate-1 spike assertions (config open + two-store CRUD) · policy matrix · desk upsert (concurrent first captures; replay repair states; hash-mismatch) · inbox lease (two instances, one directory) · drainer desk-resolve + first-note-not-dropped · chat-capture append · watch upsert (inside existing smoke file) · blob paired-delete + no-sweep · availability completeness + `.syncedPending` + batch (no per-row await) · audio two-phase (immediate card, transcript update, STT-failure retention, retry repairs same id) · desk-UUID drift guard · external-storage memory at ceiling.
- GATE: signed macOS build · full iOS suite (0 fail / 2 skips; iPhone 17 Pro `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`) · watch suite serially (`28AC563B-42C1-4E66-940D-77E63B07918B`) · `scripts/check-storage-seam.sh` · `git diff --check` · string catalogs JSON-parse + mirror triplets byte-identical · bidirectional string audit. NEVER pass `-configuration` to test invocations. macOS build verified mid-workflow after the shell trim. Spec-size guard failure recorded as pre-existing, not fixed.

## G. Release gates (recorded, not this session)
1. Deploy model 16 to CloudKit Production (supersedes the model-15 cardSize gate); record beside APPLE-CD-V7-001.
2. **Gate 2 founder signed-device QA** (§C) before any release build carrying byte sync.

## Out of scope
Projects/AI return (schema dormant) · watch voice→Work · vocabulary pass · proactive quota accounting · desk-row pruning · blob orphan sweep · lazy blob download · Android · Chat-side changes · spec-size-guard debt.

## Standing constraints (all agents)
- NO git commits/pushes by agents, ever (orchestrator commits after gate).
- Builds/tests: derivedData under `~/Library/Caches/gigaduck-builds/<slug>` ONLY; ALWAYS end with `.claude/scripts/clean-build-cache.sh <slug>` (success OR fail); never bare `rm -rf`; never `/tmp`.
- Never touch the symlink `Conduck/Configs/Identity-Override.xcconfig`.
- New user-facing strings via `String(localized:defaultValue:)`, main catalog (watch/extension only when the code lives there); envelope/snapshot mirrors in byte-identical triplets or not at all.
- Comments state constraints, never changelog narration. Match style; reuse existing components. New Swift files need no pbxproj edits; new WATCH TEST files do (avoid — use the existing smoke file); model 16 registration proven from the compiled `.momd`.
