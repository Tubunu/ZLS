import Foundation

public final class AppGroupStore {
    public static let suiteName = "group.com.zeta.stitch"
    public static let urlScheme = "zetastitch"
    public static let scrollshotNotificationID = "com.zeta.stitch.scrollshot.complete"

    public enum Keys {
        public static let autoEndSeconds = "zeta.scrollshot.autoEndSeconds"
        public static let hapticOnStart = "zeta.scrollshot.hapticOnStart"
        public static let notifyOnComplete = "zeta.scrollshot.notifyOnComplete"
        public static let exportResolution = "zeta.export.resolution"
        public static let exportFormat = "zeta.export.format"
        public static let autoTrimStaticBars = "zeta.stitch.autoTrimStaticBars"
        public static let latestRecordingID = "zeta.scrollshot.latestRecordingID"
    }

    public static let shared = AppGroupStore()

    private let fileManager: FileManager
    private let defaults: UserDefaults

    public init(fileManager: FileManager = .default, userDefaults: UserDefaults? = nil) {
        self.fileManager = fileManager
        self.defaults = userDefaults ?? UserDefaults(suiteName: Self.suiteName) ?? .standard
    }

    // MARK: - Settings

    public var autoEndSeconds: AutoEndSeconds {
        get {
            guard defaults.object(forKey: Keys.autoEndSeconds) != nil else {
                return .oneHalf
            }
            let raw = defaults.double(forKey: Keys.autoEndSeconds)
            return AutoEndSeconds(rawValue: raw) ?? .oneHalf
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.autoEndSeconds)
        }
    }

    public var hapticOnStart: Bool {
        get {
            guard defaults.object(forKey: Keys.hapticOnStart) != nil else { return true }
            return defaults.bool(forKey: Keys.hapticOnStart)
        }
        set {
            defaults.set(newValue, forKey: Keys.hapticOnStart)
        }
    }

    public var notifyOnComplete: Bool {
        get {
            guard defaults.object(forKey: Keys.notifyOnComplete) != nil else { return true }
            return defaults.bool(forKey: Keys.notifyOnComplete)
        }
        set {
            defaults.set(newValue, forKey: Keys.notifyOnComplete)
        }
    }

    public var exportResolution: ExportResolution {
        get {
            guard let raw = defaults.string(forKey: Keys.exportResolution),
                  let val = ExportResolution(rawValue: raw) else {
                return .original
            }
            return val
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.exportResolution)
        }
    }

    public var exportFormat: ExportFormat {
        get {
            guard let raw = defaults.string(forKey: Keys.exportFormat),
                  let val = ExportFormat(rawValue: raw) else {
                return .png
            }
            return val
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.exportFormat)
        }
    }

    public var autoTrimStaticBars: Bool {
        get {
            guard defaults.object(forKey: Keys.autoTrimStaticBars) != nil else { return true }
            return defaults.bool(forKey: Keys.autoTrimStaticBars)
        }
        set {
            defaults.set(newValue, forKey: Keys.autoTrimStaticBars)
        }
    }

    public var latestRecordingID: String? {
        get { defaults.string(forKey: Keys.latestRecordingID) }
        set { defaults.set(newValue, forKey: Keys.latestRecordingID) }
    }

    // MARK: - Container Directories

    public var containerRootURL: URL {
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.suiteName) {
            return groupURL
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
    }

    public var recordingsRootURL: URL {
        let url = containerRootURL.appendingPathComponent("Scrollshots", isDirectory: true)
        ensureDirectory(url)
        return url
    }

    public func recordingFolderURL(for id: String) -> URL {
        let url = recordingsRootURL.appendingPathComponent(id, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    public func keyframesFolderURL(for id: String, folderName: String = "keyframes") -> URL {
        let url = recordingFolderURL(for: id).appendingPathComponent(folderName, isDirectory: true)
        ensureDirectory(url)
        return url
    }

    public func videoURL(for info: ScreenRecordingInfo) -> URL {
        recordingFolderURL(for: info.id).appendingPathComponent(info.videoFileName)
    }

    public func metadataURL(for id: String) -> URL {
        recordingFolderURL(for: id).appendingPathComponent("recording.json")
    }

    public func saveRecordingInfo(_ info: ScreenRecordingInfo) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(info)
        try data.write(to: metadataURL(for: info.id), options: .atomic)
        latestRecordingID = info.id
    }

    public func loadRecordingInfo(id: String) -> ScreenRecordingInfo? {
        let url = metadataURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ScreenRecordingInfo.self, from: data)
    }

    public func listRecordings() -> [ScreenRecordingInfo] {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: recordingsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return contents.compactMap { folder in
            let meta = folder.appendingPathComponent("recording.json")
            guard let data = try? Data(contentsOf: meta) else { return nil }
            return try? decoder.decode(ScreenRecordingInfo.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    public func deleteRecording(id: String) throws {
        let url = recordingsRootURL.appendingPathComponent(id, isDirectory: true)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        if latestRecordingID == id {
            latestRecordingID = listRecordings().first?.id
        }
    }

    private func ensureDirectory(_ url: URL) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
