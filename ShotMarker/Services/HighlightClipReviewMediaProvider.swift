import AVFoundation
import CoreGraphics
import Foundation
#if os(iOS)
    import Photos
    import UIKit
#endif

nonisolated struct HighlightClipFrameRequest: Hashable {
    private static let timescale: CMTimeScale = 600

    let videoID: String
    let timeValue: CMTimeValue
    let pixelWidth: Int
    let pixelHeight: Int

    init(videoID: String, time: TimeInterval, targetSize: CGSize) {
        self.videoID = videoID
        timeValue = time.isFinite
            ? CMTime(seconds: time, preferredTimescale: Self.timescale).value
            : 0
        pixelWidth = targetSize.width.isFinite ? Int(targetSize.width.rounded()) : 0
        pixelHeight = targetSize.height.isFinite ? Int(targetSize.height.rounded()) : 0
    }

    var time: TimeInterval {
        CMTime(value: timeValue, timescale: Self.timescale).seconds
    }

    var targetSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }
}

enum HighlightClipReviewMediaError: LocalizedError, Equatable {
    case invalidRequest
    case sourceUnavailable
    case assetLoadFailed
    case frameUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "媒体帧请求无效。"
        case .sourceUnavailable:
            "来源视频已不可用，请排除此片段或重新选择视频。"
        case .assetLoadFailed:
            "暂时无法读取视频，请重试。"
        case .frameUnavailable:
            "暂时无法读取此处画面。"
        }
    }
}

@MainActor
final class HighlightClipReviewMediaProvider {
    typealias LoadAsset = (SelectedTrainingVideo) async throws -> AVAsset
    typealias GenerateFrame = (AVAsset, HighlightClipFrameRequest) async throws -> Data

    private let cacheLimit: Int
    private let loadAsset: LoadAsset
    private let generateFrame: GenerateFrame
    private var assetsByVideoID: [String: AVAsset] = [:]
    private var frameDataByRequest: [HighlightClipFrameRequest: Data] = [:]
    private var frameRequestRecency: [HighlightClipFrameRequest] = []

    init(
        cacheLimit: Int = 64,
        loadAsset: @escaping LoadAsset,
        generateFrame: @escaping GenerateFrame,
    ) {
        self.cacheLimit = max(cacheLimit, 0)
        self.loadAsset = loadAsset
        self.generateFrame = generateFrame
    }

    func asset(for video: SelectedTrainingVideo) async throws -> AVAsset {
        try Task.checkCancellation()
        guard !video.id.isEmpty else {
            throw HighlightClipReviewMediaError.invalidRequest
        }
        if let cached = assetsByVideoID[video.id] {
            return cached
        }

        do {
            let asset = try await loadAsset(video)
            try Task.checkCancellation()
            assetsByVideoID[video.id] = asset
            return asset
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HighlightClipReviewMediaError {
            throw error
        } catch {
            throw HighlightClipReviewMediaError.assetLoadFailed
        }
    }

    func validateSourceAvailability(for video: SelectedTrainingVideo) async throws {
        try Task.checkCancellation()
        guard !video.id.isEmpty else {
            throw HighlightClipReviewMediaError.invalidRequest
        }

        do {
            let refreshedAsset = try await loadAsset(video)
            try Task.checkCancellation()
            assetsByVideoID[video.id] = refreshedAsset
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HighlightClipReviewMediaError {
            throw error
        } catch {
            throw HighlightClipReviewMediaError.assetLoadFailed
        }
    }

    func frameData(
        for video: SelectedTrainingVideo,
        at time: TimeInterval,
        targetSize: CGSize,
    ) async throws -> Data {
        let request = try makeRequest(video: video, time: time, targetSize: targetSize)
        if let cached = cachedFrameData(for: request) {
            return cached
        }

        let asset = try await asset(for: video)
        return try await frameData(using: asset, request: request)
    }

    func thumbnailData(
        for item: HighlightClipReviewItem,
        video: SelectedTrainingVideo,
        targetSize: CGSize,
    ) async throws -> Data {
        try await frameData(
            for: video,
            at: item.start + item.duration / 2,
            targetSize: targetSize,
        )
    }

    func filmstripFrames(
        for video: SelectedTrainingVideo,
        timeRange: HighlightClipRange,
        count: Int,
        targetSize: CGSize,
    ) async throws -> [Data?] {
        guard count > 0,
              isValid(timeRange: timeRange, videoDuration: video.duration),
              isValid(targetSize: targetSize)
        else {
            throw HighlightClipReviewMediaError.invalidRequest
        }

        try Task.checkCancellation()
        let asset = try await asset(for: video)
        let binDuration = timeRange.duration / Double(count)
        var frames: [Data?] = []
        frames.reserveCapacity(count)

        for index in 0 ..< count {
            try Task.checkCancellation()
            let time = timeRange.start + (Double(index) + 0.5) * binDuration
            let request = try makeRequest(video: video, time: time, targetSize: targetSize)
            if let cached = cachedFrameData(for: request) {
                frames.append(cached)
                continue
            }

            do {
                frames.append(try await frameData(using: asset, request: request))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                frames.append(nil)
            }
        }

        return frames
    }

    func removeAllCachedResources() {
        assetsByVideoID.removeAll()
        frameDataByRequest.removeAll()
        frameRequestRecency.removeAll()
    }

    private func frameData(
        using asset: AVAsset,
        request: HighlightClipFrameRequest,
    ) async throws -> Data {
        if let cached = cachedFrameData(for: request) {
            return cached
        }

        do {
            try Task.checkCancellation()
            let data = try await generateFrame(asset, request)
            try Task.checkCancellation()
            cache(data, for: request)
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HighlightClipReviewMediaError.frameUnavailable
        }
    }

    private func makeRequest(
        video: SelectedTrainingVideo,
        time: TimeInterval,
        targetSize: CGSize,
    ) throws -> HighlightClipFrameRequest {
        guard !video.id.isEmpty,
              video.duration.isFinite,
              video.duration > 0,
              time.isFinite,
              time >= 0,
              time <= video.duration,
              isValid(targetSize: targetSize)
        else {
            throw HighlightClipReviewMediaError.invalidRequest
        }

        let request = HighlightClipFrameRequest(
            videoID: video.id,
            time: time,
            targetSize: targetSize,
        )
        guard request.pixelWidth > 0, request.pixelHeight > 0 else {
            throw HighlightClipReviewMediaError.invalidRequest
        }
        return request
    }

    private func isValid(
        timeRange: HighlightClipRange,
        videoDuration: TimeInterval,
    ) -> Bool {
        videoDuration.isFinite
            && videoDuration > 0
            && timeRange.start.isFinite
            && timeRange.duration.isFinite
            && timeRange.start >= 0
            && timeRange.duration > 0
            && timeRange.end <= videoDuration
    }

    private func isValid(targetSize: CGSize) -> Bool {
        targetSize.width.isFinite
            && targetSize.height.isFinite
            && targetSize.width > 0
            && targetSize.height > 0
    }

    private func cachedFrameData(for request: HighlightClipFrameRequest) -> Data? {
        guard let data = frameDataByRequest[request] else {
            return nil
        }

        frameRequestRecency.removeAll { $0 == request }
        frameRequestRecency.append(request)
        return data
    }

    private func cache(_ data: Data, for request: HighlightClipFrameRequest) {
        guard cacheLimit > 0 else {
            return
        }

        frameDataByRequest[request] = data
        frameRequestRecency.removeAll { $0 == request }
        frameRequestRecency.append(request)

        while frameRequestRecency.count > cacheLimit {
            let evicted = frameRequestRecency.removeFirst()
            frameDataByRequest[evicted] = nil
        }
    }
}

#if os(iOS)
    extension HighlightClipReviewMediaProvider {
        static func live(
            cacheLimit: Int = 64,
            photoLibraryAssetProvider: PhotoLibraryVideoAssetProvider = PhotoLibraryVideoAssetProvider(),
            loadTaskAsset: LoadAsset? = nil,
        ) -> HighlightClipReviewMediaProvider {
            HighlightClipReviewMediaProvider(
                cacheLimit: cacheLimit,
                loadAsset: { video in
                    if let loadTaskAsset { return try await loadTaskAsset(video) }
                    if let fileURL = URL(string: video.id), fileURL.isFileURL {
                        guard FileManager.default.fileExists(atPath: fileURL.path) else {
                            throw HighlightClipReviewMediaError.sourceUnavailable
                        }
                        return AVURLAsset(url: fileURL)
                    }

                    do {
                        try await photoLibraryAssetProvider.ensureReadAccess()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw HighlightClipReviewMediaError.assetLoadFailed
                    }

                    let photoAsset: PHAsset
                    do {
                        photoAsset = try photoLibraryAssetProvider.photoAsset(with: video.id)
                    } catch {
                        throw HighlightClipReviewMediaError.sourceUnavailable
                    }

                    do {
                        return try await photoLibraryAssetProvider.requestAVAsset(
                            for: photoAsset,
                            deliveryQuality: .medium,
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        throw HighlightClipReviewMediaError.assetLoadFailed
                    }
                },
                generateFrame: { asset, request in
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = request.targetSize

                    let image = try await withTaskCancellationHandler {
                        try await withCheckedThrowingContinuation {
                            (continuation: CheckedContinuation<CGImage, Error>) in
                            let time = CMTime(value: request.timeValue, timescale: 600)
                            generator.generateCGImageAsynchronously(for: time) { image, _, error in
                                if let error {
                                    continuation.resume(throwing: error)
                                    return
                                }

                                guard let image else {
                                    continuation.resume(
                                        throwing: HighlightClipReviewMediaError.frameUnavailable,
                                    )
                                    return
                                }

                                continuation.resume(returning: image)
                            }
                        }
                    } onCancel: {
                        generator.cancelAllCGImageGeneration()
                    }

                    guard let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.72) else {
                        throw HighlightClipReviewMediaError.frameUnavailable
                    }
                    return data
                },
            )
        }
    }
#endif
