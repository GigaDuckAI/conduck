// SPDX-License-Identifier: Apache-2.0

// WorkboardTutorialView.swift
// Conduck
//
// Five optional, replayable Work lessons. The presentation owner retains the
// session across interruptions and decides when dismissal is acknowledged.
// This view changes only that teaching session: it never captures, sends,
// creates real projects, requests permission, or focuses the Work composer.
// Skip and Go to Work only invoke onDone. The shared setup scaffold keeps
// scrollable instruction above a pinned footer and top-anchors every heading.

import SwiftUI
#if os(macOS)
import KeyboardShortcuts
#endif

struct WorkboardTutorialView: View {
    @Bindable var session: WorkboardTutorialSession
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var headingFocused: Bool
    @State private var captureRoute: CaptureRoute = .otherDevice

    var body: some View {
        ZStack {
            SetupAtmosphereBackground()
            VStack(spacing: 0) {
                chrome
                VStack(spacing: 22) {
                    introduction
                    lesson
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .onboardingStepLayout { footer }
                .environment(\.onboardingStepPlacement, .top)
                .id(session.currentStep)
                .transition(.opacity)
            }
        }
        .workboardDesktopSheetFrame(
            minWidth: 420, minHeight: 0, idealWidth: 620, idealHeight: 800,
            maxWidth: 720, maxHeight: 900
        )
        .task(id: session.currentStep) {
            headingFocused = false
            await Task.yield()
            guard !Task.isCancelled else { return }
            headingFocused = true
        }
    }

    private var chrome: some View {
        HStack(spacing: 12) {
            Button {
                changeStep { session.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .pointerIconButton(size: 44, shape: .circle)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workdesk.tour.back", defaultValue: "Previous step"
            )))
            .disabled(session.currentStep == 0)
            .opacity(session.currentStep == 0 ? 0 : 1)
            .accessibilityHidden(session.currentStep == 0)

            Spacer(minLength: 0)
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    ForEach(0..<5) { index in
                        Capsule()
                            .fill(index <= session.currentStep ? AppColors.brandAmber : AppColors.border)
                            .frame(width: 18, height: 3)
                    }
                }
                .accessibilityHidden(true)
                Text(LocalizedStringResource(
                    "workdesk.tour.progress", defaultValue: "\(session.currentStep + 1) of 5"
                ))
                .font(.caption)
                .foregroundStyle(AppColors.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringResource(
                "workdesk.tour.progress.accessibility", defaultValue: "Step \(session.currentStep + 1) of 5"
            )))
            Spacer(minLength: 0)

            Button(action: onDone) {
                Text(LocalizedStringResource("workdesk.tour.skip", defaultValue: "Skip tour"))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.vertical, 10)
            }
            .inlineLinkButton()
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
    }

    private var introduction: some View {
        VStack(spacing: 12) {
            Text(title)
                .onboardingScaledFont(.title, weight: .bold)
                .foregroundStyle(AppColors.textEmphasis)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($headingFocused)
            Text(subtitle)
                .onboardingScaledFont(.subheadline)
                .foregroundStyle(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var lesson: some View {
        switch session.currentStep {
        case 0:
            mascot
            WorkboardTourCaptureExample()
            principle(.init("workdesk.tour.collect.boundary", defaultValue: "Adding to Work doesn’t send it to your AI."))
            explanation(.init("workdesk.tour.collect.voice", defaultValue: "Spoken notes become editable text using your chosen speech provider."))
        case 1:
            captureLesson
        case 2:
            WorkboardTourProjectExample(stage: $session.projectStage)
            explanation(.init("workdesk.tour.project.arrange", defaultValue: "Hold one card over another to create a project, or use Select. Open the folder to work with its materials."))
            disclosure(.init("workdesk.tour.project.more", defaultValue: "How projects keep materials")) {
                explanation(.init("workdesk.tour.project.locations", defaultValue: "Home holds loose materials and project folders. Filing moves a material into its project. New captures inside that project land there too."))
                explanation(.init("workdesk.tour.project.layouts", defaultValue: "Arrange cards freely on the Desk, or use Tiles and List for an ordered view."))
                explanation(.init("workdesk.tour.project.shared", defaultValue: "Add to another project keeps both appearances, with shared edits. Moving replaces only the location you move from."))
            }
        case 3:
            WorkboardTourRequestExample(includesResearch: $session.includesResearch, reviewsRequest: $session.reviewsRequest)
            principle(.init("workdesk.tour.request.boundary", defaultValue: "Review first. Only Send to your chosen AI starts the conversation."))
            disclosure(.init("workdesk.tour.request.more", defaultValue: "What does a conversation need?")) {
                explanation(.init("workdesk.tour.request.context", defaultValue: "Project context is reusable background. The task is what you want this time. You can also start with a task alone."))
                explanation(.init("workdesk.tour.request.unconfigured", defaultValue: "You can collect and organize before connecting an AI. When you’re ready to send, connect yours in Settings → Personal AI."))
            }
        default:
            mascot
            WorkboardTourContinueExample()
            explanation(.init("workdesk.tour.continue.snapshot", defaultValue: "Starting a conversation keeps the materials you reviewed. Later edits don’t change its earlier messages."))
            disclosure(.init("workdesk.tour.continue.files.title", defaultValue: "About returned files")) {
                explanation(.init("workdesk.tour.continue.files.body", defaultValue: "Returned attachments can join their project. A file still on its gateway may need downloading and adding to Work before you can reuse it."))
            }
        }
    }

    private var mascot: some View {
        Image("conduck-work-guide")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .onboardingMascot(hero: true, scale: session.currentStep == 4 ? 0.75 : 1)
            .accessibilityHidden(true)
    }

    private var footer: some View {
        Button {
            if session.currentStep == 4 {
                onDone()
            } else {
                changeStep { session.advance() }
            }
        } label: {
            Text(session.currentStep == 4
                 ? LocalizedStringResource("workdesk.tour.done", defaultValue: "Go to Work")
                 : LocalizedStringResource("workdesk.tour.next", defaultValue: "Next"))
                .onboardingScaledFont(.headline)
                .foregroundStyle(AppColors.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14))
        }
        .primaryCTAButton()
        .keyboardShortcut(.defaultAction)
        .padding(.horizontal, Constants.Layout.horizontalPadding)
        .accessibilityIdentifier("workboard-tour-next")
    }

    private func changeStep(_ update: () -> Void) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18), update)
    }

    private var title: LocalizedStringResource {
        switch session.currentStep {
        case 0: .init("workdesk.tour.collect.title", defaultValue: "A home for your next idea")
        case 1: .init("workdesk.tour.capture.title", defaultValue: "Catch it where you find it")
        case 2: .init("workdesk.tour.project.title", defaultValue: "Give related ideas a project")
        case 3: .init("workdesk.tour.request.title", defaultValue: "Give your AI the right context")
        default: .init("workdesk.tour.continue.title", defaultValue: "Keep the work moving")
        }
    }

    private var subtitle: LocalizedStringResource {
        switch session.currentStep {
        case 0: .init("workdesk.tour.collect.subtitle", defaultValue: "Collect thoughts, pictures, links and files. Decide what to do with them when you’re ready.")
        case 1: .init("workdesk.tour.capture.subtitle", defaultValue: "Save something to Work while you’re in another app. It will be waiting on Home.")
        case 2: .init("workdesk.tour.project.subtitle", defaultValue: "Gather a few materials in a folder. Open it to see everything for that project.")
        case 3: .init("workdesk.tour.request.subtitle", defaultValue: "Open a project and choose New conversation. Add a task and the materials you choose.")
        default: .init("workdesk.tour.continue.subtitle", defaultValue: "Continue a conversation, or use selected materials to start a new task.")
        }
    }

    // MARK: - Platform-first capture

    private var captureLesson: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkboardTourCard(title: CaptureRoute.current.title) {
                captureInstructions(for: .current)
            }
            disclosure(.init("workdesk.tour.capture.more", defaultValue: "More ways to add")) {
                Picker(selection: $captureRoute) {
                    ForEach(CaptureRoute.allCases) { route in
                        Text(route.title).tag(route)
                    }
                } label: {
                    Text(LocalizedStringResource("workdesk.tour.capture.route", defaultValue: "Capture route"))
                }
                .pickerStyle(.menu)
                .tint(AppColors.textPrimary)
                captureInstructions(for: captureRoute)
                explanation(.init("workdesk.tour.capture.chat", defaultValue: "From a chat, choose Save message to Work on a useful message."))
                explanation(.init("workdesk.tour.capture.audio", defaultValue: "For audio files, use the attachment button or drag-and-drop inside Work."))
            }
            explanation(.init("workdesk.tour.capture.sync", defaultValue: "With content sync on, your desk follows you through your private iCloud. Very large files stay on their capture device."))
        }
    }

    @ViewBuilder private func captureInstructions(for route: CaptureRoute) -> some View {
        switch route {
        case .mac:
            routeStep(1, title: .init("workdesk.tour.capture.mac.menu", defaultValue: "Choose Capture to Work…"), detail: .init("workdesk.tour.capture.mac.menu.detail", defaultValue: "Right-click the menu-bar duck, or use your Work shortcut."))
            routeStep(2, title: .init("workdesk.tour.capture.mac.region", defaultValue: "Choose a screen region, if useful"), detail: .init("workdesk.tour.capture.mac.region.detail", defaultValue: "Press Return to skip the screenshot."))
            routeStep(3, title: .init("workdesk.tour.capture.mac.save", defaultValue: "Speak or type your thought"), detail: .init("workdesk.tour.capture.mac.save.detail", defaultValue: "For voice, click the menu-bar duck or press your Work shortcut again to save. For text, choose Add to Work."))
            #if os(macOS)
            if let shortcut = KeyboardShortcuts.getShortcut(for: .captureToWork) {
                Text(LocalizedStringResource("workdesk.tour.capture.mac.shortcut", defaultValue: "Your Work shortcut: \(shortcut.description)"))
                    .onboardingScaledFont(.subheadline, weight: .medium)
                    .foregroundStyle(AppColors.brandAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            #endif
        case .phone:
            routeStep(1, title: .init("workdesk.tour.capture.phone.share", defaultValue: "Open Share in another app"), detail: .init("workdesk.tour.capture.phone.share.detail", defaultValue: "A webpage, photo, screenshot, file or selected text."))
            routeStep(2, title: .init("workdesk.tour.capture.phone.conduck", defaultValue: "Choose Conduck"), detail: .init("workdesk.tour.capture.phone.conduck.detail", defaultValue: "Add a note if you’d like."))
            routeStep(3, title: .init("workdesk.tour.capture.phone.save", defaultValue: "Tap Add to Work"), detail: .init("workdesk.tour.capture.phone.save.detail", defaultValue: "Save it for later, without starting a conversation."))
            WorkboardTourShareExample()
            disclosure(.init("workdesk.tour.capture.phone.missing", defaultValue: "Can’t see Conduck in Share?")) {
                explanation(.init("workdesk.tour.capture.phone.missing.detail", defaultValue: "Swipe along the app row and choose More. Find Conduck there, or use Edit to add it to your favorites."))
            }
        case .watch:
            explanation(.init("workdesk.tour.capture.watch", defaultValue: "Open Conduck on Apple Watch → Ask → Add to Work. Speak your note, then tap to stop. Your paired iPhone receives it for Work."))
        case .car:
            explanation(.init("workdesk.tour.capture.car", defaultValue: "In CarPlay, tap the AI name to open the destination chooser, then choose Add to Work. Without a connected AI, Add to Work is on the main screen. Record one note and organize it later on iPhone, iPad or Mac."))
        case .shortcuts:
            explanation(.init("workdesk.tour.capture.shortcuts", defaultValue: "In Shortcuts, use Add to Work for text, Add Files to Work for files, or Record a Note to Work to open the recorder. You can include these actions in your own shortcuts and run them with Siri."))
        }
    }

    private func routeStep(_ number: Int, title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number, format: .number)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppColors.brandAmber)
                .frame(minWidth: 26, minHeight: 26)
                .background(AppColors.textPrimary.opacity(0.06), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .onboardingScaledFont(.subheadline, weight: .semibold)
                    .foregroundStyle(AppColors.textPrimary)
                Text(detail)
                    .onboardingScaledFont(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func explanation(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .onboardingScaledFont(.subheadline)
            .foregroundStyle(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func principle(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .onboardingScaledFont(.subheadline, weight: .medium)
            .foregroundStyle(AppColors.textPrimary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
    }

    private func disclosure<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 14, content: content)
                .padding(.top, 10)
        } label: {
            Text(title)
                .onboardingScaledFont(.subheadline, weight: .medium)
                .foregroundStyle(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(AppColors.textSecondary)
    }

    private enum CaptureRoute: String, CaseIterable, Identifiable {
        case phone, mac, watch, car, shortcuts
        var id: String { rawValue }
        static var current: Self {
            #if os(macOS)
            .mac
            #else
            .phone
            #endif
        }
        static var otherDevice: Self { current == .mac ? .phone : .mac }
        var title: LocalizedStringResource {
            switch self {
            case .phone: .init("workdesk.tour.route.phone", defaultValue: "iPhone and iPad · Share")
            case .mac: .init("workdesk.tour.route.mac", defaultValue: "Mac · Menu bar")
            case .watch: .init("workdesk.tour.route.watch", defaultValue: "Apple Watch")
            case .car: .init("workdesk.tour.route.car", defaultValue: "CarPlay")
            case .shortcuts: .init("workdesk.tour.route.shortcuts", defaultValue: "Siri and Shortcuts")
            }
        }
    }
}

#Preview {
    WorkboardTutorialView(session: WorkboardTutorialSession(), onDone: {})
}
