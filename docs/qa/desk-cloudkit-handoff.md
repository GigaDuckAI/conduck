# Desk + CloudKit Byte Sync — Handoff

*Superseded as the current handoff by [`docs/qa/work-usability/handoff.md`](work-usability/handoff.md), which carries this document's release gates forward; the wave described below is still the foundation everything there sits on.*

**Status: BUILT, REVIEWED, MERGED WITH `main`, awaiting founder Gate-2 QA.** Branch `feature/agent-workboard` (worktree `.codex/worktrees/conduck-agent-workboard`, whose root IS the Conduck app repo). Everything is local — never pushed. Six adversarial Codex review rounds ran over the build; every finding was confirmed by an independent fixer with a measured counterfactual, none was refuted, and the review loop was closed by founder decision after round 6 (its residue is recorded under §Open items, not fixed). The `/code-review` gate is satisfied by that verification; do not run it again.

## What this branch is

**Work = one desk.** A single space where the person drops, arranges and resizes voice notes, text, screenshots and files. No projects UI, no AI/dispatch/brief layer — nothing on the desk ever becomes a conversation turn. Bytes ≤ 30 MiB sync through the person's own iCloud private database in a second Core Data store; larger files stay on the device that has them, behind a reattach. Voice notes are playable audio cards that appear BEFORE speech-to-text; a failed transcription never loses the recording. "Data Not Collected" stays true: no company backend is involved anywhere.

## Commit chain (all local)

`96493f7` … `651a859` desk rounds → `136e088` CloudKit foundation (model 16) → `4165c74` single-desk purge → `39d19d1` byte sync (two stores) → `223ac35` two-phase audio + string audit → `801b937` wave-B fixes → `effc664` wave-C (cross-process publication lock, recovery coordinator, iOS audio exclusivity) → `f794856` wave-D (material↔blob `contentHash` pairing, kind-collision refusal, UUID-keyed retry queue, sniffed STT MIME) → `1e9a004` wave-E (collision-escape id, per-entry sidecar/tombstone durability, claim/lease API, backlog + Discard UI) → `09bc5a1` wave-F (replay never repoints a newer row, verified terminal retirement, lease ownership on every lane) → **`2c10a54` merge of Conduck `main` (`b649c83`)** → the tip: docs coherence pass + this handoff.

## Gate at the tip

| Check | Result |
|---|---|
| iOS suite (iPhone 17 sim `2B6E0EAC-…`) | **5146** tests / 0 failures / 1 environment skip (`GatewayAdapterBriefTests` clipboard pin — needs the sibling `website` checkout) |
| watchOS suite (`28AC563B-…`) | **232** / 0 |
| Signed macOS build | green |
| `scripts/check-storage-seam.sh`, `check-folder-map.sh`, `check-spec-cites.sh` | exit 0 |
| `scripts/check-spec-size.sh` | exit 0 — 16607 words of 16900 after the docs pass; every decision within its 650-word limit |
| Catalogs | all four parse (main 2273 rows); `workboard.*` 147/147 and `pendingRetry.*` 9/9 bidirectional |
| Mirror triplets (`WorkCaptureEnvelope`, `ShareTargetsSnapshot`, `WorkCaptureDirectoryPublisher` ×3) | byte-identical from `import Foundation` |
| Data model | only `Conversations 16.xcdatamodel/contents` + `.xccurrentversion` differ from `651a859`; version 15 byte-identical |

## Architecture in one screen (details: `docs/ai-context/spec.md`, the Work / desk / audio decisions)

- **Single desk** = fixed id `Constants.workboardDeskItemID`; one authoritative `upsertDeskMaterial` op serves all capture processes (app, share extensions, Shortcuts intent). Share extensions never publish blobs; they write envelopes the app drains.
- **Two stores**: `Conversations.sqlite` (Core, 7 entities) and `ConversationBlobs.sqlite` (Blobs, `WorkMaterialBlob`), both `NSPersistentCloudKitContainer` mirrors of the private database; the watch mounts Core only. `WorkMaterialStoragePolicy`: ≤ 30 MiB → `.syncedPayload`, else `.localVault`.
- **Publication protocol**: blob first, then material; `WorkMaterial.contentHash` pairs a row with its bytes; a device adopts another's upload only when a committed row names those exact bytes AND a complete blob exists; availability `.syncedPending` = "no complete blob paired to this row". Duplicate blob rows are a normal state bounded by persistence (one per attempt that died between the two saves). GC is paired deletion only — no orphan sweep, ever.
- **Cross-process safety**: `WorkCaptureInbox` generation-named claim dirs + 5-min filesystem lease; `WorkCaptureDrainer` durable-readability barrier; `WorkMaterialPublicationLock` = App-Group `flock` per material id. A capture whose id names a card of another kind is refused; the drainer and the voice recovery retry once under `WorkMaterialCollisionEscape.materialID(forCapture:)`; a second refusal is terminal and retired into `WorkCaptureInbox/refused/` by a verified copy + atomic rename (never a delete).
- **Two-phase audio**: `WorkVoiceCaptureCoordinator.publishRecording` (card appears) → STT → `attachTranscript`; on failure the bytes park in `PendingRetryStore`, a per-capture queue (sidecar written before audio, index last; tombstone before removal; sidecar authoritative over index). `claimNext` / `claim(id:duration:)` take a token-checked 10-min lease under the cross-process lock; surfaces renew every 120 s and confirm ownership before any hand-off. Work captures not yet `.published` never expire. `recover(claim:…)` is the single answer for every retry surface (app, menu bar, headless intent); `WorkVoiceRecoveryOutcome.isTerminal` drives clearing.
- **Playback**: `WorkboardAudioCardView` + `WorkboardAudioOutput`; `SpokenAudioSession` owns the audio session for Chat read-aloud and card playback; `SpeechExclusivity` on iOS and macOS.

## Decisions taken by the orchestrator (founder never signed these — reverse if wrong)

1. `workboard.sync.banner.{noAccount,restricted,quotaExceeded}` minted for the desk instead of reusing Chat's "your conversations" banner (plan §C said "reuse").
2. `WorkMaterial.contentHash` added to model 16 as an additive optional attribute (no model 17) — legal only because 16 was never deployed and is on no device.
3. A recording is republished only when its `publicationState == .phaseOneFailed`; a wordless republication marks it `.published` and keeps the entry for the words.
4. `PendingRetryStore` became a UUID-keyed queue; the legacy single slot is folded in on first load, never deleted unread.
5. Discard (per entry, confirmed) added to the retry card; for a published Work recording it removes only the retry copy.
6. Five source-text drift guards converted to behavioural seams; appex/absence guards kept.
7. `WorkboardSurface` and the dead `.openPersonalAISettings` notification deleted.
8. macOS popover Retry gated on `pendingRetryCount > 0`.
9. The payload store mirrors through a SECOND CloudKit container, `iCloud.ai.gigaduck.agentrelay.blobs` official / `iCloud.com.example.conduck.blobs` community (`CONDUCK_ICLOUD_BLOBS_CONTAINER_ID` → `ConduckCloudKitBlobsContainerID` → `Constants.iCloudCloudKitBlobsContainerID`). Core Data raises "Cannot assign the same iCloud Container Identifier to multiple stores" when two descriptions name one container, which killed the first signed macOS launch; the identifier is a set-once Apple identity from here on.

## Founder decisions open

**Copy (nine, all live in the catalog with a placeholder the founder has not read):** (a) voice-sheet privacy line — now concedes that the chosen speech provider may itself be an AI ("…never into a conversation, and never through a server of ours"); reassurance or confession? (b) the three desk sync-banner sentences; (c) `workboard.workspace.drop.overlay.caption` "…Nothing is sent."; (d) the recovered-note title (first line of the transcript); (e) tutorial line + large-file confirm; (f) `workboard.capture.discarded.message.one` is half true for a terminally refused capture; (g) backlog count "2 recordings waiting" as a caption (iOS) vs the whole sentence (macOS); (h) the shared Discard title "Discard this recording?" for a published Work capture; (i) `AppError.workDeskWriteFailed` (78) wording claims transience.
**Structure:** delete `WorkCaptureRetryCoordinator.swift` (zero callers, compiles without it) — yes/no.
**Chat behaviour changes this branch introduces (intended, but the founder should know):** starting the in-app microphone stops an active Chat read-aloud; one read-aloud stops another across windows; Chat read-aloud and Work card playback are mutually exclusive; CarPlay dictation uploads now carry `audio/x-caf` instead of a false `audio/mp4` (Gemini WAV canary, release gate 3); the Chat retry card shows a backlog count, stays retry-capable after one finish, and gains Discard.

## Open items (integrate-h §5, condensed — full table with evidence in `desk-cloudkit/fixnotes/integrate-h.md`)

| # | Item | Class |
|---|---|---|
| O-1 | `PendingRetryStore.renew` answers `false` for five reasons but only a token mismatch means the hold is lost; `PendingRetryLeaseRenewal.whileRenewing` stops on the first `false` while the recorder's loop never does. Remedy: renew returns held / lost / unavailable; retry on unavailable. The one item that can still cause a duplicate finish (never a lost recording). | correctness, small |
| O-2 | `pendingSummary()` — the retry card describes the newest capture but acts on the newest UNRESERVED one; one metadata accessor closes it | UX, small |
| O-3 | No non-retryable `AppError` for a permanent identity refusal (`.refusedTwice`) | copy + one case |
| O-4 | Cross-process lock and retry queue are proven with two store instances in ONE process; two real processes only on a signed device | Gate 2 |
| O-5 | `deleteSupersededBlobRows` can delete a peer's newer blob inside the publishing transaction; the 4-line `notNewerThan:` remedy is measured green in isolation, not applied (three call sites, one decision each) | data, decided-open |
| O-6…O-16 | hygiene / vocabulary / consolidation (IsolatedWorkStores adoption, banner collapse, `ReplyVoice` on iOS, `filename` on the snapshot, radius literal, shared card actions, availability chip mapping, `workspaceStatus` rename, external-storage memory bound uncovered by decision) | non-blocking |
| O-17 | Watch catalog drift since `efa553e` (source says "isn't available", catalog "isn't set up"); not a Work string | pre-existing |
| O-18 | Spec-size debt — CLOSED by the merge (16423/16900); the guard is a real gate again, so doc folds must pay inside their decision | closed |
| O-19 | **Founder QA — 81 device-only items across the fixnotes + plan §C Gate 2** | release gate |
| O-20 | `STTKeyBlackoutLaneTests` reports only the first broken lane | test hygiene |
| O-21 | A control fixture can name a deleted type and stay green | test hygiene |

## Release gates

1. **Deploy BOTH containers' schemas to CloudKit Production** before any release carrying these entities — the Core half (model 16 plus `WorkMaterial.contentHash`) to `iCloud.ai.gigaduck.agentrelay`, and `WorkMaterialBlob` to `iCloud.ai.gigaduck.agentrelay.blobs`. A CloudKit field can never be withdrawn, and a container whose Production schema is missing syncs in debug and silently not in TestFlight/App Store. `origin/main` ships model 13, so one deploy per container covers all. Record beside APPLE-CD-V7-001.
2. **Gate 2 — founder signed-device QA**, release-blocking for byte sync. Two signed devices on one iCloud account plus the Mac. The full lists: `desk-cloudkit/spike-fixnote.md` §(c) (18 steps: zones, import/export, delete/reinstall, watch exclusion, headless-intent 134410, quota/signed-out) and the "Founder QA" sections of `integrate-d/e/f/g/h.md` (81 items). The **first thing to do is irreversible**: park a Work voice note under the OLD build, then install this build and confirm it still finishes — the App Group retry container is rewritten on first launch.
   **The zone question is answered by construction.** The two stores mirror through SEPARATE containers, so they cannot share a record zone and no Core-store fetch can hand the wrist a blob record. `spike-fixnote.md` §(c) step 5 therefore collapses to: confirm the Blobs container's Development schema shows `CD_WorkMaterialBlob` and the Core container's does not. Step 12's watch-leakage branch has nothing left to trigger it.
3. Run the private Gemini canary for a WAV body (`Conduck-Private/scripts/validation/`) — the branch now labels WAV honestly where it used to send it as `audio/mp4`.
4. Never push unasked. When the branch is pushed it lands in the PUBLIC repo `GigaDuckAI/conduck`: nothing under `docs/qa/desk-cloudkit/` contains secrets (checked), but the fixnotes are internal working notes — decide whether they travel.
5. **Public README documents no Work desk** — its surface table lists only Chat capabilities (pre-existing gap, now a shipped user-visible surface). Needs an owner before release.

## Founder QA script — the thirteen to run first

On the iPhone unless stated; airplane mode where "offline". Failure cases are named.
1. **Upgrade** (do this FIRST, once): old build → park a Work voice note offline → install this build → retry online → one playable card with the words. Fail: card missing, card duplicated, or Diagnostics still reports a waiting recording afterwards.
2. **Desk basics**: drop text, a screenshot, a small file and a > 30 MiB file; arrange/resize; kill the app mid-drop and reopen. Fail: any card missing or duplicated.
3. **Payload container missing**: before the container exists in the portal (or with a provisioning profile that predates it), the app LAUNCHES — it does not crash — logs `Blobs container entitlement missing`, and cards on the other device stay "Waiting for iCloud…". Create the container, rebuild, and the same card opens. Fail: any launch crash naming an iCloud container identifier.
4. **Two devices, small file**: capture on A, wait on B → card opens on B. Delete on B → gone on A.
5. **Two devices, large file**: > 30 MiB on A → B shows the card as device-local (not "Waiting for iCloud…" for ever); reattach a small file on A → B opens it.
6. **Force-quit mid-publication** on A right after the progress bar → B never shows a permanent "Waiting for iCloud…"; re-capture on A → exactly one card.
7. **Voice note online**: record from the desk → playable card appears at once, words fill in. Play it while Chat read-aloud is speaking → read-aloud stops (intended).
8. **Voice note offline**: record → card appears, retry card appears; go online, Retry → words on the SAME card, no note, no second card.
9. **Two recordings waiting**: Work note offline, then Action-Button Chat capture offline; online → Retry twice → both complete; count reaches zero.
10. **Discard**: published Work note whose words failed → Discard → dialog says the recording stays in Work → card still plays. Chat capture → Discard → dialog says deleted, cannot be recovered.
11. **Racing surfaces (Mac)**: menu-bar Retry running, press the main window's retry → busy sentence, Retry button still drawn, exactly one result.
12. **Shortcuts vs app**: Action-Button capture offline, then open the app and tap Retry before the 90-second notice → exactly one finishes, the other says it is already being finished.
13. **Watch**: ordinary dictation still transcribes (AAC, unchanged); the watch never shows a Work card and never downloads a blob (Gate 2 §watch exclusion).
Then the full 81 + 18.

## Standing constraints (any future agent)

Build caches under `~/Library/Caches/gigaduck-builds/<slug>` + `clean-build-cache.sh <slug>` always · never `-configuration` on xcodebuild test/build-for-testing · check the sim's TCC row before trusting a red audio run (`sqlite3 …/TCC.db`; reset with `xcrun simctl privacy <UDID> reset all ai.gigaduck.AgentRelay`) · never touch the `Conduck/Configs/Identity-Override.xcconfig` symlink · mirror triplets change byte-identically or not at all · parallel agents never edit `.xcstrings` (one serial copy agent) · docs are present-tense end state, no changelog narration · the "nobody undo" lists in every fixnote interlock — read the relevant one before changing a mechanism · never rebase this branch; merge only · never push unasked.

## Where things are

`desk-cloudkit/plan.md` (binding plan) · `desk-cloudkit/fixnotes/` (every agent's note, waves A–F + integrate-a…h; the Codex findings are restated verbatim in the fixnotes of the wave that fixed them) · `desk-cloudkit/spike-fixnote.md` §(c) (Gate-2 checklist) · `docs/ai-context/spec.md` + `project-structure.md` (present-tense truth) · workflow scripts in the session dir `~/.claude/projects/-Users-peterkruck-repos-GigaDuck--codex-worktrees-conduck-agent-workboard/…/workflows/scripts/`. The earlier `docs/qa/workboard-worktree-handoff.md` described the pre-desk build and is retired.
