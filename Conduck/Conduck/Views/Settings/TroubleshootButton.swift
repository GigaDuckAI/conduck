// SPDX-License-Identifier: Apache-2.0

// Conduck
// TroubleshootButton.swift
//
// The reusable "Troubleshoot" affordance — a stethoscope button that opens the
// local Diagnostics screen focused on a specific failure. Presented as a local
// `.sheet` so the user can PEEK at Diagnostics and dismiss straight back to
// where they were: a mid-conversation error never ejects them into Settings.
//
// One primitive for every IN-SCENE-GRAPH error surface (conversation send-error
// banner, file-transfer setup test, home-screen retry card). The sheet self-owns
// a FRESH focused `DiagnosticsRunner` (the nil-runner branch of
// `DiagnosticsContent`), so the focused card is present from the first paint and
// the sheet's slide-up masks the single section-populate reflow — independent of
// the persistent-host prewarm that fixes the first-open flicker.
//
// The ONE surface that can't use this is the macOS menu-bar dictation popover:
// it's hosted outside the SwiftUI scene graph (a raw `NSHostingController`) and
// cannot present a sheet, so it routes through `MenuBarCoordinator` →
// `MainWindowView` → `DiagnosticsRunner.setFocus(ref:code:)` instead.
//
// Whether the button appears at all is decided upstream by `DiagnosticsFocus`'s
// failable init (the single filter): a surface builds a `DiagnosticsFocus?` and
// renders this only when non-nil, so a non-troubleshootable error (record again,
// image too large) or a plain notice shows no button.

import SwiftUI

struct TroubleshootButton: View {
    let focus: DiagnosticsFocus

    @State private var showingDiagnostics = false

    var body: some View {
        Button {
            showingDiagnostics = true
        } label: {
            Label(
                LocalizedStringResource("thread.troubleshoot", defaultValue: "Troubleshoot"),
                systemImage: "stethoscope"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppColors.brandAmber)
        }
        // A help link inside error prose, rendered in five different containers
        // (banner, retry card, failed-turn row, setup test) — so it takes the
        // inline treatment, which widens the live band without stretching or
        // re-heighting any host layout.
        .inlineLinkButton()
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                DiagnosticsView(
                    focusedRef: focus.ref,
                    focusedErrorCode: focus.errorCode
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(LocalizedStringResource("diagnostics.done", defaultValue: "Done")) {
                            showingDiagnostics = false
                        }
                    }
                }
            }
        }
    }
}
