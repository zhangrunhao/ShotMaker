@testable import ShotMarker
import AVFoundation
import XCTest

final class HighlightTaskReviewTests: XCTestCase {
    func testRetainedThumbnailDataIsBoundedAndReleaseDropsCachedAsset() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let start = Date(timeIntervalSince1970: 100)
        let task = try await fixture.manager.createTask(session:
            TrainingSession(startedAt: start, endedAt: start.addingTimeInterval(1_500),
                events: (0..<70).map { ShotMarkerEvent(markedAt: start.addingTimeInterval(Double($0 * 20 + 10))) }),
            selectedVideos: [SelectedTrainingVideo(id: "fixture", recordedStartAt: start, duration: 1_500)], settings: .default)
        weak var cachedAsset: AVAsset?
        let media = HighlightClipReviewMediaProvider(loadAsset: { _ in
            let asset = AVMutableComposition()
            cachedAsset = asset
            return asset
        }, generateFrame: { _, _ in Data([1]) })
        let session = try HighlightReviewSession(task: task, manager: fixture.manager, mediaProvider: media)
        for item in task.reviewItems {
            await session.viewModel.loadThumbnail(itemID: item.id, targetSize: .init(width: 10, height: 10))
        }
        XCTAssertEqual(task.reviewItems.count, 70)
        XCTAssertEqual(session.viewModel.thumbnailStates.values.filter { if case .loaded = $0 { true } else { false } }.count, 64)
        XCTAssertNotNil(cachedAsset)
        session.release()
        XCTAssertNil(cachedAsset)
        XCTAssertTrue(session.viewModel.thumbnailStates.isEmpty)
    }

    func testConfirmationWritesTaskRevisionBeforePublishingAndNextCardNavigation() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.create()
        let session = try HighlightReviewSession(task: task, manager: fixture.manager, mediaProvider: provider())
        let first = task.reviewItems[0]
        let editor = try XCTUnwrap(session.viewModel.makeEditorViewModel(itemID: first.id))
        editor.setIncluded(false)
        XCTAssertTrue(session.viewModel.items[0].isIncluded)
        let navigation = await editor.confirm()
        XCTAssertEqual(navigation, .open(itemID: task.reviewItems[1].id))
        XCTAssertEqual(fixture.manager.task(task.id)?.configurationRevision, 2)
        XCTAssertFalse(session.viewModel.items[0].isIncluded)
        let loaded = try await fixture.storeFixture.store.load()
        XCTAssertEqual(loaded[0].reviewItems[0].confirmationState, .confirmed)
        XCTAssertFalse(loaded[0].reviewItems[0].isIncluded)
    }

    func testStaleReviewRetainsWorkingCopyWithoutPublishing() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.create()
        let session = try HighlightReviewSession(task: task, manager: fixture.manager, mediaProvider: provider())
        var settings = task.clipSettings
        settings.markerLabelStyle.textOpacity = 0.4
        _ = try await fixture.manager.updateConfiguration(taskID: task.id, expectedRevision: 1,
            selectedVideos: TaskManagerFixture.videos, settings: settings)
        let editor = try XCTUnwrap(session.viewModel.makeEditorViewModel(itemID: task.reviewItems[0].id))
        editor.setIncluded(false)
        let navigation = await editor.confirm()
        XCTAssertNil(navigation)
        XCTAssertTrue(editor.hasChanges)
        XCTAssertNotNil(editor.saveErrorMessage)
        XCTAssertTrue(session.viewModel.items[0].isIncluded)
        XCTAssertEqual(fixture.manager.task(task.id)?.configurationRevision, 2)
    }

    func testReleaseDropsRuntimeDataAndPreservesTaskConfiguration() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.create()
        let session = try HighlightReviewSession(task: task, manager: fixture.manager, mediaProvider: provider())
        await session.viewModel.loadThumbnail(itemID: task.reviewItems[0].id, targetSize: .init(width: 10, height: 10))
        XCTAssertEqual(session.viewModel.thumbnailStates[task.reviewItems[0].id], .loaded(Data([1])))
        session.release()
        XCTAssertTrue(session.viewModel.thumbnailStates.isEmpty)
        XCTAssertTrue(session.viewModel.filmstripFramesByItemID.isEmpty)
        XCTAssertNil(session.viewModel.editingItemID)
        XCTAssertEqual(fixture.manager.task(task.id)?.reviewItems, task.reviewItems)
        XCTAssertEqual(session.viewModel.items.count, 2)
    }

    private func provider() -> HighlightClipReviewMediaProvider {
        HighlightClipReviewMediaProvider(loadAsset: { _ in AVMutableComposition() }, generateFrame: { _, _ in Data([1]) })
    }
}
