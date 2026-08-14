// SPDX-License-Identifier: Apache-2.0

// Conduck
// GatewaySetupSuccessView.swift
//
// Terminal success step of the guided gateway-setup flow: a calm confirmation
// shown once a gateway is CONNECTED. Shared by EVERY path through the flow —
// the two self-hosted lanes arrive here when `PairingImportSheet` verifies a
// `conduck-connect` setup code, and the hosted-model (OpenRouter) lane arrives
// here when `saveRemoteAgent` completes (`HostedModelGatewayStepView.onConnected`).
// This screen does NO work — it only reflects the result, so it stays a single
// summary card with a "Done" CTA.
//
// LANE-AGNOSTIC BY CONSTRUCTION: every line it renders derives from `connectedRef`
// alone, so it carries no lane and branches on none. That property is exactly what
// lets the hosted lane reuse it verbatim (OpenRouter is not a `GatewaySetupLane`) —
// do NOT reintroduce a lane parameter to special-case copy; add per-ref facts
// instead, resolved the way the rows below already are.
//
// What it surfaces (gateway name · file-transfer state · default-for-new-chats)
// is the connected-confirmation summary the guided flow ends on:
//   - the gateway's display name (a proper noun / user label) — shown verbatim,
//     never localized, never a secret;
//   - what file sharing is good for on that gateway, read straight off
//     `fileLaneStatus(for:)` so this screen tells the same three-valued story the
//     gateway editor and the File transfer page do — on, uploads only, or off.
//     `.unsupported` means no file lane at all (the hosted model's case), so the
//     row is OMITTED rather than claiming a state;
//   - whether the connected gateway is the default for new chats — only the
//     first-ever gateway bootstraps the default, so a later one gets a quiet
//     "pick it under New chats use" line instead of overclaiming.
//
// Robust to `connectedRef == nil` (or an unresolved ref): the card falls back to a
// generic "Your gateway is ready" and drops the per-ref rows.
//
// Privacy (spec.md "Privacy & Security"): the setup code (bearer token + file-server
// credential) is handled ENTIRELY inside `PairingImportSheet`, and the OpenRouter
// API key entirely inside `HostedModelGatewayStepView` — never read, logged, or
// displayed here. The only value surfaced is the display name.

import SwiftUI

struct GatewaySetupSuccessView: View {
    @Bindable var viewModel: SettingsViewModel

    /// The `RemoteAgentRef` that just connected — a verified pairing import
    /// (self-hosted lanes) or a completed OpenRouter save (hosted lane). `nil` when
    /// the success state was reached without a resolvable ref — the card then falls
    /// back to generic copy and omits the per-ref rows.
    let connectedRef: RemoteAgentRef?

    /// Dismiss the guided flow.
    let proceed: () -> Void

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Success-check size that TRACKS the mascot's per-surface height (macOS 120 /
    /// portrait 160 / landscape 80). It was a fixed 44pt — the one hero element that
    /// ignored the scaffold's per-surface scaling, so it read oversized next to the
    /// smaller macOS / landscape-iPhone mascot. Shrinks at accessibility sizes just
    /// like the mascot (×0.6) so the proportion holds across every surface.
    private var checkSize: CGFloat {
        #if os(macOS)
        let base: CGFloat = 34
        #else
        let base: CGFloat = verticalSizeClass == .compact ? 24 : 44
        #endif
        return dynamicTypeSize >= .accessibility1 ? base * 0.6 : base
    }

    /// The list row for the connected gateway, resolved BY REF against the cached
    /// roster so a second gateway names ITSELF (not the first built-in). `nil` when
    /// `connectedRef` is nil or no longer in the roster.
    private var connectedRow: PersonalAIRow? {
        guard let ref = connectedRef else { return nil }
        return viewModel.personalAIRows.first { $0.ref == ref }
    }

    /// The gateway's display name (proper noun / user label, shown verbatim).
    /// Prefers the precomputed row (handles the empty-custom-name → "New gateway"
    /// case), then the pure resolver. `nil` only when there's no ref at all.
    private var gatewayName: String? {
        if let name = connectedRow?.displayName { return name }
        return connectedRef.map { viewModel.displayName(for: $0) }
    }

    /// Whether the connected gateway is the default new conversations bind to. Only
    /// the first-ever gateway bootstraps the default, so a later one is usually NOT
    /// the default — the copy must not overclaim.
    private var isDefault: Bool {
        guard let ref = connectedRef else { return false }
        return viewModel.defaultRemoteAgentRef == ref
    }

    /// File-sharing readiness for the connected gateway, or `nil` when there is no
    /// file lane to report (`.unsupported` — the hosted model) or no ref. We never
    /// invent a state, so an absent lane drops the row.
    ///
    /// THE WHOLE BADGE, not a Bool derived from `isFileTransferAvailable`. A lane
    /// whose server accepts writes and reads but implements no directory listing
    /// passes the staged test and is therefore AVAILABLE — so a Bool answers
    /// "on", and this screen would hand a plain-nginx user an unqualified success
    /// for a capability they have exactly half of, while the gateway editor and
    /// the File transfer page both show the amber "Uploads only" for the same
    /// gateway. `.readyUploadsOnly` exists precisely so no surface has to
    /// remember to ask the second question; asking for the status is how this one
    /// stops being the surface that forgot.
    private var fileLaneStatus: GatewayFileLaneStatus? {
        guard let ref = connectedRef else { return nil }
        let status = viewModel.fileLaneStatus(for: ref)
        return status == .unsupported ? nil : status
    }

    var body: some View {
        VStack(spacing: 24) {
            // Character
            Image("conduck-space-cowboy")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .onboardingMascot()

            // Success beat — the green check + "Connected" read as ONE unit (tight
            // inner spacing) so the check doesn't add a third competing focal point
            // under the mascot. The check size tracks the mascot per surface.
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: checkSize))
                    .foregroundStyle(AppColors.success)
                    .accessibilityHidden(true)

                Text("Connected") // xcstrings: gateway-setup-success
                    .onboardingScaledFont(.title, weight: .bold)
                    .foregroundStyle(AppColors.textEmphasis)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, 32)
            }

            // The card + its footnote read as one unit, so they sit tighter
            // together than the 24pt rhythm of the beats above.
            VStack(spacing: 12) {
                summaryCard
                crossDeviceNote
            }
        }
        .onboardingStepLayout {
            footer
        }
        .task {
            // Reflect the just-connected gateway (default pointer, configured set,
            // custom roster). `loadRemoteAgentState` does NOT touch the staged
            // file-availability / live-validated sets the pairing import filled in,
            // so the file-sharing row stays accurate. Lighter than a full
            // `loadSettings`.
            await viewModel.refreshRemoteAgentState()
        }
    }

    // MARK: - Cross-device note

    /// The one forward-looking line on an otherwise backward-looking screen: this
    /// setup rides to the user's other devices (non-secrets on iCloud KVS, secrets
    /// on the synchronizable Keychain — see Privacy & Security).
    ///
    /// Deliberately OUTSIDE the summary card. That card reports only VERIFIED
    /// per-ref state (it drops the file row rather than invent one), whereas this is
    /// an unconditional statement about how Conduck stores config — true of the
    /// mechanism, but not something we probed for this user (a device with iCloud
    /// Keychain off syncs the model but not the key; the hosted step's partial-sync
    /// banner is exactly that case). Keeping it a quiet footnote in its own register
    /// preserves the card's never-claim-an-unverified-state contract.
    private var crossDeviceNote: some View {
        Text("Set up once — this carries over to your other devices.") // xcstrings: gateway-setup-success
            .onboardingScaledFont(.footnote)
            .foregroundStyle(AppColors.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
    }

    // MARK: - Summary card

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Headline: "<GatewayName> is ready" — the name is a proper noun /
            // user label, shown verbatim and wrap-/scale-capped so a long custom
            // label can't overflow the card at large Dynamic Type. Falls back to a
            // generic line when there's no resolvable ref.
            if let name = gatewayName {
                (Text(verbatim: name)
                    + Text(LocalizedStringResource(
                        "gateway.setup.success.isReadySuffix",
                        defaultValue: " is ready"))) // xcstrings: gateway-setup-success
                    .onboardingScaledFont(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Your gateway is ready") // xcstrings: gateway-setup-success
                    .onboardingScaledFont(.headline)
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // File-sharing state — only when there's a file lane to report, and
            // three-valued for the same reason every other file surface is.
            if let status = fileLaneStatus {
                summaryRow(
                    icon: Self.fileRowIcon(status),
                    text: Self.fileRowText(status),
                    tint: Self.fileRowTint(status)
                )
            }

            // New-chats routing — names the gateway when it's the default, else a
            // quiet pointer to the Settings selector (mirrors the connect step's
            // default-vs-not copy).
            if isDefault, let name = gatewayName {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .foregroundStyle(AppColors.textSecondary)
                        .accessibilityHidden(true)
                    (Text(LocalizedStringResource(
                        "gateway.setup.success.newChats.usingPrefix",
                        defaultValue: "New chats · Using ")) // xcstrings: gateway-setup-success
                        + Text(verbatim: name))
                        .onboardingScaledFont(.subheadline)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            } else {
                Text("To use it for new chats, pick it under \"New chats use\" in Settings.") // xcstrings: gateway-setup-success
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onboardingCardPadding()
        .glassCardBackground()
        .padding(.horizontal, 32)
    }

    // MARK: - File-transfer row (three-valued, like every other file surface)

    // Static + internal rather than private, for the test target: the regression
    // this row carries — a half-lane reported as an unqualified success — is a
    // pure mapping from one enum, and a `View`'s `body` is the one place it
    // cannot be asserted on.

    /// The glyph. `.readyUploadsOnly` leaves the folder family for the amber
    /// triangle the editor's badge and the File transfer page's status block
    /// already use for it — a folder icon of any fill would read as one of the
    /// two settled answers.
    static func fileRowIcon(_ status: GatewayFileLaneStatus) -> String {
        switch status {
        case .ready: return "folder.fill"
        case .readyUploadsOnly: return "exclamationmark.triangle.fill"
        case .needsAttention, .saved, .recommended, .optional, .unsupported: return "folder"
        }
    }

    /// The label. Deliberately the SHORT form the rest of the app uses for this
    /// state — the card reports, it does not explain, and the meaning lives one
    /// tap away on the File transfer page where the remedy is.
    static func fileRowText(_ status: GatewayFileLaneStatus) -> LocalizedStringResource {
        switch status {
        case .ready:
            return LocalizedStringResource(
                "gateway.setup.success.fileSharing.on",
                defaultValue: "File transfer · On")
        case .readyUploadsOnly:
            return LocalizedStringResource(
                "gateway.setup.success.fileSharing.uploadsOnly",
                defaultValue: "File transfer · Uploads only")
        case .needsAttention, .saved, .recommended, .optional, .unsupported:
            return LocalizedStringResource(
                "gateway.setup.success.fileSharing.off",
                defaultValue: "File transfer · Off")
        }
    }

    /// Amber for the half-lane, the card's own neutral for everything else. Not
    /// `GatewayFileLaneStatus.tint`, whose `.ready` is green: a second green
    /// element under the screen's hero checkmark competes with it, and this row
    /// is a summary line rather than a badge.
    static func fileRowTint(_ status: GatewayFileLaneStatus) -> Color {
        status == .readyUploadsOnly ? AppColors.warning : AppColors.textSecondary
    }

    /// A leading-icon summary line in the card (file-sharing state).
    private func summaryRow(
        icon: String,
        text: LocalizedStringResource,
        tint: Color = AppColors.textSecondary
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Pinned footer (single primary CTA)

    private var footer: some View {
        Button(action: proceed) {
            Text("Done") // xcstrings: gateway-setup-success
                .onboardingScaledFont(.headline)
                .foregroundColor(AppColors.textEmphasis)
                .frame(maxWidth: Constants.Layout.buttonMaxWidth)
                .padding(.vertical, 16)
                .background(Color.accentColor)
                .cornerRadius(14)
        }
        .primaryCTAButton()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
        .accessibilityIdentifier("guidedSetup.success.done")
    }
}

#Preview {
    ZStack {
        LinearGradient(
            colors: [AppColors.gradientStart, AppColors.gradientEnd],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()

        GatewaySetupSuccessView(
            viewModel: SettingsViewModel(),
            connectedRef: nil,
            proceed: {}
        )
    }
}
