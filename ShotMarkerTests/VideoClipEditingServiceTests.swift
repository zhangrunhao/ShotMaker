@testable import ShotMarker
import AVFoundation
import XCTest

final class VideoClipEditingServiceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testMakeTestClipExportsTwoSegmentsIntoOneMovie() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 6)
        let logger = SpyAppLogger()

        let outputURL = try await VideoClipEditingService(logger: logger).makeTestClip(from: sourceURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertNotEqual(outputURL, sourceURL)

        let outputAsset = AVURLAsset(url: outputURL)
        let outputDuration: CMTime = try await outputAsset.load(.duration)
        XCTAssertEqual(outputDuration.seconds, 4, accuracy: 0.2)

        XCTAssertEqual(logger.entry(named: "video.export.composition.started")?.level, .info)
        XCTAssertEqual(logger.entry(named: "video.export.composition.started")?.context["segmentCount"], "2")
        XCTAssertEqual(logger.entries(named: "video.export.composition.segment_inserted").count, 2)
        XCTAssertEqual(logger.entry(named: "video.export.completed")?.level, .info)
        XCTAssertEqual(logger.entry(named: "video.export.completed")?.context["outputFileExtension"], "mov")
    }

    func testMakeHighlightClipExportsPlannedSegmentsIntoOneMovie() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("highlight-source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 8)
        let firstMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002001"))
        let secondMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002002"))
        let segments = [
            HighlightClipSegment(
                markerIDs: [firstMarkerID],
                videoID: "video",
                start: 1,
                duration: 2,
            ),
            HighlightClipSegment(
                markerIDs: [secondMarkerID],
                videoID: "video",
                start: 5,
                duration: 1,
            ),
        ]

        var requestedVideoIDs: [String] = []
        let outputURL = try await VideoClipEditingService().makeHighlightClip(
            from: segments,
            markerLabelStyle: .default,
        ) { request in
            requestedVideoIDs.append(request.videoID)
            return AVURLAsset(url: sourceURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(requestedVideoIDs, ["video"])
        let outputAsset = AVURLAsset(url: outputURL)
        let outputDuration: CMTime = try await outputAsset.load(.duration)
        XCTAssertEqual(outputDuration.seconds, 3, accuracy: 0.2)
    }

    func testMakeHighlightClipUsesMarkerLabelOverlayVideoComposition() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("highlight-fast-export-source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 8)
        let logger = SpyAppLogger()
        let markerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002501"))
        let segments = [
            HighlightClipSegment(
                markerIDs: [markerID],
                videoID: "video",
                start: 1,
                duration: 2,
            ),
        ]

        let outputURL = try await VideoClipEditingService(logger: logger)
            .makeHighlightClip(from: segments, markerLabelStyle: .default) { _ in
                AVURLAsset(url: sourceURL)
            }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let exportStartedEntry = try XCTUnwrap(logger.entry(named: "video.export.started"))
        XCTAssertEqual(exportStartedEntry.context["outputNamePrefix"], "ShotMarker-Highlight")
        XCTAssertEqual(exportStartedEntry.context["presetName"], AVAssetExportPresetHighestQuality)
        XCTAssertEqual(exportStartedEntry.context["usesVideoComposition"], "true")
    }

    func testMakeHighlightClipRequestsOnlyNeededSegmentsForEachSourceVideo() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("highlight-request-source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 40)
        let firstMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002301"))
        let secondMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002302"))
        let thirdMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002303"))
        let segments = [
            HighlightClipSegment(
                markerIDs: [firstMarkerID],
                videoID: "long-video",
                start: 6,
                duration: 6,
            ),
            HighlightClipSegment(
                markerIDs: [secondMarkerID],
                videoID: "short-video",
                start: 10,
                duration: 5,
            ),
            HighlightClipSegment(
                markerIDs: [thirdMarkerID],
                videoID: "long-video",
                start: 18,
                duration: 6,
            ),
        ]

        var assetRequests: [HighlightClipAssetRequest] = []
        _ = try await VideoClipEditingService().makeHighlightClip(
            from: segments,
            markerLabelStyle: .default,
        ) { request in
            assetRequests.append(request)
            return AVURLAsset(url: sourceURL)
        }

        XCTAssertEqual(assetRequests.map(\.videoID), ["long-video", "short-video"])
        XCTAssertEqual(assetRequests[0].segments.map(\.start), [6, 18])
        XCTAssertEqual(assetRequests[0].requestedDuration, 12)
        XCTAssertEqual(assetRequests[1].segments.map(\.start), [10])
        XCTAssertEqual(assetRequests[1].requestedDuration, 5)
    }

    func testAssetRequestPrefersMediumDeliveryForSmallClipSetFromLongSourceVideo() throws {
        let markerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002401"))
        let request = HighlightClipAssetRequest(
            videoID: "long-video",
            segments: [
                HighlightClipSegment(
                    markerIDs: [markerID],
                    videoID: "long-video",
                    start: 1_200,
                    duration: 120,
                ),
            ],
        )

        XCTAssertEqual(
            request.photoLibraryDeliveryQuality(forSourceDuration: 3_600),
            .medium,
        )
        XCTAssertEqual(
            request.photoLibraryDeliveryQuality(forSourceDuration: 240),
            .high,
        )
    }

    @MainActor
    func testMakeHighlightClipReportsMatchedMarkerProgress() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("highlight-progress-source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 8)
        let firstMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002101"))
        let secondMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002102"))
        let segments = [
            HighlightClipSegment(
                markerIDs: [firstMarkerID],
                videoID: "video",
                start: 1,
                duration: 2,
                markerNumber: 1,
                markerTotalCount: 2,
            ),
            HighlightClipSegment(
                markerIDs: [secondMarkerID],
                videoID: "video",
                start: 5,
                duration: 1,
                markerNumber: 2,
                markerTotalCount: 2,
            ),
        ]

        var progressUpdates: [HighlightClipGenerationProgress] = []
        let outputURL = try await VideoClipEditingService().makeHighlightClip(
            from: segments,
            markerLabelStyle: .default,
            progressHandler: { progressUpdates.append($0) },
        ) { _ in
            AVURLAsset(url: sourceURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(progressUpdates.first, HighlightClipGenerationProgress(completedMarkerCount: 0, totalMarkerCount: 2))
        XCTAssertEqual(progressUpdates.last, HighlightClipGenerationProgress(completedMarkerCount: 2, totalMarkerCount: 2))
        XCTAssertFalse(progressUpdates.dropLast().contains(
            HighlightClipGenerationProgress(completedMarkerCount: 2, totalMarkerCount: 2),
        ))
    }

    @MainActor
    func testMakeHighlightClipDoesNotConsumeProgressWhileBuildingComposition() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("highlight-composition-progress-source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 8)
        let firstMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002201"))
        let secondMarkerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002202"))
        let segments = [
            HighlightClipSegment(
                markerIDs: [firstMarkerID],
                videoID: "first-video",
                start: 1,
                duration: 2,
                markerNumber: 1,
                markerTotalCount: 2,
            ),
            HighlightClipSegment(
                markerIDs: [secondMarkerID],
                videoID: "second-video",
                start: 5,
                duration: 1,
                markerNumber: 2,
                markerTotalCount: 2,
            ),
        ]

        var progressUpdates: [HighlightClipGenerationProgress] = []
        var requestedVideoIDs: [String] = []
        let outputURL = try await VideoClipEditingService().makeHighlightClip(
            from: segments,
            markerLabelStyle: .default,
            progressHandler: { progressUpdates.append($0) },
        ) { request in
            requestedVideoIDs.append(request.videoID)
            if request.videoID == "second-video" {
                XCTAssertEqual(
                    progressUpdates.last,
                    HighlightClipGenerationProgress(completedMarkerCount: 0, totalMarkerCount: 2),
                )
            }

            return AVURLAsset(url: sourceURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(requestedVideoIDs, ["first-video", "second-video"])
    }

    func testHighlightClipExportProgressDoesNotReachTotalBeforeExportFinishes() {
        XCTAssertEqual(
            VideoClipEditingService.completedMarkerCount(
                forExportProgress: 1,
                totalMarkerCount: 9,
                isFinished: false,
            ),
            8,
        )
        XCTAssertEqual(
            VideoClipEditingService.completedMarkerCount(
                forExportProgress: 1,
                totalMarkerCount: 9,
                isFinished: true,
            ),
            9,
        )
    }

    func testMakeHighlightClipLogsFailedExport() async {
        let logger = SpyAppLogger()
        let service = VideoClipEditingService(logger: logger)

        do {
            _ = try await service.makeHighlightClip(from: [], markerLabelStyle: .default) { _ in
                XCTFail("Should not request assets for empty segments")
                return AVURLAsset(url: URL(fileURLWithPath: "/tmp/unused.mov"))
            }
            XCTFail("Expected empty segment failure")
        } catch VideoClipEditingError.emptySegments {
            let entry = logger.entry(named: "video.export.failed")
            XCTAssertEqual(entry?.level, .error)
            XCTAssertEqual(entry?.category, .video)
            XCTAssertEqual(entry?.context["operation"], "highlightClip")
            XCTAssertNotNil(entry?.errorDescription)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExportFailureLogDoesNotIncludeSourceErrorIdentityOrPath() async {
        let logger = SpyAppLogger()
        let sensitive = "private-asset-id /private/media/source.mov"
        do {
            _ = try await VideoClipEditingService(logger: logger).makeHighlightClip(from: [
                HighlightClipSegment(markerIDs: [UUID()], videoID: "fixture", start: 0, duration: 1),
            ], markerLabelStyle: .default) { _ in
                throw NSError(domain: sensitive, code: 1, userInfo: [NSLocalizedDescriptionKey: sensitive])
            }
            XCTFail("Expected source failure")
        } catch {
            let entry = logger.entry(named: "video.export.failed")
            XCTAssertNotNil(entry)
            XCTAssertFalse(entry?.errorDescription?.contains(sensitive) ?? true)
        }
    }

    func testMakeHighlightClipCancelsExportSessionWhenTaskIsCancelled() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("highlight-cancel-source.mov")
        try await makeSilentVideo(at: sourceURL, duration: 8)
        let markerID = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002601"))
        let exportStarted = XCTestExpectation(description: "export started")
        let exportCancelled = XCTestExpectation(description: "export cancelled")
        let service = VideoClipEditingService(
            exportAsset: { _, _, _ in
                exportStarted.fulfill()
                try await Task.sleep(for: .seconds(10))
            },
            cancelExportSession: { _ in
                exportCancelled.fulfill()
            },
        )
        let segments = [
            HighlightClipSegment(
                markerIDs: [markerID],
                videoID: "video",
                start: 1,
                duration: 2,
            ),
        ]

        let task = Task {
            try await service.makeHighlightClip(from: segments, markerLabelStyle: .default) { _ in
                AVURLAsset(url: sourceURL)
            }
        }
        await fulfillment(of: [exportStarted], timeout: 5)

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            await fulfillment(of: [exportCancelled], timeout: 5)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMarkerLabelMetricsUseConfiguredRatioWithoutAbsoluteClamp() throws {
        let style = MarkerLabelStyle(
            fontSizeRatio: 0.12,
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            textOpacity: 0.8,
            backgroundOpacity: 0.3,
        )

        let metrics = try HighlightClipMarkerLabelOverlayMetrics.make(
            renderSize: CGSize(width: 1080, height: 1920),
            style: style,
        )

        XCTAssertEqual(metrics.fontSize, 129.6, accuracy: 0.001)
        XCTAssertEqual(metrics.textOpacity, 0.8, accuracy: 0.001)
        XCTAssertEqual(metrics.backgroundOpacity, 0.3, accuracy: 0.001)
    }

    func testMarkerLabelMetricsRejectInvalidRenderSize() {
        XCTAssertThrowsError(
            try HighlightClipMarkerLabelOverlayMetrics.make(
                renderSize: CGSize(width: CGFloat.nan, height: 1080),
                style: .default,
            ),
        )
        XCTAssertThrowsError(
            try HighlightClipMarkerLabelOverlayMetrics.make(
                renderSize: CGSize(width: 0, height: 1080),
                style: .default,
            ),
        )
    }

    func testMakeHighlightClipWithFullyTransparentMarkerKeepsTimeline() async throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("transparent-marker.mov")
        try await makeSilentVideo(at: sourceURL, duration: 4)
        let logger = SpyAppLogger()
        let segment = HighlightClipSegment(
            markerIDs: [
                try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000002701")),
            ],
            videoID: "video",
            start: 1,
            duration: 2,
        )
        let style = MarkerLabelStyle(
            fontSizeRatio: 0.10,
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.5,
            textOpacity: 0,
            backgroundOpacity: 0,
        )

        let outputURL = try await VideoClipEditingService(logger: logger).makeHighlightClip(
            from: [segment],
            markerLabelStyle: style,
        ) { _ in
            AVURLAsset(url: sourceURL)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let outputDuration = try await AVURLAsset(url: outputURL).load(.duration)
        XCTAssertEqual(outputDuration.seconds, 2, accuracy: 0.2)
        XCTAssertEqual(
            logger.entry(named: "video.export.started")?.context["usesVideoComposition"],
            "false",
        )
    }

    func testMarkerLabelOriginUsesConfiguredTopLeftNormalizedPosition() {
        let overlaySize = CGSize(width: 20, height: 10)
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let first = VideoClipEditingService.markerLabelCoreImageOrigin(
            style: MarkerLabelStyle(
                fontSizeRatio: 0.10,
                normalizedCenterX: 0.25,
                normalizedCenterY: 0.25,
                textOpacity: 1,
                backgroundOpacity: 0.6,
            ),
            overlaySize: overlaySize,
            imageExtent: extent,
        )
        let second = VideoClipEditingService.markerLabelCoreImageOrigin(
            style: MarkerLabelStyle(
                fontSizeRatio: 0.10,
                normalizedCenterX: 0.75,
                normalizedCenterY: 0.75,
                textOpacity: 1,
                backgroundOpacity: 0.6,
            ),
            overlaySize: overlaySize,
            imageExtent: extent,
        )

        XCTAssertEqual(first, CGPoint(x: 40, y: 70))
        XCTAssertEqual(second, CGPoint(x: 140, y: 20))
    }

    private func makeSilentVideo(at url: URL, duration: TimeInterval) async throws {
        let writer = try makeAssetWriter(at: url)
        let input = makeWriterInput()
        let adaptor = makePixelBufferAdaptor(for: input)
        guard writer.canAdd(input) else {
            throw TestVideoError.cannotAddWriterInput
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? TestVideoError.writerStartFailed
        }

        writer.startSession(atSourceTime: .zero)
        try await writeFrames(
            duration: duration,
            writer: writer,
            input: input,
            adaptor: adaptor,
        )
    }

    private func writeFrames(
        duration: TimeInterval,
        writer: AVAssetWriter,
        input: AVAssetWriterInput,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "ShotMarker.VideoClipEditingServiceTests.video-writer")
            let frameRate: Int32 = 30
            let frameCount = Int(duration * Double(frameRate))
            var frameIndex = 0
            var didResume = false

            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, frameIndex < frameCount {
                    do {
                        let pixelBuffer = try Self.makePixelBuffer(
                            width: 160,
                            height: 160,
                            value: UInt8(frameIndex % 255),
                        )
                        let presentationTime = CMTime(value: CMTimeValue(frameIndex), timescale: frameRate)
                        XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: presentationTime))
                        frameIndex += 1
                    } catch {
                        input.markAsFinished()
                        writer.cancelWriting()
                        if !didResume {
                            didResume = true
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                }

                guard frameIndex >= frameCount else {
                    return
                }

                input.markAsFinished()
                writer.finishWriting {
                    if !didResume {
                        didResume = true
                        if let error = writer.error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
        }
    }

    private func makeAssetWriter(at url: URL) throws -> AVAssetWriter {
        try AVAssetWriter(outputURL: url, fileType: .mov)
    }

    private func makeWriterInput() -> AVAssetWriterInput {
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 160,
                AVVideoHeightKey: 160,
            ],
        )
        input.expectsMediaDataInRealTime = false
        return input
    }

    private func makePixelBufferAdaptor(
        for input: AVAssetWriterInput,
    ) -> AVAssetWriterInputPixelBufferAdaptor {
        AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 160,
            ],
        )
    }

    private static func makePixelBuffer(width: Int, height: Int, value: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer,
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestVideoError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, Int32(value), CVPixelBufferGetDataSize(pixelBuffer))
        }

        return pixelBuffer
    }

    private enum TestVideoError: Error {
        case cannotAddWriterInput
        case pixelBufferCreationFailed(CVReturn)
        case writerStartFailed
    }
}

private struct SpyLogEntry {
    let level: AppLogLevel
    let category: AppLogCategory
    let name: String
    let message: String
    let context: [String: String]
    let errorDescription: String?
}

private final class SpyAppLogger: AppLogging {
    private(set) var entries: [SpyLogEntry] = []

    func debug(_ name: String, category: AppLogCategory, message: String, context: [String: String]) {
        append(level: .debug, category: category, name: name, message: message, context: context)
    }

    func info(_ name: String, category: AppLogCategory, message: String, context: [String: String]) {
        append(level: .info, category: category, name: name, message: message, context: context)
    }

    func warning(_ name: String, category: AppLogCategory, message: String, context: [String: String]) {
        append(level: .warning, category: category, name: name, message: message, context: context)
    }

    func error(
        _ name: String,
        category: AppLogCategory,
        message: String,
        error: Error?,
        context: [String: String],
    ) {
        append(
            level: .error,
            category: category,
            name: name,
            message: message,
            context: context,
            errorDescription: error.map { String(describing: $0) },
        )
    }

    func entry(named name: String) -> SpyLogEntry? {
        entries.first { $0.name == name }
    }

    func entries(named name: String) -> [SpyLogEntry] {
        entries.filter { $0.name == name }
    }

    private func append(
        level: AppLogLevel,
        category: AppLogCategory,
        name: String,
        message: String,
        context: [String: String],
        errorDescription: String? = nil,
    ) {
        entries.append(
            SpyLogEntry(
                level: level,
                category: category,
                name: name,
                message: message,
                context: context,
                errorDescription: errorDescription,
            ),
        )
    }
}
