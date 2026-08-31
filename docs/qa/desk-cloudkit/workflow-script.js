// SPDX-License-Identifier: Apache-2.0

export const meta = {
  name: 'desk-cloudkit-build',
  description: 'Single-desk Workboard: purge AI/project layer, CloudKit byte sync, audio cards',
  phases: [
    { title: 'Spike', detail: 'two-store/named-configuration feasibility (Gate 1)' },
    { title: 'Foundation', detail: 'model 16, policy, constants, record types' },
    { title: 'PurgeCore', detail: 'VM + repository + store layer' },
    { title: 'PurgeViews+Desk', detail: 'views/shell purge ∥ desk identity + capture retarget' },
    { title: 'ByteSync+Share+Tests', detail: 'blob sync ∥ share picker removal ∥ test surgery' },
    { title: 'Audio', detail: 'voice notes as two-phase audio cards' },
    { title: 'Strings', detail: 'zero-ref audit + copy + spec truth' },
    { title: 'Review', detail: 'fresh-eyes adversarial pass over the full diff' },
    { title: 'Fix', detail: 'apply confirmed findings' },
    { title: 'Gate', detail: 'signed macOS build + full iOS/watch suites + hygiene' },
  ],
}

const WT = '/Users/peterkruck/repos/GigaDuck/.codex/worktrees/conduck-agent-workboard'
const SP = '/private/tmp/claude-501/-Users-peterkruck-repos-GigaDuck/fe7dc45a-334d-4b12-9347-6762bf751362/scratchpad'
const PLAN = SP + '/desk-cloudkit-plan.md'
const FIX = SP + '/desk-fixnotes'

const COMMON = `
Worktree ${WT} — this IS the Conduck app repo (app code Conduck/Conduck/, tests Conduck/ConduckTests/, project Conduck/Conduck.xcodeproj). Branch feature/agent-workboard. Work ONLY in this directory.
BINDING PLAN: read ${PLAN} FIRST, in full. Scout maps beside it: scout-purge.md, scout-storage.md, scout-capture.md — read the sections your task names. Where plan and scouts disagree, the plan wins.
FIXNOTES CONTRACT: read every file in ${FIX}/ before starting (earlier agents' decisions bind you). When done, Write ${FIX}/<your-label>.md: what changed (file:line), decisions, deviations-with-why, what the next agent must know. Final message = ≤20-line summary.
STANDING RULES (violations fail review):
- NO git commits, NO pushes, NO git stash. Never touch the symlink Conduck/Configs/Identity-Override.xcconfig.
- Builds/tests: derivedData ONLY under ~/Library/Caches/gigaduck-builds/<your-slug>; ALWAYS finish (success OR fail) with ${WT}/.claude/scripts/clean-build-cache.sh <your-slug>; never bare rm -rf; never /tmp.
- xcodebuild test / build-for-testing: NEVER pass -configuration (scheme selects Debug-Testing; CONDUCK_TESTING hooks exist only there). iOS sim: iPhone 17 Pro UDID 04DEF4F5-C144-4936-AEC3-A971B4FA9CDC. zsh: quote everything; unquoted $VAR stays ONE arg.
- New user-facing strings via String(localized:defaultValue:) in the MAIN catalog Conduck/Conduck/Localizable.xcstrings (watch/extension catalogs only when the code lives there). Envelope/snapshot mirror files (WorkCaptureEnvelope.swift ×3, ShareTargetsSnapshot.swift ×3) change in byte-identical triplets or not at all.
- Comments state constraints only — no was/now narration. Match surrounding style; reuse existing components. New Swift files need no pbxproj edits; a new WATCH TEST file DOES (avoid — use the existing smoke file); model 16 registration must be PROVEN from the compiled .momd, not assumed to need project edits.
- Before returning: your slice must COMPILE — run an iOS build (or build-for-testing) and fix what you broke. You may consult Codex once for a hard call: cd ${WT} && codex exec --sandbox read-only "<question>".
`

// ---------- Phase 1: Spike (Gate 1) ----------
phase('Spike')
const spike = await agent(`${COMMON}
TASK: plan §C "Gate 1 — headless, in-workflow". Scratch harness code lives ONLY under ~/Library/Caches/gigaduck-builds/desk-spike/ (clean it at the end); repo stays untouched except you MAY stage nothing — read-only in the repo.
(a) PROVE locally with a standalone harness (swift package/swiftc, mini-model mimicking the real shape): a v1 SQLite store created under the DEFAULT model configuration opens under a NAMED configuration 'Core' in v2 (v2 adds configs 'Core' = old entities, 'Blobs' = one new entity) with lightweight migration, rows intact; then production-like two-SQLite topology: CRUD both stores, close, reopen, re-migrate. Record the exact recipe (how descriptions/configurations are declared) — the Foundation and ByteSync agents will replicate it in the app.
(b) RESEARCH (documented fact vs inference, cite): two NSPersistentCloudKitContainer store descriptions mirroring the SAME private database/containerIdentifier — zone-per-store behavior, documented support, known pitfalls; plus TN3164's warning about multiple container instances on one store across processes (this app's headless App Intent process shares the store) — what mitigation does Apple prescribe? Sources: developer.apple.com docs/technotes/WWDC; Context7 if useful.
(c) DRAFT the Gate-2 founder signed-device checklist (plan §C) into your fixnotes: real-CloudKit export/import both stores, zone check, delete/reinstall reimport, watch exclusion, headless-intent behavior.
VERDICT in ${FIX}/spike.md AND as the LAST LINE of your final message, exactly one word: FEASIBLE or REFUTED. REFUTED ⇒ byte sync is BLOCKED this round (plan forbids the wrist fallback); desk/purge/audio proceed on .localVault.`,
  { label: 'spike', phase: 'Spike', model: 'opus', effort: 'high' })
const spikeText = typeof spike === 'string' ? spike : JSON.stringify(spike)
const syncBlocked = !/FEASIBLE\s*$/.test((spikeText || 'REFUTED').trim())
log(syncBlocked ? 'Spike REFUTED two-store design — byte sync BLOCKED this round, building desk on .localVault' : 'Spike FEASIBLE — full byte-sync build proceeds')
const SYNCNOTE = syncBlocked
  ? 'BYTE SYNC IS BLOCKED THIS ROUND (spike refuted two-store): NO model 16, NO blob entity, NO policy switch — storage stays .localVault everywhere. Skip every blob/sync item in your task; the rest stands.'
  : 'Byte sync is GO (spike feasible): follow plan §C fully.'

// ---------- Phase 2: Foundation ----------
phase('Foundation')
await agent(`${COMMON}
${SYNCNOTE}
TASK: plan §C foundation. Read ${FIX}/spike.md FIRST and replicate its proven recipe exactly.
1. (sync GO only) New model version 'Conversations 16' (copy of 15 — NEVER edit 15): entity WorkMaterialBlob (materialID UUID, payload Binary allowsExternalBinaryDataStorage, byteSize Int64, contentHash String, createdAt Date, updatedAt Date — ALL optional, nil defaults, NO relationships, NO uniqueness constraints) + configurations 'Core' (all pre-existing entities) and 'Blobs' (blob only). Flip .xccurrentversion. PROVE registration from the compiled .momd (build, inspect Conversations.momd contents); only touch pbxproj if that proof fails.
2. Constants.swift: workboardDeskItemID = UUID("DE5C0000-0000-4000-A000-000000000001"); (sync GO only) workboardSyncCeilingBytes = 30 MB, tunable, comment: below the archived 50 MB figure, raise only on device evidence.
3. (sync GO only) New Services/Workboard/WorkMaterialStoragePolicy.swift: mode(kind:byteSize:) → .syncedPayload iff 0 < byteSize ≤ ceiling else .localVault; unit-test matrix in a new test file.
4. WorkboardRecords.swift ADDITIONS ONLY (purge agent deletes other symbols later — delete NOTHING): WorkMaterialKind.audio raw value + decode; (sync GO) WorkMaterialBlobRecord struct per house record patterns + availability groundwork for a .syncedPending state (note in fixnotes where the projection change must land).
5. (sync GO only) Migration tests per harness pattern: v15→v16 schema delta (added entity set == [WorkMaterialBlob], nothing dropped, external-storage assertion) + SQLite round trip (v15 rows → reopen under 16 'Core' + fresh Blobs store → intact + blob writable) — replicate the spike recipe as REAL repo tests.
Run your new tests targeted; report counts.`,
  { label: 'foundation', phase: 'Foundation', model: 'opus', effort: 'high' })

// ---------- Phase 3: PurgeCore ----------
phase('PurgeCore')
await agent(`${COMMON}
TASK: plan §B core purge — scout-purge §4 (WorkboardViewModel), §5 (repository + store), §1 service/intent files. PRESERVE every Foundation addition (read ${FIX}/foundation.md).
- FIRST (Codex #10a): re-home the material-kind/name mapping that WorkboardLiveRepository.swift:415 takes from WorkBriefMaterialPacket into a surviving home; THEN delete whole: WorkboardDispatchCoordinator.swift, WorkBriefAssistant.swift, WorkBriefPromptBuilder.swift, WorkboardBriefingBuilder.swift, WorkboardUploadJournal.swift, Intents/BriefWorkboardIntent.swift (+AppShortcuts.swift entry).
- WorkboardViewModel.swift per scout §4a–d: 13 dying Dependencies closures, dying published state/methods/types; completeWorkspace + WorkboardVoiceTarget.objective die; the 9 surviving closures + capture/board machinery stay.
- WorkboardLiveRepository.swift per scout §5; new init signature without dispatch/shapeDraft/readBriefingAloud/stopBriefingAloud.
- ConversationStore+Workboard.swift: delete orphaned fns per scout §5 table; KEEP everything plan §A/§C needs (unsure → KEEP + note). WorkItemStateResolver dies; its two call sites read constant .draft; delete resolver + orphaned dispatch types from WorkboardRecords.swift (NOT WorkItemState, NOT Foundation's additions). fetchRecentWorkItemSummaries: DELETE (note for share agent).
- scripts/check-storage-seam.sh: remove the WorkboardUploadJournal allowlist row.
- DO NOT touch view files, other intents, watch, share, drainer. Tests: only if a deleted symbol breaks ConduckTests COMPILATION may you delete dead test FILES from scout §6 'dies entirely'; note exactly which; leave split files alone even if red.
Compile the APP for iOS (test bundle may be temporarily red — say so in fixnotes).`,
  { label: 'purge-core', phase: 'PurgeCore', model: 'opus', effort: 'high' })

// ---------- Phase 4: PurgeViews ∥ Desk ----------
phase('PurgeViews+Desk')
await parallel([
  () => agent(`${COMMON}
TASK: plan §B view/shell purge — scout-purge §2 trim tables are the map; ${FIX}/purge-core.md has the new repository init signature. Files you OWN: WorkboardView.swift, WorkboardComponents.swift, WorkboardCaptureCanvas.swift, PersonalWorkbenchView.swift, MainWindowView.swift, WorkboardDetailView.swift, WorkboardBriefingView.swift + WorkboardDispatchSheet.swift (delete whole), ConduckApp.swift + AppDelegate.swift (call-site pruning), WorkboardVoiceCaptureView.swift (only if forced).
- WorkboardView 1317→~250 per trim table; WorkboardExperience collapses to one pane; keep .detailColumn + .presentationModifier values.
- MainWindowView per plan §B macOS spec (Codex #10c): Work active = sidebar column collapsed/empty, desk fills the window (Chat's sidebar already hides at :547 — KEEP that); Chats = Chat sidebar returns. Work sidebar mount + ⌘⇧N + 3 workboard @SceneStorage keys die. Toolbar-anchor stability (trailing-most section control, 1×1 clear principal slot) MUST survive. HIGHEST RISK: after edits run a macOS build and fix breakage before returning.
- WorkboardDetailView = the desk: drop itemID lookup/focusedSceneValue/missing-item branch; static "Work" title; renders the fixed-id desk (Desk agent wires capture; you wire display).
- WorkboardComponents per trim table (Card/state-presentation/project-commands die; Surface/EmptyState/MaterialIcon/MaterialActions/metrics survive; .conduckWorkboardCard UTType dies, .conduckWorkboardMaterial survives).
- WorkboardCaptureCanvas: .full mode + reviewAndSend + expandedComposer + isReadyToSend gate die; WorkboardCaptureDestination collapses to one title-free case.
- PersonalWorkbenchView: BriefingSpeaker + shapingHandler die; repository init updated; reconcileDurableWorkStorage keeps only reconcileWorkAssetVault; routeWorkboardDeepLink resolves to the desk.
- ConduckApp/AppDelegate: WorkboardProjectCommands + 4 UploadJournal call sites die; ⌘1/⌘2 stay.
Verify iOS AND macOS builds compile before returning (test bundle may be red — note it).`,
    { label: 'purge-views', phase: 'PurgeViews+Desk', model: 'opus', effort: 'high' }),
  () => agent(`${COMMON}
${SYNCNOTE}
TASK: plan §A desk identity + capture retarget. Read ${FIX}/purge-core.md first. Files you OWN: ConversationStore+Workboard.swift (surviving fns), WorkCaptureInbox.swift, WorkCaptureDrainer.swift, Intents/CaptureWorkboardIntent.swift, ConduckWatch Watch App/WorkboardCaptureIntent.swift, ConversationThreadView.swift (captureMessageToWork call area), WorkboardViewModel/Repository ONLY where the desk id replaces emptyWorkspaceID/beginWorkspace plumbing (coordinate via fixnotes; purge-views owns the view files). NEW test files (iOS) + the EXISTING ConduckWatchSmokeTests.swift for watch assertions (never a new watch test file).
- ONE authoritative op (Codex #1): ConversationStore.upsertDeskMaterial(...) — single write context: ensure desk row (create if absent) → same-id material exists ? return it (repair missing blob bytes if caller carries them) : insert. Subsumes createWorkItemWithInitialMaterial's throw-on-existing branch (refactor). ALL surfaces route through it: repository importMaterial initial path, captureMessageToWork (message.id stays MATERIAL id; no item mint; no objective inference; deep link → desk), CaptureWorkboardIntent, drainer.
- VM loads ONLY the fixed desk id (Codex #10b) — legacy model-15 project rows must not surface.
- Drainer: resolve desk via upsert (captureEnvelopeID: nil); .done/fallback branches + target-unavailable copy die; EVERY envelope's note becomes a material incl. the first targetless capture (the appendsToExistingItem gate would drop it — Codex #2); NO CAS in the drainer.
- Inbox cross-process ownership (Codex #2): add a filesystem lease / stale-claim horizon to WorkCaptureInbox.reconcile() so one process cannot requeue a directory another is draining; claim acknowledged only after material (+blob when sync GO) durably readable. Test with two independent inbox+drainer instances on one directory.
- Watch intent: fetch-desk-then-upsert in one context (raw Core Data; mirror the desk-id literal, comment naming Constants canonical); identifier stable; 16k cap kept.
- Tests (NEW iOS files + watch smoke file): concurrent first captures both survive; upsert replay-repair states; drainer resolve + first-note-not-dropped; inbox two-instance lease; chat-capture append; watch upsert; desk-UUID drift guard (grep main vs watch literals). Run targeted; report counts.
Compile iOS + run your new tests before returning.`,
    { label: 'desk', phase: 'PurgeViews+Desk', model: 'opus', effort: 'high' }),
])

// ---------- Phase 5: ByteSync ∥ Share ∥ TestSurgery ----------
phase('ByteSync+Share+Tests')
const phase5 = [
  () => agent(`${COMMON}
TASK: plan §A share-picker removal (6-file lockstep) — scout-purge R4 + scout-capture §1#6. Files you OWN: ConduckShareExtension/ShareView.swift + ShareViewController.swift, ConduckShareExtensionMac/ same, both extension Localizable.xcstrings, ShareTargetsSnapshotWriter.swift, mirror-guard tests (WorkCaptureInboxTests.swift:311 area, ShareTargetsSnapshot*Tests as needed).
- Delete the Work destination picker in BOTH ShareViews; appex always writes targetWorkItemID nil ("Add to Work" one-tap). KEEP the targetWorkItemID FIELD in all three envelope copies (no envelope edits if avoidable).
- ShareTargetsSnapshotWriter: stop producing recentWorkItems (fetchRecentWorkItemSummaries is gone — ${FIX}/purge-core.md); prefer writing an empty array over touching the 3-way snapshot mirrors; decide + document.
- Remove the 5 share.work.* picker keys from BOTH extension catalogs; update the six-file lockstep string test to the new truth; trim affected share tests per scout §6.
Build iOS (extensions build with the app) + run share-related test files targeted.`,
    { label: 'share', phase: 'ByteSync+Share+Tests', model: 'opus', effort: 'high' }),
  () => agent(`${COMMON}
TASK: test surgery for the purge — scout-purge §6 is the map; ${FIX}/ fixnotes list what actually died and which NEW test files exist (off-limits). Files you OWN: Conduck/ConduckTests/ EXCEPT new files by foundation/desk/bytesync agents; ConduckWatchTests only if needed (expect zero).
- Delete the 6 dies-entirely files; excise dying cases from the 6 split files (WorkspaceCapture −12, Persistence −12/13, BoardProjection −9, MaterialBoardActions −3 incl. :392-417 WorkBriefFixtures consumer, LiveRepositorySupport −3, AtomicWorkCapture −1). Verify WorkBriefFixtures has no surviving consumer.
- Re-home the surviving invariant of testDeleteAllConversationsPreservesBriefMaterialsAndTombstonesRun (delete-all preserves Work materials).
- ErrorSurfaceDriftGuardTests registry: prune ONLY rows whose surface died (DetailColumn load-retry + VoiceCaptureView survive — verify against post-purge code).
- Fix compile breakage in surviving test files from deleted symbols; adapt assertions to desk semantics; never weaken an unrelated assertion.
Then run the FULL iOS suite once (no -configuration); report executed/failed/skipped EXACTLY.`,
    { label: 'test-surgery', phase: 'ByteSync+Share+Tests', model: 'opus', effort: 'high' }),
]
if (!syncBlocked) phase5.unshift(
  () => agent(`${COMMON}
TASK: plan §C byte sync (spike verdict FEASIBLE — replicate its recipe; read ${FIX}/spike.md + foundation.md + purge-core.md + desk.md). Files you OWN: ConversationStore.swift (two store descriptions: Conversations.sqlite='Core', Conversations-Blobs.sqlite='Blobs', same CloudKit options, watchOS loads Core ONLY; test/QA in-memory + screenshot seams keep working), ConversationStore+Workboard.swift (policy application, blob read/write, availability batch, paired GC), WorkboardLiveRepository.swift (projection), WorkAssetVault.swift (header truth rewrite, lines 6-14), WorkboardCaptureCanvas.swift ONLY the availability chip/badge area + desk banner hookup (CloudSyncMonitor.shared, reuse its localized reasons), NEW test files only.
- Writers: route the five .localVault decision sites through WorkMaterialStoragePolicy; ≤30 MB → blob row + .syncedPayload; vault ONLY for .localVault; WorkMaterial.payload column stays unwritten.
- Publication protocol (Codex #5): blob durably saved FIRST → material .syncedPayload second → inbox ack last (coordinate with desk agent's upsert — repair hooks live there; read its fixnotes). Replay repairs: blob-no-material, material-no-blob (→.syncedPending), duplicate blobs (newest COMPLETE wins), hash/size mismatch (paired replace), localVault↔syncedPayload reattach transition. Injected-failure tests between steps.
- GC: PAIRED deletion only (material delete removes its blobs in the same logical op); NO orphan sweep (CloudKit imports blob-before-material; a sweep would export deletion of valid data) — document at the deletion site.
- Availability completeness (Codex #7): ONE batch fetch projecting materialID+byteSize+contentHash+updatedAt (NEVER payload); available iff a complete blob exists; .syncedPending otherwise, NON-available for open/playback. Replace the per-material await vault.contains loops (+Workboard.swift:1648-1651, :1575-1578) with batch resolution.
- Memory test: assigning ceiling-sized Data to the external-storage attribute — bounded peak memory.
- loadWorkMaterialPayload(.syncedPayload) reads newest complete blob. Thumbnails unchanged. Sim/QA stores: plain container, bytes local, no special-casing.
Tests in NEW files only. Run targeted; report counts.`,
    { label: 'bytesync', phase: 'ByteSync+Share+Tests', model: 'opus', effort: 'high' }))
await parallel(phase5)

// ---------- Phase 6: Audio ----------
phase('Audio')
await agent(`${COMMON}
${SYNCNOTE}
TASK: plan §D two-phase audio cards. Read ${FIX}/foundation.md, desk.md${syncBlocked ? '' : ', bytesync.md'}, purge-views.md. Files you OWN: InAppAudioRecorder.swift, WorkboardVoiceCaptureView.swift, WorkboardCaptureCanvas.swift (card UI + voice hand-off), ContentView.swift ONLY the Work voice retry path (:1554 area), a NEW small player helper + card view file, WorkboardViewModel.swift ONLY the voice hand-off, NEW test files.
- Phase 1 (InAppAudioRecorder.swift:307-314, BEFORE the STT hop): mint a STABLE material id, durably COPY the compressed file into storage (policy lane${syncBlocked ? ' — .localVault this round' : ''}), INSERT the audio card immediately (kind .audio, placeholder title, no transcript). Never move/retain the temp URL (three defers own it).
- Phase 2 (STT completion ~:474): UPDATE the same material's textContent/caption. STT failure leaves a playable untranscribed card — audio never lost to transcription errors.
- Work voice retry (ContentView.swift:1554): repair/attach the SAME audio material by stable id — never degrade to a note, never duplicate.
- Card UI: play/pause + progress + transcript caption; AVAudioPlayer(data:) per SpeechPlayer pattern (own small player; don't touch SpeechPlayer); a11y labels; strings in main catalog.
- Tests: immediate card, transcript update, STT-failure retention, retry-repairs-same-id, temp-file defers untouched. Run targeted.
Compile iOS + run your tests before returning.`,
  { label: 'audio', phase: 'Audio', model: 'opus', effort: 'high' })

// ---------- Phase 7: Strings + docs truth ----------
phase('Strings')
await agent(`${COMMON}
${SYNCNOTE}
TASK: plan §B strings + §E copy/docs truth. Read ALL fixnotes. Files you OWN: Conduck/Conduck/Localizable.xcstrings, WorkboardTutorialView.swift (copy only), ConversationListView.swift:344 copy, docs/ai-context/spec.md (truth edits only), affected source headers not owned earlier.
- BIDIRECTIONAL zero-reference audit over the post-purge code (rg every candidate key from scout-purge §7 against all Swift/intent files; then rg surviving workboard.* usages against the catalog). Delete only audit-confirmed-dead keys. "Add \${thought} to Work" is macro-composed — zero grep hits BY DESIGN, SURVIVES. Extension catalogs: verify the share agent removed the 5 picker keys; don't duplicate.
- Copy rewrites (keys kept): workboard.item.untitled (no "brief"), workboard.error.staleDraft, ConversationListView briefs line, tutorial point 3 → sync truth${syncBlocked ? ' (careful: byte sync is BLOCKED — keep the tutorial truthful about device-local files)' : ' ("stays in your iCloud, on all your devices" spirit)'} — warm instruction, founder does final pass.
- spec.md truth (Codex #12): rewrite the decisions at ~:430 (Work file bytes device-local) and ~:503 (audio not retained) to the new end-state, present tense, no changelog narration${syncBlocked ? ' (bytes remain device-local this round — update ONLY the audio-retention truth)' : ''}. Do NOT fix the pre-existing spec-size guard failure (19,830/16,900); do not add prose beyond the truth edits.
- Verify all 4 catalogs parse as JSON (python json.load — plutil false-fails on xcstrings); report key counts before/after.
Compile iOS before returning.`,
  { label: 'strings', phase: 'Strings', model: 'opus', effort: 'high' })

// ---------- Phase 8: Review ----------
phase('Review')
const FINDINGS = {
  type: 'object', additionalProperties: false,
  properties: {
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: {
        file: { type: 'string' }, line: { type: 'integer' },
        severity: { type: 'string', enum: ['critical', 'major', 'minor'] },
        summary: { type: 'string' }, fix: { type: 'string' },
      }, required: ['file', 'severity', 'summary', 'fix'] } },
  }, required: ['findings'],
}
const reviewLenses = [
  { key: 'correctness', focus: 'desk identity + capture correctness: the single upsert op used by ALL surfaces; race/replay/idempotency across app, drainer, watch, intents; inbox lease; first-note-not-dropped; CAS discipline; VM desk-only load; dangling refs to purged symbols' },
  { key: 'sync', focus: 'storage correctness: ' + (syncBlocked ? 'byte sync was BLOCKED (spike refuted) — verify NO blob/model-16/policy remnants shipped, .localVault everywhere, tutorial/spec claims truthful' : 'two-store setup vs spike recipe, publication protocol order (blob→material→ack), replay repair states, PAIRED GC only (no sweep), availability completeness batch (no per-row awaits — deadlock precedent), policy at every ingest site, watch exclusion, sim/QA seams, model 16 vs migration-test invariants, memory at ceiling') },
  { key: 'surface', focus: 'UI/shell + purge completeness: macOS MainWindowView per plan §B spec (sidebar collapsed in Work, toolbar anchor stable), desk on all platforms, dead code left behind, strings (dead keys gone, live keys present, mirrors byte-identical), audio two-phase UX + a11y, spec.md truth edits, plan trim-table conformance' },
]
const reviews = await parallel(reviewLenses.map(l => () =>
  agent(`FRESH EYES adversarial review — you did NOT write this code. Worktree ${WT} (Conduck app repo). Read ${PLAN} (binding), then review the ENTIRE uncommitted diff (git status; git diff HEAD; new untracked files) against it. Lens: ${l.focus}. Hunt real defects: gate-breakers (signed macOS build, full iOS+watch suites 0-fail), plan violations, data corruption, regressions of surviving behavior. Verify each suspicion against actual code before reporting; ≤12 findings, highest severity first; no style nits. Read-only — change nothing.`,
    { label: 'review:' + l.key, phase: 'Review', model: 'opus', effort: 'high', schema: FINDINGS })))
const allFindings = reviews.filter(Boolean).flatMap(r => r.findings)
const serious = allFindings.filter(f => f.severity !== 'minor')
log(`Review: ${allFindings.length} findings (${serious.length} critical/major)`)

// ---------- Phase 9: Fix ----------
phase('Fix')
if (allFindings.length > 0) {
  await agent(`${COMMON}
TASK: apply the reviewers' findings. FINDINGS (JSON): ${JSON.stringify(allFindings)}
For each: verify it is real; fix faithfully to the plan; refutations recorded with evidence in ${FIX}/fix.md — never fix by weakening a test or deleting an assertion. Minor: fix if cheap+safe, else skipped-with-reason. Compile iOS + macOS and run the test files nearest your edits before returning.`,
    { label: 'fix', phase: 'Fix', model: 'opus', effort: 'high' })
} else {
  log('No findings — skipping fix phase')
}

// ---------- Phase 10: Gate ----------
phase('Gate')
const gate = await agent(`${COMMON}
TASK: the full gate. Run each step, quote exact result lines; on failure STOP and diagnose (fix ONLY clear one-line breakage; structural problems get reported, not patched).
1. Signed macOS build: scheme Conduck, destination generic/platform=macOS (normal Debug build, no test flags).
2. Full iOS suite: xcodebuild test, scheme Conduck, sim 04DEF4F5-C144-4936-AEC3-A971B4FA9CDC, NO -configuration. Report executed/failures/skipped EXACTLY (grep the "Executed N tests" suite lines; quote everything in zsh).
3. Watch suite SERIALLY after iOS: ConduckWatchTests, sim 28AC563B-42C1-4E66-940D-77E63B07918B. Report counts.
4. ${WT}/scripts/check-storage-seam.sh — must pass. Note: the spec-size guard (check-spec-size.sh) fails PRE-EXISTING at 19,830/16,900 — record, don't fix.
5. git diff --check (whitespace) · all 4 string catalogs parse via python json.load · envelope + snapshot mirror triplets byte-identical (cmp).
6. git status --short — flag anything outside the expected surface.
Write ${FIX}/gate.md with every number. Final message: PASS/FAIL + the numbers. Clean your build cache dir.`,
  { label: 'gate', phase: 'Gate', model: 'opus', effort: 'high' })

return {
  syncBlocked,
  findings: allFindings.length,
  serious: serious.length,
  gate: typeof gate === 'string' ? gate.slice(0, 2000) : gate,
}
