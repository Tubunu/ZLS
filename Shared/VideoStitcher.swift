import Foundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Vision
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public final class VideoStitcher {
    public struct Configuration: Sendable {
        /// Minimum translation (in points/pixels on normalized analysis frame) to consider content scrolled.
        public var sameFrameMaxOffset: CGFloat
        /// Number of consecutive idle frames before firing `onScrollIdle`.
        public var idleFrameThreshold: Int
        /// Minimum vertical advancement fraction of viewport height before capturing a new keyframe.
        public var keyframeStepFraction: CGFloat
        /// Maximum width used for real-time Vision registration inside ReplayKit extension (keeps RAM tiny).
        public var analysisMaxWidth: CGFloat

        public init(
            sameFrameMaxOffset: CGFloat = 2.0,
            idleFrameThreshold: Int = 18,
            keyframeStepFraction: CGFloat = 0.42,
            analysisMaxWidth: CGFloat = 360
        ) {
            self.sameFrameMaxOffset = sameFrameMaxOffset
            self.idleFrameThreshold = idleFrameThreshold
            self.keyframeStepFraction = keyframeStepFraction
            self.analysisMaxWidth = analysisMaxWidth
        }
    }

    private let config: Configuration
    private let ciContext: CIContext
    private let sequenceHandler = VNSequenceRequestHandler()

    private var prevAnalysisImage: CIImage?
    private var accumulatedDeltaY: CGFloat = 0
    private var totalOffset: CGFloat = 0
    private var frameIndex: Int = 0
    private var keyframeIndex: Int = 0
    private var sameFrameCount: Int = 0
    private var isScrollIdle = false
    private(set) public var matchItems: [VideoMatchItem] = []

    public var frameSize: CGSize = .zero
    public var orientationRaw: Int = 0

    public var onScrollIdle: (() -> Void)?
    public var onScrollResumed: (() -> Void)?

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self.ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    }

    /// Processes a live ReplayKit video `CVPixelBuffer`, tracking scroll displacement and writing keyframes to disk.
    public func processLiveFrame(
        _ pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation = .up,
        keyframesFolder: URL
    ) {
        let rawCI = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let extent = rawCI.extent
        guard extent.width > 16, extent.height > 32 else { return }

        if frameSize == .zero {
            frameSize = extent.size
            orientationRaw = Int(orientation.rawValue)
        }

        // Crop out top status bar (7%), bottom home indicator (5%), and right scrollbar (7%)
        // so registration measures pure scrollable page motion.
        let roi = CGRect(
            x: extent.minX + extent.width * 0.03,
            y: extent.minY + extent.height * 0.06,
            width: extent.width * 0.89,
            height: extent.height * 0.87
        )
        let cropped = rawCI.cropped(to: roi)
        let scale = min(1.0, config.analysisMaxWidth / roi.width)
        let analysisImage = cropped
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: -cropped.extent.minX * scale, y: -cropped.extent.minY * scale))

        defer {
            prevAnalysisImage = analysisImage
            frameIndex += 1
        }

        guard let prev = prevAnalysisImage else {
            // Save initial keyframe immediately
            saveKeyframe(ciImage: rawCI, folder: keyframesFolder, deltaY: 0, isMatch: true)
            return
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCIImage: analysisImage)
        do {
            try sequenceHandler.perform([request], on: prev)
            guard let obs = request.results?.first as? VNImageTranslationAlignmentObservation else {
                recordIdleFrame()
                return
            }

            let dyAnalysis = obs.alignmentTransform.ty
            let dxAnalysis = obs.alignmentTransform.tx
            let dyNative = dyAnalysis / scale

            if abs(dyNative) <= config.sameFrameMaxOffset || abs(dxAnalysis) > 20 {
                recordIdleFrame()
                return
            }

            // Scrolling is active
            if isScrollIdle {
                isScrollIdle = false
                onScrollResumed?()
            }
            sameFrameCount = 0

            // Only advance forward along primary scroll axis
            accumulatedDeltaY += dyNative
            totalOffset += dyNative

            let stepThreshold = extent.height * config.keyframeStepFraction
            if abs(accumulatedDeltaY) >= stepThreshold {
                let overlap = max(0, Int(extent.height - abs(accumulatedDeltaY)))
                saveKeyframe(ciImage: rawCI, folder: keyframesFolder, deltaY: accumulatedDeltaY, isMatch: true, overlap: overlap)
                accumulatedDeltaY = 0
            }
        } catch {
            recordIdleFrame()
        }
    }

    /// Captures one final frame if significant unscrolled tail remains when finishing recording.
    public func finalizeLiveCapture(lastPixelBuffer: CVPixelBuffer?, orientation: CGImagePropertyOrientation, keyframesFolder: URL) {
        if let buffer = lastPixelBuffer, abs(accumulatedDeltaY) > 24 {
            let rawCI = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let overlap = max(0, Int(rawCI.extent.height - abs(accumulatedDeltaY)))
            saveKeyframe(ciImage: rawCI, folder: keyframesFolder, deltaY: accumulatedDeltaY, isMatch: true, overlap: overlap)
            accumulatedDeltaY = 0
        }
    }

    private func recordIdleFrame() {
        sameFrameCount += 1
        if !isScrollIdle && sameFrameCount >= config.idleFrameThreshold {
            isScrollIdle = true
            onScrollIdle?()
        }
    }

    private func saveKeyframe(
        ciImage: CIImage,
        folder: URL,
        deltaY: CGFloat,
        isMatch: Bool,
        overlap: Int = 0
    ) {
        let fileName = String(format: "kf_%04d.jpg", keyframeIndex)
        let destURL = folder.appendingPathComponent(fileName)
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        writeJPEG(cgImage: cg, to: destURL, quality: 0.94)

        let item = VideoMatchItem(
            index: keyframeIndex,
            frameIndex: frameIndex,
            totalOffset: totalOffset,
            overlapHeight: overlap,
            isMatch: isMatch,
            keyframeFileName: fileName
        )
        matchItems.append(item)
        keyframeIndex += 1
    }

    private func writeJPEG(cgImage: CGImage, to url: URL, quality: CGFloat) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Offline Video Extraction & Stitching (Main App)

    /// Extracts representative frames across a trimmed video range and runs full overlap detection.
    public static func extractKeyframes(
        from asset: AVAsset,
        timeRange: CMTimeRange,
        sampleFPS: Double = 3.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CGImage] {
        let durationSeconds = max(0.2, CMTimeGetSeconds(timeRange.duration))
        let totalSamples = max(2, min(120, Int((durationSeconds * sampleFPS).rounded())))
        let startSeconds = CMTimeGetSeconds(timeRange.start)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        var rawFrames: [CGImage] = []
        rawFrames.reserveCapacity(totalSamples)

        for i in 0..<totalSamples {
            let t = startSeconds + (Double(i) / Double(max(1, totalSamples - 1))) * durationSeconds
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: cmTime) {
                rawFrames.append(cgImage)
            }
            progress?(Double(i + 1) / Double(totalSamples) * 0.65)
        }

        guard rawFrames.count >= 2 else { return rawFrames }

        // Prune redundant static/nearly-identical frames while preserving meaningful scroll steps.
        let detector = OverlapDetector()
        var selected: [CGImage] = [rawFrames[0]]
        for idx in 1..<rawFrames.count {
            guard let last = selected.last else { break }
            let candidate = rawFrames[idx]
            let match = detector.detectVerticalOverlap(topImage: last, bottomImage: candidate)
            let contentH = max(1, candidate.height - match.botCropTop)
            let overlapRatio = Double(match.overlapPixels) / Double(candidate.height)

            // Keep frame if it scrolled at least ~18% or reached the final frame with non-zero advance
            let isLast = idx == rawFrames.count - 1
            if !match.isMatched || overlapRatio < 0.82 || (isLast && contentH > 32 && overlapRatio < 0.96) {
                selected.append(candidate)
            }
            progress?(0.65 + Double(idx + 1) / Double(rawFrames.count) * 0.35)
        }

        return selected
    }
}
