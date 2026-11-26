import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

public final class VideoWriter {
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let lock = NSLock()
    private var sessionStarted = false
    private var isWriting = false
    private var isFinished = false

    public init?(outputURL: URL, size: CGSize) {
        let evenW = max(2, Int(size.width) & ~1)
        let evenH = max(2, Int(size.height) & ~1)

        do {
            let assetWriter = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: evenW,
                AVVideoHeightKey: evenH,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 4_500_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
                ]
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true

            let sourceAttrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: evenW,
                kCVPixelBufferHeightKey as String: evenH
            ]
            let bufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: sourceAttrs
            )

            guard assetWriter.canAdd(input) else { return nil }
            assetWriter.add(input)

            self.writer = assetWriter
            self.videoInput = input
            self.adaptor = bufferAdaptor
        } catch {
            return nil
        }
    }

    public func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isWriting, !isFinished else { return false }
        isWriting = writer.startWriting()
        return isWriting
    }

    public func append(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard isWriting, !isFinished else { return }

        if !sessionStarted {
            writer.startSession(atSourceTime: presentationTime)
            sessionStarted = true
        }

        if videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }
    }

    public func finish(completion: @escaping () -> Void) {
        lock.lock()
        guard isWriting, !isFinished else {
            lock.unlock()
            completion()
            return
        }
        isFinished = true
        isWriting = false
        lock.unlock()

        if sessionStarted {
            videoInput.markAsFinished()
            writer.finishWriting {
                completion()
            }
        } else {
            writer.cancelWriting()
            completion()
        }
    }
}
