// Conduck — ConduckShareExtension (appex)
// SharedInboxManifest.swift
//
// ⚠️ VERBATIM MIRROR of the main-app `Conduck/Models/SharedInboxManifest.swift`
// The appex (writer) and the main-app `SharedInboxDrainer` (reader) are
// SEPARATE compilation modules — Swift compiles the contract once per module, so
// there is no single shared symbol either way; carrying one source file per module
// keeps this 120 MB-capped appex SELF-CONTAINED (no app-graph coupling, no
// cross-target membership, no .pbxproj surgery) instead of linking the main-app
// file across targets.
//
// KEEP THE TWO FILES BYTE-IDENTICAL BELOW THEIR HEADERS. The on-disk wire bytes
// are pinned by `encoded()` (`.iso8601` + `.sortedKeys`); ANY change here MUST be
// mirrored in the main-app file (and vice-versa) or the appex will write a
// manifest the drainer cannot decode. Drift guard: `ConduckTests/
// SharedInboxManifestTests` freezes the wire shape on the main-app side.
//
// The doc comments below are the canonical file's, kept verbatim for diffability.

import Foundation

/// One queued share envelope. Codable + Sendable so it crosses the appex →
/// App-Group-disk → drainer boundary as plain JSON. The `uuid` is the envelope
/// identity AND becomes the user `Message.id` (the dedupe key that makes a
/// re-drain idempotent — see `ConversationStore.appendMessage(id:)`).
struct SharedInboxManifest: Codable, Sendable {
    /// Schema version (currently 1). Diagnostic + future branch point — readers
    /// tolerate any value (never reject on `v` alone; see file header).
    let v: Int
    /// Envelope id. ALSO the user `Message.id` the drainer appends under, so a
    /// re-drain of the same envelope is a no-op (dedupe key).
    let uuid: UUID
    /// When the appex published the envelope (used by the janitor's stale sweep).
    let createdAt: Date
    /// User-entered caption text; may be `""` (a photo-only share).
    let caption: String
    /// Explicit "New conversation" override the user picked in the appex; `nil`
    /// means auto-route (the drainer resolves-or-mints via the shared routing
    /// helper, exactly like a headless capture).
    let conversationID: UUID?
    /// Gateway ref (`openclaw`/`hermes`/`custom_<uuid>`) the user picked via
    /// "New conversation in <Gateway>"; `nil` unless they explicitly chose a
    /// gateway for a NEW conversation (the drainer mints the conversation bound
    /// to this ref instead of the default-routing one).
    let newConversationGatewayRef: String?
    /// The gateway ref the chosen EXISTING conversation was bound to, captured at
    /// share time as a fallback hint should that conversation be deleted before
    /// the drain runs; `nil` for new/legacy envelopes.
    let selectedBackendRef: String?
    /// File attachments copied into the envelope dir, ordered by `sequence`.
    let items: [Item]
    /// Normalized shared web URLs (already de-duped + `file://` rejected by the
    /// appex's activation predicate). Carried inline — never a file.
    let urls: [String]
    /// Whether the drainer should auto-send (vs. prefill + wait) — the user's
    /// "Auto-send shared content" setting, captured at share time.
    let shouldAutosend: Bool

    /// One copied file attachment inside the envelope dir.
    struct Item: Codable, Sendable {
        /// Path RELATIVE to the envelope dir, e.g. `"att-0.heic"` — never an
        /// absolute path (the dir is moved tmp/ → published/ → processing/ during
        /// the drain, so only the relative component is stable).
        let relPath: String
        /// The original filename the source app provided, when known.
        let originalName: String?
        /// The MIME type the source app provided, when known.
        let mimeType: String?
        /// The UTI the item conformed to (`"public.jpeg"`, `"com.adobe.pdf"`, …)
        /// — drives the drainer's per-type transport classification.
        let utTypeIdentifier: String?
        /// Stable ordering within the envelope (mirrors `AttachmentDraft.sequence`
        /// + the deterministic upload key's `<sequence>` segment).
        let sequence: Int
        /// Provenance marker — `WebPageCapture.sourceKindWebpage` (`"webpage"`)
        /// when the appex SYNTHESIZED this item from a Safari page-text capture
        /// (drives the drainer's webpage-only behavior: `originalName` as the
        /// display filename + the no-file-server inline clamp); `nil` for every
        /// user-shared file (filename convention is NOT identity). Tolerant:
        /// absent on pre-capture envelopes → `nil`; nil is OMITTED from the
        /// wire (synthesized `encodeIfPresent`) so non-webpage bytes are
        /// unchanged.
        let sourceKind: String?

        // MARK: - Tolerant decode

        private enum CodingKeys: String, CodingKey {
            case relPath, originalName, mimeType, utTypeIdentifier, sequence
            case sourceKind
        }

        init(
            relPath: String,
            originalName: String?,
            mimeType: String?,
            utTypeIdentifier: String?,
            sequence: Int,
            sourceKind: String? = nil
        ) {
            self.relPath = relPath
            self.originalName = originalName
            self.mimeType = mimeType
            self.utTypeIdentifier = utTypeIdentifier
            self.sequence = sequence
            self.sourceKind = sourceKind
        }

        /// `relPath` is the only required field (an item without bytes is
        /// meaningless); every other field default-fills so a future schema
        /// addition can't break an old envelope.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.relPath = try c.decode(String.self, forKey: .relPath)
            self.originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
            self.mimeType = try c.decodeIfPresent(String.self, forKey: .mimeType)
            self.utTypeIdentifier = try c.decodeIfPresent(String.self, forKey: .utTypeIdentifier)
            self.sequence = try c.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
            self.sourceKind = try c.decodeIfPresent(String.self, forKey: .sourceKind)
        }
    }

    // MARK: - Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case v, uuid, createdAt, caption, conversationID
        case newConversationGatewayRef, selectedBackendRef
        case items, urls, shouldAutosend
    }

    init(
        v: Int,
        uuid: UUID,
        createdAt: Date,
        caption: String,
        conversationID: UUID?,
        newConversationGatewayRef: String?,
        selectedBackendRef: String?,
        items: [Item],
        urls: [String],
        shouldAutosend: Bool
    ) {
        self.v = v
        self.uuid = uuid
        self.createdAt = createdAt
        self.caption = caption
        self.conversationID = conversationID
        self.newConversationGatewayRef = newConversationGatewayRef
        self.selectedBackendRef = selectedBackendRef
        self.items = items
        self.urls = urls
        self.shouldAutosend = shouldAutosend
    }

    /// `uuid` is the only hard-required field (it is the envelope identity + the
    /// dedupe key — an envelope without it can't be routed). Everything else
    /// default-fills on a decode miss so a newer-schema envelope still decodes:
    ///   - `v` → 1 (assume the original schema)
    ///   - `createdAt` → now (a missing stamp shouldn't make the janitor sweep it)
    ///   - `caption` → "" · `items`/`urls` → [] · `shouldAutosend` → false
    ///   - `conversationID` → nil (auto-route)
    ///   - `newConversationGatewayRef`/`selectedBackendRef` → nil (an OLD envelope
    ///     written before these fields existed still decodes — no gateway hint)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.uuid = try c.decode(UUID.self, forKey: .uuid)
        self.v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
        self.conversationID = try c.decodeIfPresent(UUID.self, forKey: .conversationID)
        self.newConversationGatewayRef = try c.decodeIfPresent(String.self, forKey: .newConversationGatewayRef)
        self.selectedBackendRef = try c.decodeIfPresent(String.self, forKey: .selectedBackendRef)
        self.items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        self.urls = try c.decodeIfPresent([String].self, forKey: .urls) ?? []
        self.shouldAutosend = try c.decodeIfPresent(Bool.self, forKey: .shouldAutosend) ?? false
    }
}

/// Top-level spelling of the nested item type — the appex references the item by
/// this name. Keeps the writer (appex) and reader (drainer) on one symbol.
typealias SharedInboxManifestItem = SharedInboxManifest.Item

extension SharedInboxManifest {

    // MARK: - Cross-process JSON contract (LOAD-BEARING)

    // The appex (writer) and the main-app drainer (reader) are SEPARATE binaries.
    // A bare `JSONEncoder()`/`JSONDecoder()` defaults to `.deferredToDate` for
    // `Date` — but if one side ever set a different `dateEncodingStrategy`, the
    // two processes would silently fail to decode `createdAt`. Pin the strategy
    // HERE (ISO-8601, human-glanceable in the on-disk manifest) and route BOTH
    // sides through `encoded()` / `decode(_:)` so they can never drift. Never
    // encode/decode a `SharedInboxManifest` with an ad-hoc coder.

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Serialize for the on-disk `manifest.json` (appex write side).
    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Deserialize a `manifest.json` (drainer read side). Tolerant per-field
    /// decode still applies (see `init(from:)`).
    static func decode(_ data: Data) throws -> SharedInboxManifest {
        try makeDecoder().decode(SharedInboxManifest.self, from: data)
    }
}
