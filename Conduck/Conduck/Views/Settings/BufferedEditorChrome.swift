// SPDX-License-Identifier: Apache-2.0

// Conduck
// BufferedEditorChrome.swift
//
// Shared chrome for the buffer-until-Save settings editors — the multi-field
// BYO-server forms: custom voice endpoint (`CustomSTTConfigBody`) and Personal
// AI gateway (`RemoteAgentConfigBody`). One interaction model, one code path, so
// the behavior is identical across both.
//
// It owns the WHOLE commit/exit chrome, in a STABLE top position that never
// shifts and never bottom-docks:
//   - a leading EXIT control (discard-if-dirty; owns Esc on macOS when it is the
//     innermost mounted editor) — see `BufferedEditorExit` for its two forms,
//   - a trailing "Save" (disabled until the editor reports it can save) — present
//     from the moment the editor mounts,
//   - the "Discard changes?" confirmation alert (dirty-gated),
//   - the `.onDisappear` safety net that discards unsaved state on ANY exit that
//     isn't a committed Save/Delete.
//
// PLATFORM SPLIT (deliberate — the founder's "weird Cancel that makes the UI
// switch and swap" was a macOS-sheet artifact):
//   - iOS: the NATIVE navigation bar — `.topBarLeading` exit + `.topBarTrailing`
//     Save, with the native back button hidden. Looks native + premium; verified.
//   - macOS: a fully-CONTROLLED custom top header via `.safeAreaInset(.top)`
//     ([exit] · title · [Save]), with the nested-stack nav bar hidden. WHY not
//     toolbar placements on macOS: `.cancellationAction`/`.confirmationAction`
//     BOTTOM-dock inside a sheet (the original shift bug), and `.primaryAction`
//     docks on the LEADING edge on macOS (Apple's documented behavior) — so Save
//     would cluster on the left with the exit control + the back chevron. A custom
//     header is deterministic SwiftUI layout (no placement semantics), so the exit
//     always sits left and Save always sits right, present-from-mount, no bottom bar.
//
// WHY the native back button stays hidden on iOS even for a `.back` exit: that
// modifier also suppresses the interactive swipe-back gesture. Restoring the
// native button would make every edge-swipe a SILENT discard — the `.onDisappear`
// net reverts without asking — and SwiftUI still offers no supported "should this
// pop?" veto. So the chevron is ours, and the gesture stays off.
//
// The Delete/Forget destructive action stays INLINE in each editor (a quiet red
// row in its own bottom Section). Each editor flips `suppressCancelOnExit = true`
// right before a Save- or Delete-driven `dismiss()`, so the safety net skips.
//
// The `.onDisappear` cleanup guarantees an unsaved draft/edit can't survive a
// swipe-back, the macOS exit control, or the Settings sheet closing. The VM's
// `onDiscard` uses the store as the sole authority — robust on both platforms.

import SwiftUI

/// How a buffered editor's leading control presents itself — a navigational
/// Back, or a modal Cancel. The two differ only in appearance and wording; both
/// run the identical discard-if-dirty exit.
///
/// REQUIRED at every call site, with no default. The right answer depends on how
/// the HOST presented the editor, which the chrome cannot see, and getting it
/// wrong is the kind of mistake that reads as correct in review — so a new
/// editor is forced to state its own presentation rather than inherit one.
enum BufferedEditorExit {
    /// Pushed onto a navigation stack. Renders a back chevron matching
    /// `MacSettingsSubScreenChrome`, so the settings sub-screens and the editors
    /// share one leading edge.
    case back
    /// Presented modally as the ROOT of its own stack, where there is nothing to
    /// go "back" to and a chevron would point at nothing. Renders "Cancel".
    case cancel
}

private struct BufferedEditorChrome: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    /// True when the editor holds unsaved edits — the exit control confirms only
    /// then. A value (not a closure) so `.onChange(of:)` has explicit observation
    /// deps; the editor recomputes it on every render, so the modifier always sees
    /// the current truth.
    let isDirty: Bool

    /// The shared settings VM. This modifier registers the editor in its
    /// `bufferedEditors` stack so the OUTER settings exits (macOS Done/Esc/sidebar,
    /// iOS swipe) can consult `editorHasUnsavedChanges` and never discard an
    /// unsaved edit without the same confirmation the exit shows — and so macOS knows
    /// which editor owns Escape. Driven here so the editors stay dumb and the
    /// wiring lives in one place.
    let viewModel: SettingsViewModel

    /// This editor's identity in the VM's stack. `@State` in a `ViewModifier` is
    /// tied to the modified view's identity, so it is stable across re-renders and
    /// minted afresh per editor instance — exactly the lifetime a registration
    /// needs.
    @State private var editorID = UUID()

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

    /// How the leading control presents itself — see `BufferedEditorExit`.
    let exitStyle: BufferedEditorExit

    @State private var showingDiscardConfirm = false

    /// Leave the editor: confirm first if there is anything to lose, otherwise
    /// go. Identical for both `exitStyle` cases — the style is presentation only,
    /// never behavior.
    private func handleExit() {
        if isDirty {
            showingDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    /// Why Save is inert, for VoiceOver only. A disabled control announces
    /// "dimmed" but not the reason, and "nothing has changed yet" is the one
    /// reason that is invisible on screen — an empty required field is at least
    /// visibly empty, and each editor captions that case itself.
    ///
    /// Deliberately NOT a visible caption: it would render on the most ordinary
    /// screen in the flow (opening a working gateway to look at it) and read as
    /// a warning about something that is fine. Empty string when Save is live,
    /// so the value clears the moment an edit lands.
    private var saveAccessibilityValue: Text {
        (!isDirty && !canSave())
            ? Text(LocalizedStringResource(
                "settings.editor.save.noChanges",
                defaultValue: "No changes to save."
            ))
            : Text("")
    }

    /// The leading control, shared by both platforms so the two never drift.
    @ViewBuilder
    private var exitButton: some View {
        switch exitStyle {
        case .back:
            Button { handleExit() } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
            }
            // Reuses `MacSettingsSubScreenChrome`'s key — the same word for the
            // same control. The `mac.` in the name is legacy (it now labels the
            // iOS chevron too) and is left alone: renaming a translated key
            // costs a re-translation to say nothing new.
            .accessibilityLabel(Text(LocalizedStringResource(
                "settings.mac.back",
                defaultValue: "Back"
            )))
        case .cancel:
            Button(LocalizedStringResource("settings.editor.cancel", defaultValue: "Cancel")) {
                handleExit()
            }
        }
    }

    func body(content: Content) -> some View {
        chrome(content)
            // Publish this editor's dirty state into the VM's editor stack so the
            // outer settings exits can guard against silent loss. Registration is
            // PER-EDITOR, so a child push (e.g. the File Transfer page) neither
            // clobbers nor is clobbered by its parent — correct whichever way the
            // OS orders the child's `.onAppear` against the parent's
            // `.onDisappear`. `.onAppear` is idempotent, so a re-appear on return
            // from a child push simply refreshes the entry.
            .onAppear { viewModel.registerBufferedEditor(editorID, isDirty: isDirty) }
            .onChange(of: isDirty) { _, newValue in
                viewModel.setBufferedEditorDirty(editorID, newValue)
            }
            .onDisappear {
                // The editor is leaving — drop its registration. That releases the
                // outer gates (and drains any deferred remote reload) once a
                // Save/Cancel/teardown completes, without disturbing any other
                // editor still on screen. (The `onDiscard` safety net below still
                // rests on a child PUSH not firing this editor's `.onDisappear` —
                // registration no longer does. The one nested pair that exists is
                // gated clean by `fileTransferGateReason`, so a push can't reach a
                // dirty parent.)
                viewModel.unregisterBufferedEditor(editorID)
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
                ToolbarItem(placement: .topBarLeading) { exitButton }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saveTitle) { onSave() }
                        .fontWeight(.semibold)
                        .disabled(!canSave())
                        .accessibilityIdentifier("settings.editor.save")
                        .accessibilityValue(saveAccessibilityValue)
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
    /// Side breathing room for the exit control's hover wash. A WORD ("Cancel")
    /// needs it or the wash hugs the letters and reads as a cramped pill; the
    /// `.back` CHEVRON must not have it — it is aligned pixel-for-pixel with
    /// `MacSettingsSubScreenChrome`'s unpadded chevron so the sub-screens and the
    /// editors share one leading edge, and 10pt would visibly break that.
    private var exitWashPadding: CGFloat {
        switch exitStyle {
        case .back: return 0
        case .cancel: return 10
        }
    }

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
                    exitButton
                        // Applied HERE, not inside `exitButton`: that view is shared
                        // with the iOS toolbar path, which must keep its native
                        // treatment. The mac pointer style stays on the macOS side.
                        // Padding only in the word-labelled `.cancel` form — see
                        // `exitWashPadding`.
                        .pointerIconButton(horizontalPadding: exitWashPadding)
                        .foregroundStyle(AppColors.textSecondary)
                        // Esc exits the INNERMOST editor. Bound only on the top of
                        // the stack: SwiftUI documents no precedence between two live
                        // `.cancelAction` buttons, and on macOS a pushed-away parent
                        // stays in the hierarchy, so its header would otherwise be a
                        // competing target. `MacSettingsView`'s Done drops its own
                        // `.cancelAction` whenever any editor is mounted, so exactly
                        // one Esc target exists at a time.
                        //
                        // Also dropped while the discard alert is up. The alert's
                        // own "Keep Editing" carries `role: .cancel` and so answers
                        // Esc; leaving this button bound would put two live
                        // `.cancelAction` targets on screen with no documented
                        // precedence — one keystroke could dismiss the alert AND
                        // pop the editor, discarding the very edits the alert was
                        // asking about.
                        .keyboardShortcut(
                            (viewModel.topBufferedEditorID == editorID && !showingDiscardConfirm)
                                ? KeyboardShortcut.cancelAction : nil
                        )
                    Spacer()
                    Button(saveTitle) { onSave() }
                        // Same live band + hover wash as the exit control, so the
                        // header's two peer actions read as one family. NOT the
                        // inline-link style: that carries the pointing-hand cursor,
                        // which macOS reserves for links, and Save is a commit.
                        // The label is a WORD, so the wash gets side padding or it
                        // hugs the letters.
                        .pointerIconButton(horizontalPadding: 10)
                        .fontWeight(.semibold)
                        .foregroundStyle(canSave() ? AppColors.brandAmber : AppColors.textTertiary)
                        .disabled(!canSave())
                        .accessibilityIdentifier("settings.editor.save")
                        .accessibilityValue(saveAccessibilityValue)
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
    /// Applies the shared buffered-editor chrome: a stable top exit control
    /// (leading, discard-if-dirty, and Esc on macOS when innermost) + Save
    /// (trailing, disabled until the editor can save) — native bar on iOS, custom
    /// header on macOS — plus the discard alert, the VM editor-stack registration,
    /// and the `.onDisappear` safety net. Delete/Forget stays inline.
    /// See `BufferedEditorChrome`.
    ///
    /// `exit` has no default on purpose — see `BufferedEditorExit`.
    func bufferedEditorChrome(
        isDirty: Bool,
        viewModel: SettingsViewModel,
        onDiscard: @escaping () async -> Void,
        suppressCancelOnExit: Binding<Bool>,
        title: String,
        saveTitle: LocalizedStringResource,
        exit: BufferedEditorExit,
        canSave: @escaping () -> Bool,
        onSave: @escaping () -> Void
    ) -> some View {
        modifier(BufferedEditorChrome(
            isDirty: isDirty,
            viewModel: viewModel,
            onDiscard: onDiscard,
            suppressCancelOnExit: suppressCancelOnExit,
            title: title,
            saveTitle: saveTitle,
            canSave: canSave,
            onSave: onSave,
            exitStyle: exit
        ))
    }
}
