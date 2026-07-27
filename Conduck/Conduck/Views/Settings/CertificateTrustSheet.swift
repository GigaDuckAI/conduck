// SPDX-License-Identifier: Apache-2.0

// Conduck
// CertificateTrustSheet.swift
//
// The ONE place certificate trust is decided — opened from the "Server
// certificate" row in the gateway editor (variant `.gateway`) and the
// file-transfer page (variant `.fileServer`). The row itself only shows a
// plain-language value (Automatic / Pinned on this device / Approval needed);
// everything jargon-bearing (the fingerprint, "SPKI SHA-256") is quarantined
// in here so the main form never has to explain pinning inline.
//
// STAGING ONLY: the fingerprint binding writes through to the caller's editor
// buffer (which marks the form dirty and retracts any live verdict); nothing
// here persists. The host editor's Save — gateway editor and file-transfer
// page alike — is the single commit point, and the footer says so.
//
// The two variants differ in exactly two ways, both capability-truths:
//   • TOFU capture exists only on the gateway probe — the file-server test
//     never captures a certificate, so `.fileServer` never shows the approval
//     card (callers pass `pendingCapturedFingerprint: nil` there).
//   • The manual field's provenance line: the gateway's Test Connection can
//     fill the value in; a file server's arrives via setup code or paste.
//
// Fingerprints are public values (a hash of the server's public key), so
// displaying one is not a secret leak — unlike tokens, which never enter here.

import SwiftUI

struct CertificateTrustSheet: View {
    /// Which server's trust decision this sheet edits (copy differences only).
    enum Variant {
        case gateway
        case fileServer
    }

    let variant: Variant
    /// Write-through to the caller's staged fingerprint buffer. Empty = Automatic.
    @Binding var fingerprint: String
    /// Gateway variant only: the TOFU-captured fingerprint awaiting approval.
    /// Pass nil (default) when there is none — and always for `.fileServer`.
    var pendingCapturedFingerprint: String? = nil
    /// Runs after the user approves the captured certificate (the caller stages
    /// it and kicks the automatic re-test). The sheet dismisses itself.
    var onTrustCaptured: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(LocalizedStringResource(
                    "settings.certTrust.title",
                    defaultValue: "Server certificate"
                ))
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)

                statusText

                if let captured = pendingCapturedFingerprint,
                   !captured.isEmpty, variant == .gateway {
                    approvalCard(captured: captured)
                }

                manualSection

                if !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        fingerprint = ""
                    } label: {
                        Text(LocalizedStringResource(
                            "settings.certTrust.useAutomatic",
                            defaultValue: "Use Automatic Trust"
                        ))
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .buttonStyle(.bordered)
                }

                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Text(LocalizedStringResource(
                            "settings.certTrust.done",
                            defaultValue: "Done"
                        ))
                            .fontWeight(.semibold)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
        // App-wide rule: a scroll container hosting a text field must offer
        // drag-to-dismiss, or the keyboard traps the sheet on iOS.
        .scrollDismissesKeyboard(.interactively)
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 380)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }

    // MARK: - Status (plain-language, mirrors the row's value)

    @ViewBuilder
    private var statusText: some View {
        let pinned = !fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasPending = (pendingCapturedFingerprint?.isEmpty == false) && variant == .gateway
        if hasPending {
            Text(LocalizedStringResource(
                "settings.certTrust.status.approval",
                defaultValue: "This server showed a certificate this device doesn't recognize yet. If that's your own self-signed certificate, approve it below and Conduck will only ever accept this exact one."
            ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else if pinned {
            Text(LocalizedStringResource(
                "settings.certTrust.status.pinned",
                defaultValue: "Pinned on this device — Conduck only accepts the server holding this exact certificate, so an impostor at the same address is turned away."
            ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(LocalizedStringResource(
                "settings.certTrust.status.automatic",
                defaultValue: "Automatic — this server proves who it is with a certificate this device already trusts. Most servers work this way, and there's nothing to set up."
            ))
                .font(.subheadline)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - TOFU approval (gateway only)

    private func approvalCard(captured: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource(
                "settings.certTrust.approval.heading",
                defaultValue: "Certificate waiting for approval"
            ))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppColors.textPrimary)
            Text(captured)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(AppColors.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(LocalizedStringResource(
                "settings.certTrust.approval.hint",
                defaultValue: "Only approve a certificate you expect — one you set up on your own server."
            ))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                fingerprint = captured
                onTrustCaptured?()
                dismiss()
            } label: {
                Label(
                    LocalizedStringResource(
                        "settings.certTrust.approval.trustButton",
                        defaultValue: "Trust Certificate"
                    ),
                    systemImage: "checkmark.shield.fill"
                )
                .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.brandAmber)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppColors.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Manual pin (the only surface where the jargon lives)

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringResource(
                "settings.certTrust.manual.label",
                defaultValue: "Certificate fingerprint (SPKI SHA-256)"
            ))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.textSecondary)
            TextField(
                String(localized: "settings.certTrust.manual.prompt", defaultValue: "64 hex characters"),
                text: $fingerprint
            )
                .font(.system(.callout, design: .monospaced))
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            Text(manualHelper)
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var manualHelper: LocalizedStringResource {
        switch variant {
        case .gateway:
            return LocalizedStringResource(
                "settings.certTrust.manual.helper.gateway",
                defaultValue: "Test Connection captures this for you when your server uses its own certificate — you rarely need to type it."
            )
        case .fileServer:
            return LocalizedStringResource(
                "settings.certTrust.manual.helper.fileServer",
                defaultValue: "A setup code fills this in for you; otherwise paste it from your file server."
            )
        }
    }

}
