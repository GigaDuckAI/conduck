// Conduck
// BufferedEditorChrome.swift
//
// Shared chrome for the buffer-until-Save settings editors — the multi-field
// BYO-server forms: custom voice endpoint (`CustomSTTConfigBody`) and Personal
// AI gateway (`RemoteAgentConfigBody`). One interaction model, one code path, so
// the behavior is identical across both.
//
// It owns the WHOLE commit/cancel chrome, in a STABLE top position that never
// shifts and never bottom-docks:
//   - a leading "Cancel" (discard-if-dirty),
//   - a trailing "Save" (disabled until the editor reports it can save) — present
//     from the moment the editor mounts,
//   - the "Discard changes?" confirmation alert (dirty-gated),
//   - the `.onDisappear` safety net that discards unsaved state on ANY exit that
//     isn't a committed Save/Delete.
//
// PLATFORM SPLIT (deliberate — the founder's "weird Cancel that makes the UI
// switch and swap" was a macOS-sheet artifact):
//   - iOS: the NATIVE navigation bar — `.topBarLeading` Cancel + `.topBarTrailing`
//     Save, with the native back button hidden. Looks native + premium; verified.
//   - macOS: a fully-CONTROLLED custom top header via `.safeAreaInset(.top)`
//     ([Cancel] · title · [Save]), with the nested-stack nav bar hidden. WHY not
//     toolbar placements on macOS: `.cancellationAction`/`.confirmationAction`
//     BOTTOM-dock inside a sheet (the original shift bug), and `.primaryAction`
//     docks on the LEADING edge on macOS (Apple's documented behavior) — so Save
//     would cluster on the left with Cancel + the back chevron. A custom header
//     is deterministic SwiftUI layout (no placement semantics), so Cancel always
//     sits left and Save always sits right, present-from-mount, no bottom bar.
//
// The Delete/Forget destructive action stays INLINE in each editor (a quiet red
// row in its own bottom Section). Each editor flips `suppressCancelOnExit = true`
// right before a Save- or Delete-driven `dismiss()`, so the safety net skips.
//
// The `.onDisappear` cleanup guarantees an unsaved draft/edit can't survive a
// swipe-back, the macOS Cancel, or the Settings sheet closing. The VM's
// `onDiscard` uses the store as the sole authority — robust on both platforms.

import SwiftUI

private struct BufferedEditorChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    /// True when the editor holds unsaved edits — Cancel confirms only then. A
    /// value (not a closure) so `.onChange(of:)` has explicit observation deps;
    /// the editor recomputes it on every render, so the modifier always sees the
    /// current truth.
    let isDirty: Bool

    /// Mirror of the active editor's dirty state onto the shared
    /// `SettingsViewModel.editorHasUnsavedChanges`. The OUTER settings exits
    /// (macOS Done/Esc/sidebar, iOS swipe) consult that flag so an unsaved edit is
    /// never discarded without the same confirmation Cancel shows. Driven here so
    /// both editors stay dumb and the wiring lives in one place.
    @Binding var editorHasUnsavedChanges: Bool

    /// The VM's cancel/revert: drop a never-saved draft, or re-hydrate an
    /// existing record from storage. Runs on every non-committed exit.
    let onDiscard: () async -> Void

    /// Set by the editor before a Save/Delete `dismiss()` so the safety net
    /// doesn't also undo the just-committed change.
    @Binding var suppressCancelOnExit: Bool

    /// The editor's display name — shown centered in the macOS custom header
    /// (unused on iOS, where the native `.navigationTitle` handles it).
    let title: String

    /// Trailing "Save" button title.
    let saveTitle: LocalizedStringResource

    /// Whether Save is currently enabled (URL/name present, etc.). Evaluated live.
    let canSave: () -> Bool

    /// The editor's commit action. Runs the buffered save + dismisses on success.
    let onSave: () -> Void

    @State private var showingDiscardConfirm = false

    private func handleCancel() {
        if isDirty {
            showingDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    func body(content: Content) -> some View {
        chrome(content)
            // Publish dirty state up to the shared VM so the outer settings exits
            // can guard against silent loss. `.onAppear` seeds on mount AND
            // RE-ASSERTS on return from a child push (e.g. the File Transfer guide):
            // if a future OS were to fire `.onDisappear` on that push and clear the
            // flag, reappearing re-establishes it from the live `isDirty` (which
            // `didInitialize` keeps correct) — so the data-loss guard never silently
            // lapses. `.onChange` tracks live edits thereafter.
            .onAppear { editorHasUnsavedChanges = isDirty }
            .onChange(of: isDirty) { _, newValue in
                editorHasUnsavedChanges = newValue
            }
            .onDisappear {
                // The editor is leaving — it can no longer be the active dirty
                // editor. Clearing here releases the outer gates (and drains any
                // deferred remote reload) once a Save/Cancel/teardown completes.
                // (A child PUSH does not fire onDisappear on this OS — the same
                // assumption the onDiscard safety net below already relies on.)
                editorHasUnsavedChanges = false
                guard !suppressCancelOnExit else { return }
                Task { await onDiscard() }
            }
            .alert(
                LocalizedStringResource("settings.editor.discard.title", defaultValue: "Discard changes?"),
                isPresented: $showingDiscardConfirm
            ) {
                Button(
                    LocalizedStringResource("settings.editor.discard.confirm", defaultValue: "Discard"),
                    role: .destructive
                ) {
                    // `.onDisappear` runs the discard cleanup; just leave.
                    dismiss()
                }
                Button(
                    LocalizedStringResource("settings.editor.discard.keepEditing", defaultValue: "Keep Editing"),
                    role: .cancel
                ) { }
            } message: {
                Text(LocalizedStringResource(
                    "settings.editor.discard.message",
                    defaultValue: "Your unsaved changes will be lost."
                ))
            }
    }

    @ViewBuilder
    private func chrome(_ content: Content) -> some View {
        #if os(iOS)
        content
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel")) {
                        handleCancel()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveTitle) { onSave() }
                        .fontWeight(.semibold)
                        .disabled(!canSave())
                        .accessibilityIdentifier("settings.editor.save")
                }
            }
        #else
        content
            // Hide the nested-stack bar (back chevron + title) — the custom
            // `macHeader` is the sole top bar. `.navigationBar` placement is
            // iOS-only, so use the placement-free visibility overload here.
            .toolbar(.hidden)
            .safeAreaInset(edge: .top, spacing: 0) { macHeader }
        #endif
    }

    #if os(macOS)
    /// The macOS pinned top header — Cancel (left) · title (centered) · Save
    /// (right). Deterministic layout (a `ZStack` centers the title regardless of
    /// the two buttons' differing widths); a bottom hairline separates it from the
    /// scrolling form. Sits flush under the sheet's top edge via `.safeAreaInset`.
    private var macHeader: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppColors.textEmphasis)
                    .lineLimit(1)
                HStack {
                    Button(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel")) {
                        handleCancel()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    Button(saveTitle) { onSave() }
                        .buttonStyle(.plain)
                        .fontWeight(.semibold)
                        .foregroundStyle(canSave() ? AppColors.brandAmber : AppColors.textTertiary)
                        .disabled(!canSave())
                        .accessibilityIdentifier("settings.editor.save")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider().overlay(AppColors.border)
        }
        // OPAQUE — a translucent header let the scrolling form ghost through
        // behind the title (a stray "API key / Set ›" smudge). The detail pane's
        // gradient reads as `gradientStart` at its top edge, so a flat
        // `gradientStart` fill is seamless against it while fully hiding content
        // that scrolls underneath.
        .background(AppColors.gradientStart)
    }
    #endif
}

extension View {
    /// Applies the shared buffered-editor chrome: a stable top Cancel (leading,
    /// discard-if-dirty) + Save (trailing, disabled-until-valid) — native bar on
    /// iOS, custom header on macOS — plus the discard alert + `.onDisappear`
    /// safety net. Delete/Forget stays inline. See `BufferedEditorChrome`.
    func bufferedEditorChrome(
        isDirty: Bool,
        editorHasUnsavedChanges: Binding<Bool>,
        onDiscard: @escaping () async -> Void,
        suppressCancelOnExit: Binding<Bool>,
        title: String,
        saveTitle: LocalizedStringResource,
        canSave: @escaping () -> Bool,
        onSave: @escaping () -> Void
    ) -> some View {
        modifier(BufferedEditorChrome(
            isDirty: isDirty,
            editorHasUnsavedChanges: editorHasUnsavedChanges,
            onDiscard: onDiscard,
            suppressCancelOnExit: suppressCancelOnExit,
            title: title,
            saveTitle: saveTitle,
            canSave: canSave,
            onSave: onSave
        ))
    }
}
