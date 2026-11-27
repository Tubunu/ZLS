import Foundation
import CoreGraphics
import Metal
import MetalKit

public struct ScrollbarDetector {
    /// Detects vertical iOS scroll indicator capsules near the right edge of a screenshot.
    public static func detectScrollbars(in image: CGImage) -> [ScrollbarRegion] {
        let w = image.width
        let h = image.height
        guard w >= 80, h >= 100 else { return [] }

        // Scan the rightmost strip where iOS renders UIScrollView / WKWebView indicators.
        let stripWidth = min(56, max(28, w / 16))
        let stripX = w - stripWidth
        guard let stripCrop = image.cropping(to: CGRect(x: stripX, y: 0, width: stripWidth, height: h)),
              let pixels = rgbaBytes(from: stripCrop, width: stripWidth, height: h) else {
            return []
        }

        let minBarWidth = max(3, Int((Double(w) * 0.003).rounded()))
        let maxBarWidth = min(stripWidth - 12, max(minBarWidth + 4, Int((Double(w) * 0.018).rounded())))
        let minBarHeight = max(32, Int((Double(h) * 0.03).rounded()))
        guard minBarWidth <= maxBarWidth else { return [] }

        // Stage A: Locate vertical scrollbar core capsule using outer background sampling
        // (far enough outside the capsule so anti-aliased edge shoulders don't pollute background).
        var bestSpan: (localX: Int, barW: Int, yStart: Int, yEnd: Int, score: Double)?

        for candW in minBarWidth...maxBarWidth {
            for lx in stride(from: stripWidth - candW - 6, through: 6, by: -1) {
                var activeMask = [Bool](repeating: false, count: h)

                for y in 0..<h {
                    let leftSampleX = max(0, lx - 6)
                    let rightSampleX = min(stripWidth - 1, lx + candW + 5)
                    let lRGB = rgb(pixels, stride: stripWidth, x: leftSampleX, y: y)
                    let rRGB = rgb(pixels, stride: stripWidth, x: rightSampleX, y: y)

                    // Left and right background around the scrollbar should agree closely.
                    let bgDiff = colorDistance(lRGB, rRGB)
                    guard bgDiff < 20.0 else { continue }

                    var maxInternalSpread = 0.0
                    let firstIn = rgb(pixels, stride: stripWidth, x: lx + candW / 2, y: y)

                    for dx in 0..<candW {
                        let c = rgb(pixels, stride: stripWidth, x: lx + dx, y: y)
                        maxInternalSpread = max(maxInternalSpread, colorDistance(c, firstIn))
                    }
                    let bgAvg = (
                        (lRGB.0 + rRGB.0) * 0.5,
                        (lRGB.1 + rRGB.1) * 0.5,
                        (lRGB.2 + rRGB.2) * 0.5
                    )
                    let minInteriorDiff = colorDistance(firstIn, bgAvg)

                    if maxInternalSpread < 28.0 && minInteriorDiff > 14.0 {
                        activeMask[y] = true
                    }
                }

                // Extract longest contiguous run (allowing up to 3px horizontal-divider / cap gaps).
                var y = 0
                while y < h {
                    if !activeMask[y] {
                        y += 1
                        continue
                    }
                    let start = y
                    var end = y
                    var gap = 0
                    while end + 1 < h {
                        if activeMask[end + 1] {
                            end += 1
                            gap = 0
                        } else if gap < 3 && end + 2 < h && activeMask[end + 2] {
                            gap += 1
                            end += 1
                        } else {
                            break
                        }
                    }
                    let runLen = end - start + 1
                    if runLen >= minBarHeight {
                        // Prefer wider full core capsules over narrow 3px slices inside the capsule.
                        let score = Double(runLen) + Double(candW) * 4.0
                        if bestSpan == nil || score > bestSpan!.score {
                            bestSpan = (lx, candW, start, end, score)
                        }
                    }
                    y = end + 1
                }
            }
        }

        guard let found = bestSpan else { return [] }

        // Stage B: Expand horizontally & vertically to capture the full anti-aliased edge halo
        // and semi-transparent rounded caps so removal leaves zero 1px outline box.
        let coreLen = max(1, found.yEnd - found.yStart + 1)
        let midY0 = found.yStart + coreLen / 4
        let midY1 = max(midY0 + 1, found.yEnd - coreLen / 4)
        let rowStep = max(1, (midY1 - midY0) / 48)

        func rowOuterBg(y: Int, leftX: Int, rightX: Int) -> (Double, Double, Double) {
            let lx1 = max(0, leftX - 6)
            let lx2 = max(0, leftX - 5)
            let rx1 = min(stripWidth - 1, rightX + 5)
            let rx2 = min(stripWidth - 1, rightX + 6)
            let l1 = rgb(pixels, stride: stripWidth, x: lx1, y: y)
            let l2 = rgb(pixels, stride: stripWidth, x: lx2, y: y)
            let r1 = rgb(pixels, stride: stripWidth, x: rx1, y: y)
            let r2 = rgb(pixels, stride: stripWidth, x: rx2, y: y)
            return (
                (l1.0 + l2.0 + r1.0 + r2.0) * 0.25,
                (l1.1 + l2.1 + r1.1 + r2.1) * 0.25,
                (l1.2 + l2.2 + r1.2 + r2.2) * 0.25
            )
        }

        func columnDiffersFromBg(colX: Int) -> Bool {
            var differCount = 0
            var totalCount = 0
            var y = midY0
            while y < midY1 {
                let bg = rowOuterBg(y: y, leftX: found.localX, rightX: found.localX + found.barW - 1)
                let c = rgb(pixels, stride: stripWidth, x: colX, y: y)
                if colorDistance(c, bg) > 3.5 {
                    differCount += 1
                }
                totalCount += 1
                y += rowStep
            }
            return totalCount > 0 && Double(differCount) / Double(totalCount) >= 0.55
        }

        var expLeftX = found.localX
        let maxExpandLeft = max(2, expLeftX - 6)
        while expLeftX > maxExpandLeft && columnDiffersFromBg(colX: expLeftX - 1) {
            expLeftX -= 1
        }

        var expRightX = found.localX + found.barW // exclusive
        let maxExpandRight = min(stripWidth - 2, expRightX + 6)
        while expRightX < maxExpandRight && columnDiffersFromBg(colX: expRightX) {
            expRightX += 1
        }

        // Add 1px outer anti-aliasing / chroma-subsampling safety margin on each side.
        expLeftX = max(1, expLeftX - 1)
        expRightX = min(stripWidth - 1, expRightX + 1)

        func rowHasCapPixels(y: Int) -> Bool {
            guard y >= 0, y < h else { return false }
            let lBg = rgb(pixels, stride: stripWidth, x: max(0, expLeftX - 4), y: y)
            let rBg = rgb(pixels, stride: stripWidth, x: min(stripWidth - 1, expRightX + 3), y: y)
            guard colorDistance(lBg, rBg) < 22.0 else { return false }
            let bg = ((lBg.0 + rBg.0) * 0.5, (lBg.1 + rBg.1) * 0.5, (lBg.2 + rBg.2) * 0.5)
            for x in expLeftX..<expRightX {
                if colorDistance(rgb(pixels, stride: stripWidth, x: x, y: y), bg) > 4.0 {
                    return true
                }
            }
            return false
        }

        var expTopY = found.yStart
        let topExpandLimit = max(0, found.yStart - 10)
        while expTopY > topExpandLimit && rowHasCapPixels(y: expTopY - 1) {
            expTopY -= 1
        }

        var expBotY = found.yEnd // inclusive
        let botExpandLimit = min(h - 1, found.yEnd + 10)
        while expBotY < botExpandLimit && rowHasCapPixels(y: expBotY + 1) {
            expBotY += 1
        }

        // Expand 2px vertically beyond last visible cap pixels to erase faintest rounded corners cleanly.
        expTopY = max(0, expTopY - 2)
        expBotY = min(h - 1, expBotY + 2)

        let region = ScrollbarRegion(
            x: stripX + expLeftX,
            y: expTopY,
            width: max(1, expRightX - expLeftX),
            height: max(1, expBotY - expTopY + 1),
            leftPadding: 4,
            rightPadding: 4
        )
        return [region]
    }

    private static func rgbaBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private static func rgb(_ bytes: [UInt8], stride: Int, x: Int, y: Int) -> (Double, Double, Double) {
        let idx = (y * stride + x) * 4
        return (Double(bytes[idx]), Double(bytes[idx + 1]), Double(bytes[idx + 2]))
    }

    private static func colorDistance(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let dr = a.0 - b.0
        let dg = a.1 - b.1
        let db = a.2 - b.2
        return (abs(dr) + abs(dg) + abs(db)) / 3.0
    }
}

public final class ScrollbarProcessor {
    private struct ScrollbarUniforms {
        var barX: Int32
        var barY: Int32
        var barWidth: Int32
        var barHeight: Int32
        var leftPadding: UInt32
        var rightPadding: UInt32
    }

    public static let shared = ScrollbarProcessor()

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let pipelineState: MTLComputePipelineState?
    private let textureLoader: MTKTextureLoader?

    private init() {
        let dev = MTLCreateSystemDefaultDevice()
        self.device = dev
        self.commandQueue = dev?.makeCommandQueue()
        self.textureLoader = dev.map { MTKTextureLoader(device: $0) }
        if let dev,
           let library = dev.makeDefaultLibrary(),
           let fn = library.makeFunction(name: "scrollBarTransform") {
            self.pipelineState = try? dev.makeComputePipelineState(function: fn)
        } else {
            self.pipelineState = nil
        }
    }

    /// Removes the detected scrollbar regions using Metal GPU compute when available,
    /// falling back seamlessly to deterministic CPU interpolation.
    public func removeScrollbars(from image: CGImage, regions: [ScrollbarRegion]) -> CGImage {
        guard !regions.isEmpty else { return image }
        if let gpuResult = applyWithMetal(image: image, regions: regions) {
            return gpuResult
        }
        return applyWithCPU(image: image, regions: regions)
    }

    private func applyWithMetal(image: CGImage, regions: [ScrollbarRegion]) -> CGImage? {
        guard let device,
              let commandQueue,
              let pipelineState,
              let textureLoader else {
            return nil
        }

        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue | MTLTextureUsage.shaderWrite.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue)
        ]

        guard var currentTex = try? textureLoader.newTexture(cgImage: image, options: options) else {
            return nil
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: currentTex.pixelFormat,
            width: currentTex.width,
            height: currentTex.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared

        guard var outTex = device.makeTexture(descriptor: desc) else { return nil }

        for region in regions {
            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeComputeCommandEncoder() else {
                return nil
            }
            var uniforms = ScrollbarUniforms(
                barX: Int32(region.x),
                barY: Int32(region.y),
                barWidth: Int32(region.width),
                barHeight: Int32(region.height),
                leftPadding: UInt32(region.leftPadding),
                rightPadding: UInt32(region.rightPadding)
            )
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(currentTex, index: 0)
            encoder.setTexture(outTex, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<ScrollbarUniforms>.stride, index: 0)

            let w = pipelineState.threadExecutionWidth
            let h = max(1, pipelineState.maxTotalThreadsPerThreadgroup / w)
            let tgSize = MTLSize(width: w, height: h, depth: 1)
            let gridSize = MTLSize(
                width: (currentTex.width + w - 1) / w,
                height: (currentTex.height + h - 1) / h,
                depth: 1
            )
            encoder.dispatchThreadgroups(gridSize, threadsPerThreadgroup: tgSize)
            encoder.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()

            swap(&currentTex, &outTex)
        }

        return cgImage(from: currentTex, colorSpace: image.colorSpace)
    }

    private func cgImage(from texture: MTLTexture, colorSpace: CGColorSpace?) -> CGImage? {
        let w = texture.width
        let h = texture.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let region = MTLRegionMake2D(0, 0, w, h)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        let bitmapInfo: UInt32
        switch texture.pixelFormat {
        case .bgra8Unorm, .bgra8Unorm_srgb:
            bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        default:
            bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        }

        let cs = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        return ctx.makeImage()
    }

    public func applyWithCPU(image: CGImage, regions: [ScrollbarRegion]) -> CGImage {
        let w = image.width
        let h = image.height
        let bytesPerRow = w * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &bytes,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        for reg in regions {
            let minX = max(0, reg.x)
            let maxX = min(w, reg.x + reg.width)
            let minY = max(0, reg.y)
            let maxY = min(h, reg.y + reg.height)
            guard minX < maxX, minY < maxY else { continue }

            let leftCenter = max(0, minX - reg.leftPadding)
            let rightCenter = min(w - 1, maxX + reg.rightPadding)
            let l0 = max(0, min(max(0, minX - 1), leftCenter - 1))
            let l1 = max(0, min(max(0, minX - 1), leftCenter))
            let l2 = max(0, min(max(0, minX - 1), leftCenter + 1))

            let rLo = min(maxX, w - 1)
            let r0 = min(w - 1, max(rLo, rightCenter - 1))
            let r1 = min(w - 1, max(rLo, rightCenter))
            let r2 = min(w - 1, max(rLo, rightCenter + 1))

            for y in minY..<maxY {
                let rowOff = y * bytesPerRow
                let lv0 = Double(
                    Int(bytes[rowOff + l0 * 4]) + Int(bytes[rowOff + l1 * 4]) + Int(bytes[rowOff + l2 * 4])
                ) / 3.0
                let lv1 = Double(
                    Int(bytes[rowOff + l0 * 4 + 1]) + Int(bytes[rowOff + l1 * 4 + 1]) + Int(bytes[rowOff + l2 * 4 + 1])
                ) / 3.0
                let lv2 = Double(
                    Int(bytes[rowOff + l0 * 4 + 2]) + Int(bytes[rowOff + l1 * 4 + 2]) + Int(bytes[rowOff + l2 * 4 + 2])
                ) / 3.0
                let lv3 = Double(
                    Int(bytes[rowOff + l0 * 4 + 3]) + Int(bytes[rowOff + l1 * 4 + 3]) + Int(bytes[rowOff + l2 * 4 + 3])
                ) / 3.0

                let rv0 = Double(
                    Int(bytes[rowOff + r0 * 4]) + Int(bytes[rowOff + r1 * 4]) + Int(bytes[rowOff + r2 * 4])
                ) / 3.0
                let rv1 = Double(
                    Int(bytes[rowOff + r0 * 4 + 1]) + Int(bytes[rowOff + r1 * 4 + 1]) + Int(bytes[rowOff + r2 * 4 + 1])
                ) / 3.0
                let rv2 = Double(
                    Int(bytes[rowOff + r0 * 4 + 2]) + Int(bytes[rowOff + r1 * 4 + 2]) + Int(bytes[rowOff + r2 * 4 + 2])
                ) / 3.0
                let rv3 = Double(
                    Int(bytes[rowOff + r0 * 4 + 3]) + Int(bytes[rowOff + r1 * 4 + 3]) + Int(bytes[rowOff + r2 * 4 + 3])
                ) / 3.0

                for x in minX..<maxX {
                    let t = Double(x - minX + 1) / Double(max(1, (maxX - minX) + 1))
                    let omt = 1.0 - t
                    let pOff = rowOff + x * 4
                    bytes[pOff] = UInt8(max(0, min(255, (lv0 * omt + rv0 * t).rounded())))
                    bytes[pOff + 1] = UInt8(max(0, min(255, (lv1 * omt + rv1 * t).rounded())))
                    bytes[pOff + 2] = UInt8(max(0, min(255, (lv2 * omt + rv2 * t).rounded())))
                    bytes[pOff + 3] = UInt8(max(0, min(255, (lv3 * omt + rv3 * t).rounded())))
                }
            }
        }

        return ctx.makeImage() ?? image
    }
}
