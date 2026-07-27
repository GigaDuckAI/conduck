// SPDX-License-Identifier: Apache-2.0

// Conduck
// AttachmentDeliveryPlanner.swift
//
// The SINGLE source of truth for how a TEXT/code attachment is routed onto the
// wire (Codex refinement #1). A text file mirrors how an IMAGE is handled: when
// the bound gateway has a file-server it is DUAL-routed — a copy rides inline as
// a fenced block (instant, gateway-independent comprehension) AND the raw bytes
// are uploaded to the user's file-server so the agent's tools can run / grep /
// transform the REAL file. Large text drops the inline copy (file-only); a
// server-less gateway stays inline-only (today's behavior — no regression).
//
// Pure + `Sendable` + STATELESS — no I/O, no actor, no UI. The three call sites
// (iOS `ComposerAttachmentCoordinator`, the macOS `MessageComposerBar` staging
// path, and `SharedInboxDrainer`) all consult this ONE function so the picker /
// entry point never decides semantics: the same file lands the same way whether
// it arrived via the photo importer, the file importer, drag-drop, or a system
// share. Route is decided by EXTRACTED UTF-8 byte count (what actually rides the
// wire), NOT the raw file size on disk — an `.rtf` extracts to far fewer bytes.
//
// Founder-tunable thresholds live in `Constants` (`textInlineMaxBytes`,
// `textInlineTurnBudgetBytes`).

import Foundation
import UniformTypeIdentifiers

/// Decides whether a text/code attachment rides inline, uploads a server copy,
/// or both — from its extracted UTF-8 size, the bound gateway's file-server
/// presence, and the remaining per-turn inline budget. Stateless + pure.
enum AttachmentDeliveryPlanner {

    /// How a text file's server copy should be handled.
    enum ServerCopy: Equatable, Sendable {
        /// No server copy — the gateway has no file-server (inline is the only
        /// transport; today's behavior).
        case none
        /// A server copy is PREFERRED but not required: the file is small enough
        /// to ride inline as a fallback, so the eager upload never gates Send. If
        /// the upload hasn't landed by send time the file rides inline-only.
        case preferred
        /// A server copy is REQUIRED: the file is too large to inline, so the
        /// upload is the ONLY transport and Send gates on it landing (the existing
        /// `.serverFile` strict-send-gating behavior).
        case required
    }

    /// The routing decision for one text attachment.
    struct DeliveryPlan: Equatable, Sendable {
        /// Whether a fenced inline copy of the extracted text rides the wire this
        /// turn.
        let inline: Bool
        /// How the server copy is handled (see `ServerCopy`).
        let serverCopy: ServerCopy
        /// When set, the inline copy must be CLAMPED to this many UTF-8 bytes
        /// (the drainer cuts via `WebPageCapture.truncatedForInline`, honest
        /// note included INSIDE the cap). Only ever set for a WEBPAGE capture
        /// on a server-less gateway — this client-owned-history protocol
        /// re-sends the full conversation every turn, so an unbounded page
        /// would tax every subsequent turn. `nil` (every other case) keeps
        /// today's behavior: regular text inlines UNLIMITED on a server-less
        /// gateway (no regression, test-locked).
        let inlineByteLimit: Int?

        /// Explicit init so `inlineByteLimit` defaults away at the existing
        /// call sites / test fixtures (additive change, nothing recompiles
        /// differently).
        init(inline: Bool, serverCopy: ServerCopy, inlineByteLimit: Int? = nil) {
            self.inline = inline
            self.serverCopy = serverCopy
            self.inlineByteLimit = inlineByteLimit
        }
    }

    /// Plan the delivery of one text attachment.
    ///
    /// - Parameters:
    ///   - extractedByteCount: the UTF-8 byte count of the EXTRACTED text (the
    ///     bytes that would ride inline), NOT the raw on-disk file size.
    ///   - fileServerPresent: whether the bound gateway has a configured
    ///     file-server (a `fileTransferSnapshot` resolves).
    ///   - inlineBudgetRemaining: how many inline bytes this turn can still spend
    ///     before the per-turn aggregate cap (`textInlineTurnBudgetBytes`) is hit.
    ///     The caller decrements it as it accepts inline files in staged order.
    ///   - clampInlineWhenServerless: when `true`, a SERVER-LESS gateway clamps
    ///     the inline copy to `textInlineMaxBytes` (carried as `inlineByteLimit`);
    ///     with a file-server present it has NO effect (the copy routes exactly
    ///     like regular text). The drainer sets it for an appex-synthesized
    ///     Safari page-text capture (`SharedInboxManifest.Item.sourceKind ==
    ///     WebPageCapture.sourceKindWebpage`) so an unbounded page can't tax
    ///     every subsequent turn of the client-owned history.
    /// - Returns: the `DeliveryPlan`.
    ///
    /// Rules:
    /// - no server → `{inline: true, .none}` (inline is the only transport);
    ///   `clampInlineWhenServerless` additionally carries `inlineByteLimit =
    ///   textInlineMaxBytes` (clamped + honest note); regular text stays
    ///   unlimited (no regression).
    /// - server + small (≤ `textInlineMaxBytes`) + fits the turn budget →
    ///   `{inline: true, .preferred}` (dual: inline now + eager upload).
    /// - server + large (> `textInlineMaxBytes`) → `{inline: false, .required}`
    ///   (file-only — too big to inline; upload gates Send).
    /// - server + small but OVER the remaining turn budget →
    ///   `{inline: false, .preferred}` (still uploaded for the agent's tools, but
    ///   the inline copy is suppressed on the wire to keep the turn bounded).
    static func plan(
        extractedByteCount: Int,
        fileServerPresent: Bool,
        inlineBudgetRemaining: Int,
        clampInlineWhenServerless: Bool = false
    ) -> DeliveryPlan {
        // No file-server → inline-only (no regression; works on a thin gateway).
        // Clamp exception: when `clampInlineWhenServerless` is set the inline
        // copy is capped to the inline limit so a huge capture can't tax every
        // subsequent turn of the conversation.
        guard fileServerPresent else {
            return DeliveryPlan(
                inline: true,
                serverCopy: .none,
                inlineByteLimit: clampInlineWhenServerless ? Constants.textInlineMaxBytes : nil
            )
        }

        // Large text → file-only (drop inline; the upload is the only transport).
        if extractedByteCount > Constants.textInlineMaxBytes {
            return DeliveryPlan(inline: false, serverCopy: .required)
        }

        // Small text: dual when the inline copy fits the remaining turn budget;
        // otherwise still upload (preferred) but suppress the inline copy on the
        // wire so the per-turn inline aggregate stays bounded.
        if extractedByteCount <= inlineBudgetRemaining {
            return DeliveryPlan(inline: true, serverCopy: .preferred)
        }
        return DeliveryPlan(inline: false, serverCopy: .preferred)
    }
}

/// The shared I/O preparation seam for composer text/code attachments.
///
/// Both Apple composers feed the planner's decision through this helper so a
/// brand-new conversation (`conversationID == nil`) behaves exactly like an
/// established one: a READY file lane still produces an upload request, but its
/// `storedKey` is flat because no conversation folder exists yet. Keeping the
/// upload request beside the staged tile also makes the contract deterministic
/// in XCTest without performing a network PUT.
struct TextAttachmentStagePreparation {
    struct UploadRequest: Equatable {
        /// Stable app-temporary copy of the ORIGINAL picked bytes. The upload
        /// must read this URL, never a re-encoded copy of `extractedText`.
        let localURL: URL
        /// Pre-minted server handle. A VM-less first turn deliberately has no
        /// folder prefix; established conversations use their UUID folder when
        /// the server's nested-write probe passed.
        let storedKey: String
    }

    let attachment: StagedAttachment
    let uploadRequest: UploadRequest?
}

enum TextAttachmentStagePreparer {
    /// Prepare one already-extracted text/code attachment for a composer.
    ///
    /// The caller resolves READY by the effective `RemoteAgentRef`, then passes
    /// the resulting Boolean here. `conversationID` is optional by design: nil
    /// means the first turn has not minted its conversation yet, not that the
    /// file lane is unavailable.
    static func prepare(
        sourceURL: URL,
        extracted: TextFileExtractor.ExtractedFile,
        fileServerReady: Bool,
        inlineBudgetRemaining: Int,
        folderCapable: Bool,
        conversationID: UUID?,
        uuid: UUID = UUID()
    ) async -> TextAttachmentStagePreparation {
        let byteCount = extracted.text.lengthOfBytes(using: .utf8)
        let plan = AttachmentDeliveryPlanner.plan(
            extractedByteCount: byteCount,
            fileServerPresent: fileServerReady,
            inlineBudgetRemaining: inlineBudgetRemaining
        )

        guard plan.serverCopy != .none else {
            return TextAttachmentStagePreparation(
                attachment: StagedAttachment(kind: .file(sourceURL)),
                uploadRequest: nil
            )
        }

        // The picker's security scope is not guaranteed to outlive staging.
        // Copy the ORIGINAL bytes once into app temp; both the eager PUT and a
        // user-triggered Retry read this stable file. A copy failure preserves
        // the historical inline-only fallback.
        guard let stagingURL = await Task.detached(
            operation: { AttachmentStagingFile.copyUnderScope(sourceURL) }
        ).value else {
            return TextAttachmentStagePreparation(
                attachment: StagedAttachment(kind: .file(sourceURL)),
                uploadRequest: nil
            )
        }

        let storedKey = FileServerClient.makeStoredKey(
            originalName: extracted.filename,
            uuid: uuid,
            folder: folderCapable ? conversationID?.uuidString : nil
        )
        let upload = TextAttachmentStagePreparation.UploadRequest(
            localURL: stagingURL,
            storedKey: storedKey
        )

        if plan.inline {
            return TextAttachmentStagePreparation(
                attachment: StagedAttachment(
                    kind: .dualText(
                        url: stagingURL,
                        extractedText: extracted.text,
                        filename: extracted.filename,
                        mimeType: extracted.mimeType
                    ),
                    serverUploadState: .uploading(progress: 0)
                ),
                uploadRequest: upload
            )
        }

        let mimeType = UTType(filenameExtension: sourceURL.pathExtension)?.preferredMIMEType
            ?? extracted.mimeType
        return TextAttachmentStagePreparation(
            attachment: StagedAttachment(
                kind: .serverFile(
                    url: stagingURL,
                    originalName: extracted.filename,
                    mimeType: mimeType
                ),
                serverUploadState: .uploading(progress: 0)
            ),
            uploadRequest: upload
        )
    }
}

/// Shared stable-copy helper for composer uploads. It brackets the original
/// picker URL's security scope and performs a file-to-file copy, so large files
/// never balloon into an in-memory `Data`.
///
/// The ONE implementation for every composer host — the iOS coordinator, the
/// macOS bar, and the text planner all call this. Each host used to carry its
/// own private copy, which is precisely how the length bound below can go
/// missing on two paths out of three and still look fixed.
enum AttachmentStagingFile {

    /// Longest leaf a staged copy may occupy, in BYTES.
    ///
    /// POSIX `NAME_MAX` is 255 bytes and every filesystem the app stages onto
    /// enforces it per path component. Overflow is not cosmetic: `copyItem`
    /// throws `ENAMETOOLONG`, `copyUnderScope` returns nil, and the binary
    /// composer path then drops the attachment with no chip and no error — the
    /// user picks a file and nothing at all happens.
    static let stagingLeafMaxBytes = 255

    /// The `TempScratchSweeper.ownedPrefixes` entry every staged copy carries.
    /// Kept as a constant for the budget arithmetic; the literal is ALSO spelled
    /// inline at the append below, because `TempScratchLeafDriftGuardTests`
    /// reads the claimed prefix off the call site as a string literal.
    static let stagingLeafPrefix = "conduck-ftstage-"

    /// Bytes the FIXED part of a staging leaf occupies: the claimed prefix, a
    /// UUID string (always 36 ASCII characters), and the `-` separating it from
    /// the source name. `AttachmentStagingFileTests` re-measures a real leaf
    /// end-to-end so this arithmetic cannot drift from the format string.
    static let stagingLeafReservedBytes = stagingLeafPrefix.utf8.count + 36 + 1

    /// Longest dot-suffix still treated as an extension worth preserving — same
    /// rule, and same reason, as `FileServerClient.boundedStoredKeyName`.
    private static let maxPreservedExtensionCharacters = 16

    /// Bound the SOURCE filename so `conduck-ftstage-<uuid>-<name>` fits inside
    /// one path component, keeping the extension.
    ///
    /// Counted in BYTES, unlike `FileServerClient.boundedStoredKeyName`, whose
    /// input has already been mapped to the single-byte set `[A-Za-z0-9._-]`.
    /// This one takes the RAW filesystem name, where one character can be four
    /// bytes: 70 emoji are a legal 280-byte filename on the source volume and
    /// would sail past a character-counted bound of 202.
    ///
    /// The cut lands on a Character boundary, so the result is never a severed
    /// UTF-8 sequence — a leaf the filesystem would reject for a second,
    /// harder-to-read reason.
    ///
    /// A no-op for every name that already fits, so an ordinary attachment
    /// stages under exactly the leaf it always did.
    static func boundedSourceLeaf(
        _ leaf: String,
        budgetBytes: Int = stagingLeafMaxBytes - stagingLeafReservedBytes
    ) -> String {
        guard budgetBytes > 0 else { return "" }
        guard leaf.utf8.count > budgetBytes else { return leaf }

        // A leading dot is a dotfile — all stem. Reading it as an extension
        // would truncate the entire name away.
        var stem = leaf
        var ext = ""
        if let dot = leaf.lastIndex(of: "."), dot != leaf.startIndex {
            let suffix = String(leaf[dot...])
            if suffix.count <= maxPreservedExtensionCharacters,
               suffix.utf8.count < budgetBytes {
                stem = String(leaf[..<dot])
                ext = suffix
            }
        }

        let stemBudget = budgetBytes - ext.utf8.count
        var kept = ""
        var used = 0
        for character in stem {
            let width = String(character).utf8.count
            guard used + width <= stemBudget else { break }
            kept.append(character)
            used += width
        }
        return kept + ext
    }

    nonisolated static func copyUnderScope(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "conduck-ftstage-\(UUID().uuidString)-\(boundedSourceLeaf(url.lastPathComponent))"
            )
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }
}
