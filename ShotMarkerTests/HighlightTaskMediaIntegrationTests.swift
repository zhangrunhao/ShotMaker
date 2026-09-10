@testable import ShotMarker
import AVFoundation
import XCTest

final class HighlightTaskMediaIntegrationTests: XCTestCase {
    func testRealSourcesRenderOneMovieThenEditedTaskReplacesOutputAndSurvivesRelaunch() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let a = fixture.directory.appendingPathComponent("a.mov")
        let b = fixture.directory.appendingPathComponent("b.mov")
        try await makeVideo(at: a, width: 320, height: 180)
        try await makeVideo(at: b, width: 180, height: 320)
        let files = HighlightTaskFileStore(baseDirectory: fixture.directory,
            temporaryDirectory: fixture.directory.appendingPathComponent("tmp"))
        let media = HighlightTaskMedia(fileStore: files)
        let runner = HighlightRenderRunner(assetForVideo: { video, _ in try await media.asset(for: video) }, logger: AppLogger.shared)
        let manager = HighlightTaskManager(store: fixture.store, fileStore: files, runner: runner,
            validateSource: { video in _ = try await media.asset(for: video).load(.duration) })
        let started = Date(timeIntervalSince1970: 100)
        let session = TrainingSession(startedAt: started, endedAt: started.addingTimeInterval(70),
            events: [10.0, 12, 32, 55].map { ShotMarkerEvent(markedAt: started.addingTimeInterval($0)) })
        let videos = [SelectedTrainingVideo(id: a.absoluteString, recordedStartAt: started, duration: 40),
                      SelectedTrainingVideo(id: b.absoluteString, recordedStartAt: started.addingTimeInterval(30), duration: 40)]
        let task = try await manager.createTask(session: session, selectedVideos: videos, settings: .default)
        XCTAssertEqual(task.reviewItems.map(\.duration), [15, 13, 13])
        try await manager.start(taskID: task.id, expectedRevision: 1)
        await manager.waitUntilIdle()
        XCTAssertEqual(manager.task(task.id)?.state, .completed)
        let old = try XCTUnwrap(manager.task(task.id)?.currentOutput)
        let oldURL = try manager.playbackURL(taskID: task.id)
        let duration = try await AVURLAsset(url: oldURL).load(.duration).seconds
        XCTAssertEqual(duration, 41, accuracy: 0.1)
        let draft = try HighlightTaskPlanner.reviewDraft(for: task)
        var excluded = draft.items[0]
        excluded.isIncluded = false
        let changed = try await manager.confirmClip(taskID: task.id, expectedRevision: 1, item: excluded)
        XCTAssertEqual(changed.state, .modified)
        XCTAssertEqual(changed.currentOutput, old)
        try await manager.start(taskID: task.id, expectedRevision: changed.configurationRevision)
        await manager.waitUntilIdle()
        let newURL = try manager.playbackURL(taskID: task.id)
        XCTAssertNotEqual(newURL, oldURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        let newDuration = try await AVURLAsset(url: newURL).load(.duration).seconds
        XCTAssertEqual(newDuration, 26, accuracy: 0.1)
        let reloaded = try await HighlightTaskStore(fileURL: fixture.fileURL).loadForLaunch()
        XCTAssertEqual(reloaded[0].state, .completed)
        XCTAssertEqual(reloaded[0].currentOutput?.configurationRevision, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.appendingPathComponent("tmp").path), [])
        try await manager.delete(taskID: task.id)
        XCTAssertTrue(manager.tasks.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: newURL.path))
    }

    private func makeVideo(at url: URL, width: Int, height: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), width > height ? 90 : 180, CVPixelBufferGetDataSize(pixelBuffer))
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        for index in 0..<400 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertTrue(adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(index), timescale: 10)))
        }
        writer.endSession(atSourceTime: CMTime(seconds: 40, preferredTimescale: 600))
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
