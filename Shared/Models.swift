import Foundation
import CoreGraphics

public enum StitchMode: String, Codable, CaseIterable, Identifiable {
    case longStitch
    case vertical
    case horizontal

    public var id: String { rawValue }
}

public enum ExportResolution: String, Codable, CaseIterable, Identifiable {
    case original
    case shortSide2048
    case shortSide1080

    public var id: String { rawValue }

    public var maxShortSide: CGFloat? {
        switch self {
        case .original: return nil
        case .shortSide2048: return 2048
        case .shortSide1080: return 1080
        }
    }
}

public enum ExportFormat: String, Codable, CaseIterable, Identifiable {
    case png
    case heic
    case jpeg

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .png: return "png"
        case .heic: return "heic"
        case .jpeg: return "jpg"
        }
    }
}

public enum AutoEndSeconds: Double, Codable, CaseIterable, Identifiable {
    case never = 0
    case half = 0.5
    case one = 1.0
    case oneHalf = 1.5
    case two = 2.0
    case twoHalf = 2.5
    case three = 3.0

    public var id: Double { rawValue }
}

public enum SeamMatchStatus: Equatable, Codable {
    case matched(confidence: Double)
    case noMatch
    case manual

    public var needsAttention: Bool {
        if case .noMatch = self { return true }
        return false
    }
}

/// Represents the seam between `topIndex` and `topIndex + 1` in a stitched sequence.
public struct StitchSeam: Identifiable, Equatable, Codable {
    public let id: UUID
    public let topIndex: Int
    /// Pixels trimmed from the bottom of the upper frame (e.g. static tab bar / home bar).
    public var topCropBottom: Int
    /// Pixels trimmed from the top of the lower frame (overlap + static status bar).
    public var botCropTop: Int
    /// Detected vertical overlap height in pixels (for informative UI display).
    public var overlapHeight: Int
    public var status: SeamMatchStatus

    public init(
        id: UUID = UUID(),
        topIndex: Int,
        topCropBottom: Int = 0,
        botCropTop: Int = 0,
        overlapHeight: Int = 0,
        status: SeamMatchStatus = .matched(confidence: 1.0)
    ) {
        self.id = id
        self.topIndex = topIndex
        self.topCropBottom = max(0, topCropBottom)
        self.botCropTop = max(0, botCropTop)
        self.overlapHeight = max(0, overlapHeight)
        self.status = status
    }
}

public struct NormalizedCropRect: Equatable, Codable {
    public var top: CGFloat
    public var bottom: CGFloat
    public var left: CGFloat
    public var right: CGFloat

    public static let full = NormalizedCropRect(top: 0, bottom: 0, left: 0, right: 0)

    public init(top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) {
        let clampedTop = min(max(top, 0), 0.85)
        let clampedBot = min(max(bottom, 0), 0.85 - clampedTop)
        let clampedLeft = min(max(left, 0), 0.85)
        let clampedRight = min(max(right, 0), 0.85 - clampedLeft)
        self.top = clampedTop
        self.bottom = clampedBot
        self.left = clampedLeft
        self.right = clampedRight
    }

    public var isFull: Bool {
        top < 0.001 && bottom < 0.001 && left < 0.001 && right < 0.001
    }

    public func pixelRect(for size: CGSize) -> CGRect {
        let x = (left * size.width).rounded()
        let y = (top * size.height).rounded()
        let maxX = ((1.0 - right) * size.width).rounded()
        let maxY = ((1.0 - bottom) * size.height).rounded()
        return CGRect(
            x: x,
            y: y,
            width: max(1, maxX - x),
            height: max(1, maxY - y)
        )
    }
}

public struct ScrollbarRegion: Equatable, Codable, Identifiable {
    public let id: UUID
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let leftPadding: Int
    public let rightPadding: Int

    public init(
        id: UUID = UUID(),
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        leftPadding: Int = 2,
        rightPadding: Int = 2
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.leftPadding = leftPadding
        self.rightPadding = rightPadding
    }
}

public struct VideoMatchItem: Codable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let frameIndex: Int
    public let totalOffset: CGFloat
    public let overlapHeight: Int
    public let isMatch: Bool
    public let keyframeFileName: String

    public init(
        index: Int,
        frameIndex: Int,
        totalOffset: CGFloat,
        overlapHeight: Int,
        isMatch: Bool,
        keyframeFileName: String
    ) {
        self.index = index
        self.frameIndex = frameIndex
        self.totalOffset = totalOffset
        self.overlapHeight = overlapHeight
        self.isMatch = isMatch
        self.keyframeFileName = keyframeFileName
    }
}

public struct ScreenRecordingInfo: Codable, Equatable, Identifiable {
    public let id: String
    public let date: Date
    public let frameWidth: Int
    public let frameHeight: Int
    public let orientationRaw: Int
    public let videoFileName: String
    public let keyframesFolderName: String
    public let matches: [VideoMatchItem]

    public init(
        id: String,
        date: Date = Date(),
        frameWidth: Int,
        frameHeight: Int,
        orientationRaw: Int = 0,
        videoFileName: String = "recording.mp4",
        keyframesFolderName: String = "keyframes",
        matches: [VideoMatchItem]
    ) {
        self.id = id
        self.date = date
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.orientationRaw = orientationRaw
        self.videoFileName = videoFileName
        self.keyframesFolderName = keyframesFolderName
        self.matches = matches
    }
}
