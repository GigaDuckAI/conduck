// SPDX-License-Identifier: Apache-2.0

// ConduckTests
// WorkboardBoardProjectionTests.swift
//
// The board's derived surface: the composer's emptiness flag normalizes before
// it answers.

import XCTest
@testable import Conduck

@MainActor
final class WorkboardBoardProjectionTests: XCTestCase {
    private enum TestError: Error { case unexpectedCall }

    // MARK: - Composer flag

    func testComposerFlagTracksNormalizedEmptinessRatherThanRawText() {
        let viewModel = makeViewModel()
        let itemID = Constants.workboardDeskItemID

        viewModel.setWorkspaceComposerDraft("   \n ", for: itemID)
        XCTAssertFalse(viewModel.hasComposerDraft(for: itemID), "whitespace is not a thought")

        viewModel.setWorkspaceComposerDraft("  a real thought ", for: itemID)
        XCTAssertTrue(viewModel.hasComposerDraft(for: itemID))

        viewModel.setWorkspaceComposerDraft("", for: itemID)
        XCTAssertFalse(viewModel.hasComposerDraft(for: itemID))
    }

    // MARK: - Helpers

    private func makeViewModel() -> WorkboardViewModel {
        WorkboardViewModel(dependencies: WorkboardViewModel.Dependencies(
            loadDesk: { nil },
            importMaterial: { _, _, _ in throw TestError.unexpectedCall },
            removeMaterial: { _, _ in throw TestError.unexpectedCall },
            replaceMaterial: { _, _, _, _ in throw TestError.unexpectedCall },
            openConversation: { _ in },
            openMaterial: { _ in },
            openGatewaySettings: {}
        ))
    }
}
