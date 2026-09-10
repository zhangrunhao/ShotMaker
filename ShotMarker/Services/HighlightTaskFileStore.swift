import CoreMedia
import Foundation

nonisolated struct PreparedHighlightTaskInputs: Sendable {
    let taskID: UUID
    let videos: [HighlightTaskVideo]
    let stagingDirectory: URL
    let addedPaths: [String]
}

actor HighlightTaskFileStore {
    nonisolated let baseDirectory: URL
    nonisolated let temporaryDirectory: URL
    private let manager = FileManager.default

    init(baseDirectory: URL? = nil, temporaryDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ShotMarker", isDirectory: true)
        self.temporaryDirectory = temporaryDirectory ?? FileManager.default.temporaryDirectory
    }

    func prepareInputs(_ selected: [SelectedTrainingVideo], taskID: UUID,
        existing: [HighlightTaskVideo]) async throws -> PreparedHighlightTaskInputs {
        guard (1...20).contains(selected.count) else { throw HighlightTaskError.invalidTask }
        let staging = try url(forRelativePath: "HighlightTasks/.staging-\(taskID)-\(UUID())")
        try manager.createDirectory(at: staging.appendingPathComponent("Inputs"), withIntermediateDirectories: true)
        var addedPaths: [String] = []
        var videos: [HighlightTaskVideo] = []
        do {
            for video in selected {
                try Task.checkCancellation()
                guard video.duration.isFinite, video.duration > 0,
                      video.recordedStartAt.timeIntervalSince1970.isFinite else { throw HighlightTaskError.invalidTask }
                let old = existing.first { $0.sourceIdentity == video.reviewSourceIdentity }
                let videoID = old?.id ?? UUID()
                let identity: HighlightClipReviewSourceIdentity
                let source: HighlightTaskVideoSource
                if let old, try canReuse(old, selectionID: video.id) {
                    identity = old.sourceIdentity
                    source = old.source
                } else if let url = URL(string: video.id), url.isFileURL {
                    let fileExtension = url.pathExtension.lowercased()
                    guard fileExtension.isEmpty || fileExtension.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                        throw HighlightTaskError.invalidPath
                    }
                    let name = "\(videoID).\(fileExtension.isEmpty ? "mov" : fileExtension)"
                    let destination = staging.appendingPathComponent("Inputs/\(name)")
                    try manager.copyItem(at: url, to: destination)
                    let digest = try await HighlightClipReviewContentHasher().sha256(for: destination)
                    identity = .fileSHA256(digest)
                    if let expected = video.reviewSourceIdentity, expected != identity { throw HighlightTaskError.sourceUnavailable }
                    let path = "HighlightTasks/\(taskID)/Inputs/\(name)"
                    source = .taskInputFile(relativePath: path)
                    addedPaths.append(path)
                } else {
                    identity = video.reviewSourceIdentity ?? .photoLibraryAsset(video.id)
                    guard identity.kind == .photoLibraryAsset, !identity.value.isEmpty else { throw HighlightTaskError.sourceUnavailable }
                    source = .photoLibraryAsset(localIdentifier: identity.value)
                }
                guard !videos.contains(where: { $0.sourceIdentity == identity }) else { throw HighlightTaskError.invalidTask }
                videos.append(HighlightTaskVideo(id: videoID, sourceIdentity: identity,
                    recordedStartAt: Date(timeIntervalSince1970: (video.recordedStartAt.timeIntervalSince1970 * 1_000).rounded() / 1_000),
                    duration: CMTime(seconds: video.duration, preferredTimescale: 600).seconds, source: source))
            }
            return PreparedHighlightTaskInputs(taskID: taskID, videos: videos, stagingDirectory: staging, addedPaths: addedPaths)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    func commitInputs(_ prepared: PreparedHighlightTaskInputs, creating: Bool) throws {
        if creating {
            let destination = try taskDirectory(prepared.taskID)
            guard !manager.fileExists(atPath: destination.path) else { throw HighlightTaskError.invalidPath }
            try manager.moveItem(at: prepared.stagingDirectory, to: destination)
        } else {
            do {
                for path in prepared.addedPaths {
                    let destination = try writingURL(path)
                    try manager.moveItem(at: prepared.stagingDirectory.appendingPathComponent("Inputs/\(destination.lastPathComponent)"), to: destination)
                }
                try manager.removeItem(at: prepared.stagingDirectory)
            } catch {
                for path in prepared.addedPaths { try? removeFile(path) }
                throw error
            }
        }
    }

    func discard(_ prepared: PreparedHighlightTaskInputs, committedCreation: Bool = false) throws {
        try removeIfPresent(prepared.stagingDirectory)
        if committedCreation { try removeTask(prepared.taskID) }
        else { for path in prepared.addedPaths { try removeFile(path) } }
    }

    func moveOutput(at sourceURL: URL, taskID: UUID, outputID: UUID) throws -> String {
        let path = "HighlightTasks/\(taskID)/Outputs/\(outputID)/highlight.mov"
        let destination = try writingURL(path)
        try manager.moveItem(at: sourceURL, to: destination)
        return path
    }

    func removeOutput(taskID: UUID, outputID: UUID) throws {
        try removeIfPresent(try url(forRelativePath: "HighlightTasks/\(taskID)/Outputs/\(outputID)"))
    }

    func removeUnusedInputs(old: [HighlightTaskVideo], current: [HighlightTaskVideo]) throws {
        for video in old {
            if case .taskInputFile(let path) = video.source,
               !current.contains(where: { $0.source == video.source }) { try removeFile(path) }
        }
    }

    private func canReuse(_ old: HighlightTaskVideo, selectionID: String) throws -> Bool {
        guard case .taskInputFile(let path) = old.source,
              let selectedURL = URL(string: selectionID), selectedURL.isFileURL else { return true }
        let oldURL = try url(forRelativePath: path)
        // Missing stored input stays editable; an explicitly reselected file repairs it.
        return manager.fileExists(atPath: oldURL.path)
            || oldURL.standardizedFileURL == selectedURL.standardizedFileURL
    }

    func removeTask(_ taskID: UUID) throws { try removeIfPresent(try taskDirectory(taskID)) }

    func prepareExecution(_ executionID: UUID) throws -> URL {
        let directory = executionDirectory(executionID)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("highlight.mov")
    }

    func removeExecution(_ executionID: UUID) throws { try removeIfPresent(executionDirectory(executionID)) }

    /// Only call after a reliable task document load, and while no transactions are in flight.
    func cleanOrphans(referencing tasks: [HighlightTask]) throws {
        let root = try url(forRelativePath: "HighlightTasks")
        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for directory in try children(root) {
            let name = directory.lastPathComponent
            if name.hasPrefix(".staging-") { try manager.removeItem(at: directory); continue }
            guard let taskID = UUID(uuidString: name) else { continue }
            guard let task = tasksByID[taskID] else { try removeTask(taskID); continue }
            let inputNames = Set(task.videos.compactMap { video -> String? in
                guard case .taskInputFile(let path) = video.source else { return nil }
                return URL(fileURLWithPath: path).lastPathComponent
            })
            for input in try children(try url(forRelativePath: "HighlightTasks/\(taskID)/Inputs")) where !inputNames.contains(input.lastPathComponent) {
                try manager.removeItem(at: input)
            }
            for output in try children(try url(forRelativePath: "HighlightTasks/\(taskID)/Outputs")) {
                if let id = UUID(uuidString: output.lastPathComponent), id != task.currentOutput?.id {
                    try removeOutput(taskID: taskID, outputID: id)
                }
            }
        }
        let active = Set(tasks.compactMap { $0.activeExecution?.id })
        for path in try children(temporaryDirectory) {
            let name = path.lastPathComponent
            guard name.hasPrefix("ShotMarker-Render-"),
                  let id = UUID(uuidString: String(name.dropFirst("ShotMarker-Render-".count))), !active.contains(id) else { continue }
            try removeExecution(id)
        }
    }

    nonisolated func url(forRelativePath path: String) throws -> URL {
        guard HighlightTaskValidation.isSafePath(path), path.split(separator: "/").first == "HighlightTasks" else {
            throw HighlightTaskError.invalidPath
        }
        // Reject every symlink component, including links into another task within the sandbox.
        var cursor = baseDirectory
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw HighlightTaskError.invalidPath
            }
        }
        let root = baseDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard cursor.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw HighlightTaskError.invalidPath }
        return cursor
    }

    private func writingURL(_ path: String) throws -> URL {
        let url = try url(forRelativePath: path)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }
    private func taskDirectory(_ id: UUID) throws -> URL { try url(forRelativePath: "HighlightTasks/\(id)") }
    private func executionDirectory(_ id: UUID) -> URL { temporaryDirectory.appendingPathComponent("ShotMarker-Render-\(id)", isDirectory: true) }
    private func removeFile(_ path: String) throws { try removeIfPresent(try url(forRelativePath: path)) }
    private func removeIfPresent(_ url: URL) throws {
        if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
    }
    private func children(_ url: URL) throws -> [URL] {
        guard manager.fileExists(atPath: url.path) else { return [] }
        return try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
}
