import Foundation
import SwiftUI
import UIKit
import CoreGraphics

public enum EditorToolMode: Equatable {
    case preview
    case seamEdit
    case crop
}

public enum SeamTrimTarget: String, CaseIterable, Identifiable {
    case bottomOfUpper
    case topOfLower

    public var id: String { rawValue }
}

@MainActor
public final class StitchEditorViewModel: ObservableObject {
    public let draft: StitchDraft
    private let engine = StitchEngine()

    @Published public var mode: StitchMode
    @Published public var seams: [StitchSeam] = []
    @Published public var detectedScrollbars: [[ScrollbarRegion]] = []
    @Published public var removeScrollbars: Bool = false
    @Published public var crop: NormalizedCropRect = .full
    @Published public var spacing: Int = 0

    @Published public var toolMode: EditorToolMode = .preview
    @Published public var activeSeamIndex: Int?
    @Published public var seamTrimTarget: SeamTrimTarget = .topOfLower
    @Published public var isAnalyzing: Bool = true

    /// Display images (original or scrollbar-cleaned) cached per source segment.
    @Published public private(set) var displayImages: [UIImage] = []
    private var cleanedCGImages: [CGImage]?

    public init(draft: StitchDraft) {
        self.draft = draft
        self.mode = draft.mode
        self.displayImages = draft.images.map { UIImage(cgImage: $0) }
    }

    public var totalScrollbarCount: Int {
        detectedScrollbars.reduce(0) { $0 + $1.count }
    }

    public var unmatchedCount: Int {
        seams.filter { $0.status.needsAttention }.count
    }

    public var outputPixelSize: CGSize {
        let geom = engine.computeCanvasGeometry(
            images: draft.images,
            seams: seams,
            mode: mode,
            spacing: spacing
        )
        let full = CGSize(width: geom.width, height: geom.height)
        return crop.isFull ? full : crop.pixelRect(for: full).size
    }

    public func analyzeIfNeeded(autoTrimStaticBars: Bool) async {
        guard isAnalyzing else { return }

        if let provided = draft.initialSeams {
            self.seams = provided
            self.detectedScrollbars = await engine.detectScrollbars(in: draft.images)
        } else {
            let (computedSeams, scrollbars) = await engine.buildInitialPlan(
                images: draft.images,
                mode: mode,
                autoTrimStaticBars: autoTrimStaticBars
            )
            self.seams = computedSeams
            self.detectedScrollbars = scrollbars
        }

        if let firstUnmatched = seams.firstIndex(where: { $0.status.needsAttention }) {
            self.activeSeamIndex = firstUnmatched
            self.toolMode = .seamEdit
        } else if !seams.isEmpty {
            self.activeSeamIndex = 0
        }

        self.isAnalyzing = false
    }

    public func switchMode(to newMode: StitchMode, autoTrimStaticBars: Bool) async {
        guard newMode != mode else { return }
        mode = newMode
        isAnalyzing = true
        let (computedSeams, _) = await engine.buildInitialPlan(
            images: draft.images,
            mode: newMode,
            autoTrimStaticBars: autoTrimStaticBars
        )
        seams = computedSeams
        activeSeamIndex = seams.isEmpty ? nil : 0
        isAnalyzing = false
    }

    public func toggleScrollbarRemoval() {
        let next = !removeScrollbars
        removeScrollbars = next

        if next {
            if cleanedCGImages == nil {
                cleanedCGImages = draft.images.enumerated().map { idx, img in
                    let regs = idx < detectedScrollbars.count ? detectedScrollbars[idx] : []
                    return regs.isEmpty ? img : ScrollbarProcessor.shared.removeScrollbars(from: img, regions: regs)
                }
            }
            if let cleaned = cleanedCGImages {
                displayImages = cleaned.map { UIImage(cgImage: $0) }
            }
        } else {
            displayImages = draft.images.map { UIImage(cgImage: $0) }
        }
    }

    public func nudgeActiveSeam(deltaPixels: Int) {
        guard let idx = activeSeamIndex, idx >= 0, idx < seams.count else { return }
        adjustSeam(at: idx, target: seamTrimTarget, deltaPixels: deltaPixels)
    }

    public func adjustSeam(at index: Int, target: SeamTrimTarget, deltaPixels: Int) {
        guard index >= 0, index < seams.count, index + 1 < draft.images.count else { return }
        var seam = seams[index]

        switch target {
        case .bottomOfUpper:
            let img = draft.images[index]
            let prevTopTrim = index > 0 ? seams[index - 1].botCropTop : 0
            let maxBotTrim = max(0, (mode == .horizontal ? img.width : img.height) - prevTopTrim - 24)
            seam.topCropBottom = max(0, min(maxBotTrim, seam.topCropBottom + deltaPixels))
        case .topOfLower:
            let img = draft.images[index + 1]
            let nextBotTrim = index + 1 < seams.count ? seams[index + 1].topCropBottom : 0
            let maxTopTrim = max(0, (mode == .horizontal ? img.width : img.height) - nextBotTrim - 24)
            seam.botCropTop = max(0, min(maxTopTrim, seam.botCropTop + deltaPixels))
        }

        seam.status = .manual
        seams[index] = seam
    }

    public func rematchSeam(at index: Int, autoTrimStaticBars: Bool) {
        guard index >= 0, index < seams.count, index + 1 < draft.images.count, mode == .longStitch else { return }
        let detector = OverlapDetector(config: OverlapDetectionConfig(autoTrimStaticBars: autoTrimStaticBars))
        let result = detector.detectVerticalOverlap(topImage: draft.images[index], bottomImage: draft.images[index + 1])
        seams[index] = result.toSeam(topIndex: index)
    }

    public func cycleSpacing() {
        let presets = [0, 8, 16, 28]
        if let idx = presets.firstIndex(of: spacing) {
            spacing = presets[(idx + 1) % presets.count]
        } else {
            spacing = 0
        }
    }

    public func exportResult(resolution: ExportResolution, format: ExportFormat) async -> StitchResultDraft? {
        let imagesCopy = draft.images
        let seamsCopy = seams
        let scrollbarsCopy = detectedScrollbars
        let modeCopy = mode
        let removeSB = removeScrollbars
        let cropCopy = crop
        let spacingCopy = mode == .longStitch ? 0 : spacing
        let assetsCopy = draft.sourceAssets
        let recIDCopy = draft.sourceRecordingID

        return await Task.detached(priority: .userInitiated) {
            let localEngine = StitchEngine()
            guard let rendered = localEngine.renderStitchedImage(
                images: imagesCopy,
                seams: seamsCopy,
                scrollbars: scrollbarsCopy,
                mode: modeCopy,
                removeScrollbars: removeSB,
                crop: cropCopy,
                resolution: resolution,
                spacing: spacingCopy
            ) else {
                return nil
            }

            let chosenFormat: ExportFormat
            let data: Data
            if let encoded = StitchEngine.encodeImage(rendered, format: format) {
                chosenFormat = format
                data = encoded
            } else if let pngFallback = StitchEngine.encodeImage(rendered, format: .png) {
                chosenFormat = .png
                data = pngFallback
            } else {
                return nil
            }

            return StitchResultDraft(
                image: rendered,
                encodedData: data,
                format: chosenFormat,
                sourceAssets: assetsCopy,
                sourceRecordingID: recIDCopy
            )
        }.value
    }

    public func croppedUIImage(for index: Int) -> UIImage {
        let source = index < displayImages.count ? displayImages[index] : UIImage(cgImage: draft.images[index])
        guard let cg = source.cgImage else { return source }
        let trimStart = index > 0 && index - 1 < seams.count ? seams[index - 1].botCropTop : 0
        let trimEnd = index < seams.count ? seams[index].topCropBottom : 0

        if mode == .horizontal {
            let x = max(0, min(trimStart, cg.width - 2))
            let w = max(1, cg.width - x - max(0, min(trimEnd, cg.width - x - 1)))
            if let cropped = cg.cropping(to: CGRect(x: x, y: 0, width: w, height: cg.height)) {
                return UIImage(cgImage: cropped)
            }
        } else {
            let y = max(0, min(trimStart, cg.height - 2))
            let h = max(1, cg.height - y - max(0, min(trimEnd, cg.height - y - 1)))
            if let cropped = cg.cropping(to: CGRect(x: 0, y: y, width: cg.width, height: h)) {
                return UIImage(cgImage: cropped)
            }
        }
        return source
    }
}
