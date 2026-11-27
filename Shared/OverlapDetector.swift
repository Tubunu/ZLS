import Foundation
import CoreGraphics
import Accelerate
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
        maxOverlapRatio: Double = 0.90,
        maxNormalizedMAD: Double = 0.045,
        ignoreRightScrollbarFraction: Double = 0.06
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
            overlapHeight: isMatched ? overlapPixels : 0,
            status: isMatched ? .matched(confidence: confidence) : .noMatch
        )
    }
}

/// Native-height grayscale perceptual bit-hash + trimmed-MAD vertical overlap detector.
///
/// Mirrors the reverse-engineered `PixelHashMerger` architecture (native vertical resolution,
/// horizontal stride sampling, per-row mean bit-hash DP, blank/uniform row differentiation,
/// and status-bar/Dynamic-Island chrome tolerance) enhanced with trimmed-column pixel MAD
/// verification so floating buttons, corner badges, dark mode, and H.264 video frames align
/// cleanly down to 1px.
public final class OverlapDetector: @unchecked Sendable {
    private let config: OverlapDetectionConfig

    public init(config: OverlapDetectionConfig = OverlapDetectionConfig()) {
        self.config = config
    }

    /// Estimates static top header and bottom footer row counts shared between two frames.
    public static func detectChromeHeights(
        topImage: CGImage,
        bottomImage: CGImage,
        ignoreRightScrollbarFraction: Double = 0.06
    ) -> (headerRows: Int, footerRows: Int) {
        guard topImage.width == bottomImage.width,
              topImage.width >= 24,
              topImage.height >= 48,
              bottomImage.height >= 48,
              let topGray = GrayBitmap.render(image: topImage),
              let botGray = GrayBitmap.render(image: bottomImage) else {
            return (0, 0)
        }
        let workW = topGray.width
        let leftSkip = workW >= 120 ? min(Int((Double(workW) * 0.025).rounded()), 28) : 0
        let rightSkip = workW >= 120
            ? max(Int((Double(workW) * ignoreRightScrollbarFraction).rounded()), leftSkip)
            : 0
        let xStart = leftSkip
        let xEnd = max(xStart + 16, workW - rightSkip)
        let chrome = detectStaticChrome(top: topGray, bottom: botGray, xStart: xStart, xEnd: xEnd)
        return (chrome.headerRows, chrome.footerRows)
    }

    public func detectVerticalOverlap(topImage: CGImage, bottomImage: CGImage) -> OverlapResult {
        detectVerticalOverlap(
            topImage: topImage,
            bottomImage: bottomImage,
            expectedOverlapHint: nil,
            searchRadius: 72,
            forcedHeaderRows: nil,
            forcedFooterRows: nil
        )
    }

    public func detectVerticalOverlap(
        topImage: CGImage,
        bottomImage: CGImage,
        expectedOverlapHint: Int?,
        searchRadius: Int = 72,
        forcedHeaderRows: Int? = nil,
        forcedFooterRows: Int? = nil
    ) -> OverlapResult {
        let origTopW = topImage.width
        let origTopH = topImage.height
        let origBotW = bottomImage.width
        let origBotH = bottomImage.height

        guard origTopW >= 24, origTopH >= 48, origBotW >= 24, origBotH >= 48 else {
            return OverlapResult(topCropBottom: 0, botCropTop: 0, overlapPixels: 0, confidence: 0, isMatched: false)
        }

        let botScaleY: Double
        let scaledBot: CGImage
        if origBotW == origTopW {
            scaledBot = bottomImage
            botScaleY = 1.0
        } else {
            let targetBotH = max(48, Int((Double(origBotH) * Double(origTopW) / Double(origBotW)).rounded()))
            guard let resampled = Self.resizeCGImage(bottomImage, toWidth: origTopW, height: targetBotH) else {
                return OverlapResult(topCropBottom: 0, botCropTop: 0, overlapPixels: 0, confidence: 0, isMatched: false)
            }
            scaledBot = resampled
            botScaleY = Double(origBotH) / Double(targetBotH)
        }

        guard let topGray = GrayBitmap.render(image: topImage),
              let botGray = GrayBitmap.render(image: scaledBot) else {
            return OverlapResult(topCropBottom: 0, botCropTop: 0, overlapPixels: 0, confidence: 0, isMatched: false)
        }

        let workW = topGray.width
        let topH = topGray.height
        let workBotH = botGray.height

        let leftSkip = workW >= 120 ? min(Int((Double(workW) * 0.025).rounded()), 28) : 0
        let rightSkip = workW >= 120
            ? max(Int((Double(workW) * config.ignoreRightScrollbarFraction).rounded()), leftSkip)
            : 0
        let xStart = leftSkip
        let xEnd = max(xStart + 16, workW - rightSkip)

        let minH = min(topH, workBotH)

        // Determine static top & bottom chrome even when autoTrimStaticBars is disabled so we never
        // lock onto a repeating navigation bar or tab bar at identical Y coordinates.
        let detectedChrome = Self.detectStaticChrome(
            top: topGray,
            bottom: botGray,
            xStart: xStart,
            xEnd: xEnd
        )
        let headerRows = min(max(0, forcedHeaderRows ?? detectedChrome.headerRows), minH / 2)
        let footerRows = min(max(0, forcedFooterRows ?? detectedChrome.footerRows), minH / 2)

        let topWinStart = headerRows
        let topWinEnd = max(topWinStart, topH - footerRows)
        let botWinStart = headerRows
        let botWinEnd = max(botWinStart, workBotH - footerRows)

        let topContentH = topWinEnd - topWinStart
        let botContentH = botWinEnd - botWinStart
        let usableMinH = min(topContentH, botContentH)

        let staticFooterOrigBot = config.autoTrimStaticBars
            ? Int((Double(footerRows) * botScaleY).rounded())
            : 0
        let staticHeaderOrigBot = config.autoTrimStaticBars
            ? Int((Double(headerRows) * botScaleY).rounded())
            : 0

        guard usableMinH >= 32 else {
            return OverlapResult(
                topCropBottom: config.autoTrimStaticBars ? footerRows : 0,
                botCropTop: staticHeaderOrigBot,
                overlapPixels: 0,
                confidence: 0,
                isMatched: false
            )
        }

        let topHashes = RowSignatureTable.build(bitmap: topGray, xStart: xStart, xEnd: xEnd)
        let botHashes = RowSignatureTable.build(bitmap: botGray, xStart: xStart, xEnd: xEnd)

        let minOverlap = max(20, Int((Double(usableMinH) * config.minOverlapRatio).rounded()))
        let maxOverlap = min(
            usableMinH - 4,
            max(minOverlap + 8, Int((Double(usableMinH) * config.maxOverlapRatio).rounded()))
        )

        var candidates: [OverlapCandidate] = []
        candidates.reserveCapacity(64)

        // 0. If caller provided an optical-tracking overlap hint (Video mode), fast-rank lags with row signatures,
        // then run full-res verification only on top candidates around the hint.
        if let hintWork = expectedOverlapHint.map({ Int((Double($0) / max(botScaleY, 0.001)).rounded()) }),
           hintWork >= 16 {
            let lo = max(16, hintWork - searchRadius)
            let hi = min(usableMinH, hintWork + searchRadius)
            let lagBase = topWinEnd - botWinStart

            var scoredOv: [(ov: Int, diff: Double)] = []
            scoredOv.reserveCapacity(max(1, hi - lo + 1))
            for ov in lo...hi {
                let sTop = topWinEnd - ov
                let sBot = botWinStart
                let span = min(ov, min(topWinEnd - sTop, botWinEnd - sBot))
                guard span >= 16 else { continue }
                let rowStep = span > 240 ? 3 : 2
                var err = 0.0
                var cnt = 0
                var k = 0
                while k < span {
                    let ts = topHashes.rows[sTop + k]
                    let bs = botHashes.rows[sBot + k]
                    err += Double(abs(Int(ts.mean) - Int(bs.mean)) + abs(Int(ts.edgeMean) - Int(bs.edgeMean)))
                    cnt += 1
                    k += rowStep
                }
                if cnt > 0 {
                    scoredOv.append((ov, err / Double(cnt)))
                }
            }
            scoredOv.sort { $0.diff < $1.diff }

            var testedHintLags = Set<Int>()
            var bestGuidedMatch: VerifiedOverlap?
            for item in scoredOv.prefix(8) {
                for delta in -2...2 {
                    let lag = lagBase - (item.ov + delta)
                    if !testedHintLags.insert(lag).inserted { continue }
                    if let verified = verifyLag(
                        lag: lag,
                        top: topGray,
                        bot: botGray,
                        topSigs: topHashes,
                        botSigs: botHashes,
                        xStart: xStart,
                        xEnd: xEnd,
                        topWinStart: topWinStart,
                        topWinEnd: topWinEnd,
                        botWinStart: botWinStart,
                        botWinEnd: botWinEnd,
                        minOverlap: max(16, min(minOverlap, hintWork - 8)),
                        maxOverlap: min(usableMinH, hintWork + searchRadius)
                    ) {
                        if bestGuidedMatch == nil || verified.score > bestGuidedMatch!.score {
                            bestGuidedMatch = verified
                        }
                    }
                }
            }
            if let guided = bestGuidedMatch,
               guided.normalizedMAD <= max(config.maxNormalizedMAD, 0.06),
               guided.confidence >= 0.45 {
                return finalizeResult(
                    verified: guided,
                    top: topGray,
                    bot: botGray,
                    xStart: xStart,
                    xEnd: xEnd,
                    topH: topH,
                    origBotH: origBotH,
                    botScaleY: botScaleY,
                    minBotExpandY: detectedChrome.headerCoreRows,
                    maxTopExpandY: topH - detectedChrome.footerCoreRows,
                    headerRows: headerRows,
                    footerRows: footerRows,
                    staticHeaderOrigBot: staticHeaderOrigBot
                )
            }
        }

        // 1. Primary Engine: Native-height Perceptual Bit-Hash 2D DP (PixelHashMerger).
        let dpCandidates = findBitHashDPCandidates(
            topSigs: topHashes,
            botSigs: botHashes,
            topWinStart: topWinStart,
            topWinEnd: topWinEnd,
            botWinStart: botWinStart,
            botWinEnd: botWinEnd,
            minOverlap: minOverlap,
            maxOverlap: maxOverlap,
            headerDetected: headerRows > 0 || footerRows > 0
        )
        candidates.append(contentsOf: dpCandidates)

        // 2. Complementary Engine: Vertical Row-Mean + Horizontal-Edge Gradient Projection.
        // Handles low-contrast gradients, dark themes, and soft cards where rowMean thresholding flips bits.
        let projCandidates = findGradientProjectionCandidates(
            topSigs: topHashes,
            botSigs: botHashes,
            topWinStart: topWinStart,
            topWinEnd: topWinEnd,
            botWinStart: botWinStart,
            botWinEnd: botWinEnd,
            minOverlap: minOverlap,
            maxOverlap: maxOverlap,
            headerDetected: headerRows > 0 || footerRows > 0
        )
        candidates.append(contentsOf: projCandidates)

        var bestVerified = evaluateCandidates(
            candidates,
            top: topGray,
            bot: botGray,
            topSigs: topHashes,
            botSigs: botHashes,
            xStart: xStart,
            xEnd: xEnd,
            topWinStart: topWinStart,
            topWinEnd: topWinEnd,
            botWinStart: botWinStart,
            botWinEnd: botWinEnd,
            minOverlap: minOverlap,
            maxOverlap: maxOverlap
        )

        // 3. Fallback Engine: Scrolled Interior ROI Vision Translational Registration + Native Verification.
        let acceptThreshold = max(config.maxNormalizedMAD, 0.055)
        if bestVerified == nil || bestVerified!.normalizedMAD > acceptThreshold || bestVerified!.confidence < 0.35 {
            let visionCandidates = visionROICandidates(
                topImage: topImage,
                botImage: scaledBot,
                topH: topH,
                workBotH: workBotH,
                xStart: xStart,
                xEnd: xEnd,
                topWinStart: topWinStart,
                topWinEnd: topWinEnd,
                botWinStart: botWinStart,
                botWinEnd: botWinEnd
            )
            if !visionCandidates.isEmpty,
               let visionVerified = evaluateCandidates(
                   visionCandidates,
                   top: topGray,
                   bot: botGray,
                   topSigs: topHashes,
                   botSigs: botHashes,
                   xStart: xStart,
                   xEnd: xEnd,
                   topWinStart: topWinStart,
                   topWinEnd: topWinEnd,
                   botWinStart: botWinStart,
                   botWinEnd: botWinEnd,
                   minOverlap: minOverlap,
                   maxOverlap: maxOverlap
               ) {
                if bestVerified == nil || visionVerified.score > bestVerified!.score {
                    bestVerified = visionVerified
                }
            }
        }

        if let winner = bestVerified,
           winner.normalizedMAD <= max(config.maxNormalizedMAD, 0.058),
           winner.overlapLen >= minOverlap {
            return finalizeResult(
                verified: winner,
                top: topGray,
                bot: botGray,
                xStart: xStart,
                xEnd: xEnd,
                topH: topH,
                origBotH: origBotH,
                botScaleY: botScaleY,
                minBotExpandY: detectedChrome.headerCoreRows,
                maxTopExpandY: topH - detectedChrome.footerCoreRows,
                headerRows: headerRows,
                footerRows: footerRows,
                staticHeaderOrigBot: staticHeaderOrigBot
            )
        }

        _ = staticFooterOrigBot
        return OverlapResult(
            topCropBottom: config.autoTrimStaticBars ? footerRows : 0,
            botCropTop: staticHeaderOrigBot,
            overlapPixels: 0,
            confidence: 0,
            isMatched: false
        )
    }

    private func finalizeResult(
        verified: VerifiedOverlap,
        top: GrayBitmap,
        bot: GrayBitmap,
        xStart: Int,
        xEnd: Int,
        topH: Int,
        origBotH: Int,
        botScaleY: Double,
        minBotExpandY: Int,
        maxTopExpandY: Int,
        headerRows: Int,
        footerRows: Int,
        staticHeaderOrigBot: Int
    ) -> OverlapResult {
        // Recover any post-divider / pre-divider blank margin rows that happen to match
        // pixel-for-pixel at the winning scroll lag.
        var expandedStartBot = verified.startBot
        var expandedEndTop = verified.endTop
        var expandedEndBot = verified.endBot
        var expandedOverlap = verified.overlapLen
        let lag = verified.lag

        let activeW = max(1, xEnd - xStart)
        let colStep = max(1, activeW / 96)

        func pairRowMatches(topY: Int, botY: Int) -> Bool {
            guard topY >= 0, topY < top.height, botY >= 0, botY < bot.height else { return false }
            let tBase = topY * top.width + xStart
            let bBase = botY * bot.width + xStart
            var count = 0
            var close = 0
            var inlierSum = 0
            var inlierCount = 0
            var x = 0
            while x < activeW {
                let d = abs(Int(top.pixels[tBase + x]) - Int(bot.pixels[bBase + x]))
                if d <= 12 { close += 1 }
                if d <= 30 {
                    inlierSum += d
                    inlierCount += 1
                }
                count += 1
                x += colStep
            }
            let frac = Double(close) / Double(max(1, count))
            let mad = inlierCount > 0 ? Double(inlierSum) / Double(inlierCount) : 255.0
            return frac >= 0.88 && mad <= 9.0
        }

        let upFloor = max(0, max(minBotExpandY, expandedStartBot - 128))
        var stepsUp = 0
        while expandedStartBot > upFloor && stepsUp < 128 {
            let nextBot = expandedStartBot - 1
            let nextTop = nextBot + lag
            guard pairRowMatches(topY: nextTop, botY: nextBot) else { break }
            expandedStartBot = nextBot
            expandedOverlap += 1
            stepsUp += 1
        }

        let downCeiling = min(topH, min(maxTopExpandY, expandedEndTop + 128))
        var stepsDown = 0
        while expandedEndTop < downCeiling && expandedEndBot < bot.height && stepsDown < 128 {
            let nextTop = expandedEndTop
            let nextBot = expandedEndBot
            guard pairRowMatches(topY: nextTop, botY: nextBot) else { break }
            expandedEndTop += 1
            expandedEndBot += 1
            expandedOverlap += 1
            stepsDown += 1
        }

        _ = headerRows
        _ = footerRows
        _ = staticHeaderOrigBot

        let topCropBottom = max(0, topH - expandedEndTop)
        let scaledBotCropTop = min(origBotH - 1, max(0, Int((Double(expandedEndBot) * botScaleY).rounded())))
        let scaledOverlap = max(1, Int((Double(expandedOverlap) * botScaleY).rounded()))

        return OverlapResult(
            topCropBottom: topCropBottom,
            botCropTop: scaledBotCropTop,
            overlapPixels: scaledOverlap,
            confidence: verified.confidence,
            isMatched: true
        )
    }

    // MARK: - Grayscale Bitmap Rendering (1:1 Native Row Resolution)

    private struct GrayBitmap {
        let width: Int
        let height: Int
        let pixels: [UInt8] // row-major, row 0 = visual top

        static func render(image: CGImage) -> GrayBitmap? {
            let w = image.width
            let h = image.height
            guard w > 0, h > 0 else { return nil }
            let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2) ?? CGColorSpaceCreateDeviceGray()
            var data = [UInt8](repeating: 0, count: w * h)
            let ok = data.withUnsafeMutableBytes { buf -> Bool in
                guard let base = buf.baseAddress,
                      let ctx = CGContext(
                          data: base,
                          width: w,
                          height: h,
                          bitsPerComponent: 8,
                          bytesPerRow: w,
                          space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.none.rawValue
                      ) else {
                    return false
                }
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            return ok ? GrayBitmap(width: w, height: h, pixels: data) : nil
        }
    }

    private static func resizeCGImage(_ image: CGImage, toWidth width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    // MARK: - Per-Row Perceptual Bit-Hash & Gradient Signatures

    private struct RowSig {
        let w0: UInt64
        let w1: UInt64
        let w2: UInt64
        let popCount: UInt16
        let mean: UInt8
        let range: UInt8
        let edgeMean: UInt8
        let edgeSum: Int32
        let isBlank: Bool
    }

    private struct RowSignatureTable {
        let rows: [RowSig]
        let bitCount: Int

        static func build(bitmap: GrayBitmap, xStart: Int, xEnd: Int) -> RowSignatureTable {
            let activeW = max(1, xEnd - xStart)
            var stride = max(2, activeW / 192)
            while ((activeW + stride - 1) / stride) > 192 {
                stride += 1
            }
            let sampleCount = max(1, (activeW + stride - 1) / stride)
            var result: [RowSig] = []
            result.reserveCapacity(bitmap.height)

            var samples = [Int](repeating: 0, count: sampleCount)
            bitmap.pixels.withUnsafeBufferPointer { px in
                let w = bitmap.width
                for y in 0..<bitmap.height {
                    let rowBase = y * w + xStart
                    var sum = 0
                    var minV = 255
                    var maxV = 0
                    var diffSum = 0
                    var smallDiffs = 0
                    var prevV = Int(px[rowBase])

                    var sIdx = 0
                    var x = 0
                    while x < activeW && sIdx < sampleCount {
                        let v = Int(px[rowBase + x])
                        samples[sIdx] = v
                        sum += v
                        if v < minV { minV = v }
                        if v > maxV { maxV = v }
                        if sIdx > 0 {
                            let d = abs(v - prevV)
                            diffSum += d
                            if d <= 9 { smallDiffs += 1 }
                        }
                        prevV = v
                        sIdx += 1
                        x += stride
                    }

                    let count = max(1, sIdx)
                    let meanInt = sum / count
                    let rangeInt = maxV - minV

                    var w0: UInt64 = 0
                    var w1: UInt64 = 0
                    var w2: UInt64 = 0
                    for b in 0..<count {
                        if samples[b] >= meanInt {
                            if b < 64 {
                                w0 |= (UInt64(1) << b)
                            } else if b < 128 {
                                w1 |= (UInt64(1) << (b - 64))
                            } else {
                                w2 |= (UInt64(1) << (b - 128))
                            }
                        }
                    }

                    let pop = UInt16(w0.nonzeroBitCount + w1.nonzeroBitCount + w2.nonzeroBitCount)
                    let isBlank = rangeInt <= 14 || (count > 8 && Double(smallDiffs) / Double(count - 1) >= 0.96 && rangeInt <= 18)
                    let edgeMeanInt = count > 1 ? min(255, diffSum / (count - 1)) : 0

                    result.append(RowSig(
                        w0: w0,
                        w1: w1,
                        w2: w2,
                        popCount: pop,
                        mean: UInt8(clamping: meanInt),
                        range: UInt8(clamping: rangeInt),
                        edgeMean: UInt8(clamping: edgeMeanInt),
                        edgeSum: Int32(diffSum),
                        isBlank: isBlank
                    ))
                }
            }

            return RowSignatureTable(rows: result, bitCount: sampleCount)
        }
    }

    // MARK: - Tolerant Static Chrome Detection (Status Bar + Dynamic Island + Nav/Tab Bar)

    private struct StaticChrome {
        let headerRows: Int
        let footerRows: Int
        let headerCoreRows: Int
        let footerCoreRows: Int
    }

    private static func detectStaticChrome(
        top: GrayBitmap,
        bottom: GrayBitmap,
        xStart: Int,
        xEnd: Int
    ) -> StaticChrome {
        let minH = min(top.height, bottom.height)
        let maxHeader = min(Int(Double(minH) * 0.28), max(0, minH - 64))
        let maxFooter = min(Int(Double(minH) * 0.22), max(0, minH - 64))
        let colStep = max(1, (xEnd - xStart) / 96)

        func rowMatchesAt(_ topY: Int, _ botY: Int) -> (matches: Bool, textured: Bool, mean: Int) {
            let tBase = topY * top.width
            let bBase = botY * bottom.width
            var total = 0
            var close = 0
            var sum = 0
            var minT = 255
            var maxT = 0
            var minB = 255
            var maxB = 0
            var x = xStart
            while x < xEnd {
                let tv = Int(top.pixels[tBase + x])
                let bv = Int(bottom.pixels[bBase + x])
                sum += (tv + bv) >> 1
                if tv < minT { minT = tv }
                if tv > maxT { maxT = tv }
                if bv < minB { minB = bv }
                if bv > maxB { maxB = bv }
                if abs(tv - bv) <= 10 {
                    close += 1
                }
                total += 1
                x += colStep
            }
            let frac = total > 0 ? Double(close) / Double(total) : 0
            let textured = (maxT - minT) > 16 || (maxB - minB) > 16
            return (frac >= 0.96, textured, total > 0 ? sum / total : 0)
        }

        func hasFullWidthStep(topY1: Int, topY2: Int, botY1: Int, botY2: Int) -> Bool {
            guard topY1 >= 0, topY1 < top.height, topY2 >= 0, topY2 < top.height,
                  botY1 >= 0, botY1 < bottom.height, botY2 >= 0, botY2 < bottom.height else {
                return false
            }
            let tBase1 = topY1 * top.width
            let tBase2 = topY2 * top.width
            let bBase1 = botY1 * bottom.width
            let bBase2 = botY2 * bottom.width
            var total = 0
            var bothStepped = 0
            var x = xStart
            while x < xEnd {
                let dt = abs(Int(top.pixels[tBase1 + x]) - Int(top.pixels[tBase2 + x]))
                let db = abs(Int(bottom.pixels[bBase1 + x]) - Int(bottom.pixels[bBase2 + x]))
                if dt >= 18 && db >= 18 {
                    bothStepped += 1
                }
                total += 1
                x += colStep
            }
            return total > 0 && Double(bothStepped) / Double(total) >= 0.70
        }

        // Top scan: tolerate clock / battery / Dynamic Island changes ONLY in top ~9.5%, and ONLY bridge
        // when structured static chrome (non-blank nav bar / icon / divider) resumes below the clock.
        let statusBandY = min(maxHeader, max(44, Int(Double(minH) * 0.095)))
        let clockGap = max(36, Int(Double(minH) * 0.055))

        var matchFlags = [Bool](repeating: false, count: maxHeader)
        var texFlags = [Bool](repeating: false, count: maxHeader)
        var means = [Int](repeating: 0, count: maxHeader)
        for y in 0..<maxHeader {
            let r = rowMatchesAt(y, y)
            matchFlags[y] = r.matches
            texFlags[y] = r.textured
            means[y] = r.mean
        }

        var headerRows = 0
        var headerCoreRows = 0
        if maxHeader > 0 {
            var y = 0
            var lastMatchY = -1
            var lastTexChromeY = -1
            var anyDiffInsideHeader = false
            var anyTexturedMatch = false
            var anyDividerInChrome = false

            while y < maxHeader {
                if matchFlags[y] {
                    lastMatchY = y
                    if texFlags[y] {
                        anyTexturedMatch = true
                        lastTexChromeY = y
                    } else if y > 0 && matchFlags[y - 1] && abs(means[y] - means[y - 1]) >= 12 {
                        anyDividerInChrome = true
                    }
                    y += 1
                } else {
                    anyDiffInsideHeader = true
                    guard lastMatchY >= 8, y < statusBandY else { break }
                    var resumeY: Int?
                    var consecTex = 0
                    var consecMatch = 0
                    let preGapMean = means[lastMatchY]
                    let lookEnd = min(maxHeader, y + clockGap + 40)
                    for k in y..<lookEnd {
                        if matchFlags[k] {
                            consecMatch += 1
                            let isDividerStep = abs(means[k] - preGapMean) >= 10
                                || (k > 0 && abs(means[k] - means[k - 1]) >= 10)
                            if texFlags[k] || isDividerStep { consecTex += 1 }
                            if consecTex >= 2 && consecMatch >= 4 {
                                var startRun = k
                                while startRun > y && matchFlags[startRun - 1] {
                                    startRun -= 1
                                }
                                resumeY = startRun
                                break
                            }
                        } else {
                            consecTex = 0
                            consecMatch = 0
                        }
                    }
                    if let resume = resumeY, (resume - y) <= clockGap {
                        anyDividerInChrome = true
                        y = resume
                    } else {
                        break
                    }
                }
            }

            if lastMatchY >= 0 {
                let isBoundaryBar = hasFullWidthStep(
                    topY1: lastMatchY,
                    topY2: lastMatchY + 1,
                    botY1: lastMatchY,
                    botY2: lastMatchY + 1
                )
                let reachedLimitWithoutDiff = (!anyDiffInsideHeader && lastMatchY >= maxHeader - 2)
                if (!anyTexturedMatch && !anyDividerInChrome && !isBoundaryBar) || (reachedLimitWithoutDiff && !anyTexturedMatch) {
                    headerRows = 0
                    headerCoreRows = 0
                } else {
                    headerRows = lastMatchY + 1
                    headerCoreRows = (anyTexturedMatch && lastTexChromeY >= 0) ? (lastTexChromeY + 1) : 0
                }
            }
        }

        // Bottom scan: symmetric from bottom edge upward.
        var botMatchFlags = [Bool](repeating: false, count: maxFooter)
        var botTexFlags = [Bool](repeating: false, count: maxFooter)
        var botMeans = [Int](repeating: 0, count: maxFooter)
        for k in 0..<maxFooter {
            let r = rowMatchesAt(top.height - 1 - k, bottom.height - 1 - k)
            botMatchFlags[k] = r.matches
            botTexFlags[k] = r.textured
            botMeans[k] = r.mean
        }

        var footerRows = 0
        var footerCoreRows = 0
        if maxFooter > 0 {
            var k = 0
            var lastMatchK = -1
            var lastTexChromeK = -1
            var anyDiffInsideFooter = false
            var anyTexturedMatch = false
            var anyDividerInChrome = false
            let homeBandK = min(maxFooter, max(36, Int(Double(minH) * 0.08)))
            let homeGap = max(24, Int(Double(minH) * 0.03))

            while k < maxFooter {
                if botMatchFlags[k] {
                    lastMatchK = k
                    if botTexFlags[k] {
                        anyTexturedMatch = true
                        lastTexChromeK = k
                    } else if k > 0 && botMatchFlags[k - 1] && abs(botMeans[k] - botMeans[k - 1]) >= 12 {
                        anyDividerInChrome = true
                    }
                    k += 1
                } else {
                    anyDiffInsideFooter = true
                    guard lastMatchK >= 8, k < homeBandK else { break }
                    var resumeK: Int?
                    var consecTex = 0
                    var consecMatch = 0
                    let preGapMean = botMeans[lastMatchK]
                    let lookEnd = min(maxFooter, k + homeGap + 30)
                    for m in k..<lookEnd {
                        if botMatchFlags[m] {
                            consecMatch += 1
                            let isDividerStep = abs(botMeans[m] - preGapMean) >= 10
                                || (m > 0 && abs(botMeans[m] - botMeans[m - 1]) >= 10)
                            if botTexFlags[m] || isDividerStep { consecTex += 1 }
                            if consecTex >= 2 && consecMatch >= 4 {
                                var startRun = m
                                while startRun > k && botMatchFlags[startRun - 1] {
                                    startRun -= 1
                                }
                                resumeK = startRun
                                break
                            }
                        } else {
                            consecTex = 0
                            consecMatch = 0
                        }
                    }
                    if let resume = resumeK, (resume - k) <= homeGap {
                        anyDividerInChrome = true
                        k = resume
                    } else {
                        break
                    }
                }
            }

            if lastMatchK >= 0 {
                let topEdgeY = top.height - 1 - lastMatchK
                let botEdgeY = bottom.height - 1 - lastMatchK
                let isBoundaryBar = hasFullWidthStep(
                    topY1: topEdgeY,
                    topY2: topEdgeY - 1,
                    botY1: botEdgeY,
                    botY2: botEdgeY - 1
                )
                let reachedLimitWithoutDiff = (!anyDiffInsideFooter && lastMatchK >= maxFooter - 2)
                if (!anyTexturedMatch && !anyDividerInChrome && !isBoundaryBar) || (reachedLimitWithoutDiff && !anyTexturedMatch) {
                    footerRows = 0
                    footerCoreRows = 0
                } else {
                    footerRows = lastMatchK + 1
                    footerCoreRows = (anyTexturedMatch && lastTexChromeK >= 0) ? (lastTexChromeK + 1) : 0
                }
            }
        }

        return StaticChrome(
            headerRows: headerRows,
            footerRows: footerRows,
            headerCoreRows: headerCoreRows,
            footerCoreRows: footerCoreRows
        )
    }

    // MARK: - Candidate Generation 1: Bit-Hash 2D Rolling DP (PixelHashMerger)

    private struct OverlapCandidate {
        let lag: Int // topRow - botRow
        let startTop: Int
        let startBot: Int
        let approxLen: Int
        let nonBlankScore: Int
    }

    private func findBitHashDPCandidates(
        topSigs: RowSignatureTable,
        botSigs: RowSignatureTable,
        topWinStart: Int,
        topWinEnd: Int,
        botWinStart: Int,
        botWinEnd: Int,
        minOverlap: Int,
        maxOverlap: Int,
        headerDetected: Bool
    ) -> [OverlapCandidate] {
        let topN = topWinEnd - topWinStart
        let botN = botWinEnd - botWinStart
        guard topN >= minOverlap, botN >= minOverlap else { return [] }

        let maxBitDist = max(6, Int(ceil(Double(topSigs.bitCount) * 0.045)))
        let minScrollLag = headerDetected ? -min(topN, botN) : max(8, Int(Double(min(topN, botN)) * 0.015))
        let minRunToRecord = max(20, min(minOverlap, 28))

        // Best run recorded per diagonal `lag = topY - botY` (grouped into lag buckets to limit array work).
        var bestByLag: [Int: (topEnd: Int, botEnd: Int, len: Int, nonBlank: Int)] = [:]
        bestByLag.reserveCapacity(64)

        var prevLen = [Int32](repeating: 0, count: botN + 1)
        var currLen = [Int32](repeating: 0, count: botN + 1)
        var prevNonBlank = [Int32](repeating: 0, count: botN + 1)
        var currNonBlank = [Int32](repeating: 0, count: botN + 1)

        topSigs.rows.withUnsafeBufferPointer { tPtr in
            botSigs.rows.withUnsafeBufferPointer { bPtr in
                for ti in 0..<topN {
                    let topY = topWinStart + ti
                    let ts = tPtr[topY]
                    let tPop = Int(ts.popCount)
                    let tMean = Int(ts.mean)
                    let tBlank = ts.isBlank
                    let tw0 = ts.w0
                    let tw1 = ts.w1
                    let tw2 = ts.w2

                    currLen.withUnsafeMutableBufferPointer { cLen in
                        prevLen.withUnsafeBufferPointer { pLen in
                            currNonBlank.withUnsafeMutableBufferPointer { cNB in
                                prevNonBlank.withUnsafeBufferPointer { pNB in
                                    cLen[0] = 0
                                    cNB[0] = 0
                                    for bj in 0..<botN {
                                        let botY = botWinStart + bj
                                        let lag = topY - botY
                                        // Avoid static un-scrolled identity diagonal when no header/footer was trimmed.
                                        if !headerDetected && abs(lag) < minScrollLag {
                                            let oldLen = Int(pLen[bj])
                                            if oldLen >= minRunToRecord {
                                                let oldNB = Int(pNB[bj])
                                                let prevLag = lag // previous cell was (topY-1) - (botY-1) == lag
                                                if oldNB >= 4 {
                                                    if let ex = bestByLag[prevLag] {
                                                        if oldNB > ex.nonBlank || (oldNB == ex.nonBlank && oldLen > ex.len) {
                                                            bestByLag[prevLag] = (topY, botY, oldLen, oldNB)
                                                        }
                                                    } else {
                                                        bestByLag[prevLag] = (topY, botY, oldLen, oldNB)
                                                    }
                                                }
                                            }
                                            cLen[bj + 1] = 0
                                            cNB[bj + 1] = 0
                                            continue
                                        }

                                        let bs = bPtr[botY]
                                        let meanDiff = abs(tMean - Int(bs.mean))
                                        let bBlank = bs.isBlank

                                        let rowMatches: Bool
                                        let nbCredit: Int32
                                        if tBlank && bBlank {
                                            rowMatches = meanDiff <= 14
                                            nbCredit = 0
                                        } else if tBlank != bBlank {
                                            // Tolerate thin hairline difference in high-res text/edges only if mean very close
                                            rowMatches = meanDiff <= 6 && abs(Int(ts.range) - Int(bs.range)) <= 10
                                            nbCredit = 0
                                        } else {
                                            let popDiff = abs(tPop - Int(bs.popCount))
                                            if popDiff <= maxBitDist && meanDiff <= 32 {
                                                let dist = (tw0 ^ bs.w0).nonzeroBitCount
                                                    + (tw1 ^ bs.w1).nonzeroBitCount
                                                    + (tw2 ^ bs.w2).nonzeroBitCount
                                                rowMatches = dist <= maxBitDist
                                                nbCredit = rowMatches ? 1 : 0
                                            } else {
                                                rowMatches = false
                                                nbCredit = 0
                                            }
                                        }

                                        if rowMatches {
                                            cLen[bj + 1] = pLen[bj] + 1
                                            cNB[bj + 1] = pNB[bj] + nbCredit
                                        } else {
                                            let oldLen = Int(pLen[bj])
                                            if oldLen >= minRunToRecord {
                                                let oldNB = Int(pNB[bj])
                                                if oldNB >= 4 {
                                                    if let ex = bestByLag[lag] {
                                                        if oldNB > ex.nonBlank || (oldNB == ex.nonBlank && oldLen > ex.len) {
                                                            bestByLag[lag] = (topY, botY, oldLen, oldNB)
                                                        }
                                                    } else {
                                                        bestByLag[lag] = (topY, botY, oldLen, oldNB)
                                                    }
                                                }
                                            }
                                            cLen[bj + 1] = 0
                                            cNB[bj + 1] = 0
                                        }
                                    }

                                    // Flush runs reaching the right edge (bj == botN - 1 -> col botN).
                                    let endLen = Int(cLen[botN])
                                    if endLen >= minRunToRecord {
                                        let endNB = Int(cNB[botN])
                                        let lag = topY - (botWinEnd - 1)
                                        if endNB >= 4 {
                                            if let ex = bestByLag[lag] {
                                                if endNB > ex.nonBlank || (endNB == ex.nonBlank && endLen > ex.len) {
                                                    bestByLag[lag] = (topY + 1, botWinEnd, endLen, endNB)
                                                }
                                            } else {
                                                bestByLag[lag] = (topY + 1, botWinEnd, endLen, endNB)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    swap(&prevLen, &currLen)
                    swap(&prevNonBlank, &currNonBlank)
                }

                // Flush runs reaching bottom edge (ti == topN -> prevLen).
                for bj in 1...botN {
                    let endLen = Int(prevLen[bj])
                    if endLen >= minRunToRecord {
                        let endNB = Int(prevNonBlank[bj])
                        let botYEnd = botWinStart + bj
                        let lag = topWinEnd - botYEnd
                        if endNB >= 4 {
                            if let ex = bestByLag[lag] {
                                if endNB > ex.nonBlank || (endNB == ex.nonBlank && endLen > ex.len) {
                                    bestByLag[lag] = (topWinEnd, botYEnd, endLen, endNB)
                                }
                            } else {
                                bestByLag[lag] = (topWinEnd, botYEnd, endLen, endNB)
                            }
                        }
                    }
                }
            }
        }

        // Convert top DP runs into candidates, filtering completely impossible overlap lengths.
        let sorted = bestByLag.sorted { lhs, rhs in
            if lhs.value.nonBlank != rhs.value.nonBlank {
                return lhs.value.nonBlank > rhs.value.nonBlank
            }
            return lhs.value.len > rhs.value.len
        }

        var output: [OverlapCandidate] = []
        output.reserveCapacity(min(24, sorted.count))
        for (lag, info) in sorted.prefix(24) {
            // Also skip overlaps bigger than maxOverlap + small headroom
            if info.len > maxOverlap + 40 { continue }
            output.append(OverlapCandidate(
                lag: lag,
                startTop: info.topEnd - info.len,
                startBot: info.botEnd - info.len,
                approxLen: info.len,
                nonBlankScore: info.nonBlank
            ))
        }
        return output
    }

    // MARK: - Candidate Generation 2: Row Mean + Edge Energy 1D Boundary Correlation

    private func findGradientProjectionCandidates(
        topSigs: RowSignatureTable,
        botSigs: RowSignatureTable,
        topWinStart: Int,
        topWinEnd: Int,
        botWinStart: Int,
        botWinEnd: Int,
        minOverlap: Int,
        maxOverlap: Int,
        headerDetected: Bool
    ) -> [OverlapCandidate] {
        let topN = topWinEnd - topWinStart
        let botN = botWinEnd - botWinStart
        let usable = min(topN, botN)
        guard usable >= minOverlap else { return [] }

        let coarseStep = usable > 900 ? 3 : (usable > 420 ? 2 : 1)
        let rowStep = usable > 1200 ? 4 : 2

        var scored: [(lag: Int, overlap: Int, sad: Double)] = []
        scored.reserveCapacity(16)

        var overlap = minOverlap
        while overlap <= maxOverlap {
            let startTop = topWinEnd - overlap
            let startBot = botWinStart
            let lag = startTop - startBot
            if !headerDetected && abs(lag) < max(8, Int(Double(usable) * 0.015)) {
                overlap += coarseStep
                continue
            }

            var diffSum = 0.0
            var varTop = 0.0
            var count = 0
            var prevMean = Int(topSigs.rows[startTop].mean)
            var r = 0
            while r < overlap {
                let ts = topSigs.rows[startTop + r]
                let bs = botSigs.rows[startBot + r]
                let dm = abs(Int(ts.mean) - Int(bs.mean))
                let de = abs(Int(ts.edgeMean) - Int(bs.edgeMean))
                let dr = abs(Int(ts.range) - Int(bs.range))
                diffSum += Double(dm) + 0.8 * Double(de) + 0.5 * Double(dr)
                varTop += Double(abs(Int(ts.mean) - prevMean) + Int(ts.edgeMean) + Int(ts.range))
                prevMean = Int(ts.mean)
                count += 1
                r += rowStep
            }

            if count > 0, varTop / Double(count) >= 2.5 {
                let norm = diffSum / (Double(count) * 255.0)
                if norm <= 0.10 {
                    scored.append((lag, overlap, norm))
                }
            }
            overlap += coarseStep
        }

        scored.sort { $0.sad < $1.sad }
        var result: [OverlapCandidate] = []
        for entry in scored.prefix(8) {
            for delta in -coarseStep...coarseStep {
                let ov = entry.overlap + delta
                guard ov >= minOverlap && ov <= maxOverlap else { continue }
                let lag = (topWinEnd - ov) - botWinStart
                result.append(OverlapCandidate(
                    lag: lag,
                    startTop: topWinEnd - ov,
                    startBot: botWinStart,
                    approxLen: ov,
                    nonBlankScore: ov
                ))
            }
        }
        return result
    }

    // MARK: - Candidate Generation 3: Scrolled-Interior Vision Fallback

    private func visionROICandidates(
        topImage: CGImage,
        botImage: CGImage,
        topH: Int,
        workBotH: Int,
        xStart: Int,
        xEnd: Int,
        topWinStart: Int,
        topWinEnd: Int,
        botWinStart: Int,
        botWinEnd: Int
    ) -> [OverlapCandidate] {
        let roiW = max(16, xEnd - xStart)
        let topSpanH = topWinEnd - topWinStart
        let botSpanH = botWinEnd - botWinStart
        guard topSpanH >= 48, botSpanH >= 48 else { return [] }

        let topBandH = min(topSpanH, max(48, Int(Double(topSpanH) * 0.65)))
        let botBandH = min(botSpanH, max(48, Int(Double(botSpanH) * 0.65)))
        let topBandY = topWinEnd - topBandH
        let botBandY = botWinStart

        guard let topCrop = topImage.cropping(to: CGRect(x: xStart, y: topBandY, width: roiW, height: topBandH)),
              let botCrop = botImage.cropping(to: CGRect(x: xStart, y: botBandY, width: roiW, height: botBandH)) else {
            return []
        }

        let req = VNTranslationalImageRegistrationRequest(targetedCGImage: topCrop)
        let handler = VNImageRequestHandler(cgImage: botCrop, options: [:])
        do {
            try handler.perform([req])
        } catch {
            return []
        }

        guard let obs = req.results?.first as? VNImageTranslationAlignmentObservation else {
            return []
        }

        let ty = obs.alignmentTransform.ty
        let tx = obs.alignmentTransform.tx
        guard abs(tx) < Double(roiW) * 0.08, abs(ty) > 4 else { return [] }

        // Test both sign conventions of Vision translation with our native pixel verifier.
        var candidates: [OverlapCandidate] = []
        let dyRounded = Int(ty.rounded())
        for shift in [dyRounded, -dyRounded] {
            // In overlapping region: topBand[k] aligns with botBand[k - shift]
            let overlap = topBandH - shift
            if overlap >= 20, overlap <= min(topSpanH, botSpanH) {
                let lag = (topBandY + shift) - botBandY
                candidates.append(OverlapCandidate(
                    lag: lag,
                    startTop: topWinEnd - overlap,
                    startBot: botWinStart,
                    approxLen: overlap,
                    nonBlankScore: overlap
                ))
            }
        }
        return candidates
    }

    // MARK: - Full-Resolution Trimmed-Column Pixel Verification & Refinement

    private struct VerifiedOverlap {
        let lag: Int
        let startTop: Int
        let endTop: Int
        let startBot: Int
        let endBot: Int
        let overlapLen: Int
        let normalizedMAD: Double
        let nonBlankRows: Int
        let confidence: Double
        let score: Double
    }

    private func evaluateCandidates(
        _ candidates: [OverlapCandidate],
        top: GrayBitmap,
        bot: GrayBitmap,
        topSigs: RowSignatureTable,
        botSigs: RowSignatureTable,
        xStart: Int,
        xEnd: Int,
        topWinStart: Int,
        topWinEnd: Int,
        botWinStart: Int,
        botWinEnd: Int,
        minOverlap: Int,
        maxOverlap: Int
    ) -> VerifiedOverlap? {
        var testedLags = Set<Int>()
        var best: VerifiedOverlap?

        for cand in candidates {
            for dLag in -1...1 {
                let lag = cand.lag + dLag
                if !testedLags.insert(lag).inserted { continue }
                guard let verified = verifyLag(
                    lag: lag,
                    top: top,
                    bot: bot,
                    topSigs: topSigs,
                    botSigs: botSigs,
                    xStart: xStart,
                    xEnd: xEnd,
                    topWinStart: topWinStart,
                    topWinEnd: topWinEnd,
                    botWinStart: botWinStart,
                    botWinEnd: botWinEnd,
                    minOverlap: minOverlap,
                    maxOverlap: maxOverlap
                ) else {
                    continue
                }
                if best == nil || verified.score > best!.score {
                    best = verified
                }
            }
        }

        // Fine local ±3px sweep around winner to lock onto exact 1px border/text phase.
        if let seed = best {
            for delta in -3...3 where delta != 0 {
                let lag = seed.lag + delta
                if !testedLags.insert(lag).inserted { continue }
                if let finer = verifyLag(
                    lag: lag,
                    top: top,
                    bot: bot,
                    topSigs: topSigs,
                    botSigs: botSigs,
                    xStart: xStart,
                    xEnd: xEnd,
                    topWinStart: topWinStart,
                    topWinEnd: topWinEnd,
                    botWinStart: botWinStart,
                    botWinEnd: botWinEnd,
                    minOverlap: minOverlap,
                    maxOverlap: maxOverlap
                ), finer.score > best!.score {
                    best = finer
                }
            }
        }

        return best
    }

    private func verifyLag(
        lag: Int,
        top: GrayBitmap,
        bot: GrayBitmap,
        topSigs: RowSignatureTable,
        botSigs: RowSignatureTable,
        xStart: Int,
        xEnd: Int,
        topWinStart: Int,
        topWinEnd: Int,
        botWinStart: Int,
        botWinEnd: Int,
        minOverlap: Int,
        maxOverlap: Int
    ) -> VerifiedOverlap? {
        // Intersection of [topWinStart..<topWinEnd] and [botWinStart + lag ..< botWinEnd + lag]
        let sTop = max(topWinStart, botWinStart + lag)
        let eTop = min(topWinEnd, botWinEnd + lag)
        let span = eTop - sTop
        guard span >= minOverlap else { return nil }

        let activeW = max(1, xEnd - xStart)
        let mainLimitX = max(8, Int((Double(activeW) * 0.78).rounded()))
        let colStep = max(1, activeW / 96)
        let isVideoMode = config.maxNormalizedMAD > 0.055
        let tol = isVideoMode ? 22 : 14
        let minMainFrac = isVideoMode ? 0.84 : 0.92
        let maxMainMAD = isVideoMode ? 15.0 : 9.0
        let minFgFrac = isVideoMode ? 0.64 : 0.78

        var rowMatches = [Bool](repeating: false, count: span)
        var rowMADs = [Double](repeating: 255.0, count: span)

        top.pixels.withUnsafeBufferPointer { tPx in
            bot.pixels.withUnsafeBufferPointer { bPx in
                let tw = top.width
                let bw = bot.width
                for k in 0..<span {
                    let topY = sTop + k
                    let botY = topY - lag
                    let tBase = topY * tw + xStart
                    let bBase = botY * bw + xStart

                    let tBg = (Int(tPx[tBase]) + Int(tPx[tBase + activeW - 1])) >> 1
                    let bBg = (Int(bPx[bBase]) + Int(bPx[bBase + activeW - 1])) >> 1

                    var allCount = 0
                    var allClose = 0
                    var mainCount = 0
                    var mainClose = 0
                    var mainDiffSum = 0
                    var fgTotal = 0
                    var fgMatch = 0

                    var x = 0
                    while x < activeW {
                        let tv = Int(tPx[tBase + x])
                        let bv = Int(bPx[bBase + x])
                        let d = abs(tv - bv)
                        if d <= tol { allClose += 1 }
                        allCount += 1

                        if x < mainLimitX {
                            mainCount += 1
                            mainDiffSum += d
                            if d <= tol { mainClose += 1 }

                            if abs(tv - tBg) > 20 || abs(bv - bBg) > 20 {
                                fgTotal += 1
                                if d <= tol + 4 { fgMatch += 1 }
                            }
                        }
                        x += colStep
                    }

                    let goodFracAll = Double(allClose) / Double(max(1, allCount))
                    let mainFrac = Double(mainClose) / Double(max(1, mainCount))
                    let mainMAD = Double(mainDiffSum) / Double(max(1, mainCount))

                    guard goodFracAll >= 0.76, mainFrac >= minMainFrac, mainMAD <= maxMainMAD else {
                        rowMatches[k] = false
                        continue
                    }

                    if fgTotal >= 2 {
                        let fgFrac = Double(fgMatch) / Double(fgTotal)
                        if fgFrac < minFgFrac {
                            rowMatches[k] = false
                            continue
                        }
                    }

                    rowMatches[k] = true
                    rowMADs[k] = mainMAD
                }
            }
        }

        // Find longest contiguous matching sub-band (bridging at most 3 isolated anti-aliasing rows).
        var bestStart = 0
        var bestLen = 0
        var curStart = -1
        var missStreak = 0
        var lastGood = -1

        for k in 0..<span {
            if rowMatches[k] {
                if curStart == -1 { curStart = k }
                lastGood = k
                missStreak = 0
            } else if curStart != -1 {
                missStreak += 1
                if missStreak > 1 {
                    let len = lastGood - curStart + 1
                    if len > bestLen {
                        bestLen = len
                        bestStart = curStart
                    }
                    curStart = -1
                    missStreak = 0
                }
            }
        }
        if curStart != -1 {
            let len = lastGood - curStart + 1
            if len > bestLen {
                bestLen = len
                bestStart = curStart
            }
        }

        guard bestLen >= minOverlap, bestLen <= maxOverlap + 12 else { return nil }

        let verifiedSTop = sTop + bestStart
        let verifiedETop = verifiedSTop + bestLen
        let verifiedSBot = verifiedSTop - lag
        let verifiedEBot = verifiedETop - lag

        var madSum = 0.0
        var nonBlankMadSum = 0.0
        var nonBlankCount = 0
        for k in bestStart..<(bestStart + bestLen) {
            let m = rowMADs[k]
            madSum += m
            let topY = sTop + k
            let botY = topY - lag
            if !topSigs.rows[topY].isBlank || !botSigs.rows[botY].isBlank {
                nonBlankCount += 1
                nonBlankMadSum += m
            }
        }

        // Require non-trivial matched structure unless overlap itself is small enough.
        let minRequiredNonBlank = min(6, max(1, bestLen / 8))
        guard nonBlankCount >= minRequiredNonBlank else { return nil }

        let normMAD = madSum / (Double(bestLen) * 255.0)
        let nonBlankNormMAD = nonBlankCount > 0 ? (nonBlankMadSum / (Double(nonBlankCount) * 255.0)) : normMAD
        let effectiveMAD = 0.45 * normMAD + 0.55 * nonBlankNormMAD

        // Penalize seams that stop far short of the bottom of `top` or start far below the top of `bot`.
        let distTopEnd = max(0, topWinEnd - verifiedETop)
        let distBotStart = max(0, verifiedSBot - botWinStart)
        let boundaryGap = Double(distTopEnd + distBotStart)
        let boundaryPenalty = min(0.35, boundaryGap / Double(max(120, min(topWinEnd - topWinStart, botWinEnd - botWinStart))))

        let contentCoverage = Double(nonBlankCount) / Double(max(1, bestLen))
        let errorRatio = effectiveMAD / max(config.maxNormalizedMAD, 0.03)
        let rawConfidence = max(0.0, min(1.0, (1.0 - errorRatio * 0.72) * (1.0 - boundaryPenalty * 0.6)))

        // Composite ranking score strongly favoring dense, boundary-anchored, low-error matches.
        let lengthBonus = Double(bestLen) * (0.35 + 0.65 * contentCoverage)
        let score = lengthBonus * max(0.05, 1.0 - errorRatio * 0.85) - boundaryGap * 0.45

        return VerifiedOverlap(
            lag: lag,
            startTop: verifiedSTop,
            endTop: verifiedETop,
            startBot: verifiedSBot,
            endBot: verifiedEBot,
            overlapLen: bestLen,
            normalizedMAD: effectiveMAD,
            nonBlankRows: nonBlankCount,
            confidence: rawConfidence,
            score: score
        )
    }
}
