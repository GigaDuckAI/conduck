# f5-file-capture — multi-file envelope publisher + playable audio cards

## What changed

**`Conduck/Conduck/Services/WorkCaptureInbox.swift`**

- New top-level `struct WorkCaptureFileInput` (above `actor WorkCaptureInbox`).
- New `WorkCaptureInbox.publishFileCapture(note:files:captureID:createdAt:)`.
- New `WorkCaptureInbox.fileEntryID(forCapture:sequence:)` — `nonisolated static`, UUIDv5
  (Insecure.SHA1 over namespace + captureID bytes + big-endian `UInt32(sequence)`), namespace
  `F11E0000-0000-4000-A000-000000000001`. Same derivation shape as
  `WorkVoiceScreenshotCoordinator.materialID(forCapture:)`, distinct namespace.
- **Refactor, not a copy**: `publishAppCapture(note:imageData:…)` no longer owns the transaction.
  Both publishers now build `[StagedEntry]` and call the shared private
  `publishCapture(id:createdAt:note:source:staged:)`, which keeps the exact order the old body had —
  `ensureScaffold` → staging-name discriminator → `fileExists(published) || isClaimed(id)`
  short-circuit → byte limits → `beginStaging` → payloads → `commit` → `postLocalChange()` →
  the same `defer { publisher.discard }` and the same two catch clauses.
  `publishAppCapture(note:screenshotPNG:…)` is untouched. `WorkCaptureInboxTests` (29) unchanged and green.
- Supporting privates: `StagedPayload` (`.inline(Data)` / `.copiedFile(from: URL)`), `StagedEntry`,
  `refuseOversizedSources(_:id:)`, `stagePayloads(_:into:publisher:)`, `copyPayload(from:to:)`,
  `sourceByteCount(at:)`, `stagedByteCount(at:)`, `withSecurityScope(_:_:)`, `paddedSequence(_:)`.
  New `import CryptoKit`.

**`Conduck/Conduck/Services/Workboard/WorkCaptureDrainer.swift`**

- `import UniformTypeIdentifiers`.
- New `private static func isAudioPayload(_ entry:) -> Bool` — `mimeType` lowercased prefix
  `"audio/"`, else `UTType(typeIdentifier)?.conforms(to: .audio)`.
- `materialDraft(for:in:sourceDevice:createdAt:)`: a `.file` entry that is audio now yields
  `kind: .audio` (image/webPage/text/url paths, titles, storage mode, byte sizing all unchanged).

## New API (exact signatures)

```swift
struct WorkCaptureFileInput: Sendable {
    let url: URL
    let displayName: String?
    let mimeType: String?
    let typeIdentifier: String?
    let byteCount: Int64
}

// on actor WorkCaptureInbox
@discardableResult
func publishFileCapture(
    note: String?,
    files: [WorkCaptureFileInput],
    captureID: UUID = UUID(),
    createdAt: Date = Date()
) throws -> UUID

nonisolated static func fileEntryID(forCapture captureID: UUID, sequence: Int) -> UUID
```

### Contract for the `AddFilesToWorkIntent` caller

- `source: .shortcut` is stamped by the publisher; the caller must not pass a source.
- Entry `id` = `fileEntryID(forCapture: captureID, sequence: <index in files>)`, so the card ids are
  knowable before the drain. Pass a **stable** `captureID` (derive it from whatever the Shortcut can
  replay, or mint once and hold it) — a fresh UUID per attempt defeats the repair.
- Bytes are **copied**, never read into memory; the URL is wrapped in
  `startAccessingSecurityScopedResource()` inside the publisher, so an `IntentFile.fileURL` may be
  handed over directly. If a file arrives as `data` only, the caller must write it to a temp file
  first (there is no `Data` lane on `WorkCaptureFileInput` by design — a headless process must not
  hold 256 MB).
- Refusals, all thrown before anything is published (`pendingCount()` stays 0):
  | condition | error |
  |---|---|
  | `files.count > WorkCaptureEnvelope.maximumEntryCount` (24) | `WorkCaptureEnvelope.PublicationValidationFailure.tooManyEntries` |
  | any file > `maximumFileBytes` (256 MB), declared or measured | `…PublicationValidationFailure.invalidFileEntry` |
  | a source that is missing or not a regular file | `…PublicationValidationFailure.invalidFileEntry` |
  | total > `maximumEnvelopeBytes` (512 MB) | `WorkCaptureInbox.InboxError.invalidEnvelope(captureID, .envelopeTooLarge)` |
  | no note and no files | `…PublicationValidationFailure.emptyCapture` |
- Replaying the same `captureID` while the envelope is still queued returns the id and publishes
  nothing (same short-circuit `publishAppCapture` has).
- The published entry's `byteCount` is the size of the **staged** file, not the caller's declared
  value; the declared value only buys the early refusal.
- After publishing, drain as `WorkVoiceScreenshotCoordinator.publish` does:
  `_ = try? await WorkCaptureDrainer(inbox: .shared, store: .shared, sourceDevice: …).drainAvailableCaptures()`.

## New strings

None. No user-facing copy was added or reworded in this slice.

## Tests

Measured from `~/Library/Caches/gigaduck-builds/work-f5/test.log` / `test2.log`.

| Class | Executed | Failures |
|---|---|---|
| `WorkCaptureFileCaptureTests` (new) | 8 | 0 |
| `WorkCaptureDrainerAudioKindTests` (new) | 4 | 0 |
| `WorkCaptureInboxTests` | 29 | 0 |
| `WorkCaptureDrainerTests` | 10 | 0 |
| `WorkCaptureSharePublisherTests` | 7 | 0 |
| regression sweep: `WorkCaptureDrainerCollisionTests`, `…DurabilityTests`, `…RetirementTests`, `…TakeoverTests`, `WorkCaptureInboxLeaseTests`, `WorkCaptureRefreshCoordinatorTests`, `ConversationStoreWorkCaptureTests`, `ConversationStoreAtomicWorkCaptureTests` | 48 | 0 |

`build-for-testing`: 0 `: error: ` lines.

The size-limit cases use **sparse files** (`FileHandle.truncate(atOffset:)`) — a suite that actually
wrote 256 MB would fail on disk pressure rather than on the behaviour under test.

## Requests (files I do not own)

1. **`AddFilesToWorkIntent`** (slice B intent agent) — use the contract above. In particular: derive
   or persist a stable `captureID`, and surface the four refusals as distinct user-facing outcomes
   (too many files / one file too big / the set too big / nothing to add). The dialog is true at
   publication time, so count the files you passed, not the cards you hope for.
2. **Images from the Files action land as `.file` cards, not `.image`** — `publishFileCapture`
   stamps every entry `kind: .file` because the plan scopes the drainer mapping to audio only. If
   slice A wants picked images to get thumbnails and the gallery, the one-line change is the same
   `isAudioPayload` shape for `image/*` in `WorkCaptureDrainer.materialDraft`. **Flagging, not
   doing** — it is outside my slice, and the drainer's `.image` branch is shared with slice A.
3. **Docs agent**: `project-structure.md` needs no new file entry (no new source files outside
   `ConduckTests`), but the spec's Work ingress paragraph should say that a Shortcut's files publish
   through the same envelope queue as the share sheet and that audio files become playable cards.

## Nobody undo

- **`publishCapture` is one transaction with a fixed order.** The
  `fileExists(published) || isClaimed(id)` short-circuit runs *before* any size check and before
  staging: that ordering is what makes a replayed `publishAppCapture` return the id instead of
  throwing. Moving the limit checks above it changes behaviour a GigaAction retry depends on.
- **Limits are checked twice on purpose**: `refuseOversizedSources` measures the *sources* before a
  byte is copied (so a 600 MB set never lands on the disk first), and `stagePayloads` re-checks the
  *staged* sizes (so a wrong or racing size cannot smuggle bytes past the ceiling). Neither is
  redundant with `validateForPublication`, which never sees a file's bytes.
- **The manifest carries the measured size, not the declared one.** `WorkCaptureInbox.validateEnvelope`
  destroys a capture whose `byteCount` disagrees with its payload (`payloadSizeMismatch`), so
  "simplifying" `stagePayloads` back to the caller's declared count turns a file that changed under
  the copy into a silently discarded capture.
- **`copyItem`, never `Data(contentsOf:)`.** The per-file ceiling is 256 MB and the publisher runs
  in a headless intent process.
- **`fileEntryID`'s namespace and hash input are permanent.** The derivation is what lets a killed
  Shortcut repair its own cards; changing the namespace, the byte order, or the `UInt32` width makes
  every replay lay a second copy of the same files on the desk.
- **`withSecurityScope` wraps the stat as well as the copy** — a Shortcut's URL is unreadable
  outside the scope, and a stat failure there is reported as a missing file (a refusal), not as a
  transient fault.
- **`isAudioPayload` checks `entry.kind == .file` at the call site**, so a `.webPage` archive can
  never become an audio card.

## Open questions

1. Should an audio card captured this way get its own fallback title instead of the existing
   `workboard.capture.file` / "File"? Left unchanged because it would need a new catalog key and the
   plan does not budget one; every real share/Shortcut path supplies a display name anyway.
2. Request 2 above (image files → `.image` cards) is a founder-visible behaviour choice, not just an
   implementation detail: with it, a picked photo gets a thumbnail and the gallery; without it, it
   is a file row that opens in Quick Look.
3. `publishFileCapture` refuses the whole set when one source is unreadable. The alternative —
   publish what can be read and report the misses — is what the share extension does for attachment
   failures. Refusing whole was chosen because a Shortcut has no UI to show the misses in.
