import Foundation

struct TrainingSessionJSONImportResult: Equatable {
    let importedCount: Int
    let insertedCount: Int
    let replacedCount: Int
}

enum TrainingSessionJSONTransferError: LocalizedError, Equatable {
    case emptyExportSelection
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .emptyExportSelection:
            "请先选择要导出的训练记录。"
        case .invalidJSON:
            "JSON 文件格式不正确，无法导入训练记录。"
        }
    }
}

struct TrainingSessionJSONTransferService {
    private let store: TrainingSessionStoreProtocol
    private let reviewStore: (any HighlightClipReviewStoring)?
    private let notificationCenter: NotificationCenter
    private let logger: AppLogging
    private let decoder = JSONDecoder()
    private let encoder: JSONEncoder

    init(
        store: TrainingSessionStoreProtocol,
        reviewStore: (any HighlightClipReviewStoring)? = nil,
        notificationCenter: NotificationCenter = .default,
        logger: AppLogging = AppLogger.shared,
    ) {
        self.store = store
        self.reviewStore = reviewStore
        self.notificationCenter = notificationCenter
        self.logger = logger

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func importTrainingSessions(from fileURL: URL) async throws -> TrainingSessionJSONImportResult {
        let isAccessingSecurityScopedResource = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessingSecurityScopedResource {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        return try await importTrainingSessions(from: Data(contentsOf: fileURL))
    }

    func importTrainingSessions(from data: Data) async throws -> TrainingSessionJSONImportResult {
        guard let importedSessions = Self.decodeTrainingSessions(from: data, decoder: decoder) else {
            throw TrainingSessionJSONTransferError.invalidJSON
        }

        var sessions = try store.loadTrainingSessions()
        var insertedCount = 0
        var replacedCount = 0
        var changedReplacedIDs: [UUID] = []

        for importedSession in importedSessions {
            if let index = sessions.firstIndex(where: { $0.id == importedSession.id }) {
                if HighlightClipReviewIdentityBuilder.trainingIdentity(for: sessions[index])
                    != HighlightClipReviewIdentityBuilder.trainingIdentity(for: importedSession),
                    !changedReplacedIDs.contains(importedSession.id)
                {
                    changedReplacedIDs.append(importedSession.id)
                }
                sessions[index] = importedSession
                replacedCount += 1
            } else {
                sessions.append(importedSession)
                insertedCount += 1
            }
        }

        try store.saveTrainingSessions(sessions)
        await cleanupReviewRecords(for: changedReplacedIDs)
        notificationCenter.post(name: .trainingSessionsDidChange, object: nil)

        return TrainingSessionJSONImportResult(
            importedCount: importedSessions.count,
            insertedCount: insertedCount,
            replacedCount: replacedCount,
        )
    }

    func exportData(for sessions: [TrainingSession]) throws -> Data {
        guard !sessions.isEmpty else {
            throw TrainingSessionJSONTransferError.emptyExportSelection
        }

        return try encoder.encode(sessions)
    }

    private static func decodeTrainingSessions(from data: Data, decoder: JSONDecoder) -> [TrainingSession]? {
        if let sessions = try? decoder.decode([TrainingSession].self, from: data) {
            return sessions
        }

        if let session = try? decoder.decode(TrainingSession.self, from: data) {
            return [session]
        }

        return nil
    }

    private func cleanupReviewRecords(for trainingSessionIDs: [UUID]) async {
        var failureCategories: Set<String> = []
        var failureCount = 0
        for id in trainingSessionIDs {
            do {
                try await reviewStore?.deleteRecords(forTrainingSessionID: id)
            } catch {
                failureCount += 1
                failureCategories.insert(Self.reviewCleanupErrorCategory(error))
            }
        }

        guard failureCount > 0 else {
            return
        }
        logger.error(
            "highlight.review.cleanup.failed",
            category: .video,
            message: "清理失效的片段确认记录失败",
            error: nil,
            context: [
                "errorCategory": failureCategories.count == 1
                    ? failureCategories.first ?? "reviewStoreIO"
                    : "multipleReviewStoreFailures",
                "affectedTrainingCount": "\(failureCount)",
            ],
        )
    }

    private nonisolated static func reviewCleanupErrorCategory(_ error: Error) -> String {
        error is HighlightClipReviewStoreError ? "reviewStoreContract" : "reviewStoreIO"
    }
}
