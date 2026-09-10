import Foundation

nonisolated protocol HighlightTaskStoring: Sendable {
    func loadForLaunch() async throws -> [HighlightTask]
    func load() async throws -> [HighlightTask]
    func create(_ task: HighlightTask) async throws
    func updateConfiguration(id: UUID, expectedRevision: Int, videos: [HighlightTaskVideo],
        settings: ClipSettings, items: [PersistedHighlightTaskClip]) async throws -> HighlightTask
    func installExecution(taskID: UUID, expectedRevision: Int, execution: HighlightRenderExecution) async throws -> HighlightTask
    func updateProgress(taskID: UUID, executionID: UUID, revision: Int, progress: HighlightJobProgress) async throws -> HighlightTask?
    func finishExecution(taskID: UUID, executionID: UUID, revision: Int,
        status: HighlightTaskGenerationResultStatus, errorCode: HighlightTaskGenerationErrorCode?,
        output: HighlightTaskOutput?) async throws -> HighlightTask?
    func stopAll() async throws -> [HighlightTask]
    func savePhotoResult(taskID: UUID, outputID: UUID, savedAt: Date?, errorCode: HighlightTaskPhotoSaveErrorCode?) async throws -> HighlightTask?
    func delete(id: UUID, expectedRevision: Int) async throws
}

actor HighlightTaskStore: HighlightTaskStoring {
    typealias AtomicWrite = @Sendable (Data, URL) throws -> Void
    private let fileURL: URL
    private let atomicWrite: AtomicWrite
    private let now: @Sendable () -> Date

    init(fileURL: URL? = nil,
         atomicWrite: @escaping AtomicWrite = { try $0.write(to: $1, options: .atomic) },
         now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotMarker/highlight-tasks.json")
        self.atomicWrite = atomicWrite
        self.now = now
    }

    func load() throws -> [HighlightTask] { try read().tasks }

    func loadForLaunch() throws -> [HighlightTask] { try stopAll() }

    func create(_ task: HighlightTask) throws {
        var document = try read()
        guard !document.tasks.contains(where: { $0.id == task.id }), task.configurationRevision == 1,
              task.activeExecution == nil, task.currentOutput == nil, task.lastGenerationResult == nil
        else { throw HighlightTaskError.invalidTask }
        try HighlightTaskValidation.validate(task)
        document.tasks.insert(task, at: 0)
        try write(document)
    }

    func updateConfiguration(id: UUID, expectedRevision: Int, videos: [HighlightTaskVideo],
        settings: ClipSettings, items: [PersistedHighlightTaskClip]) throws -> HighlightTask {
        var document = try read()
        let index = try index(of: id, revision: expectedRevision, in: document)
        var task = document.tasks[index]
        guard task.activeExecution == nil else { throw HighlightTaskError.busy }
        guard task.videos != videos || task.clipSettings != settings.normalized || task.reviewItems != items else { return task }
        task.videos = videos
        task.clipSettings = settings.normalized
        task.reviewItems = items
        task.configurationRevision += 1
        task.updatedAt = now()
        try HighlightTaskValidation.validate(task)
        document.tasks[index] = task
        try write(document)
        return task
    }

    func installExecution(taskID: UUID, expectedRevision: Int, execution: HighlightRenderExecution) throws -> HighlightTask {
        var document = try read()
        let index = try index(of: taskID, revision: expectedRevision, in: document)
        guard document.tasks[index].activeExecution == nil else { throw HighlightTaskError.busy }
        let task = document.tasks[index]
        guard execution.configurationRevision == expectedRevision, execution.status == .queued,
              execution.snapshot.trainingSnapshot == task.trainingSnapshot,
              execution.snapshot.videos == task.videos, execution.snapshot.clipSettings == task.clipSettings
        else { throw HighlightTaskError.invalidTask }
        document.tasks[index].activeExecution = execution
        document.tasks[index].updatedAt = now()
        try HighlightTaskValidation.validate(document.tasks[index])
        try write(document)
        return document.tasks[index]
    }

    func updateProgress(taskID: UUID, executionID: UUID, revision: Int, progress: HighlightJobProgress) throws -> HighlightTask? {
        var document = try read()
        guard let index = activeIndex(taskID, executionID, revision, in: document) else { return nil }
        document.tasks[index].activeExecution?.status = .running
        document.tasks[index].activeExecution?.progress = progress
        document.tasks[index].activeExecution?.updatedAt = now()
        try write(document)
        return document.tasks[index]
    }

    func finishExecution(taskID: UUID, executionID: UUID, revision: Int,
        status: HighlightTaskGenerationResultStatus, errorCode: HighlightTaskGenerationErrorCode? = nil,
        output: HighlightTaskOutput? = nil) throws -> HighlightTask? {
        var document = try read()
        guard let index = activeIndex(taskID, executionID, revision, in: document) else { return nil }
        guard (status == .failed) == (errorCode != nil), (status == .succeeded) == (output != nil) else {
            throw HighlightTaskError.invalidTask
        }
        if let output {
            guard output.configurationRevision == revision else { throw HighlightTaskError.revisionConflict }
            document.tasks[index].currentOutput = output
        }
        document.tasks[index].activeExecution = nil
        document.tasks[index].lastGenerationResult = HighlightTaskGenerationResult(executionID: executionID,
            configurationRevision: revision, status: status, finishedAt: now(), errorCode: errorCode)
        document.tasks[index].updatedAt = now()
        try HighlightTaskValidation.validate(document.tasks[index])
        try write(document)
        return document.tasks[index]
    }

    func stopAll() throws -> [HighlightTask] {
        var document = try read()
        var changed = false
        for index in document.tasks.indices {
            guard let execution = document.tasks[index].activeExecution else { continue }
            document.tasks[index].activeExecution = nil
            document.tasks[index].lastGenerationResult = HighlightTaskGenerationResult(executionID: execution.id,
                configurationRevision: execution.configurationRevision, status: .stopped, finishedAt: now(), errorCode: nil)
            document.tasks[index].updatedAt = now()
            changed = true
        }
        if changed { try write(document) }
        return document.tasks
    }

    func savePhotoResult(taskID: UUID, outputID: UUID, savedAt: Date?, errorCode: HighlightTaskPhotoSaveErrorCode?) throws -> HighlightTask? {
        var document = try read()
        guard let index = document.tasks.firstIndex(where: { $0.id == taskID }),
              document.tasks[index].currentOutput?.id == outputID else { return nil }
        if let savedAt { document.tasks[index].currentOutput?.photoLibrarySavedAt = savedAt }
        document.tasks[index].currentOutput?.photoLibrarySaveErrorCode = errorCode
        document.tasks[index].updatedAt = now()
        try write(document)
        return document.tasks[index]
    }

    func delete(id: UUID, expectedRevision: Int) throws {
        var document = try read()
        let index = try index(of: id, revision: expectedRevision, in: document)
        guard document.tasks[index].activeExecution == nil else { throw HighlightTaskError.busy }
        document.tasks.remove(at: index)
        try write(document)
    }

    private func index(of id: UUID, revision: Int, in document: HighlightTaskStoreDocument) throws -> Int {
        guard let index = document.tasks.firstIndex(where: { $0.id == id }) else { throw HighlightTaskError.notFound }
        guard document.tasks[index].configurationRevision == revision else { throw HighlightTaskError.revisionConflict }
        return index
    }

    private func activeIndex(_ taskID: UUID, _ executionID: UUID, _ revision: Int, in document: HighlightTaskStoreDocument) -> Int? {
        document.tasks.firstIndex {
            $0.id == taskID && $0.configurationRevision == revision && $0.activeExecution?.id == executionID
                && $0.activeExecution?.configurationRevision == revision
        }
    }

    private func read() throws -> HighlightTaskStoreDocument {
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            // A quarantined document has no reliable reference set, including after another launch.
            let siblings = (try? manager.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)) ?? []
            if siblings.contains(where: { $0.hasPrefix("highlight-tasks.corrupt-") }) { throw HighlightTaskError.corruptDocument }
            return .empty
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) } catch { throw HighlightTaskError.persistence }
        struct Header: Decodable { let schemaVersion: Int }
        if let header = try? JSONDecoder().decode(Header.self, from: data), header.schemaVersion > 1 {
            throw HighlightTaskError.unsupportedSchema
        }
        do {
            let document = try JSONDecoder().decode(HighlightTaskStoreDocument.self, from: data)
            guard document.schemaVersion == 1, Set(document.tasks.map(\.id)).count == document.tasks.count else {
                throw HighlightTaskError.invalidTask
            }
            for task in document.tasks { try HighlightTaskValidation.validate(task) }
            return document
        } catch {
            let formatter = ISO8601DateFormatter()
            let timestamp = formatter.string(from: now()).replacingOccurrences(of: ":", with: "-")
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("highlight-tasks.corrupt-\(timestamp)-\(UUID()).json")
            do { try manager.moveItem(at: fileURL, to: backup) } catch { throw HighlightTaskError.persistence }
            throw HighlightTaskError.corruptDocument
        }
    }

    private func write(_ document: HighlightTaskStoreDocument) throws {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try atomicWrite(encoder.encode(document), fileURL)
        } catch { throw HighlightTaskError.persistence }
    }
}
