// Conduck
// AppleOnDeviceEngineModeTests.swift
//
// Pure coverage for `AppleOnDeviceEngineMode` — the stored choice between the
// keyboard-dictation engine (default) and the downloadable high-quality model.
// Raw values are persisted (App-Group defaults + iCloud KVS), so they are
// LOCKED storage literals; `fromStored` must never dead-end voice on a corrupt
// value. No I/O — the SettingsManager round-trip lives in
// `SettingsManagerICloudSyncTests`.

import XCTest
@testable import Conduck

final class AppleOnDeviceEngineModeTests: XCTestCase {

    func testDefaultIsDictation() {
        XCTAssertEqual(AppleOnDeviceEngineMode.default, .dictation,
                       "Fresh / unset on-device engine must be keyboard dictation (no download).")
    }

    func testRawValuesAreLockedStorageLiterals() {
        XCTAssertEqual(AppleOnDeviceEngineMode.dictation.rawValue, "dictation")
        XCTAssertEqual(AppleOnDeviceEngineMode.highQuality.rawValue, "highQuality")
    }

    func testFromStoredDecodesKnownValues() {
        XCTAssertEqual(AppleOnDeviceEngineMode.fromStored("dictation"), .dictation)
        XCTAssertEqual(AppleOnDeviceEngineMode.fromStored("highQuality"), .highQuality)
    }

    func testFromStoredFallsBackToDictationOnNilOrGarbage() {
        XCTAssertEqual(AppleOnDeviceEngineMode.fromStored(nil), .dictation,
                       "A missing value must resolve to the dictation default.")
        XCTAssertEqual(AppleOnDeviceEngineMode.fromStored(""), .dictation)
        XCTAssertEqual(AppleOnDeviceEngineMode.fromStored("speechAnalyzer"), .dictation,
                       "An unrecognized raw value must never dead-end voice — fall back to dictation.")
    }

    func testAllCasesAreExactlyTwo() {
        XCTAssertEqual(AppleOnDeviceEngineMode.allCases.count, 2)
    }
}
