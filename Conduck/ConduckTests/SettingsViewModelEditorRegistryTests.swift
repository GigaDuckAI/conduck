// Conduck
// SettingsViewModelEditorRegistryTests.swift
//
// The buffered-editor registry (`bufferedEditors`) that backs
// `editorHasUnsavedChanges`, `hasMountedBufferedEditor` and `topBufferedEditorID`.
//
// WHY it is a stack and not a flag: editors legitimately co-mount — the gateway
// editor pushes the file-transfer page, and both carry `bufferedEditorChrome`.
// A single shared `Bool` was clobbered by the child's `.onAppear` on push and
// cleared by its `.onDisappear` on pop, so the parent's data-loss guard rested on
// an untested "a child push doesn't fire the parent's onDisappear" assumption.
// These tests pin the per-editor semantics that make the guard correct under
// EITHER ordering.
//
// `topBufferedEditorID` additionally decides which macOS editor owns Esc
// (`BufferedEditorChrome.macHeader`), so its ordering contract is load-bearing:
// Esc must cancel the innermost editor, never close all of Settings.
//
// Pure in-memory state — no Keychain, no network, no persistence. Safe unsigned.

import XCTest
@testable import Conduck

@MainActor
final class SettingsViewModelEditorRegistryTests: XCTestCase {

    // MARK: - Co-mounted editors

    /// The bug the registry exists to prevent: a clean child mounting over a dirty
    /// parent must not report the surface as clean. With the old shared `Bool` the
    /// child's `.onAppear` overwrote `true` with `false`, silently unlocking every
    /// outer exit gate.
    func testCleanChildDoesNotClearDirtyParent() {
        let vm = SettingsViewModel()
        let parent = UUID()
        let child = UUID()

        vm.registerBufferedEditor(parent, isDirty: true)
        vm.registerBufferedEditor(child, isDirty: false)

        XCTAssertTrue(vm.editorHasUnsavedChanges)
        XCTAssertEqual(vm.bufferedEditors.count, 2)
    }

    /// The mirror case: popping the clean child must leave the dirty parent's
    /// guard intact. The old `.onDisappear` cleared the shared flag outright.
    func testPoppingCleanChildLeavesDirtyParentGuarded() {
        let vm = SettingsViewModel()
        let parent = UUID()
        let child = UUID()

        vm.registerBufferedEditor(parent, isDirty: true)
        vm.registerBufferedEditor(child, isDirty: false)
        vm.unregisterBufferedEditor(child)

        XCTAssertTrue(vm.editorHasUnsavedChanges)
        XCTAssertEqual(vm.topBufferedEditorID, parent)
    }

    /// A dirty child over a clean parent keeps the surface dirty until the child
    /// itself goes — the reported chain (gateway editor clean, file-transfer page
    /// dirty).
    func testDirtyChildOverCleanParent() {
        let vm = SettingsViewModel()
        let parent = UUID()
        let child = UUID()

        vm.registerBufferedEditor(parent, isDirty: false)
        vm.registerBufferedEditor(child, isDirty: true)
        XCTAssertTrue(vm.editorHasUnsavedChanges)

        vm.unregisterBufferedEditor(child)
        XCTAssertFalse(vm.editorHasUnsavedChanges)
        XCTAssertTrue(vm.hasMountedBufferedEditor, "the parent editor is still on screen")
    }

    // MARK: - Mount presence vs. dirtiness

    /// `hasMountedBufferedEditor` must be independent of dirtiness — it gates the
    /// macOS Esc binding, and Esc has to cancel a CLEAN editor too rather than
    /// closing Settings from three levels deep.
    func testMountPresenceIsIndependentOfDirtiness() {
        let vm = SettingsViewModel()
        XCTAssertFalse(vm.hasMountedBufferedEditor)
        XCTAssertNil(vm.topBufferedEditorID)

        let editor = UUID()
        vm.registerBufferedEditor(editor, isDirty: false)
        XCTAssertTrue(vm.hasMountedBufferedEditor)
        XCTAssertFalse(vm.editorHasUnsavedChanges)

        vm.unregisterBufferedEditor(editor)
        XCTAssertFalse(vm.hasMountedBufferedEditor)
        XCTAssertNil(vm.topBufferedEditorID)
    }

    /// `topBufferedEditorID` is the INNERMOST editor, i.e. the last mounted.
    func testTopEditorIsTheLastMounted() {
        let vm = SettingsViewModel()
        let first = UUID()
        let second = UUID()
        let third = UUID()

        vm.registerBufferedEditor(first, isDirty: false)
        XCTAssertEqual(vm.topBufferedEditorID, first)
        vm.registerBufferedEditor(second, isDirty: false)
        XCTAssertEqual(vm.topBufferedEditorID, second)
        vm.registerBufferedEditor(third, isDirty: false)
        XCTAssertEqual(vm.topBufferedEditorID, third)

        // Popping unwinds to the next one out, so Esc follows the user back.
        vm.unregisterBufferedEditor(third)
        XCTAssertEqual(vm.topBufferedEditorID, second)
        vm.unregisterBufferedEditor(second)
        XCTAssertEqual(vm.topBufferedEditorID, first)
    }

    // MARK: - Registration hygiene

    /// `.onAppear` can fire again for an already-registered editor (a re-appear on
    /// return from a child push). That must refresh the entry, not duplicate it —
    /// a duplicate would leave a stale registration behind on unregister and pin
    /// `hasMountedBufferedEditor` true forever.
    func testReRegisteringSameEditorIsIdempotent() {
        let vm = SettingsViewModel()
        let editor = UUID()

        vm.registerBufferedEditor(editor, isDirty: false)
        vm.registerBufferedEditor(editor, isDirty: true)

        XCTAssertEqual(vm.bufferedEditors.count, 1)
        XCTAssertTrue(vm.editorHasUnsavedChanges)

        vm.unregisterBufferedEditor(editor)
        XCTAssertFalse(vm.hasMountedBufferedEditor)
    }

    /// Live edits flow through `setBufferedEditorDirty`, and an unknown id is a
    /// no-op rather than a phantom registration.
    func testSetDirtyTracksEditsAndIgnoresUnknownEditors() {
        let vm = SettingsViewModel()
        let editor = UUID()
        vm.registerBufferedEditor(editor, isDirty: false)

        vm.setBufferedEditorDirty(editor, true)
        XCTAssertTrue(vm.editorHasUnsavedChanges)
        vm.setBufferedEditorDirty(editor, false)
        XCTAssertFalse(vm.editorHasUnsavedChanges)

        vm.setBufferedEditorDirty(UUID(), true)
        XCTAssertFalse(vm.editorHasUnsavedChanges)
        XCTAssertEqual(vm.bufferedEditors.count, 1)
    }

    /// Unregistering an id that was never registered must not disturb the stack.
    func testUnregisteringUnknownEditorIsHarmless() {
        let vm = SettingsViewModel()
        let editor = UUID()
        vm.registerBufferedEditor(editor, isDirty: true)

        vm.unregisterBufferedEditor(UUID())

        XCTAssertEqual(vm.bufferedEditors.count, 1)
        XCTAssertTrue(vm.editorHasUnsavedChanges)
    }

    // MARK: - The direct-writer setter

    /// Non-chrome writers (the onboarding gateway steps, the container
    /// belt-and-braces resets, the existing tests) still assert dirtiness through
    /// the property, with no editor registered at all.
    func testDirectWriterAssertsDirtinessWithoutAnyEditor() {
        let vm = SettingsViewModel()

        vm.editorHasUnsavedChanges = true
        XCTAssertTrue(vm.editorHasUnsavedChanges)
        XCTAssertFalse(vm.hasMountedBufferedEditor, "no editor is mounted — only the direct flag is set")

        vm.editorHasUnsavedChanges = false
        XCTAssertFalse(vm.editorHasUnsavedChanges)
    }

    /// `= false` is a HARD RESET: it clears registered editors' dirty bits too,
    /// which is what the outer Discard pre-clear and the sheet-dismiss cleanup have
    /// always meant. Registrations survive — the editors are torn down by their own
    /// `.onDisappear`, not by this.
    func testFalseIsAHardResetAcrossTheStack() {
        let vm = SettingsViewModel()
        let parent = UUID()
        let child = UUID()
        vm.registerBufferedEditor(parent, isDirty: true)
        vm.registerBufferedEditor(child, isDirty: true)

        vm.editorHasUnsavedChanges = false

        XCTAssertFalse(vm.editorHasUnsavedChanges)
        XCTAssertEqual(vm.bufferedEditors.count, 2, "the editors are still on screen")
        XCTAssertTrue(vm.bufferedEditors.allSatisfy { !$0.isDirty })
    }

    /// A direct assertion and a registered dirty editor are independent sources —
    /// clearing one must not clear the other's contribution.
    func testDirectFlagAndEditorDirtinessAreIndependent() {
        let vm = SettingsViewModel()
        let editor = UUID()

        vm.editorHasUnsavedChanges = true
        vm.registerBufferedEditor(editor, isDirty: false)
        XCTAssertTrue(vm.editorHasUnsavedChanges, "the direct flag still stands")

        vm.setBufferedEditorDirty(editor, true)
        vm.editorHasUnsavedChanges = false
        XCTAssertFalse(vm.editorHasUnsavedChanges, "a hard reset clears both sources")

        vm.setBufferedEditorDirty(editor, true)
        XCTAssertTrue(vm.editorHasUnsavedChanges, "a fresh edit re-dirties the surface")
    }
}
