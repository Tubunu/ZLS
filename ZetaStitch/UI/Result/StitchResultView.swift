import SwiftUI
import UIKit
import Photos

public struct StitchResultView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var photoService: PhotoLibraryService
    @Environment(\.dismiss) private var dismiss

    let draft: StitchResultDraft

    @State private var isSavedToPhotos = false
    @State private var isSaving = false
    @State private var didDeleteOriginals = false
    @State private var showDeleteConfirm = false
    @State private var showFullScreenPreview = false
    @State private var shareFileURL: URL?

    private var hasOriginalsToDelete: Bool {
        (!draft.sourceAssets.isEmpty || draft.sourceRecordingID != nil) && !didDeleteOriginals
    }

    public init(draft: StitchResultDraft) {
        self.draft = draft
    }

    public var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    headerBar

                    statusPill

                    previewHeroCard

                    metadataRow

                    primaryActionStack

                    moreExportGrid
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 32)
            }
        }
        .navigationBarHidden(true)
        .task {
            await saveToPhotosIfNeeded()
        }
        .fullScreenCover(isPresented: $showFullScreenPreview) {
            FullScreenImagePreviewView(image: UIImage(cgImage: draft.image))
        }
        .sheet(
            isPresented: Binding(
                get: { shareFileURL != nil },
                set: { if !$0 { shareFileURL = nil } }
            )
        ) {
            if let shareFileURL {
                ActivityShareSheet(items: [shareFileURL])
            }
        }
        .alert(
            NSLocalizedString("result.delete_originals.confirm_title", comment: ""),
            isPresented: $showDeleteConfirm
        ) {
            Button(NSLocalizedString("common.delete", comment: ""), role: .destructive) {
                deleteOriginals()
            }
            Button(NSLocalizedString("common.cancel", comment: ""), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("result.delete_originals.confirm_message", comment: ""))
        }
    }

    private var headerBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(ZetaTheme.surfaceCard, in: Circle())
            }

            Spacer()

            Text(NSLocalizedString("result.title", comment: ""))
                .font(.headline)

            Spacer()

            Button {
                appState.popToRoot()
            } label: {
                Text(NSLocalizedString("result.back_home", comment: ""))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ZetaTheme.accent)
            }
        }
        .padding(.top, 8)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                Text(NSLocalizedString("result.saving", comment: ""))
            } else if isSavedToPhotos {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(ZetaTheme.success)
                Text(NSLocalizedString("result.saved_to_photos", comment: ""))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(ZetaTheme.accent)
                Text(NSLocalizedString("result.ready_to_save", comment: ""))
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(ZetaTheme.surfaceCard, in: Capsule())
    }

    private var previewHeroCard: some View {
        Button {
            showFullScreenPreview = true
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(uiImage: UIImage(cgImage: draft.image))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 220, maxHeight: 380)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack(spacing: 5) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    Text(NSLocalizedString("result.tap_preview", comment: ""))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(10)
            }
            .padding(10)
            .background(ZetaTheme.surfaceCard, in: RoundedRectangle(cornerRadius: ZetaTheme.cornerRadiusCard, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var metadataRow: some View {
        HStack(spacing: 10) {
            metadataChip(
                icon: "aspectratio",
                text: "\(draft.image.width) × \(draft.image.height)"
            )
            metadataChip(
                icon: "doc",
                text: ByteCountFormatter.string(fromByteCount: Int64(draft.encodedData.count), countStyle: .file)
            )
            metadataChip(
                icon: "sparkles",
                text: draft.format.fileExtension.uppercased()
            )
        }
    }

    private func metadataChip(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.weight(.medium).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(ZetaTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var primaryActionStack: some View {
        VStack(spacing: 10) {
            if isSavedToPhotos {
                Button {
                    if let url = URL(string: "photos-redirect://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label(NSLocalizedString("result.show_in_photos", comment: ""), systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ZetaTheme.accent, in: Capsule())
                }
            } else {
                Button {
                    Task { await saveToPhotosIfNeeded(force: true) }
                } label: {
                    Label(NSLocalizedString("result.save_to_photos", comment: ""), systemImage: "square.and.arrow.down")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(ZetaTheme.accent, in: Capsule())
                }
            }

            if hasOriginalsToDelete {
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label(NSLocalizedString("result.delete_originals", comment: ""), systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(ZetaTheme.surfaceCard, in: Capsule())
                }
            } else if didDeleteOriginals {
                Text(NSLocalizedString("result.deleted_originals", comment: ""))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(ZetaTheme.success)
                    .padding(.vertical, 4)
            }
        }
    }

    private var moreExportGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("result.more_sharing", comment: ""))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

            HStack(spacing: 10) {
                exportTile(
                    icon: "square.and.arrow.up",
                    title: NSLocalizedString("result.share_image", comment: "")
                ) {
                    shareImage()
                }

                exportTile(
                    icon: "doc.richtext",
                    title: NSLocalizedString("result.export_pdf", comment: "")
                ) {
                    exportPDF()
                }

                exportTile(
                    icon: "doc.zipper",
                    title: NSLocalizedString("result.export_zip", comment: "")
                ) {
                    exportZIP()
                }
            }
        }
    }

    private func exportTile(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(ZetaTheme.accent)
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(ZetaTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Actions

    private func saveToPhotosIfNeeded(force: Bool = false) async {
        guard force || !isSavedToPhotos else { return }
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status == .authorized || status == .limited || force else { return }

        await MainActor.run { isSaving = true }
        do {
            _ = try await photoService.saveImageDataToPhotos(draft.encodedData)
            await MainActor.run {
                isSaving = false
                withAnimation { isSavedToPhotos = true }
            }
        } catch {
            await MainActor.run {
                isSaving = false
                if force {
                    appState.errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func deleteOriginals() {
        Task {
            do {
                if !draft.sourceAssets.isEmpty {
                    try await photoService.deleteAssets(draft.sourceAssets)
                }
                if let recID = draft.sourceRecordingID {
                    try AppGroupStore.shared.deleteRecording(id: recID)
                }
                await MainActor.run {
                    withAnimation { didDeleteOriginals = true }
                }
            } catch {
                await MainActor.run {
                    appState.errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func shareImage() {
        let name = "ZetaStitch_\(timestampString()).\(draft.format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try draft.encodedData.write(to: url, options: .atomic)
            shareFileURL = url
        } catch {
            appState.errorAlertMessage = error.localizedDescription
        }
    }

    private func exportPDF() {
        appState.busyMessage = NSLocalizedString("result.creating_pdf", comment: "")
        appState.isBusy = true
        let img = draft.image
        Task.detached(priority: .userInitiated) {
            let pdfData = PDFCreator.createPDFData(from: img)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZetaStitch_\(Self.staticTimestamp()).pdf")
            try? pdfData.write(to: url, options: .atomic)
            await MainActor.run {
                appState.isBusy = false
                shareFileURL = url
            }
        }
    }

    private func exportZIP() {
        appState.busyMessage = NSLocalizedString("result.creating_zip", comment: "")
        appState.isBusy = true
        let imageData = draft.encodedData
        let ext = draft.format.fileExtension
        Task.detached(priority: .userInitiated) {
            do {
                let ts = Self.staticTimestamp()
                let entry = ZipArchiveWriter.Entry(fileName: "ZetaStitch_\(ts).\(ext)", data: imageData)
                let zipData = try ZipArchiveWriter.createArchive(entries: [entry])
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("ZetaStitch_\(ts).zip")
                try zipData.write(to: url, options: .atomic)
                await MainActor.run {
                    appState.isBusy = false
                    shareFileURL = url
                }
            } catch {
                await MainActor.run {
                    appState.isBusy = false
                    appState.errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func timestampString() -> String {
        Self.staticTimestamp()
    }

    private static func staticTimestamp() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd_HHmmss"
        return fmt.string(from: Date())
    }
}

// MARK: - Full Screen Zoom Preview

private struct FullScreenImagePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    let image: UIImage

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width * scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { val in
                                    scale = min(max(1.0, lastScale * val), 6.0)
                                }
                                .onEnded { _ in
                                    lastScale = scale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(response: 0.28)) {
                                if scale > 1.2 {
                                    scale = 1.0
                                    lastScale = 1.0
                                } else {
                                    scale = 2.5
                                    lastScale = 2.5
                                }
                            }
                        }
                }

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(16)
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
