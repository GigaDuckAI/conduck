// SPDX-License-Identifier: Apache-2.0
//
// App-owned metadata stays available when source bytes are missing. File and
// link actions use the router's existing native-preview/export boundaries;
// editable notes remain separate from the original content and companions.

#if !os(watchOS)
import SwiftUI
import QuickLook

struct WorkMaterialNotesSummary: View {
    let material: WorkboardMaterialSnapshot
    let router: PersonalWorkbenchRouter
    let onEdit: () -> Void

    var body: some View {
        let annotation = router.textState(for: material).annotation ?? ""
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(LocalizedStringResource("workdesk.material.notes.title", defaultValue: "Your notes"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Button(action: onEdit) {
                    Text(router.hasUnsavedNotes(for: material.id)
                        ? LocalizedStringResource("workboard.material.notes.continue", defaultValue: "Continue editing…")
                        : annotation.isEmpty
                        ? LocalizedStringResource("workboard.material.notes.add", defaultValue: "Add notes…")
                        : LocalizedStringResource("workboard.material.notes.edit", defaultValue: "Edit notes…"))
                        .font(.subheadline).padding(.vertical, 6)
                }.inlineLinkButton()
            }
            if !annotation.isEmpty {
                Text(verbatim: annotation).font(.callout).lineLimit(3)
                    .foregroundStyle(AppColors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct WorkMaterialDetailsSheet: View {
    let material: WorkboardMaterialSnapshot
    let router: PersonalWorkbenchRouter
    @State private var editor: WorkMaterialTextEditorSession?
    @State private var isOpening = false
    @State private var previewLoadID: UUID?
    @State private var inlineNotes: WorkMaterialTextEditorSession?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var currentMaterial: WorkboardMaterialSnapshot {
        PersonalWorkbenchRouter.currentDeskCard(in: router.deskMaterials(), for: material)
    }

    private var canEditSource: Bool {
        !currentMaterial.isRemoteProjectResult && (currentMaterial.kind == .note || currentMaterial.kind == .transcript)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    sourceContent
                    if router.hasSourceConversation(material.id) {
                        Button(LocalizedStringResource("workboard.material.sourceConversation", defaultValue: "Open source conversation")) {
                            router.openSourceConversation(material.id)
                        }.inlineLinkButton()
                    }
                    Divider()
                    if let inlineNotes {
                        WorkMaterialInlineNotesEditor(session: inlineNotes) { self.inlineNotes = nil }
                    } else {
                        WorkMaterialNotesSummary(material: currentMaterial, router: router) {
                            inlineNotes = router.textEditor(for: currentMaterial, field: .annotation)
                        }
                    }
                    if let notice = router.previewNotice {
                        Text(verbatim: notice.message).font(.callout).foregroundStyle(.red)
                    }
                    WorkShareStatusBanner(share: router.share, rendersFailure: true, reduceMotion: reduceMotion)
                }
                .padding(20)
                .frame(maxWidth: 740, alignment: .leading).frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(AppColors.background)
            .navigationTitle(Text(verbatim: currentMaterial.name))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(LocalizedStringResource("common.done", defaultValue: "Done")) { router.closeMaterial() }
                        .disabled(inlineNotes?.isDirty == true || inlineNotes?.isBusy == true)
                }
                ToolbarItem(placement: .automatic) {
                    if WorkboardCardActionPolicy.allows(.open, when: currentMaterial.availability), !currentMaterial.isRemoteProjectResult {
                        Button {
                            router.share.share(materialID: material.id)
                        } label: {
                            Label(LocalizedStringResource("workboard.material.share", defaultValue: "Share"), systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .sheet(item: $editor) { session in WorkMaterialTextEditor(session: session) }
        .interactiveDismissDisabled(inlineNotes?.isDirty == true || inlineNotes?.isBusy == true)
        .task(id: WorkMaterialNativePreviewKey(material: currentMaterial)) {
            let material = currentMaterial
            guard !Task.isCancelled, material.kind == .file || material.kind == .audio else { return }
            // Revision and availability changes invalidate both the displayed
            // export and any in-flight copy before starting a replacement.
            router.filePreview.cancelPendingPresentation()
            previewLoadID = nil
            isOpening = false
            guard WorkboardCardActionPolicy.allows(.open, when: material.availability) else { return }
            await loadOriginal(material)
        }
        .workboardDesktopSheetFrame(minWidth: 420, minHeight: 400)
    }

    @ViewBuilder
    private var sourceContent: some View {
        let material = currentMaterial
        if material.kind == .note || material.kind == .transcript {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: router.textState(for: material).textContent ?? material.detail ?? "")
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if canEditSource {
                    Button {
                        editor = router.textEditor(for: material, field: .source)
                    } label: {
                        Text(material.kind == .transcript
                            ? LocalizedStringResource("workboard.material.transcript.edit", defaultValue: "Edit transcript")
                            : LocalizedStringResource("workboard.material.text.edit", defaultValue: "Edit text"))
                    }.inlineLinkButton()
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text(verbatim: material.name).font(.headline)
                } icon: {
                    Image(systemName: material.kind == .image ? "photo" : material.kind == .link ? "link" : material.kind == .audio ? "waveform" : "doc")
                }
                if let address = material.urlString, material.kind == .link {
                    Text(verbatim: address).font(.callout).textSelection(.enabled)
                        .foregroundStyle(AppColors.textSecondary)
                }
                if WorkboardCardActionPolicy.allows(.open, when: material.availability) {
                    if material.kind == .file || material.kind == .audio {
                        if let url = router.filePreview.previewURL, let lease = router.nativePreviewLease, lease.url == url {
                            WorkMaterialNativePreview(lease: lease)
                                .id(url)
                                .frame(minHeight: 300, idealHeight: 420, maxHeight: 500)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .accessibilityLabel(Text(LocalizedStringResource("workboard.material.original.preview", defaultValue: "Preview original")))
                        } else if isOpening {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                        } else {
                            Button(LocalizedStringResource("common.retry", defaultValue: "Try again")) { openOriginal(material) }
                                .inlineLinkButton()
                        }
                    } else {
                        Button {
                            openOriginal(material)
                        } label: {
                            Text(material.kind == .link
                                ? LocalizedStringResource("workboard.material.link.open", defaultValue: "Open link")
                                : LocalizedStringResource("workboard.material.image.open", defaultValue: "Open image"))
                                .padding(.vertical, 6)
                        }.inlineLinkButton().disabled(isOpening)
                    }
                } else {
                    Text(material.availability == .syncPending
                        ? LocalizedStringResource("workboard.material.syncPending", defaultValue: "Waiting for iCloud…")
                        : LocalizedStringResource("workboard.material.original.unavailable", defaultValue: "The original isn’t available on this device. Your notes are still available here."))
                        .font(.callout).foregroundStyle(AppColors.textSecondary)
                }
            }
        }
    }
    private func openOriginal(_ material: WorkboardMaterialSnapshot) {
        guard !isOpening else { return }
        Task { await loadOriginal(material) }
    }

    private func loadOriginal(_ material: WorkboardMaterialSnapshot) async {
        guard !Task.isCancelled else { return }
        let loadID = UUID()
        previewLoadID = loadID
        isOpening = true
        await router.openOriginal(material)
        if previewLoadID == loadID { isOpening = false }
    }

}
#endif
