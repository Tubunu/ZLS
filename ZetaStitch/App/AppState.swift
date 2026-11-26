import Foundation
import SwiftUI
import Photos
import AVFoundation
import ImageIO

public struct StitchDraft: Identifiable, Hashable {
    public let id = UUID()
    public let mode: StitchMode
    public let images: [CGImage]
    public let sourceAssets: [PHAsset]
    public let sourceRecordingID: String?
    public let initialSeams: [StitchSeam]?

    public init(
        mode: StitchMode,
        images: [CGImage],
        sourceAssets: [PHAsset] = [],
        sourceRecordingID: String? = nil,
        initialSeams: [StitchSeam]? = nil
    ) {
        self.mode = mode
        self.images = images
        self.sourceAssets = sourceAssets
        self.sourceRecordingID = sourceRecordingID
        self.initialSeams = initialSeams
    }

    public static func == (lhs: StitchDraft, rhs: StitchDraft) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct VideoTrimmerDraft: Identifiable, Hashable {
    public let id = UUID()
    public let asset: AVAsset
    public let sourcePhotoAsset: PHAsset?
    public let sourceRecordingID: String?

    public init(asset: AVAsset, sourcePhotoAsset: PHAsset? = nil, sourceRecordingID: String? = nil) {
        self.asset = asset
        self.sourcePhotoAsset = sourcePhotoAsset
        self.sourceRecordingID = sourceRecordingID
    }

    public static func == (lhs: VideoTrimmerDraft, rhs: VideoTrimmerDraft) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public struct StitchResultDraft: Identifiable, Hashable {
    public let id = UUID()
    public let image: CGImage
    public let encodedData: Data
    public let format: ExportFormat
    public let sourceAssets: [PHAsset]
    public let sourceRecordingID: String?

    public init(
        image: CGImage,
        encodedData: Data,
        format: ExportFormat,
        sourceAssets: [PHAsset],
        sourceRecordingID: String?
    ) {
        self.image = image
        self.encodedData = encodedData
        self.format = format
        self.sourceAssets = sourceAssets
        self.sourceRecordingID = sourceRecordingID
    }

    public static func == (lhs: StitchResultDraft, rhs: StitchResultDraft) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum AppRoute: Hashable {
    case editor(StitchDraft)
    case videoTrimmer(VideoTrimmerDraft)
    case result(StitchResultDraft)
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var navigationPath: [AppRoute] = []
    @Published public var isScrollshotHubPresented = false
    @Published public var isSettingsPresented = false
    @Published public var isScrollshotGuidePresented = false
    @Published public var pendingNewRecording: ScreenRecordingInfo?
    @Published public var isBusy = false
    @Published public var busyMessage: String = ""
    @Published public var errorAlertMessage: String?

    // Reactive mirrored preferences backed by AppGroupStore
    @Published public var autoEndSeconds: AutoEndSeconds {
        didSet { AppGroupStore.shared.autoEndSeconds = autoEndSeconds }
    }
    @Published public var hapticOnStart: Bool {
        didSet { AppGroupStore.shared.hapticOnStart = hapticOnStart }
    }
    @Published public var notifyOnComplete: Bool {
        didSet { AppGroupStore.shared.notifyOnComplete = notifyOnComplete }
    }
    @Published public var exportResolution: ExportResolution {
        didSet { AppGroupStore.shared.exportResolution = exportResolution }
    }
    @Published public var exportFormat: ExportFormat {
        didSet { AppGroupStore.shared.exportFormat = exportFormat }
    }
    @Published public var autoTrimStaticBars: Bool {
        didSet { AppGroupStore.shared.autoTrimStaticBars = autoTrimStaticBars }
    }

    private var lastPromptedRecordingID: String?

    public init() {
        let store = AppGroupStore.shared
        self.autoEndSeconds = store.autoEndSeconds
        self.hapticOnStart = store.hapticOnStart
        self.notifyOnComplete = store.notifyOnComplete
        self.exportResolution = store.exportResolution
        self.exportFormat = store.exportFormat
        self.autoTrimStaticBars = store.autoTrimStaticBars
        self.lastPromptedRecordingID = store.latestRecordingID
    }

    public func checkForNewScrollshot() {
        let store = AppGroupStore.shared
        guard let latestID = store.latestRecordingID,
              latestID != lastPromptedRecordingID,
              let info = store.loadRecordingInfo(id: latestID),
              !info.matches.isEmpty else {
            return
        }
        lastPromptedRecordingID = latestID
        pendingNewRecording = info
    }

    public func openRecordingInEditor(_ info: ScreenRecordingInfo) {
        pendingNewRecording = nil
        isScrollshotHubPresented = false
        let kfFolder = AppGroupStore.shared.keyframesFolderURL(for: info.id, folderName: info.keyframesFolderName)

        var loadedImages: [CGImage] = []
        loadedImages.reserveCapacity(info.matches.count)

        for match in info.matches {
            let fileURL = kfFolder.appendingPathComponent(match.keyframeFileName)
            if let src = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
               let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                loadedImages.append(cg)
            }
        }

        if !loadedImages.isEmpty {
            let draft = StitchDraft(
                mode: .longStitch,
                images: loadedImages,
                sourceAssets: [],
                sourceRecordingID: info.id
            )
            navigationPath.append(.editor(draft))
            return
        }

        // Fall back to trimming the recorded MP4 if keyframes aren't available
        let videoURL = AppGroupStore.shared.videoURL(for: info)
        if FileManager.default.fileExists(atPath: videoURL.path) {
            let avAsset = AVURLAsset(url: videoURL)
            navigationPath.append(.videoTrimmer(VideoTrimmerDraft(
                asset: avAsset,
                sourcePhotoAsset: nil,
                sourceRecordingID: info.id
            )))
        }
    }

    public func popToRoot() {
        navigationPath.removeAll()
    }
}
