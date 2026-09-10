import Foundation

protocol TrainingSessionImporting {
    func `import`(_ payload: TrainingSessionSyncPayload) async throws
}

final class TrainingSessionImporter: TrainingSessionImporting {
    private let store: TrainingSessionStoreProtocol
    private let reviewStore: (any HighlightClipReviewStoring)?
    private let logger: AppLogging

    init(
        store: TrainingSessionStoreProtocol,
        reviewStore: (any HighlightClipReviewStoring)? = nil,
        logger: AppLogging = AppLogger.shared,
    ) {
        self.store = store
        self.reviewStore = reviewStore
        self.logger = logger
    }

    func `import`(_ payload: TrainingSessionSyncPayload) async throws {
        var sessions = try store.loadTrainingSessions()
        let session = TrainingSession(
            id: payload.id,
            startedAt: payload.startedAt,
            endedAt: payload.endedAt,
            events: payload.events.map { event in
                ShotMarkerEvent(id: event.id, markedAt: event.markedAt)
            },
        )
        var replacedSession: TrainingSession?

        if let index = sessions.firstIndex(where: { $0.id == payload.id }) {
            replacedSession = sessions[index]
            sessions[index] = session
        } else {
            sessions.append(session)
        }

        try store.saveTrainingSessions(sessions)

        guard let replacedSession,
              HighlightClipReviewIdentityBuilder.trainingIdentity(for: replacedSession)
                  != HighlightClipReviewIdentityBuilder.trainingIdentity(for: session)
        else {
            return
        }

        do {
            try await reviewStore?.deleteRecords(forTrainingSessionID: session.id)
        } catch {
            logger.error(
                "highlight.review.cleanup.failed",
                category: .video,
                message: "清理失效的片段确认记录失败",
                error: nil,
                context: [
                    "errorCategory": Self.reviewCleanupErrorCategory(error),
                    "affectedTrainingCount": "1",
                ],
            )
        }
    }

    private nonisolated static func reviewCleanupErrorCategory(_ error: Error) -> String {
        error is HighlightClipReviewStoreError ? "reviewStoreContract" : "reviewStoreIO"
    }
}
