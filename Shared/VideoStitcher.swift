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

        // Crop out top status/navigation chrome (16%), bottom tab/home area (16%),
        // and side margins / scrollbar (10%) so registration measures pure scrollable page motion.
        let roi = CGRect(
            x: extent.minX + extent.width * 0.08,
            y: extent.minY + extent.height * 0.16,
            width: extent.width * 0.82,
            height: extent.height * 0.68
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

    /// Result of extracting representative video frames together with optical-tracked, pixel-refined seams.
    public struct VideoStitchExtractionResult: Sendable {
        public let images: [CGImage]
        public let seams: [StitchSeam]

        public init(images: [CGImage], seams: [StitchSeam]) {
            self.images = images
            self.seams = seams
        }
    }

    /// Extracts representative frames across a trimmed video range via sequential `AVAssetReader` decoding,
    /// ROI Vision optical flow tracking, and pixel-level overlap refinement.
    public static func extractKeyframes(
        from asset: AVAsset,
        timeRange: CMTimeRange,
        sampleFPS: Double = 24.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [CGImage] {
        let result = try await extractStitchResult(
            from: asset,
            timeRange: timeRange,
            targetFPS: sampleFPS,
            progress: progress
        )
        return result.images
    }

    /// Streams sequential video frames with `AVAssetReader`, tracks cumulative scroll displacement
    /// inside the inner scrollable viewport using `VNTranslationalImageRegistrationRequest`, selects
    /// evenly spaced forward keyframes (ignoring pauses & end-of-scroll bounceback), and refines every
    /// seam at 1:1 native pixel resolution using `OverlapDetector`.
    public static func extractStitchResult(
        from asset: AVAsset,
        timeRange: CMTimeRange,
        targetFPS: Double = 24.0,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> VideoStitchExtractionResult {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            return VideoStitchExtractionResult(images: [], seams: [])
        }

        let assetDuration = try await asset.load(.duration)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let orientation = orientation(from: preferredTransform)

        let totalSec = max(0.05, CMTimeGetSeconds(assetDuration))
        let rawStart = CMTimeGetSeconds(timeRange.start)
        let rawEnd = CMTimeGetSeconds(timeRange.end)
        let startSec = max(0.0, min(totalSec - 0.05, rawStart.isFinite ? rawStart : 0.0))
        let endSec = min(totalSec, max(startSec + 0.05, rawEnd.isFinite ? rawEnd : totalSec))
        let effectiveDuration = max(0.05, endSec - startSec)
        let effectiveRange = CMTimeRange(
            start: CMTime(seconds: startSec, preferredTimescale: 600),
            end: CMTime(seconds: endSec, preferredTimescale: 600)
        )

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = effectiveRange

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(trackOutput) else {
            return VideoStitchExtractionResult(images: [], seams: [])
        }
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw reader.error ?? NSError(
                domain: "com.zeta.stitch.video",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start AVAssetReader"]
            )
        }

        let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        let sequenceHandler = VNSequenceRequestHandler()
        let minSampleInterval = 1.0 / max(12.0, min(30.0, targetFPS))

        struct RawKeyframe {
            let image: CGImage
            let stepFromPrev: Double
        }

        var keyframes: [RawKeyframe] = []
        var prevTrackedBuffer: CVPixelBuffer?
        var prevTrackedPTS: Double = -.greatestFiniteMagnitude
        var lastConsideredPTS: Double = -.greatestFiniteMagnitude

        var orientedSize: CGSize = .zero
        var usableH: Double = 0
        var stepPixels: Double = 360

        var signedCumOffset: Double = 0
        var dominantSign: Double = 0
        var peakForwardOffset: Double = 0
        var lastCapturedForwardOffset: Double = 0
        var peakBuffer: CVPixelBuffer?
        var fallbackLastBuffer: CVPixelBuffer?

        // Inner scrollable viewport ROI (cuts status/nav top 20%, tab/home bottom 20%, left/right 14% including scrollbar).
        let scrollROI = CGRect(x: 0.14, y: 0.20, width: 0.72, height: 0.60)

        while reader.status == .reading {
            let sample = autoreleasepool { trackOutput.copyNextSampleBuffer() }
            guard let sampleBuffer = sample else { break }

            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if pts.isFinite && (pts - lastConsideredPTS) < minSampleInterval && prevTrackedBuffer != nil {
                continue
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
            lastConsideredPTS = pts.isFinite ? pts : lastConsideredPTS

            if orientedSize == .zero {
                let rawW = Double(CVPixelBufferGetWidth(pixelBuffer))
                let rawH = Double(CVPixelBufferGetHeight(pixelBuffer))
                let swapsAxes = orientation == .left || orientation == .right
                    || orientation == .leftMirrored || orientation == .rightMirrored
                orientedSize = CGSize(width: swapsAxes ? rawH : rawW, height: swapsAxes ? rawW : rawH)
                usableH = max(64.0, orientedSize.height * 0.78)
                stepPixels = max(72.0, usableH * 0.42)
            }

            fallbackLastBuffer = pixelBuffer

            guard let refBuf = prevTrackedBuffer else {
                prevTrackedBuffer = pixelBuffer
                prevTrackedPTS = pts.isFinite ? pts : startSec
                peakBuffer = pixelBuffer
                if let cg = renderCGImage(from: pixelBuffer, orientation: orientation, ciContext: ciContext) {
                    keyframes.append(RawKeyframe(image: cg, stepFromPrev: 0))
                }
                if pts.isFinite {
                    let frac = min(1.0, max(0.0, (pts - startSec) / effectiveDuration))
                    progress?(frac * 0.65)
                }
                continue
            }

            // Fast interior luma MAD check so totally stationary pause frames don't trigger redundant Vision work,
            // while still keeping `refBuf` pinned until real scroll displacement accumulates.
            let elapsedSinceTracked = pts.isFinite ? (pts - prevTrackedPTS) : minSampleInterval
            let lumaDiff = interiorLumaDiff(refBuf, pixelBuffer)
            if lumaDiff < 1.15 && elapsedSinceTracked < 0.28 {
                continue
            }

            var dyPixels: Double?
            autoreleasepool {
                let request = VNTranslationalImageRegistrationRequest(
                    targetedCVPixelBuffer: refBuf,
                    orientation: orientation,
                    options: [:]
                )
                request.regionOfInterest = scrollROI
                do {
                    try sequenceHandler.perform([request], on: pixelBuffer, orientation: orientation)
                    if let obs = request.results?.first as? VNImageTranslationAlignmentObservation {
                        let tx = Double(obs.alignmentTransform.tx)
                        let ty = Double(obs.alignmentTransform.ty)
                        if abs(tx) <= orientedSize.width * 0.085 && abs(ty) <= usableH * 0.85 {
                            dyPixels = ty
                        }
                    }
                } catch {
                    dyPixels = nil
                }
            }

            prevTrackedBuffer = pixelBuffer
            if pts.isFinite {
                prevTrackedPTS = pts
                let frac = min(1.0, max(0.0, (pts - startSec) / effectiveDuration))
                progress?(frac * 0.65)
            }

            guard let ty = dyPixels else {
                // If scene changed dramatically without clean Vision translation, capture a visual checkpoint.
                if lumaDiff >= 8.0,
                   let cg = renderCGImage(from: pixelBuffer, orientation: orientation, ciContext: ciContext) {
                    keyframes.append(RawKeyframe(image: cg, stepFromPrev: stepPixels))
                    lastCapturedForwardOffset = peakForwardOffset
                }
                continue
            }

            if abs(ty) < 0.6 {
                continue
            }

            signedCumOffset += ty
            if dominantSign == 0, abs(signedCumOffset) >= max(24.0, usableH * 0.04) {
                dominantSign = signedCumOffset >= 0 ? 1.0 : -1.0
            }

            let forwardPos = dominantSign != 0 ? (signedCumOffset * dominantSign) : abs(signedCumOffset)
            if forwardPos >= peakForwardOffset {
                peakForwardOffset = forwardPos
                peakBuffer = pixelBuffer

                let delta = peakForwardOffset - lastCapturedForwardOffset
                if delta >= stepPixels {
                    if let cg = renderCGImage(from: pixelBuffer, orientation: orientation, ciContext: ciContext) {
                        keyframes.append(RawKeyframe(image: cg, stepFromPrev: delta))
                        lastCapturedForwardOffset = peakForwardOffset
                    }
                }
            }
        }

        // Capture final forward scroll tail (or fallback last frame if scroll occurred cleanly at end).
        let remainingTail = peakForwardOffset - lastCapturedForwardOffset
        let tailBuffer = remainingTail >= max(24.0, usableH * 0.08)
            ? peakBuffer
            : (keyframes.count == 1 ? fallbackLastBuffer : nil)
        if let finalBuf = tailBuffer,
           let cg = renderCGImage(from: finalBuf, orientation: orientation, ciContext: ciContext) {
            let step = max(24.0, remainingTail)
            // Avoid exact duplicate of initial keyframe if video never scrolled at all.
            if keyframes.count > 1 || interiorMADBetweenCGImages(keyframes.first?.image, cg) >= 2.0 {
                keyframes.append(RawKeyframe(image: cg, stepFromPrev: step))
            }
        }

        if reader.status == .reading {
            reader.cancelReading()
        }

        guard keyframes.count >= 2 else {
            progress?(1.0)
            return VideoStitchExtractionResult(images: keyframes.map(\.image), seams: [])
        }

        let detector = OverlapDetector(
            config: OverlapDetectionConfig(
                autoTrimStaticBars: true,
                minOverlapRatio: 0.04,
                maxOverlapRatio: 0.94,
                maxNormalizedMAD: 0.068,
                ignoreRightScrollbarFraction: 0.07
            )
        )

        let initialChrome = OverlapDetector.detectChromeHeights(
            topImage: keyframes[0].image,
            bottomImage: keyframes[keyframes.count - 1].image,
            ignoreRightScrollbarFraction: 0.07
        )
        let initialUsableH = max(
            32,
            keyframes[0].image.height - initialChrome.headerRows - initialChrome.footerRows
        )

        // Confirm whether `keyframes[0]` is visually above `keyframes[1]` or user scrolled upward.
        if keyframes.count >= 2 {
            let first = keyframes[0].image
            let second = keyframes[1].image
            let fwdHint = max(20, min(initialUsableH - 8, initialUsableH - Int(keyframes[1].stepFromPrev.rounded())))
            let forwardRes = detector.detectVerticalOverlap(
                topImage: first,
                bottomImage: second,
                expectedOverlapHint: fwdHint,
                searchRadius: max(140, Int(Double(first.height) * 0.22))
            )
            let reverseRes = detector.detectVerticalOverlap(
                topImage: second,
                bottomImage: first,
                expectedOverlapHint: fwdHint,
                searchRadius: max(140, Int(Double(first.height) * 0.22))
            )
            if reverseRes.isMatched && (!forwardRes.isMatched || reverseRes.confidence > forwardRes.confidence + 0.12) {
                let revImages = Array(keyframes.map(\.image).reversed())
                var revSteps = Array(repeating: 0.0, count: revImages.count)
                for idx in 1..<revImages.count {
                    revSteps[idx] = keyframes[keyframes.count - idx].stepFromPrev
                }
                keyframes = zip(revImages, revSteps).map { RawKeyframe(image: $0.0, stepFromPrev: $0.1) }
            }
        }

        var finalImages = keyframes.map(\.image)
        var finalSeams: [StitchSeam] = []
        finalSeams.reserveCapacity(finalImages.count - 1)

        // Refine every pair's seam around the tracked scroll displacement.
        for i in 0..<(finalImages.count - 1) {
            let topImg = finalImages[i]
            let botImg = finalImages[i + 1]
            let step = keyframes[i + 1].stepFromPrev
            let pairUsableH = max(
                32,
                topImg.height - initialChrome.headerRows - initialChrome.footerRows
            )
            let hint = step > 8
                ? max(20, min(pairUsableH - 8, pairUsableH - Int(step.rounded())))
                : nil

            let result = detector.detectVerticalOverlap(
                topImage: topImg,
                bottomImage: botImg,
                expectedOverlapHint: hint,
                searchRadius: max(120, Int(Double(topImg.height) * 0.20)),
                forcedHeaderRows: initialChrome.headerRows > 0 ? initialChrome.headerRows : nil,
                forcedFooterRows: initialChrome.footerRows > 0 ? initialChrome.footerRows : nil
            )

            if result.isMatched {
                finalSeams.append(result.toSeam(topIndex: i))
            } else if step > 16, step < Double(topImg.height) * 0.92 {
                // Optical-tracking fallback for heavy motion blur / video fade transitions.
                let botCut = min(botImg.height - 8, max(result.botCropTop, topImg.height - result.topCropBottom - Int(step.rounded())))
                let fallbackOverlap = max(24, botCut - initialChrome.headerRows)
                finalSeams.append(StitchSeam(
                    topIndex: i,
                    topCropBottom: result.topCropBottom,
                    botCropTop: botCut,
                    overlapHeight: fallbackOverlap,
                    status: .matched(confidence: 0.50)
                ))
            } else {
                finalSeams.append(result.toSeam(topIndex: i))
            }

            progress?(0.65 + Double(i + 1) / Double(max(1, finalImages.count - 1)) * 0.35)
        }

        // Prune degenerate zero-advance transitions cleanly if two consecutive frames snapped nearly 0px apart.
        if finalSeams.count >= 2 {
            var kept: [RawKeyframe] = [keyframes[0]]
            var skippedStep = 0.0
            for idx in 0..<finalSeams.count {
                let seam = finalSeams[idx]
                let remaining = finalImages[idx + 1].height - seam.botCropTop - initialChrome.footerRows
                skippedStep += keyframes[idx + 1].stepFromPrev
                if remaining >= 24 || idx == finalSeams.count - 1 {
                    kept.append(RawKeyframe(image: finalImages[idx + 1], stepFromPrev: skippedStep))
                    skippedStep = 0.0
                }
            }
            if kept.count < finalImages.count && kept.count >= 2 {
                finalImages = kept.map(\.image)
                finalSeams = (0..<(finalImages.count - 1)).map { idx in
                    let step = kept[idx + 1].stepFromPrev
                    let hint = max(20, initialUsableH - Int(step.rounded()))
                    return detector.detectVerticalOverlap(
                        topImage: finalImages[idx],
                        bottomImage: finalImages[idx + 1],
                        expectedOverlapHint: hint,
                        searchRadius: max(120, Int(Double(finalImages[idx].height) * 0.20)),
                        forcedHeaderRows: initialChrome.headerRows > 0 ? initialChrome.headerRows : nil,
                        forcedFooterRows: initialChrome.footerRows > 0 ? initialChrome.footerRows : nil
                    ).toSeam(topIndex: idx)
                }
            }
        }

        progress?(1.0)
        return VideoStitchExtractionResult(images: finalImages, seams: finalSeams)
    }

    // MARK: - AVAssetReader Helpers

    private static func orientation(from t: CGAffineTransform) -> CGImagePropertyOrientation {
        let angle = atan2(t.b, t.a)
        if abs(angle - .pi / 2) < 0.15 {
            return .right
        } else if abs(angle + .pi / 2) < 0.15 {
            return .left
        } else if abs(abs(angle) - .pi) < 0.15 {
            return .down
        } else {
            return .up
        }
    }

    private static func renderCGImage(
        from pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        ciContext: CIContext
    ) -> CGImage? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
        let originFixed = ci.transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
        return ciContext.createCGImage(originFixed, from: CGRect(origin: .zero, size: originFixed.extent.size))
    }

    private static func interiorLumaDiff(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Double {
        let w = min(CVPixelBufferGetWidth(lhs), CVPixelBufferGetWidth(rhs))
        let h = min(CVPixelBufferGetHeight(lhs), CVPixelBufferGetHeight(rhs))
        guard w >= 32, h >= 32 else { return 255.0 }

        CVPixelBufferLockBaseAddress(lhs, .readOnly)
        CVPixelBufferLockBaseAddress(rhs, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
            CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
        }

        guard let baseL = CVPixelBufferGetBaseAddress(lhs)?.assumingMemoryBound(to: UInt8.self),
              let baseR = CVPixelBufferGetBaseAddress(rhs)?.assumingMemoryBound(to: UInt8.self) else {
            return 255.0
        }

        let bprL = CVPixelBufferGetBytesPerRow(lhs)
        let bprR = CVPixelBufferGetBytesPerRow(rhs)
        let x0 = Int(Double(w) * 0.18)
        let x1 = Int(Double(w) * 0.82)
        let y0 = Int(Double(h) * 0.22)
        let y1 = Int(Double(h) * 0.78)
        let stepX = max(4, (x1 - x0) / 36)
        let stepY = max(4, (y1 - y0) / 48)

        var diffSum = 0
        var count = 0
        var y = y0
        while y < y1 {
            let rowL = baseL.advanced(by: y * bprL)
            let rowR = baseR.advanced(by: y * bprR)
            var x = x0
            while x < x1 {
                let off = x * 4
                let lL = (Int(rowL[off]) + 4 * Int(rowL[off + 1]) + 2 * Int(rowL[off + 2])) >> 3
                let lR = (Int(rowR[off]) + 4 * Int(rowR[off + 1]) + 2 * Int(rowR[off + 2])) >> 3
                diffSum += abs(lL - lR)
                count += 1
                x += stepX
            }
            y += stepY
        }
        return count > 0 ? Double(diffSum) / Double(count) : 255.0
    }

    private static func interiorMADBetweenCGImages(_ lhs: CGImage?, _ rhs: CGImage) -> Double {
        guard let lhs, lhs.width == rhs.width, lhs.height == rhs.height else { return 255.0 }
        let w = min(64, lhs.width)
        let h = min(64, lhs.height)
        guard w >= 8, h >= 8 else {
            return 255.0
        }
        let cs = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
        var bufL = [UInt8](repeating: 0, count: w * h)
        var bufR = [UInt8](repeating: 0, count: w * h)
        let okL = bufL.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(lhs, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        let okR = bufR.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(rhs, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard okL && okR else { return 255.0 }
        var sum = 0
        for i in 0..<(w * h) {
            sum += abs(Int(bufL[i]) - Int(bufR[i]))
        }
        return Double(sum) / Double(w * h)
    }
}
