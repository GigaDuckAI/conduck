// SPDX-License-Identifier: Apache-2.0

#if os(macOS)
// Conduck
// RegionCaptureController.swift
//
// macOS region-screenshot capture for the ⌘⇧2 menu-bar hotkey ("capture a
// screen region, then ask about it"). This file owns ONLY the CAPTURE half:
//   1. preflight BOTH permissions (mic + Screen Recording) BEFORE any overlay,
//   2. a dimmed crosshair overlay window the user drags a region on,
//   3. a ScreenCaptureKit screenshot of that region → lossless PNG `Data`.
// The caller owns the recording + send half (its `ImageProcessor` normalises
// the PNG to a JPEG data-URI at send time).
//
// Single public entry: `captureRegion() async -> Data?`. Returns `nil` on
// cancel / permission-denied / empty selection. Never writes the screenshot to
// disk and never logs image bytes (in-memory PNG only).
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
// Overlay design mirrors `MenuBarController.showPopover()`'s activation
// rationale: a borderless background-app window can't become key (no keyDown
// for Esc) unless we `NSApp.activate(ignoringOtherApps:)` + override
// `canBecomeKey`/`canBecomeMain`.

import AppKit
import ScreenCaptureKit
import CoreGraphics
import AVFoundation

/// Drives the ⌘⇧2 region-capture flow: permission preflight → crosshair overlay
/// → ScreenCaptureKit screenshot. Main-actor isolated (all overlay UI) with an
/// async public method (the SCK capture hop is async).
@MainActor
final class RegionCaptureController {

    /// Full flow: preflight permissions → dimmed crosshair overlay → user drags a
    /// region → capture that region via ScreenCaptureKit. Returns PNG `Data`
    /// (lossless; the caller's `ImageProcessor` normalizes to JPEG at send time)
    /// or `nil` on cancel / permission-denied / empty.
    /// `requiresMicrophone` (default true — the voice flow) gates the mic half
    /// of the preflight: a TEXT-mode "Screenshot & Ask" types its question, so
    /// demanding mic access there would block a feature that never records.
    func captureRegion(requiresMicrophone: Bool = true) async -> Data? {
        // Re-entrancy guard: the preflight's `runModal` alerts pump a nested
        // run loop that still delivers the global hotkey, so a second ⌘⇧2
        // mid-flow would stack a second alert (or overlay) on the first.
        // MainActor isolation makes the check-and-set race-free.
        guard !captureFlowActive else { return nil }
        captureFlowActive = true
        defer { captureFlowActive = false }

        // 1. Preflight permissions before showing any overlay. Never let the
        //    user drag-then-fail.
        guard await preflightPermissions(requiresMicrophone: requiresMicrophone) else { return nil }

        // 2. Crosshair overlay → user drags a region (or cancels with Esc / a
        //    too-small drag / an outside dismiss).
        guard let selection = await presentOverlay() else { return nil }

        // 3. Capture the resolved rect via ScreenCaptureKit (overlay already
        //    torn down inside `presentOverlay`, so the dim chrome is never shot).
        return await captureSelection(selection)
    }

    /// `true` while a capture flow (preflight alert, overlay, or SCK hop) is
    /// in progress — see the re-entrancy guard in `captureRegion`.
    private var captureFlowActive = false

    // MARK: - 1. Permission preflight

    /// `true` only when the needed permissions are usable RIGHT NOW (mic checked
    /// only when `requiresMicrophone` — the text-mode flow never records).
    /// Mic uses the same authorization primitive as the voice-capture pipeline
    /// (`AudioRecorder.startRecording()` → `AVAudioApplication.requestRecordPermission()`).
    /// Screen Recording uses the `CGPreflight…`/`CGRequest…` pair behind a
    /// rationale-first alert (see header). A missing permission → `false`
    /// (caller returns nil WITHOUT showing the overlay).
    private func preflightPermissions(requiresMicrophone: Bool) async -> Bool {
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
                showMicrophonePermissionAlert()
                return false
            }
        }

        // --- Screen Recording ---
        if CGPreflightScreenCaptureAccess() {
            // Diagnostics relevance gate: the feature is live on this Mac —
            // surface the (green) Screen Recording capability row.
            UserDefaults(suiteName: Constants.appGroupID)?
                .set(true, forKey: Constants.screenRecordingCaptureAttemptedKey)
            return true
        }

        // Rationale-first (see header): our alert always precedes the system
        // ask, so the two dialogs are strictly sequential in every TCC state —
        // never simultaneous.
        guard showScreenRecordingRationale() else { return false }

        // The request call itself registers Conduck in the Screen & System
        // Audio Recording pane — only from this point may the Diagnostics row
        // send the user there (its gate written any earlier would deep-link a
        // pane with no Conduck entry). Cancelling the rationale above
        // deliberately leaves the row hidden.
        let granted = CGRequestScreenCaptureAccess()
        UserDefaults(suiteName: Constants.appGroupID)?
            .set(true, forKey: Constants.screenRecordingCaptureAttemptedKey)

        if granted {
            // Grant recorded in TCC but not adopted by THIS process — macOS
            // frequently applies it only at the next launch, so proceeding
            // would silently capture desktop-wallpaper-only pixels. Tell
            // the user to relaunch instead. (No system dialog in this state.)
            showGrantNeedsRelaunchAlert()
        } else {
            // Either the system consent dialog is now up (first request for
            // this TCC identity) or the system stayed silent (prior denial,
            // or a grant recorded under a previous code signature). Open the
            // exact Settings pane unconditionally: for a denial it IS the
            // repair; for a fresh ask it merely pre-opens the pane the
            // system dialog's own button leads to.
            openPrivacyPane("Privacy_ScreenCapture")
        }
        return false
    }

    /// Mic missing (voice-mode ⌘⇧2 only). Single-purpose, friendly alert:
    /// explains WHY, states the data flow (screenshot + your words → YOUR
    /// configured gateway), deep-links the Microphone privacy pane.
    private func showMicrophonePermissionAlert() {
        let openSettings = runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.mic.title",
                defaultValue: "Conduck needs microphone access"
            )),
            body: String(localized: LocalizedStringResource(
                "regionCapture.permission.mic.body",
                defaultValue: "Region Capture lets you select part of your screen and ask about it by voice. To record your question, Conduck needs microphone access.\n\nYour screenshot and your words are sent only to the AI gateway you configured — nowhere else."
            )),
            primaryButton: String(localized: LocalizedStringResource(
                "regionCapture.permission.openSettings",
                defaultValue: "Open System Settings"
            ))
        )
        if openSettings {
            openPrivacyPane("Privacy_Microphone")
        }
    }

    /// Rationale-first pre-prompt for Screen Recording: ALWAYS shown before
    /// `CGRequestScreenCaptureAccess()`, so Conduck's alert and the system
    /// consent dialog are strictly sequential in every TCC state (see header).
    /// `true` = the user chose Continue (consented to the system ask).
    private func showScreenRecordingRationale() -> Bool {
        runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.title",
                defaultValue: "Conduck needs Screen Recording access"
            )),
            body: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.body",
                defaultValue: "Region Capture lets you select part of your screen and ask about it. To take that screenshot, Conduck needs Screen Recording access.\n\nIf System Settings already shows Conduck as on, turn it off and on again, then quit and reopen Conduck.\n\nYour screenshot and your words are sent only to the AI gateway you configured — nowhere else."
            )),
            primaryButton: String(localized: LocalizedStringResource(
                "regionCapture.permission.continue",
                defaultValue: "Continue"
            ))
        )
    }

    /// The grant IS recorded in TCC but this process can't use it — macOS
    /// frequently adopts a Screen Recording grant only at the next launch.
    /// System Settings adds nothing in this state; the only repair is a
    /// relaunch, so the primary action is a one-click quit (manual reopen —
    /// an auto-relaunch helper is sandbox-hostile). "Quit Conduck" reuses the
    /// status-menu item's existing catalog key.
    private func showGrantNeedsRelaunchAlert() {
        let quit = runPermissionAlert(
            title: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.title",
                defaultValue: "Conduck needs Screen Recording access"
            )),
            body: String(localized: LocalizedStringResource(
                "regionCapture.permission.screen.relaunchBody",
                defaultValue: "Thanks — Screen Recording is now allowed. macOS only applies this after a restart, so please quit and reopen Conduck, then try Region Capture again.\n\nYour screenshot and your words are sent only to the AI gateway you configured — nowhere else."
            )),
            primaryButton: String(localized: "Quit Conduck")
        )
        if quit {
            NSApp.terminate(nil)
        }
    }

    /// Shared scaffold for the permission alerts: activates the app first (a
    /// modal alert from a menu-bar/background app can't reliably take focus
    /// otherwise — same rationale as `showPopover`), presents an informational
    /// alert with one primary button + Cancel. `true` = primary chosen.
    private func runPermissionAlert(title: String, body: String, primaryButton: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: primaryButton)
        alert.addButton(withTitle: String(localized: LocalizedStringResource(
            "regionCapture.permission.cancel",
            defaultValue: "Cancel"
        )))
        return alert.runModal() == .alertFirstButtonReturn
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

    /// Present the crosshair overlay on the screen under the cursor; resolve with
    /// the dragged region, or `nil` on cancel. The overlay window is torn down
    /// BEFORE this returns so the dim/selection chrome is never in the shot.
    private func presentOverlay() async -> RegionSelection? {
        // Single-display v1: the overlay lives on the screen under the current
        // mouse location; the drag is confined to it.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
        else { return nil }

        let result: NSRect? = await withCheckedContinuation { continuation in
            let overlay = RegionOverlayWindow(screen: screen) { rect in
                continuation.resume(returning: rect)
            }
            overlay.present()
        }

        guard let rect = result else { return nil }
        return RegionSelection(globalRect: rect, screen: screen)
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

/// Borderless full-screen-on-one-display crosshair overlay. Dims the display,
/// "spotlights" the live selection, and reports the final region (or cancel) via
/// `onFinish`. `canBecomeKey`/`canBecomeMain` are overridden so a borderless
/// window can receive keyDown for Esc (default borderless windows refuse key).
@MainActor
private final class RegionOverlayWindow: NSWindow {

    /// `nil` = cancelled (Esc / too-small drag / dismissed). Called exactly once.
    private let onFinish: (NSRect?) -> Void
    private var didFinish = false
    private let captureScreen: NSScreen

    init(screen: NSScreen, onFinish: @escaping (NSRect?) -> Void) {
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

        let view = RegionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.onComplete = { [weak self] rect in self?.finish(with: rect) }
        view.onCancel = { [weak self] in self?.finish(with: nil) }
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
    private func finish(with rect: NSRect?) {
        guard !didFinish else { return }
        didFinish = true
        NSCursor.arrow.set()
        orderOut(nil)
        close()
        onFinish(rect)
    }
}

/// The overlay's content view: owns the dim + spotlight drawing, the drag
/// gesture, and the Esc key. Reports the selected rect (in this view's
/// coordinates, then converted to global by the view) via `onComplete`, or
/// `onCancel`. Mouse handling is on the VIEW itself — NO `CGEventTap` (sandbox
/// hostile).
@MainActor
private final class RegionOverlayView: NSView {

    /// Called with the selected rect in AppKit GLOBAL (bottom-left) coordinates.
    var onComplete: ((NSRect) -> Void)?
    /// Called when the user cancels (Esc / too-small drag).
    var onCancel: (() -> Void)?

    /// Drag anchor + current point in this view's (bottom-left) coordinates.
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?

    /// Below this size (points) a drag is treated as a mis-click → cancel.
    private static let minDragSize: CGFloat = 4

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

    /// Centered single-line hint. Drawn via `NSAttributedString` so it needs no
    /// subview lifecycle.
    private func drawHintLabel() {
        let text = String(localized: LocalizedStringResource(
            "regionCapture.overlay.hint",
            defaultValue: "Drag to capture · Esc to cancel"
        ))
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

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}
#endif
