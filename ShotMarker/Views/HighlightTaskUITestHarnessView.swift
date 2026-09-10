#if DEBUG
import Foundation
import SwiftUI

/// Isolated, deterministic state fixtures for the real task row and configuration views.
struct HighlightTaskUITestHarnessView: View {
    @StateObject private var fixture = TaskUIFixture()
    @State private var editing = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(fixture.manager.tasks) { task in
                    HighlightTaskRow(task: task, manager: fixture.manager,
                        onEdit: { editing = true }, onPlay: {})
                }
            }
            .navigationDestination(isPresented: $editing) {
                if let task = fixture.manager.tasks.first {
                    HighlightTaskEditorView(task: task, manager: fixture.manager) { editing = false }
                }
            }
            .task { await fixture.prepare() }
        }
    }
}

@MainActor
private final class TaskUIFixture: ObservableObject {
    let manager: HighlightTaskManager
    private let store: HighlightTaskStore
    private let files: HighlightTaskFileStore
    private var prepared = false
    private var observation: AnyCancellable?

    init() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ShotMarker-TaskUI-\(UUID())")
        store = HighlightTaskStore(fileURL: root.appendingPathComponent("highlight-tasks.json"))
        files = HighlightTaskFileStore(baseDirectory: root, temporaryDirectory: root.appendingPathComponent("tmp"))
        manager = HighlightTaskManager(store: store, fileStore: files, runner: TaskUIRunner(), validateSource: { _ in })
        observation = manager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func prepare() async {
        guard !prepared else { return }
        prepared = true
        do {
            let video = HighlightTaskVideo(id: UUID(), sourceIdentity: .photoLibraryAsset("fixture"),
                recordedStartAt: Date(timeIntervalSince1970: 100), duration: 60, source: .photoLibraryAsset(localIdentifier: "fixture"))
            let session = TrainingSession(startedAt: video.recordedStartAt,
                endedAt: video.recordedStartAt.addingTimeInterval(60), events: [ShotMarkerEvent(markedAt: video.recordedStartAt.addingTimeInterval(10))])
            var task = try HighlightTaskPlanner.makeTask(id: UUID(), session: session, videos: [video], settings: .default)
            try await store.create(task)
            let state = ProcessInfo.processInfo.environment["SHOTMARKER_UI_TEST_TASK_STATE"] ?? "completed"
            let first = try HighlightTaskPlanner.execution(for: task)
            _ = try await store.installExecution(taskID: task.id, expectedRevision: 1, execution: first)
            let id = UUID()
            let output = HighlightTaskOutput(id: id, relativePath: "HighlightTasks/\(task.id)/Outputs/\(id)/highlight.mov",
                configurationRevision: 1, generatedAt: Date())
            task = try await store.finishExecution(taskID: task.id, executionID: first.id, revision: 1, status: .succeeded, output: output)!
            if state == "modified" {
                var settings = task.clipSettings
                settings.markerLabelStyle.textOpacity = 0.5
                _ = try await store.updateConfiguration(id: task.id, expectedRevision: 1, videos: task.videos, settings: settings, items: task.reviewItems)
            } else if state == "queued" || state == "running" {
                let execution = try HighlightTaskPlanner.execution(for: task)
                _ = try await store.installExecution(taskID: task.id, expectedRevision: 1, execution: execution)
                if state == "running" {
                    _ = try await store.updateProgress(taskID: task.id, executionID: execution.id, revision: 1,
                        progress: HighlightJobProgress(completedMarkerCount: 0, totalMarkerCount: 1))
                }
            }
            await manager.refresh()
        } catch { assertionFailure("Task UI fixture failed to initialize") }
    }
}

import Combine
private struct TaskUIRunner: HighlightRenderRunning {
    func run(execution: HighlightRenderExecution, outputURL: URL,
        onProgress: @escaping @MainActor (HighlightJobProgress) -> Void) async throws -> URL {
        throw CancellationError()
    }
}
#endif
