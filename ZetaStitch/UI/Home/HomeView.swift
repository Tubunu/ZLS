import SwiftUI
import Photos
import PhotosUI
import AVFoundation
import UIKit

public struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var photoService: PhotoLibraryService

    @State private var selectedAssetIDs: [String] = []
    @State private var cellFrames: [String: CGRect] = [:]
    @State private var isSwipeSelecting = false
    @State private var swipeTargetState: Bool = true
    @State private var lastSweptAssetID: String?
    @State private var photosPickerItems: [PhotosPickerItem] = []

    private var selectedAssets: [PHAsset] {
        let map = Dictionary(uniqueKeysWithValues: photoService.assets.map { ($0.localIdentifier, $0) })
        return selectedAssetIDs.compactMap { map[$0] }
    }

    private var selectedMediaType: PHAssetMediaType? {
        selectedAssets.first?.mediaType
    }

    public init() {}

    public var body: some View {
        ZStack(alignment: .bottom) {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                topHeaderBar

                if let newRec = appState.pendingNewRecording {
                    newScrollshotBanner(info: newRec)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if photoService.authorizationStatus == .limited {
                    limitedLibraryBanner
                }

                contentBody
            }

            floatingBottomDock
        }
        .navigationBarHidden(true)
        .onChange(of: photosPickerItems) { items in
            guard !items.isEmpty else { return }
            Task {
                await handleSystemPhotosPicker(items)
            }
        }
    }

    // MARK: - Header

    private var topHeaderBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(photoService.albums) { album in
                    Button {
                        photoService.selectAlbum(album)
                    } label: {
                        HStack {
                            Text("\(album.title) (\(album.count))")
                            if album.id == photoService.selectedAlbumID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(currentAlbumTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }

            Spacer()

            Button {
                appState.isScrollshotHubPresented = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "record.circle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ZetaTheme.accent)
                    Text(NSLocalizedString("home.scrollshot", comment: ""))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: Capsule())
            }

            Button {
                appState.isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle())
            }
            .accessibilityLabel(NSLocalizedString("settings.title", comment: ""))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var currentAlbumTitle: String {
        photoService.albums.first(where: { $0.id == photoService.selectedAlbumID })?.title
            ?? NSLocalizedString("album.screenshots", comment: "")
    }

    private func newScrollshotBanner(info: ScreenRecordingInfo) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(ZetaTheme.accent, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("scrollshot.ready.banner.title", comment: ""))
                    .font(.subheadline.weight(.semibold))
                Text(String(format: NSLocalizedString("scrollshot.ready.banner.subtitle", comment: ""), info.matches.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(NSLocalizedString("common.open", comment: "")) {
                appState.openRecordingInEditor(info)
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                withAnimation { appState.pendingNewRecording = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
        }
        .padding(12)
        .background(ZetaTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private var limitedLibraryBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(ZetaTheme.warning)
            Text(NSLocalizedString("home.permission.limited.tip", comment: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(NSLocalizedString("home.permission.limited.add", comment: "")) {
                presentLimitedLibraryPicker()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(ZetaTheme.surfaceCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Content Body

    @ViewBuilder
    private var contentBody: some View {
        switch photoService.authorizationStatus {
        case .authorized, .limited:
            if photoService.assets.isEmpty {
                emptyAlbumView
            } else {
                assetGridView
            }
        case .notDetermined:
            permissionGuideView(denied: false)
        case .denied, .restricted:
            permissionGuideView(denied: true)
        @unknown default:
            permissionGuideView(denied: true)
        }
    }

    private var assetGridView: some View {
        let columns = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 3)]

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(photoService.assets, id: \.localIdentifier) { asset in
                    let id = asset.localIdentifier
                    let selIndex = selectedAssetIDs.firstIndex(of: id)
                    PhotoGridCell(
                        asset: asset,
                        selectionNumber: selIndex.map { $0 + 1 },
                        photoService: photoService
                    )
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: AssetFramePreferenceKey.self,
                                value: [id: geo.frame(in: .named("assetGrid"))]
                            )
                        }
                    )
                    .onTapGesture {
                        toggleSelection(for: asset)
                    }
                }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 120)
        }
        .coordinateSpace(name: "assetGrid")
        .onPreferenceChange(AssetFramePreferenceKey.self) { frames in
            self.cellFrames = frames
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.22)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("assetGrid")))
                .onChanged { value in
                    switch value {
                    case .second(true, let drag?):
                        handleSweepDrag(at: drag.location)
                    default:
                        break
                    }
                }
                .onEnded { _ in
                    isSwipeSelecting = false
                    lastSweptAssetID = nil
                }
        )
    }

    private var emptyAlbumView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(NSLocalizedString("home.empty.title", comment: ""))
                .font(.headline)
            Text(NSLocalizedString("home.empty.subtitle", comment: ""))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            PhotosPicker(
                selection: $photosPickerItems,
                maxSelectionCount: 30,
                matching: .images
            ) {
                Label(NSLocalizedString("home.pick_from_system", comment: ""), systemImage: "photo.stack")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.bottom, 80)
    }

    private func permissionGuideView(denied: Bool) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle()
                    .fill(ZetaTheme.accent.opacity(0.12))
                    .frame(width: 84, height: 84)
                Image(systemName: denied ? "lock.shield" : "photo.stack")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(ZetaTheme.accent)
            }

            Text(NSLocalizedString(denied ? "home.permission.deny.title" : "home.permission.notdetermined.title", comment: ""))
                .font(.body.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 36)

            Button {
                if denied {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    Task { await photoService.requestPermission() }
                }
            } label: {
                Text(NSLocalizedString(denied ? "common.go_settings" : "home.permission.allow", comment: ""))
                    .font(.headline)
                    .frame(minWidth: 180)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            Spacer()
        }
        .padding(.bottom, 60)
    }

    // MARK: - Floating Bottom Dock

    private var floatingBottomDock: some View {
        Group {
            if selectedAssets.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "hand.tap")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("home.picker.hint", comment: ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    PhotosPicker(
                        selection: $photosPickerItems,
                        maxSelectionCount: 30,
                        matching: .images
                    ) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(ZetaTheme.accent)
                    }
                    .accessibilityLabel(NSLocalizedString("home.pick_from_system", comment: ""))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                .zetaGlassToolbar()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else if selectedMediaType == .video, let videoAsset = selectedAssets.first {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.snappy) { selectedAssetIDs.removeAll() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 36, height: 36)
                            .background(Color.primary.opacity(0.08), in: Circle())
                    }

                    Button {
                        openVideoTrimmer(for: videoAsset)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "scissors")
                            Text(NSLocalizedString("home.action.video_stitch", comment: ""))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(ZetaTheme.accent, in: Capsule())
                    }
                }
                .padding(10)
                .zetaGlassToolbar()
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else {
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { selectedAssetIDs.removeAll() }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "xmark")
                                .font(.caption.weight(.bold))
                            Text("\(selectedAssets.count)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                        }
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.08), in: Circle())
                    }

                    Button {
                        startPhotoStitch(mode: .longStitch)
                    } label: {
                        Label(NSLocalizedString("mode.long_stitch", comment: ""), systemImage: "rectangle.stack")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                selectedAssets.count >= 2 ? ZetaTheme.accent : Color.gray.opacity(0.5),
                                in: Capsule()
                            )
                    }
                    .disabled(selectedAssets.count < 2)

                    Button {
                        startPhotoStitch(mode: .vertical)
                    } label: {
                        Label(NSLocalizedString("mode.v_stitch", comment: ""), systemImage: "rectangle.split.1x2")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .disabled(selectedAssets.count < 2)

                    Button {
                        startPhotoStitch(mode: .horizontal)
                    } label: {
                        Label(NSLocalizedString("mode.h_stitch", comment: ""), systemImage: "rectangle.split.2x1")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    .disabled(selectedAssets.count < 2)
                }
                .padding(10)
                .zetaGlassToolbar()
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .animation(.snappy(duration: 0.22), value: selectedAssetIDs)
    }

    // MARK: - Selection & Actions

    private func toggleSelection(for asset: PHAsset) {
        let id = asset.localIdentifier
        if let idx = selectedAssetIDs.firstIndex(of: id) {
            selectedAssetIDs.remove(at: idx)
            return
        }

        if let currentType = selectedMediaType, currentType != asset.mediaType {
            appState.errorAlertMessage = NSLocalizedString("picker.error.mixed_media", comment: "")
            return
        }

        if asset.mediaType == .video {
            selectedAssetIDs = [id]
            return
        }

        if selectedAssetIDs.count >= 30 {
            appState.errorAlertMessage = String(format: NSLocalizedString("picker.error.max_limit", comment: ""), 30)
            return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        selectedAssetIDs.append(id)
    }

    private func handleSweepDrag(at location: CGPoint) {
        guard let hitID = cellFrames.first(where: { $0.value.contains(location) })?.key,
              hitID != lastSweptAssetID,
              let asset = photoService.assets.first(where: { $0.localIdentifier == hitID }),
              asset.mediaType == .image else {
            return
        }

        lastSweptAssetID = hitID
        if !isSwipeSelecting {
            isSwipeSelecting = true
            swipeTargetState = !selectedAssetIDs.contains(hitID)
        }

        if swipeTargetState {
            if !selectedAssetIDs.contains(hitID) && selectedAssetIDs.count < 30 && (selectedMediaType == nil || selectedMediaType == .image) {
                UISelectionFeedbackGenerator().selectionChanged()
                selectedAssetIDs.append(hitID)
            }
        } else {
            selectedAssetIDs.removeAll { $0 == hitID }
        }
    }

    private func startPhotoStitch(mode: StitchMode) {
        let chosen = selectedAssets
        guard chosen.count >= 2 else { return }

        appState.busyMessage = NSLocalizedString("editor.loading_images", comment: "")
        appState.isBusy = true

        Task {
            do {
                var loaded: [CGImage] = []
                loaded.reserveCapacity(chosen.count)
                for asset in chosen {
                    let img = try await photoService.loadFullResolutionCGImage(for: asset)
                    loaded.append(img)
                }
                await MainActor.run {
                    appState.isBusy = false
                    let draft = StitchDraft(
                        mode: mode,
                        images: loaded,
                        sourceAssets: chosen
                    )
                    appState.navigationPath.append(.editor(draft))
                }
            } catch {
                await MainActor.run {
                    appState.isBusy = false
                    appState.errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func openVideoTrimmer(for asset: PHAsset) {
        appState.busyMessage = NSLocalizedString("common.loading", comment: "")
        appState.isBusy = true

        Task {
            do {
                let avAsset = try await photoService.loadAVAsset(for: asset)
                await MainActor.run {
                    appState.isBusy = false
                    appState.navigationPath.append(.videoTrimmer(VideoTrimmerDraft(
                        asset: avAsset,
                        sourcePhotoAsset: asset,
                        sourceRecordingID: nil
                    )))
                }
            } catch {
                await MainActor.run {
                    appState.isBusy = false
                    appState.errorAlertMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleSystemPhotosPicker(_ items: [PhotosPickerItem]) async {
        await MainActor.run {
            appState.busyMessage = NSLocalizedString("editor.loading_images", comment: "")
            appState.isBusy = true
        }

        var loaded: [CGImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data),
               let cg = uiImage.normalizedCGImage() {
                loaded.append(cg)
            }
        }

        await MainActor.run {
            photosPickerItems = []
            appState.isBusy = false
            if loaded.count >= 2 {
                let draft = StitchDraft(mode: .longStitch, images: loaded)
                appState.navigationPath.append(.editor(draft))
            } else if !loaded.isEmpty {
                appState.errorAlertMessage = NSLocalizedString("picker.error.need_two_images", comment: "")
            }
        }
    }

    private func presentLimitedLibraryPicker() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootVC = scene.windows.first?.rootViewController else {
            return
        }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: rootVC)
    }
}

private struct AssetFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct PhotoGridCell: View {
    @Environment(\.displayScale) private var displayScale
    let asset: PHAsset
    let selectionNumber: Int?
    let photoService: PhotoLibraryService

    @State private var thumbnail: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color(uiColor: .secondarySystemFill)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()

                if let number = selectionNumber {
                    Color.black.opacity(0.18)
                    Text("\(number)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(ZetaTheme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                        .padding(6)
                } else {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                        .background(Circle().fill(Color.black.opacity(0.22)))
                        .frame(width: 22, height: 22)
                        .padding(6)
                }

                if asset.mediaType == .video {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(formatDuration(asset.duration))
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: ZetaTheme.cornerRadiusTile, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: ZetaTheme.cornerRadiusTile, style: .continuous)
                    .strokeBorder(selectionNumber != nil ? ZetaTheme.accent : .clear, lineWidth: 2.5)
            )
            .onAppear {
                let scale = max(1, displayScale)
                let size = CGSize(width: geo.size.width * scale, height: geo.size.height * scale)
                requestID = photoService.requestThumbnail(for: asset, targetSize: size) { img in
                    self.thumbnail = img
                }
            }
            .onDisappear {
                photoService.cancelThumbnailRequest(requestID)
                requestID = PHInvalidImageRequestID
            }
        }
        .aspectRatio(0.75, contentMode: .fit)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}
