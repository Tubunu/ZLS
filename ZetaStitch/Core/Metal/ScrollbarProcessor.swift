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
        let stripWidth = min(44, max(24, w / 16))
        let stripX = w - stripWidth
        guard let stripCrop = image.cropping(to: CGRect(x: stripX, y: 0, width: stripWidth, height: h)),
              let pixels = rgbaBytes(from: stripCrop, width: stripWidth, height: h) else {
            return []
        }

        let minBarWidth = max(3, Int((Double(w) * 0.004).rounded()))
        let maxBarWidth = max(minBarWidth + 4, Int((Double(w) * 0.022).rounded()))
        let minBarHeight = max(32, Int((Double(h) * 0.03).rounded()))

        // Evaluate candidate columns from right to left (typical indicator sits ~4..24px from right edge).
        var bestSpan: (localX: Int, barW: Int, yStart: Int, yEnd: Int, score: Double)?

        for candW in minBarWidth...min(maxBarWidth, stripWidth - 8) {
            for lx in stride(from: stripWidth - candW - 4, through: 4, by: -1) {
                var activeMask = [Bool](repeating: false, count: h)

                for y in 0..<h {
                    let leftSampleX = max(0, lx - 3)
                    let rightSampleX = min(stripWidth - 1, lx + candW + 2)
                    let lRGB = rgb(pixels, stride: stripWidth, x: leftSampleX, y: y)
                    let rRGB = rgb(pixels, stride: stripWidth, x: rightSampleX, y: y)

                    // Left and right background around the scrollbar should agree closely.
                    let bgDiff = colorDistance(lRGB, rRGB)
                    guard bgDiff < 22.0 else { continue }

                    // Pixels inside the scrollbar capsule should be consistent and distinct from background.
                    var minInteriorDiff = Double.greatestFiniteMagnitude
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
                    minInteriorDiff = colorDistance(firstIn, bgAvg)

                    if maxInternalSpread < 26.0 && minInteriorDiff > 16.0 {
                        activeMask[y] = true
                    }
                }

                // Extract longest contiguous run (allowing up to 2px rounded-cap gap).
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
                        } else if gap < 2 && end + 2 < h && activeMask[end + 2] {
                            gap += 1
                            end += 1
                        } else {
                            break
                        }
                    }
                    let runLen = end - start + 1
                    if runLen >= minBarHeight {
                        let score = Double(runLen) - Double(abs(candW - 6)) * 2.0
                        if bestSpan == nil || score > bestSpan!.score {
                            bestSpan = (lx, candW, start, end, score)
                        }
                    }
                    y = end + 1
                }
            }
        }

        guard let found = bestSpan else { return [] }
        let region = ScrollbarRegion(
            x: stripX + found.localX,
            y: found.yStart,
            width: found.barW,
            height: found.yEnd - found.yStart + 1,
            leftPadding: 3,
            rightPadding: 3
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

        return cgImage(from: currentTex)
    }

    private func cgImage(from texture: MTLTexture) -> CGImage? {
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

        let cs = CGColorSpaceCreateDeviceRGB()
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
        let cs = CGColorSpaceCreateDeviceRGB()
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

            let leftX = max(0, minX - reg.leftPadding)
            let rightX = min(w - 1, maxX + reg.rightPadding)

            for y in minY..<maxY {
                let rowOff = y * bytesPerRow
                let lOff = rowOff + leftX * 4
                let rOff = rowOff + rightX * 4
                for x in minX..<maxX {
                    let t = Double(x - minX + 1) / Double(max(1, (maxX - minX) + 1))
                    let pOff = rowOff + x * 4
                    for c in 0..<4 {
                        let lv = Double(bytes[lOff + c])
                        let rv = Double(bytes[rOff + c])
                        bytes[pOff + c] = UInt8(max(0, min(255, (lv * (1.0 - t) + rv * t).rounded())))
                    }
                }
            }
        }

        return ctx.makeImage() ?? image
    }
}
