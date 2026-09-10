import AVFoundation
import Combine
import Foundation

@MainActor
final class HighlightTaskManager: ObservableObject {
    @Published private(set) var tasks: [HighlightTask] = []
    @Published private(set) var photoSavingTaskIDs: Set<UUID> = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoaded = false

    let fileStore: HighlightTaskFileStore
    private let store: any HighlightTaskStoring
    private let runner: any HighlightRenderRunning
    private let validateSource: (HighlightTaskVideo) async throws -> Void
    private let saveVideo: (URL) async throws -> Void
    private let analytics: AnalyticsTracking
    private let logger: AppLogging
    private var running: (taskID: UUID, executionID: UUID, work: Task<Void, Never>)?
    private var preparingTaskIDs: Set<UUID> = []
    private var foreground = true
    private var lifecycleGeneration = 0
    private var stoppingAll = false
    private var loading = false
    private var refreshSequence = 0

    init(store: any HighlightTaskStoring, fileStore: HighlightTaskFileStore,
        runner: any HighlightRenderRunning, validateSource: @escaping (HighlightTaskVideo) async throws -> Void,
        saveVideo: @escaping (URL) async throws -> Void = { _ in },
        analytics: AnalyticsTracking = NoopAnalyticsTracker(), logger: AppLogging = AppLogger.shared) {
        self.store = store
        self.fileStore = fileStore
        self.runner = runner
        self.validateSource = validateSource
        self.saveVideo = saveVideo
        self.analytics = analytics
        self.logger = logger
    }

    func task(_ id: UUID) -> HighlightTask? { tasks.first { $0.id == id } }

    func load() async {
        guard !loading else { return }
        if isLoaded || running != nil || !preparingTaskIDs.isEmpty {
            if stoppingAll { await stopAllExecutions() }
            else { await refresh() }
            return
        }
        loading = true
        defer { loading = false }
        do {
            let loaded = try await store.loadForLaunch()
            // A failed document load must never yield a reference set for cleanup.
            do { try await fileStore.cleanOrphans(referencing: loaded) }
            catch { logCleanupFailure() }
            tasks = loaded
            errorMessage = nil
            isLoaded = true
        } catch { errorMessage = message(error) }
    }

    func refresh() async {
        refreshSequence += 1
        let sequence = refreshSequence
        do {
            let loaded = try await store.load()
            guard sequence == refreshSequence else { return }
            tasks = loaded
            errorMessage = nil
        } catch { if sequence == refreshSequence { errorMessage = message(error) } }
    }

    func createTask(id: UUID = UUID(), session: TrainingSession, selectedVideos: [SelectedTrainingVideo],
        settings: ClipSettings) async throws -> HighlightTask {
        if let existing = task(id) { return existing }
        guard preparingTaskIDs.insert(id).inserted else { throw HighlightTaskError.busy }
        defer { preparingTaskIDs.remove(id) }
        let prepared = try await fileStore.prepareInputs(selectedVideos, taskID: id, existing: [])
        var moved = false
        var committed = false
        do {
            let task = try HighlightTaskPlanner.makeTask(id: id, session: session, videos: prepared.videos, settings: settings)
            try Task.checkCancellation()
            try await fileStore.commitInputs(prepared, creating: true)
            moved = true
            try await store.create(task)
            committed = true
            await refresh()
            return task
        } catch {
            if !committed {
                do { try await fileStore.discard(prepared, committedCreation: moved) }
                catch { logCleanupFailure() }
            }
            throw sanitized(error)
        }
    }

    @discardableResult
    func updateConfiguration(taskID: UUID, expectedRevision: Int, selectedVideos: [SelectedTrainingVideo],
        settings: ClipSettings) async throws -> HighlightTaskReconciliation {
        let old = try editableTask(taskID, revision: expectedRevision)
        guard preparingTaskIDs.insert(taskID).inserted else { throw HighlightTaskError.busy }
        defer { preparingTaskIDs.remove(taskID) }
        let prepared = try await fileStore.prepareInputs(selectedVideos, taskID: taskID, existing: old.videos)
        var committed = false
        do {
            let result = try HighlightTaskPlanner.reconcile(task: old, videos: prepared.videos, settings: settings)
            try Task.checkCancellation()
            try await fileStore.commitInputs(prepared, creating: false)
            _ = try await store.updateConfiguration(id: taskID, expectedRevision: expectedRevision,
                videos: prepared.videos, settings: settings, items: result.items)
            committed = true
            await refresh()
            do { try await fileStore.removeUnusedInputs(old: old.videos, current: prepared.videos) }
            catch { logCleanupFailure() }
            return result
        } catch {
            if !committed {
                do { try await fileStore.discard(prepared) } catch { logCleanupFailure() }
            }
            if error as? HighlightTaskError == .revisionConflict { await refresh() }
            throw sanitized(error)
        }
    }

    func confirmClip(taskID: UUID, expectedRevision: Int, item: HighlightClipReviewItem) async throws -> HighlightTask {
        let old = try editableTask(taskID, revision: expectedRevision)
        guard let index = old.reviewItems.firstIndex(where: { $0.id == item.id }) else { throw HighlightTaskError.invalidTask }
        var confirmed = try HighlightTaskPlanner.persisted(item)
        let original = old.reviewItems[index]
        guard original.videoID == confirmed.videoID, original.markerIDs == confirmed.markerIDs,
              original.defaultStart == confirmed.defaultStart, original.defaultDuration == confirmed.defaultDuration
        else { throw HighlightTaskError.revisionConflict }
        confirmed.confirmationState = .confirmed
        var items = old.reviewItems
        items[index] = confirmed
        do {
            let updated = try await store.updateConfiguration(id: taskID, expectedRevision: expectedRevision,
                videos: old.videos, settings: old.clipSettings, items: items)
            await refresh()
            return updated
        } catch {
            if error as? HighlightTaskError == .revisionConflict { await refresh() }
            throw sanitized(error)
        }
    }

    func resetClips(taskID: UUID, expectedRevision: Int) async throws -> HighlightTask {
        let old = try editableTask(taskID, revision: expectedRevision)
        let reset = try HighlightTaskPlanner.reconcile(task: old, videos: old.videos, settings: old.clipSettings, resetAll: true)
        let updated = try await store.updateConfiguration(id: taskID, expectedRevision: expectedRevision,
            videos: old.videos, settings: old.clipSettings, items: reset.items)
        await refresh()
        return updated
    }

    func start(taskID: UUID, expectedRevision: Int) async throws {
        guard foreground && !stoppingAll else { throw HighlightTaskError.background }
        let generation = lifecycleGeneration
        let task = try editableTask(taskID, revision: expectedRevision)
        guard preparingTaskIDs.insert(taskID).inserted else { throw HighlightTaskError.busy }
        defer { preparingTaskIDs.remove(taskID) }
        let execution = try HighlightTaskPlanner.execution(for: task)
        let includedSources = Set(execution.snapshot.segments.map(\.videoID))
        for video in task.videos where includedSources.contains(video.id.uuidString) {
            do { try await validateSource(video) } catch { throw HighlightTaskError.sourceUnavailable }
        }
        try Task.checkCancellation()
        guard foreground && !stoppingAll && generation == lifecycleGeneration else { throw HighlightTaskError.background }
        _ = try await store.installExecution(taskID: taskID, expectedRevision: expectedRevision, execution: execution)
        await refresh()
        if foreground && !stoppingAll && generation == lifecycleGeneration { startNextIfPossible() }
        else { try await stop(taskID: taskID) }
    }

    func restart(taskID: UUID) async throws {
        guard let task = task(taskID) else { throw HighlightTaskError.notFound }
        guard task.canRegenerateDirectly else { throw HighlightTaskError.mustReview }
        try await start(taskID: taskID, expectedRevision: task.configurationRevision)
    }

    func stop(taskID: UUID) async throws {
        guard let execution = task(taskID)?.activeExecution else { return }
        let result = try await store.finishExecution(taskID: taskID, executionID: execution.id,
            revision: execution.configurationRevision, status: .stopped, errorCode: nil, output: nil)
        if result != nil, running?.executionID == execution.id { running?.work.cancel() }
        await refresh()
        // running is deliberately retained until its underlying export and cleanup finish.
        startNextIfPossible()
    }

    func enterBackground() {
        foreground = false
        lifecycleGeneration += 1
        stoppingAll = true
        Task { await stopAllExecutions() }
    }
    func enterForeground() { foreground = true }

    func stopAllExecutions() async {
        stoppingAll = true
        var persisted = false
        do {
            _ = try await store.stopAll()
            persisted = true
            running?.work.cancel()
            await refresh()
        } catch {
            running?.work.cancel()
            errorMessage = message(error)
        }
        await waitUntilIdle()
        if persisted { stoppingAll = false }
    }

    func delete(taskID: UUID) async throws {
        guard let task = task(taskID) else { return }
        _ = try editableTask(taskID, revision: task.configurationRevision)
        guard !preparingTaskIDs.contains(taskID) else { throw HighlightTaskError.busy }
        try await store.delete(id: taskID, expectedRevision: task.configurationRevision)
        await refresh()
        do { try await fileStore.removeTask(taskID) } catch { logCleanupFailure() }
    }

    func playbackURL(taskID: UUID) throws -> URL {
        guard let task = task(taskID), task.allowedActions.contains(.play), let output = task.currentOutput else {
            throw HighlightTaskError.missingFile
        }
        let url = try fileStore.url(forRelativePath: output.relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { throw HighlightTaskError.missingFile }
        return url
    }

    func saveToPhotoLibrary(taskID: UUID) async throws {
        guard let task = task(taskID), task.allowedActions.contains(.save), let output = task.currentOutput,
              photoSavingTaskIDs.insert(taskID).inserted else { throw HighlightTaskError.busy }
        defer { photoSavingTaskIDs.remove(taskID) }
        do {
            try await saveVideo(playbackURL(taskID: taskID))
        } catch {
            _ = try await store.savePhotoResult(taskID: taskID, outputID: output.id, savedAt: nil, errorCode: .saveFailed)
            await refresh()
            throw HighlightTaskError.photoSaveFailed
        }
        analytics.track(.highlightSaveSucceeded)
        _ = try await store.savePhotoResult(taskID: taskID, outputID: output.id, savedAt: Date(), errorCode: nil)
        await refresh()
    }

    func waitUntilIdle() async { while let work = running?.work { await work.value } }

    private func startNextIfPossible() {
        guard foreground, !stoppingAll, running == nil,
              let next = tasks.filter({ $0.activeExecution?.status == .queued })
                .min(by: { $0.activeExecution!.createdAt < $1.activeExecution!.createdAt }),
              let execution = next.activeExecution else { return }
        let work = Task { await perform(taskID: next.id, execution: execution) }
        running = (next.id, execution.id, work)
    }

    private func perform(taskID: UUID, execution: HighlightRenderExecution) async {
        var newOutputID: UUID?
        var committed = false
        do {
            try Task.checkCancellation()
            guard try await store.updateProgress(taskID: taskID, executionID: execution.id,
                revision: execution.configurationRevision, progress: .zero) != nil else { throw CancellationError() }
            await refresh()
            let outputURL = try await fileStore.prepareExecution(execution.id)
            let generatedURL = try await runner.run(execution: execution, outputURL: outputURL) { [weak self] progress in
                Task { await self?.recordProgress(taskID: taskID, execution: execution, progress: progress) }
            }
            try Task.checkCancellation()
            let oldOutput = task(taskID)?.currentOutput
            let outputID = UUID()
            newOutputID = outputID
            let path = try await fileStore.moveOutput(at: generatedURL, taskID: taskID, outputID: outputID)
            let output = HighlightTaskOutput(id: outputID, relativePath: path,
                configurationRevision: execution.configurationRevision, generatedAt: Date())
            if try await store.finishExecution(taskID: taskID, executionID: execution.id,
                revision: execution.configurationRevision, status: .succeeded, errorCode: nil, output: output) != nil {
                committed = true
                analytics.track(.highlightGenerateSucceeded)
                await refresh()
                if let oldOutput {
                    do { try await fileStore.removeOutput(taskID: taskID, outputID: oldOutput.id) }
                    catch { logCleanupFailure() }
                }
            }
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            let code: HighlightTaskGenerationErrorCode = newOutputID != nil ? .outputCommitFailed
                : (error as? HighlightTaskError == .sourceUnavailable ? .sourceUnavailable : .exportFailed)
            do {
                _ = try await store.finishExecution(taskID: taskID, executionID: execution.id,
                    revision: execution.configurationRevision, status: cancelled ? .stopped : .failed,
                    errorCode: cancelled ? nil : code, output: nil)
                await refresh()
            } catch { errorMessage = message(error) }
        }
        if !committed, let newOutputID {
            do { try await fileStore.removeOutput(taskID: taskID, outputID: newOutputID) }
            catch { logCleanupFailure() }
        }
        do { try await fileStore.removeExecution(execution.id) } catch { logCleanupFailure() }
        if running?.executionID == execution.id { running = nil }
        startNextIfPossible()
    }

    private func recordProgress(taskID: UUID, execution: HighlightRenderExecution, progress: HighlightJobProgress) async {
        do {
            if try await store.updateProgress(taskID: taskID, executionID: execution.id,
                revision: execution.configurationRevision, progress: progress) != nil { await refresh() }
        } catch { errorMessage = message(error) }
    }

    private func editableTask(_ id: UUID, revision: Int) throws -> HighlightTask {
        guard let task = task(id) else { throw HighlightTaskError.notFound }
        guard task.activeExecution == nil, !photoSavingTaskIDs.contains(id) else { throw HighlightTaskError.busy }
        guard task.configurationRevision == revision else { throw HighlightTaskError.revisionConflict }
        return task
    }
    private func sanitized(_ error: Error) -> Error {
        if error is CancellationError || error is HighlightTaskError || error is HighlightClipReviewPlanningError { return error }
        return HighlightTaskError.persistence
    }
    private func message(_ error: Error) -> String { sanitized(error).localizedDescription }
    private func logCleanupFailure() {
        logger.warning("highlight.task.cleanup.failed", category: .video, message: "任务文件清理将在下次启动重试",
            context: ["errorCategory": "fileCleanup"])
    }
}
