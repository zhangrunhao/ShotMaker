import AVFoundation
import CoreImage
import Foundation
#if canImport(UIKit)
    import UIKit
#endif

struct HighlightClipGenerationProgress: Equatable {
    let completedMarkerCount: Int
    let totalMarkerCount: Int
}

enum HighlightClipPhotoLibraryDeliveryQuality: Equatable {
    case high
    case medium
}

struct HighlightClipAssetRequest: Equatable {
    let videoID: String
    let segments: [HighlightClipSegment]

    var requestedDuration: TimeInterval {
        segments.reduce(0) { total, segment in
            total + max(segment.duration, 0)
        }
    }

    func photoLibraryDeliveryQuality(
        forSourceDuration sourceDuration: TimeInterval,
    ) -> HighlightClipPhotoLibraryDeliveryQuality {
        guard sourceDuration.isFinite, sourceDuration > 0 else {
            return .high
        }

        let longSourceThreshold: TimeInterval = 10 * 60
        let smallRequestedFraction = 0.15
        guard sourceDuration >= longSourceThreshold else {
            return .high
        }

        return requestedDuration / sourceDuration <= smallRequestedFraction ? .medium : .high
    }
}

nonisolated struct HighlightClipMarkerLabelOverlayMetrics: Equatable {
    let fontSize: CGFloat
    let textOpacity: CGFloat
    let backgroundOpacity: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let cornerRadius: CGFloat

    static func make(
        renderSize: CGSize,
        style: MarkerLabelStyle,
    ) throws -> HighlightClipMarkerLabelOverlayMetrics {
        guard renderSize.width.isFinite,
              renderSize.height.isFinite,
              renderSize.width > 0,
              renderSize.height > 0
        else {
            throw VideoClipEditingError.missingVideoTrack
        }

        let normalized = style.normalized
        let fontSize = min(renderSize.width, renderSize.height)
            * CGFloat(normalized.fontSizeRatio)
        return HighlightClipMarkerLabelOverlayMetrics(
            fontSize: fontSize,
            textOpacity: CGFloat(normalized.textOpacity),
            backgroundOpacity: CGFloat(normalized.backgroundOpacity),
            horizontalPadding: fontSize * 0.55,
            verticalPadding: fontSize * 0.28,
            cornerRadius: fontSize * 0.25,
        )
    }
}

struct VideoClipEditingService {
    private let logger: AppLogging
    private let requestedOutputURL: URL?
    private let exportAsset: (AVAssetExportSession, URL, AVFileType) async throws -> Void
    private let cancelExportSession: (AVAssetExportSession) -> Void

    init(
        logger: AppLogging = AppLogger.shared,
        outputURL: URL? = nil,
        exportAsset: @escaping (AVAssetExportSession, URL, AVFileType) async throws -> Void = { exportSession, outputURL, fileType in
            try await exportSession.export(to: outputURL, as: fileType)
        },
        cancelExportSession: @escaping (AVAssetExportSession) -> Void = { exportSession in
            exportSession.cancelExport()
        },
    ) {
        self.logger = logger
        requestedOutputURL = outputURL
        self.exportAsset = exportAsset
        self.cancelExportSession = cancelExportSession
    }

    func makeTestClip(from sourceURL: URL) async throws -> URL {
        do {
            let asset = AVURLAsset(url: sourceURL)
            let duration: CMTime = try await asset.load(.duration)
            let segments = VideoClipSegmentPlanner.testSegments(forDuration: duration.seconds)
            return try await exportClip(from: asset, segments: segments)
        } catch {
            logExportFailure(operation: "testClip", error: error)
            throw error
        }
    }

    func makeHighlightClip(
        from segments: [HighlightClipSegment],
        markerLabelStyle: MarkerLabelStyle,
        progressHandler: (@MainActor (HighlightClipGenerationProgress) -> Void)? = nil,
        _ assetProvider: (HighlightClipAssetRequest) async throws -> AVAsset,
    ) async throws -> URL {
        do {
            let normalizedMarkerLabelStyle = markerLabelStyle.normalized
            return try await exportClip(
                from: segments,
                markerLabelStyle: normalizedMarkerLabelStyle,
                progressHandler: progressHandler,
                assetProvider: assetProvider,
            )
        } catch {
            logExportFailure(operation: "highlightClip", error: error)
            throw error
        }
    }

    private func exportClip(from asset: AVAsset, segments: [VideoClipSegment]) async throws -> URL {
        guard !segments.isEmpty else {
            throw VideoClipEditingError.emptySegments
        }

        let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = sourceVideoTracks.first else {
            throw VideoClipEditingError.missingVideoTrack
        }

        logger.info(
            "video.export.composition.started",
            category: .video,
            message: "开始组装视频导出时间线",
            context: [
                "operation": "testClip",
                "segmentCount": "\(segments.count)",
            ],
        )

        let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first

        // AVMutableComposition 是一个“空时间线”。
        // 我们不会直接修改原视频，而是把原视频中的若干时间片段插入到这条新时间线里。
        let composition = AVMutableComposition()

        // 新时间线至少需要一条视频轨道。后面每插入一个片段，都会写入这条轨道。
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid,
        ) else {
            throw VideoClipEditingError.compositionTrackUnavailable
        }

        // 如果原视频有音频，就给新时间线也建一条音频轨道。
        // 没有音频的视频也可以正常剪，不需要强制失败。
        let compositionAudioTrack: AVMutableCompositionTrack? = if sourceAudioTrack == nil {
            nil
        } else {
            composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid,
            )
        }

        // 保留原视频方向信息。否则竖屏视频导出后可能变成横着或旋转 90 度。
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        // insertionTime 表示“下一个片段应该放在新视频的哪个时间点”。
        // 第一个片段从 0 秒开始；每插完一段，就往后移动这段的时长。
        var insertionTime = CMTime.zero
        for (index, segment) in segments.enumerated() {
            // timeRange 表示从原视频里截哪一段，例如 0-2 秒，或 5-7 秒。
            let segmentDuration = CMTime(seconds: segment.duration, preferredTimescale: 600)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                duration: segmentDuration,
            )

            // 把原视频的这一段插入到新时间线的视频轨道里。
            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: insertionTime)

            // 音频也用同样的 timeRange 和 insertionTime，保证声音和画面同步拼接。
            if let sourceAudioTrack, let compositionAudioTrack {
                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: insertionTime)
            }

            // 下一段紧跟在当前片段后面，于是两个片段会拼成一个连续的新视频。
            insertionTime = CMTimeAdd(insertionTime, segmentDuration)
            logger.info(
                "video.export.composition.segment_inserted",
                category: .video,
                message: "已插入视频片段",
                context: [
                    "operation": "testClip",
                    "segmentIndex": "\(index + 1)",
                ],
            )
        }

        return try await export(composition)
    }

    private func exportClip(
        from segments: [HighlightClipSegment],
        markerLabelStyle: MarkerLabelStyle,
        progressHandler: (@MainActor (HighlightClipGenerationProgress) -> Void)?,
        assetProvider: (HighlightClipAssetRequest) async throws -> AVAsset,
    ) async throws -> URL {
        let validSegments = segments.filter { $0.duration > 0 }
        guard !validSegments.isEmpty else {
            throw VideoClipEditingError.emptySegments
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid,
        ) else {
            throw VideoClipEditingError.compositionTrackUnavailable
        }

        var compositionAudioTrack: AVMutableCompositionTrack?

        var insertionTime = CMTime.zero
        var didSetPreferredTransform = false
        var assetsByVideoID: [String: AVAsset] = [:]
        var overlayRanges: [HighlightClipOverlayRange] = []
        let assetRequestsByVideoID = Self.assetRequestsByVideoID(for: validSegments)
        let totalMarkerCount = validSegments.reduce(0) { $0 + $1.coveredMarkerCount }
        logger.info(
            "video.export.composition.started",
            category: .video,
            message: "开始组装视频导出时间线",
            context: [
                "operation": "highlightClip",
                "segmentCount": "\(validSegments.count)",
                "sourceVideoCount": "\(assetRequestsByVideoID.count)",
                "totalMarkerCount": "\(totalMarkerCount)",
            ],
        )
        progressHandler?(
            HighlightClipGenerationProgress(
                completedMarkerCount: 0,
                totalMarkerCount: totalMarkerCount,
            ),
        )

        for (index, segment) in validSegments.enumerated() {
            let asset: AVAsset
            if let cachedAsset = assetsByVideoID[segment.videoID] {
                asset = cachedAsset
            } else {
                asset = try await assetProvider(assetRequestsByVideoID[segment.videoID]!)
                assetsByVideoID[segment.videoID] = asset
            }

            let sourceVideoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let sourceVideoTrack = sourceVideoTracks.first else {
                throw VideoClipEditingError.missingVideoTrack
            }

            if !didSetPreferredTransform {
                compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)
                didSetPreferredTransform = true
            }

            let segmentDuration = CMTime(seconds: segment.duration, preferredTimescale: 600)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: segment.start, preferredTimescale: 600),
                duration: segmentDuration,
            )
            let outputTimeRange = CMTimeRange(start: insertionTime, duration: segmentDuration)

            try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: insertionTime)

            if let sourceAudioTrack = try await asset.loadTracks(withMediaType: .audio).first {
                if compositionAudioTrack == nil {
                    compositionAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid,
                    )
                }

                guard let compositionAudioTrack else {
                    throw VideoClipEditingError.compositionTrackUnavailable
                }

                try compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: insertionTime)
            }

            overlayRanges.append(HighlightClipOverlayRange(timeRange: outputTimeRange, label: segment.markerLabel))

            insertionTime = CMTimeAdd(insertionTime, segmentDuration)
            logger.info(
                "video.export.composition.segment_inserted",
                category: .video,
                message: "已插入视频片段",
                context: [
                    "operation": "highlightClip",
                    "segmentIndex": "\(index + 1)",
                    "markerCount": "\(segment.coveredMarkerCount)",
                ],
            )
        }

        return try await export(
            composition,
            outputNamePrefix: "ShotMarker-Highlight",
            videoComposition: try await Self.markerLabelVideoComposition(
                for: composition,
                overlayRanges: overlayRanges,
                style: markerLabelStyle,
            ),
            progressTotalMarkerCount: totalMarkerCount,
            progressHandler: progressHandler,
        )
    }

    private static func assetRequestsByVideoID(
        for segments: [HighlightClipSegment],
    ) -> [String: HighlightClipAssetRequest] {
        var segmentsByVideoID: [String: [HighlightClipSegment]] = [:]
        for segment in segments {
            segmentsByVideoID[segment.videoID, default: []].append(segment)
        }

        return segmentsByVideoID.reduce(into: [:]) { requests, element in
            let (videoID, segments) = element
            requests[videoID] = HighlightClipAssetRequest(videoID: videoID, segments: segments)
        }
    }

    private func export(
        _ composition: AVAsset,
        outputNamePrefix: String = "ShotMarker-TestClip",
        videoComposition: AVVideoComposition? = nil,
        progressTotalMarkerCount: Int? = nil,
        progressHandler: (@MainActor (HighlightClipGenerationProgress) -> Void)? = nil,
    ) async throws -> URL {
        let exportSessionConfiguration = Self.makeExportSession(
            for: composition,
            videoComposition: videoComposition,
        )
        guard let exportSession = exportSessionConfiguration.exportSession else {
            throw VideoClipEditingError.exportSessionUnavailable
        }

        let outputURL = requestedOutputURL ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("\(outputNamePrefix)-\(UUID().uuidString).mov")
        var outputSucceeded = false
        defer {
            if !outputSucceeded { try? FileManager.default.removeItem(at: outputURL) }
        }
        exportSession.videoComposition = videoComposition
        logger.info(
            "video.export.started",
            category: .video,
            message: "开始导出视频",
            context: [
                "outputFileExtension": outputURL.pathExtension,
                "outputNamePrefix": outputNamePrefix,
                "presetName": exportSessionConfiguration.presetName,
                "usesVideoComposition": "\(videoComposition != nil)",
            ],
        )

        let progressTask: Task<Void, Never>? = if let progressTotalMarkerCount, let progressHandler {
            Task { @MainActor in
                var lastReportedMarkerCount = 0
                while !Task.isCancelled {
                    let completedMarkerCount = Self.completedMarkerCount(
                        forExportProgress: exportSession.progress,
                        totalMarkerCount: progressTotalMarkerCount,
                        isFinished: false,
                    )

                    if completedMarkerCount > lastReportedMarkerCount {
                        lastReportedMarkerCount = completedMarkerCount
                        progressHandler(
                            HighlightClipGenerationProgress(
                                completedMarkerCount: completedMarkerCount,
                                totalMarkerCount: progressTotalMarkerCount,
                            ),
                        )
                    }

                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        } else {
            nil
        }
        defer {
            progressTask?.cancel()
        }

        let exportCancellation = VideoClipExportCancellationBox(
            exportSession: exportSession,
            cancelExportSession: cancelExportSession,
        )
        try await withTaskCancellationHandler {
            try await exportAsset(exportSession, outputURL, .mov)
            try Task.checkCancellation()
        } onCancel: {
            exportCancellation.cancel()
        }

        if let progressTotalMarkerCount, let progressHandler {
            progressHandler(
                HighlightClipGenerationProgress(
                    completedMarkerCount: Self.completedMarkerCount(
                        forExportProgress: exportSession.progress,
                        totalMarkerCount: progressTotalMarkerCount,
                        isFinished: true,
                    ),
                    totalMarkerCount: progressTotalMarkerCount,
                ),
            )
        }

        logger.info(
            "video.export.completed",
            category: .video,
            message: "视频导出完成",
            context: [
                "outputFileExtension": outputURL.pathExtension,
                "outputNamePrefix": outputNamePrefix,
            ],
        )

        outputSucceeded = true
        return outputURL
    }

    static func completedMarkerCount(
        forExportProgress progress: Float,
        totalMarkerCount: Int,
        isFinished: Bool,
    ) -> Int {
        guard totalMarkerCount > 0 else {
            return 0
        }

        if isFinished {
            return totalMarkerCount
        }

        let clampedProgress = min(max(Double(progress), 0), 1)
        let completedMarkerCount = Int(floor(clampedProgress * Double(totalMarkerCount)))
        return min(max(completedMarkerCount, 0), totalMarkerCount - 1)
    }

    private static func makeExportSession(
        for asset: AVAsset,
        videoComposition: AVVideoComposition?,
    ) -> (exportSession: AVAssetExportSession?, presetName: String) {
        let presetNames = if videoComposition == nil {
            [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality]
        } else {
            [AVAssetExportPresetHighestQuality]
        }

        for presetName in presetNames {
            if let exportSession = AVAssetExportSession(asset: asset, presetName: presetName) {
                return (exportSession, presetName)
            }
        }

        return (nil, presetNames.last ?? AVAssetExportPresetHighestQuality)
    }

    private func logExportFailure(operation: String, error: Error) {
        logger.error(
            "video.export.failed",
            category: .video,
            message: "视频导出失败",
            error: error as? VideoClipEditingError ?? .exportFailed,
            context: ["operation": operation, "errorCategory": error is CancellationError ? "cancelled" : "exportFailed"],
        )
    }

    private static func secondsString(_ value: TimeInterval) -> String {
        String(format: "%.3f", value)
    }

    private static func markerLabelVideoComposition(
        for asset: AVAsset,
        overlayRanges: [HighlightClipOverlayRange],
        style: MarkerLabelStyle,
    ) async throws -> AVVideoComposition? {
        #if canImport(UIKit)
            guard !overlayRanges.isEmpty else {
                return nil
            }

            let normalizedStyle = style.normalized
            guard normalizedStyle.textOpacity > 0 || normalizedStyle.backgroundOpacity > 0 else {
                return nil
            }

            let renderSize = try await markerLabelRenderSize(for: asset)
            let metrics = try HighlightClipMarkerLabelOverlayMetrics.make(
                renderSize: renderSize,
                style: normalizedStyle,
            )
            let overlayImagesByLabel = Dictionary(
                uniqueKeysWithValues: Set(overlayRanges.map(\.label)).compactMap { label in
                    makeMarkerLabelOverlayImage(
                        text: label,
                        metrics: metrics,
                    ).map { (label, $0) }
                },
            )

            guard !overlayImagesByLabel.isEmpty else {
                return nil
            }

            return try await AVVideoComposition(applyingFiltersTo: asset) { parameters in
                guard let overlayRange = overlayRanges.first(where: { $0.timeRange.containsTime(parameters.compositionTime) }),
                      let overlayImage = overlayImagesByLabel[overlayRange.label]
                else {
                    return AVCIImageFilteringResult(resultImage: parameters.sourceImage)
                }

                let sourceImage = parameters.sourceImage
                let origin = markerLabelCoreImageOrigin(
                    style: normalizedStyle,
                    overlaySize: overlayImage.extent.size,
                    imageExtent: sourceImage.extent,
                )
                let translatedOverlay = overlayImage.transformed(
                    by: CGAffineTransform(
                        translationX: origin.x - overlayImage.extent.minX,
                        y: origin.y - overlayImage.extent.minY,
                    ),
                )
                let outputImage = translatedOverlay
                    .composited(over: sourceImage)
                    .cropped(to: sourceImage.extent)

                return AVCIImageFilteringResult(resultImage: outputImage)
            }
        #else
            return nil
        #endif
    }

    nonisolated static func markerLabelCoreImageOrigin(
        style: MarkerLabelStyle,
        overlaySize: CGSize,
        imageExtent: CGRect,
    ) -> CGPoint {
        let normalized = style.normalized
        return MarkerLabelLayout.coreImageOrigin(
            for: CGPoint(
                x: CGFloat(normalized.normalizedCenterX),
                y: CGFloat(normalized.normalizedCenterY),
            ),
            labelSize: overlaySize,
            in: imageExtent,
        )
    }

    #if canImport(UIKit)
        private static func markerLabelRenderSize(for asset: AVAsset) async throws -> CGSize {
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw VideoClipEditingError.missingVideoTrack
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let transformedRect = CGRect(origin: .zero, size: naturalSize)
                .applying(preferredTransform)
            let renderSize = CGSize(
                width: abs(transformedRect.width),
                height: abs(transformedRect.height),
            )
            guard renderSize.width.isFinite,
                  renderSize.height.isFinite,
                  renderSize.width > 0,
                  renderSize.height > 0
            else {
                throw VideoClipEditingError.missingVideoTrack
            }

            return renderSize
        }

        private static func makeMarkerLabelOverlayImage(
            text: String,
            metrics: HighlightClipMarkerLabelOverlayMetrics,
        ) -> CIImage? {
            let font = UIFont.monospacedDigitSystemFont(ofSize: metrics.fontSize, weight: .black)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.white.withAlphaComponent(metrics.textOpacity),
                .paragraphStyle: paragraphStyle,
            ]
            let textSize = text.size(withAttributes: attributes)
            let imageSize = CGSize(
                width: ceil(textSize.width + metrics.horizontalPadding * 2),
                height: ceil(textSize.height + metrics.verticalPadding * 2),
            )
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: imageSize, format: format).image { _ in
                let bounds = CGRect(origin: .zero, size: imageSize)
                UIColor.black.withAlphaComponent(metrics.backgroundOpacity).setFill()
                UIBezierPath(roundedRect: bounds, cornerRadius: metrics.cornerRadius).fill()

                let textRect = bounds.insetBy(
                    dx: metrics.horizontalPadding,
                    dy: metrics.verticalPadding,
                )
                text.draw(in: textRect, withAttributes: attributes)
            }

            return CIImage(image: image)
        }
    #endif
}

private struct HighlightClipOverlayRange {
    let timeRange: CMTimeRange
    let label: String
}

nonisolated private final class VideoClipExportCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private let exportSession: AVAssetExportSession
    private let cancelExportSession: (AVAssetExportSession) -> Void
    private var isCancelled = false

    init(
        exportSession: AVAssetExportSession,
        cancelExportSession: @escaping (AVAssetExportSession) -> Void,
    ) {
        self.exportSession = exportSession
        self.cancelExportSession = cancelExportSession
    }

    func cancel() {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return
        }

        isCancelled = true
        let exportSession = exportSession
        let cancelExportSession = cancelExportSession
        lock.unlock()

        cancelExportSession(exportSession)
    }
}

enum VideoClipEditingError: LocalizedError {
    case emptySegments
    case missingVideoTrack
    case compositionTrackUnavailable
    case exportSessionUnavailable
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .emptySegments:
            "视频太短，无法生成测试剪辑。"
        case .missingVideoTrack:
            "没有找到可剪辑的视频轨道。"
        case .compositionTrackUnavailable:
            "无法创建视频拼接轨道。"
        case .exportSessionUnavailable:
            "无法创建视频导出任务。"
        case .exportFailed:
            "视频生成失败，请重试。"
        }
    }
}
