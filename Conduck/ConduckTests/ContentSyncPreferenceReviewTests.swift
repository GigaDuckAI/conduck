// SPDX-License-Identifier: Apache-2.0

// Independent failure-case coverage for preference values received from other
// devices. A valid but exhausted revision must never make an explicit OFF write
// become an invalid stored value that subsequently falls back to default ON.

import XCTest
@testable import Conduck

final class ContentSyncPreferenceReviewTests: XCTestCase {
    func testAnExhaustedIncomingRevisionCannotTurnAnExplicitOffBackOn() throws {
        let store = ContentSyncPreferenceStore(dependencies: .inMemory())
        let incoming = ContentSyncPreference(enabled: false, revision: Int64.max - 1, identifier: UUID())
        _ = store.adopt(incoming)

        do {
            let written = try store.setEnabled(false)
            XCTAssertTrue(written.isValid, "A successful preference write must remain decodable as a valid preference.")
        } catch {
            // Refusing an unrepresentable revision is acceptable; silently
            // losing OFF by writing an invalid one is not.
        }
        XCTAssertFalse(store.isEnabled, "The explicit OFF choice must never fall through to synthesized ON.")
    }
}
