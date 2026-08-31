# Desk + CloudKit Byte Sync — Continuation Handoff

**Status: PARKED mid-build, at a clean checkpoint.** The founder stopped the build workflow after 2 of 10 phases (2026-08-31). Everything committed at this tip is coherent and verified; nothing is half-edited. This document is the single entry point for resuming.

## What this branch is

`feature/agent-workboard` — the Workboard feature, redirected across several founder QA rounds into a radically simpler product: **Work = one desk.** A single space where the user drops, arranges, and resizes voice notes, text, screenshots, and files. No projects UI, no AI/dispatch/brief layer. Bytes sync via CloudKit to the user's private iCloud (no company backend; "Data Not Collected" stays true). Voice notes become playable audio cards.

Commit chain (all local, never pushed): `96493f7` Codex base → `192b3fc` cleanup → `a2f7569` free card board + tutorial → `6ec69e7` desk-only surface → `23d975c` bare desk → `651a859` headingless desk → **this checkpoint** (foundation slice + these docs).

## Where the build stopped — phase status

The build ran as a 10-phase orchestrated workflow (`docs/qa/desk-cloudkit/workflow-script.js` — the exact script, still the best build map):

| # | Phase | Status |
|---|---|---|
| 1 | Spike (two-store/named-configuration feasibility) | ✅ DONE — **FEASIBLE**, repo untouched; recipe + pitfalls in `desk-cloudkit/spike-fixnote.md` |
| 2 | Foundation (model 16, desk constants, storage policy, records, migration tests) | ✅ DONE + COMMITTED — see `desk-cloudkit/foundation-fixnote.md` |
| 3 | PurgeCore (VM + repository + store layer) | ❌ not started (agent was killed before its first edit) |
| 4 | PurgeViews ∥ Desk (shell purge ∥ desk identity + capture retarget) | ❌ |
| 5 | ByteSync ∥ Share-picker removal ∥ Test surgery | ❌ |
| 6 | Audio cards (two-phase capture) | ❌ |
| 7 | Strings + spec truth | ❌ |
| 8–10 | Adversarial review → Fix → Full gate | ❌ |

## What is committed at this tip

Foundation slice (verified by its agent: iOS build-for-testing **and** macOS build succeeded; targeted tests 13/13; storage-seam script clean):

- **`Conversations 16` model** — new version (15 untouched): entity `WorkMaterialBlob` (materialID/payload external-storage/byteSize/contentHash/createdAt/updatedAt, all optional, no relationships, no uniqueness) + CloudKit configurations `Core` (7 pre-existing entities) and `Blobs` (blob only). `.xccurrentversion` → 16. Registration proven from the compiled `.momd`, no pbxproj edit.
- **`Constants.workboardDeskItemID`** = `DE5C0000-0000-4000-A000-000000000001` (the single desk's fixed id) and **`workboardSyncCeilingBytes`** = 30 MB (tunable; deliberately below the archived 50 MB CKAsset figure).
- **`WorkMaterialStoragePolicy`** (new, no call sites yet) — the single ≤ceiling→`.syncedPayload` / else `.localVault` authority.
- **`WorkboardRecords.swift` additions** — `WorkMaterialKind.audio`, `WorkMaterialAvailability.syncedPending`, `WorkMaterialBlobRecord` (with `isComplete`).
- **Migration tests** — v15→v16 schema delta + real two-store SQLite round trip (ported from the spike harness).
- New string key `workboard.material.syncPending` ("Waiting for iCloud…").
- Two one-line exhaustive-switch additions in `WorkBriefPromptBuilder`/`WorkboardDispatchCoordinator` — those files DIE in phase 3; the additions exist only to keep this tip compiling.

**Verification honesty:** the full iOS/watch suites were NOT re-run on this tip. Baseline at `651a859`: iOS 4750 executed / 0 failures / 2 skips; watch 229 / 0. Foundation is purely additive (+9 tests expected), but run the full gate before trusting the tip.

## How to resume

1. Launch `claude` from the monorepo root, then work in this worktree. Read this file, then `desk-cloudkit/plan.md` **in full** — it is the binding plan (Codex-reviewed: SOUND WITH CHANGES, all 12 changes folded in; verdict extract in `desk-cloudkit/codex-plan-review.md`).
2. The scout maps (`scout-purge.md` = the exact delete/trim/test/strings map with file:line; `scout-storage.md` = the storage seam; `scout-capture.md` = all 10 capture surfaces + single-desk design) date from `651a859`. They stay accurate until phase 3 starts editing; re-verify line numbers opportunistically.
3. Re-launch the workflow from `desk-cloudkit/workflow-script.js`, **dropping phases 1–2** (their outputs are committed; their fixnotes live in this directory — point the script's `FIX` dir here or copy these fixnotes into the new session's fixnotes dir so later agents read them). The old run id is useless across sessions.
4. Phase-3+ agents must respect the "Binding for the agents after me" sections in both fixnotes — especially: the `.syncedPending` projection lands at `MaterialRow.record(availableLocalKeys:)` (`ConversationStore+Workboard.swift` ~:2202), reuse `workboard.material.syncPending`, ByteSync replicates the spike's store-description recipe exactly (`#if !os(watchOS)` around the Blobs description IS the watch exclusion), and the Watch desk-id literal + drift-guard test are still TODO.

## Open items the plan already decides (don't re-litigate)

- Single desk = fixed UUID, **no dedup/merge pass** (projection already unions duplicate rows); lazy creation; one authoritative `upsertDeskMaterial` op for all four capture processes; drainer gets a filesystem lease (cross-process inbox race is real).
- Blob GC = **paired deletion only, no orphan sweep** (a sweep would export deletion of valid CloudKit data).
- Audio = two-phase (card appears instantly, transcript fills in; STT failure never loses audio; the Work voice retry path must repair the same material).
- If anything refutes the two-store design late: byte sync is **blocked**, not downgraded — "every blob on the wrist" was explicitly rejected.

## Two flags raised by the spike (for the next orchestrator)

1. **The zone question is genuinely undocumented**: two mirrored stores, same container, same `.private` scope — one shared zone or two? It is Gate 2 step 5 (below). Documented fallback if it goes badly: a second CloudKit container identifier for the Blobs store (config change, not a redesign — needs portal + both entitlements files + a second Production deploy).
2. **TN3164 hardening (plan-adjacent, pre-existing surface)**: Apple prescribes that only the app process attach `cloudKitContainerOptions`; the headless intent/extension processes should load the store mirror-less. Worth folding into the ByteSync phase.

## Release gates (unchanged discipline)

1. **Deploy model 16 to CloudKit Production** before any release carrying these entities (supersedes the model-15 `cardSize` gate; `origin/main` ships model 13, so one deploy covers all). Record beside APPLE-CD-V7-001.
2. **Gate 2 — founder signed-device QA** (release-blocking for byte sync): the full 18-step checklist is in `desk-cloudkit/spike-fixnote.md` §(c) — zones, import/export, delete/reinstall, watch exclusion, headless-intent 134410, quota/signed-out.
3. Rebase/merge onto Conduck `main` before integration (brings the `fetchRecentForPicker` deadlock fix this branch predates). Never push unasked.

## Standing constraints (any future agent)

Build caches under `~/Library/Caches/gigaduck-builds/<slug>` + `clean-build-cache.sh` always · never pass `-configuration` to xcodebuild test/build-for-testing · iOS sim iPhone 17 Pro `04DEF4F5-C144-4936-AEC3-A971B4FA9CDC`, watch `28AC563B-42C1-4E66-940D-77E63B07918B` serially after iOS · never touch the `Conduck/Configs/Identity-Override.xcconfig` symlink · envelope/snapshot mirror files change in byte-identical triplets or not at all · new watch TEST files need a manual target add (use the existing smoke file) · `plutil -lint` false-fails on `.xcstrings` (use a JSON parser) · the spec-size guard fails pre-existing (19,830/16,900) — record, don't fix.

## Earlier handoff

`docs/qa/workboard-worktree-handoff.md` covers the original (pre-desk) implementation and its QA script; it describes machinery that phases 3+ delete. Where it conflicts with `desk-cloudkit/plan.md`, the plan wins.
