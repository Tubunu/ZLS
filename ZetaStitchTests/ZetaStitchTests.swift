import XCTest
import CoreGraphics
import CoreVideo
import AVFoundation
@testable import ZetaStitch

final class ZetaStitchTests: XCTestCase {

    // MARK: - Overlap Detection & Stitching

    func testVerticalOverlapDetectionRemovesDuplicateContentAndStaticBars() throws {
        // Construct two synthetic 300x500 screenshots sharing:
        // - Static header (top 40px)
        // - Unique scrolling bands with 140px overlap between bottom of top & top of bottom
        // - Static footer (bottom 30px)
        let width = 300
        let height = 500
        let headerH = 40
        let footerH = 30
        let contentH = height - headerH - footerH // 430
        let overlap = 140
        let scrollStep = contentH - overlap // 290

        let totalVirtualH = headerH + contentH + scrollStep + footerH
        let virtualCanvas = makeTexturedStripImage(width: width, height: totalVirtualH)

        let topImg = renderScreenshot(
            virtualCanvas: virtualCanvas,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            scrollOffset: 0
        )
        let botImg = renderScreenshot(
            virtualCanvas: virtualCanvas,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            scrollOffset: scrollStep
        )

        let detector = OverlapDetector(config: OverlapDetectionConfig(autoTrimStaticBars: true))
        let result = detector.detectVerticalOverlap(topImage: topImg, bottomImage: botImg)

        XCTAssertTrue(result.isMatched)
        XCTAssertGreaterThan(result.confidence, 0.5)
        XCTAssertLessThanOrEqual(abs(result.topCropBottom - footerH), 6)
        XCTAssertLessThanOrEqual(abs(result.overlapPixels - overlap), 10)

        let engine = StitchEngine()
        let stitched = engine.renderStitchedImage(
            images: [topImg, botImg],
            seams: [result.toSeam(topIndex: 0)],
            scrollbars: [[], []],
            mode: .longStitch,
            removeScrollbars: false
        )
        XCTAssertNotNil(stitched)
        if let stitched {
            XCTAssertEqual(stitched.width, width)
            XCTAssertLessThanOrEqual(abs(stitched.height - totalVirtualH), 14)
        }
    }

    func testUniformBlankImagesDoNotFalseMatch() {
        let img1 = makeSolidImage(width: 240, height: 400, r: 255, g: 255, b: 255)
        let img2 = makeSolidImage(width: 240, height: 400, r: 255, g: 255, b: 255)
        let detector = OverlapDetector()
        let result = detector.detectVerticalOverlap(topImage: img1, bottomImage: img2)
        XCTAssertFalse(result.isMatched)
    }

    func testHorizontalAndVerticalCollageGeometry() {
        let a = makeSolidImage(width: 200, height: 400, r: 10, g: 20, b: 30)
        let b = makeSolidImage(width: 200, height: 400, r: 40, g: 50, b: 60)
        let engine = StitchEngine()
        let seam = StitchSeam(topIndex: 0, topCropBottom: 0, botCropTop: 0, overlapHeight: 0, status: .manual)

        let vGeom = engine.computeCanvasGeometry(images: [a, b], seams: [seam], mode: .vertical, spacing: 10)
        XCTAssertEqual(vGeom.width, 200)
        XCTAssertEqual(vGeom.height, 810)

        let hGeom = engine.computeCanvasGeometry(images: [a, b], seams: [seam], mode: .horizontal, spacing: 12)
        XCTAssertEqual(hGeom.width, 412)
        XCTAssertEqual(hGeom.height, 400)
    }

    // MARK: - Scrollbar Detection & Removal

    func testScrollbarDetectorAndCPURemoval() throws {
        let w = 240
        let h = 400
        let img = makeScreenshotWithScrollbar(width: w, height: h, barX: 222, barY: 80, barW: 6, barH: 120)

        let regions = ScrollbarDetector.detectScrollbars(in: img)
        XCTAssertEqual(regions.count, 1)
        if let reg = regions.first {
            XCTAssertLessThanOrEqual(abs(reg.x - 222), 2)
            XCTAssertLessThanOrEqual(abs(reg.width - 6), 2)
            XCTAssertGreaterThanOrEqual(reg.height, 110)

            let cleaned = ScrollbarProcessor.shared.applyWithCPU(image: img, regions: [reg])
            let pixel = samplePixel(cleaned, x: 225, y: 140)
            // Background is white (255, 255, 255), scrollbar was dark gray (90, 90, 90)
            XCTAssertGreaterThan(pixel.r, 235)
            XCTAssertGreaterThan(pixel.g, 235)
            XCTAssertGreaterThan(pixel.b, 235)
        }
    }

    // MARK: - Export (PDF & ZIP)

    func testPDFAndZipArchiveCreation() throws {
        let img = makeTexturedStripImage(width: 300, height: 600)
        let pdfData = PDFCreator.createPDFData(from: img)
        XCTAssertGreaterThan(pdfData.count, 100)
        let pdfHeader = String(data: pdfData.prefix(4), encoding: .ascii)
        XCTAssertEqual(pdfHeader, "%PDF")

        let payload = Data("ZetaStitchTestPayload".utf8)
        let zipData = try ZipArchiveWriter.createArchive(entries: [
            ZipArchiveWriter.Entry(fileName: "test.txt", data: payload)
        ])
        // PK\x03\x04 local file header signature
        XCTAssertEqual(zipData.prefix(4), Data([0x50, 0x4B, 0x03, 0x04]))
        // Ends with EOCD 0x06054b50 at -22 bytes
        let eocdOffset = zipData.count - 22
        XCTAssertEqual(zipData[eocdOffset..<(eocdOffset + 4)], Data([0x50, 0x4B, 0x05, 0x06]))
    }

    // MARK: - Synthetic Image Helpers

    private func makeSolidImage(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: bytes.count, by: 4) {
            bytes[i] = r
            bytes[i + 1] = g
            bytes[i + 2] = b
            bytes[i + 3] = 255
        }
        return imageFromRGBA(bytes: bytes, width: width, height: height)
    }

    private func makeTexturedStripImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 250, count: width * height * 4)
        for y in 0..<height {
            let band = y / 18
            for x in 0..<width {
                let idx = (y * width + x) * 4
                let pattern = ((x * 7 + band * 53 + (y % 18) * 19) % 211)
                let isBlock = (x > 20 && x < width - 24) && ((y % 18) > 3 && (y % 18) < 14) && ((x + band * 31) % 37 < 22)
                if isBlock {
                    bytes[idx] = UInt8(30 + (pattern % 140))
                    bytes[idx + 1] = UInt8(40 + ((band * 29) % 150))
                    bytes[idx + 2] = UInt8(70 + ((x * 3) % 160))
                } else {
                    bytes[idx] = 246
                    bytes[idx + 1] = 247
                    bytes[idx + 2] = 250
                }
                bytes[idx + 3] = 255
            }
        }
        return imageFromRGBA(bytes: bytes, width: width, height: height)
    }

    private func renderScreenshot(
        virtualCanvas: CGImage,
        width: Int,
        height: Int,
        headerH: Int,
        footerH: Int,
        scrollOffset: Int
    ) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        // Draw scrolling body
        let bodyH = height - headerH - footerH
        if let bodyCrop = virtualCanvas.cropping(to: CGRect(x: 0, y: headerH + scrollOffset, width: width, height: bodyH)) {
            ctx.draw(bodyCrop, in: CGRect(x: 0, y: footerH, width: width, height: bodyH))
        }
        // Fixed top status/nav bar
        ctx.setFillColor(CGColor(red: 0.12, green: 0.25, blue: 0.72, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - headerH, width: width, height: headerH))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 24, y: height - headerH + 14, width: 90, height: 10))

        // Fixed bottom toolbar
        ctx.setFillColor(CGColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: footerH))
        ctx.setFillColor(CGColor(red: 0.25, green: 0.28, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 90, y: 8, width: 120, height: 5))

        return ctx.makeImage()!
    }

    private func makeScreenshotWithScrollbar(
        width: Int,
        height: Int,
        barX: Int,
        barY: Int,
        barW: Int,
        barH: Int
    ) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in barY..<(barY + barH) {
            for x in barX..<(barX + barW) {
                let idx = (y * width + x) * 4
                bytes[idx] = 90
                bytes[idx + 1] = 90
                bytes[idx + 2] = 95
                bytes[idx + 3] = 255
            }
        }
        return imageFromRGBA(bytes: bytes, width: width, height: height)
    }

    private func imageFromRGBA(bytes: [UInt8], width: Int, height: Int) -> CGImage {
        var mutable = bytes
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &mutable,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return ctx.makeImage()!
    }

    private func samplePixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let idx = (y * image.width + x) * 4
        return (bytes[idx], bytes[idx + 1], bytes[idx + 2])
    }

    // MARK: - Realism Upgrades: Status Bar Clock Change, Sparse UI, Video Stream

    func testDynamicStatusBarClockAndStickyHeaderAlignment() async throws {
        let width = 720
        let height = 1400
        let headerH = 210
        let footerH = 110
        let overlap = 320
        let usableH = height - headerH - footerH // 1080
        let feedH = usableH * 2 - overlap // 1840

        let feed = makeRealisticFeedImage(width: width, height: feedH, darkMode: false)

        let topRaw = renderScreenshotWithClock(
            feed: feed,
            feedOffsetY: 0,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            clockSeed: 1,
            addFloatingBadgeAtBottomRight: true,
            scrollbarTopFraction: 0.18
        )
        let botRaw = renderScreenshotWithClock(
            feed: feed,
            feedOffsetY: usableH - overlap,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            clockSeed: 99,
            addFloatingBadgeAtBottomRight: false,
            scrollbarTopFraction: 0.52
        )

        let detector = OverlapDetector(config: OverlapDetectionConfig(autoTrimStaticBars: true))
        let result = detector.detectVerticalOverlap(topImage: topRaw, bottomImage: botRaw)

        XCTAssertTrue(result.isMatched, "Should match even when status bar clock, scrollbar, and corner FAB differ")
        XCTAssertLessThanOrEqual(abs(result.overlapPixels - overlap), 4)
        XCTAssertLessThanOrEqual(abs(result.topCropBottom - footerH), 4)
        XCTAssertLessThanOrEqual(abs(result.botCropTop - (headerH + overlap)), 4)

        let engine = StitchEngine()
        let stitched = try XCTUnwrap(engine.renderStitchedImage(
            images: [topRaw, botRaw],
            seams: [result.toSeam(topIndex: 0)],
            scrollbars: [[], []],
            mode: .longStitch,
            removeScrollbars: false
        ))
        let expectedH = headerH + feedH + footerH
        XCTAssertLessThanOrEqual(abs(stitched.height - expectedH), 8)
    }

    func testLowContrastSparseContentWithoutHeadersMatchesCleanly() throws {
        let width = 480
        let height = 900
        let overlap = 260
        let totalH = height * 2 - overlap

        // Minimalist sparse article with large uniform #F4F5F7 gaps and crisp dark text bars (no static headers)
        let feed = makeSparseArticleImage(width: width, height: totalH)
        let topImg = try XCTUnwrap(feed.cropping(to: CGRect(x: 0, y: 0, width: width, height: height)))
        let botImg = try XCTUnwrap(feed.cropping(to: CGRect(x: 0, y: height - overlap, width: width, height: height)))

        let detector = OverlapDetector(config: OverlapDetectionConfig(autoTrimStaticBars: true))
        let result = detector.detectVerticalOverlap(topImage: topImg, bottomImage: botImg)

        XCTAssertTrue(result.isMatched)
        XCTAssertLessThanOrEqual(abs(result.overlapPixels - overlap), 4)
        XCTAssertLessThanOrEqual(result.topCropBottom, 4)
        XCTAssertLessThanOrEqual(abs(result.botCropTop - overlap), 4)
    }

    func testVideoExtractionWithAVAssetWriterTracksScrollAndRefinesSeams() async throws {
        let width = 480
        let height = 840
        let headerH = 88
        let footerH = 64
        let usableH = height - headerH - footerH // 688
        let scrollDistance = 760
        let feedH = usableH + scrollDistance // 1448

        let feed = makeRealisticFeedImage(width: width, height: feedH, darkMode: true)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeta_scroll_test_\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await writeSyntheticScrollVideo(
            to: tempURL,
            feed: feed,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            scrollDistance: scrollDistance
        )

        let asset = AVURLAsset(url: tempURL)
        let duration = try await asset.load(.duration)
        let extraction = try await VideoStitcher.extractStitchResult(
            from: asset,
            timeRange: CMTimeRange(start: .zero, end: duration)
        )

        XCTAssertGreaterThanOrEqual(extraction.images.count, 2)
        XCTAssertLessThanOrEqual(extraction.images.count, 8)
        XCTAssertEqual(extraction.seams.count, extraction.images.count - 1)
        for seam in extraction.seams {
            XCTAssertFalse(seam.status.needsAttention, "Expected matched seam in scrolled video")
        }

        let engine = StitchEngine()
        let emptyBars = Array(repeating: [ScrollbarRegion](), count: extraction.images.count)
        let stitched = try XCTUnwrap(engine.renderStitchedImage(
            images: extraction.images,
            seams: extraction.seams,
            scrollbars: emptyBars,
            mode: .longStitch,
            removeScrollbars: false
        ))

        let expectedH = headerH + feedH + footerH
        XCTAssertLessThanOrEqual(
            abs(stitched.height - expectedH),
            90,
            "Video stitched height \(stitched.height) should closely track expected \(expectedH)"
        )
    }

    private func makeRealisticFeedImage(width: Int, height: Int, darkMode: Bool) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let bg: UInt8 = darkMode ? 18 : 246
        for y in 0..<height {
            let blockIdx = y / 96
            let localY = y % 96
            let cardMargin = 20
            let hasDivider = localY == 94 || localY == 95
            for x in 0..<width {
                let off = (y * width + x) * 4
                var r = bg
                var g = bg
                var b = bg
                if hasDivider {
                    r = darkMode ? 52 : 210
                    g = darkMode ? 52 : 212
                    b = darkMode ? 56 : 218
                } else if x >= cardMargin && x < width - cardMargin && localY >= 14 && localY <= 82 {
                    // Draw deterministic unique pseudo-text/avatar bars per block index so no two cards collide
                    let isAvatar = x < cardMargin + 44 && localY >= 22 && localY <= 66
                    let textBand = (localY >= 22 && localY <= 34) || (localY >= 46 && localY <= 58) || (localY >= 64 && localY <= 72)
                    let seed = (blockIdx &* 131 + localY &* 17 + (x / 11) &* 37) & 0xFF
                    let lineLimit = width - 48 - ((blockIdx * 53 + (localY / 12) * 31) % max(40, width / 3))
                    if isAvatar {
                        r = UInt8(60 + (blockIdx * 47) % 160)
                        g = UInt8(90 + (blockIdx * 29) % 140)
                        b = UInt8(140 + (blockIdx * 71) % 110)
                    } else if textBand && x >= cardMargin + 58 && x < lineLimit && (seed % 5 != 0) {
                        let c: UInt8 = darkMode ? 226 : 34
                        r = c; g = c; b = c
                    } else {
                        let cardBg: UInt8 = darkMode ? 32 : 255
                        r = cardBg; g = cardBg; b = cardBg
                    }
                }
                bytes[off] = r
                bytes[off + 1] = g
                bytes[off + 2] = b
                bytes[off + 3] = 255
            }
        }
        return imageFromRGBA(bytes: bytes, width: width, height: height)
    }

    private func makeSparseArticleImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let paraIdx = y / 110
            let ly = y % 110
            let lineLen = width / 3 + ((paraIdx * 73) % (width / 2))
            for x in 0..<width {
                let off = (y * width + x) * 4
                var r: UInt8 = 244
                var g: UInt8 = 245
                var b: UInt8 = 247
                if ly >= 20 && ly <= 34 && x >= 32 && x < lineLen {
                    let wordGap = ((x + paraIdx * 13) / 18) % 4 == 0
                    if !wordGap {
                        r = 32; g = 36; b = 42
                    }
                }
                bytes[off] = r; bytes[off + 1] = g; bytes[off + 2] = b; bytes[off + 3] = 255
            }
        }
        return imageFromRGBA(bytes: bytes, width: width, height: height)
    }

    private func renderScreenshotWithClock(
        feed: CGImage,
        feedOffsetY: Int,
        width: Int,
        height: Int,
        headerH: Int,
        footerH: Int,
        clockSeed: Int,
        addFloatingBadgeAtBottomRight: Bool,
        scrollbarTopFraction: Double
    ) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        let usableH = height - headerH - footerH
        let bodyCrop = feed.cropping(to: CGRect(x: 0, y: feedOffsetY, width: width, height: usableH))!
        var bodyBytes = [UInt8](repeating: 0, count: width * usableH * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bCtx = CGContext(
            data: &bodyBytes,
            width: width,
            height: usableH,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        bCtx.draw(bodyCrop, in: CGRect(x: 0, y: 0, width: width, height: usableH))

        for y in 0..<height {
            for x in 0..<width {
                let off = (y * width + x) * 4
                if y < headerH {
                    var v: UInt8 = 248
                    // Dynamic status clock digits at y = 44..<76, x = 44..<160
                    if y >= 44 && y < 76 && x >= 44 && x < 160 {
                        if ((x / 8 + y / 6 + clockSeed) % 3) == 0 { v = 24 }
                    }
                    // Identical navigation bar title & bottom separator below status bar
                    if y >= 118 && y < 146 && x >= width / 3 && x < (width * 2) / 3 {
                        v = 30
                    }
                    if y >= headerH - 2 {
                        v = 205
                    }
                    bytes[off] = v; bytes[off + 1] = v; bytes[off + 2] = v; bytes[off + 3] = 255
                } else if y >= height - footerH {
                    var v: UInt8 = 248
                    if y < height - footerH + 2 { v = 205 }
                    if y >= height - 22 && y <= height - 16 && x >= width / 3 && x <= (width * 2) / 3 {
                        v = 40
                    }
                    bytes[off] = v; bytes[off + 1] = v; bytes[off + 2] = v; bytes[off + 3] = 255
                } else {
                    let by = y - headerH
                    let bOff = (by * width + x) * 4
                    bytes[off] = bodyBytes[bOff]
                    bytes[off + 1] = bodyBytes[bOff + 1]
                    bytes[off + 2] = bodyBytes[bOff + 2]
                    bytes[off + 3] = 255
                }
            }
        }

        // Floating corner action badge (ignored by trimmed-column MAD)
        if addFloatingBadgeAtBottomRight {
            let bx0 = width - 86
            let bx1 = width - 26
            let by0 = height - footerH - 92
            let by1 = height - footerH - 32
            for y in by0..<by1 {
                for x in bx0..<bx1 {
                    let off = (y * width + x) * 4
                    bytes[off] = 40; bytes[off + 1] = 120; bytes[off + 2] = 255; bytes[off + 3] = 255
                }
            }
        }

        // Right-edge scrollbar pill in differing vertical location
        let sbTop = headerH + Int(Double(usableH) * scrollbarTopFraction)
        let sbBot = min(height - footerH - 8, sbTop + 120)
        for y in sbTop..<sbBot {
            for x in (width - 10)..<(width - 4) {
                let off = (y * width + x) * 4
                bytes[off] = 130; bytes[off + 1] = 130; bytes[off + 2] = 140; bytes[off + 3] = 255
            }
        }

        return imageFromRGBA(bytes: bytes, width: width, height: height)
    }

    func testRepeatingDividersStillAnchorToExactOverlap() throws {
        let width = 420
        let height = 860
        let headerH = 90
        let footerH = 70
        let overlap = 220
        let usableH = height - headerH - footerH // 700
        let feedH = usableH * 2 - overlap // 1180

        // Alternating colored stripes + repeated 120px card dividers
        var bytes = [UInt8](repeating: 250, count: width * feedH * 4)
        for y in 0..<feedH {
            let block = y / 120
            let ly = y % 120
            let isDivider = ly < 3
            let textLen = 90 + ((block * 67) % 240)
            for x in 0..<width {
                let off = (y * width + x) * 4
                var r: UInt8 = 250
                var g: UInt8 = 250
                var b: UInt8 = 252
                if isDivider {
                    r = 210; g = 212; b = 218
                } else if ly >= 28 && ly <= 42 && x >= 30 && x < textLen {
                    r = UInt8(30 + (block * 23) % 80)
                    g = 40
                    b = UInt8(70 + (block * 41) % 120)
                }
                bytes[off] = r; bytes[off + 1] = g; bytes[off + 2] = b; bytes[off + 3] = 255
            }
        }
        let feed = imageFromRGBA(bytes: bytes, width: width, height: feedH)
        let topImg = renderScreenshotWithClock(
            feed: feed,
            feedOffsetY: 0,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            clockSeed: 7,
            addFloatingBadgeAtBottomRight: false,
            scrollbarTopFraction: 0.1
        )
        let botImg = renderScreenshotWithClock(
            feed: feed,
            feedOffsetY: usableH - overlap,
            width: width,
            height: height,
            headerH: headerH,
            footerH: footerH,
            clockSeed: 14,
            addFloatingBadgeAtBottomRight: false,
            scrollbarTopFraction: 0.45
        )

        let detector = OverlapDetector(config: OverlapDetectionConfig(autoTrimStaticBars: true))
        let res = detector.detectVerticalOverlap(topImage: topImg, bottomImage: botImg)
        XCTAssertTrue(res.isMatched)
        let diag = "overlap=\(res.overlapPixels) topCrop=\(res.topCropBottom) botCrop=\(res.botCropTop) conf=\(res.confidence)"
        XCTAssertLessThanOrEqual(abs(res.overlapPixels - overlap), 4, diag)
        XCTAssertLessThanOrEqual(abs(res.topCropBottom - footerH), 4, diag)
        XCTAssertLessThanOrEqual(abs(res.botCropTop - (headerH + overlap)), 4, diag)
    }

    private func writeSyntheticScrollVideo(
        to url: URL,
        feed: CGImage,
        width: Int,
        height: Int,
        headerH: Int,
        footerH: Int,
        scrollDistance: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let cs = CGColorSpaceCreateDeviceRGB()
        var feedBytes = [UInt8](repeating: 0, count: feed.width * feed.height * 4)
        let fCtx = CGContext(
            data: &feedBytes,
            width: feed.width,
            height: feed.height,
            bitsPerComponent: 8,
            bytesPerRow: feed.width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        fCtx.draw(feed, in: CGRect(x: 0, y: 0, width: feed.width, height: feed.height))

        let fps = 24
        let totalFrames = 60

        for f in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let scrollOffset: Int
            if f < 10 {
                scrollOffset = 0
            } else if f < 50 {
                let t = Double(f - 10) / 40.0
                scrollOffset = Int((t * Double(scrollDistance)).rounded())
            } else {
                // Simulate slight end-of-scroll rubber-band bounceback after hitting bottom
                let bounce = f < 55 ? (f - 50) * 6 : (60 - f) * 4
                scrollOffset = max(0, scrollDistance - bounce)
            }

            var maybePB: CVPixelBuffer?
            if let pool = adaptor.pixelBufferPool {
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &maybePB)
            } else {
                CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &maybePB)
            }
            guard let pb = maybePB else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            if let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) {
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                for y in 0..<height {
                    let rowPtr = base.advanced(by: y * bpr)
                    if y < headerH {
                        for x in 0..<width {
                            let off = x * 4
                            var v: UInt8 = 28
                            if y >= 22 && y < 38 && x >= 24 && x < 90 && ((f / 15 + x / 6) % 2 == 0) {
                                v = 220
                            } else if y >= headerH - 2 {
                                v = 72
                            }
                            rowPtr[off] = v; rowPtr[off + 1] = v; rowPtr[off + 2] = v; rowPtr[off + 3] = 255
                        }
                    } else if y >= height - footerH {
                        for x in 0..<width {
                            let off = x * 4
                            let v: UInt8 = y == height - footerH ? 72 : 28
                            rowPtr[off] = v; rowPtr[off + 1] = v; rowPtr[off + 2] = v; rowPtr[off + 3] = 255
                        }
                    } else {
                        let fy = min(feed.height - 1, scrollOffset + (y - headerH))
                        for x in 0..<width {
                            let fOff = (fy * feed.width + x) * 4
                            let off = x * 4
                            // BGRA
                            rowPtr[off] = feedBytes[fOff + 2]
                            rowPtr[off + 1] = feedBytes[fOff + 1]
                            rowPtr[off + 2] = feedBytes[fOff]
                            rowPtr[off + 3] = 255
                        }
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            let pts = CMTime(value: CMTimeValue(f), timescale: CMTimeScale(fps))
            adaptor.append(pb, withPresentationTime: pts)
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed, let err = writer.error {
            throw err
        }
    }
}
