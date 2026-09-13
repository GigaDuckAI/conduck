// SPDX-License-Identifier: Apache-2.0

// Conduck
// CustomGateway.swift
//
// Custom-gateways. The persisted ROSTER record for one user-defined custom
// OpenAI-compatible gateway. Only `id` + `name` + `model` + badge fields
// live here (the registry JSON under `Constants.customGatewaysRegistryKey`,
// App-Group + iCloud-KVS dual-write); the URL / bearer token / cert
// fingerprint ride the SAME per-ref slots as the built-ins
// (`SettingsManager.getRemoteAgentURL(for:)` etc.) — i.e. the built-in
// storage posture, extended. See `docs/ai-context/spec.md`.
//
// Pure value type — shared by the app AND Watch targets (Approach A
// membership exception in project.pbxproj).

import Foundation

/// One user-defined custom gateway's roster entry. URL/token/cert are NOT
/// here — they live in the per-ref storage slots keyed by `ref`.
struct CustomGateway: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    /// User-given label. Required at save. Drives the picker label + the
    /// default Watch/CarPlay badge monogram.
    var name: String
    /// Optional model name sent as the `"model"` field. Nil → omit (gateway
    /// default, identical to built-ins). Required by servers like vLLM/Ollama.
    var model: String?
    /// Badge color palette key (`RemoteAgentBadgePalette`). Nil → auto-assign
    /// the next unused palette slot at create time.
    var colorID: String?
    /// Badge monogram (1–2 chars). Nil → derive from `name`.
    var monogram: String?

    init(id: UUID, name: String, model: String? = nil, colorID: String? = nil, monogram: String? = nil) {
        self.id = id
        self.name = name
        self.model = model
        self.colorID = colorID
        self.monogram = monogram
    }

    var ref: RemoteAgentRef { .custom(id) }
}

/// Local display identity retained when a custom gateway leaves the roster.
/// Its last known name helps Usage identify the history; other surfaces retain
/// their existing generic-name badge adapter below. No connection details live here.
///
/// Forgetting a BUILT-IN keeps its badge for free — `RemoteAgentBackend.shortCode`
/// and the reserved palette hues are compiled in. Forgetting a CUSTOM used to
/// destroy its badge, because the roster entry that held the monogram and colour
/// WAS the identity; old conversations (which keep their `custom_<uuid>` binding
/// forever) then rendered a blank gap. This record closes that asymmetry.
///
/// **Deliberately NOT synced — App Group only, never iCloud KVS.** A monogram
/// can carry organization or personal identity and `retiredAt` carries timing,
/// so publishing tombstones would leak them into whatever iCloud account the
/// device is signed into next, and a restored backup would republish records the
/// user thought were gone. Instead every device DERIVES the same tombstone
/// independently: the device where the user forgot retires at the Forget site,
/// and peers retire when they observe the gateway disappear from the synced
/// roster. A disappearance preserves identity but is not proof of deletion:
/// only an explicit local Forget records `explicitlyRemovedAt`.
struct RetiredGatewayBadge: Codable, Sendable, Identifiable, Hashable {
    /// The forgotten gateway's uuid — matches `RemoteAgentRef.custom(id)` and
    /// the `Conversation.backend` string its conversations still carry.
    let id: UUID
    /// Frozen at retirement, up to two chars. Empty when a retained name has
    /// no drawable initials, such as an emoji-only label.
    var monogram: String
    /// Frozen RESOLVED palette id — never nil, so the colour is genuinely fixed
    /// rather than relying on today's happens-to-be-first fallback.
    var colorID: String
    /// When this device observed retirement. Orders the retention trim;
    /// a synced roster disappearance does not prove when or why it disappeared.
    var retiredAt: Date
    /// Last name known on this device. Absent in records saved by older builds.
    var lastKnownName: String? = nil
    /// Set only by explicit local Forget, never inferred from a roster shrink.
    var explicitlyRemovedAt: Date? = nil

    var ref: RemoteAgentRef { .custom(id) }

    /// Freeze a departing gateway's display identity. A valid name survives
    /// even without a drawable monogram; an entirely empty identity is skipped.
    ///
    /// The colour is resolved to a CONCRETE palette id rather than carrying the
    /// roster's optional: a nil / unknown `colorID` renders through a fallback,
    /// which would silently change hue if the palette were ever reordered, and
    /// "frozen" has to mean frozen.
    static func freeze(
        _ gateway: CustomGateway,
        at date: Date,
        explicitRemoval: Bool = false
    ) -> RetiredGatewayBadge? {
        let monogram = RemoteAgentRefMetadata.monogram(for: gateway.ref, customs: [gateway])
        let name = gateway.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !monogram.isEmpty || !name.isEmpty else { return nil }
        let colorID = RemoteAgentBadgePalette.customPalette
            .first(where: { $0.id == gateway.colorID })?.id
            ?? RemoteAgentBadgePalette.customPalette[0].id
        return RetiredGatewayBadge(
            id: gateway.id, monogram: monogram, colorID: colorID, retiredAt: date,
            lastKnownName: name.isEmpty ? nil : name,
            explicitlyRemovedAt: explicitRemoval ? date : nil
        )
    }
}

// The phone and the Watch each keep their OWN retirement records (they are
// derived independently and never couriered), but they must agree on what a
// record IS, how a list of them is ordered and trimmed, and how one merges with
// the live roster. These helpers are that single definition — this file already
// carries the app+Watch target-membership exception, so a new file would be the
// wrong home (it would silently miss the Watch target).
extension Array where Element == RetiredGatewayBadge {

    /// Insert a frozen record, newest first, trimmed to
    /// `Constants.maxRetiredGatewayBadges`.
    ///
    /// Idempotent: an already-retired uuid keeps its ORIGINAL identity, so a
    /// re-observed deletion (a peer's roster sync arriving after the local
    /// Forget) cannot rewrite history or reorder the trim. Returns nil when the
    /// list is unchanged, so a caller can skip a pointless persist. Explicit
    /// local intent can strengthen an uncertain record without reordering it.
    func retiring(_ badge: RetiredGatewayBadge) -> [RetiredGatewayBadge]? {
        if let index = firstIndex(where: { $0.id == badge.id }) {
            guard self[index].explicitlyRemovedAt == nil,
                  let removedAt = badge.explicitlyRemovedAt else { return nil }
            var updated = self
            updated[index].explicitlyRemovedAt = removedAt
            if updated[index].lastKnownName == nil {
                updated[index].lastKnownName = badge.lastKnownName
            }
            return updated
        }
        return (self + [badge])
            .sorted { ($0.retiredAt, $0.id.uuidString) > ($1.retiredAt, $1.id.uuidString) }
            .prefix(Constants.maxRetiredGatewayBadges)
            .map { $0 }
    }

    /// Drop records whose gateway is live again.
    ///
    /// A retirement can be derived from a roster that merely LOOKS shrunken —
    /// an iCloud initial-sync change carrying a server roster older than a
    /// gateway this device just created, for instance. `gatewayBadgeRoster`
    /// already prefers the live entry, so such a record is invisible, but it
    /// would otherwise hold a retention slot for the life of the install. This
    /// runs wherever the live roster is written, which makes the mistake
    /// self-correcting the moment the real roster arrives.
    func pruning(liveIDs: Set<UUID>) -> [RetiredGatewayBadge] {
        filter { !liveIDs.contains($0.id) }
    }
}

extension Array where Element == CustomGateway {

    /// The live roster plus the forgotten ones, in the single shape every badge
    /// resolver already takes. An ACTIVE entry always wins a uuid collision — a
    /// gateway retired and later recreated under the same uuid is live again,
    /// not a memory of one.
    ///
    /// This badge adapter keeps the SAME generic name a missing roster entry
    /// resolves to. Usage reads the historical identity separately; changing
    /// this adapter would change every existing surface that expects
    /// a real gateway name — "Gateway 'Forgotten gateway' is no longer
    /// available" in the recovery banner, and a placeholder in the Watch thread
    /// header. Only the monogram and colour are restored.
    func unioningRetired(_ retired: [RetiredGatewayBadge]) -> [CustomGateway] {
        let liveIDs = Set(map(\.id))
        return self + retired.pruning(liveIDs: liveIDs).map {
            CustomGateway(
                id: $0.id,
                name: RemoteAgentRefMetadata.genericCustomName,
                model: nil,
                colorID: $0.colorID,
                monogram: $0.monogram
            )
        }
    }
}
