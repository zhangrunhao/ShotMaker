@testable import ShotMarker
import XCTest

final class HighlightTaskManagerTests: XCTestCase {
    func testReloadDuringActiveRenderDoesNotNormalizeOrCleanRunningExecution() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        await fixture.manager.load()
        let task = try await fixture.create()
        try await fixture.manager.start(taskID: task.id, expectedRevision: 1)
        await waitFor { fixture.runner.executions.count == 1 }
        await fixture.manager.load()
        XCTAssertEqual(fixture.manager.task(task.id)?.state, .running)
        XCTAssertNotNil(fixture.manager.task(task.id)?.activeExecution)
        fixture.runner.finishNextSuccessfully()
        await fixture.manager.waitUntilIdle()
        XCTAssertEqual(fixture.manager.task(task.id)?.state, .completed)
    }

    func testBackgroundForegroundDuringSourceValidationCannotStartPreBackgroundRequest() async throws {
        let storage = try TaskStoreFixture()
        defer { storage.cleanup() }
        let files = HighlightTaskFileStore(baseDirectory: storage.directory)
        let runner = ControlledHighlightRenderRunner()
        var continuation: CheckedContinuation<Void, Never>?
        let manager = HighlightTaskManager(store: storage.store, fileStore: files, runner: runner,
            validateSource: { _ in await withCheckedContinuation { continuation = $0 } })
        let task = try await manager.createTask(session: HighlightTaskTestFixture.session,
            selectedVideos: TaskManagerFixture.videos, settings: .default)
        let start = Task { try await manager.start(taskID: task.id, expectedRevision: 1) }
        await waitFor { continuation != nil }
        manager.enterBackground()
        await manager.stopAllExecutions()
        manager.enterForeground()
        continuation?.resume()
        do { try await start.value; XCTFail("A pre-background start request must stay invalidated") } catch {}
        if manager.task(task.id)?.activeExecution != nil {
            await waitFor { runner.executions.count == 1 }
            try await manager.stop(taskID: task.id)
            runner.finishNextSuccessfully()
        }
        await manager.waitUntilIdle()
        XCTAssertEqual(runner.executions.count, 0)
    }

    func testCreateIsVisibleBeforeRenderAndRepeatedCreationIDDoesNotDuplicate() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        await fixture.manager.load()
        let id = UUID()
        let first = try await fixture.create(id: id)
        let repeated = try await fixture.create(id: id)
        XCTAssertEqual(first.id, repeated.id)
        XCTAssertEqual(fixture.manager.tasks.count, 1)
        XCTAssertEqual(first.state, .reviewing)
        XCTAssertEqual(fixture.runner.executions.count, 0)
    }

    func testStopPreservesTaskAndKeepsSerialSlotUntilUncooperativeRunnerExits() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.create()
        let second = try await fixture.create()
        try await fixture.manager.start(taskID: first.id, expectedRevision: 1)
        await waitFor { fixture.runner.executions.count == 1 }
        try await fixture.manager.start(taskID: second.id, expectedRevision: 1)
        try await fixture.manager.stop(taskID: first.id)
        XCTAssertEqual(fixture.manager.task(first.id)?.state, .stopped)
        XCTAssertEqual(fixture.runner.executions.count, 1)
        fixture.runner.finishNextSuccessfully()
        await waitFor { fixture.runner.executions.count == 2 }
        XCTAssertNil(fixture.manager.task(first.id)?.currentOutput)
        XCTAssertEqual(fixture.manager.task(first.id)?.state, .stopped)
        try await fixture.manager.stop(taskID: second.id)
        fixture.runner.finishNextSuccessfully()
        await fixture.manager.waitUntilIdle()
        XCTAssertTrue(fixture.analytics.events.isEmpty)
    }

    func testQueuedStopNeverStartsAndBackgroundStopsAllWithoutAutomaticRestart() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let first = try await fixture.create()
        let queued = try await fixture.create()
        try await fixture.manager.start(taskID: first.id, expectedRevision: 1)
        await waitFor { fixture.runner.executions.count == 1 }
        try await fixture.manager.start(taskID: queued.id, expectedRevision: 1)
        fixture.manager.enterBackground()
        await waitFor { fixture.manager.tasks.allSatisfy { $0.state == .stopped } }
        fixture.runner.finishNextSuccessfully()
        await fixture.manager.waitUntilIdle()
        fixture.manager.enterForeground()
        XCTAssertEqual(fixture.runner.executions.count, 1)
        XCTAssertTrue(fixture.manager.tasks.allSatisfy { $0.currentOutput == nil })
    }

    func testSuccessfulReplacementDeletesOldOnlyAfterCommitAndTracksSuccess() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.create()
        try await fixture.manager.start(taskID: task.id, expectedRevision: 1)
        await waitFor { fixture.runner.executions.count == 1 }
        fixture.runner.finishNextSuccessfully()
        await fixture.manager.waitUntilIdle()
        let old = try XCTUnwrap(fixture.manager.task(task.id)?.currentOutput)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try fixture.files.url(forRelativePath: old.relativePath).path))
        try await fixture.manager.restart(taskID: task.id)
        await waitFor { fixture.runner.executions.count == 2 }
        XCTAssertEqual(fixture.manager.task(task.id)?.allowedActions, [.stop])
        XCTAssertEqual(fixture.manager.task(task.id)?.currentOutput, old)
        fixture.runner.finishNextSuccessfully()
        await fixture.manager.waitUntilIdle()
        XCTAssertNotEqual(fixture.manager.task(task.id)?.currentOutput?.id, old.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try fixture.files.url(forRelativePath: old.relativePath).path))
        XCTAssertEqual(fixture.analytics.events, [.highlightGenerateSucceeded, .highlightGenerateSucceeded])
    }

    func testFailedRegenerationKeepsPreviousOutputAndChangedConfigurationRequiresReview() async throws {
        let fixture = try TaskManagerFixture()
        defer { fixture.cleanup() }
        let task = try await fixture.create()
        try await fixture.manager.start(taskID: task.id, expectedRevision: 1)
        await waitFor { fixture.runner.executions.count == 1 }
        fixture.runner.finishNextSuccessfully()
        await fixture.manager.waitUntilIdle()
        let old = try XCTUnwrap(fixture.manager.task(task.id)?.currentOutput)
        try await fixture.manager.restart(taskID: task.id)
        await waitFor { fixture.runner.executions.count == 2 }
        fixture.runner.failNext()
        await fixture.manager.waitUntilIdle()
        XCTAssertEqual(fixture.manager.task(task.id)?.state, .failed)
        XCTAssertEqual(fixture.manager.task(task.id)?.currentOutput, old)
        var settings = task.clipSettings
        settings.markerLabelStyle.textOpacity = 0.3
        _ = try await fixture.manager.updateConfiguration(taskID: task.id, expectedRevision: 1,
            selectedVideos: TaskManagerFixture.videos, settings: settings)
        XCTAssertEqual(fixture.manager.task(task.id)?.state, .modified)
        do { try await fixture.manager.restart(taskID: task.id); XCTFail("Changed configuration requires review") }
        catch { XCTAssertEqual(error as? HighlightTaskError, .mustReview) }
    }

    private func waitFor(_ condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for observable state")
    }
}

@MainActor
final class ControlledHighlightRenderRunner: HighlightRenderRunning {
    private(set) var executions: [HighlightRenderExecution] = []
    private var pending: [(URL, CheckedContinuation<URL, Error>)] = []
    func run(execution: HighlightRenderExecution, outputURL: URL,
        onProgress: @escaping @MainActor (HighlightJobProgress) -> Void) async throws -> URL {
        executions.append(execution)
        return try await withCheckedThrowingContinuation { pending.append((outputURL, $0)) }
    }
    func finishNextSuccessfully() {
        guard !pending.isEmpty else { return }
        let (url, continuation) = pending.removeFirst()
        do { try Data("rendered".utf8).write(to: url); continuation.resume(returning: url) }
        catch { continuation.resume(throwing: error) }
    }
    func failNext() {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume(throwing: HighlightTaskError.sourceUnavailable)
    }
    func finishWithMissingOutput() {
        guard !pending.isEmpty else { return }
        let (url, continuation) = pending.removeFirst()
        continuation.resume(returning: url)
    }
}

struct TaskManagerFixture {
    let storeFixture: TaskStoreFixture
    let files: HighlightTaskFileStore
    let runner = ControlledHighlightRenderRunner()
    let analytics = SpyAnalyticsTracker()
    let manager: HighlightTaskManager
    static let videos = [SelectedTrainingVideo(id: "fixture", recordedStartAt: Date(timeIntervalSince1970: 100),
        duration: 60, reviewSourceIdentity: .photoLibraryAsset("fixture"))]
    init() throws {
        storeFixture = try TaskStoreFixture()
        files = HighlightTaskFileStore(baseDirectory: storeFixture.directory,
            temporaryDirectory: storeFixture.directory.appendingPathComponent("tmp"))
        manager = HighlightTaskManager(store: storeFixture.store, fileStore: files, runner: runner,
            validateSource: { _ in }, analytics: analytics)
    }
    func create(id: UUID = UUID()) async throws -> HighlightTask {
        try await manager.createTask(id: id, session: HighlightTaskTestFixture.session,
            selectedVideos: Self.videos, settings: .default)
    }
    func cleanup() { storeFixture.cleanup() }
}
