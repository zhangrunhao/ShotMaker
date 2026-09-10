import AVFoundation
import Foundation

extension HighlightTaskManager {
    static func live(logger: AppLogging = AppLogger.shared,
        analytics: AnalyticsTracking = NoopAnalyticsTracker()) -> HighlightTaskManager {
        let files = HighlightTaskFileStore()
        let media = HighlightTaskMedia(fileStore: files)
        let saver = VideoClipPhotoLibrarySaver(logger: logger)
        return HighlightTaskManager(store: HighlightTaskStore(), fileStore: files,
            runner: HighlightRenderRunner(assetForVideo: { video, request in
                try await media.asset(for: video, quality: request.photoLibraryDeliveryQuality(forSourceDuration: video.duration))
            }, logger: logger), validateSource: { video in
                let asset = try await media.asset(for: video)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration + 1.0 / 600 >= video.duration,
                      !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw HighlightTaskError.sourceUnavailable }
            }, saveVideo: { try await saver.saveVideo(at: $0) }, analytics: analytics, logger: logger)
    }
}

struct HighlightTaskMedia {
    let fileStore: HighlightTaskFileStore
    private let photoProvider = PhotoLibraryVideoAssetProvider()

    func asset(for video: HighlightTaskVideo, quality: HighlightClipPhotoLibraryDeliveryQuality = .medium) async throws -> AVAsset {
        switch video.source {
        case .photoLibraryAsset(let identifier):
            try await photoProvider.ensureReadAccess()
            let photo = try photoProvider.photoAsset(with: identifier)
            try await photoProvider.requestLocalAVAsset(for: photo)
            return try await photoProvider.requestAVAsset(for: photo, deliveryQuality: quality, allowsNetworkAccess: false)
        case .taskInputFile(let path):
            let url = try fileStore.url(forRelativePath: path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw HighlightTaskError.sourceUnavailable }
            return AVURLAsset(url: url)
        }
    }

    func selectionVideo(for video: HighlightTaskVideo) throws -> SelectedTrainingVideo {
        let sourceID: String
        switch video.source {
        case .photoLibraryAsset(let identifier): sourceID = identifier
        case .taskInputFile(let path): sourceID = try fileStore.url(forRelativePath: path).absoluteString
        }
        return SelectedTrainingVideo(id: sourceID, recordedStartAt: video.recordedStartAt,
            duration: video.duration, reviewSourceIdentity: video.sourceIdentity)
    }
}
