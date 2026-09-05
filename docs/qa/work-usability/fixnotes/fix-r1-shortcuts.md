# fix-r1-shortcuts — Codex R1 findings on the Shortcuts slice

Findings file: `docs/qa/work-usability/verify/codex-r1-shortcuts.json` (3: one major, two
minor). All three verified against the code; all three FIXED. No finding was refuted.

**Concurrency note, read first.** A second writer was editing this slice's files during
this pass (see "Tree state"). Everything below is the state on disk after the merge, and
every line of it was re-verified by reading the file, building both platforms and running
the suites.

---

## S1 (major) — different files alike in name and size overwrote each other · FIXED

**Verified, not refuted.** `captureIdentity(note:files:)` hashed the note plus each file's
NAME and `byteCount` only. Two different `memo.txt`s of five bytes derive one id; entry ids
under it are `WorkCaptureInbox.fileEntryID(forCapture:sequence:)`, derived from that id and
the position, so the second capture is a REPAIR of the first — `ConversationStore+Workboard`
repoints the existing card rows at the new payload and deletes the superseded blob. The
earlier bytes are gone. The collision escape in the store keys on kind and ownership, and
two ordinary file cards do not escape it.

**What changed** — `Conduck/Conduck/Intents/AddFilesToWorkIntent.swift`:

- `AddFilesToWorkIntent.contentDigest(at:)` (new, private): SHA-256 of the source's bytes,
  read through a `FileHandle` in 256 KB chunks (`digestChunkBytes`) under
  `startAccessingSecurityScopedResource()`. Never `Data(contentsOf:)`.
- `AddFilesToWorkIntent.captureIdentity(note:files:)`: each file now contributes
  `name ‖ 0x00 ‖ bigEndian(byteCount) ‖ digest` instead of `name ‖ 0x00 ‖ size`. UUIDv5
  shape unchanged — same namespace `A11F0000-0000-4000-A000-000000000001`, same
  `Insecure.SHA1` outer hash, same version/variant bits, same ORDER-sensitivity.
- An unreadable source digests as 32 zero bytes, not as an empty file's digest: SHA-256
  never answers all-zero, so an unreadable file can neither borrow a real file's identity
  nor shorten the field. (The queue refuses such a set moments later regardless.)

**Deliberate contradiction of a b2 "Nobody undo".** That note reads *"It hashes names and
sizes, never bytes. A headless intent process must not read a quarter of a gigabyte to
decide what to call something."* The constraint it protects is MEMORY, and the fix keeps
it: the digest is streamed, so RAM stays at one 256 KB chunk however big the file is. What
the note traded away was correctness — name+size is not an identity, and under a scheme
whose whole purpose is "the same input REPLACES the earlier capture", a collision is data
loss, not a duplicate. The cost paid is one extra sequential read of bytes the publisher is
about to copy anyway. The plan's replay property is untouched: identical bytes still derive
the identical id and still repair.

**Test that pins it** — `WorkShortcutIntentsTests`:
`testTwoFilesAlikeInNameAndSizeButNotInBytesAreDifferentCaptures` (two real 5-byte
`memo.txt` files with different contents → different ids; a third file with the SAME bytes →
the same id, so a killed shortcut's rerun still repairs; version-5 bits re-asserted) and
`testAnUnreadableSourceIsNotTheSameCaptureAsAnEmptyFile`.

---

## S2 (minor) — a cold-launch voice request stranded behind Chats · FIXED

**Verified, not refuted.** `RecordWorkNoteIntent` posts `.showWorkboardVoiceCapture` (via
`request()`) and then `.showWorkboard`. On a cold launch both are delivered to nobody;
`PersonalWorkbenchView.Router.destination` initialises to `.chats` and only
`.showWorkboard` moves it. `WorkboardCaptureCanvas.consumeVoiceCaptureLaunchRoute()`
correctly refuses to claim a request it cannot present (`guard
workbenchDestinationIsActive`), so the request survives — but nothing ever reveals Work,
and the recorder waits for a tap the person has no reason to make.

**What changed** (all shell-level, per the ownership split — `WorkboardCaptureCanvas` and
`PersonalWorkbenchView` untouched):

- `Conduck/Conduck/Views/Workboard/WorkVoiceCaptureLaunchRoute.swift` —
  `var isPending: Bool` (a PEEK, never a claim) and `func revealWorkIfPending()`, which
  posts `.showWorkboard` on the next main-actor turn while the request is still pending and
  does NOT consume. The hop exists because an appearance callback can run while the
  `.showWorkboard` observers are still being installed; the flag is re-read after it.
- `Conduck/Conduck/RootView.swift` — `.onAppear { …revealWorkIfPending() }` on the
  `PersonalWorkbenchView` branch (iOS shell).
- `Conduck/Conduck/ConduckApp.swift` — the same `.onAppear` on the macOS `Window("Conduck",
  id: "main")` content, so a window opened for the intent opens ON Work.

Consumption stays exactly where it was: the visible composer. The shells only reveal.

**Test that pins it** — `WorkShortcutIntentsTests`:
`testRevealingAPendingRequestDoesNotSpendIt` (reveal posts `.showWorkboard` and the request
is STILL claimable afterwards), `testRevealingWithoutARequestPostsNothing` (a plain launch
never yanks anyone off Chats), and
`testTheShellsRevealWorkForAPendingRequestAndLeaveConsumptionToTheComposer` (source guard:
both shells call `revealWorkIfPending()`; neither calls `consume()`).

**Residual, recorded rather than fixed:** on a Mac that is fully quit, if `perform()` runs
before the `main` scene's observers are installed, no window opens at all — the request then
lands the moment a window is opened by any means (Dock, menu bar, popover), because that
window's `.onAppear` reveals Work. Closing the last sliver would need an AppKit
activation hook in `AppDelegate`, which is outside this slice's ownership.

---

## S3 (minor) — an oversized note reported an unreadable file · FIXED

**Verified, not refuted.** The intent trimmed the note but never bounded it.
`WorkCaptureEnvelope.validateForPublication()` throws `.noteTooLong` above
`maximumNoteCharacters` (16 000), and `WorkFileCaptureRefusal.init(publicationFailure:files:)`
handled only `.tooManyEntries` / `.emptyCapture`, defaulting everything else to
`.unreadableFile(name: files.first…)` — so a perfectly readable `memo.txt` was named as the
failure, and re-picking it could never help.

**What changed** — `Conduck/Conduck/Intents/AddFilesToWorkIntent.swift`:

- `WorkFileCaptureRefusal.noteTooLong` (new case) + its `errorDescription`.
- `WorkFileCaptureRefusal.init(publicationFailure:files:)` maps `.noteTooLong` explicitly
  instead of letting it fall to the `unreadableFile` default.
- `AddFilesToWorkIntent.refusal(forNote:)` (new, pure, static) — the ceiling is the
  envelope's, single-sourced; `perform()` calls it right after trimming, so the refusal
  happens before a byte is staged.

**Catalog row added by this fix** (`Conduck/Conduck/Localizable.xcstrings`, exactly the
shipped row shape — `extractionState` + `localizations.en.stringUnit{state,value}`, 4-space
entry indent, inserted alphabetically between `…error.noFiles` and `…error.setTooLarge`):

```
intent.workAddFiles.error.noteTooLong | That note is too long to add to Work. Shorten it, then try again.
```

No platform name, no send/dispatch/draft/brief verb. It names the NOTE, which is the whole
point of the finding: the files were never the problem.

**Test that pins it** — `WorkShortcutIntentsTests`:
`testAnOversizedNoteIsRefusedAsANote` (ceiling-exact: 16 000 passes, 16 001 refuses) and
`testTheQueuesNoteVerdictIsNotReportedAsAnUnreadableFile` (the queue's verdict maps to
`.noteTooLong`, explicitly NOT to `.unreadableFile`).

---

## Invariants held

Durable-before-hop untouched (publication is still the boundary; the drain is still
best-effort). One desk write — nothing here writes the desk at all. No path from this slice
to a gateway or a conversation. No wire string, no `Wire` enum, no envelope schema, no
`.xcdatamodeld` touched. `WorkCaptureInbox`, `WorkCaptureDrainer` and the three shipped
`AppShortcut` entries are byte-identical to `HEAD`. `fileEntryID`'s namespace, byte order
and `UInt32` width are untouched; only the CAPTURE id's input grew, and its UUIDv5 shape
did not change.

Behaviour change worth naming for the founder: a capture id derived from bytes means the
ids differ from `692608d`'s for the same files. Nothing has shipped, and an envelope queued
by an older build drains under its own id, so there is no migration.

## Measured

Slug `fix-shortcuts`, all under `~/Library/Caches/gigaduck-builds/fix-shortcuts/`, no
`-configuration` flag, cleaned with `.claude/scripts/clean-build-cache.sh fix-shortcuts`.

| Run | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` |
| `WorkShortcutIntentsTests` (15 → 22) | Executed 22, **0** failures |
| `WorkCaptureFileCaptureTests` | Executed 9, **0** failures |
| `WorkCaptureInboxTests` | Executed 29, **0** failures |

Every suite's `Test Suite … started` line is present in `test1.log`, so no filter passed
vacuously.

## Tree state (concurrent writer)

While this pass ran, another writer edited four files in this slice's ownership. Nothing was
undone; the merged state is what was built and tested above.

- `WorkVoiceCaptureLaunchRoute.swift`, `RootView.swift`, `ConduckApp.swift` — the S2 fix
  landed there in the shape described above (identical to the fix this agent had scoped).
- `RecordWorkNoteIntent.swift` — a CLAIMS fix, not one of these three findings: keys
  renamed `intent.workRecordNote.{title,description}` → `intent.workVoiceNote.{…}` and the
  description rewritten off "Nothing is sent to an AI" onto the honest boundary (the audio
  reaches the chosen speech provider; it never becomes a conversation turn). The catalog
  rows were renamed with it. Left as found — it is true, and it matches
  `workboard.voice.privacy`.
- Consequence for this slice's tests: `testNoNewIntentTitleOrDescriptionNamesAPlatform`
  pinned the four key SPELLINGS and would have failed on that rename. It now pins the files
  action's two keys by name and the voice action's two by SHAPE (one keyed title, one keyed
  description, both platform-free), so the claims lane can own its own copy without
  breaking this guard. The ITMS-90626 hole it exists for is still closed.

## Open items

1. **The Mac's fully-quit sliver** (S2 residual, above): needs an `AppDelegate` hook, which
   this slice does not own.
2. **The digest costs a read.** A 512 MB set is now read once for the identity and once for
   the copy. Bounded and sequential, but if a Shortcut over huge video ever feels slow, the
   honest lever is a cheaper identity for very large files (e.g. head+tail sampling), which
   is a correctness/latency trade the founder should make deliberately, not a refactor.
3. `b2`'s open question 1 still stands and is untouched by this pass: a deliberate double
   run over the SAME bytes is a repair, not a second set of cards. The founder's call at QA
   step 6 is now strictly better informed — with S1 fixed, "the same bytes" is what the
   sentence actually means.

## Founder QA (delta only — b2's script otherwise stands)

1. Shortcut over `memo.txt` containing "alpha" → one card. Change the file's contents to
   "bravo" (same name, same length) and run it again. Expected: **TWO** cards now, the first
   still holding "alpha". Before this fix the second run overwrote the first.
2. Run the same shortcut twice over an UNCHANGED file. Expected: still ONE card (repair).
3. Run the action with a huge Note (paste a long document into the Note parameter) and one
   ordinary file. Expected: "That note is too long to add to Work. Shorten it, then try
   again." — it must NOT name the file. Nothing lands on the desk.
4. Force-quit Conduck, then "Hey Siri, record a note to Work in Conduck". Expected: the app
   opens ON Work with the recorder up, not on Chats. Repeat on the Mac with the app quit and
   with it running quiet in the menu bar.
