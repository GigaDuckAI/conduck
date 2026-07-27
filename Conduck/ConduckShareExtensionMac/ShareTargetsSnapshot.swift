// SPDX-License-Identifier: Apache-2.0

// Conduck — ConduckShareExtensionMac (macOS appex)
// ShareTargetsSnapshot.swift
//
// ⚠️ VERBATIM MIRROR — keep byte-identical below this header to
// Conduck/Conduck/Conduck/Models/ShareTargetsSnapshot.swift
//
// The main app (writer) and this appex picker (reader) are SEPARATE compilation
// modules — Swift compiles the contract once per module, so there is no single
// shared symbol either way; carrying one source file per module keeps this 120 MB-
// capped appex SELF-CONTAINED (no app-graph coupling, no cross-target membership,
// no .pbxproj surgery) instead of linking the main-app file across targets.
//
// KEEP THE TWO FILES BYTE-IDENTICAL BELOW THEIR HEADERS. The on-disk wire bytes are
// pinned by `encoded()` (`.iso8601` + `.sortedKeys`); ANY change here MUST be
// mirrored in the main-app file (and vice-versa) or the appex will be unable to
// decode the snapshot the app wrote (→ empty picker). Drift guard: `ConduckTests/
// ShareTargetsSnapshotTests` freezes the wire shape AND asserts this mirror is
// byte-identical to the canonical below the header.
//
// The doc comments below are the canonical file's, kept verbatim for diffability.
import Foundation

/// The flattened "Send to" target list the main app publishes for the appex picker.
/// Codable + Sendable so it crosses the app → App-Group-disk → appex boundary as
/// plain JSON.
struct ShareTargetsSnapshot: Codable, Sendable {
    /// Schema version (currently 1). Diagnostic + future branch point — readers
    /// tolerate any value (never reject on `schemaVersion` alone; see file header).
    let schemaVersion: Int
    /// When the main app last regenerated the snapshot (diagnostic / staleness).
    let generatedAt: Date
    /// Configured gateways the user can start a NEW conversation with, in display
    /// order. May be empty (no gateway configured yet).
    let gateways: [Gateway]
    /// Existing conversations the user can APPEND a share to, most-recent-first.
    /// May be empty (a fresh install with no conversations).
    let recentConversations: [RecentConversation]

    /// One gateway the picker offers for a NEW conversation. Every render value is
    /// pre-resolved main-app-side (the appex can't reach the palette enum).
    struct Gateway: Codable, Sendable {
        /// `RemoteAgentRef` rawString: `"openclaw"` / `"hermes"` / `"custom_<uuid>"`.
        /// The ref the drainer mints the new conversation against.
        let ref: String
        /// Display label, e.g. `"OpenClaw"`, `"Hermes"`, or the custom name.
        let displayName: String
        /// Resolved badge color `"#RRGGBB"` — the appex renders it directly (it
        /// cannot reach the palette enum to resolve a semantic color itself).
        let colorHex: String
        /// 1–2 char badge label.
        let monogram: String
        /// Whether the gateway has BOTH a URL + token, i.e. a new conversation can
        /// actually be created against it (an unconfigured gateway is shown disabled).
        let configured: Bool

        // MARK: - Tolerant decode

        private enum CodingKeys: String, CodingKey {
            case ref, displayName, colorHex, monogram, configured
        }

        init(
            ref: String,
            displayName: String,
            colorHex: String,
            monogram: String,
            configured: Bool
        ) {
            self.ref = ref
            self.displayName = displayName
            self.colorHex = colorHex
            self.monogram = monogram
            self.configured = configured
        }

        /// `ref` is the only required field (a gateway without a ref can't be
        /// routed); every render value default-fills so a future schema addition
        /// can't break an old snapshot.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.ref = try c.decode(String.self, forKey: .ref)
            self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
            self.colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? ""
            self.monogram = try c.decodeIfPresent(String.self, forKey: .monogram) ?? ""
            self.configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        }
    }

    /// One existing conversation the picker offers for APPEND.
    struct RecentConversation: Codable, Sendable {
        /// Conversation identity — the drainer appends the shared turn under it.
        let id: UUID
        /// Derived display label (title ?? first-user-turn snippet ?? "New Conversation").
        let label: String
        /// The conversation's bound gateway rawString (so the appex can show which
        /// gateway it will land in).
        let backendRef: String
        /// Last-activity timestamp — drives the most-recent-first ordering.
        let lastActivityAt: Date

        // MARK: - Tolerant decode

        private enum CodingKeys: String, CodingKey {
            case id, label, backendRef, lastActivityAt
        }

        init(
            id: UUID,
            label: String,
            backendRef: String,
            lastActivityAt: Date
        ) {
            self.id = id
            self.label = label
            self.backendRef = backendRef
            self.lastActivityAt = lastActivityAt
        }

        /// `id` is the only required field (without it the appex can't target the
        /// conversation); everything else default-fills on a decode miss.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
            self.backendRef = try c.decodeIfPresent(String.self, forKey: .backendRef) ?? ""
            self.lastActivityAt = try c.decodeIfPresent(Date.self, forKey: .lastActivityAt) ?? Date(timeIntervalSince1970: 0)
        }
    }

    // MARK: - Tolerant decode

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, gateways, recentConversations
    }

    init(
        schemaVersion: Int,
        generatedAt: Date,
        gateways: [Gateway],
        recentConversations: [RecentConversation]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.gateways = gateways
        self.recentConversations = recentConversations
    }

    /// Nothing is hard-required at the top level — a snapshot with no targets is a
    /// valid (empty) picker. Every field default-fills on a decode miss so a
    /// newer-schema snapshot still decodes:
    ///   - `schemaVersion` → 1 (assume the original schema)
    ///   - `generatedAt` → epoch (a missing stamp reads as maximally stale)
    ///   - `gateways`/`recentConversations` → [] (empty picker, not a throw)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        self.generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date(timeIntervalSince1970: 0)
        self.gateways = try c.decodeIfPresent([Gateway].self, forKey: .gateways) ?? []
        self.recentConversations = try c.decodeIfPresent([RecentConversation].self, forKey: .recentConversations) ?? []
    }
}

extension ShareTargetsSnapshot {

    // MARK: - Cross-process JSON contract (LOAD-BEARING)

    // The main app (writer) and the appex picker (reader) are SEPARATE binaries.
    // A bare `JSONEncoder()`/`JSONDecoder()` defaults to `.deferredToDate` for
    // `Date` — but if one side ever set a different `dateEncodingStrategy`, the two
    // processes would silently fail to decode `generatedAt`/`lastActivityAt`. Pin
    // the strategy HERE (ISO-8601, human-glanceable in the on-disk snapshot) and
    // route BOTH sides through `encoded()` / `decode(_:)` so they can never drift.
    // Never encode/decode a `ShareTargetsSnapshot` with an ad-hoc coder.

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

    /// Serialize for the on-disk App-Group snapshot (main-app write side).
    func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Deserialize the snapshot (appex read side). A malformed payload returns
    /// `nil` (the appex falls back to its default target) instead of throwing.
    /// Tolerant per-field decode still applies (see `init(from:)`).
    static func decode(_ data: Data) -> ShareTargetsSnapshot? {
        try? makeDecoder().decode(ShareTargetsSnapshot.self, from: data)
    }
}
