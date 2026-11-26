import Foundation
import CoreGraphics
import UIKit

public enum PDFCreator {
    /// Creates a crisp PDF document from a stitched `CGImage`.
    /// Automatically splits ultra-tall screenshots into tiled pages when height exceeds Apple PDF viewer's 14,400pt limit.
    public static func createPDFData(from image: CGImage) -> Data {
        let maxPageHeightPx: CGFloat = 12000
        let imgW = CGFloat(image.width)
        let imgH = CGFloat(image.height)

        // Scale page width to clean readable 595pt (A4 width) or proportional points while preserving crisp pixel backing.
        let targetPageWidthPt: CGFloat = 595.0
        let scale = targetPageWidthPt / max(1, imgW)
        let sliceHeightPx = min(imgH, maxPageHeightPx)
        let pageCount = max(1, Int(ceil(imgH / sliceHeightPx)))

        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextCreator as String: "Zeta Stitch"
        ]

        let firstPageH = min(imgH, sliceHeightPx) * scale
        let renderer = UIGraphicsPDFRenderer(
            bounds: CGRect(x: 0, y: 0, width: targetPageWidthPt, height: firstPageH),
            format: format
        )

        return renderer.pdfData { ctx in
            for page in 0..<pageCount {
                let yPx = CGFloat(page) * sliceHeightPx
                let hPx = min(sliceHeightPx, imgH - yPx)
                let pageBounds = CGRect(x: 0, y: 0, width: targetPageWidthPt, height: hPx * scale)
                ctx.beginPage(withBounds: pageBounds, pageInfo: [:])

                if let slice = image.cropping(to: CGRect(x: 0, y: yPx, width: imgW, height: hPx)) {
                    let uiImg = UIImage(cgImage: slice)
                    uiImg.draw(in: pageBounds)
                }
            }
        }
    }
}
