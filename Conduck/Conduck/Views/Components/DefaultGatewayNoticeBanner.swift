// SPDX-License-Identifier: Apache-2.0

// Conduck
// DefaultGatewayNoticeBanner.swift
//
// The conversation shell's one sentence about this device's "Default for new
// chats" — a broken pointer, a pointer never chosen, or a repair this device
// already made.
//
// Sibling of `PendingRetryCard`: same directory, same chrome primitive (16pt
// padding then `glassCardBackground(borderColor:)`), so the shell keeps ONE
// banner vocabulary and a second kind of card never appears above the transcript.
// The host owns everything stateful — what to say (`DefaultGatewayNotice`), where
// the fix lives, and what a dismissal means. This view only renders.
//
// The device word is forked ("this iPad", not "this device") the way
// `TTSKeyReadinessBanner` forks it: "this device" reads as boilerplate a user
// scrolls past, while "this iPad" reads as a fact they can check against the
// slab in their hands — and the fact is the whole point, because the pointer is
// device-local and the gateway is very likely fine on their Mac.
//
// Colour carries the difference between a fault and an outstanding choice:
// `sunsetOrange` (the retry card's border) for a default that cannot send, amber
// for "you have not picked one yet" and for an adoption. Nothing here is red —
// nothing is lost, and the exit is one tap away in every case.

import SwiftUI

struct DefaultGatewayNoticeBanner: View {
    let notice: DefaultGatewayNotice
    /// Land the user on Settings → Personal AI, which shows BOTH doors: pick a
    /// different gateway, or finish setting up the named one.
    let onOpenPersonalAI: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: glyph)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                // The house rule forbids a bare `.buttonStyle(.plain)` on a
                // custom-drawn control; `pointerIconButton` gives macOS its
                // guaranteed live square + hover wash and falls back to `.plain`
                // everywhere else, so ONE call site serves all three platforms.
                .pointerIconButton(shape: .circle)
                .accessibilityLabel(Text(dismissLabel))
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            actionButton
        }
        .padding(16)
        .glassCardBackground(borderColor: borderColor)
        .accessibilityIdentifier("chat.defaultGatewayNotice")
    }

    // MARK: - Action

    @ViewBuilder
    private var actionButton: some View {
        switch notice {
        case .brokenDefault, .noDefaultChosen:
            Button {
                onOpenPersonalAI()
            } label: {
                Text(actionTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .adopted:
            // Borderless, not prominent: an adoption is information, and a
            // prominent button beside it reads as an error the user must clear.
            Button {
                onOpenPersonalAI()
            } label: {
                Text(actionTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
            .tint(AppColors.brandAmber)
        }
    }

    // MARK: - Treatment

    private var glyph: String {
        switch notice {
        case .brokenDefault: return "exclamationmark.triangle.fill"
        case .noDefaultChosen: return "questionmark.circle"
        case .adopted: return "checkmark.circle"
        }
    }

    private var accent: Color {
        switch notice {
        case .brokenDefault: return AppColors.sunsetOrange
        // Amber, not orange: nothing is broken here — a choice is outstanding.
        case .noDefaultChosen, .adopted: return AppColors.brandAmber
        }
    }

    private var borderColor: Color {
        switch notice {
        case .brokenDefault: return AppColors.sunsetOrange.opacity(0.4)
        case .noDefaultChosen, .adopted: return AppColors.brandAmber.opacity(0.35)
        }
    }

    // MARK: - Copy (device-idiom forked)

    private var title: String {
        switch notice {
        case .brokenDefault(_, let name):
            #if os(macOS)
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.broken.title.mac",
                defaultValue: "\(name) isn't set up on this Mac."
            ))
            #else
            if DeviceCapabilities.isiPad {
                return String(localized: LocalizedStringResource(
                    "chat.defaultGateway.broken.title.ipad",
                    defaultValue: "\(name) isn't set up on this iPad."
                ))
            }
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.broken.title.iphone",
                defaultValue: "\(name) isn't set up on this iPhone."
            ))
            #endif

        case .noDefaultChosen:
            #if os(macOS)
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.noDefault.title.mac",
                defaultValue: "This Mac doesn't have a default gateway."
            ))
            #else
            if DeviceCapabilities.isiPad {
                return String(localized: LocalizedStringResource(
                    "chat.defaultGateway.noDefault.title.ipad",
                    defaultValue: "This iPad doesn't have a default gateway."
                ))
            }
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.noDefault.title.iphone",
                defaultValue: "This iPhone doesn't have a default gateway."
            ))
            #endif

        case .adopted(let adoptedName, _):
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.adopted.title",
                defaultValue: "New chats now use \(adoptedName)"
            ))
        }
    }

    // The closing sentence of the two "…start a chat from outside the app" bodies
    // — "New chats you start here are fine" — is true ONLY because
    // `NewChatGatewaySeed.resolve` FILTERS unconfigured gateways out of the
    // picker's pre-selection, so the in-app composer always opens on a gateway
    // that can send. If that ladder is ever taught to honour the stored default
    // unconditionally, this sentence becomes a lie and both strings need new keys.
    private var message: String {
        switch notice {
        case .brokenDefault:
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.broken.body",
                defaultValue: "It's your default for new chats, so anything that starts a chat from outside the app has nowhere to go. New chats you start here are fine."
            ))

        case .noDefaultChosen:
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.noDefault.body",
                defaultValue: "Anything that starts a chat from outside the app doesn't know which one to use. Pick one and new chats will start on it. New chats you start here are fine."
            ))

        case .adopted(_, let previousName):
            #if os(macOS)
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.adopted.body.mac",
                defaultValue: "\(previousName) isn't set up on this Mac. Chats you've already started keep the gateway they started on."
            ))
            #else
            if DeviceCapabilities.isiPad {
                return String(localized: LocalizedStringResource(
                    "chat.defaultGateway.adopted.body.ipad",
                    defaultValue: "\(previousName) isn't set up on this iPad. Chats you've already started keep the gateway they started on."
                ))
            }
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.adopted.body.iphone",
                defaultValue: "\(previousName) isn't set up on this iPhone. Chats you've already started keep the gateway they started on."
            ))
            #endif
        }
    }

    private var actionTitle: String {
        switch notice {
        case .brokenDefault:
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.broken.action",
                defaultValue: "Choose a default"
            ))
        case .noDefaultChosen:
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.noDefault.action",
                defaultValue: "Pick a gateway"
            ))
        case .adopted:
            return String(localized: LocalizedStringResource(
                "chat.defaultGateway.adopted.action",
                defaultValue: "Change"
            ))
        }
    }

    private var dismissLabel: String {
        String(localized: LocalizedStringResource(
            "chat.defaultGateway.dismiss.a11y",
            defaultValue: "Dismiss"
        ))
    }
}
