import Foundation
import CoreGraphics
import ReplayKit
import AudioToolbox
import CoreMedia
import CoreVideo
import ImageIO

final class SampleHandler: RPBroadcastSampleHandler {
    private let processingQueue = DispatchQueue(label: "com.zeta.stitch.scrollshot.processing", qos: .userInitiated)
    private let store = AppGroupStore.shared

    private var recordingID: String = ""
    private var recordingURL: URL?
    private var keyframesFolderURL: URL?
    private var videoWriter: VideoWriter?
    private var videoStitcher = VideoStitcher()

    private var lastAnalyzedTime: CMTime = .invalid
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastOrientation: CGImagePropertyOrientation = .up
    private var autoEndWorkItem: DispatchWorkItem?
    private var isFinalized = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let id = UUID().uuidString
        recordingID = id
        recordingURL = store.recordingFolderURL(for: id).appendingPathComponent("recording.mp4")
        keyframesFolderURL = store.keyframesFolderURL(for: id)
        isFinalized = false
        lastAnalyzedTime = .invalid
        lastPixelBuffer = nil

        if store.hapticOnStart {
            AudioServicesPlaySystemSound(1519)
        }

        let autoEndDelay = store.autoEndSeconds.rawValue
        videoStitcher = VideoStitcher()
        videoStitcher.onScrollIdle = { [weak self] in
            guard let self, autoEndDelay > 0 else { return }
            self.scheduleAutoFinish(after: autoEndDelay)
        }
        videoStitcher.onScrollResumed = { [weak self] in
            self?.cancelAutoFinish()
        }
    }

    override func broadcastPaused() {
        cancelAutoFinish()
    }

    override func broadcastResumed() {
        // Resumes seamlessly on next sample buffer.
    }

    override func broadcastFinished() {
        finalizeSynchronously()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let orientation = extractOrientation(from: sampleBuffer)

        processingQueue.async { [weak self] in
            guard let self, !self.isFinalized else { return }

            if self.videoWriter == nil, let url = self.recordingURL {
                let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
                let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
                let writer = VideoWriter(outputURL: url, size: CGSize(width: width, height: height))
                if writer?.start() == true {
                    self.videoWriter = writer
                }
            }

            self.videoWriter?.append(pixelBuffer: pixelBuffer, presentationTime: pts)
            self.lastPixelBuffer = pixelBuffer
            self.lastOrientation = orientation

            // Analyze at ~6 fps max to stay comfortably below ReplayKit's 50MB memory limit.
            let shouldAnalyze: Bool
            if !self.lastAnalyzedTime.isValid {
                shouldAnalyze = true
            } else {
                let elapsed = CMTimeGetSeconds(CMTimeSubtract(pts, self.lastAnalyzedTime))
                shouldAnalyze = elapsed >= 0.16
            }

            if shouldAnalyze, let kfURL = self.keyframesFolderURL {
                self.lastAnalyzedTime = pts
                autoreleasepool {
                    self.videoStitcher.processLiveFrame(
                        pixelBuffer,
                        orientation: orientation,
                        keyframesFolder: kfURL
                    )
                }
            }
        }
    }

    private func scheduleAutoFinish(after delay: TimeInterval) {
        cancelAutoFinish()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.finalizeSynchronously()
            let message = NSLocalizedString("scrollshot.auto_finished.alert", comment: "")
            let err = NSError(
                domain: "com.zeta.stitch.scrollshot",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
            self.finishBroadcastWithError(err)
        }
        autoEndWorkItem = item
        processingQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelAutoFinish() {
        autoEndWorkItem?.cancel()
        autoEndWorkItem = nil
    }

    private func finalizeSynchronously() {
        let group = DispatchGroup()
        group.enter()

        processingQueue.async { [weak self] in
            guard let self else {
                group.leave()
                return
            }
            guard !self.isFinalized else {
                group.leave()
                return
            }
            self.isFinalized = true
            self.cancelAutoFinish()

            if let kfURL = self.keyframesFolderURL {
                autoreleasepool {
                    self.videoStitcher.finalizeLiveCapture(
                        lastPixelBuffer: self.lastPixelBuffer,
                        orientation: self.lastOrientation,
                        keyframesFolder: kfURL
                    )
                }
            }

            let info = ScreenRecordingInfo(
                id: self.recordingID,
                date: Date(),
                frameWidth: Int(self.videoStitcher.frameSize.width),
                frameHeight: Int(self.videoStitcher.frameSize.height),
                orientationRaw: self.videoStitcher.orientationRaw,
                videoFileName: "recording.mp4",
                keyframesFolderName: "keyframes",
                matches: self.videoStitcher.matchItems
            )
            try? self.store.saveRecordingInfo(info)

            if self.store.notifyOnComplete {
                NotificationService.shared.postScrollshotReadyNotification(
                    recordingID: self.recordingID,
                    frameCount: self.videoStitcher.matchItems.count
                )
            }

            if let writer = self.videoWriter {
                writer.finish {
                    group.leave()
                }
            } else {
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + 8.0)
    }

    private func extractOrientation(from sampleBuffer: CMSampleBuffer) -> CGImagePropertyOrientation {
        guard let raw = CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber else {
            return .up
        }
        return CGImagePropertyOrientation(rawValue: raw.uint32Value) ?? .up
    }
}
