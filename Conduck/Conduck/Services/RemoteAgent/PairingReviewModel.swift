// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingReviewModel.swift
//
// What the user is shown BEFORE a scanned/pasted setup code is allowed to
// configure anything — the content of the import review card.
//
// THE PROPERTY THIS FILE EXISTS TO CREATE: every fact ON THE CARD is either
// derived from the URL that will actually be stored, or read from LOCAL state.
// A hostile code can change WHERE the card points, which is the one thing the
// user is being asked to look at — it cannot change what the card SAYS about it.
//
// Scoped to the card, deliberately, because two payload-chosen strings ARE still
// imported: a custom gateway's `name` and its `model`. They are held to
// `PairingPayload.sanitizedDisplayText` (no control or bidi scalars, bounded
// length) and the name is further truncated on commit, so neither can spoof or
// corrupt what it appears in. They stay off the card because a name is the one
// field whose whole function is to look authoritative ("Acme Corp Gateway"), and
// a consent screen must not lend its own credibility to a caption its author
// wrote. After import both are ordinary local settings the user can edit.
//
// Recognition, not verification. A pairing code is a bearer credential and its
// whole payload is attacker-selectable, so no in-band field can prove the code
// came from someone trustworthy. What the card can do is show the destination
// truthfully enough that a person who knows their own server recognises it, and
// state plainly what accepting grants. That is the entire security claim; the
// certificate question is decided separately and afterwards by
// `PairingTrustDecision`, against the live server rather than against the code.
//
// Pure value type — no SwiftUI, no actor. Built by
// `SettingsViewModel.pairingReview(for:target:freshlyMinted:)`, which supplies
// the local-state facts, so the shape below stays independently testable.

import Foundation

struct PairingReviewModel: Equatable, Sendable {

    /// The file-transfer half. Both arms carry a destination because "same host
    /// as the gateway" is NOT a reason to hide it — `…example:443/agent` and
    /// `…example:9443/files` are different backends, as are two paths on one
    /// origin, and the file lane is where "reading or changing files" happens.
    enum FileLane: Equatable, Sendable {
        /// The code carries a file-server block; this is where files will go.
        /// `replacing` is the lane already configured at this target, if any.
        case incoming(destination: String, replacing: String?)
        /// The code carries NO file-server block and the target already has a
        /// lane — the deliberate keep-existing rule. Named explicitly because
        /// silence here reads as "my file transfer is gone".
        case keepsExisting(destination: String)
    }

    /// Where messages will be sent — the EFFECTIVE normalized serialization,
    /// byte-for-byte what `saveRemoteAgent` persists after
    /// `normalizedGatewayBaseURL`. Not a bare host: host alone hides a
    /// non-default port and a tenant/path prefix, which is precisely where a
    /// look-alike destination hides.
    let gatewayDestination: String

    /// The URL currently saved at this target, when one exists (i.e. this import
    /// is an overwrite). Kept even when it equals `gatewayDestination` — the
    /// token and certificate settings are replaced either way, and the card
    /// distinguishes the two cases via `gatewayDestinationChanges`.
    let previousGatewayDestination: String?

    /// The target's name from LOCAL state — a built-in's own display name, or
    /// the name the user already gave an existing custom gateway. `nil` for a
    /// brand-new custom, where the only available name is the one the code
    /// chose, and rendering that would hand the attacker a caption.
    let targetName: String?

    let fileLane: FileLane?

    /// True when no gateway is configured yet, so this import also becomes the
    /// gateway new conversations bind to (`saveRemoteAgent`'s first-gateway
    /// bootstrap). A consequence the user cannot see anywhere else at this
    /// point, hence a row.
    let becomesDefault: Bool

    /// True iff this import both replaces an existing configuration AND moves it
    /// somewhere else — the case that deserves an old → new comparison rather
    /// than a plain "your saved settings are being replaced".
    var gatewayDestinationChanges: Bool {
        guard let previousGatewayDestination else { return false }
        return previousGatewayDestination != gatewayDestination
    }

    /// True when this import overwrites a configured gateway at all.
    var replacesExistingGateway: Bool { previousGatewayDestination != nil }

    // MARK: - Construction

    /// - Parameters:
    ///   - existingGatewayURL: the URL saved at the target today, `nil` when the
    ///     slot is empty (including a freshly minted custom draft).
    ///   - existingFileServerDestination: the target's CONFIGURED file lane (URL
    ///     *and* credential present), `nil` when nothing is set up. A lane that
    ///     is merely half-written must read `nil` here, or the card promises to
    ///     keep something that isn't there.
    ///   - targetName: see `targetName`. Callers pass `nil` for a brand-new
    ///     custom rather than falling back to the payload's chosen name.
    ///   - anyGatewayConfigured: whether ANY gateway is configured right now.
    static func make(
        payload: PairingPayload,
        existingGatewayURL: URL?,
        existingFileServerDestination: String?,
        targetName: String?,
        anyGatewayConfigured: Bool
    ) -> PairingReviewModel {
        let fileLane: FileLane? = {
            if let incoming = payload.fileServer {
                return .incoming(
                    destination: incoming.url.absoluteString,
                    replacing: existingFileServerDestination
                )
            }
            if let existing = existingFileServerDestination {
                return .keepsExisting(destination: existing)
            }
            return nil
        }()

        return PairingReviewModel(
            // The one transformation applied on the save path. Rendering the raw
            // payload URL would show a destination the app is not going to use
            // (a pasted `/v1/chat/completions` is stripped on commit).
            gatewayDestination: SettingsViewModel
                .normalizedGatewayBaseURL(payload.url).absoluteString,
            previousGatewayDestination: existingGatewayURL?.absoluteString,
            targetName: targetName,
            fileLane: fileLane,
            becomesDefault: !anyGatewayConfigured
        )
    }
}
