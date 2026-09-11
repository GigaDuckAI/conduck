# integrate-0 — foundation-wave integration

Integrator pass after `f1-voice-source`, `f2-quicklook-lift`, `f3-gallery-generalise`,
`f4-thumbnails`, `f5-file-capture`, `f6-guards`. The six slices merged with **no compile
conflict**: the first iOS `build-for-testing` on the combined tree was 0 errors. One
cross-slice test failure and one header-style nit needed fixing.

## What changed

- `Conduck/ConduckTests/ErrorSurfaceDriftGuardTests.swift` — `retrySurfaces` gains
  `"Conduck/Views/Conversation/AttachmentFullScreenView.swift": .notErrorDriven(reason:)`.
  **Reason:** f3's `ZoomableImagePage` added an explicit failure state with a `Retry`
  button (`AttachmentFullScreenView.swift:387`), and Rule 2 of that guard fails any
  SwiftUI file drawing a literal "Retry" that the registry has never been told about
  (`testEveryRetryControlConsultsARetryabilityGate`). `.notErrorDriven` is the correct
  classification, not `.gated`: the control re-runs a LOCAL byte read plus an ImageIO
  decode through the injected `loadFullBytes` closure — no transport, no `AppError`, and
  therefore no `isRetryable` verdict for it to consult. This is exactly the registration
  f2 filed as a request against the gallery agent.
- `Conduck/ConduckTests/WorkDeskWriteOwnershipDriftGuardTests.swift` — inserted the blank
  line between the SPDX tag and the `// Conduck` header block. **Reason:** house header
  style, and `scripts/add-spdx-headers.sh` documents that the blank line is load-bearing —
  SwiftFormat's `--header` rule treats the first comment block followed by a blank line as
  the replaceable header, so without the separator a format pass can rewrite the licence
  tag away. `--check` did not catch it because the file is still untracked.

Nothing else was edited. No slice's mechanism was simplified, relaxed or reshaped.

## New API

None — integration only.

## New strings

Merged across all six fixnotes (only f3 added any):

```
attachment.gallery.loadFailed | This image couldn't be opened. | Shown in the full-screen image gallery when a picture's full bytes cannot be loaded or decoded.
attachment.gallery.retry | Retry | Button in the full-screen image gallery that re-attempts loading the current picture.
```

f1, f2, f4, f5, f6 added none.

## Tests

Targeted run — every class the six reports name, plus the six mandated by the brief
(`WorkboardCopyTruthGuardTests`, `WorkCaptureInboxTests`, `WorkboardOpenPathTests`,
`WorkboardDeskSurfaceDriftGuardTests`, `MacWorkbenchShellDriftGuardTests`,
`WorkboardMaterialPresentationTests`) — 37 classes, all in one `test-without-building`
invocation:

```
Executed 341 tests, with 0 failures (0 unexpected) in 24.142 (24.219) seconds
```

37 `Test Suite … started` lines confirm every named class actually ran (a typo'd
`-only-testing` filter would otherwise pass vacuously).

Builds, all with `-derivedDataPath ~/Library/Caches/gigaduck-builds/work-int0/…` and no
`-configuration` flag:

| Target | Result |
|---|---|
| iOS `build-for-testing` (sim `04DEF4F5`) | exit 0, **0** `: error: ` |
| macOS `build` (`platform=macOS`) | exit 0, **0** `: error: ` — real signing through the identity override, no `CODE_SIGNING_ALLOWED=NO` fallback needed |
| watchOS `build` (scheme `ConduckWatch Watch App`, sim `28AC563B`) | exit 0, **0** `: error: ` |

Guard scripts, all exit **0**: `check-storage-seam.sh` (824 files, seam intact) ·
`check-folder-map.sh` (36 dirs, all mapped — `Views/Components/` already carried a row, so
f2's new file needed none) · `check-spec-cites.sh` · `check-spec-size.sh` (16,649 of
16,900 words — unchanged; this wave added no spec prose yet, so the docs pass still has
251 words of headroom) · `check-legal-copies.sh` · `add-spdx-headers.sh --check`.
`git diff --check` clean.

## Requests

Carried forward from the foundation fixnotes to the slices that own the files (none is
mine to make):

- **Slice A / `PersonalWorkbenchView.swift`** — (f4) call
  `await ConversationStore.shared.repairMissingWorkThumbnails()` in
  `reconcileDurableWorkStorage()`, after `reconcileWorkAssetVault()`, inside the same
  `Task`. (f2) add `@State private var filePreview = FilePreviewCoordinator()`,
  `.quickLookPreview($filePreview.previewURL)` and the dismissal `onChange` bridge on the
  desk root; mint `beginRequest()` at the tap, check `isCurrent(token)` after
  `makePreviewCopy`, then `present(PreviewedFile(url:reclaim:), token:)`. Do **not** add a
  macOS-side reclaim — the coordinator's policy already withholds it there.
- **Slice A / router** — (f3) use the primary
  `AttachmentFullScreenView(pages:startIndex:loadFullBytes:fullDecodeMaxPixel:)`; the
  loader must THROW on unreadable bytes so the page shows Retry rather than spinning.
- **Slice A / drainer mapping** — (f5) images published through `publishFileCapture` land
  as `.file` cards today; an `image/*` branch alongside `isAudioPayload` in
  `WorkCaptureDrainer.materialDraft` is slice A's to add.
- **Slice B / intents** — (f5) stable `captureID` per attempt, pass `file.fileURL`
  directly, surface the four distinct refusals, drain inline. (f6) declare
  `title`/`description` as `intent.<name>.title` / `.description` catalog keys, not bare
  English literals, or the new platform-name rule cannot see them.
- **Slice C / Watch** — (f6) any new wrist desk write stays in
  `ConduckWatch Watch App/WorkboardCaptureIntent.swift`.
- **Copy agent** — the two `attachment.gallery.*` rows above; every `intent.*.title` /
  `.description` row must be platform-free.
- **Docs pass** — (f4) a truncated `/// Pin or unpin one project…` doc comment sits above
  `func loadWorkMaterial(id:)` in `ConversationStore+Workboard.swift`, documenting a
  function that is not there; left alone deliberately to keep f4's diff to its slice.
  (f5) the spec's Work ingress text should note that a Shortcut's files publish through the
  same envelope queue as the share sheet and that audio files become playable cards.

## Nobody undo

Every "Nobody undo" from the six fixnotes still stands and was honoured — in particular
f6's `WorkDeskWriteOwnershipDriftGuardTests` exemption by exact squeezed call text (never a
filename allowlist), f2's `FilePreviewReclaimPolicy` (must not collapse back into
`#if os(iOS)`) and its reclaim CLOSURE (not a URL the coordinator deletes), f1's
`sourceDevice` default (must stay defaulted, and must not revert to `SourceDevice.current`
inside the draft), and f4's staged-lane thumbnail gate plus the no-`updatedAt` backfill
contract.

Added by this pass:

- The `AttachmentFullScreenView.swift` row in `retrySurfaces` must not be widened into a
  `.gated` entry or deleted "because the gallery is local". `.notErrorDriven` is the claim
  that no `AppError` reaches the control; if the gallery ever loads bytes over a transport,
  the row has to be re-decided, not removed.

## Open questions

- f4's recovery-path note is unresolved and out of this wave: `republishRecording` stamps
  the RECOVERING device because `PendingRetryStore` metadata carries no `sourceDevice`
  field. Slices C and E stamp correctly on the happy path; a recovered wrist or car capture
  will read as the phone.
- f3's deliberate behaviour: a gallery page released at 6x briefly shows a magnified
  thumbnail before the original re-decodes. Founder QA call.
- f5's audio cards keep the generic "File" fallback title; no new key was minted.
