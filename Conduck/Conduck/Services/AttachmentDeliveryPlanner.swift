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
