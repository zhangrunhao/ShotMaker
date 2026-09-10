import AVFoundation
import Combine
import Foundation

@MainActor
final class HighlightReviewSession: ObservableObject {
    @Published private(set) var viewModel: HighlightClipReviewViewModel
    private let revision: Revision
    private let manager: HighlightTaskManager
    private var viewModelObservation: AnyCancellable?
    private var playbackController: HighlightClipPlaybackController?
    private let onExit: () -> Void
    private let cleanupPreparation: () -> Void

    private final class Revision {
        var task: HighlightTask
        init(_ task: HighlightTask) { self.task = task }
    }

    init(task: HighlightTask, manager: HighlightTaskManager,
        mediaProvider: HighlightClipReviewMediaProvider? = nil, notice: String? = nil,
        cleanupPreparation: @escaping () -> Void = {}, onExit: @escaping () -> Void = {}) throws {
        self.manager = manager
        self.onExit = onExit
        self.cleanupPreparation = cleanupPreparation
        let revision = Revision(task)
        self.revision = revision
        let media = HighlightTaskMedia(fileStore: manager.fileStore)
        let provider = mediaProvider ?? HighlightClipReviewMediaProvider.live(loadTaskAsset: { selected in
            guard let video = task.videos.first(where: { $0.id.uuidString == selected.id }) else { throw HighlightTaskError.sourceUnavailable }
            return try await media.asset(for: video)
        })
        viewModel = try Self.makeViewModel(revision: revision, manager: manager, provider: provider, notice: notice, onExit: onExit)
        observeViewModel()
    }

    func makePlaybackController() -> HighlightClipPlaybackController {
        playbackController?.reset()
        let provider = viewModel.mediaProvider
        let controller = HighlightClipPlaybackController { try await provider.asset(for: $0) }
        playbackController = controller
        return controller
    }

    func resetAll() async throws {
        let updated = try await manager.resetClips(taskID: revision.task.id, expectedRevision: revision.task.configurationRevision)
        release()
        revision.task = updated
        viewModel = try Self.makeViewModel(revision: revision, manager: manager,
            provider: viewModel.mediaProvider, notice: "已按当前默认时长重置全部片段。", onExit: onExit)
        observeViewModel()
    }

    private func observeViewModel() {
        viewModelObservation = viewModel.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func release() {
        viewModel.cancelMediaLoading()
        playbackController?.reset()
        playbackController = nil
        cleanupPreparation()
    }

    private static func makeViewModel(revision: Revision, manager: HighlightTaskManager,
        provider: HighlightClipReviewMediaProvider, notice: String?, onExit: @escaping () -> Void) throws -> HighlightClipReviewViewModel {
        let task = revision.task
        return HighlightClipReviewViewModel(draft: try HighlightTaskPlanner.reviewDraft(for: task),
            videos: task.videos.map(\.selectedTrainingVideo), clipSettings: task.clipSettings,
            persistConfirmation: { item in
                revision.task = try await manager.confirmClip(taskID: task.id,
                    expectedRevision: revision.task.configurationRevision, item: item)
            }, recoveryNoticeMessage: notice, mediaProvider: provider,
            submitSegments: { _ in
                try await manager.start(taskID: task.id, expectedRevision: revision.task.configurationRevision)
            }, onSubmissionSucceeded: onExit)
    }
}
