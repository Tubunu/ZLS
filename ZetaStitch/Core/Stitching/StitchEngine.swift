import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public struct RenderedSlice: Identifiable {
    public let id: Int
    public let image: CGImage
    public let originalSize: CGSize
    public let cropTop: Int
    public let cropBottom: Int
    public let scrollbarRegions: [ScrollbarRegion]
}

public struct StitchPlanSummary: Equatable {
    public let totalWidth: Int
    public let totalHeight: Int
    public let unmatchedSeamIndices: [Int]
    public let detectedScrollbarCount: Int
}

public final class StitchEngine {
    private let detector: OverlapDetector
    private let scrollbarProcessor: ScrollbarProcessor

    public init(
        detector: OverlapDetector = OverlapDetector(),
        scrollbarProcessor: ScrollbarProcessor = .shared
    ) {
        self.detector = detector
        self.scrollbarProcessor = scrollbarProcessor
    }

    public func detectScrollbars(in images: [CGImage]) async -> [[ScrollbarRegion]] {
        guard !images.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, [ScrollbarRegion]).self) { group in
            for (idx, img) in images.enumerated() {
                group.addTask {
                    (idx, ScrollbarDetector.detectScrollbars(in: img))
                }
            }
            var result = Array(repeating: [ScrollbarRegion](), count: images.count)
            for await (idx, regs) in group {
                result[idx] = regs
            }
            return result
        }
    }

    public func buildInitialPlan(
        images: [CGImage],
        mode: StitchMode,
        autoTrimStaticBars: Bool
    ) async -> (seams: [StitchSeam], scrollbars: [[ScrollbarRegion]]) {
        guard images.count >= 1 else { return ([], []) }

        let detectorConfig = OverlapDetectionConfig(autoTrimStaticBars: autoTrimStaticBars)
        let localDetector = OverlapDetector(config: detectorConfig)

        async let scrollbarsTask = detectScrollbars(in: images)

        if images.count == 1 {
            let sb = await scrollbarsTask
            return ([], sb)
        }

        if mode == .longStitch {
            let seams = await withTaskGroup(of: (Int, StitchSeam).self) { group in
                for i in 0..<(images.count - 1) {
                    let top = images[i]
                    let bot = images[i + 1]
                    group.addTask {
                        let res = localDetector.detectVerticalOverlap(topImage: top, bottomImage: bot)
                        return (i, res.toSeam(topIndex: i))
                    }
                }
                var out = (0..<(images.count - 1)).map { StitchSeam(topIndex: $0, status: .noMatch) }
                for await (idx, seam) in group {
                    out[idx] = seam
                }
                return out
            }
            let sb = await scrollbarsTask
            return (seams, sb)
        } else {
            let seams = (0..<(images.count - 1)).map {
                StitchSeam(topIndex: $0, topCropBottom: 0, botCropTop: 0, overlapHeight: 0, status: .manual)
            }
            let sb = await scrollbarsTask
            return (seams, sb)
        }
    }

    public func computeCanvasGeometry(
        images: [CGImage],
        seams: [StitchSeam],
        mode: StitchMode,
        spacing: Int = 0
    ) -> (width: Int, height: Int, slices: [(cropRect: CGRect, drawSize: CGSize)]) {
        guard !images.isEmpty else { return (0, 0, []) }

        switch mode {
        case .longStitch, .vertical:
            let targetWidth = images[0].width
            var slices: [(CGRect, CGSize)] = []
            var totalHeight = 0

            for (i, img) in images.enumerated() {
                let trimTop = i > 0 && i - 1 < seams.count ? seams[i - 1].botCropTop : 0
                let trimBot = i < seams.count ? seams[i].topCropBottom : 0
                let clampedTop = max(0, min(trimTop, img.height - 2))
                let clampedBot = max(0, min(trimBot, img.height - clampedTop - 1))
                let visibleH = max(1, img.height - clampedTop - clampedBot)

                let scale = Double(targetWidth) / Double(max(1, img.width))
                let drawH = max(1, Int((Double(visibleH) * scale).rounded()))
                slices.append((
                    CGRect(x: 0, y: clampedTop, width: img.width, height: visibleH),
                    CGSize(width: targetWidth, height: drawH)
                ))
                totalHeight += drawH
                if i < images.count - 1 && mode == .vertical {
                    totalHeight += max(0, spacing)
                }
            }
            return (targetWidth, max(1, totalHeight), slices)

        case .horizontal:
            let targetHeight = images[0].height
            var slices: [(CGRect, CGSize)] = []
            var totalWidth = 0

            for (i, img) in images.enumerated() {
                let trimLeft = i > 0 && i - 1 < seams.count ? seams[i - 1].botCropTop : 0
                let trimRight = i < seams.count ? seams[i].topCropBottom : 0
                let clampedLeft = max(0, min(trimLeft, img.width - 2))
                let clampedRight = max(0, min(trimRight, img.width - clampedLeft - 1))
                let visibleW = max(1, img.width - clampedLeft - clampedRight)

                let scale = Double(targetHeight) / Double(max(1, img.height))
                let drawW = max(1, Int((Double(visibleW) * scale).rounded()))
                slices.append((
                    CGRect(x: clampedLeft, y: 0, width: visibleW, height: img.height),
                    CGSize(width: drawW, height: targetHeight)
                ))
                totalWidth += drawW
                if i < images.count - 1 {
                    totalWidth += max(0, spacing)
                }
            }
            return (max(1, totalWidth), targetHeight, slices)
        }
    }

    public func renderStitchedImage(
        images: [CGImage],
        seams: [StitchSeam],
        scrollbars: [[ScrollbarRegion]],
        mode: StitchMode,
        removeScrollbars: Bool,
        crop: NormalizedCropRect = .full,
        resolution: ExportResolution = .original,
        spacing: Int = 0
    ) -> CGImage? {
        guard !images.isEmpty else { return nil }

        // Optionally clean scrollbars per source screenshot before slicing/compositing.
        let processedImages: [CGImage]
        if removeScrollbars {
            processedImages = images.enumerated().map { idx, img in
                let regs = idx < scrollbars.count ? scrollbars[idx] : []
                return regs.isEmpty ? img : scrollbarProcessor.removeScrollbars(from: img, regions: regs)
            }
        } else {
            processedImages = images
        }

        let geometry = computeCanvasGeometry(
            images: processedImages,
            seams: seams,
            mode: mode,
            spacing: spacing
        )

        guard geometry.width > 0, geometry.height > 0 else { return nil }

        // Determine output scale factor from ExportResolution + hard safety pixel cap (~80MP)
        var outputScale: Double = 1.0
        if let maxShort = resolution.maxShortSide {
            let currentShort = Double(min(geometry.width, geometry.height))
            if currentShort > maxShort {
                outputScale = maxShort / currentShort
            }
        }
        let maxPixels = 80_000_000.0
        let estPixels = Double(geometry.width) * Double(geometry.height) * outputScale * outputScale
        if estPixels > maxPixels {
            outputScale *= sqrt(maxPixels / estPixels)
        }

        let outW = max(1, Int((Double(geometry.width) * outputScale).rounded()))
        let outH = max(1, Int((Double(geometry.height) * outputScale).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: outW,
            height: outH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))

        switch mode {
        case .longStitch, .vertical:
            var cursorTopY = 0.0
            let gap = mode == .vertical ? Double(max(0, spacing)) * outputScale : 0.0
            for (idx, slice) in geometry.slices.enumerated() {
                guard let sub = processedImages[idx].cropping(to: slice.cropRect) else { continue }
                let drawW = Double(outW)
                let drawH = Double(slice.drawSize.height) * outputScale
                let cgY = Double(outH) - cursorTopY - drawH
                ctx.draw(sub, in: CGRect(x: 0, y: cgY, width: drawW, height: drawH))
                cursorTopY += drawH + gap
            }

        case .horizontal:
            var cursorX = 0.0
            let gap = Double(max(0, spacing)) * outputScale
            for (idx, slice) in geometry.slices.enumerated() {
                guard let sub = processedImages[idx].cropping(to: slice.cropRect) else { continue }
                let drawW = Double(slice.drawSize.width) * outputScale
                let drawH = Double(outH)
                ctx.draw(sub, in: CGRect(x: cursorX, y: 0, width: drawW, height: drawH))
                cursorX += drawW + gap
            }
        }

        guard let fullImage = ctx.makeImage() else { return nil }
        if crop.isFull {
            return fullImage
        }
        let pxRect = crop.pixelRect(for: CGSize(width: fullImage.width, height: fullImage.height))
        return fullImage.cropping(to: pxRect) ?? fullImage
    }

    public static func encodeImage(_ image: CGImage, format: ExportFormat, quality: CGFloat = 0.92) -> Data? {
        let utType: UTType
        switch format {
        case .png: utType = .png
        case .heic: utType = .heic
        case .jpeg: utType = .jpeg
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, utType.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if format != .png {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return nil
        }
        return mutableData as Data
    }
}
