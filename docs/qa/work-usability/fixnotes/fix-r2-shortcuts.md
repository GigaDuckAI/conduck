# fix-r2-shortcuts — Codex R2 findings on the Shortcuts slice

Findings files: `verify/codex-r2-shortcuts.json` (R1 major, R2 minor) and
`verify/codex-r2-cross.json` (R1 = the same major, R3 = the same minor). Both verified
against the code; both FIXED. Nothing refuted.

The verifier's round-1 re-reads for this slice — S1 "still-open", S2 "still-open", S3
"closed" — are exactly R1 and R2 restated, so the two lists below cover all four ids.

---

## R1 (major) — the digest named the SOURCE, not the bytes that get published · FIXED

**Verified, not refuted.** `perform()` computed `captureIdentity` by streaming a digest over
`file.fileURL` and then handed those SAME external URLs to `publishFileCapture`, which opens
its own security scope and copies them a moment later. Between the two reads the file
belongs to somebody else's process — an editor, a sync client, a file provider — so:

- run 1 captures `memo.txt` = "alpha" and the card lands;
- run 2 digests "alpha" (same id), the source is rewritten to "bravo" (five bytes either
  way, so every size check passes), the publisher copies "bravo";
- the drainer upserts by the derived entry id, `ConversationStore+Workboard` repoints the
  existing rows and deletes the superseded blob. The first card now holds "bravo".

Round 1 closed the *stable* collision (two different files alike in name and size); this is
the *mutable* one, and it is the same data loss.

**What changed** — `Conduck/Conduck/Intents/AddFilesToWorkIntent.swift` only:

- **`AddFilesToWorkIntent.Snapshot`** (new, nested): `input: WorkCaptureFileInput` plus
  `digest: Data`. The two travel together because they must be true of the same bytes.
- **`snapshot(_:into:)`** (new): copies a source into this process's own scratch leaf and
  digests it in the SAME streamed pass — `FileHandle` read → `FileHandle` write →
  `SHA256.update`, 256 KB at a time (`digestChunkBytes`, unchanged), under the source's
  security scope. Returns the snapshot's REAL byte count. Any read or write error throws
  `WorkFileCaptureRefusal.unreadableFile(name:)`.
- **`snapshot(_:bytes:into:)`** (new): the same for an `IntentFile` that arrives as bytes
  with no URL — already this process's own, so it is written once and digested in memory.
- **`captureIdentity(note:files:)`** now takes `[Snapshot]` and is **pure** — no I/O at all.
  Same UUIDv5 shape, same namespace `A11F0000-…-0001`, same order-sensitivity, same
  `name ‖ 0x00 ‖ bigEndian(size) ‖ digest` field layout; only the digest's *provenance*
  changed, from "a read of the source" to "the copy that is about to be published".
- **`perform()`** is now two passes. Pass 1 *describes* every file (resolved type, generated
  leaf name, declared size) and runs `refusal(for:)` — so a set that cannot become a capture
  is still refused **before one byte is duplicated** onto the person's disk. Pass 2
  snapshots every file into the staging root and re-runs `refusal(for:)` on the measured
  sizes. `publishFileCapture` then receives the SNAPSHOT urls; the external source is never
  read again.
- `contentDigest(at:)` and its all-zero sentinel are **gone**. An unreadable source refuses
  the capture with the existing `intent.workAddFiles.error.unreadableFile` row, whose
  wording already fits ("“x” couldn’t be read, so nothing was added to Work.").

`WorkCaptureInbox` was NOT touched: `publishFileCapture` already accepts any URL and copies
it, so an already-staged owned copy needs no new entry point and no behaviour change for the
share extensions or the in-app publisher.

**Costs, named honestly.** A URL-backed set is now written to temp once before the queue
copies it, so peak scratch for a 512 MB set is ~1 GB instead of ~512 MB, and the source is
read once (was: read once for the digest, then read again by the publisher — so the number
of *reads of the person's file* did not grow). Memory is still one 256 KB chunk.

**Two b2 "Nobody undo" premises this disproves — deliberately, and only these two.**

1. *"It hashes names and sizes, never bytes."* Already contradicted in round 1, on the
   memory argument (streamed, so RAM is one chunk). Unchanged here.
2. *"`file.fileURL` is handed over unread. The publisher opens the security scope and
   copies."* The constraint that note protects is MEMORY — never touch `.data` on a
   URL-backed file — and it is kept exactly: `.data` is read only for a file that carries no
   URL at all (pass 1 asks `file.fileURL.map(byteCount(at:))` first, and `??` is lazy). What
   the finding disproves is the note's *safety* conclusion: handing an external URL to the
   publisher unread is not safe under an identity scheme whose whole purpose is
   "the same input REPLACES the earlier capture", because nothing freezes that URL's bytes
   between the naming and the copy. A capture may only name bytes it owns.

**Tests that pin it**

- `WorkCaptureFileCaptureTests.testASourceRewrittenAfterItsIdentityCannotPublishUnderTheEarlierCapture`
  — the whole lane: snapshot `memo.txt` = "alpha", derive the id, **rewrite the source to
  "bravo"**, publish, claim, and assert the envelope's payload is `alpha` and its entry is 5
  bytes; then snapshot the rewritten source and assert its capture id DIFFERS. Red before
  the fix (the published bytes were "bravo" under the "alpha" id; and the API it uses did
  not exist).
- `WorkShortcutIntentsTests.testTheSnapshotFreezesTheBytesTheIdentityWasTakenOver` — the
  same property at the unit seam: the snapshot's bytes and its id survive a source rewrite,
  and a re-snapshot of the rewritten source is a different capture.
- `WorkShortcutIntentsTests.testAnUnreadableSourceRefusesTheCaptureInsteadOfNamingIt`
  (replaces `…IsNotTheSameCaptureAsAnEmptyFile`, whose sentinel is gone) — a missing source
  throws `.unreadableFile(name: "note.txt")`.
- `testTwoFilesAlikeInNameAndSizeButNotInBytesAreDifferentCaptures` now runs through the
  production `snapshot(_:into:)`, so it covers publication-shaped inputs; the replay half
  (identical bytes → identical id → repair) still holds.
- `testTheCaptureDigestStreamsTheBytesRatherThanLoadingThem` gained
  `try writer.write(contentsOf: chunk)`, which pins the copy and the digest as ONE pass.
- `testTheCaptureIdentityIsDerivedFromTheInput` gained a same-name, same-SIZE,
  different-DIGEST case.

## R2 / cross R3 (minor) — a fully quit Mac opened no window at all · FIXED

**Verified, not refuted.** `RecordWorkNoteIntent.perform()` runs while the app is launching:
`.showWorkboardVoiceCapture` and the `.showWorkboard` behind it are posted before the `main`
scene's subscribers exist, and `applicationWillFinishLaunching` forces `.accessory` so no
window opens on its own. Round 1's repair lives in the window content's `.onAppear`, which
cannot run when no window is ever created — the residual fix-r1-shortcuts.md:86 recorded.

**What changed** — `Conduck/Conduck/AppDelegate.swift` only (macOS):

- `revealWorkForAPendingVoiceRequest()` (new, private): after the same 500 ms the onboarding
  open waits (SwiftUI installs the scene's `.onReceive` subscribers after
  `applicationDidFinishLaunching` returns), it re-reads `WorkVoiceCaptureLaunchRoute.shared
  .isPending`, calls `NSApp.activate(ignoringOtherApps:)` — an `.accessory` app that opens a
  window without activating puts it behind whatever is frontmost — and then
  `revealWorkIfPending()`, whose `.showWorkboard` the `main` scene's existing `.onReceive`
  turns into `openWindow(id: "main")`.
- Called from **`applicationDidFinishLaunching`** AND **`applicationDidBecomeActive`**,
  because the ordering between `perform()` and this delegate is the system's to choose: a
  foreground intent activates the app, so a request that arrives just after launch is
  answered by the activation it itself causes. No-op whenever nothing is pending.

**A PEEK, never a claim.** The hook never calls `consume()` — consumption stays with the
visible composer, the only surface that can present the recorder. `ConduckApp.swift` and
`WorkVoiceCaptureLaunchRoute.swift` are unchanged; the reveal is the route's own method.

**Test that pins it** — `WorkShortcutIntentsTests
.testTheMacLifetimeOpensAWindowForARequestThatArrivedBeforeAnyExisted`: a source guard that
brace-matches the two lifecycle methods and asserts each calls the hook, and that the hook's
body checks `isPending`, activates, calls `revealWorkIfPending()` and never `consume()`.
Red before the fix (`RefusalLaneSource.body(ofFunction:)` throws `missingFunction`).
Source-shaped for the same reason as the round-1 shell guard: the alternative is driving an
AppKit cold launch from a unit test.

## Invariants held

Durable-before-hop untouched — publication is still the boundary and the inline drain is
still best-effort. One desk write; nothing in this slice writes the desk at all. No path
from here to a gateway or a conversation. **No wire string and no `Wire` enum touched; no
envelope-schema and no `.xcdatamodeld` edit; no catalog row added, renamed or removed** (the
refusal reuses the shipped `intent.workAddFiles.error.unreadableFile`). `WorkCaptureInbox`,
`WorkCaptureDrainer`, `AppShortcuts.swift`, `RecordWorkNoteIntent.swift`,
`WorkVoiceCaptureLaunchRoute.swift` and `ConduckApp.swift` are byte-identical to `HEAD`.
`fileEntryID`'s derivation is untouched; the capture id's UUIDv5 shape is unchanged and only
its digest's provenance moved.

Behaviour worth naming for the founder: capture ids again differ from the previous build's
for the same files (nothing has shipped, and an envelope queued by an older build drains
under its own id, so there is no migration).

## Measured

Slug `fix2-shortcuts`, all under `~/Library/Caches/gigaduck-builds/fix2-shortcuts/`, no
`-configuration` flag, cleaned with `.claude/scripts/clean-build-cache.sh fix2-shortcuts`.

| Run | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` |
| `WorkShortcutIntentsTests` | Executed 27, **0** failures |
| `WorkCaptureFileCaptureTests` | Executed 10, **0** failures |
| `WorkCaptureInboxTests` | Executed 29, **0** failures |
| `TempScratchSweeperTests` | Executed 11, **0** failures |

All four `Test Suite … started` lines are present in `test1.log` (77 tests total), so no
filter passed vacuously.

## Open items

1. **The snapshot doubles peak scratch** for a URL-backed set (≤ ~1 GB at the 512 MB
   ceiling), for the window between the snapshot and the queue's own copy. The lever, if it
   ever matters, is letting the publisher MOVE an owned staged file instead of copying it —
   a new entry point on `WorkCaptureInbox`, deliberately not taken here because it changes a
   publisher three other callers share.
2. **A deliberate double run over the SAME bytes is still a repair**, not a second set of
   cards (b2 open question 1, unchanged and now exactly true as written).

## Founder QA (delta only)

1. Shortcut over `memo.txt` = "alpha" → one card. Change the file to "bravo" (same length),
   run again. Expected: **two** cards, the first still "alpha".
2. Harder version of the same: run the shortcut over a file you edit *while it runs* (a big
   video, so the copy takes a moment). Expected: whatever landed is internally consistent —
   a card whose bytes are what the card claims — and it never replaces an earlier card.
3. Delete a file from Files, then run a shortcut that still names it. Expected:
   "“x” couldn’t be read, so nothing was added to Work." — and nothing on the desk.
4. **Quit Conduck entirely on the Mac** (⌘Q, no menu-bar duck left), then "Hey Siri, record
   a note to Work in Conduck". Expected: a window OPENS, on Work, with the recorder up —
   without you clicking the Dock or the menu bar first. Repeat with the app running quiet in
   the menu bar and with a window already open on Chats.
