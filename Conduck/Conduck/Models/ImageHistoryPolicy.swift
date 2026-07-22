// Conduck
// ImageHistoryPolicy.swift
//
// Per-gateway graduated image-history policy for the remote-agent (Personal
// AI) layer. Mirrors `RemoteAgentAuthScheme` in shape: a small persisted enum
// (`imageHistory.policy.<suffix>`), an explicit fail-safe `default`, and a
// tolerant `from(rawValue:)`. Replaces the old per-gateway "keep all prior
// images inline" BOOL (`fileServer.keepImagesInline.<suffix>`, retained as the
// lazy-migration source — `.all` is the bool's exact semantics).
//
// Why an enum, not a bool: the inline window is the only client-side lever on
// prior-turn image cost (the user pays their own LLM bill, and some gateways
// re-process every inline image every request), but a single escape hatch was
// all-or-nothing. Three levels — Recent (window 3) / Extended (window 10) /
// All (unlimited) — let the user trade history fidelity against cost/latency
// per gateway. The policy also bounds NEVER-UPLOADED (unkeyed) images: beyond
// `orphanInlineWindow` image-bearing turns they EXPIRE to the honest
// unavailable note instead of riding inline forever (the old unbounded
// token-burn hole exactly where no file fallback exists). `.all` disables
// both windows (the historic behavior).
//
// CROSS-TARGET: a Watch-target membership exception (pbxproj `63E4A001…` set,
// alongside `ConverseRequest.swift`) — the Watch assembles the same wire
// history and always runs `.default` (the setting is never broadcast).

import Foundation

/// How much prior-turn IMAGE history a gateway's requests carry inline.
/// Persisted per-`RemoteAgentRef` (`imageHistory.policy.<suffix>`); consumed
/// by `ConverseRequest.priorTurns` via `ConversationHistoryAssembler`.
enum ImageHistoryPolicy: String, Sendable, Equatable, Codable, CaseIterable {
    /// Newest `Constants.imageInlineWindow` (3) image-bearing turns ride
    /// inline; older uploaded images demote to on-disk references, and
    /// never-uploaded images expire after `orphanInlineWindow` turns. The
    /// fastest/cheapest level — the default.
    case recent

    /// Same shape as `.recent` with a wider inline window
    /// (`Constants.imageInlineWindowExtended`, 10) — higher cost and slower
    /// replies on image-heavy chats, more in-full vision history.
    case extended

    /// Every image-bearing prior turn rides inline within `contextMaxTurns`
    /// (the historic behavior). No window, no orphan expiry — insurance
    /// against a gateway that can't re-open images from disk.
    case all

    /// The default applied whenever no policy is stored, a stored raw value
    /// can't be decoded, or the surface can't read settings (watchOS).
    static let `default`: ImageHistoryPolicy = .recent

    /// Parse a stored raw string, falling back to `.default` for nil /
    /// unrecognized input (forward-compat with future levels).
    static func from(rawValue: String?) -> ImageHistoryPolicy {
        guard let rawValue, let policy = ImageHistoryPolicy(rawValue: rawValue) else {
            return .default
        }
        return policy
    }

    /// Count of most-recent image-bearing prior turns whose images ride the
    /// wire inline. `nil` = unlimited (`.all` — every image-bearing turn
    /// inline, no demotion, no expiry).
    var inlineWindow: Int? {
        switch self {
        case .recent: return Constants.imageInlineWindow
        case .extended: return Constants.imageInlineWindowExtended
        case .all: return nil
        }
    }

    /// Grace window for NEVER-UPLOADED (unkeyed) images: an unkeyed image
    /// beyond `inlineWindow` stays inline until this many image-bearing turns
    /// have passed, then EXPIRES to the unavailable note (there is no file to
    /// reference). `nil` = never expire (`.all`).
    var orphanInlineWindow: Int? {
        switch self {
        case .recent, .extended: return Constants.imageOrphanInlineWindow
        case .all: return nil
        }
    }
}
