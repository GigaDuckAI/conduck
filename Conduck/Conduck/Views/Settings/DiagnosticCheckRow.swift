// SPDX-License-Identifier: Apache-2.0

// Conduck
// DiagnosticCheckRow.swift
//
// One status row in the Diagnostics checklist. Mirrors the
// `STTTestSuiteResultView.stageRow` idiom (20pt status glyph + title + a
// one-line plain-English detail) so the two screens read as one family.
//
// Dumb view: it renders a `DiagnosticCheck` and nothing more, plus two optional
// display overrides (`titleOverride` / `detailOverride`) that let a caller show a
// user's real gateway name where the check's own copy-safe text cannot — safe
// because `copyBlock()` reads the `DiagnosticCheck`, never this view. For a
// `.failed` row with a code and no detail, the text falls back to the
// taxonomy-derived fix from `DiagnosticsExplainer` — never raw provider error text.

import SwiftUI

struct DiagnosticCheckRow: View {
    let check: DiagnosticCheck
    /// UI-only display title that overrides `check.title` for rendering (the
    /// gateway header uses it to show a custom gateway's REAL name). `copyBlock()`
    /// reads `check.title`, never this view, so the override can carry a user name
    /// without breaching the copy-block allowlist. Default-nil ⇒ `check.title`.
    var titleOverride: String? = nil
    /// UI-only display detail that overrides `check.detail` for RENDERING — the
    /// default-gateway row uses it to name the gateway in its explanation.
    /// `copyBlock()` reads `check.detail`'s copy-safe generic form and never this
    /// view, so the override can carry a user's gateway name without breaching the
    /// copy-block allowlist. Default-nil ⇒ `check.detail`.
    var detailOverride: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusGlyph
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(titleOverride ?? check.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AppColors.textPrimary)
                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(detailColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Status glyph (same vocabulary as STTTestSuiteResultView)

    @ViewBuilder
    private var statusGlyph: some View {
        switch check.status {
        case .notRun:
            Image(systemName: "circle")
                .foregroundStyle(AppColors.textTertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(AppColors.success)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(AppColors.warning)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(AppColors.error)
        case .notApplicable:
            Image(systemName: "minus.circle")
                .foregroundStyle(AppColors.textTertiary)
        }
    }

    // MARK: - Detail line

    /// A caller-supplied display detail wins (it can name the gateway); otherwise
    /// the runner's copy-safe `detail`; and for a `.failed` row that arrived
    /// without one, the code's plain-English fix.
    private var detailText: String? {
        if let override = detailOverride { return override }
        if let detail = check.detail { return detail }
        if case let .failed(code) = check.status, let code {
            return DiagnosticsExplainer.explain(code: code).fix
        }
        return nil
    }

    private var detailColor: Color {
        switch check.status {
        case .failed: return AppColors.error
        case .warning: return AppColors.warning
        default: return AppColors.textSecondary
        }
    }
}
