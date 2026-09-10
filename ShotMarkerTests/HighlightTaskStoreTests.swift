@testable import ShotMarker
import XCTest

final class HighlightTaskStoreTests: XCTestCase {
    func testOutputCommitWriteFailurePreservesPriorOutputAndActiveExecutionForFailureHandling() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let task = try HighlightTaskTestFixture.task()
        try await fixture.store.create(task)
        let first = try HighlightTaskPlanner.execution(for: task)
        _ = try await fixture.store.installExecution(taskID: task.id, expectedRevision: 1, execution: first)
        let oldOutput = HighlightTaskTestFixture.output(task: task)
        _ = try await fixture.store.finishExecution(taskID: task.id, executionID: first.id, revision: 1, status: .succeeded, output: oldOutput)
        let second = try HighlightTaskPlanner.execution(for: task)
        _ = try await fixture.store.installExecution(taskID: task.id, expectedRevision: 1, execution: second)
        let before = try Data(contentsOf: fixture.fileURL)
        let failing = HighlightTaskStore(fileURL: fixture.fileURL, atomicWrite: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        do {
            _ = try await failing.finishExecution(taskID: task.id, executionID: second.id, revision: 1,
                status: .succeeded, output: HighlightTaskTestFixture.output(task: task))
            XCTFail("Expected output-reference write failure")
        } catch { XCTAssertEqual(error as? HighlightTaskError, .persistence) }
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        let loaded = try await fixture.store.load()
        XCTAssertEqual(loaded[0].currentOutput, oldOutput)
        XCTAssertEqual(loaded[0].activeExecution?.id, second.id)
    }

    func testCompletionWinsAgainstLateStopAndActiveConfigurationOrDeleteAreRejected() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let task = try HighlightTaskTestFixture.task()
        try await fixture.store.create(task)
        let execution = try HighlightTaskPlanner.execution(for: task)
        _ = try await fixture.store.installExecution(taskID: task.id, expectedRevision: 1, execution: execution)
        do { try await fixture.store.delete(id: task.id, expectedRevision: 1); XCTFail("Cannot delete active task") }
        catch { XCTAssertEqual(error as? HighlightTaskError, .busy) }
        do {
            _ = try await fixture.store.updateConfiguration(id: task.id, expectedRevision: 1,
                videos: task.videos, settings: task.clipSettings, items: task.reviewItems)
            XCTFail("Cannot edit active task")
        } catch { XCTAssertEqual(error as? HighlightTaskError, .busy) }
        let output = HighlightTaskTestFixture.output(task: task)
        _ = try await fixture.store.finishExecution(taskID: task.id, executionID: execution.id, revision: 1, status: .succeeded, output: output)
        let lateStop = try await fixture.store.finishExecution(taskID: task.id, executionID: execution.id, revision: 1, status: .stopped)
        XCTAssertNil(lateStop)
        let loaded = try await fixture.store.load()
        XCTAssertEqual(loaded[0].state, .completed)
        XCTAssertEqual(loaded[0].currentOutput, output)
    }

    func testRoundTripPreservesSnapshotWithoutOriginalTrainingIdentity() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let task = try HighlightTaskTestFixture.task()
        try await fixture.store.create(task)
        let loaded = try await HighlightTaskStore(fileURL: fixture.fileURL).loadForLaunch()
        XCTAssertEqual(loaded, [task])
        let root = try JSONDecoder().decode(HighlightTaskStoreDocument.self, from: Data(contentsOf: fixture.fileURL))
        XCTAssertEqual(root.schemaVersion, 1)
        XCTAssertEqual(root.tasks[0].trainingSnapshot.markers.map(\.sourceOrder), [0, 1, 2])
        XCTAssertTrue(Set(task.trainingSnapshot.markers.map(\.id)).isDisjoint(with: HighlightTaskTestFixture.session.events.map(\.id)))
    }

    func testConfigurationNoopAndMultipleFieldsIncrementOnlyOnceThenRejectStaleRevision() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let task = try HighlightTaskTestFixture.task()
        try await fixture.store.create(task)
        let before = try Data(contentsOf: fixture.fileURL)
        let unchanged = try await fixture.store.updateConfiguration(id: task.id, expectedRevision: 1,
            videos: task.videos, settings: task.clipSettings, items: task.reviewItems)
        XCTAssertEqual(unchanged.configurationRevision, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), before)
        var settings = task.clipSettings
        settings.markerLabelStyle.textOpacity = 0.5
        var items = task.reviewItems
        items[0].isIncluded = false
        let updated = try await fixture.store.updateConfiguration(id: task.id, expectedRevision: 1,
            videos: task.videos, settings: settings, items: items)
        XCTAssertEqual(updated.configurationRevision, 2)
        XCTAssertEqual(updated.trainingSnapshot, task.trainingSnapshot)
        do {
            _ = try await fixture.store.updateConfiguration(id: task.id, expectedRevision: 1,
                videos: task.videos, settings: task.clipSettings, items: task.reviewItems)
            XCTFail("Stale editor must not overwrite the committed configuration")
        } catch { XCTAssertEqual(error as? HighlightTaskError, .revisionConflict) }
    }

    func testFailedAtomicWriteLeavesDiskUnchanged() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let task = try HighlightTaskTestFixture.task()
        try await fixture.store.create(task)
        let bytes = try Data(contentsOf: fixture.fileURL)
        let failing = HighlightTaskStore(fileURL: fixture.fileURL, atomicWrite: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
        do { try await failing.delete(id: task.id, expectedRevision: 1); XCTFail("Expected write failure") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), bytes)
    }

    func testStopWinsAgainstLateOutputAndLaunchStopsAllRemainingExecutions() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let task = try HighlightTaskTestFixture.task()
        try await fixture.store.create(task)
        let execution = try HighlightTaskPlanner.execution(for: task)
        _ = try await fixture.store.installExecution(taskID: task.id, expectedRevision: 1, execution: execution)
        let stopped = try await fixture.store.finishExecution(taskID: task.id, executionID: execution.id,
            revision: 1, status: .stopped)
        XCTAssertEqual(stopped?.state, .stopped)
        let late = try await fixture.store.finishExecution(taskID: task.id, executionID: execution.id,
            revision: 1, status: .succeeded, output: HighlightTaskTestFixture.output(task: task))
        XCTAssertNil(late)
        let second = try HighlightTaskPlanner.execution(for: task)
        _ = try await fixture.store.installExecution(taskID: task.id, expectedRevision: 1, execution: second)
        let recovered = try await HighlightTaskStore(fileURL: fixture.fileURL).loadForLaunch()
        XCTAssertNil(recovered[0].activeExecution)
        XCTAssertEqual(recovered[0].state, .stopped)
        XCTAssertEqual(recovered[0].lastGenerationResult?.executionID, second.id)
    }

    func testUnknownSchemaAndCorruptDocumentStayProtectedAcrossInstances() async throws {
        let fixture = try TaskStoreFixture()
        defer { fixture.cleanup() }
        let future = Data(#"{"schemaVersion":2,"tasks":[]}"#.utf8)
        try future.write(to: fixture.fileURL)
        do { _ = try await fixture.store.loadForLaunch(); XCTFail("Must protect future schema") } catch {}
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), future)
        try Data("broken".utf8).write(to: fixture.fileURL)
        do { _ = try await fixture.store.loadForLaunch(); XCTFail("Must report corrupt document") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
        do { _ = try await HighlightTaskStore(fileURL: fixture.fileURL).loadForLaunch(); XCTFail("Unrecovered backup must protect files") } catch {}
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        XCTAssertEqual(names.filter { $0.hasPrefix("highlight-tasks.corrupt-") }.count, 1)
    }

    func testActiveExecutionOnlyAllowsStopEvenWithAnOldOutput() throws {
        var task = try HighlightTaskTestFixture.task()
        task.currentOutput = HighlightTaskTestFixture.output(task: task)
        XCTAssertEqual(task.state, .completed)
        task.configurationRevision += 1
        XCTAssertEqual(task.state, .modified)
        XCTAssertFalse(task.canRegenerateDirectly)
        task.activeExecution = try HighlightTaskPlanner.execution(for: task)
        XCTAssertEqual(task.allowedActions, [.stop])
        task.activeExecution?.status = .running
        XCTAssertEqual(task.allowedActions, [.stop])
        XCTAssertTrue(task.outputIsOutdated)
    }
}

struct TaskStoreFixture {
    let directory: URL
    let fileURL: URL
    let store: HighlightTaskStore
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("highlight-tasks.json")
        store = HighlightTaskStore(fileURL: fileURL)
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

enum HighlightTaskTestFixture {
    static let session = TrainingSession(startedAt: Date(timeIntervalSince1970: 100),
        endedAt: Date(timeIntervalSince1970: 160), events: [10.0, 12, 40].map {
            ShotMarkerEvent(markedAt: Date(timeIntervalSince1970: 100 + $0))
        })
    static func task() throws -> HighlightTask {
        try HighlightTaskPlanner.makeTask(id: UUID(), session: session, videos: [video()], settings: .default)
    }
    static func video() -> HighlightTaskVideo {
        HighlightTaskVideo(id: UUID(), sourceIdentity: .photoLibraryAsset("fixture"),
            recordedStartAt: Date(timeIntervalSince1970: 100), duration: 60,
            source: .photoLibraryAsset(localIdentifier: "fixture"))
    }
    static func output(task: HighlightTask) -> HighlightTaskOutput {
        let id = UUID()
        return HighlightTaskOutput(id: id, relativePath: "HighlightTasks/\(task.id)/Outputs/\(id)/highlight.mov",
            configurationRevision: task.configurationRevision, generatedAt: Date())
    }
}
