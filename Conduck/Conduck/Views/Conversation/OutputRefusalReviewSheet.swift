// SPDX-License-Identifier: Apache-2.0

// Conduck
// OutputRefusalReviewSheet.swift
//
// The escape hatch behind the thread's held-back row: what this reply's output
// folder held, why Conduck did not put a one-tap download in the chat for it,
// and a way to get the file anyway.
//
// WHAT IT IS NOT, said first because everything else follows from it. This is
// not a security boundary and it must never present itself as one. The type gate
// reads a NAME and never the bytes, so it stops nothing a hostile agent would do
// — rename the payload to `.txt` and it is delivered as an ordinary chip — and
// it only ever inconveniences an honest one. What it IS is a statement of
// policy: what Conduck opens on its own, with no user involvement. A policy the
// user cannot get past is a bug, not a safeguard, so every file here has exactly
// one visible action and no path out of this sheet is a dead end.
//
// THAT IS WHY `thread.outputs.review.why.byName` IS NOT OPTIONAL COPY. Without
// the sentence saying Conduck goes by the file's NAME and not by what is inside
// it, the whole surface reads as "Conduck inspected this and is worried", which
// is false, and which turns "Save anyway" into defeating a safety system rather
// than finishing a task.
//
// IT NEVER SHOWS A SHAPE-REFUSED NAME, and that is structural rather than
// remembered: its only input is `[OutputTypeRefusal]`, a value nothing can mint
// from the validator's shape arm — `OutboxEntryVerdict.refusedShape` carries no
// name to mint one from. A hostile or unusable name has no name-bearing surface
// anywhere in this app; its entire presentation is a count on the row.
//
// SAVING NEVER PREVIEWS. The bytes go to the system save browser (iOS) or the
// save panel (macOS), and nothing in this file touches `FilePreviewCoordinator`,
// `previewURL` or `.quickLookPreview` — handing a type the app declined to open
// straight to Quick Look in the last three lines of the flow would undo the
// feature silently. Nor does it write a preview into the store the way a chip
// download does: there is no `AttachmentRecord` to patch, and a thumbnail of
// bytes the app declined to open has no business in a synced, iCloud-replicated
// record.
//
// THE VERB STAYS "SAVE", ALWAYS. No Install, no "Open in Settings", no deep link
// that shortens the path between a saved file and an installed one. App Store
// review guideline 2.5.3 reads on handing a user a file that can change their
// operating system, and the three facts that make Conduck's position defensible
// are that the bytes come from a server the USER configured, that the transfer
// is user-initiated twice (a row they tap, then a button they tap), and that
// Conduck never opens the file. All three are properties of this file.
//
// PRIVACY: never logs filenames, storedKeys, URLs, destinations or credentials.

import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - The view-facing refusal

/// One entry a reply's output folder held that Conduck will not open on its own,
/// in the shape the row and this sheet render.
///
/// SAFE TO DISPLAY, and the licence is structural rather than a judgement call.
/// The extension test is the LAST guard in `FileServerClient.outboxEntryVerdict`,
/// so a name that reaches it has already cleared the single-path-component test,
/// the accept-list of Unicode categories, the leading-dot / leading-dash /
/// leading-combining-mark / surrounding-whitespace tests and both length
/// budgets. A name here is therefore exactly as displayable as a delivered
/// chip's label — the same name, past the same guards, one test further on.
///
/// There is deliberately no initializer reachable from a SHAPE refusal. Making
/// that unrepresentable is cheaper than remembering it at every call site.
struct OutputTypeRefusal: Identifiable, Equatable, Sendable {
    /// The server's own entry name, verbatim — never repaired, never trimmed. A
    /// cleaned name addresses a file that does not exist.
    let name: String
    /// `<outputBoxKey>/<name>` — the GET target "Save anyway" spends. REBUILT
    /// here rather than stored on the record: the record already carries the
    /// folder, and one key kept in two places is one more pair of values that
    /// can drift apart.
    let storedKey: String
    /// From the listing's `getcontentlength`. 0 means the server omitted it,
    /// matching `AttachmentRecord.byteSize` so the size caption and the
    /// large-download soft-confirm read it exactly the way a chip does.
    let byteSize: Int
    /// Why the type gate refused it. Two shapes, because they are two different
    /// sentences to the user and the second one has no type to name.
    let reason: Reason

    enum Reason: Equatable, Sendable {
        /// Lowercased and already proven ASCII-alphanumeric by
        /// `FileServerClient.outboxEntryVerdict`, which is what makes it safe to
        /// interpolate into the app's own prose.
        case unopenedExtension(String)
        /// No dot, an empty tail, or a tail this app cannot read as a type.
        /// UNKNOWN TYPE, never "no type" — nothing may assert what the file is.
        case noReadableExtension
    }

    /// `storedKey` and not `name`: the listing lane already refuses a folder
    /// with duplicate names, but the key is the value that is unique by
    /// construction and it is the one a `ForEach` must not collide on.
    var id: String { storedKey }

    /// Whether this file belongs to the class where the gap between "I opened
    /// it" and "my device changed" is smallest — a configuration profile, an
    /// installer, a package, a credential store, a script the system runs rather
    /// than displays.
    ///
    /// THE DETECTOR OWNS THE SET, not this view and not the validator. A literal
    /// inside a `View` cannot be unit-tested and drifts silently; the validator
    /// stays ignorant of the question entirely and merely carries the extension
    /// out. One direction of dependency, one testable list.
    var isConfigurationOrInstaller: Bool {
        guard case .unopenedExtension(let ext) = reason else { return false }
        return FileTransferOutputDetector.configurationInstallerExtensions.contains(ext)
    }

    /// Whether this file is an Office document, template or add-in whose ending
    /// permits an embedded macro.
    ///
    /// A SEPARATE QUESTION FROM THE ONE ABOVE, because it earns a separate
    /// sentence. A macro-enabled document IS meant to be read — the claim the
    /// class above makes about the file that triggered it is the one thing that
    /// is not true here — and its actual risk, code saved inside the file, is
    /// something that class's warning never mentions. Two predicates, two blocks,
    /// each sentence provable of every member of its own set.
    var isMacroEnabledDocument: Bool {
        guard case .unopenedExtension(let ext) = reason else { return false }
        return FileTransferOutputDetector.macroEnabledDocumentExtensions.contains(ext)
    }

    /// Project a turn's PERSISTED census into the entries a rescue can actually
    /// be offered for.
    ///
    /// RE-RUN THROUGH THE VALIDATOR rather than trusted from the record, and the
    /// reason is the allowlist itself: it is the one input here that can move
    /// between the pass that wrote the census and the render that reads it. A
    /// name that has since become deliverable must not be offered as a refusal,
    /// and the verdict is the single place that decision lives — so this asks it
    /// again instead of encoding a second copy of the answer.
    ///
    /// Empty for a turn with no folder. `<outputBoxKey>/<name>` is the only way
    /// back to the bytes, so a census with no folder describes files nothing
    /// could fetch.
    static func rescuableEntries(in message: MessageRecord) -> [OutputTypeRefusal] {
        guard let outcome = ConversationDetailViewModel.outputDeliveryRow(for: message),
              let outboxKey = message.outputBoxKey else { return [] }
        return outcome.typeRefusedEntries.compactMap { entry in
            switch FileServerClient.outboxEntryVerdict(entry.name) {
            case .refusedExtension(let name, let ext):
                return OutputTypeRefusal(
                    name: name,
                    storedKey: "\(outboxKey)/\(name)",
                    byteSize: entry.byteSize,
                    reason: .unopenedExtension(ext)
                )
            case .refusedUntyped(let name):
                return OutputTypeRefusal(
                    name: name,
                    storedKey: "\(outboxKey)/\(name)",
                    byteSize: entry.byteSize,
                    reason: .noReadableExtension
                )
            case .deliverable, .refusedShape:
                // `.deliverable` means the allowlist widened under a stored
                // census and the file is an ordinary chip now — the next pass
                // rewrites the census, and until then offering a rescue for a
                // file the thread is about to show would be a contradiction.
                // `.refusedShape` is unreachable (nothing shape-refused is ever
                // persisted with a name) and is dropped rather than trusted.
                return nil
            }
        }
    }
}

/// One turn's type-refused entries, held for the review sheet.
///
/// CARRIES THE LANE, not just the ids: a rescue is a GET, and a GET is only
/// legal against the exact durable lane that owns the key — the same gate
/// `ServerFileDownloadChip` reads through `expectedLaneID`. A persisted refusal
/// naming a file on a server that is no longer configured still draws its row
/// (the fact about what happened stays true) and fails closed at the save.
struct OutputRefusalReview: Identifiable, Equatable {
    let messageID: UUID
    let laneID: String?
    let entries: [OutputTypeRefusal]

    var id: UUID { messageID }

    /// Nil when this turn has nothing to review — which is the ordinary case, so
    /// the failable init is what keeps the caller from presenting an empty sheet.
    init?(message: MessageRecord) {
        let entries = OutputTypeRefusal.rescuableEntries(in: message)
        guard !entries.isEmpty else { return nil }
        self.messageID = message.id
        self.laneID = message.outputScanLaneID
        self.entries = entries
    }
}

// MARK: - The sheet

struct OutputRefusalReviewSheet: View {
    let entries: [OutputTypeRefusal]
    /// The conversation's bound gateway — resolves the file-server snapshot.
    /// Nil falls back to the Settings default ref, exactly as a chip does.
    let boundRef: RemoteAgentRef?
    /// The durable lane that owns these keys. Nil is unprovable and fails closed.
    let expectedLaneID: String?

    @Environment(\.dismiss) private var dismiss

    /// Per-entry save state, keyed by storedKey. Absent = idle.
    @State private var saveStates: [String: SaveState] = [:]
    /// The entry a large-file soft-confirm is holding, so confirming cannot come
    /// back for a different file than the one the message named.
    @State private var largeSaveCandidate: OutputTypeRefusal?
    @State private var showingLargeSaveConfirm = false
    #if os(iOS)
    /// What the export picker is PRESENTED on. SwiftUI owns this binding and
    /// nils it on a swipe-down or a tap outside without telling anyone, so it
    /// can hold the presentation and nothing else.
    @State private var exportItem: PendingExport?
    /// What the export is SETTLED from — the same value, retained across the
    /// dismissal that clears the binding above. Two properties for one value
    /// because the role that has to survive dismissal cannot be the role
    /// dismissal erases: the reclaim needs the scratch item and the row needs
    /// its key precisely at the moment `exportItem` is already gone.
    @State private var settlingExport: PendingExport?
    /// The picker's own verdict, when it got to give one. It stays false when
    /// the sheet went away without a delegate callback, which is a cancel in
    /// every respect that matters here — nothing was copied, so nothing may
    /// claim it was.
    @State private var exportDidSave = false
    #endif

    private enum SaveState: Equatable {
        case saving
        case saved
        case failed(message: String, retryable: Bool)
    }

    #if os(iOS)
    /// One adopted file waiting on the export picker. `Identifiable` so the
    /// nested sheet is item-driven, and carrying everything the settle needs —
    /// the scratch item to reclaim and, in `id`, the `saveStates` key of the
    /// row that is waiting on it.
    private struct PendingExport: Identifiable {
        /// The refused entry's `storedKey`, so the row this export belongs to
        /// is addressable from the settle without re-deriving it.
        let id: String
        let url: URL
        let scratch: AgentDownloadScratch.ScratchItem
    }
    #endif

    /// True when ANY entry is a configuration/installer type. Computed over the
    /// whole set rather than per row so the sentence is stated ONCE, at the top,
    /// where it is read before any button — repeating it under every row would
    /// make the sheet read as an alarm.
    private var hasConfigurationClass: Bool {
        entries.contains(where: \.isConfigurationOrInstaller)
    }

    /// True when ANY entry is a macro-enabled Office type. Independent of the
    /// flag above, so a folder holding both a `.pkg` and a `.docm` shows both
    /// sentences: each is true of its own file and neither is true of the other,
    /// and picking one to stand for both is how a warning ends up describing a
    /// file that is not on the sheet.
    private var hasMacroDocumentClass: Bool {
        entries.contains(where: \.isMacroEnabledDocument)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppColors.textPrimary)

                // THE POLICY, then the honesty line, in that order. The first
                // says what Conduck does; the second says what it read to decide
                // — and the second is what keeps the third block below from
                // reading as a verdict about these particular bytes.
                Text(LocalizedStringResource(
                    "thread.outputs.review.why",
                    defaultValue: "Conduck puts a one-tap download in the chat for the file types an agent usually produces — documents, images, audio, data, code. Anything else stays in the folder until you've had a look."))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(LocalizedStringResource(
                    "thread.outputs.review.why.byName",
                    defaultValue: "Conduck goes by the file's name, not by what's inside it. So this is about what your agent called the file, not a judgment about the file itself."))
                    .font(.subheadline)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if hasConfigurationClass { configurationWarning }
                if hasMacroDocumentClass { macroDocumentWarning }

                VStack(spacing: 10) {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                }

                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Text(LocalizedStringResource(
                            "attachment.fullscreen.done", defaultValue: "Done"))
                            .fontWeight(.semibold)
                            .foregroundStyle(AppColors.textPrimary)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.bordered)
                }
            }
            .padding(20)
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 400)
        #else
        .presentationDetents([.medium, .large])
        #endif
        // The SAME soft-confirm the chip applies, and reusing it is the point:
        // the listing gave a size, so skipping the gate would make the one lane
        // in the app with no large-transfer warning the one reached from a
        // warning row.
        .alert(
            LocalizedStringResource(
                "fileTransfer.download.softConfirm.title",
                defaultValue: "Download large file?"),
            isPresented: $showingLargeSaveConfirm
        ) {
            Button(LocalizedStringResource(
                "fileTransfer.download.softConfirm.download",
                defaultValue: "Download")) {
                if let entry = largeSaveCandidate { beginSave(entry) }
                largeSaveCandidate = nil
            }
            Button(
                LocalizedStringResource("fileTransfer.softConfirm.cancel", defaultValue: "Cancel"),
                role: .cancel
            ) {
                largeSaveCandidate = nil
            }
        } message: {
            Text(largeSaveMessage)
        }
        #if os(iOS)
        // Nested on THIS sheet rather than routed to the thread root: the
        // download runs while this sheet is open and reports its progress on the
        // row, so the picker has to come back to the surface the user is
        // standing in. A root presentation would have to dismiss this one first
        // and lose the row state that says which file just landed.
        .sheet(item: $exportItem) { item in
            ServerFileExportPicker(url: item.url) { saved in
                // RECORD AND DISMISS ONLY. The picker knows the one thing the
                // dismissal cannot tell us — whether bytes were copied — so
                // that is all it reports here. Reclaiming the scratch and
                // resolving the row happen in `settleExport`, which the nil
                // below drives, because a swipe-down reaches that nil without
                // reaching this closure at all.
                exportDidSave = saved
                exportItem = nil
            }
        }
        // THE SETTLE. Every way out of the picker ends with this binding going
        // non-nil → nil — Save, Cancel, swipe-down, tap-outside on iPad, and
        // any presentation style a later change might adopt — so that
        // transition, and not a delegate callback, is what the row and the
        // scratch file hang on. The same shape and the same reason as the
        // `previewURL` watcher in `ConversationThreadView`: the state heals
        // itself rather than depending on a particular exit being taken.
        //
        // NON-NIL → NIL AND ONLY THAT, matching that watcher: scene
        // backgrounding does not fire it, and `acceptsSave` already refuses a
        // second save while an export is live, so there is no non-nil → non-nil
        // hand-off to model.
        //
        // NOT `.interactiveDismissDisabled`, which is how the app's dirty-editor
        // sheets hold a user in. That answer suppresses the ONE gesture that
        // exposes the gap and leaves the state exactly as dependent on which
        // exit was taken — a later presentation change reopens the dead end,
        // and it makes the system's own save browser the one sheet in the app
        // that will not close. The state healing itself needs neither.
        .onChange(of: exportItem?.id) { previous, current in
            guard previous != nil, current == nil else { return }
            settleExport()
        }
        #endif
    }

    #if os(iOS)
    /// Finish one export, whichever way the picker went away.
    ///
    /// ONE RECLAIM PATH FOR EVERY EXIT. The picker copied (asCopy), the user
    /// cancelled, or the user swiped the sheet away; either way this device is
    /// done with the scratch copy. The 24 h age sweep is the safety net, never
    /// the plan — and the reclaim CANNOT be a `defer` around presentation the
    /// way the macOS panel's is, because `NSSavePanel.runModal()` is
    /// synchronous while the document picker is delegate-driven and
    /// asynchronous. A `defer` there would delete the file before the user
    /// picked a folder.
    ///
    /// The `guard` is what makes a second call harmless: the ledger is cleared
    /// before the work, so nothing can discard the same scratch item twice or
    /// overwrite a row that has already settled.
    ///
    /// NOT ALSO CALLED FROM `.onDisappear`, deliberately. The one exit that
    /// would need it — this whole review sheet going away while the picker is
    /// still up — is not reachable, since the picker covers the only control
    /// that closes it, and `.onDisappear` has a real hazard the watcher does
    /// not: it can fire as a presentation side effect, and a spurious one here
    /// would delete the scratch file out from under a live picker and destroy
    /// the save it was opened to perform. An unreachable path may fall to the
    /// age sweep; a reachable one may not be endangered to cover it.
    private func settleExport() {
        guard let export = settlingExport else { return }
        settlingExport = nil
        let saved = exportDidSave
        exportDidSave = false
        Task { await AgentDownloadScratch.shared.discard(export.scratch) }
        // A cancel is not a failure: the row goes back to offering the save,
        // exactly as the macOS panel's cancel arm does. A dismissal with no
        // delegate callback lands here too, and it lands as a cancel — the
        // sheet may only say "Saved" about a copy it watched happen.
        saveStates[export.id] = saved ? .saved : nil
    }
    #endif

    /// Singular and plural are separate KEYS rather than one inflected string:
    /// the words differ ("this file" / "these files"), not just a number, and
    /// there is no number in either.
    private var title: LocalizedStringResource {
        entries.count == 1
            ? LocalizedStringResource(
                "thread.outputs.review.title.one",
                defaultValue: "About this file")
            : LocalizedStringResource(
                "thread.outputs.review.title.many",
                defaultValue: "About these files")
    }

    // MARK: - The louder warnings

    // ONE BLOCK PER CLASS, AND THE SENTENCE MUST BE TRUE OF THE FILE THAT DREW
    // IT. Both blocks below share a register and a card; what they must never
    // share is a claim. A single warning covering every refused type the app
    // thinks is risky has to generalise until it describes none of them — one
    // block for both classes gives a `.docm` a sentence about profiles
    // rewriting Wi-Fi — and a warning a user can see does not fit their file is
    // one they learn to skip, including on the `.mobileconfig` where every word
    // of it is exact.
    //
    // THEY WARN, THEY DO NOT BLOCK, and that distinction is the whole design. A
    // confirmation stacked on top of a gate that reads only the filename buys
    // no safety — the hostile case renames to `.txt` and never arrives here at
    // all — and it costs the escape hatch its reason to exist.
    //
    // MECHANISM, MOMENT, CONDITION in both: what the format can do, WHEN the
    // consequence lands (opening, never saving), and a test the user can answer
    // from memory of their own last message. The words "malicious" and "trust
    // the source" appear in neither — the first is a verdict Conduck cannot
    // reach, the second an insinuation about the user's own agent.

    /// The louder sentence for the class of file where the gap between "I opened
    /// it" and "my device changed" is smallest: profiles, certificates,
    /// installers, packages, credential stores, and the documents whose whole
    /// purpose is to launch something.
    ///
    /// IT SAYS "A DEVICE", NOT "YOUR DEVICE", and that word is load-bearing. The
    /// class deliberately spans platforms Conduck does not run on — `.msi`,
    /// `.deb`, `.rpm`, `.apk`, `.exe`, `.reg`, `.desktop` — because the file the
    /// user saves is a file they can forward, sync or open on another machine.
    /// "Your device" is FALSE for every one of those on iOS and macOS, and a
    /// warning a user can personally disprove is a warning they learn to skip,
    /// including on the `.mobileconfig` where it is exactly true. What IS true of
    /// every member is what the format is FOR: configuring, installing or running
    /// something, rather than being read.
    private var configurationWarning: some View {
        warningCard(title: LocalizedStringResource(
            "thread.outputs.review.installer.title.v2",
            defaultValue: "This kind of file can change a device")) {
            warningBullet(LocalizedStringResource(
                "thread.outputs.review.installer.what.v2",
                defaultValue: "Files like this are meant to configure, install, or run something rather than to be read. A profile or certificate changes settings like Wi-Fi, VPN and trust; an installer or program puts software on a machine."))
            warningBullet(LocalizedStringResource(
                "thread.outputs.review.installer.when.v2",
                defaultValue: "Saving it changes nothing. Opening it later — here, or wherever you move it — is the step that does."))
            warningBullet(LocalizedStringResource(
                "thread.outputs.review.installer.trust",
                defaultValue: "Open it only if you asked for it and you know what it sets up."))
        }
    }

    /// The sentence for macro-enabled Office types, which are documents — the one
    /// thing the block above cannot say about the file that triggered it.
    ///
    /// IT CLAIMS PERMISSION, NOT PRESENCE. Conduck read a filename and never a
    /// byte, so the tail proves only that a macro is ALLOWED in this file; a
    /// `.docm` an agent produced from a template usually holds none. Claiming
    /// there is code in the file would be the same defect in the other
    /// direction — a sentence the app cannot prove from what it observed.
    ///
    /// AND IT DOES NOT CLAIM THE CODE RUNS BY ITSELF. Whether a macro executes
    /// belongs to whatever app opens the file and to that app's own macro
    /// settings, neither of which Conduck can see, so the moment is located at
    /// "opening it in an app that runs macros" rather than at opening in general.
    /// No device claim appears at all: the risk here travels with the file, not
    /// with the machine it lands on.
    private var macroDocumentWarning: some View {
        warningCard(title: LocalizedStringResource(
            "thread.outputs.review.macro.title",
            defaultValue: "This kind of file can run code when it's opened")) {
            warningBullet(LocalizedStringResource(
                "thread.outputs.review.macro.what",
                defaultValue: "These file endings mark Word, Excel and PowerPoint files that are allowed to hold macros — small programs saved inside the file itself. The ending says a macro is allowed, not that there is one."))
            warningBullet(LocalizedStringResource(
                "thread.outputs.review.macro.when",
                defaultValue: "Saving it changes nothing. Opening it in an app that runs macros — Word, Excel or PowerPoint — is the step that can run one."))
            warningBullet(LocalizedStringResource(
                "thread.outputs.review.macro.trust",
                defaultValue: "Open it only if you asked for it and a macro is something you'd expect in it."))
        }
    }

    /// The shared card. ONE chrome for every warning class, so a second sentence
    /// reads as a second fact about a second file rather than as an escalation —
    /// a distinct tint or glyph per class would invent a severity ordering the
    /// app has no basis for. The glyph is `accessibilityHidden`, so it carries
    /// nothing a VoiceOver user would lose to the sameness.
    private func warningCard<Bullets: View>(
        title: LocalizedStringResource,
        @ViewBuilder bullets: () -> Bullets
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.shield")
                .font(.subheadline)
                .foregroundStyle(AppColors.warning)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppColors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                bullets()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.warning.opacity(0.35), lineWidth: 1)
        )
    }

    /// Hanging-indented bullet: each sentence wraps under its own text rather
    /// than under the glyph, and each combines into ONE accessibility element so
    /// VoiceOver reads a sentence instead of a bullet character.
    private func warningBullet(_ text: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(verbatim: "•")
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.footnote)
        .foregroundStyle(AppColors.textSecondary)
        .accessibilityElement(children: .combine)
    }

    // MARK: - One entry

    /// One refused entry: the name, the reason in plain words, the size, and the
    /// one action. A SHEET ROW, not a chip — full width, no type-tinted file
    /// glyph, and the verb spelled out, because this whole surface exists to
    /// make the difference between "Conduck opens this" and "you open this"
    /// legible.
    @ViewBuilder
    private func entryRow(_ entry: OutputTypeRefusal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.name)
                .font(.callout.weight(.medium))
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
                // MIDDLE, not tail: the extension is the subject of the reason
                // line directly under it, and tail truncation eats it first.
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
                // A bare filename read out of nowhere gives a VoiceOver user no
                // idea what kind of element they are on — the noun comes first,
                // matching the shipped "File %@, unavailable here".
                .accessibilityLabel(Text(String(
                    format: String(localized: LocalizedStringResource(
                        "thread.outputs.review.file.a11y",
                        defaultValue: "File %@")),
                    entry.name)))

            Text(reasonText(entry))
                .font(.caption)
                .foregroundStyle(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            // A WebDAV listing may carry no `getcontentlength`, and a silent gap
            // in a panel whose whole purpose is "here is what I know about this
            // file" reads as a rendering bug rather than as an absence.
            Text(entry.byteSize > 0
                ? AttachmentChipStyle.formattedSize(entry.byteSize)
                : String(localized: LocalizedStringResource(
                    "thread.outputs.review.size.unknown", defaultValue: "Size unknown")))
                .font(.caption2)
                .foregroundStyle(AppColors.textTertiary)

            switch saveStates[entry.id] {
            case .saving:
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(AppColors.textTertiary)
                    Text(LocalizedStringResource(
                        "thread.outputs.review.saving", defaultValue: "Downloading…"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.textTertiary)
                }
            case .saved:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text(LocalizedStringResource(
                        "thread.outputs.review.saved", defaultValue: "Saved"))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppColors.success)
            case .failed(let message, let retryable):
                // CAUSE AND REMEDY, never the cause alone: `descriptionWithRecovery`
                // is what carries the interception warning on a pin mismatch,
                // which lives ENTIRELY in the remedy half. No line cap, because
                // the half that clips first is the remedy.
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppColors.error)
                    .fixedSize(horizontal: false, vertical: true)
                // A TERMINAL refusal keeps its explanation and loses only the
                // button that could never have honoured it — re-firing into the
                // identical answer buries the one sentence that mattered.
                if retryable { saveButton(entry) }
            case nil:
                saveButton(entry)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppColors.cardBackgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppColors.borderSubtle, lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
    }

    private func saveButton(_ entry: OutputTypeRefusal) -> some View {
        Button { save(entry) } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                Text(saveTitle)
            }
            .font(.caption.weight(.semibold))
            // AMBER, not red. Nothing failed and nothing is being forced: this
            // is the ordinary way to get a file the app declined to open, and a
            // destructive tint would read as a warning the sheet has already
            // given in full above.
            .foregroundStyle(AppColors.brandAmber)
        }
        .inlineLinkButton()
        // "anyway" is the whole point of this control, and a VoiceOver user who
        // hears only "Save file report" has lost the fact that they are stepping
        // past a default.
        .accessibilityLabel(Text(String(
            format: String(localized: LocalizedStringResource(
                "thread.outputs.review.save.a11y", defaultValue: "Save %@ anyway")),
            entry.name)))
    }

    /// Platform-correct casing, and TWO KEYS rather than one. macOS title-cases
    /// button verbs and iOS sentence-cases them, and two source strings that
    /// differ only by casing collide into a single symbol during catalog
    /// extraction — so the split has to be in the keys, not in the values.
    private var saveTitle: LocalizedStringResource {
        #if os(macOS)
        LocalizedStringResource("thread.outputs.review.save.mac", defaultValue: "Save Anyway…")
        #else
        LocalizedStringResource("thread.outputs.review.save", defaultValue: "Save anyway…")
        #endif
    }

    /// The reason, in the user's words. Two shapes, because "Conduck doesn't
    /// open .mobileconfig files" and "Conduck can't tell what kind of file this
    /// is" are different facts and the second has no type to name.
    ///
    /// THE EXTENSION IS INTERPOLATED, and it is safe to: `outboxEntryExtension`
    /// proves the tail is ASCII alphanumeric before the allowlist is consulted,
    /// so nothing that reaches this line can carry a control character, a bidi
    /// override or a path separator into the app's own prose.
    private func reasonText(_ entry: OutputTypeRefusal) -> String {
        switch entry.reason {
        case .unopenedExtension(let ext):
            return String(
                format: String(localized: LocalizedStringResource(
                    "thread.outputs.review.reason.type",
                    defaultValue: "Conduck doesn't open .%@ files on its own.")),
                ext)
        case .noReadableExtension:
            return String(localized: LocalizedStringResource(
                "thread.outputs.review.reason.noType",
                defaultValue: "This file's name doesn't say what kind of file it is, so Conduck can't tell what it would be opening."))
        }
    }

    // MARK: - Save

    /// Button action. A KNOWN very-large size goes through the same soft-confirm
    /// the chip applies; an unknown size (`byteSize == 0`) never reaches the gate
    /// and saves immediately, exactly as a chip does.
    private func save(_ entry: OutputTypeRefusal) {
        guard acceptsSave(entry) else { return }
        if entry.byteSize > Constants.fileTransferSoftConfirmBytes {
            largeSaveCandidate = entry
            showingLargeSaveConfirm = true
        } else {
            beginSave(entry)
        }
    }

    /// The SINGLE gate every entry point reads. A save already in flight must not
    /// stack, and on iOS a second save while a picker is up would have to replace
    /// a live `exportItem` — which would strand the first item's scratch
    /// directory. Refusing the second tap cannot leak; modelling the race can.
    private func acceptsSave(_ entry: OutputTypeRefusal) -> Bool {
        #if os(iOS)
        // BOTH, not just the presentation. `settlingExport` outlives
        // `exportItem` by the span between the dismissal and the settle, and a
        // save admitted inside that span would overwrite the ledger and strand
        // the scratch directory it was still holding.
        guard exportItem == nil, settlingExport == nil else { return false }
        #endif
        switch saveStates[entry.id] {
        case .saving: return false
        case .failed(_, let retryable): return retryable
        case .saved, nil: return true
        }
    }

    private var largeSaveMessage: String {
        guard let entry = largeSaveCandidate else { return "" }
        return String(
            format: String(localized: LocalizedStringResource(
                "fileTransfer.download.softConfirm.message",
                defaultValue: "%1$@ is %2$@ in size. Large files can take a while to download.")),
            entry.name,
            AttachmentChipStyle.formattedSize(entry.byteSize))
    }

    /// Download the bytes and hand them to the system SAVE flow.
    ///
    /// The guard sequence is `ServerFileDownloadChip.beginDownload`'s, minus the
    /// two steps that must not apply here: no preview claim is minted (there is
    /// no panel to win) and no preview patch is written to the store (there is
    /// no attachment row to patch, and a preview of bytes the app declined to
    /// open has no business in a synced record).
    private func beginSave(_ entry: OutputTypeRefusal) {
        saveStates[entry.id] = .saving
        Task {
            // `??` with an `await` RHS is rejected (the operator's autoclosure
            // isn't async) — resolve the ref with an explicit if-let instead.
            let ref: RemoteAgentRef
            if let boundRef {
                ref = boundRef
            } else {
                ref = await SettingsManager.shared.defaultRemoteAgentRef()
            }
            let snapshot = await SettingsManager.shared.fileTransferSnapshot(for: ref)
            // MANDATORY, and the same gate a chip reads: a GET is only legal
            // against the exact durable lane that owns the key. A refusal
            // recorded before the user repointed their file server fails closed
            // here rather than fetching from a stranger's namespace.
            guard FileTransferLaneOwnership.canAccessExistingBlob(
                    expectedLaneID: expectedLaneID,
                    snapshot: snapshot
                  ),
                  let snapshot else {
                present(AppError.fileTransferNotConfigured, for: entry)
                return
            }
            do {
                let tempURL = try await BackgroundFileTransfer.shared.downloadFile(
                    snapshot: snapshot,
                    storedKey: entry.storedKey)
                #if os(macOS)
                await presentSavePanel(tempURL: tempURL, entry: entry)
                #else
                // Adopted so the export picker names the file the way the server
                // did — the raw download temp is a bare UUID with no extension,
                // and the picker exports the name it is handed. `mimeType: nil`
                // deliberately: an entry that never became an attachment has no
                // recorded MIME, and a name with no readable extension must
                // export bare rather than acquire an invented tail.
                let item = try await AgentDownloadScratch.shared.adopt(
                    tempURL, preferredName: entry.name, mimeType: nil)
                let export = PendingExport(id: entry.id, url: item.url, scratch: item)
                // The settle ledger is armed BEFORE the presentation, and the
                // verdict is reset with it. Arming after would leave a window
                // where a dismissal has nothing to reclaim from, and a stale
                // `true` would let a swiped-away picker inherit the previous
                // export's "Saved".
                settlingExport = export
                exportDidSave = false
                exportItem = export
                #endif
            } catch let error as AppError {
                present(error, for: entry)
            } catch {
                // No `AppError` behind it (an adoption failure, a non-taxonomy
                // throw) — unknown is not terminal, so the row stays tappable.
                saveStates[entry.id] = .failed(
                    message: String(localized: LocalizedStringResource(
                        "fileTransfer.download.failed",
                        defaultValue: "Couldn't download the file.")),
                    retryable: true)
            }
        }
    }

    /// Cause AND remedy, and a retry only where the taxonomy allows one.
    @MainActor
    private func present(_ error: AppError, for entry: OutputTypeRefusal) {
        let message = error.descriptionWithRecovery(for: boundRef)
        saveStates[entry.id] = .failed(
            message: message.isEmpty
                ? String(localized: LocalizedStringResource(
                    "fileTransfer.download.failed",
                    defaultValue: "Couldn't download the file."))
                : message,
            retryable: error.isRetryable)
    }

    #if os(macOS)
    /// The shipped save-panel path, reused verbatim: the `defer` reclaims the
    /// temp on every exit, the byte copy hops to a detached task (a cross-volume
    /// copy of a large file beachballs the main thread), and an existing file is
    /// replaced ATOMICALLY rather than deleted first.
    @MainActor
    private func presentSavePanel(tempURL: URL, entry: OutputTypeRefusal) async {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let destination = panel.url else {
            saveStates[entry.id] = nil   // user cancelled — not a failure
            return
        }
        do {
            try await Task.detached {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
                } else {
                    try FileManager.default.copyItem(at: tempURL, to: destination)
                }
            }.value
            saveStates[entry.id] = .saved
        } catch {
            // A local write failure (full disk, read-only volume) is not a
            // server verdict, so the row stays tappable for another destination.
            saveStates[entry.id] = .failed(
                message: String(localized: LocalizedStringResource(
                    "fileTransfer.save.failed", defaultValue: "Couldn't save the file.")),
                retryable: true)
        }
    }
    #endif
}
