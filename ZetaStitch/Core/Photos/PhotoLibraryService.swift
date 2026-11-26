import Foundation
import Combine
import Photos
import UIKit
import AVFoundation
import ImageIO

public struct PhotoAlbumItem: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let count: Int
    public let collection: PHAssetCollection?
    public let isScreenRecordingsOnly: Bool

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: PhotoAlbumItem, rhs: PhotoAlbumItem) -> Bool {
        lhs.id == rhs.id
    }
}

public final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus
    @Published public private(set) var albums: [PhotoAlbumItem] = []
    @Published public private(set) var assets: [PHAsset] = []
    @Published public var selectedAlbumID: String = "screenshots"

    private let imageManager = PHCachingImageManager()

    public override init() {
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        super.init()
        PHPhotoLibrary.shared().register(self)
        if authorizationStatus == .authorized || authorizationStatus == .limited {
            reloadAlbumsAndAssets()
        }
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    public func requestPermission() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
            if status == .authorized || status == .limited {
                self.reloadAlbumsAndAssets()
            }
        }
    }

    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            self.reloadAlbumsAndAssets()
        }
    }

    public func reloadAlbumsAndAssets() {
        var builtAlbums: [PhotoAlbumItem] = []

        // 1. Screenshots Smart Album (primary default for Zeta)
        let screenshotsFetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumScreenshots, options: nil)
        if let col = screenshotsFetch.firstObject {
            let count = assetCount(in: col, screenRecordingsOnly: false)
            builtAlbums.append(PhotoAlbumItem(
                id: "screenshots",
                title: NSLocalizedString("album.screenshots", comment: ""),
                count: count,
                collection: col,
                isScreenRecordingsOnly: false
            ))
        }

        // 2. All Photos & Videos
        let recentsFetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: nil)
        if let col = recentsFetch.firstObject {
            let count = assetCount(in: col, screenRecordingsOnly: false)
            builtAlbums.append(PhotoAlbumItem(
                id: "recents",
                title: NSLocalizedString("album.recents", comment: ""),
                count: count,
                collection: col,
                isScreenRecordingsOnly: false
            ))
        }

        // 3. Screen Recordings (Videos)
        let videosFetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumVideos, options: nil)
        if let col = videosFetch.firstObject {
            let count = assetCount(in: col, screenRecordingsOnly: true)
            builtAlbums.append(PhotoAlbumItem(
                id: "screen_recordings",
                title: NSLocalizedString("album.videos", comment: ""),
                count: count,
                collection: col,
                isScreenRecordingsOnly: true
            ))
        }

        // 4. User custom albums
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        userAlbums.enumerateObjects { col, _, _ in
            let count = self.assetCount(in: col, screenRecordingsOnly: false)
            if count > 0 {
                builtAlbums.append(PhotoAlbumItem(
                    id: col.localIdentifier,
                    title: col.localizedTitle ?? NSLocalizedString("album.untitled", comment: ""),
                    count: count,
                    collection: col,
                    isScreenRecordingsOnly: false
                ))
            }
        }

        self.albums = builtAlbums
        if !builtAlbums.contains(where: { $0.id == selectedAlbumID }) {
            // Fall back to recents if screenshots smart album is empty/missing
            if let nonEmpty = builtAlbums.first(where: { $0.count > 0 }) ?? builtAlbums.first {
                selectedAlbumID = nonEmpty.id
            }
        } else if selectedAlbumID == "screenshots",
                  let shotAlbum = builtAlbums.first(where: { $0.id == "screenshots" }),
                  shotAlbum.count == 0,
                  let fallback = builtAlbums.first(where: { $0.count > 0 }) {
            selectedAlbumID = fallback.id
        }

        loadAssetsForSelectedAlbum()
    }

    public func selectAlbum(_ album: PhotoAlbumItem) {
        selectedAlbumID = album.id
        loadAssetsForSelectedAlbum()
    }

    private func loadAssetsForSelectedAlbum() {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        guard let album = albums.first(where: { $0.id == selectedAlbumID }),
              let collection = album.collection else {
            let allFetch = PHAsset.fetchAssets(with: options)
            self.assets = extractAssets(from: allFetch)
            return
        }

        if album.isScreenRecordingsOnly {
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        let fetch = PHAsset.fetchAssets(in: collection, options: options)
        self.assets = extractAssets(from: fetch)
    }

    private func assetCount(in collection: PHAssetCollection, screenRecordingsOnly: Bool) -> Int {
        let opts = PHFetchOptions()
        if screenRecordingsOnly {
            opts.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        }
        return PHAsset.fetchAssets(in: collection, options: opts).count
    }

    private func extractAssets(from result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var list: [PHAsset] = []
        list.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            list.append(asset)
        }
        return list
    }

    public func requestThumbnail(for asset: PHAsset, targetSize: CGSize, completion: @escaping (UIImage?) -> Void) -> PHImageRequestID {
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = true
        return imageManager.requestImage(for: asset, targetSize: targetSize, contentMode: .aspectFill, options: opts) { img, _ in
            completion(img)
        }
    }

    public func cancelThumbnailRequest(_ requestID: PHImageRequestID) {
        guard requestID != PHInvalidImageRequestID else { return }
        imageManager.cancelImageRequest(requestID)
    }

    public func loadFullResolutionCGImage(for asset: PHAsset) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let opts = PHImageRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = true
            opts.isSynchronous = false

            let lock = NSLock()
            var resumed = false
            func finish(_ result: Result<CGImage, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            imageManager.requestImageDataAndOrientation(for: asset, options: opts) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    finish(.failure(error))
                    return
                }
                guard let data,
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    finish(.failure(NSError(
                        domain: "PhotoLibraryService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to decode image"]
                    )))
                    return
                }
                // Respect EXIF orientation if needed by normalizing through UIImage
                let uiImg = UIImage(data: data)
                if let normalized = uiImg?.normalizedCGImage() {
                    finish(.success(normalized))
                } else {
                    finish(.success(cgImage))
                }
            }
        }
    }

    public func loadAVAsset(for asset: PHAsset) async throws -> AVAsset {
        try await withCheckedThrowingContinuation { continuation in
            let opts = PHVideoRequestOptions()
            opts.deliveryMode = .highQualityFormat
            opts.isNetworkAccessAllowed = true

            let lock = NSLock()
            var resumed = false
            func finish(_ result: Result<AVAsset, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            imageManager.requestAVAsset(forVideo: asset, options: opts) { avAsset, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    finish(.failure(error))
                    return
                }
                if let avAsset {
                    finish(.success(avAsset))
                } else {
                    finish(.failure(NSError(
                        domain: "PhotoLibraryService",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to load video asset"]
                    )))
                }
            }
        }
    }

    public func saveImageDataToPhotos(_ data: Data) async throws -> String? {
        var createdID: String?
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            createdID = request.placeholderForCreatedAsset?.localIdentifier
        }
        return createdID
    }

    public func deleteAssets(_ assetsToDelete: [PHAsset]) async throws {
        guard !assetsToDelete.isEmpty else { return }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assetsToDelete as NSFastEnumeration)
        }
    }
}

private extension UIImage {
    func normalizedCGImage() -> CGImage? {
        guard imageOrientation != .up else { return cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let drawn = renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
        return drawn.cgImage
    }
}
