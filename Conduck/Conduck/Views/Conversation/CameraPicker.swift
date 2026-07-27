// SPDX-License-Identifier: Apache-2.0

#if os(iOS)
// Conduck
// CameraPicker.swift
//
// There is no SwiftUI-native camera, so this is a thin
// `UIViewControllerRepresentable` bridge over `UIImagePickerController`
// (`sourceType: .camera`) that returns the captured image as JPEG `Data` (the
// VM's `ImageProcessor` re-encodes/downsizes it anyway, but JPEG keeps the
// staging payload small). Present as a `.fullScreenCover` from the host.
//
// JIT permission (key UX decision #5): the host checks
// `AVCaptureDevice.authorizationStatus(for: .video)` BEFORE presenting. On
// `.denied`/`.restricted` it must NOT present a black camera — instead it shows
// an inline alert with an "Open Settings" button (the helper enum below
// provides the status check + the settings-URL open so the host stays thin).
// `.notDetermined` is fine to present: `UIImagePickerController` triggers the
// system permission prompt itself on first appearance.

import SwiftUI
import UIKit
import AVFoundation

struct CameraPicker: UIViewControllerRepresentable {
    /// Captured image bytes (JPEG). Called on the main actor; nil never sent —
    /// a cancel just dismisses.
    let onCapture: (Data) -> Void
    /// Dismiss the cover (cancel or after capture).
    let onDismiss: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onDismiss: () -> Void

        init(onCapture: @escaping (Data) -> Void, onDismiss: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onDismiss = onDismiss
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.95) {
                onCapture(data)
            }
            onDismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDismiss()
        }
    }
}

/// JIT camera-permission helper for the host. Keeps the authorization check +
/// the Settings-deep-link in one place so the host's camera-tap handler stays
/// thin (check → present cover OR show denied alert → "Open Settings").
enum CameraPermission {
    enum Access {
        /// Safe to present the camera (authorized, or not-yet-determined — the
        /// picker triggers the system prompt itself on first appearance).
        case proceed
        /// Denied / restricted — show the inline alert, do NOT present.
        case denied
    }

    static var current: Access {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted: return .denied
        case .authorized, .notDetermined: return .proceed
        @unknown default: return .proceed
        }
    }

    /// Open the app's Settings page so the user can flip camera access on.
    @MainActor
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
#endif
