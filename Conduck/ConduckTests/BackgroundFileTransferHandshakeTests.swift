// SPDX-License-Identifier: Apache-2.0

//
//  BackgroundFileTransferHandshakeTests.swift
//  ConduckTests
//
//  Locks the pure status→error seam that drives the WebDAV create-parent
//  handshake (`BackgroundFileTransfer.completionError(statusCode:isUpload:)`).
//  The handshake is the ONE documented carve-out to the driver's fail-fast
//  policy: a nested-PUT 409 (missing parent collection, RFC 4918 §9.7) is the
//  server forcing a MKCOL + re-PUT, so the completion path must hand `uploadFile`
//  the `NestedPutParentMissing` sentinel for a 409-on-upload and NOTHING else —
//  every other status keeps its legacy mapping, and a 409 on a DOWNLOAD (or a
//  405 on an upload — MKCOL cannot fix "method disallowed") must NOT trip the
//  handshake.
//
//  Deterministic + headless: pure function under test, no network, no session,
//  no Keychain. `AppError` is `LocalizedError`, NOT `Equatable` (its
//  `Error`-carrying cases block a synthesized `==`), so results are compared by
//  the stable numeric `errorCode`.
//

import XCTest
@testable import Conduck

final class BackgroundFileTransferHandshakeTests: XCTestCase {

    // MARK: - The 409 handshake trigger (upload only)

    func testUpload409YieldsNestedPutParentMissingSentinel() {
        let result = BackgroundFileTransfer.completionError(statusCode: 409, isUpload: true)
        XCTAssertEqual(result as? BackgroundFileTransfer.NestedPutParentMissing,
                       BackgroundFileTransfer.NestedPutParentMissing(),
                       "a 409 on an upload is the create-parent handshake signal, not an AppError")
    }

    /// A 409 on a DOWNLOAD keeps the legacy default mapping — the handshake is an
    /// upload-only protocol step; a download 409 is not ours to fix with a MKCOL.
    func testDownload409KeepsLegacyUploadFailedMapping() {
        let result = BackgroundFileTransfer.completionError(statusCode: 409, isUpload: false)
        XCTAssertNil(result as? BackgroundFileTransfer.NestedPutParentMissing,
                     "a download 409 must NOT surface the handshake sentinel")
        XCTAssertEqual((result as? AppError)?.errorCode,
                       AppError.fileTransferUploadFailed.errorCode,
                       "a download 409 keeps the legacy fail-fast mapping")
    }

    /// 405 on an upload (target is a collection / method disallowed) is the
    /// locked design decision NOT to trigger the handshake — MKCOL + re-PUT
    /// cannot fix it, so it stays the fail-fast default.
    func testUpload405DoesNotTriggerHandshake() {
        let result = BackgroundFileTransfer.completionError(statusCode: 405, isUpload: true)
        XCTAssertNil(result as? BackgroundFileTransfer.NestedPutParentMissing,
                     "405 on a PUT means MKCOL cannot help — not the handshake")
        XCTAssertEqual((result as? AppError)?.errorCode,
                       AppError.fileTransferUploadFailed.errorCode,
                       "405 on a PUT stays the fail-fast default")
    }

    // MARK: - Success + non-HTTP

    func testSuccessStatusesYieldNil() {
        XCTAssertNil(BackgroundFileTransfer.completionError(statusCode: 201, isUpload: true),
                     "201 Created is a successful PUT")
        XCTAssertNil(BackgroundFileTransfer.completionError(statusCode: 204, isUpload: true),
                     "204 No Content is a successful PUT")
    }

    /// A nil status (non-`HTTPURLResponse`) yields nil — only an HTTP response
    /// carries a status to map; a transport failure is the delegate's `error`
    /// path, so this seam stays out of it.
    func testNilStatusYieldsNil() {
        XCTAssertNil(BackgroundFileTransfer.completionError(statusCode: nil, isUpload: true))
        XCTAssertNil(BackgroundFileTransfer.completionError(statusCode: nil, isUpload: false))
    }

    // MARK: - Legacy status mappings preserved (both directions)

    func testAuthFailuresMapToAuthFailed() {
        for status in [401, 403] {
            XCTAssertEqual(
                (BackgroundFileTransfer.completionError(statusCode: status, isUpload: true) as? AppError)?.errorCode,
                AppError.fileTransferAuthFailed.errorCode,
                "\(status) → auth failed")
        }
    }

    func testNotFoundMapsToFileUnavailable() {
        XCTAssertEqual(
            (BackgroundFileTransfer.completionError(statusCode: 404, isUpload: true) as? AppError)?.errorCode,
            AppError.fileTransferFileUnavailable.errorCode,
            "404 → file unavailable")
    }

    func testServerErrorsMapToServerError() {
        for status in [500, 503] {
            XCTAssertEqual(
                (BackgroundFileTransfer.completionError(statusCode: status, isUpload: true) as? AppError)?.errorCode,
                AppError.fileTransferServerError.errorCode,
                "\(status) → server error")
        }
    }
}
