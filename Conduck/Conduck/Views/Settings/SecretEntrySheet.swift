// Conduck
// SecretEntrySheet.swift
//
// A focused tap-in sheet for entering ONE secret — a gateway bearer token or a
// custom-endpoint API key. The native SwiftUI `SecureField` lives HERE, in the
// sheet's own hosting context, deliberately NOT inline in the parent editor's
// `Form`. On macOS a `SecureField` is an out-of-process `NSSecureTextField`
// (ViewBridge); churning it inside a Form's layout pass triggers
// `_NSDetectedLayoutRecursion` and blanks the pane (see the history on
// RemoteAgentConfigBody / CustomSTTConfigBody). A sheet mounts/unmounts the
// secure view through a discrete presentation lifecycle, so the parent editor can
// freely show/hide an ordinary (non-secure) summary row on the auth toggle
// without ever touching the secure view. DO NOT inline this back into a Form.
//
// Privacy: the secret never leaves this sheet's transient `draft` @State except
// via `onCommit` into the caller's editor-local buffer (the only thing Save
// persists, to the Keychain). Nothing here logs or echoes the value.

import SwiftUI

struct SecretEntrySheet: View {
    let title: LocalizedStringResource
    /// SecureField placeholder text.
    let prompt: String
    /// Seed value (the caller's current buffer) — copied into local @State on appear.
    let initialValue: String
    /// Commits the entered value back to the caller's editor-local buffer.
    let onCommit: (String) -> Void

    @State private var draft: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AppColors.textPrimary)
            SecureField(prompt, text: $draft)
                // No `.textContentType(.password)` — a bearer token / API key
                // isn't a website login; that content type wrongly summons the
                // Passwords autofill bar + "save password?" prompt. `SecureField`
                // masks regardless.
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onSubmit {
                    // Return commits the secret (mirrors the Done button).
                    onCommit(draft)
                    dismiss()
                }
            // Calm grey, spaced: neutral text labels (no blue/amber clash) with a
            // wide gap so the two actions don't crowd. Done is a quiet bordered
            // pill — matches the app's "Speak a sample" / Test Connection look.
            HStack(spacing: 20) {
                Spacer()
                Button(role: .cancel) {
                    dismiss()
                } label: {
                    Text(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel"))
                        .foregroundStyle(AppColors.textPrimary)
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    onCommit(draft)
                    dismiss()
                } label: {
                    Text(LocalizedStringResource("settings.secret.done", defaultValue: "Done"))
                        .fontWeight(.semibold)
                        .foregroundStyle(AppColors.textPrimary)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .onAppear { draft = initialValue }
        // Don't let a swipe-down silently drop a typed-but-uncommitted secret —
        // the visible Cancel/Done stay the deliberate exits. Pristine (untouched)
        // → swipe still dismisses freely.
        .interactiveDismissDisabled(draft != initialValue && !draft.isEmpty)
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 170)
        #else
        .presentationDetents([.height(220)])
        #endif
    }
}
