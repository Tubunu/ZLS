import XCTest
import CoreGraphics
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
}
