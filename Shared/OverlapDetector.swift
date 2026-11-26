import Foundation
import CoreGraphics
import CoreImage
import Vision

public struct OverlapDetectionConfig: Sendable {
    public var autoTrimStaticBars: Bool
    public var minOverlapRatio: Double
    public var maxOverlapRatio: Double
    public var maxNormalizedMAD: Double
    public var ignoreRightScrollbarFraction: Double

    public init(
        autoTrimStaticBars: Bool = true,
        minOverlapRatio: Double = 0.04,
        maxOverlapRatio: Double = 0.92,
        maxNormalizedMAD: Double = 14.0,
        ignoreRightScrollbarFraction: Double = 0.07
    ) {
        self.autoTrimStaticBars = autoTrimStaticBars
        self.minOverlapRatio = minOverlapRatio
        self.maxOverlapRatio = maxOverlapRatio
        self.maxNormalizedMAD = maxNormalizedMAD
        self.ignoreRightScrollbarFraction = ignoreRightScrollbarFraction
    }
}

public struct OverlapResult: Equatable, Sendable {
    public let topCropBottom: Int
    public let botCropTop: Int
    public let overlapPixels: Int
    public let confidence: Double
    public let isMatched: Bool

    public func toSeam(topIndex: Int) -> StitchSeam {
        StitchSeam(
            topIndex: topIndex,
            topCropBottom: topCropBottom,
            botCropTop: botCropTop,
            overlapHeight: overlapPixels,
            status: isMatched ? .matched(confidence: confidence) : .noMatch
        )
    }
}

public final class OverlapDetector: @unchecked Sendable {
    private let config: OverlapDetectionConfig

    public init(config: OverlapDetectionConfig = OverlapDetectionConfig()) {
        self.config = config
    }

    /// Detects the vertical overlap and static header/footer trims between two consecutive screenshots.
    public func detectVerticalOverlap(topImage: CGImage, bottomImage: CGImage) -> OverlapResult {
        let topW = topImage.width
        let topH = topImage.height
        let botW = bottomImage.width
        let botH = bottomImage.height

        guard topW > 16, topH > 32, botW > 16, botH > 32 else {
            return OverlapResult(topCropBottom: 0, botCropTop: 0, overlapPixels: 0, confidence: 0, isMatched: false)
        }

        // Normalize both images into compact grayscale buffers for fast coarse alignment.
        let sampleW = min(240, min(topW, botW))
        let topScale = Double(sampleW) / Double(topW)
        let botScale = Double(sampleW) / Double(botW)
        let sampleTopH = max(32, Int((Double(topH) * topScale).rounded()))
        let sampleBotH = max(32, Int((Double(botH) * botScale).rounded()))

        guard let topLuma = renderGrayscaleBytes(image: topImage, width: sampleW, height: sampleTopH),
              let botLuma = renderGrayscaleBytes(image: bottomImage, width: sampleW, height: sampleBotH) else {
            return OverlapResult(topCropBottom: 0, botCropTop: 0, overlapPixels: 0, confidence: 0, isMatched: false)
        }

        // Ignore left 3% and rightmost scrollbar strip when comparing rows.
        let compareMinX = max(0, Int(Double(sampleW) * 0.03))
        let compareMaxX = max(compareMinX + 16, Int(Double(sampleW) * (1.0 - config.ignoreRightScrollbarFraction)))

        let (staticHeaderSample, staticFooterSample) = config.autoTrimStaticBars
            ? detectStaticHeaderAndFooter(
                top: topLuma, topH: sampleTopH,
                bot: botLuma, botH: sampleBotH,
                stride: sampleW,
                xStart: compareMinX,
                xEnd: compareMaxX
            )
            : (0, 0)

        let topContentEnd = max(staticHeaderSample + 16, sampleTopH - staticFooterSample)
        let botContentStart = min(sampleBotH - 16, staticHeaderSample)
        let topContentLen = max(16, topContentEnd - staticHeaderSample)
        let botContentLen = max(16, (sampleBotH - staticFooterSample) - botContentStart)
        let usableMinLen = min(topContentLen, botContentLen)

        let minOv = max(10, Int((Double(usableMinLen) * config.minOverlapRatio).rounded()))
        let maxOv = min(usableMinLen - 2, Int((Double(usableMinLen) * config.maxOverlapRatio).rounded()))

        guard minOv < maxOv else {
            let headerPx = Int((Double(staticHeaderSample) / botScale).rounded())
            let footerPx = Int((Double(staticFooterSample) / topScale).rounded())
            return OverlapResult(topCropBottom: footerPx, botCropTop: headerPx, overlapPixels: 0, confidence: 0, isMatched: false)
        }

        // Build 16-band signatures + row horizontal energy to penalize uniform whitespace matches.
        let bandCount = 16
        let topSig = buildRowSignatures(luma: topLuma, width: sampleW, height: sampleTopH, xStart: compareMinX, xEnd: compareMaxX, bands: bandCount)
        let botSig = buildRowSignatures(luma: botLuma, width: sampleW, height: sampleBotH, xStart: compareMinX, xEnd: compareMaxX, bands: bandCount)

        struct Candidate {
            let ov: Int
            let score: Double
        }

        var coarseCandidates: [Candidate] = []
        coarseCandidates.reserveCapacity(16)

        for ov in minOv...maxOv {
            let topStartRow = topContentEnd - ov
            var madSum = 0.0
            var activeRows = 0
            var totalEnergy = 0.0

            for r in 0..<ov {
                let tr = topStartRow + r
                let br = botContentStart + r
                let tEnergy = topSig.energies[tr]
                let bEnergy = botSig.energies[br]
                let rowE = 0.5 * (tEnergy + bEnergy)
                totalEnergy += rowE
                if rowE > 2.5 {
                    activeRows += 1
                }

                let tBase = tr * bandCount
                let bBase = br * bandCount
                var rowDiff = 0
                for b in 0..<bandCount {
                    rowDiff += abs(Int(topSig.bands[tBase + b]) - Int(botSig.bands[bBase + b]))
                }
                madSum += Double(rowDiff) / Double(bandCount)
            }

            // Require meaningful visual detail so blank white/solid regions don't falsely match.
            let minTexturedRows = max(3, ov / 8)
            guard activeRows >= minTexturedRows || totalEnergy / Double(ov) > 3.5 else {
                continue
            }

            let meanMAD = madSum / Double(ov)
            // Small reward for richer overlap length when two overlaps have near-equal low MAD.
            let lengthBonus = min(1.8, Double(ov) / Double(usableMinLen) * 1.5)
            let effectiveScore = meanMAD - lengthBonus
            coarseCandidates.append(Candidate(ov: ov, score: effectiveScore))
        }

        coarseCandidates.sort { $0.score < $1.score }

        // Evaluate top non-overlapping coarse candidates with full-pixel comparison.
        var selectedOffsets: [Int] = []
        for cand in coarseCandidates {
            if selectedOffsets.allSatisfy({ abs($0 - cand.ov) > 4 }) {
                selectedOffsets.append(cand.ov)
                if selectedOffsets.count >= 8 { break }
            }
        }

        var bestSampleOv = 0
        var bestPixelMAD = Double.greatestFiniteMagnitude

        for ov in selectedOffsets {
            let topStartRow = topContentEnd - ov
            var diffSum: Int64 = 0
            var pixelCount: Int64 = 0
            for r in 0..<ov {
                let tOffset = (topStartRow + r) * sampleW
                let bOffset = (botContentStart + r) * sampleW
                for x in compareMinX..<compareMaxX {
                    diffSum += Int64(abs(Int(topLuma[tOffset + x]) - Int(botLuma[bOffset + x])))
                }
                pixelCount += Int64(compareMaxX - compareMinX)
            }
            let mad = Double(diffSum) / Double(max(1, pixelCount))
            if mad < bestPixelMAD {
                bestPixelMAD = mad
                bestSampleOv = ov
            }
        }

        // Convert sample coordinates to native pixel coordinates and refine locally.
        var nativeFooterTrim = Int((Double(staticFooterSample) / topScale).rounded())
        var nativeHeaderTrim = Int((Double(staticHeaderSample) / botScale).rounded())
        var nativeOverlap = Int((Double(bestSampleOv) / botScale).rounded())

        if bestSampleOv > 0, bestPixelMAD <= config.maxNormalizedMAD * 1.4 {
            let searchRadius = max(4, Int((2.5 / botScale).rounded()))
            let refined = refineAtFullResolution(
                topImage: topImage,
                bottomImage: bottomImage,
                topFooterTrim: nativeFooterTrim,
                botHeaderTrim: nativeHeaderTrim,
                approxOverlap: nativeOverlap,
                searchRadius: searchRadius
            )
            nativeOverlap = refined.overlap
            if refined.mad < bestPixelMAD {
                bestPixelMAD = refined.mad
            }
        }

        // Vision translational fallback when coarse matching was uncertain.
        if (bestSampleOv == 0 || bestPixelMAD > config.maxNormalizedMAD),
           let visionMatch = detectWithVision(
               topImage: topImage,
               bottomImage: bottomImage,
               topHeaderTrim: nativeHeaderTrim,
               topFooterTrim: nativeFooterTrim
           ) {
            return visionMatch
        }

        let isMatched = bestSampleOv > 0 && bestPixelMAD <= config.maxNormalizedMAD
        let confidence = isMatched
            ? max(0.0, min(1.0, 1.0 - (bestPixelMAD / (config.maxNormalizedMAD * 1.5))))
            : 0.0

        if !isMatched {
            // Preserve static bar trims even if overlap couldn't be determined reliably.
            nativeFooterTrim = min(nativeFooterTrim, topH / 4)
            nativeHeaderTrim = min(nativeHeaderTrim, botH / 4)
            return OverlapResult(
                topCropBottom: nativeFooterTrim,
                botCropTop: nativeHeaderTrim,
                overlapPixels: 0,
                confidence: confidence,
                isMatched: false
            )
        }

        let clampedOverlap = max(0, min(nativeOverlap, botH - nativeHeaderTrim - 1))
        return OverlapResult(
            topCropBottom: nativeFooterTrim,
            botCropTop: nativeHeaderTrim + clampedOverlap,
            overlapPixels: clampedOverlap,
            confidence: confidence,
            isMatched: true
        )
    }

    // MARK: - Helpers

    private func detectStaticHeaderAndFooter(
        top: [UInt8], topH: Int,
        bot: [UInt8], botH: Int,
        stride: Int,
        xStart: Int,
        xEnd: Int
    ) -> (header: Int, footer: Int) {
        let minH = min(topH, botH)
        let maxHeader = Int(Double(minH) * 0.22)
        let maxFooter = Int(Double(minH) * 0.18)
        let span = max(1, xEnd - xStart)

        var headerRows = 0
        var lastTexturedHeader = 0
        for y in 0..<maxHeader {
            let rowOff = y * stride
            var diff = 0
            var prev = Int(top[rowOff + xStart])
            var rowGrad = 0
            for x in xStart..<xEnd {
                let tv = Int(top[rowOff + x])
                let bv = Int(bot[rowOff + x])
                diff += abs(tv - bv)
                rowGrad += abs(tv - prev)
                prev = tv
            }
            let mad = Double(diff) / Double(span)
            let meanGrad = Double(rowGrad) / Double(span)
            if mad <= 3.2 {
                headerRows = y + 1
                if meanGrad > 2.0 {
                    lastTexturedHeader = headerRows
                }
            } else {
                break
            }
        }
        // Only trim header up to the last textured static element (e.g. status bar + fixed nav bar)
        // plus 1px cushion so scrolled whitespace isn't swallowed as static chrome.
        let finalHeader = lastTexturedHeader > 0 ? min(headerRows, lastTexturedHeader + 2) : 0

        var footerRows = 0
        var lastTexturedFooter = 0
        for offset in 0..<maxFooter {
            let ty = topH - 1 - offset
            let by = botH - 1 - offset
            let tOff = ty * stride
            let bOff = by * stride
            var diff = 0
            var prev = Int(top[tOff + xStart])
            var rowGrad = 0
            for x in xStart..<xEnd {
                let tv = Int(top[tOff + x])
                let bv = Int(bot[bOff + x])
                diff += abs(tv - bv)
                rowGrad += abs(tv - prev)
                prev = tv
            }
            let mad = Double(diff) / Double(span)
            let meanGrad = Double(rowGrad) / Double(span)
            if mad <= 3.2 {
                footerRows = offset + 1
                if meanGrad > 2.0 {
                    lastTexturedFooter = footerRows
                }
            } else {
                break
            }
        }
        let finalFooter = lastTexturedFooter > 0 ? min(footerRows, lastTexturedFooter + 2) : 0

        return (finalHeader, finalFooter)
    }

    private struct RowSignatures {
        let bands: [UInt8]
        let energies: [Double]
    }

    private func buildRowSignatures(
        luma: [UInt8],
        width: Int,
        height: Int,
        xStart: Int,
        xEnd: Int,
        bands: Int
    ) -> RowSignatures {
        var bandValues = [UInt8](repeating: 0, count: height * bands)
        var energies = [Double](repeating: 0, count: height)
        let activeW = max(1, xEnd - xStart)

        for y in 0..<height {
            let rowOff = y * width
            var rowGradSum = 0
            var prevPix = Int(luma[rowOff + xStart])

            for b in 0..<bands {
                let bx0 = xStart + (b * activeW) / bands
                let bx1 = max(bx0 + 1, xStart + ((b + 1) * activeW) / bands)
                var sum = 0
                for x in bx0..<bx1 {
                    let v = Int(luma[rowOff + x])
                    sum += v
                    rowGradSum += abs(v - prevPix)
                    prevPix = v
                }
                bandValues[y * bands + b] = UInt8(sum / (bx1 - bx0))
            }
            energies[y] = Double(rowGradSum) / Double(activeW)
        }
        return RowSignatures(bands: bandValues, energies: energies)
    }

    private func refineAtFullResolution(
        topImage: CGImage,
        bottomImage: CGImage,
        topFooterTrim: Int,
        botHeaderTrim: Int,
        approxOverlap: Int,
        searchRadius: Int
    ) -> (overlap: Int, mad: Double) {
        let width = min(topImage.width, bottomImage.width)
        let topH = topImage.height
        let botH = bottomImage.height

        let minOv = max(8, approxOverlap - searchRadius)
        let maxOv = min(min(topH - topFooterTrim, botH - botHeaderTrim) - 1, approxOverlap + searchRadius)
        guard minOv <= maxOv else { return (approxOverlap, Double.greatestFiniteMagnitude) }

        // Crop just the candidate strips at native height (width capped at 600px for crispness + speed).
        let evalW = min(600, width)
        let xStart = Int(Double(evalW) * 0.04)
        let xEnd = max(xStart + 16, Int(Double(evalW) * (1.0 - config.ignoreRightScrollbarFraction)))

        let topStripH = min(topH - topFooterTrim, maxOv + 4)
        let topStripY = max(0, topH - topFooterTrim - topStripH)
        let botStripH = min(botH - botHeaderTrim, maxOv + 4)
        let botStripY = botHeaderTrim

        guard let topCrop = topImage.cropping(to: CGRect(x: 0, y: topStripY, width: width, height: topStripH)),
              let botCrop = bottomImage.cropping(to: CGRect(x: 0, y: botStripY, width: width, height: botStripH)),
              let topBytes = renderGrayscaleBytes(image: topCrop, width: evalW, height: topStripH),
              let botBytes = renderGrayscaleBytes(image: botCrop, width: evalW, height: botStripH) else {
            return (approxOverlap, Double.greatestFiniteMagnitude)
        }

        var bestOv = approxOverlap
        var bestMAD = Double.greatestFiniteMagnitude
        let span = Int64(max(1, xEnd - xStart))

        for ov in minOv...maxOv {
            let tBaseRow = topStripH - ov
            guard tBaseRow >= 0, ov <= botStripH else { continue }
            var diffSum: Int64 = 0
            // Sample up to 64 evenly distributed rows across the overlap for native 1px precision.
            let step = max(1, ov / 64)
            var sampledRows: Int64 = 0
            var r = 0
            while r < ov {
                let tOff = (tBaseRow + r) * evalW
                let bOff = r * evalW
                for x in xStart..<xEnd {
                    diffSum += Int64(abs(Int(topBytes[tOff + x]) - Int(botBytes[bOff + x])))
                }
                sampledRows += 1
                r += step
            }
            let mad = Double(diffSum) / Double(max(1, sampledRows * span))
            if mad < bestMAD {
                bestMAD = mad
                bestOv = ov
            }
        }
        return (bestOv, bestMAD)
    }

    private func detectWithVision(
        topImage: CGImage,
        bottomImage: CGImage,
        topHeaderTrim: Int,
        topFooterTrim: Int
    ) -> OverlapResult? {
        let topROI = CGRect(
            x: 0,
            y: topHeaderTrim,
            width: topImage.width,
            height: max(32, topImage.height - topHeaderTrim - topFooterTrim)
        )
        let botROI = CGRect(
            x: 0,
            y: topHeaderTrim,
            width: bottomImage.width,
            height: max(32, bottomImage.height - topHeaderTrim - topFooterTrim)
        )

        guard let topCrop = topImage.cropping(to: topROI),
              let botCrop = bottomImage.cropping(to: botROI) else {
            return nil
        }

        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: botCrop)
        let handler = VNImageRequestHandler(cgImage: topCrop, options: [:])
        do {
            try handler.perform([request])
            guard let observation = request.results?.first as? VNImageTranslationAlignmentObservation else {
                return nil
            }
            // In Vision coordinates, positive ty indicates upward shift of content when scrolling down.
            let dy = observation.alignmentTransform.ty
            let contentH = topCrop.height
            // Overlap exists when bottom image scrolled down by `scrollDelta` < contentH
            let scrollDelta = Int(abs(dy).rounded())
            let overlap = contentH - scrollDelta
            guard overlap > 24, overlap < Int(Double(contentH) * 0.94), abs(observation.alignmentTransform.tx) < 16 else {
                return nil
            }
            return OverlapResult(
                topCropBottom: topFooterTrim,
                botCropTop: topHeaderTrim + overlap,
                overlapPixels: overlap,
                confidence: 0.72,
                isMatched: true
            )
        } catch {
            return nil
        }
    }

    private func renderGrayscaleBytes(image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }
}
