import Combine
import Foundation

struct TrainingSessionRowViewData: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let titleDate: Date
    let descriptionStartedAt: Date
    let descriptionEndedAt: Date
    let markerCount: Int

    init(
        id: UUID,
        startedAt: Date,
        titleDate: Date,
        descriptionStartedAt: Date,
        descriptionEndedAt: Date,
        markerCount: Int,
    ) {
        self.id = id
        self.startedAt = startedAt
        self.titleDate = titleDate
        self.descriptionStartedAt = descriptionStartedAt
        self.descriptionEndedAt = descriptionEndedAt
        self.markerCount = markerCount
    }

    init(session: TrainingSession) {
        let markerTimeRange = session.markerTimeRange

        self.init(
            id: session.id,
            startedAt: session.startedAt,
            titleDate: markerTimeRange.startedAt,
            descriptionStartedAt: markerTimeRange.startedAt,
            descriptionEndedAt: markerTimeRange.endedAt,
            markerCount: session.markerCount,
        )
    }
}

@MainActor
final class TrainingSessionListViewModel: ObservableObject {
    @Published private(set) var rows: [TrainingSessionRowViewData] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var selectedSessionIDs: Set<UUID> = []

    private let store: TrainingSessionStoreProtocol
    private let reviewStore: (any HighlightClipReviewStoring)?
    private let notificationCenter: NotificationCenter
    private let logger: AppLogging
    private var sessions: [TrainingSession] = []
    private var trainingSessionsDidChangeObserver: NSObjectProtocol?

    var isEmpty: Bool {
        rows.isEmpty
    }

    var isSelectionMode: Bool {
        !selectedSessionIDs.isEmpty
    }

    var canMergeSelectedSessions: Bool {
        selectedSessionIDs.count >= 2
    }

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
        trainingSessionsDidChangeObserver = notificationCenter.addObserver(
            forName: .trainingSessionsDidChange,
            object: nil,
            queue: nil,
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.load()
            }
        }
    }

    deinit {
        if let trainingSessionsDidChangeObserver {
            notificationCenter.removeObserver(trainingSessionsDidChangeObserver)
        }
    }

    func load() async {
        let loadedSessions: [TrainingSession]
        do {
            loadedSessions = try store.loadTrainingSessions()
            sessions = loadedSessions
            rows = Self.makeRows(from: loadedSessions)
            selectedSessionIDs.formIntersection(Set(rows.map(\.id)))
            errorMessage = nil
            logger.info(
                "training.sessions.load.succeeded",
                category: .training,
                message: "训练记录读取成功",
                context: ["trainingSessionCount": "\(loadedSessions.count)"],
            )
        } catch {
            sessions = []
            rows = []
            selectedSessionIDs = []
            errorMessage = "无法读取训练记录"
            logger.error(
                "training.sessions.load.failed",
                category: .training,
                message: "训练记录读取失败",
                error: error,
            )
            return
        }

        do {
            try await reviewStore?.reconcile(
                validTrainingIdentities: Set(
                    loadedSessions.map {
                        HighlightClipReviewIdentityBuilder.trainingIdentity(for: $0)
                    },
                ),
            )
        } catch {
            errorMessage = nil
            logger.error(
                "highlight.review.reconcile.failed",
                category: .video,
                message: "片段确认记录协调失败",
                error: nil,
                context: [
                    "errorCategory": Self.reviewCleanupErrorCategory(error),
                    "trainingSessionCount": "\(loadedSessions.count)",
                ],
            )
        }
    }

    func session(for sessionID: UUID) -> TrainingSession? {
        sessions.first { $0.id == sessionID }
    }

    func beginSelection(with sessionID: UUID) {
        guard rows.contains(where: { $0.id == sessionID }) else {
            return
        }

        selectedSessionIDs = [sessionID]
    }

    func toggleSelection(for sessionID: UUID) {
        guard rows.contains(where: { $0.id == sessionID }) else {
            return
        }

        if selectedSessionIDs.contains(sessionID) {
            selectedSessionIDs.remove(sessionID)
        } else {
            selectedSessionIDs.insert(sessionID)
        }
    }

    func clearSelection() {
        selectedSessionIDs = []
    }

    func isSelected(_ sessionID: UUID) -> Bool {
        selectedSessionIDs.contains(sessionID)
    }

    func selectedSessionsForExport() -> [TrainingSession] {
        rows.compactMap { row in
            guard selectedSessionIDs.contains(row.id) else {
                return nil
            }

            return session(for: row.id)
        }
    }

    func allSessionsForExport() -> [TrainingSession] {
        rows.compactMap { row in
            session(for: row.id)
        }
    }

    func importTrainingSessions(from fileURL: URL) async throws -> TrainingSessionJSONImportResult {
        let service = TrainingSessionJSONTransferService(
            store: store,
            reviewStore: reviewStore,
            notificationCenter: notificationCenter,
            logger: logger,
        )
        let result = try await service.importTrainingSessions(from: fileURL)
        await load()
        return result
    }

    func exportSelectedSessionsData() throws -> Data {
        try TrainingSessionJSONTransferService(
            store: store,
            reviewStore: reviewStore,
            notificationCenter: notificationCenter,
            logger: logger,
        )
        .exportData(for: selectedSessionsForExport())
    }

    func exportAllSessionsData() throws -> Data {
        try TrainingSessionJSONTransferService(
            store: store,
            reviewStore: reviewStore,
            notificationCenter: notificationCenter,
            logger: logger,
        )
        .exportData(for: allSessionsForExport())
    }

    func mergeSelectedSessions() async {
        guard canMergeSelectedSessions else {
            return
        }

        let mergedSessionIDs = selectedSessionIDs
        do {
            var sessions = try store.loadTrainingSessions()
            let selectedSessions = sessions.filter { mergedSessionIDs.contains($0.id) }

            guard selectedSessions.count >= 2, let mergedSession = TrainingSession.merged(selectedSessions) else {
                return
            }

            sessions.removeAll { mergedSessionIDs.contains($0.id) }
            sessions.append(mergedSession)

            try store.saveTrainingSessions(sessions)
            self.sessions = sessions
            selectedSessionIDs = []
            rows = Self.makeRows(from: sessions)
            errorMessage = nil
            logger.info(
                "training.sessions.merge.succeeded",
                category: .training,
                message: "训练记录合并成功",
                context: ["mergedSessionCount": "\(selectedSessions.count)"],
            )
            notificationCenter.post(name: .trainingSessionsDidChange, object: nil)
        } catch {
            errorMessage = "无法合并训练记录"
            logger.error(
                "training.sessions.merge.failed",
                category: .training,
                message: "训练记录合并失败",
                error: error,
                context: ["selectedSessionCount": "\(selectedSessionIDs.count)"],
            )
            return
        }

        await cleanupReviewRecords(for: mergedSessionIDs)
    }

    func deleteSelectedSessions() async {
        let deletedSessionIDs = selectedSessionIDs
        guard !deletedSessionIDs.isEmpty else {
            return
        }

        do {
            var sessions = try store.loadTrainingSessions()
            sessions.removeAll { deletedSessionIDs.contains($0.id) }
            try store.saveTrainingSessions(sessions)
            self.sessions = sessions
            selectedSessionIDs = []
            rows = Self.makeRows(from: sessions)
            errorMessage = nil
            logger.info(
                "training.sessions.delete.succeeded",
                category: .training,
                message: "训练记录删除成功",
                context: ["deletedTrainingSessionCount": "\(deletedSessionIDs.count)"],
            )
            notificationCenter.post(name: .trainingSessionsDidChange, object: nil)
        } catch {
            errorMessage = "无法删除训练记录"
            logger.error(
                "training.sessions.delete.failed",
                category: .training,
                message: "训练记录删除失败",
                error: error,
                context: ["selectedSessionCount": "\(deletedSessionIDs.count)"],
            )
            return
        }

        await cleanupReviewRecords(for: deletedSessionIDs)
    }

    private func cleanupReviewRecords(for trainingSessionIDs: Set<UUID>) async {
        var failureCategories: Set<String> = []
        var failureCount = 0
        for id in trainingSessionIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
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

    private static func makeRows(from sessions: [TrainingSession]) -> [TrainingSessionRowViewData] {
        sessions
            .sorted { $0.startedAt > $1.startedAt }
            .map(TrainingSessionRowViewData.init(session:))
    }
}
