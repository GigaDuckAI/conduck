// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewayPresenceDot.swift
//
// The chat toolbar's gateway presence dot: a passive mark that sits LEADING of
// the gateway name on iPhone, iPad and the Mac window and answers one question
// before the user types — can this device reach that gateway right now? Muted
// green = a probe is in flight, full green = the probe succeeded, red = it
// failed. ~7pt at the default text size, scaled from there by Dynamic Type.
//
// NOT A CONTROL. It has no tap target, no hover treatment and no
// `MacPointerTargets` primitive. A dot that could be clicked would promise a
// destination this indicator does not have.
//
// WHERE IT SITS DIFFERS BY PLATFORM. iPhone/iPad mount it INSIDE the title
// control's label (picker `Menu`, clone `Button`, static title), leading the
// name. The Mac mounts it BESIDE the control in the same `ToolbarItem`, so it
// holds one position across that window's three title states instead of moving
// with whichever control is on screen. A dot dropped into the Mac picker's
// label would not have rendered at all under the DEFAULT menu style — AppKit
// keeps only the label's text there (measured: the pill's own capsule vanished
// too, which is why `MainWindowView` styles that `Menu` itself). Either way,
// the Mac dot is always its own accessibility element; the two modes below are
// an iOS concern.
//
// RED NEVER MEANS "NOT SET UP". The hosts pass `nil` for a gateway that is not
// configured on this device, and nil renders NOTHING — which is what keeps the
// spec rule "a conversation window says nothing about an unconnected gateway"
// true. Red is only ever "configured, and the probe failed".
//
// SHAPE, NOT COLOUR — the convention `ConversationActivityMark.swift` sets for
// the conversation list. A colour dot cannot honour it by itself, so the
// colour channel is backed two ways: VoiceOver reads the state as words
// ALWAYS, and *Differentiate Without Colour* swaps the disc for an SF Symbol
// whose silhouette carries the state (dotted ring / check / cross). The
// default look is unchanged, so this costs the sighted user nothing.
//
// TWO ACCESSIBILITY MODES, because SwiftUI collapses a `Menu`/`Button` label
// subtree into ONE element and the host's own `.accessibilityLabel` ("Choose
// AI", "Clone & continue…") then REPLACES everything the subtree would have
// said. A dot that declares its own element inside such a control is therefore
// silently dropped, and VoiceOver never hears the state at all. So:
//
//   • `standaloneAccessibility: true` (default) — the dot IS its own element,
//     with the state as its label and `toolbar.gatewayPresence` as its QA
//     identifier. Used in the read-only title branches, which are plain text
//     and collapse nothing.
//   • `standaloneAccessibility: false` — the dot is `.accessibilityHidden`,
//     and the HOST applies `.gatewayPresenceAccessibilityValue(_:)` to the
//     CONTROL instead, so the state arrives as that one element's VALUE
//     ("Choose AI, Connected"). Same reasoning as `ConversationActivityMark`'s
//     glyph, which hides itself because the composed row label already speaks.
//
// READS THE MONITOR IN ITS OWN `body`, and takes the REF, not a verdict. Every
// host mounts this inside a `.toolbar { ToolbarItem { … } }` closure, and an
// `@Observable` property read from inside toolbar content is not reliably
// tracked as a dependency of the host's body — measured on the Mac: the toolbar
// rendered once with "no verdict yet" (nothing), the monitor then wrote green,
// and nothing re-rendered. A read inside THIS view's body is tracked like any
// other view body, wherever the view is mounted. The same rule governs
// `gatewayPresenceAccessibilityValue(for:)`, which is a `ViewModifier` for the
// same reason. Hosts therefore never read `GatewayPresenceMonitor` themselves.
//
// iOS/macOS only, by file location: the wrist and CarPlay have neither the
// width for a mark nor a toolbar to put it in, and the Mac menu-bar popover is
// out of scope.

import SwiftUI

/// The gateway presence indicator for `ref`. `nil` ref (a gateway this device
/// cannot send on, or nothing on screen) renders nothing at all, as does a ref
/// the monitor holds no verdict for yet.
struct GatewayPresenceDot: View {
    let ref: RemoteAgentRef?

    /// Read HERE, in this view's body, so the dependency is tracked — see the
    /// header. `flatMap` collapses "no ref" and "no verdict yet" into the same
    /// nothing.
    private var presence: GatewayPresence? {
        ref.flatMap { GatewayPresenceMonitor.shared.presence[$0] }
    }

    /// The drawn diameter, Dynamic-Type scaled from the caller's value. The
    /// caller's number is the size at the DEFAULT text size, not a fixed one:
    /// the dot sits beside a title that grows, and a mark pinned at 7pt next to
    /// an AX5 headline reads as a speck of dust rather than a status.
    ///
    /// `relativeTo: .headline` for BOTH platforms even though the Mac pill's
    /// name is `.subheadline`: the two styles scale within a point of each
    /// other, macOS's Dynamic Type range is far narrower than iOS's, and one
    /// text style keeps this a single spelling instead of a second knob every
    /// caller would have to get right.
    @ScaledMetric private var diameter: CGFloat

    /// Whether the dot declares its OWN accessibility element (see the header's
    /// "TWO ACCESSIBILITY MODES"). False inside a `Menu`/`Button` label, where
    /// the control's label would discard it and the host speaks the state via
    /// `.gatewayPresenceAccessibilityValue(_:)` instead.
    let standaloneAccessibility: Bool

    /// When on, the disc becomes a symbol so the state survives the colour
    /// channel being removed.
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

    /// Explicit rather than memberwise: `@ScaledMetric` needs the caller's
    /// number as its `wrappedValue`, which the synthesized initializer cannot
    /// express. `diameter` 7 sits beside the iOS `.headline` title; hosts pass
    /// 6 on macOS, where the pill's name is `.subheadline`.
    init(ref: RemoteAgentRef?, diameter: CGFloat = 7, standaloneAccessibility: Bool = true) {
        self.ref = ref
        self._diameter = ScaledMetric(wrappedValue: diameter, relativeTo: .headline)
        self.standaloneAccessibility = standaloneAccessibility
    }

    var body: some View {
        if let presence {
            if standaloneAccessibility {
                drawn(presence)
                    // One a11y element, always spoken as words — the colour is
                    // reinforcement, never the only carrier of the state.
                    .accessibilityElement()
                    .accessibilityLabel(Text(Self.label(for: presence)))
                    // Non-localized, so QA and UI tests can assert the state
                    // without pinning a translation.
                    .accessibilityValue(Text(verbatim: Self.rawState(for: presence)))
                    .accessibilityIdentifier("toolbar.gatewayPresence")  // stable QA target (non-localized)
            } else {
                // Inside a control's label the host owns the single element, so
                // an element here is either discarded or read out of order.
                drawn(presence)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The mark itself, identical in both accessibility modes — only the
    /// element declaration above differs.
    private func drawn(_ presence: GatewayPresence) -> some View {
        mark(for: presence)
            .frame(width: markSize, height: markSize)
            #if os(macOS)
            // Same words the tooltip-less platforms get from VoiceOver: on the
            // Mac a hover is the cheapest way to ask what the dot means. Kept in
            // BOTH modes — a tooltip describes whatever the pointer is actually
            // over, and the host control's own `.help` still covers the rest of
            // the pill.
            .help(String(localized: Self.label(for: presence)))
            #endif
            // Colour/symbol crossfade only. No pulse: a passive indicator that
            // animates continuously reads as activity the app is not actually
            // doing.
            .animation(.default, value: self.presence)
    }

    /// The symbol is drawn BIGGER than the disc it replaces. `circle.dotted`,
    /// `checkmark.circle.fill` and `xmark.circle.fill` all reduce to the same
    /// filled ring at dot size — the glyph inside is what carries the state, and
    /// at 7pt it is not resolvable. The box therefore grows when *Differentiate
    /// Without Colour* is on; the title control shifts by those few points once,
    /// at the moment the setting is toggled, which nobody does mid-glance.
    private static let symbolScale: CGFloat = 1.6

    private var markSize: CGFloat {
        differentiateWithoutColor ? diameter * Self.symbolScale : diameter
    }

    /// Disc by default; symbol under *Differentiate Without Colour*.
    @ViewBuilder
    private func mark(for presence: GatewayPresence) -> some View {
        if differentiateWithoutColor {
            Image(systemName: Self.symbolName(for: presence))
                .resizable()
                .scaledToFit()
                .foregroundStyle(Self.tint(for: presence))
        } else {
            Circle()
                .fill(Self.tint(for: presence))
        }
    }

    /// Muted green while the probe is in flight — the same hue as the settled
    /// "reachable" state, so the transition is a fade-in rather than a colour
    /// change the eye reads as a different verdict.
    private static func tint(for presence: GatewayPresence) -> Color {
        switch presence {
        case .checking: return AppColors.success.opacity(0.35)
        case .reachable: return AppColors.success
        case .unreachable: return AppColors.error
        }
    }

    private static func symbolName(for presence: GatewayPresence) -> String {
        switch presence {
        case .checking: return "circle.dotted"
        case .reachable: return "checkmark.circle.fill"
        case .unreachable: return "xmark.circle.fill"
        }
    }

    /// "Not reachable", never "offline" or "down": the claim this probe can
    /// honestly make is about THIS device's reach, not the server's health.
    ///
    /// Not private — `gatewayPresenceAccessibilityValue(_:)` speaks for the dot
    /// when it is hidden inside a control, and the two must never drift into
    /// two different spellings of the same state.
    static func label(for presence: GatewayPresence) -> LocalizedStringResource {
        switch presence {
        case .checking:
            return LocalizedStringResource("chat.presence.checking", defaultValue: "Checking connection")
        case .reachable:
            return LocalizedStringResource("chat.presence.reachable", defaultValue: "Connected")
        case .unreachable:
            return LocalizedStringResource("chat.presence.unreachable", defaultValue: "Not reachable")
        }
    }

    private static func rawState(for presence: GatewayPresence) -> String {
        switch presence {
        case .checking: return "checking"
        case .reachable: return "reachable"
        case .unreachable: return "unreachable"
        }
    }
}

extension View {
    /// Speaks the presence state as the accessibility VALUE of the control this
    /// is applied to — the companion to `GatewayPresenceDot(standaloneAccessibility: false)`.
    ///
    /// Apply it to the `Menu`/`Button` ITSELF, never to the dot: SwiftUI folds a
    /// control's label subtree into one element and the control's own
    /// `.accessibilityLabel` overwrites what that subtree said, so a dot nested
    /// in there is mute however it is annotated. As a value it composes with the
    /// existing label instead of fighting it ("Choose AI, Connected").
    ///
    /// `nil` — no verdict, or a gateway this device cannot send on — leaves the
    /// view untouched, matching the dot's own "nil renders nothing".
    ///
    /// Takes the REF and reads the monitor inside a `ViewModifier` body, for the
    /// reason in the dot's header: a read made in the host's toolbar closure is
    /// not reliably tracked, and a value that never updates would announce a
    /// stale state.
    func gatewayPresenceAccessibilityValue(for ref: RemoteAgentRef?) -> some View {
        modifier(GatewayPresenceAccessibilityValue(ref: ref))
    }
}

/// The modifier behind `gatewayPresenceAccessibilityValue(for:)` — a distinct
/// view body so the monitor read is a tracked dependency.
private struct GatewayPresenceAccessibilityValue: ViewModifier {
    let ref: RemoteAgentRef?

    func body(content: Content) -> some View {
        if let ref, let presence = GatewayPresenceMonitor.shared.presence[ref] {
            content.accessibilityValue(Text(GatewayPresenceDot.label(for: presence)))
        } else {
            content
        }
    }
}
