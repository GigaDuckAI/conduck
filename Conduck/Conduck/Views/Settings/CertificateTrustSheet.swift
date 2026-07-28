// SPDX-License-Identifier: Apache-2.0

// Conduck
// CertificateTrustSheet.swift
//
// The ONE place the optional certificate pin is edited — opened from the
// "Server certificate" row in the gateway editor and the file-transfer page.
// The row itself only shows a plain-language value (Automatic / Pinned on this
// device); everything jargon-bearing (the fingerprint, "SPKI SHA-256") is
// quarantined in here so the main form never has to explain pinning inline.
//
// A pin only ever TIGHTENS: Conduck refuses any certificate this device
// doesn't already trust, and a fingerprint narrows that further to one exact
// certificate. It can never make an untrusted server acceptable — so this
// sheet has no "trust it anyway", and both servers' copy is identical (the
// gateway and the file server are the same decision).
//
// STAGING ONLY: the fingerprint binding writes through to the caller's editor
// buffer (which marks the form dirty and retracts any live verdict); nothing
// here persists. The host editor's Save — gateway editor and file-transfer
// page alike — is the single commit point.
//
// Fingerprints are public values (a hash of the server's public key), so
// displaying one is not a secret leak — unlike tokens, which never enter here.

import SwiftUI

struct CertificateTrustSheet: View {
    /// Write-through to the caller's staged fingerprint buffer. Empty = Automatic.
    @Binding var fingerprint: String

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
        if pinned {
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
            // `.v2` key: the old helper promised Test Connection / a setup code
            // would fill this in, which the removal of trust-on-first-use made
            // false — and the catalog value WINS over `defaultValue:`, so the
            // reword needs a fresh key.
            Text(LocalizedStringResource(
                "settings.certTrust.manual.helper.v2",
                defaultValue: "Optional, and only ever a tightening: Conduck already refuses a certificate this device doesn't trust, and a fingerprint narrows that to one exact certificate. Paste it from the server you run."
            ))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
