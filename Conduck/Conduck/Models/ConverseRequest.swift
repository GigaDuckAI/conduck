// Conduck
// ConverseRequest.swift
//
// Network foundation. Wire Codables for the OpenAI-compatible
// `/v1/chat/completions` request/response that both OpenClaw and Hermes
// Agent gateways expose (`spec.md "Remote Agent Round-Trip"`).
//
// Both types in one file matches the `STTBroadcastEnvelope.swift` shape
// (one wire concept = one file). Single-file scope keeps the request +
// response evolutionary path in lockstep — V1.1 multimodal extension
// converts `Message.content: String` → `Message.content: Content` (enum
// with `.text` / `.parts` cases + custom encoder) as a local refactor
// here, with no API ripple to `RemoteAgentClient` callers.
//
// Client-owned history (`spec.md "Remote Agent Round-Trip"`): BOTH backends
// receive the FULL client-owned conversation in `messages[]` over a
// STATELESS request.
// There is NO session-ID wire field — no `x-openclaw-session-key` header,
// no `conversation` body field, no per-backend dispatch. The conversation
// store is the single source of truth for the context that gets
// sent; `RemoteAgentClient` assembles `messages[]` from it (subject to the
// trim policy) and sends the identical request shape to every
// backend. Reply parsing, transport, and error mapping are likewise
// backend-agnostic.
//
// `model` is omitted from the encoded body — V1 lets the gateway pick
// its configured default. The gateway operator is the one who chose
// the upstream LLM; the client second-guessing that with a `model`
// override defeats the point of self-hosting.

import Foundation
#if DEBUG
import os.log
#endif

/// OpenAI-compatible chat-completions request body.
///
/// `messages` carries the **full client-owned history** (oldest → newest,
/// after the trim policy) plus the new user turn. There is no
/// session-ID field of any kind — continuity rides on the local
/// conversation store, not a wire identifier. The encoded body is
/// byte-shape-identical for OpenClaw and Hermes.
struct ConverseRequest: Encodable, Sendable {
    let messages: [Message]
    let stream: Bool

    /// Optional model name. OMITTED from the encoded body when nil — V1
    /// built-ins (OpenClaw/Hermes) always pass nil so the gateway picks its
    /// configured default (the original posture). A user's CUSTOM gateway may
    /// set it (many OpenAI-compatible servers — vLLM/Ollama/LiteLLM — require an
    /// explicit model). Encoded only when present (custom `encode(to:)` below),
    /// so the built-in / text-only wire stays byte-identical.
    let model: String?

    init(messages: [Message], stream: Bool, model: String? = nil) {
        self.messages = messages
        self.stream = stream
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case messages, stream, model
    }

    /// Custom encoder: OMIT `model` when nil (the synthesized encoder would
    /// emit `"model": null`; `encodeIfPresent` drops the key entirely). Keeps
    /// the built-in body exactly `{messages, stream}` as before.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        try container.encodeIfPresent(model, forKey: .model)
    }

    /// Single user/assistant turn. `content` is multimodal: a `.text` case
    /// encodes a BARE JSON string (text-only turns — the portable, model-
    /// agnostic shape); a `.parts` case encodes the OpenAI content-parts array
    /// (text + `image_url` blocks) for multimodal turns. Roles are stringly-
    /// typed to keep the wire boring (`"user"` / `"assistant"` / `"system"`).
    struct Message: Encodable, Sendable {
        let role: String
        let content: Content

        /// Back-compat initializer — keeps every existing `.init(role:content:)`
        /// call site (tests + history mapping) compiling and serialising a bare
        /// `content` string unchanged. Sets `.text`.
        init(role: String, content: String) {
            self.role = role
            self.content = .text(content)
        }

        /// Multimodal initializer — used by `assembleMessages` / `priorTurns`
        /// when a turn carries images (or spliced text-file blocks alongside
        /// images).
        init(role: String, content: Content) {
            self.role = role
            self.content = content
        }
    }

    /// A turn's content: either plain text (encoded as a bare JSON string —
    /// the portable shape every OpenAI-compatible gateway accepts) or an
    /// ordered array of content parts (text + `image_url` blocks).
    ///
    /// `Equatable` + `ExpressibleByStringLiteral` keep the content directly
    /// comparable / constructible from a bare string for callers + tests that
    /// reason about the text-only shape (a string literal coerces to `.text`),
    /// since a `.text` turn is conceptually just its string.
    enum Content: Encodable, Sendable, Equatable, ExpressibleByStringLiteral {
        case text(String)
        case parts([Part])

        init(stringLiteral value: String) {
            self = .text(value)
        }

        func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let string):
                // Single-value container → encodes a BARE JSON string, so
                // `content` deserialises as `String` (preserves the text-only
                // wire shape + `ConverseWireTests`' `content as? String`).
                var container = encoder.singleValueContainer()
                try container.encode(string)
            case .parts(let parts):
                var container = encoder.unkeyedContainer()
                for part in parts {
                    try container.encode(part)
                }
            }
        }
    }

    /// One element of a multimodal `content` array. `.text` → `{"type":"text",
    /// "text":…}`; `.imageURL` → `{"type":"image_url","image_url":{"url":…}}`
    /// where the URL is a base64 `data:image/jpeg;base64,…` data-URI (the only
    /// portable image input across arbitrary BYO gateways).
    enum Part: Encodable, Sendable, Equatable {
        case text(String)
        case imageURL(String)

        private enum CodingKeys: String, CodingKey {
            case type
            case text
            case imageURL = "image_url"
        }

        private struct ImageURLPayload: Encodable {
            let url: String
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let string):
                try container.encode("text", forKey: .type)
                try container.encode(string, forKey: .text)
            case .imageURL(let url):
                try container.encode("image_url", forKey: .type)
                try container.encode(ImageURLPayload(url: url), forKey: .imageURL)
            }
        }
    }

    /// Map a conversation's stored `MessageRecord`s into the wire
    /// `[Message]` array (the OAI `role`/`content` shape), oldest → newest.
    /// `RemoteAgentClient.assembleMessages` then appends the new user turn
    /// and applies the trim policy.
    ///
    /// `excludingNewUserText` drops a trailing user turn whose text matches
    /// the just-captured turn — the converse callers append the user turn to
    /// the store BEFORE building the request (so the store is authoritative
    /// if the reply never lands), but the request assembler re-appends the
    /// new user turn itself, so the stored copy must not be sent twice.
    ///
    /// `dataURIsByMessageID` is a PRE-RESOLVED map of `Message.id` →
    /// ordered image data-URIs (`data:image/jpeg;base64,…`). This method stays
    /// synchronous/pure — `ConversationHistoryAssembler` (the single production
    /// caller) does the async `loadAttachmentData` hops and hands the resolved
    /// bytes in. A turn whose id is present (with non-empty URIs) is an
    /// IMAGE-BEARING turn.
    ///
    /// **Image-history policy (`imagePolicy`):** the method walks turns
    /// most-recent → oldest, counting image-bearing ones, and assigns each a
    /// tri-state disposition driven by the per-gateway `ImageHistoryPolicy`:
    ///
    /// - **inline** — within the policy's `inlineWindow` (newest N image-bearing
    ///   turns; `.all` has no window, so EVERY image-bearing turn is inline —
    ///   the historic behavior). Images ride as `image_url` parts.
    /// - **reference** — aged out AND every image keyed (a persisted
    ///   `storedKey`, dual-image route — uploaded once to the gateway
    ///   file-server): inline `image_url` parts are DROPPED and a
    ///   `spliceImageTextRefs` imperative file reference is spliced instead
    ///   (the path the agent can re-open from disk). This converts prior-turn
    ///   images from re-shipped-every-turn to uploaded-once-referenced-after.
    /// - **expire** — aged out, ≥1 image UNKEYED (inline-only — no file-server,
    ///   or the eager upload never landed), AND past the policy's
    ///   `orphanInlineWindow` grace (within the grace it stays inline — there
    ///   is no file to reference yet). The keyed subset still splices its
    ///   `spliceImageTextRefs` disk refs; the unkeyed remainder gets the honest
    ///   `spliceImageUnavailableNote` with the UNKEYED count. Bounds the token
    ///   burn of orphan images, which previously rode inline for the full
    ///   `contextMaxTurns`.
    ///
    /// The CURRENT turn's images are never handled here (the caller excludes
    /// the new user turn).
    ///
    /// **Honesty floor (unresolved image turns):** a record whose attachments
    /// include user-side images (`isImage && !isServerReference`) but whose id is
    /// NOT in `dataURIsByMessageID` (the caller skipped the async resolve) never
    /// flattens to bare text. All images keyed → the same `spliceImageTextRefs`
    /// disk reference as the aged-out path; any image unkeyed →
    /// `spliceImageUnavailableNote`. Floor turns are not in the map, so they
    /// never consume an inline-window slot, and `.all` cannot force inline what
    /// was never resolved.
    ///
    /// Each record's attached text files (its `AttachmentRecord.isText`
    /// snapshots carrying `extractedText`) are spliced into that turn's text as
    /// fenced, filename-labelled blocks — identical shape to the new-user
    /// splice in `assembleMessages`, so a model sees the same format whether a
    /// file was attached this turn or three turns ago.
    ///
    /// `folder` (the conversationID UUID string) is accepted for caller symmetry
    /// but the on-disk path the reference splices comes from each attachment's
    /// persisted `storedKey` (which ALREADY carries the folder prefix when it was
    /// minted folder-capable) — authoritative over any reconstruction.
    static func priorTurns(
        from records: [MessageRecord],
        excludingNewUserText newUserText: String? = nil,
        dataURIsByMessageID: [UUID: [String]] = [:],
        folder: String? = nil,
        imagePolicy: ImageHistoryPolicy = .default
    ) -> [Message] {
        var working = records
        if let newUserText,
           let last = working.last,
           last.role == "user",
           last.text == newUserText {
            working.removeLast()
        }

        // Decide, per image-bearing turn, its DISPOSITION (inline / reference /
        // expire). Walk most-recent → oldest with one shared image-bearing
        // counter; the newest `inlineWindow` image-bearing turns are inline
        // (`.all` has a nil window → everything inline, the escape hatch).
        // Beyond the window a turn goes to REFERENCE only when EVERY image has
        // a persisted `storedKey` (files to point at). A turn with ≥1 UNKEYED
        // image can't fully reference: within the `orphanInlineWindow` grace it
        // stays inline (no file exists yet — dropping it would blind the
        // agent); past the grace it EXPIRES (keyed subset → disk refs, unkeyed
        // remainder → the honest unavailable note) so never-uploaded images
        // stop riding inline forever.
        let window = imagePolicy.inlineWindow
        let orphanWindow = imagePolicy.orphanInlineWindow
        var dispositionByID: [UUID: ImageTurnDisposition] = [:]
        var imageBearingSeen = 0
        for record in working.reversed() {
            let isImageBearing = !(dataURIsByMessageID[record.id] ?? []).isEmpty
            guard isImageBearing else { continue }

            // EVERY image on this turn must have a persisted storedKey before we
            // can convert it to a reference. If even one image is unkeyed (e.g. a
            // co-attached image whose eager upload never landed by send-time —
            // Send is never upload-gated), converting the turn would drop that
            // image's inline bytes while the reference splice (below) names only
            // the keyed images, losing the unkeyed one entirely (no pixels, no
            // disk ref). Mixed → inline within the orphan grace, expire after
            // (this also subsumes the all-inline-only, no-file-server case).
            let imageAtts = record.attachments.filter { $0.isImage && !$0.isServerReference }
            let allImagesReferenceable = !imageAtts.isEmpty && imageAtts.allSatisfy {
                $0.storedKey?.isEmpty == false
            }

            if let window {
                if imageBearingSeen < window {
                    dispositionByID[record.id] = .inline      // within the newest-N window
                } else if allImagesReferenceable {
                    dispositionByID[record.id] = .reference   // aged out + all on disk → reference
                } else if orphanWindow.map({ imageBearingSeen < $0 }) ?? true {
                    // Unkeyed within the orphan grace. A nil grace means NEVER
                    // expire (the same meaning nil carries on `inlineWindow`)
                    // — unreachable with the three shipped policies (only
                    // `.all` has a nil grace, and its nil window short-circuits
                    // above), but a future level with a window and no grace
                    // must not silently expire orphans instantly.
                    dispositionByID[record.id] = .inline
                } else {
                    dispositionByID[record.id] = .expire      // unkeyed past the grace → expire
                }
            } else {
                dispositionByID[record.id] = .inline          // `.all` — no window, all inline
            }
            imageBearingSeen += 1
        }

        // Map `agent` → `assistant` on the wire (OAI role); `user` stays.
        return working.map { record in
            let wireRole = record.role == "agent" ? "assistant" : record.role

            // Split this turn's text-file attachments by whether a file-server
            // copy exists (a non-empty `storedKey`, the dual-text route — Codex
            // #4: `isText && storedKey != nil`). WITHOUT a key → inline as today
            // (server-less / un-uploaded — no file to reference). WITH a key →
            // DROP the inline fenced text and splice a concise DISK reference
            // instead: re-shipping a file's full text every stateless turn is the
            // text analogue of the image-replay token cost, and the agent already
            // holds the byte-faithful original in its working dir (it can re-read
            // on demand). No window needed (unlike images): a disk ref is a few
            // tokens vs an image's on-demand-vision trade, so age it immediately.
            let inlineTextAtts = record.attachments.filter { $0.isText && !($0.storedKey?.isEmpty == false) }
            let agedTextAtts = record.attachments.filter { $0.isText && ($0.storedKey?.isEmpty == false) }

            let textFileBlocks: [(filename: String, text: String)] = inlineTextAtts
                .compactMap { att in
                    guard let text = att.extractedText else { return nil }
                    return (filename: Self.filename(for: att), text: text)
                }
            var splicedText = Self.spliceText(record.text, textFileBlocks: textFileBlocks)

            // Splice this turn's SERVER-FILE references (file-transfer route) AFTER
            // the text-file fenced blocks. A prior-turn server ref must be retained
            // on the wire so a model that acted on `report.pdf` three turns ago
            // still sees the "saved as <storedKey>" line in context — identical
            // render to the new-user splice in `assembleMessages` (Order within a
            // turn's text: base → text-file fences → server-file refs line). The
            // real bytes never travel inline; the line names the stored key the
            // agent's tools already hold in its working folder.
            //
            // AGED DUAL-TEXT files (Codex #4) join the SAME block: a prior dual-text
            // file whose inline fence was dropped above (because it has a `storedKey`)
            // re-splices here as a concise disk ref — folded into the one "in your
            // working directory" block alongside `.serverFile` refs so the turn
            // carries a single, non-duplicated instruction header.
            let agedTextRefs: [(originalName: String, storedKey: String)] = agedTextAtts
                .map { (originalName: Self.filename(for: $0), storedKey: $0.storedKey ?? "") }
            let serverFileRefs: [(originalName: String, storedKey: String)] = record.attachments
                .filter { $0.isServerFile }
                .map { (originalName: $0.filename ?? $0.storedKey ?? "file", storedKey: $0.storedKey ?? "") }
            splicedText = Self.spliceServerFileRefs(splicedText, serverFiles: serverFileRefs + agedTextRefs)

            let imageURIs = dataURIsByMessageID[record.id] ?? []
            let isImageBearing = !imageURIs.isEmpty
            let disposition = dispositionByID[record.id] ?? .inline

            if !isImageBearing {
                // HONESTY FLOOR — a turn that CARRIED user-side images but has no
                // resolved map entry must NEVER silently flatten to bare text:
                // the model sees plain text where it once saw pixels, denies the
                // images ever existed, and retro-claims its own earlier (correct)
                // vision answer was a hallucination (real observed failure, when
                // three dispatch surfaces skipped the resolve pre-assembler).
                // Production triggers today: unloadable/empty bytes (un-synced
                // CloudKit asset, deleted blob) or a future caller bypassing
                // `ConversationHistoryAssembler`. ALL images keyed → splice the SAME
                // `spliceImageTextRefs` disk reference the aged-out path uses (a
                // file the agent can re-open); ANY image unkeyed → an honest
                // unavailable note (there is no file to point at — all-or-
                // nothing, so the note's count never under-reports). Floor turns
                // are not in the map, so they never consume an inline-window
                // slot (the loop above keys on map presence) and the `.all`
                // policy cannot force inline what was never resolved.
                let floorImageAtts = record.attachments.filter { $0.isImage && !$0.isServerReference }
                guard !floorImageAtts.isEmpty else {
                    // Non-image turn — bare text (with any text-file / server-file
                    // splices already applied).
                    return Message(role: wireRole, content: .text(splicedText))
                }
                let allKeyed = floorImageAtts.allSatisfy { $0.storedKey?.isEmpty == false }
                if allKeyed {
                    let imageRefs: [(storedKey: String, filename: String)] = floorImageAtts
                        .compactMap { att in
                            guard let key = att.storedKey, !key.isEmpty else { return nil }
                            return (storedKey: key, filename: Self.displayFilename(forStoredKey: key))
                        }
                    return Message(role: wireRole,
                                   content: .text(Self.spliceImageTextRefs(splicedText, images: imageRefs)))
                }
                return Message(role: wireRole,
                               content: .text(Self.spliceImageUnavailableNote(splicedText,
                                                                              imageCount: floorImageAtts.count)))
            }

            switch disposition {
            case .inline:
                // Inline image turn (within the window, the orphan grace, or
                // `.all`). PARTIAL-RESOLUTION floor: a multi-image turn where
                // only SOME bytes resolved (e.g. one synced + one un-synced
                // CloudKit asset) rides the resolved subset inline — the
                // missing rest gets the same honest unavailable note instead of
                // vanishing silently (the all-or-nothing floor above only
                // catches the zero-URI case). Fully-resolved turns:
                // `missing == 0`, text untouched, byte-identical to the
                // pre-floor wire.
                let userImageCount = record.attachments.filter { $0.isImage && !$0.isServerReference }.count
                let missing = max(0, userImageCount - imageURIs.count)
                let inlineText = missing > 0
                    ? Self.spliceImageUnavailableNote(splicedText, imageCount: missing)
                    : splicedText
                let parts: [Part] = [.text(inlineText)] + imageURIs.map { Part.imageURL($0) }
                return Message(role: wireRole, content: .parts(parts))

            case .reference:
                // Aged-out image turn, ALL images on disk → DROP the inline
                // bytes; splice an imperative text reference naming each
                // image's on-disk path. The path comes from the attachment's
                // persisted `storedKey` (already folder-prefixed when minted);
                // a display filename is derived from the key's last
                // `__`-delimited segment (images carry no `filename`).
                let imageRefs: [(storedKey: String, filename: String)] = record.attachments
                    .filter { $0.isImage && !$0.isServerReference }
                    .compactMap { att in
                        guard let key = att.storedKey, !key.isEmpty else { return nil }
                        return (storedKey: key, filename: Self.displayFilename(forStoredKey: key))
                    }
                let referencedText = Self.spliceImageTextRefs(splicedText, images: imageRefs)
                // No inline parts → stays a bare text turn (the reference is text).
                return Message(role: wireRole, content: .text(referencedText))

            case .expire:
                // EXPIRED image turn — aged past both the inline window AND the
                // orphan grace with ≥1 unkeyed image. The keyed subset still has
                // on-disk files → the same imperative `spliceImageTextRefs`
                // refs as `.reference`; the unkeyed remainder has nothing to
                // point at → the honest `spliceImageUnavailableNote`, counting
                // ONLY the unkeyed images (the keyed ones remain reachable via
                // their refs — the note must not over-report). An all-unkeyed
                // turn yields the note alone. No inline parts → `.text`.
                let imageAtts = record.attachments.filter { $0.isImage && !$0.isServerReference }
                let keyedRefs: [(storedKey: String, filename: String)] = imageAtts
                    .compactMap { att in
                        guard let key = att.storedKey, !key.isEmpty else { return nil }
                        return (storedKey: key, filename: Self.displayFilename(forStoredKey: key))
                    }
                let unkeyedCount = imageAtts.count - keyedRefs.count
                let expiredText = Self.spliceImageUnavailableNote(
                    Self.spliceImageTextRefs(splicedText, images: keyedRefs),
                    imageCount: unkeyedCount
                )
                return Message(role: wireRole, content: .text(expiredText))
            }
        }
    }

    /// The adapter-contract v1 (revision 1.3) canonical historical-image
    /// disclosure, VERBATIM — frozen by the public contract; adapters use the
    /// same string when they substitute a historical image they cannot
    /// forward. Client-side it backs compat mode ("Keep chatting without
    /// photos"): outbound-only, the stored history and UI keep the images.
    static let historicalImageDisclosure =
        "An image was attached in this earlier message, but this adapter cannot inspect it. Do not infer its contents."

    /// Whether any assembled prior turn still carries an inline `image_url`
    /// part. Recorded AT DISPATCH TIME into the failure classification
    /// (`failureHadHistoryImages`) — the poisoned-chat copy must reflect what
    /// the failed request actually contained, and the image-history policy
    /// can demote stored images to file references, so a render-time thread
    /// scan would over-claim.
    static func containsImageParts(_ messages: [Message]) -> Bool {
        messages.contains { message in
            guard case .parts(let parts) = message.content else { return false }
            return parts.contains { if case .imageURL = $0 { return true } else { return false } }
        }
    }

    /// Compat-mode post-pass: replace every historical `image_url` part
    /// IN PLACE with a text part carrying the canonical disclosure. Runs on
    /// the ASSEMBLED prior turns — after the image-history policy routed each
    /// turn — so it touches exactly the image parts that would have gone on
    /// the wire (reference/expired turns are already text and pass through
    /// untouched; per-part replacement keeps part order and count). The
    /// CURRENT turn is never in this array (callers exclude it), honoring
    /// "NEW current-turn photos are never silently removed".
    static func substitutingHistoricalImages(in messages: [Message]) -> [Message] {
        messages.map { message in
            guard case .parts(let parts) = message.content else { return message }
            var replaced = false
            let substituted: [Part] = parts.map { part in
                if case .imageURL = part {
                    replaced = true
                    return .text(Self.historicalImageDisclosure)
                }
                return part
            }
            guard replaced else { return message }
            return Message(role: message.role, content: .parts(substituted))
        }
    }

    /// Tri-state wire disposition for an IMAGE-BEARING prior turn, decided by
    /// the `priorTurns` newest→oldest walk under the per-gateway
    /// `ImageHistoryPolicy` (see the policy paragraph in `priorTurns`' doc).
    private enum ImageTurnDisposition {
        /// Images ride inline as `image_url` parts (within the inline window,
        /// within the orphan grace, or policy `.all`).
        case inline
        /// All images keyed + aged out → drop inline bytes, splice the
        /// imperative on-disk references.
        case reference
        /// ≥1 unkeyed image aged past the orphan grace → keyed subset to disk
        /// refs, unkeyed remainder to the honest unavailable note.
        case expire
    }

    /// Derive a human display filename from a stored key for the image text
    /// reference. A key is `[<folder>/]<8hex>__<name>`: take the last path
    /// component, then the segment AFTER the `__` separator (the original
    /// sanitized name). Falls back to the last path component, then the raw key.
    private static func displayFilename(forStoredKey key: String) -> String {
        let lastComponent = key.split(separator: "/").last.map(String.init) ?? key
        if let range = lastComponent.range(of: "__") {
            let name = String(lastComponent[range.upperBound...])
            return name.isEmpty ? lastComponent : name
        }
        return lastComponent
    }

    // MARK: - Text-file splicing (shared by priorTurns + assembleMessages)

    /// Splice fenced, filename-labelled text-file blocks into a turn's text.
    /// Empty `textFileBlocks` returns `base` unchanged (text-only fast path).
    /// Each block is rendered as:
    ///
    ///     --- <filename> (untrusted user-provided file contents) ---
    ///     ````…
    ///     <text>
    ///     ````…
    ///
    /// so any model (no portable file-input wire) sees clearly-delimited file
    /// content inline. No size cap (the user pays their own bill).
    ///
    /// **Robust fencing (Codex #3 — latent bug fix):** a naive 3-backtick fence
    /// BREAKS when the file content itself contains a ``` run (e.g. a Markdown
    /// file with code blocks) — the inner ``` prematurely closes the outer fence,
    /// so the model mis-reads where the file ends and the user's instructions
    /// resume. We compute a fence LONGER than the longest backtick run anywhere in
    /// the content (min 3) so the file body can never contain a matching closer.
    /// The label also tags the block as UNTRUSTED user-provided file data (the
    /// content is not an instruction to the model — a prompt-injection guardrail).
    static func spliceText(
        _ base: String,
        textFileBlocks: [(filename: String, text: String)]
    ) -> String {
        guard !textFileBlocks.isEmpty else { return base }
        var pieces: [String] = base.isEmpty ? [] : [base]
        for block in textFileBlocks {
            let fence = Self.safeFence(for: block.text)
            pieces.append("--- \(block.filename) (untrusted user-provided file contents) ---\n\(fence)\n\(block.text)\n\(fence)")
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Compute a backtick fence guaranteed not to appear as a run inside `content`:
    /// one longer than the longest consecutive-backtick run in the text, with a
    /// floor of 3 (standard Markdown fence). So a file containing ` ``` ` gets a
    /// 4-backtick fence; ` ```` ` gets 5; plain text gets 3.
    static func safeFence(for content: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for character in content {
            if character == "`" {
                currentRun += 1
                if currentRun > longestRun { longestRun = currentRun }
            } else {
                currentRun = 0
            }
        }
        let fenceLength = max(3, longestRun + 1)
        return String(repeating: "`", count: fenceLength)
    }

    /// Splice a SERVER-FILE reference block into a turn's text (file-transfer
    /// route). Empty `serverFiles` returns `base` unchanged (the common
    /// text/image-only fast path). Otherwise a single human-readable block is
    /// appended AFTER the base text + any text-file fenced blocks — never as a
    /// content part: the real bytes live in the agent's working folder (the user
    /// PUT them to the file-server), so the model only needs to be TOLD which
    /// files are there + the opaque path they were saved under. Rendered as:
    ///
    ///     The following file(s) are in your working directory — use them for this request. Each input lives under its conversation folder at the path shown:
    ///     - report.pdf (saved as <conversationID>/a1b2c3d4__report.pdf)
    ///
    /// (one bullet per file: `- <originalName> (saved as <storedKey>)`, where
    /// `storedKey` now carries the per-conversation folder prefix). Joined to the
    /// base with `"\n\n"` — the same joining idiom `spliceText` uses — so a turn's
    /// assembled text reads base → text-file fences → server-file refs.
    ///
    /// This block is a pure INPUT reference — output guidance lives in the single
    /// per-turn `fileDeliveryInstruction` (appended once by `assembleMessages`,
    /// newest turn only). It CANNOT live here: this splice also runs on every
    /// REPLAYED prior turn (`priorTurns` reconstruction), so an instruction
    /// clause in this header would duplicate across the whole resent history.
    ///
    /// PRIVACY: `storedKey` + `originalName` are part of the turn the user
    /// deliberately sends to their OWN gateway; this method never logs them.
    static func spliceServerFileRefs(
        _ base: String,
        serverFiles: [(originalName: String, storedKey: String)]
    ) -> String {
        guard !serverFiles.isEmpty else { return base }
        var lines = ["The following file(s) are in your working directory — use them for this request. Each input lives under its conversation folder at the path shown:"]
        for file in serverFiles {
            lines.append("- \(file.originalName) (saved as \(file.storedKey))")
        }
        let block = lines.joined(separator: "\n")
        return base.isEmpty ? block : [base, block].joined(separator: "\n\n")
    }

    /// The single per-turn file-DELIVERY instruction (file-transfer route).
    /// Appended once — newest user turn only, via `assembleMessages` — whenever
    /// the conversation's bound gateway has a READY file lane
    /// (`fileTransferReadySnapshot != nil`), attachments or not.
    ///
    /// Why it exists (verified live against OpenClaw, July 2026): agent
    /// platforms deliver output files via channel-attachment directives (e.g. a
    /// `MEDIA:<path>` reply line) that the OpenAI-compatible endpoint STRIPS —
    /// the reply reaches Conduck file-less and nameless, so output detection
    /// (which scans reply text for filenames, then probes the file-server)
    /// correctly finds nothing and the download chip never appears. The
    /// instruction pins the one contract that works on EVERY gateway: write the
    /// file to the working-directory root (where the detector probes) and NAME
    /// it in plain reply text.
    ///
    /// Why per-turn wire text (not gateway-side config): it is the only layer
    /// Conduck controls for arbitrary BYO gateways, and it beats session-start
    /// bootstrap files (OpenClaw injects `TOOLS.md` at session START only — an
    /// edit never reaches a running session). It also rides on attachment-LESS
    /// turns — "write me a report.md" with nothing attached is exactly the turn
    /// the reference splices above can't cover.
    ///
    /// Why the wording: the request may visibly carry inline images, so it must
    /// NOT claim "this channel has no attachments" — the claim is strictly about
    /// the reply direction (attachment directives don't reach the user). The
    /// `[Conduck file transfer]` tag gives gateway-side agent instructions
    /// (e.g. the conduck-connect `TOOLS.md` block) a deterministic marker to
    /// scope on, so a rule like "no MEDIA: in Conduck sessions" can be gated to
    /// Conduck turns and never leak into the same agent's WhatsApp/Telegram
    /// channels, where MEDIA: is correct.
    static let fileDeliveryInstruction =
        "[Conduck file transfer] To return a file, write it to the root of your working directory and state its exact filename in plain text in your reply. Attachment directives (MEDIA: lines or similar) do not reach this user — only files named in plain reply text are delivered."

    /// Append `fileDeliveryInstruction` to a fully-spliced turn text. LAST in
    /// the text-body order (base → text-file fences → server refs → image refs →
    /// dual-text refs → THIS), newest user turn only — see `assembleMessages`.
    static func spliceFileDeliveryInstruction(_ base: String) -> String {
        base.isEmpty ? fileDeliveryInstruction : [base, fileDeliveryInstruction].joined(separator: "\n\n")
    }

    /// The dispatch SURFACE a converse request originates from, gating the
    /// per-turn spoken-summary clause below. `.standard` is every read-first
    /// surface (foreground iOS/iPad/Mac composer, ConverseIntent, background
    /// iOS) — no spoken clause. `.spoken` is the compact hands-busy voice
    /// surfaces (CarPlay + Apple Watch), whose reply is heard aloud on a glance
    /// device. Defaulted to `.standard` at every `assembleMessages` call site
    /// so read-first surfaces stay byte-identical without an edit.
    enum Surface: Sendable {
        case standard
        case spoken
    }

    /// The single per-turn SPOKEN-SUMMARY instruction for voice surfaces
    /// (CarPlay + Apple Watch). Appended once — newest user turn only, via
    /// `assembleMessages` when `surface == .spoken` — AFTER the file-delivery
    /// instruction (when a ready lane also splices it).
    ///
    /// Why it exists: a voice-surface reply is HEARD aloud on a compact,
    /// hands-busy device, so an agent that recites a file's full contents,
    /// code, or a long URL produces an unusable spoken wall. The clause tells
    /// the agent to name the artifact's exact filename and summarize the useful
    /// result in a sentence or two of spoken-friendly prose instead.
    ///
    /// Why the `[Conduck voice]` tag: it MIRRORS the `[Conduck file transfer]`
    /// tag's purpose — a deterministic marker gateway-side agent instructions
    /// can scope on (a rule keyed to Conduck voice turns never leaks into the
    /// same agent's read-first channels). Unlike the delivery instruction, this
    /// clause makes NO delivery promise — no working-directory contract, no
    /// filename-in-reply requirement tied to a file lane — so it rides even
    /// when the surface has NO file lane at all (the agent can still create an
    /// artifact in its own workspace, and the clause only shapes how the reply
    /// is spoken). That lane-independence is why it splices unconditionally on
    /// a spoken surface, separate from the `fileServerReady` gate.
    static let spokenSummaryInstruction =
        "[Conduck voice] The user will likely hear this reply aloud on a compact, hands-busy device (Apple Watch or in the car) rather than read it. If your work produces a file or another long artifact, say its exact filename and summarize the useful result in one to three short spoken-friendly sentences. Never read long file contents, code, or URLs aloud."

    /// Append `spokenSummaryInstruction` to a fully-spliced turn text. Splices
    /// AFTER `spliceFileDeliveryInstruction` (when the lane is ready) so the
    /// text-body order on a ready-lane spoken turn reads
    /// … → delivery instruction → THIS, newest user turn only — see
    /// `assembleMessages`. Mirrors `spliceFileDeliveryInstruction`.
    static func spliceSpokenSummaryInstruction(_ base: String) -> String {
        base.isEmpty ? spokenSummaryInstruction : [base, spokenSummaryInstruction].joined(separator: "\n\n")
    }

    /// Splice a DUAL-TEXT server-file reference block into a turn's text (the
    /// dual-text route: a composer text/code file rides BOTH inline as a fenced
    /// block AND uploads its byte-faithful original to the file-server so the
    /// agent's tools can run / modify / derive from the REAL file). Empty
    /// `textFiles` returns `base` unchanged (the inline-only fast path — no
    /// file-server, or the eager upload hadn't landed by send time). Otherwise a
    /// single block is appended AFTER the base text + any text-file fenced blocks +
    /// any non-image server-file refs — never as a content part: the readable
    /// contents already ride inline (the model can READ them cheaply), so this
    /// block only TELLS the agent the same file is ALSO on disk for TOOL
    /// operations, and not to reopen it merely to summarize what's already inline
    /// (redundant-read suppression — distinct from the imperative
    /// `spliceServerFileRefs`, which is for files whose bytes never ride inline).
    /// Rendered as:
    ///
    ///     The readable contents of the file(s) below are already included above. The byte-faithful original of each is also saved in your working directory at the path shown — use it for file-tool operations (run / modify / produce derived files). Do not reopen it merely to summarize the included contents:
    ///     - notes.md (saved as <conversationID>/a1b2c3d4__notes.md)
    ///
    /// (one bullet per file: `- <originalName> (saved as <storedKey>)`, where
    /// `storedKey` carries the per-conversation folder prefix). Joined to the base
    /// with `"\n\n"` — the same idiom the other splices use — so a turn's assembled
    /// text reads base → text-file fences → non-image server refs → image refs →
    /// dual-text disk refs.
    ///
    /// PRIVACY: `storedKey` + `originalName` are part of the turn the user
    /// deliberately sends to their OWN gateway; this method never logs them.
    static func spliceTextFileServerRefs(
        _ base: String,
        textFiles: [(originalName: String, storedKey: String)]
    ) -> String {
        guard !textFiles.isEmpty else { return base }
        var lines = ["The readable contents of the file(s) below are already included above. The byte-faithful original of each is also saved in your working directory at the path shown — use it for file-tool operations (run / modify / produce derived files). Do not reopen it merely to summarize the included contents:"]
        for file in textFiles {
            lines.append("- \(file.originalName) (saved as \(file.storedKey))")
        }
        let block = lines.joined(separator: "\n")
        return base.isEmpty ? block : [base, block].joined(separator: "\n\n")
    }

    /// Splice an IMAGE server-file reference block into a turn's text (the
    /// dual-image route: a composer image rides BOTH inline as base64 vision AND
    /// uploads its ORIGINAL RAW bytes to the file-server so the agent can EDIT
    /// it). Empty `images` returns `base` unchanged (the inline-only fast path —
    /// no file-server, or the eager upload hadn't landed by send time). Otherwise
    /// a single block is appended AFTER the base text + any text-file fenced
    /// blocks + any non-image server-file refs — never as a content part: the
    /// image bytes already ride inline as `image_url` parts (vision sees the
    /// downsized JPEG), so this block only TELLS the agent the same image is ALSO
    /// saved as a file (the untouched original) it may modify/process, and not to
    /// open it just to describe it (redundant-read suppression — the inline copy
    /// is the cheaper read for description/Q&A). Rendered as:
    ///
    ///     You can already see the attached image(s); the file(s) below are there only if you're asked to modify or process them — don't open them just to describe or answer questions about them:
    ///     - image.heic (saved as a1b2c3d4__image.heic)
    ///
    /// Each `filename` is the SYNTHETIC display name with the original's TRUE
    /// extension (privacy — a composer image's real filename never travels, but
    /// its real FORMAT does, so the agent's tooling knows it's a `.heic` /
    /// `.png` / `.dng`, not a fabricated `.jpg`). The host synthesizes the name
    /// by POSITION (`image.<ext>` for the first, `image-N.<ext>` after). Joined
    /// to the base with `"\n\n"` — the same idiom `spliceServerFileRefs` uses —
    /// so a turn's assembled text reads base → text-file fences → server-file
    /// refs → image refs.
    ///
    /// PRIVACY: `storedKey` + `filename` are part of the turn the user
    /// deliberately sends to their OWN gateway; this method never logs them. The
    /// synthetic position-based name carries no user filename — only the format.
    ///
    /// `images` is the ordered list of `(storedKey, filename)` pairs (one per
    /// composer image whose eager upload landed).
    static func spliceImageServerRefs(
        _ base: String,
        images: [(storedKey: String, filename: String)]
    ) -> String {
        guard !images.isEmpty else { return base }
        var lines = ["You can already see the attached image(s); the file(s) below are there only if you're asked to modify or process them — don't open them just to describe or answer questions about them:"]
        for image in images {
            lines.append("- \(image.filename) (saved as \(image.storedKey))")
        }
        let block = lines.joined(separator: "\n")
        return base.isEmpty ? block : [base, block].joined(separator: "\n\n")
    }

    /// Splice an IMAGE **text reference** block for an OLDER prior turn whose
    /// inline image bytes have been DROPPED from the wire (the per-gateway
    /// `ImageHistoryPolicy` window: only the newest N image-bearing turns ride
    /// inline; beyond that, an image uploaded once to the gateway file-server
    /// is REFERENCED, not re-shipped — and an expired mixed turn splices its
    /// keyed subset here too). This is DISTINCT from `spliceImageServerRefs`
    /// (the CURRENT-turn dual-image wording) on purpose: that wording says *"you
    /// can already see the attached image… don't open them just to describe"* —
    /// reusing it here would train the agent AWAY from reopening, but for an aged
    /// image there is NO inline copy on the wire, so the agent MUST reopen the file
    /// to see pixels. The wording is therefore IMPERATIVE: the image is no longer
    /// visible inline, open/read it from disk if the user asks about visual detail.
    /// Rendered as:
    ///
    ///     Earlier image(s) from this conversation are no longer attached inline but remain saved on disk at the path(s) below. If the user asks about visual details not covered by the text history, open/read the file before answering:
    ///     - image.heic (saved as <conversationID>/a1b2c3d4__image.heic)
    ///
    /// (one bullet per image: `- <filename> (saved as <storedKey>)`, where
    /// `storedKey` carries the per-conversation folder prefix so the agent has the
    /// exact on-disk path). Empty `images` returns `base` unchanged. Joined to the
    /// base with `"\n\n"` — the same idiom as the other splices.
    ///
    /// PRIVACY: `storedKey` + `filename` are part of the turn the user already
    /// sent to their OWN gateway; this method never logs them.
    static func spliceImageTextRefs(
        _ base: String,
        images: [(storedKey: String, filename: String)]
    ) -> String {
        guard !images.isEmpty else { return base }
        var lines = ["Earlier image(s) from this conversation are no longer attached inline but remain saved on disk at the path(s) below. If the user asks about visual details not covered by the text history, open/read the file before answering:"]
        for image in images {
            lines.append("- \(image.filename) (saved as \(image.storedKey))")
        }
        let block = lines.joined(separator: "\n")
        return base.isEmpty ? block : [base, block].joined(separator: "\n\n")
    }

    /// Splice an IMAGE-UNAVAILABLE note for a prior turn whose images can
    /// NEITHER ride inline (the caller never resolved `dataURIsByMessageID` for
    /// it) NOR be referenced on disk (at least one image has no persisted
    /// `storedKey`). The constraint this encodes: a turn that carried images
    /// must never silently flatten to bare text — a model re-reading the history
    /// would see plain text where it once saw pixels, deny the images ever
    /// existed, and retro-claim its own earlier (correct) vision answer was a
    /// hallucination (real observed failure). The wording is honest +
    /// prohibitive: the images are gone from this request, say so, ask for a
    /// re-attach, never guess. `imageCount <= 0` returns `base` unchanged (the
    /// no-image fast path). Rendered as:
    ///
    ///     2 image(s) were attached to this message but are not included in this request and are not otherwise available to you. If the user asks about their visual content, say you can no longer see these image(s) and ask the user to re-attach them if needed — do not guess.
    ///
    /// Joined to the base with `"\n\n"` — the same idiom as the other splices.
    /// DISTINCT from `spliceImageTextRefs` on purpose: that wording points at an
    /// on-disk file the agent CAN re-open; here there is no file — borrowing the
    /// imperative open-the-file wording would trade one confabulation for
    /// another (the agent would go open a path that does not exist).
    static func spliceImageUnavailableNote(_ base: String, imageCount: Int) -> String {
        guard imageCount > 0 else { return base }
        let note = "\(imageCount) image(s) were attached to this message but are not included in this request and are not otherwise available to you. If the user asks about their visual content, say you can no longer see these image(s) and ask the user to re-attach them if needed — do not guess."
        return base.isEmpty ? note : [base, note].joined(separator: "\n\n")
    }

    /// Splice label for a text attachment: prefer the stored original
    /// `filename` (e.g. "report.csv"); fall back to a mimeType-derived name for
    /// legacy rows persisted before the `filename` column existed.
    private static func filename(for attachment: AttachmentRecord) -> String {
        if let name = attachment.filename, !name.isEmpty { return name }
        switch attachment.mimeType {
        case "text/markdown": return "file.md"
        case "text/csv": return "file.csv"
        case "application/json": return "file.json"
        case "text/plain": return "file.txt"
        default: return "file.txt"
        }
    }
}

/// OpenAI-compatible chat-completions response body. Decoding is TOLERANT
/// of unknown top-level fields — gateways routinely add `model`, `usage`,
/// `id`, `created`, `system_fingerprint`, etc. We extract only what we
/// need (`choices[0].message.content`); anything else is silently ignored.
///
/// Decoding-side errors (`choices` missing, `choices` empty,
/// `message.content` missing) surface to callers as `DecodingError` and
/// are translated to `AppError.remoteAgentInvalidResponse` by
/// `RemoteAgentClient.decodeReply`.
struct ConverseResponse: Decodable, Sendable {
    let choices: [Choice]

    struct Choice: Decodable, Sendable {
        let message: Message
    }

    struct Message: Decodable, Sendable {
        let content: String
    }

    /// Convenience accessor for the only field V1 cares about. Returns
    /// `nil` when the response has no choices — caller maps that to
    /// `.remoteAgentInvalidResponse`.
    var firstReplyContent: String? {
        choices.first?.message.content
    }
}

// MARK: - Converse latency/shape diagnostics (DEBUG only)

#if DEBUG
/// DEBUG-only latency/shape observability for the converse hop.
///
/// Purpose: pin where converse latency is spent — in particular the
/// "image-after-text is ~10× slower than image-as-first-turn" case. That slow
/// case is the ONLY one producing a MIXED-shape `messages[]` (bare-string text
/// turns + one `.parts` image turn); logging the assembled shape + client-side
/// send→done timing proves what the app emits and attributes the wall-clock to
/// the gateway, not the device. Pairs with `Conduck/scripts/wire-latency-probe.sh`.
///
/// PRIVACY (spec.md "Privacy & Security" — non-negotiable): METADATA ONLY. Never reads or logs
/// message content, image bytes, gateway URLs, or bearer tokens — only roles,
/// content KIND (text vs parts), part/image counts, byte SIZES, elapsed time.
/// Compiled out of Release entirely (`#if DEBUG`).
///
/// Inspect:  log stream --predicate 'subsystem == "ai.gigaduck.agentrelay.diag"'
/// (official build — the subsystem is `Constants.identityNamespace` + ".diag")
///
/// Lives in this file (not its own) so it inherits `ConverseRequest`'s target
/// membership (app + Watch) without a project.pbxproj edit.
enum RemoteAgentDiagnostics {
    static let log = Logger(subsystem: Constants.identityNamespace + ".diag", category: "converse")

    /// One-line, content-free summary of an assembled `messages[]` array: per-turn
    /// `role:kind` (kind = `text` or `parts(N,imgM)`), whether the overall request
    /// is `uniform` (all-text or all-parts) or **MIXED** (the image-after-text
    /// suspect), the turn count, and the encoded body size. No content is read.
    static func shapeSummary(_ messages: [ConverseRequest.Message], bodyBytes: Int) -> String {
        var kinds: [String] = []
        var sawText = false
        var sawParts = false
        for message in messages {
            switch message.content {
            case .text:
                sawText = true
                kinds.append("\(message.role):text")
            case .parts(let parts):
                sawParts = true
                let images = parts.reduce(0) { acc, part in
                    if case .imageURL = part { return acc + 1 }
                    return acc
                }
                kinds.append("\(message.role):parts(\(parts.count),img\(images))")
            }
        }
        let shape = (sawText && sawParts) ? "MIXED" : "uniform"
        return "shape=\(shape) turns=\(messages.count) bytes=\(bodyBytes) [\(kinds.joined(separator: ", "))]"
    }
}
#endif
