// SPDX-License-Identifier: Apache-2.0

// Conduck
// PairingScannerView.swift
//
// iOS-only live QR viewport for the pairing-import sheet — a
// `UIViewControllerRepresentable` over VisionKit's `DataScannerViewController`,
// embedded at the top of `PairingImportSheet`'s input step. Recognizes QR codes
// only; every recognized payload gets a cheap `"conduck-setup:"` prefix check
// and then a FULL `PairingPayload.parse` — unrelated QR codes (WiFi cards,
// URLs, …) are ignored silently, never surfaced as errors. On the first
// successful parse: stop scanning, success haptic, fire `onCode` exactly once.
// A code that IS a `conduck-setup:` payload but fails to parse (a newer
// `conduck-setup:v2` or a damaged v1) fires `onRejected` — once per unique
// payload string — and keeps scanning, so the camera never looks dead on a
// Conduck code it can't use.
//
// WHOLE FILE is `#if os(iOS) && canImport(VisionKit)`-gated: the synchronized
// pbxproj group compiles every file under `Conduck/` into the macOS slice too,
// and `DataScannerViewController` is iOS-only — the guard is mandatory, not
// hygiene. NOT a Watch-target member.
//
// PRIVACY (docs/ai-context/spec.md): the recognized payload string embeds the
// gateway bearer token + file-server credential. It is handed to `onCode` and
// NEVER logged, echoed, or stored here.

#if os(iOS) && canImport(VisionKit)
import SwiftUI
import UIKit
import Vision
import VisionKit

struct PairingScannerView: UIViewControllerRepresentable {
    /// Fired ONCE with the raw recognized pairing string (already verified to
    /// fully parse as a `PairingPayload`). The receiver re-parses — cheap and
    /// keeps a single source of truth.
    let onCode: (String) -> Void

    /// Fired when live scanning can't start (camera restriction, capture
    /// failure, …) so the host can fall back to the paste-only layout.
    var onUnavailable: (() -> Void)? = nil

    /// Fired when a scanned code IS a `conduck-setup:` payload but fails to
    /// parse (unsupported version / damaged) — carries the typed error so the
    /// host can surface the matching inline copy. Fired once per unique payload
    /// string; scanning continues. Default no-op keeps existing call sites
    /// source-compatible. NEVER carries payload content (`PairingParseError` is
    /// a bare enum — no secrets).
    var onRejected: ((PairingParseError) -> Void)? = nil

    /// Whether live QR scanning is possible on this device right now
    /// (hardware + OS support AND not blocked by camera restrictions).
    static var isAvailableForScanning: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {
        // Keep the coordinator's callbacks fresh (the representable struct is
        // re-created on every parent update; the coordinator persists).
        context.coordinator.onCode = onCode
        context.coordinator.onUnavailable = onUnavailable
        context.coordinator.onRejected = onRejected

        // Start (or restart) scanning once mounted. After a successful fire the
        // viewport stays frozen — the sheet moves on to the import stages.
        guard !context.coordinator.didFire, !uiViewController.isScanning else { return }
        do {
            try uiViewController.startScanning()
        } catch {
            // Camera unavailable / restricted — degrade to paste-only. The
            // error itself is NOT surfaced (it can't carry payload content,
            // but the paste fallback is the whole remedy anyway).
            onUnavailable?()
        }
    }

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onUnavailable: onUnavailable, onRejected: onRejected)
    }

    // MARK: - Coordinator (DataScanner delegate)

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var onUnavailable: (() -> Void)?
        var onRejected: ((PairingParseError) -> Void)?

        /// One-shot latch — `didAdd`/`didUpdate` both stream while a code is in
        /// frame; the FIRST successful parse wins and every later recognition
        /// is dropped so `onCode` can never double-fire.
        private(set) var didFire = false

        /// Every `conduck-setup:` payload that already failed to parse — both
        /// delegate callbacks stream in-frame codes continuously, so this de-dupes
        /// `onRejected` to once per unique payload string for the scanner's
        /// lifetime (two damaged codes in frame must not alternate re-fires).
        private var rejectedPayloads: Set<String> = []

        init(
            onCode: @escaping (String) -> Void,
            onUnavailable: (() -> Void)?,
            onRejected: ((PairingParseError) -> Void)?
        ) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
            self.onRejected = onRejected
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(addedItems, scanner: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            handle(updatedItems, scanner: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            onUnavailable?()
        }

        private func handle(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !didFire else { return }
            for item in items {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue,
                      payload.trimmingCharacters(in: .whitespacesAndNewlines)
                          .hasPrefix("conduck-setup:")  // cheap gate: a Conduck code
                else { continue }                        // anything else is ignored silently

                switch PairingPayload.parse(payload) {   // full validation
                case .success:
                    didFire = true
                    scanner.stopScanning()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(payload)
                    return
                case .failure(let error):
                    // A Conduck code that can't be used (newer version / damaged):
                    // surface the typed error ONCE and keep scanning, so the camera
                    // never silently drops a code the user clearly meant to scan.
                    if rejectedPayloads.insert(payload).inserted {
                        onRejected?(error)
                    }
                }
            }
        }
    }
}
#endif
