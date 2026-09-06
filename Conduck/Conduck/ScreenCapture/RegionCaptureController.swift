// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// RegionCaptureController.swift
//
// macOS region-screenshot capture, shared by the TWO menu-bar lanes that start
// with a drag:
//   • ⌘⇧2 "Screenshot & Ask"  (`.ask`)  — the screenshot IS the request, so
//     anything short of pixels aborts the flow.
//   • ⌃⌘W "Capture to Work"   (`.work`) — the screenshot is optional decoration
//     on a private note, so every stop offers a way to continue without one.
// This file owns ONLY the CAPTURE half:
//   1. preflight BOTH permissions (mic + Screen Recording) BEFORE any overlay,
//   2. a dimmed crosshair overlay window the user drags a region on,
//   3. a ScreenCaptureKit screenshot of that region → lossless PNG `Data`.
// The caller owns the recording + send/save half (Ask's `ImageProcessor`
// normalises the PNG to a JPEG data-URI at send time).
//
// Single public entry:
//   `captureRegion(purpose:requiresMicrophone:) async -> RegionCaptureOutcome`.
// The answer is an ENUM rather than `Data?` because Work must distinguish "the
// person chose no screenshot" (`.skipped` — start the microphone anyway) from
// "we could not take one" (`.cancelled` / `.unavailable` — start nothing). One
// `nil` cannot carry that split, and guessing either way is a real failure: a
// wrong `.skipped` starts a microphone nobody asked for, a wrong `.cancelled`
// drops the note the user did ask for. Never writes the screenshot to disk and
// never logs image bytes (in-memory PNG only).
//
// Permission preflight is deliberately UP FRONT so the user is never allowed to
// drag-select and only THEN hit a permission wall. Screen Recording consent is
// per TCC identity (code SIGNATURE) and resettable — a re-signed install
// (dev → TestFlight), `tccutil reset`, or removal in System Settings all make
// the system consent dialog appear again — so NO persisted flag can predict
// whether it will show. The flow is therefore RATIONALE-FIRST: Conduck's own
// alert always precedes `CGRequestScreenCaptureAccess()` (which returns the
// current grant immediately; the first request for this TCC identity since the
// last reset also pops the system consent dialog), making the two dialogs
// strictly sequential — never simultaneous — in every TCC state. A grant
// recorded but not adopted by this process (macOS frequently applies it only
// at the next launch) is treated as "relaunch needed", with a one-click Quit.
//
// Alert COPY is parameterized by purpose, not shared: Ask's wording promises
// that the screenshot and the spoken words go to the configured AI gateway,
// which is simply false on the Work lane (the desk is local and nothing there
// reaches a gateway). A permission prompt that misstates where data goes is the
// worst possible place for reused copy.
//
// Overlay design mirrors `MenuBarController.showPopover()`'s activation
// rationale: a borderless background-app window can't become key (no keyDown
// for Esc) unless we `NSApp.activate(ignoringOtherApps:)` + override
// `canBecomeKey`/`canBecomeMain`.

import AppKit
import ScreenCaptureKit
import CoreGraphics
import AVFoundation

/// Which lane asked for the capture. Drives the overlay hint, whether Return
/// skips the screenshot, and the permission-alert copy and buttons.
enum RegionCapturePurpose: Sendable {
    /// ⌘⇧2 — the screenshot is the question. No skip anywhere.
    case ask
    /// ⌃⌘W — the screenshot is optional; every stop can continue without it.
    case work
}

/// How a capture attempt ended. Four outcomes rather than `Data?` because the
/// Work lane acts differently on three of them (see the file header).
enum RegionCaptureOutcome: Sendable {
    /// Lossless PNG bytes for the dragged region.
    case captured(Data)
    /// Work only: the person deliberately chose to continue WITHOUT a
    /// screenshot (Return, the overlay's skip action, or a permission alert's
    /// "Continue Without Screenshot"). The caller proceeds with the rest of the
    /// capture.
    case skipped
    /// The person backed out of the whole capture: Esc, a sub-4pt drag
    /// (mis-click), Cancel in a permission alert, an outside dismiss. The
    /// caller starts nothing.
    case cancelled
    /// Conduck could not take a screenshot: a re-entrant call, a permission
    /// denied with no skip chosen, a ScreenCaptureKit failure, an empty shot.
    /// Distinct from `.cancelled` only for the caller's own logging/telemetry —
    /// both mean "start nothing" on the Ask lane.
    case unavailable
}

/// Drives the region-capture flow for both lanes: permission preflight →
/// crosshair overlay → ScreenCaptureKit screenshot. Main-actor isolated (all
/// overlay UI) with an async public method (the SCK capture hop is async).
@MainActor
final class RegionCaptureController {

    /// Full flow: preflight permissions → dimmed crosshair overlay → user drags
    /// a region → capture that region via ScreenCaptureKit.
    /// `purpose` (default `.ask`) selects the hint text, whether Return skips,
    /// and the alert copy/buttons; only `.work` can ever produce `.skipped`.
    /// `requiresMicrophone` (default true — the voice flow) gates the mic half
    /// of the preflight: a TEXT-mode capture types its words, so demanding mic
    /// access there would block a feature that never records.
    func captureRegion(
        purpose: RegionCapturePurpose = .ask,
        requiresMicrophone: Bool = true
    ) async -> RegionCaptureOutcome {
        // Re-entrancy guard: the preflight's `runModal` alerts pump a nested
        // run loop that still delivers the global hotkey, so a second press
        // mid-flow would stack a second alert (or overlay) on the first.
        // MainActor isolation makes the check-and-set race-free.
        // `.unavailable`, never `.skipped`: a dropped duplicate press is not a
        // decision to go without a screenshot, and treating it as one would
        // start a microphone off a stray keystroke.
        guard !captureFlowActive else { return .unavailable }
        captureFlowActive = true
        defer { captureFlowActive = false }

        // 1. Preflight permissions before showing any overlay. Never let the
        //    user drag-then-fail.
        switch await preflightPermissions(purpose: purpose, requiresMicrophone: requiresMicrophone) {
        case .proceed:
            break
        case .skipScreenshot:
            return .skipped
        case .cancelled:
            return .cancelled
        case .unavailable:
            return .unavailable
        }

        // 2. Crosshair overlay → user drags a region (or, on Work, skips it) or
        //    cancels with Esc / a too-small drag / an outside dismiss.
        let selection: RegionSelection
        switch await presentOverlay(purpose: purpose) {
        case .selected(let region):
            selection = region
        case .skipped:
            return .skipped
        case .cancelled:
            return .cancelled
        case .unavailable:
            return .unavailable
        }

        // 3. Capture the resolved rect via ScreenCaptureKit (overlay already
        //    torn down inside `presentOverlay`, so the dim chrome is never shot).
        //    A failed capture is `.unavailable`, NOT `.skipped`: nobody chose to
        //    go without the image, so Work must not silently save a note that
        //    was supposed to carry one.
        guard let data = await captureSelection(selection) else { return .unavailable }
        return .captured(data)
    }

    /// `true` while a capture flow (preflight alert, overlay, or SCK hop) is
    /// in progress — see the re-entrancy guard in `captureRegion`.
    private var captureFlowActive = false

    // MARK: - 1. Permission preflight

    /// How the preflight ended. `.skipScreenshot` is reachable only on the Work
    /// lane, where a permission wall is a reason to drop the picture rather than
    /// the whole note.
    private enum PreflightOutcome {
        case proceed
        case skipScreenshot
        case cancelled
        case unavailable
    }

    /// `.proceed` only when the needed permissions are usable RIGHT NOW (mic
    /// checked only when `requiresMicrophone` — the text-mode flow never
    /// records). Mic uses the same authorization primitive as the voice-capture
    /// pipeline (`AudioRecorder.startRecording()` →
    /// `AVAudioApplication.requestRecordPermission()`). Screen Recording uses
    /// the `CGPreflight…`/`CGRequest…` pair behind a rationale-first alert (see
    /// header). Anything else → the overlay is never shown.
    private func preflightPermissions(
        purpose: RegionCapturePurpose,
        requiresMicrophone: Bool
    ) async -> PreflightOutcome {
        // --- Microphone (mirrors AudioRecorder.swift:32) ---
        // A non-prompting status read first, so an already-decided "denied" goes
        // straight to the alert rather than re-prompting. `.notDetermined` falls
        // through to the same async request the recorder uses.
        if requiresMicrophone {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            let micGranted: Bool
            switch micStatus {
            case .authorized:
                micGranted = true
            case .notDetermined:
                micGranted = await AVAudioApplication.requestRecordPermission()
            case .denied, .restricted:
                micGranted = false
            @unknown default:
                micGranted = false
            }

            guard micGranted else {
                // No skip offered here even on Work: a missing microphone stops
                // the RECORDING, not the screenshot, so "continue without a
                // screenshot" would offer to continue with nothing at all.
                switch showMicrophonePermissionAlert(purpose: purpose) {
                case .primary:
                    return .unavailable
                case .skip, .cancel:
                    // `.skip` is unreachable (this alert never offers one) and
                    // folds into cancel so the switch stays total without a
                    // trap in a permission path.
                    return .cancelled
                }
            }
        }

        // --- Screen Recording ---
        if CGPreflightScreenCaptureAccess() {
            // Diagnostics relevance gate: the feature is live on this Mac —
            // surface the (green) Screen Recording capability row.
            SettingsDependencies.processDefault.defaults
                .set(true, forKey: Constants.screenRecordingCaptureAttemptedKey)
            return .proceed
        }

        // Rationale-first (see header): our alert always precedes the system
        // ask, so the two dialogs are strictly sequential in every TCC state —
        // never simultaneous.
        switch showScreenRecordingRationale(purpose: purpose) {
        case .primary:
            break
        case .skip:
            return .skipScreenshot
        case .cancel:
            return .cancelled
        }

        // The request call itself registers Conduck in the Screen & System
        // Audio Recording pane — only from this point may the Diagnostics row
        // send the user there (its gate written any earlier would deep-link a
        // pane with no Conduck entry). Cancelling the rationale above
        // deliberately leaves the row hidden.
        let granted = CGRequestScreenCaptureAccess()
        SettingsDependencies.processDefault.defaults
            .set(true, forKey: Constants.screenRecordingCaptureAttemptedKey)

        if granted {
            // Grant recorded in TCC but not adopted by THIS process — macOS
            // frequently applies it only at the next launch, so proceeding
            // would silently capture desktop-wallpaper-only pixels. Tell
            // the user to relaunch instead. (No system dialog in this state.)
            switch showGrantNeedsRelaunchAlert(purpose: purpose) {
            case .primary:
                return .unavailable
            case .skip:
                return .skipScreenshot
            case .cancel:
                return .cancelled
            }
        }

        // Either the system consent dialog is now up (first request for this
        // TCC identity) or the system stayed silent (prior denial, or a grant
        // recorded under a previous code signature).
        switch purpose {
        case .ask:
            // Open the exact Settings pane unconditionally: for a denial it IS
            // the repair; for a fresh ask it merely pre-opens the pane the
            // system dialog's own button leads to. Ask has no alert here
            // because it has no third choice — without pixels there is no
            // question to send.
            openPrivacyPane("Privacy_ScreenCapture")
            return .unavailable
        case .work:
            // Work DOES have a third choice, so it needs a surface to offer it
            // on; the deep link moves behind that alert's primary button.
            switch showScreenRecordingDeniedAlert() {
            case .primary:
                return .unavailable
            case .skip:
                return .skipScreenshot
            case .cancel:
                return .cancelled
            }
        }
    }

    /// Mic missing (voice-mode capture only). Single-purpose, friendly alert:
    /// explains WHY and deep-links the Microphone privacy pane. Ask states the
    /// data flow (screenshot + your words → YOUR configured gateway); Work says
    /// nothing of the sort because nothing on the desk leaves the Mac.
    private func showMicrophonePermissionAlert(purpose: RegionCapturePurpose) -> PermissionAlertChoice {
        let choice = runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.mic.title",
                defaultValue: "Conduck needs microphone access"
            )),
            body: microphoneBody(for: purpose),
            primaryButton: String(localized: LocalizedStringResource(
                "regionCapture.permission.openSettings",
                defaultValue: "Open System Settings"
            )),
            offersSkip: false
        )
        if choice == .primary {
            openPrivacyPane("Privacy_Microphone")
        }
        return choice
    }

    private func microphoneBody(for purpose: RegionCapturePurpose) -> String {
        switch purpose {
        case .ask:
            return String(localized: LocalizedStringResource(
                "regionCapture.permission.mic.body",
                defaultValue: "Region Capture lets you select part of your screen and ask about it by voice. To record your question, Conduck needs microphone access.\n\nYour screenshot and your words are sent only to the AI gateway you configured — nowhere else."
            ))
        case .work:
            return String(localized: LocalizedStringResource(
                "regionCapture.permission.mic.work.body",
                defaultValue: "Capture to Work saves a spoken note on your desk. To record it, Conduck needs microphone access."
            ))
        }
    }

    /// Rationale-first pre-prompt for Screen Recording: ALWAYS shown before
    /// `CGRequestScreenCaptureAccess()`, so Conduck's alert and the system
    /// consent dialog are strictly sequential in every TCC state (see header).
    /// `.primary` = the user chose Continue (consented to the system ask).
    private func showScreenRecordingRationale(purpose: RegionCapturePurpose) -> PermissionAlertChoice {
        runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.title",
                defaultValue: "Conduck needs Screen Recording access"
            )),
            body: screenRationaleBody(for: purpose),
            primaryButton: String(localized: LocalizedStringResource(
                "regionCapture.permission.continue",
                defaultValue: "Continue"
            )),
            offersSkip: purpose == .work
        )
    }

    private func screenRationaleBody(for purpose: RegionCapturePurpose) -> String {
        switch purpose {
        case .ask:
            return String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.body",
                defaultValue: "Region Capture lets you select part of your screen and ask about it. To take that screenshot, Conduck needs Screen Recording access.\n\nIf System Settings already shows Conduck as on, turn it off and on again, then quit and reopen Conduck.\n\nYour screenshot and your words are sent only to the AI gateway you configured — nowhere else."
            ))
        case .work:
            return String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.work.body",
                defaultValue: "Capture to Work can save a picture of part of your screen next to your note. To take that picture, Conduck needs Screen Recording access."
            ))
        }
    }

    /// The grant IS recorded in TCC but this process can't use it — macOS
    /// frequently adopts a Screen Recording grant only at the next launch.
    /// System Settings adds nothing in this state; the only repair is a
    /// relaunch, so the primary action is a one-click quit (manual reopen —
    /// an auto-relaunch helper is sandbox-hostile). "Quit Conduck" reuses the
    /// status-menu item's existing catalog key.
    private func showGrantNeedsRelaunchAlert(purpose: RegionCapturePurpose) -> PermissionAlertChoice {
        let choice = runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.title",
                defaultValue: "Conduck needs Screen Recording access"
            )),
            body: relaunchBody(for: purpose),
            primaryButton: String(localized: "Quit Conduck"),
            offersSkip: purpose == .work
        )
        if choice == .primary {
            NSApp.terminate(nil)
        }
        return choice
    }

    private func relaunchBody(for purpose: RegionCapturePurpose) -> String {
        switch purpose {
        case .ask:
            return String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.relaunchBody",
                defaultValue: "Thanks — Screen Recording is now allowed. macOS only applies this after a restart, so please quit and reopen Conduck, then try Region Capture again.\n\nYour screenshot and your words are sent only to the AI gateway you configured — nowhere else."
            ))
        case .work:
            return String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.work.relaunchBody",
                defaultValue: "Screen Recording is now allowed, but macOS only applies it after a restart. Quit and reopen Conduck to include pictures, or keep going without one."
            ))
        }
    }

    /// Work-only stop: Screen Recording is denied (or the system's own consent
    /// dialog has just come up). Ask deep-links the pane and ends there; Work
    /// needs a surface on which to offer the third choice, so the deep link
    /// becomes this alert's primary button.
    private func showScreenRecordingDeniedAlert() -> PermissionAlertChoice {
        let choice = runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.title",
                defaultValue: "Conduck needs Screen Recording access"
            )),
            body: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.work.deniedBody",
                defaultValue: "Conduck does not have Screen Recording access yet, so it cannot add a picture. Turn it on in System Settings, or keep going without one."
            )),
            primaryButton: String(localized: LocalizedStringResource(
                "regionCapture.permission.openSettings",
                defaultValue: "Open System Settings"
            )),
            offersSkip: true
        )
        if choice == .primary {
            openPrivacyPane("Privacy_ScreenCapture")
        }
        return choice
    }

    /// What the user chose in a permission alert. `.skip` exists only where
    /// `offersSkip` put a button there — i.e. only on the Work lane, where a
    /// screenshot is optional decoration on a note rather than the request.
    private enum PermissionAlertChoice {
        case primary
        case skip
        case cancel
    }

    /// Shared scaffold for the permission alerts: activates the app first (a
    /// modal alert from a menu-bar/background app can't reliably take focus
    /// otherwise — same rationale as `showPopover`), presents an informational
    /// alert with one primary button, an optional "Continue Without Screenshot",
    /// and Cancel LAST. Conventional NSAlert order: the primary leads and the
    /// escape hatch trails, so Return never lands on the choice that abandons
    /// the capture.
    private func runPermissionAlert(
        title: String,
        body: String,
        primaryButton: String,
        offersSkip: Bool
    ) -> PermissionAlertChoice {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: primaryButton)
        if offersSkip {
            alert.addButton(withTitle: String(localized: LocalizedStringResource(
                "regionCapture.permission.skipScreenshot",
                defaultValue: "Continue Without Screenshot"
            )))
        }
        alert.addButton(withTitle: String(localized: LocalizedStringResource(
            "regionCapture.permission.cancel",
            defaultValue: "Cancel"
        )))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .primary
        case .alertSecondButtonReturn:
            // Index 1 is the skip button only when one was added; otherwise it
            // is Cancel, and reading it as a skip would start a microphone the
            // user just declined.
            return offersSkip ? .skip : .cancel
        default:
            // The third button (Cancel, when a skip was added) and any other
            // dismissal. Defaulting to `.cancel` is the safe direction: an
            // unexpected return code must never be read as consent.
            return .cancel
        }
    }

    /// Deep-link to a System Settings → Privacy & Security pane by anchor
    /// (e.g. "Privacy_ScreenCapture", "Privacy_Microphone").
    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - 2. Overlay → selected region

    /// The user's drag result: a region in AppKit GLOBAL (bottom-left origin)
    /// coordinates plus the screen it was drawn on (needed for the SCK display
    /// resolution + coordinate flip).
    private struct RegionSelection {
        let globalRect: NSRect
        let screen: NSScreen
    }

    /// `presentOverlay`'s answer. Differs from `RegionOverlayResult` (the
    /// window's raw report) only in that the rect has been paired with the
    /// screen it was drawn on, and in carrying `.unavailable` for the one
    /// failure the window never sees: no screen to put an overlay on.
    private enum SelectionOutcome {
        case selected(RegionSelection)
        case skipped
        case cancelled
        case unavailable
    }

    /// Present the crosshair overlay on the screen under the cursor; resolve
    /// with the dragged region, a skip (Work only), or a cancel. The overlay
    /// window is torn down BEFORE this returns so the dim/selection chrome is
    /// never in the shot.
    private func presentOverlay(purpose: RegionCapturePurpose) async -> SelectionOutcome {
        // Single-display v1: the overlay lives on the screen under the current
        // mouse location; the drag is confined to it.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        else { return .unavailable }

        let result: RegionOverlayResult = await withCheckedContinuation { continuation in
            let overlay = RegionOverlayWindow(screen: screen, purpose: purpose) { result in
                continuation.resume(returning: result)
            }
            overlay.present()
        }

        switch result {
        case .region(let rect):
            return .selected(RegionSelection(globalRect: rect, screen: screen))
        case .skipped:
            return .skipped
        case .cancelled:
            return .cancelled
        }
    }

    // MARK: - 3. ScreenCaptureKit capture

    /// Capture the selected region as lossless PNG bytes. The filter path
    /// (per-display `SCContentFilter` + `sourceRect`) is primary; on any throw it
    /// falls back to the global-rect `captureImage(in:)` overload. Returns `nil`
    /// on empty/zero-size capture or total failure.
    private func captureSelection(_ selection: RegionSelection) async -> Data? {
        let screen = selection.screen
        let globalRect = selection.globalRect

        // Resolve this screen's CGDirectDisplayID for SCDisplay matching + the
        // coordinate flip below.
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID

        do {
            let content = try await SCShareableContent.current

            guard let displayID,
                  let scDisplay = content.displays.first(where: { $0.displayID == displayID })
            else {
                throw RegionCaptureError.displayNotFound
            }

            // Exclude Conduck's own windows (the overlay is already gone, but a
            // settings/main window could overlap the region).
            let ownApps = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
            }
            let filter = SCContentFilter(
                display: scDisplay,
                excludingApplications: ownApps,
                exceptingWindows: []
            )

            // Coordinate mapping (THE critical bug source): the drag rect is
            // AppKit global, BOTTOM-left origin. SCK `sourceRect` wants
            // DISPLAY-LOCAL, TOP-left points. Subtract the screen origin to make
            // it display-local, then flip Y within the display height.
            let localBottomLeft = NSRect(
                x: globalRect.origin.x - screen.frame.origin.x,
                y: globalRect.origin.y - screen.frame.origin.y,
                width: globalRect.width,
                height: globalRect.height
            )
            var sourceRect = CGRect(
                x: localBottomLeft.origin.x,
                y: screen.frame.height - localBottomLeft.maxY,
                width: localBottomLeft.width,
                height: localBottomLeft.height
            )
            // Clamp to the display bounds (a drag that grazed an edge can't ask
            // SCK for pixels outside the display).
            sourceRect = sourceRect.intersection(
                CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
            )
            guard sourceRect.width >= 1, sourceRect.height >= 1 else {
                throw RegionCaptureError.emptyRegion
            }

            let config = SCStreamConfiguration()
            config.sourceRect = sourceRect
            // `pointPixelScale` is the display's points→pixels factor; fall back
            // to the screen's backing scale if SCK reports a non-positive value.
            let scale = CGFloat(filter.pointPixelScale)
            let s = scale > 0 ? scale : screen.backingScaleFactor
            config.width = Int(sourceRect.width * s)
            config.height = Int(sourceRect.height * s)
            config.showsCursor = false

            let cg = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )
            guard cg.width > 0, cg.height > 0 else {
                throw RegionCaptureError.emptyRegion
            }
            return pngData(from: cg)

        } catch {
            // Fallback: the global-rect overload. `captureImage(in:)` wants a rect
            // in GLOBAL TOP-left points — flip the AppKit global (bottom-left)
            // rect against the PRIMARY display height.
            return await captureViaGlobalRect(globalRect)
        }
    }

    /// Fallback capture via `SCScreenshotManager.captureImage(in:)`. The input is
    /// the region in GLOBAL TOP-left points (flip against the primary display
    /// height, `NSScreen.screens[0].frame.maxY`).
    private func captureViaGlobalRect(_ globalRect: NSRect) async -> Data? {
        guard let primary = NSScreen.screens.first else { return nil }
        let primaryTop = primary.frame.maxY
        let globalTopLeft = CGRect(
            x: globalRect.origin.x,
            y: primaryTop - globalRect.maxY,
            width: globalRect.width,
            height: globalRect.height
        )
        guard globalTopLeft.width >= 1, globalTopLeft.height >= 1 else { return nil }

        do {
            let cg = try await SCScreenshotManager.captureImage(in: globalTopLeft)
            guard cg.width > 0, cg.height > 0 else { return nil }
            return pngData(from: cg)
        } catch {
            return nil
        }
    }

    /// CGImage → lossless PNG `Data` (in-memory only; never touches disk).
    private func pngData(from cg: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// Internal capture-stage failures (all routed to the global-rect fallback or
    /// a nil return; never surfaced to the user).
    private enum RegionCaptureError: Error {
        case displayNotFound
        case emptyRegion
    }
}

// MARK: - Overlay window

/// The overlay's raw report. `.skipped` is produced only under
/// `RegionCapturePurpose.work`; on `.ask` the overlay has no key or action that
/// can emit it.
private enum RegionOverlayResult: Sendable {
    case region(NSRect)
    case skipped
    case cancelled
}

/// Borderless full-screen-on-one-display crosshair overlay. Dims the display,
/// "spotlights" the live selection, and reports the outcome via `onFinish`.
/// `canBecomeKey`/`canBecomeMain` are overridden so a borderless window can
/// receive keyDown for Esc (default borderless windows refuse key).
@MainActor
private final class RegionOverlayWindow: NSWindow {

    /// Called exactly once, with the drag, a skip, or a cancel.
    private let onFinish: (RegionOverlayResult) -> Void
    private var didFinish = false
    private let captureScreen: NSScreen

    init(
        screen: NSScreen,
        purpose: RegionCapturePurpose,
        onFinish: @escaping (RegionOverlayResult) -> Void
    ) {
        self.onFinish = onFinish
        self.captureScreen = screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        hasShadow = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ignoresMouseEvents = false

        let view = RegionOverlayView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            purpose: purpose
        )
        view.onComplete = { [weak self] rect in self?.finish(with: .region(rect)) }
        view.onSkip = { [weak self] in self?.finish(with: .skipped) }
        view.onCancel = { [weak self] in self?.finish(with: .cancelled) }
        contentView = view
    }

    // Borderless windows refuse key (and thus keyDown) by default → no Esc.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Show the overlay, activate Conduck, and route the cursor + first responder
    /// to the drawing view so it gets mouse + key events immediately.
    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if let view = contentView {
            makeFirstResponder(view)
        }
        NSCursor.crosshair.set()
    }

    /// Resolve exactly once: tear down the window FIRST (so the dim/selection
    /// chrome is never in the screenshot), then deliver the result.
    private func finish(with result: RegionOverlayResult) {
        guard !didFinish else { return }
        didFinish = true
        NSCursor.arrow.set()
        orderOut(nil)
        close()
        onFinish(result)
    }
}

/// The overlay's content view: owns the dim + spotlight drawing, the drag
/// gesture, and the keyboard. Reports the selected rect (in this view's
/// coordinates, then converted to global by the view) via `onComplete`, the
/// Work lane's skip via `onSkip`, or `onCancel`. Mouse handling is on the VIEW
/// itself — NO `CGEventTap` (sandbox hostile).
@MainActor
private final class RegionOverlayView: NSView {

    /// Called with the selected rect in AppKit GLOBAL (bottom-left) coordinates.
    var onComplete: ((NSRect) -> Void)?
    /// Called when the user skips the screenshot (Work lane only: Return/Enter
    /// or the "Skip screenshot" accessibility action).
    var onSkip: (() -> Void)?
    /// Called when the user cancels (Esc / too-small drag).
    var onCancel: (() -> Void)?

    /// Which lane this overlay serves. Immutable and injected, so the hint, the
    /// Return key and the skip action can never disagree about it.
    private let purpose: RegionCapturePurpose

    /// Drag anchor + current point in this view's (bottom-left) coordinates.
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    /// Below this size (points) a drag is treated as a mis-click → cancel.
    /// Cancel, not skip, on BOTH lanes: a stray click must never be read as
    /// "start recording without a screenshot".
    private static let minDragSize: CGFloat = 4

    init(frame: NSRect, purpose: RegionCapturePurpose) {
        self.purpose = purpose
        super.init(frame: frame)

        // VoiceOver reach: a borderless overlay carries no controls, so without
        // an explicit element + label there is nothing for a custom action to
        // hang on. The label is the same sentence the hint draws, so both
        // audiences are told about the same affordances.
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(hintText)

        // The skip action exists ONLY on Work. Offering it on Ask would name an
        // outcome that lane has no code path for (no pixels, no question), and
        // keyboard-free VoiceOver users would be the only ones who could reach
        // it.
        if purpose == .work {
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(
                    name: String(localized: LocalizedStringResource(
                        "regionCapture.overlay.skipAction",
                        defaultValue: "Skip screenshot"
                    ))
                ) { [weak self] in
                    // AppKit is main-actor annotated wholesale, so this handler
                    // is already `@MainActor` — no hop, and the skip resolves
                    // inside this event rather than a turn later. `true` tells
                    // the accessibility client the action ran.
                    self?.onSkip?()
                    return true
                }
            ])
        }
    }

    required init?(coder: NSCoder) {
        fatalError("RegionOverlayView is code-only; it has no nib representation.")
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false } // AppKit bottom-left, matches NSScreen.

    // The crosshair should persist over the whole overlay.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Dim the whole display ~0.25 black.
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        let hint = currentSelectionRect()
        if let rect = hint, rect.width > 0, rect.height > 0 {
            // Spotlight: punch the dim back out inside the live selection so the
            // user sees what they're about to capture. `.clear` compositing on the
            // NSRect erases the dim already drawn there back to the clear window
            // backing; a faint white wash keeps the region readable, plus a crisp
            // 1px white border.
            rect.fill(using: .clear)
            NSColor.white.withAlphaComponent(0.06).setFill()
            rect.fill()

            NSColor.white.setStroke()
            let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }

        drawHintLabel()
    }

    /// The overlay's one-line instruction, and the view's accessibility label.
    /// Each lane gets its OWN catalog key rather than a runtime-assembled
    /// string: the sentences differ in more than one clause, and a translator
    /// handed a half-string cannot punctuate a list they can't see.
    private var hintText: String {
        switch purpose {
        case .ask:
            return String(localized: LocalizedStringResource(
                "regionCapture.overlay.hint",
                defaultValue: "Drag to capture · Esc to cancel"
            ))
        case .work:
            return String(localized: LocalizedStringResource(
                "regionCapture.overlay.hint.work",
                defaultValue: "Drag to capture · Return to skip · Esc to cancel"
            ))
        }
    }

    /// Centered single-line hint. Drawn via `NSAttributedString` so it needs no
    /// subview lifecycle.
    private func drawHintLabel() {
        let text = hintText
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let size = attributed.size()
        let padding = NSSize(width: 18, height: 10)
        let boxSize = NSSize(width: size.width + padding.width * 2,
                             height: size.height + padding.height * 2)
        let boxOrigin = NSPoint(
            x: bounds.midX - boxSize.width / 2,
            y: bounds.maxY - boxSize.height - 48 // a little down from the top
        )
        let box = NSRect(origin: boxOrigin, size: boxSize)

        NSColor.black.withAlphaComponent(0.55).setFill()
        let bg = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        bg.fill()

        let textRect = NSRect(
            x: box.minX + padding.width,
            y: box.minY + padding.height,
            width: size.width,
            height: size.height
        )
        attributed.draw(in: textRect)
    }

    /// The live selection rect (in this view's coordinates) from the drag anchor
    /// + current point, normalized so width/height are positive.
    private func currentSelectionRect() -> NSRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    // MARK: Mouse (on the view itself — no CGEventTap)

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        defer { dragStart = nil; dragCurrent = nil }

        guard let rect = currentSelectionRect() else {
            onCancel?()
            return
        }
        // A drag smaller than ~4×4 pt is a mis-click → cancel.
        guard rect.width >= Self.minDragSize, rect.height >= Self.minDragSize else {
            onCancel?()
            return
        }
        // Convert the view-local rect to AppKit GLOBAL (screen) coordinates for
        // the capture stage.
        guard let window else { onCancel?(); return }
        let windowRect = convert(rect, to: nil)              // view → window
        let globalRect = window.convertToScreen(windowRect)  // window → screen
        onComplete?(globalRect)
    }

    // MARK: Key

    /// Esc cancels on BOTH lanes — one press always gets out of an accidental
    /// hotkey. Return/Enter skips the screenshot on WORK ONLY: Ask has nothing
    /// to fall back to (the pixels are the question), so a Return there stays an
    /// unhandled key rather than a silent send with no image.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        // 36 = Return, 76 = keypad Enter. Both, because a keypad Enter that did
        // nothing would read as a frozen overlay.
        if purpose == .work, event.keyCode == 36 || event.keyCode == 76 {
            onSkip?()
            return
        }
        super.keyDown(with: event)
    }
}
#endif
