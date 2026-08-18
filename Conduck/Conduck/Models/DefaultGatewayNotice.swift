// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayNotice.swift
//
// What the app SAYS about this device's "Default for new chats", as a pure
// function over the verdict.
//
// A display mapper, never a second opinion. `SettingsManager.resolveDefaultGateway()`
// decides what the pointer IS; this decides which of three sentences — if any —
// the user is owed about it. Nothing here reads storage, nothing here re-derives
// a state, and nothing here may speak about a verdict the resolver chose to keep
// quiet.
//
// It is a value rather than three inline `switch`es because its consumers are the
// iPhone shell, the iPad detail column and the macOS window — SwiftUI views the
// iOS-Simulator suite can neither compile nor run (`MainWindowView` is
// `#if os(macOS)` outright, so a predicate written inside it is never seen by a
// test). Written inline it would exist in three copies, and three copies of a
// rule this fine-grained drift. Same argument, same shape, as the sibling
// `NewChatGatewaySeed` and `GatewayGate`.
//
// The SILENCES are the load-bearing half, and each has its own reason:
//
//   - `.readingUnreliable` is the I3 guard. A Keychain blackout (secrets are
//     `kSecAttrAccessibleAfterFirstUnlock`) or a half-arrived iCloud Keychain
//     sync reads every gateway as gone. A banner announcing a broken default
//     there is a lie told by a locked device, about a gateway that is fine.
//
//   - `.nothingConfigured` and `.setupUnfinished` belong to the empty state and
//     the locked composer, which already say the true thing. A banner on top of
//     those nags a user who is halfway through setting a gateway up.
//
//   - `.bootstrapped` filled a pointer in where the user had chosen none and
//     exactly one gateway could send. Nothing the user chose was overridden, so
//     there is nothing to announce.
//
// Only ONE verdict speaks, plus the stored repair record: no default chosen at
// all (`.selectionRequired`), and an adoption this device performed and has not
// yet mentioned. A parked `.defaultUnavailable` is re-read as the former, because
// a placeholder is not a default and the user is owed the sentence about the
// choice they still have to make, not one about a choice they never made.
//
//   - `.defaultUnavailable` with a pointer the USER chose is the fourth silence,
//     and the deliberate one. The pointer really is unavailable here, and the
//     app really does have something to say about it — but not HERE. A chat
//     window the user opened to type in is not where an unconnected gateway
//     gets turned into a chore, and a banner that returns every launch is
//     exactly that. The sentence is owed where the user went looking: the
//     "Default for new chats" picker and the gateway's own editor both name it,
//     and every headless refusal names it too, because the user pressed a button
//     there and a silent refusal would be worse than a named one.
//
// The strings live in the surfaces, not here — the same verdict is worded
// differently in a chat banner, a Settings footer and a picker callout.

import Foundation

/// The one sentence a conversation surface may say about this device's default
/// gateway, or nil when there is nothing honest to say.
enum DefaultGatewayNotice: Equatable, Sendable {
    /// Nothing is stored and the device may not guess: two or more gateways can
    /// send, or one can while another is a token away. Nothing is broken and
    /// nothing was overridden — the user simply has a choice to make, and until
    /// they make it every lane without a picker has nowhere to send.
    case noDefaultChosen(candidates: [RemoteAgentRef])

    /// Conduck already moved the pointer, because the adopted gateway was the
    /// only one that could send.
    case adopted(adoptedName: String, previousName: String)

    /// Identity a SESSION dismissal is scoped to. `.adopted` has none: it is
    /// dismissed by acknowledging the stored record, not by a session flag, so
    /// the acknowledgment survives a relaunch and the other one does not.
    enum DismissalKey: Equatable {
        case noDefaultChosen
    }

    var dismissalKey: DismissalKey? {
        switch self {
        case .noDefaultChosen: return .noDefaultChosen
        case .adopted: return nil
        }
    }

    /// The statement owed to the user, or nil for "say nothing".
    ///
    /// - Parameters:
    ///   - resolution: the verdict from the SAME `newChatPickerSnapshot` turn the
    ///     caller seeded its picker from, so the banner and the picker can never
    ///     describe different rosters.
    ///   - roster: ALWAYS the snapshot's `badgeRoster`, never `customGateways()`.
    ///     The badge roster unions RETIRED customs, so a default parked on a
    ///     custom the user forgot resolves to its real name instead of a raw
    ///     UUID. Names come from `RemoteAgentRefMetadata` and never from a URL
    ///     (I5).
    ///   - pendingAdoption: a repair this device performed and has not yet been
    ///     acknowledged.
    ///
    /// The park — "the APP put this pointer here, one step after the user forgot
    /// a different gateway" — arrives INSIDE `resolution` rather than as its own
    /// parameter. A parked pointer that cannot send is not a broken default;
    /// there is no default, only a placeholder, so it takes the no-default
    /// sentence. Every surface a user can meet this state on makes the same
    /// collapse, and reading it off the verdict is what stops one of them
    /// forgetting to ask.
    static func resolve(
        resolution: DefaultGatewayResolution,
        roster: [CustomGateway],
        pendingAdoption: DefaultGatewayAdoptionNotice?
    ) -> DefaultGatewayNotice? {
        // An unacknowledged repair OUTRANKS everything: the user is owed the news
        // that their pointer moved, and it is the only thing this banner says
        // about a pointer that is not simply unchosen.
        //
        // The names come from the RECORD, never re-resolved against the live
        // roster: the replaced gateway may be a custom that is gone by now, and a
        // repair that names a UUID explains nothing.
        if let pendingAdoption {
            return .adopted(
                adoptedName: pendingAdoption.adoptedName,
                previousName: pendingAdoption.previousName
            )
        }

        switch resolution {
        case .defaultUnavailable(_, let candidates, let pointerIsParked):
            // A pointer the APP parked is a placeholder, not a default, and the
            // no-default sentence describes it exactly: nothing is chosen, several
            // gateways work, pick one. Candidates are non-empty by construction
            // here, so the collapse can never produce a "pick one" with nothing
            // to pick.
            if pointerIsParked {
                return candidates.isEmpty ? nil : .noDefaultChosen(candidates: candidates)
            }
            // A pointer the USER chose, unavailable here: SAY NOTHING. This is the
            // chat window, which the user did not open to be told about Settings.
            // A banner on every launch turns an unconnected gateway into a chore,
            // which is exactly what it is not — and the fact is not lost, it is
            // moved: the picker they open and the gateway's own editor both name
            // it, and every headless refusal still names it, because there the
            // user pressed a button and is owed an answer.
            //
            // Deliberately NOT collapsed into `.noDefaultChosen` either. A pointer
            // IS chosen; "no default yet" would be false, and it would invite the
            // user to replace a choice that may be one iCloud sync from working.
            return nil

        case .selectionRequired(let candidates):
            // Not defensive noise: with nothing to pick, "pick one" is a lie, and
            // the empty state already owns that screen.
            return candidates.isEmpty ? nil : .noDefaultChosen(candidates: candidates)

        case .usable, .adopted, .bootstrapped:
            // The pointer works — say nothing. (`.adopted` reaches the banner only
            // through the pending record above; once acknowledged it is silent,
            // which is what makes the acknowledgment mean something.)
            return nil

        case .nothingConfigured:
            // The honest first-run state, owned by `UnconfiguredEmptyState` and
            // the locked composer. A second voice here says nothing new.
            return nil

        case .setupUnfinished:
            // Half-finished setup with nothing configured — the same empty state
            // owns it, and a banner here would nag a user mid-setup.
            return nil

        case .readingUnreliable:
            // THE I3 GUARD. A Keychain blackout, or an iCloud Keychain sync that
            // has delivered some secrets and not others. Every gateway reads as
            // gone and none of them is. A banner accusing the user's default of
            // being broken would be a lie told by a locked device, so render
            // nothing and let the send fail closed on its own.
            return nil
        }
    }
}

extension DefaultGatewayNotice {
    /// The value shown in the "Default for new chats" row.
    ///
    /// Under `.selectionRequired` the compatibility shim projects to the built-in
    /// fallback, which may itself be configured — so a name there would claim a
    /// choice the user never made. Lives here, beside the mapper, so the two
    /// Personal AI twins cannot drift and the string is unit-testable without a
    /// view.
    static func selectorValue(needsChoice: Bool, displayName: String) -> String {
        needsChoice
            ? String(localized: LocalizedStringResource(
                "settings.personalAI.default.notChosen",
                defaultValue: "Not chosen yet"))
            : displayName
    }
}
