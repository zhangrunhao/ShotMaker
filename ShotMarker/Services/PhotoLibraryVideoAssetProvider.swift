#if os(iOS)
    import AVFoundation
    import Foundation
    import Photos
    import UIKit

    nonisolated struct PhotoLibraryVideoAssetProvider {
        static let thumbnailTargetSize = CGSize(width: 320, height: 320)
        static let thumbnailContentMode: PHImageContentMode = .aspectFit

        static func makeThumbnailRequestOptions() -> PHImageRequestOptions {
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            options.isSynchronous = true
            return options
        }

        static func makeLocalThumbnailVideoRequestOptions() -> PHVideoRequestOptions {
            let options = PHVideoRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            return options
        }

        static func resolveThumbnailData(
            photoLibraryData: Data?,
            localVideoData: () async -> Data?,
        ) async -> Data? {
            guard photoLibraryData == nil else {
                return photoLibraryData
            }

            return await localVideoData()
        }

        func ensureReadAccess() async throws {
            let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            switch status {
            case .authorized, .limited:
                return
            case .notDetermined:
                let requestedStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                guard requestedStatus == .authorized || requestedStatus == .limited else {
                    throw HighlightVideoSelectionError.photoLibraryAccessDenied
                }
            case .denied, .restricted:
                throw HighlightVideoSelectionError.photoLibraryAccessDenied
            @unknown default:
                throw HighlightVideoSelectionError.photoLibraryAccessDenied
            }
        }

        func photoAsset(with localIdentifier: String) throws -> PHAsset {
            let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
            guard let asset = result.firstObject else {
                throw HighlightVideoSelectionError.videoLoadFailed
            }

            return asset
        }

        func metadata(from asset: PHAsset) throws -> TrainingVideoMetadata {
            guard let recordedStartAt = asset.creationDate else {
                throw HighlightVideoSelectionError.missingRecordedStartAt
            }

            guard asset.duration.isFinite, asset.duration > 0 else {
                throw HighlightVideoSelectionError.invalidDuration
            }

            return TrainingVideoMetadata(recordedStartAt: recordedStartAt, duration: asset.duration)
        }

        func thumbnailData(from asset: PHAsset) async -> Data? {
            let options = Self.makeThumbnailRequestOptions()

            var photoLibraryData: Data?
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: Self.thumbnailTargetSize,
                contentMode: Self.thumbnailContentMode,
                options: options,
            ) { image, _ in
                photoLibraryData = image?.jpegData(compressionQuality: 0.72)
            }

            return await Self.resolveThumbnailData(photoLibraryData: photoLibraryData) {
                await localVideoThumbnailData(from: asset)
            }
        }

        private func localVideoThumbnailData(from asset: PHAsset) async -> Data? {
            do {
                let localAsset = try await localThumbnailAVAsset(for: asset)
                let generator = AVAssetImageGenerator(asset: localAsset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = Self.thumbnailTargetSize
                let image = try await cgImage(from: generator, at: .zero)
                return UIImage(cgImage: image).jpegData(compressionQuality: 0.72)
            } catch {
                return nil
            }
        }

        private func localThumbnailAVAsset(for asset: PHAsset) async throws -> AVAsset {
            let options = Self.makeLocalThumbnailVideoRequestOptions()
            return try await withCheckedThrowingContinuation { continuation in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                        return
                    }

                    if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
                        continuation.resume(throwing: HighlightVideoSelectionError.videoLoadFailed)
                        return
                    }

                    guard let avAsset else {
                        continuation.resume(throwing: HighlightVideoSelectionError.videoNotReady)
                        return
                    }

                    continuation.resume(returning: avAsset)
                }
            }
        }

        private func cgImage(
            from generator: AVAssetImageGenerator,
            at time: CMTime,
        ) async throws -> CGImage {
            try await withCheckedThrowingContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }

                    guard let image else {
                        continuation.resume(throwing: HighlightVideoSelectionError.videoLoadFailed)
                        return
                    }

                    continuation.resume(returning: image)
                }
            }
        }

        func requestAVAsset(
            for asset: PHAsset,
            deliveryQuality: HighlightClipPhotoLibraryDeliveryQuality,
            allowsNetworkAccess: Bool = true,
            progressHandler: (@Sendable (Double) -> Void)? = nil,
        ) async throws -> AVAsset {
            let options = PHVideoRequestOptions()
            options.deliveryMode = deliveryQuality.photoVideoRequestDeliveryMode
            options.isNetworkAccessAllowed = allowsNetworkAccess
            if let progressHandler {
                options.progressHandler = { progress, _, _, _ in
                    progressHandler(progress)
                }
            }

            let cancellationBox = PhotoLibraryAssetRequestCancellationBox()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let requestID = PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                        if let error = info?[PHImageErrorKey] as? Error {
                            continuation.resume(throwing: error)
                            return
                        }

                        if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }

                        guard let avAsset else {
                            continuation.resume(throwing: HighlightVideoSelectionError.videoLoadFailed)
                            return
                        }

                        continuation.resume(returning: avAsset)
                    }
                    cancellationBox.setRequestID(requestID)
                }
            } onCancel: {
                cancellationBox.cancel()
            }
        }

        func requestLocalAVAsset(for asset: PHAsset) async throws {
            let options = PHVideoRequestOptions()
            options.deliveryMode = .mediumQualityFormat
            options.isNetworkAccessAllowed = false

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                    if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                        return
                    }

                    if let isCancelled = info?[PHImageCancelledKey] as? Bool, isCancelled {
                        continuation.resume(throwing: HighlightVideoSelectionError.videoLoadFailed)
                        return
                    }

                    guard avAsset != nil else {
                        continuation.resume(throwing: HighlightVideoSelectionError.videoNotReady)
                        return
                    }

                    continuation.resume()
                }
            }
        }
    }

    extension HighlightClipPhotoLibraryDeliveryQuality {
        nonisolated var photoVideoRequestDeliveryMode: PHVideoRequestOptionsDeliveryMode {
            switch self {
            case .high:
                .highQualityFormat
            case .medium:
                .mediumQualityFormat
            }
        }
    }

    nonisolated private final class PhotoLibraryAssetRequestCancellationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID = PHInvalidImageRequestID
        private var isCancelled = false

        func setRequestID(_ requestID: PHImageRequestID) {
            lock.lock()
            if isCancelled {
                lock.unlock()
                PHImageManager.default().cancelImageRequest(requestID)
                return
            }

            self.requestID = requestID
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let currentRequestID = requestID
            lock.unlock()

            guard currentRequestID != PHInvalidImageRequestID else {
                return
            }

            PHImageManager.default().cancelImageRequest(currentRequestID)
        }
    }
#endif
