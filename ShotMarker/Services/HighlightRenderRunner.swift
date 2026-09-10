import AVFoundation
import Foundation

@MainActor
protocol HighlightRenderRunning {
    func run(execution: HighlightRenderExecution, outputURL: URL,
        onProgress: @escaping @MainActor (HighlightJobProgress) -> Void) async throws -> URL
}

struct HighlightRenderRunner: HighlightRenderRunning {
    let assetForVideo: (HighlightTaskVideo, HighlightClipAssetRequest) async throws -> AVAsset
    let logger: AppLogging

    func run(execution: HighlightRenderExecution, outputURL: URL,
        onProgress: @escaping @MainActor (HighlightJobProgress) -> Void) async throws -> URL {
        let snapshot = execution.snapshot
        let segments = try HighlightClipReviewPlanner.validateConfirmedSegments(snapshot.segments,
            videos: snapshot.videos.map(\.selectedTrainingVideo),
            validMarkerIDs: Set(snapshot.trainingSnapshot.markers.map(\.id)))
        let videos = Dictionary(uniqueKeysWithValues: snapshot.videos.map { ($0.id.uuidString, $0) })
        try Task.checkCancellation()
        let service = VideoClipEditingService(logger: logger, outputURL: outputURL)
        return try await service.makeHighlightClip(from: segments.map(\.highlightClipSegment),
            markerLabelStyle: snapshot.clipSettings.markerLabelStyle,
            progressHandler: { onProgress(HighlightJobProgress(completedMarkerCount: $0.completedMarkerCount, totalMarkerCount: $0.totalMarkerCount)) },
            { request in
                guard let video = videos[request.videoID] else { throw HighlightTaskError.sourceUnavailable }
                return try await assetForVideo(video, request)
            })
    }
}
