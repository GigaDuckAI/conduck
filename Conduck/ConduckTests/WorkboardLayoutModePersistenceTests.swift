// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardLayoutModePersistenceTests.swift
//
// The desk's layout preference belongs to the view model, so a control declared
// ABOVE the board — a toolbar item that cannot reach the board's own state —
// drives the same value the board draws from. Two halves of that contract are
// worth holding: a model adopts what the last session stored, and every write
// reaches the storage seam once, from the model rather than from a view. The
// second is the one that decides whether a preference survives a relaunch, and
// it is invisible on screen for as long as the model that made the change is
// still alive.
//
// The host is built with `CONDUCK_TESTING`, so the defaults these tests read
// and clear are the in-memory double the app itself is running on.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardLayoutModePersistenceTests: XCTestCase {
    private enum TestError: Error { case unexpectedCall }

    override func setUp() async throws {
        try await super.setUp()
        TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
    }

    override func tearDown() async throws {
        TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
        try await super.tearDown()
    }

    // MARK: - Adoption

    func testLayoutModeDefaultsToTilesWithNothingStored() {
        XCTAssertEqual(makeViewModel().layoutMode, .tiles)
    }

    func testLayoutModeAdoptsThePersistedModeOnConstruction() {
        WorkboardLayoutMode.list.save()

        XCTAssertEqual(makeViewModel().layoutMode, .list)
    }

    // MARK: - Persistence

    func testSettingLayoutModePersistsIt() {
        let viewModel = makeViewModel()

        viewModel.layoutMode = .list

        XCTAssertEqual(WorkboardLayoutMode.load(), .list)
    }

    func testAPersistedLayoutModeOutlivesTheModelThatWroteIt() {
        makeViewModel().layoutMode = .list

        // A relaunch is exactly this: a second model reading the same store.
        XCTAssertEqual(makeViewModel().layoutMode, .list)
    }

    func testSwitchingBackToTilesPersistsToo() {
        WorkboardLayoutMode.list.save()
        let viewModel = makeViewModel()

        viewModel.layoutMode = .tiles

        XCTAssertEqual(WorkboardLayoutMode.load(), .tiles)
        XCTAssertEqual(makeViewModel().layoutMode, .tiles)
    }

    /// Every case, through the STORE rather than only through `load()`.
    ///
    /// `load()` falls back to `.tiles` on a missing or unreadable value, so a
    /// Tiles assertion taken on `load()` alone cannot tell a value that was
    /// written and read back from a value that was never written at all — the
    /// fallback answers Tiles for both. Reading the raw string out of the store
    /// separates them, and `allCases` keeps the pair of assertions honest when a
    /// third layout is added: a case whose `rawValue` collides or whose write
    /// never lands fails here instead of shipping as "it just opens in Tiles".
    func testEveryLayoutModeRoundTripsThroughItsStoredRawValue() {
        for mode in WorkboardLayoutMode.allCases {
            // Path 1 — the type's own writer.
            TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
            mode.save()

            XCTAssertEqual(
                TestStores.defaults.string(forKey: Constants.workboardLayoutKey), mode.rawValue,
                "\(mode) did not store its own raw value. Nothing is in the store for the next launch "
                + "to read, and `load()` will answer Tiles from its fallback whatever this case was."
            )
            XCTAssertEqual(
                WorkboardLayoutMode.load(), mode,
                "\(mode) did not survive a read back through `load()` — the value written and the "
                + "value parsed disagree."
            )
            XCTAssertEqual(
                makeViewModel().layoutMode, mode,
                "A model built after \(mode) was stored did not adopt it, so a relaunch opens the "
                + "desk in a layout the user did not choose."
            )

            // Path 2 — the model's `didSet`, which is what the toolbar's picker
            // actually drives. Run from a CLEARED store, so a case that happens
            // to match the fallback still has to prove it wrote something.
            TestStores.defaults.removeObject(forKey: Constants.workboardLayoutKey)
            makeViewModel().layoutMode = mode

            XCTAssertEqual(
                TestStores.defaults.string(forKey: Constants.workboardLayoutKey), mode.rawValue,
                "Assigning \(mode) on the view model stored nothing. The preference then lives only "
                + "in the model that made the change and dies with it — invisible on screen for as "
                + "long as that model is alive."
            )
            XCTAssertEqual(
                WorkboardLayoutMode.load(), mode,
                "Assigning \(mode) on the view model did not reach the value a next launch reads."
            )
        }
    }

    /// A board that only answers for its layout preference. Every desk
    /// operation throws or does nothing: none of them is reached here, and a
    /// stub that quietly succeeded would hide a test that started calling one.
    private func makeViewModel() -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { nil },
            importMaterial: { _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openMaterial: { _ in }
        ))
    }
}
