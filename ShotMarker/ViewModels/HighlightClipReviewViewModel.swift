import Combine
import CoreGraphics
import Foundation

enum HighlightClipThumbnailState: Equatable {
    case idle
    case loading
    case loaded(Data)
    case placeholder
}

@MainActor
final class HighlightClipReviewViewModel: ObservableObject {
    typealias SubmitSegments = ([ConfirmedHighlightSegment]) async throws -> Void

    @Published private(set) var items: [HighlightClipReviewItem]
    @Published private(set) var summary: HighlightClipReviewSummary
    @Published private(set) var thumbnailStates: [UUID: HighlightClipThumbnailState]
    @Published private(set) var filmstripFramesByItemID: [UUID: [Data?]] = [:]
    @Published private(set) var filmstripWindowsByItemID: [UUID: HighlightClipTimelineWindow] = [:]
    @Published private(set) var filmstripLoadingItemIDs: Set<UUID> = []
    @Published private(set) var unavailableItemIDs: Set<UUID> = []
    @Published private(set) var itemErrorMessages: [UUID: String] = [:]
    @Published private(set) var planningErrorMessage: String?
    @Published private(set) var editingItemID: UUID?
    @Published private(set) var isSubmitting = false
    @Published private(set) var submissionErrorMessage: String?
    @Published private(set) var recoveryNoticeMessage: String?

    let mediaProvider: HighlightClipReviewMediaProvider
    private(set) var videos: [SelectedTrainingVideo]

    private let combinationKey: HighlightClipReviewCombinationKey?
    private let reviewStore: (any HighlightClipReviewStoring)?
    private let persistConfirmation: ((HighlightClipReviewItem) async throws -> Void)?
    private let now: () -> Date
    private let inputFingerprint: HighlightClipReviewInputFingerprint
    private let submitSegments: SubmitSegments
    private let onSubmissionSucceeded: () -> Void
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]
    private var thumbnailRecency: [UUID] = []
    private var thumbnailTargetSizes: [UUID: CGSize] = [:]
    private var filmstripTasks: [UUID: Task<Void, Never>] = [:]
    private var filmstripRequestIDs: [UUID: UUID] = [:]

    init(
        draft: HighlightClipReviewDraft,
        videos: [SelectedTrainingVideo],
        clipSettings: ClipSettings,
        combinationKey: HighlightClipReviewCombinationKey? = nil,
        reviewStore: (any HighlightClipReviewStoring)? = nil,
        persistConfirmation: ((HighlightClipReviewItem) async throws -> Void)? = nil,
        recoveryNoticeMessage: String? = nil,
        mediaProvider: HighlightClipReviewMediaProvider,
        now: @escaping () -> Date = Date.init,
        submitSegments: @escaping SubmitSegments,
        onSubmissionSucceeded: @escaping () -> Void = {},
    ) {
        items = draft.items
        self.videos = videos
        self.combinationKey = combinationKey
        self.reviewStore = reviewStore
        self.persistConfirmation = persistConfirmation
        self.recoveryNoticeMessage = recoveryNoticeMessage
        self.mediaProvider = mediaProvider
        self.now = now
        self.submitSegments = submitSegments
        self.onSubmissionSucceeded = onSubmissionSucceeded
        inputFingerprint = Self.makeFingerprint(videos: videos, clipSettings: clipSettings)

        let includedMarkerCount = draft.items
            .filter(\.isIncluded)
            .reduce(0) { $0 + $1.markerReferences.count }
        let excludedMarkerCount = draft.items
            .filter { !$0.isIncluded }
            .reduce(0) { $0 + $1.markerReferences.count }
        summary = HighlightClipReviewSummary(
            includedMarkerCount: includedMarkerCount,
            excludedMarkerCount: excludedMarkerCount,
            finalSegments: [],
            displayNumberRangesByItemID: [:],
            mergingItemIDs: [],
        )
        thumbnailStates = draft.items.reduce(into: [:]) { states, item in
            states[item.id] = .idle
        }

        refreshSummary()
    }

    var canConfirm: Bool {
        guard !summary.finalSegments.isEmpty,
              planningErrorMessage == nil,
              !isSubmitting
        else {
            return false
        }

        return items.filter(\.isIncluded).allSatisfy { item in
            !unavailableItemIDs.contains(item.id)
                && itemErrorMessages[item.id] == nil
        }
    }

    func loadThumbnail(itemID: UUID, targetSize: CGSize) async {
        guard let task = startThumbnailLoad(itemID: itemID, targetSize: targetSize) else {
            return
        }

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func loadFilmstrip(
        itemID: UUID,
        window: HighlightClipTimelineWindow,
        count: Int,
        targetSize: CGSize,
    ) async {
        guard let item = items.first(where: { $0.id == itemID }),
              let video = videos.first(where: { $0.id == item.videoID })
        else {
            return
        }

        cancelFilmstripLoading(itemID: itemID)
        let requestID = UUID()
        filmstripRequestIDs[itemID] = requestID
        filmstripLoadingItemIDs.insert(itemID)
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await performFilmstripLoad(
                itemID: itemID,
                video: video,
                window: window,
                count: count,
                targetSize: targetSize,
                requestID: requestID,
            )
        }
        filmstripTasks[itemID] = task

        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelFilmstripLoading(itemID: UUID) {
        filmstripTasks[itemID]?.cancel()
        filmstripTasks[itemID] = nil
        filmstripRequestIDs[itemID] = nil
        filmstripLoadingItemIDs.remove(itemID)
        filmstripFramesByItemID[itemID] = nil
        filmstripWindowsByItemID[itemID] = nil
    }

    func markSourceUnavailable(itemID: UUID) {
        guard items.contains(where: { $0.id == itemID }) else {
            return
        }

        unavailableItemIDs.insert(itemID)
        itemErrorMessages[itemID] = Self.userFacingMessage(
            for: HighlightClipReviewMediaError.sourceUnavailable,
        )
    }

    func makeEditorViewModel(itemID: UUID) -> HighlightClipEditorViewModel? {
        guard let item = items.first(where: { $0.id == itemID }),
              let video = videos.first(where: { $0.id == item.videoID })
        else {
            return nil
        }
        editingItemID = itemID
        return HighlightClipEditorViewModel(
            item: item,
            video: video,
            confirmWorkingCopy: { [weak self] workingItem in
                guard let self else {
                    throw CancellationError()
                }
                return try await self.confirmWorkingCopy(workingItem)
            },
        )
    }

    func closeEditor() {
        editingItemID = nil
    }

    private func confirmWorkingCopy(
        _ workingItem: HighlightClipReviewItem,
    ) async throws -> HighlightClipConfirmationNavigation {
        do {
            guard let index = items.firstIndex(where: { $0.id == workingItem.id }) else {
                throw HighlightClipReviewPlanningError.missingMarkers
            }
            let currentItem = items[index]
            guard currentItem.videoID == workingItem.videoID,
                  currentItem.markerReferences == workingItem.markerReferences,
                  currentItem.defaultStart == workingItem.defaultStart,
                  currentItem.defaultDuration == workingItem.defaultDuration
            else {
                throw HighlightClipReviewPlanningError.inconsistentNumbering
            }
            guard let video = videos.first(where: { $0.id == currentItem.videoID }) else {
                throw HighlightClipReviewPlanningError.sourceVideoMissing
            }

            let normalizedStart = HighlightClipReviewPlanner.normalizedTenths(
                workingItem.start,
            )
            let normalizedEnd = HighlightClipReviewPlanner.normalizedTenths(
                workingItem.range.end,
            )
            let normalizedDuration = HighlightClipReviewPlanner.normalizedTenths(
                normalizedEnd - normalizedStart,
            )
            _ = try HighlightClipReviewPlanner.validatedRange(
                HighlightClipRange(
                    start: normalizedStart,
                    duration: normalizedDuration,
                ),
                videoDuration: video.duration,
            )

            var candidate = currentItem
            candidate.start = normalizedStart
            candidate.duration = normalizedDuration
            candidate.isIncluded = workingItem.isIncluded

            var sourceValidationSucceeded = false
            if candidate.isIncluded {
                try await mediaProvider.validateSourceAvailability(for: video)
                sourceValidationSucceeded = true
            }

            if let persistConfirmation {
                try await persistConfirmation(candidate)
            } else if let combinationKey, let reviewStore {
                let videoIdentity = try HighlightClipReviewIdentityBuilder.videoIdentity(for: video)
                let confirmationDate = now()
                let confirmation = PersistedHighlightClipConfirmation(
                    videoIdentity: videoIdentity,
                    markerIDs: currentItem.markerReferences.map(\.id),
                    defaultStart: currentItem.defaultStart,
                    defaultDuration: currentItem.defaultDuration,
                    start: candidate.start,
                    duration: candidate.duration,
                    isIncluded: candidate.isIncluded,
                    confirmedAt: confirmationDate,
                )
                try await reviewStore.upsert(
                    confirmation,
                    for: combinationKey,
                    now: confirmationDate,
                )

            } else {
                throw HighlightTaskError.persistence
            }

            candidate.confirmationState = .confirmed
            items[index] = candidate
            if sourceValidationSucceeded {
                unavailableItemIDs.remove(candidate.id)
                itemErrorMessages[candidate.id] = nil
            }
            refreshSummary()
            scheduleThumbnailRefreshIfNeeded(itemID: candidate.id)

            if let nextItem = items.dropFirst(index + 1).first(where: {
                $0.confirmationState == .defaultValue
            }) {
                editingItemID = nextItem.id
                return .open(itemID: nextItem.id)
            }

            editingItemID = nil
            return .returnToReview
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw HighlightClipReviewConfirmationFailure(
                message: Self.confirmationMessage(for: error),
            )
        }
    }

    func confirmedSegments() throws -> [ConfirmedHighlightSegment] {
        let displayedSegments = summary.finalSegments
        _ = try HighlightClipReviewPlanner.validateConfirmedSegments(
            displayedSegments,
            videos: videos,
            validMarkerIDs: Set(items.flatMap(\.markerReferences).map(\.id)),
        )
        return displayedSegments
    }

    func submit() async {
        guard canConfirm, !isSubmitting else {
            return
        }

        isSubmitting = true
        submissionErrorMessage = nil
        defer {
            isSubmitting = false
        }

        do {
            try await validateIncludedSources()
        } catch is CancellationError {
            return
        } catch {
            submissionErrorMessage = Self.userFacingMessage(for: error)
            return
        }

        let segments: [ConfirmedHighlightSegment]
        do {
            segments = try confirmedSegments()
        } catch {
            planningErrorMessage = Self.userFacingMessage(for: error)
            return
        }

        do {
            try await submitSegments(segments)
            onSubmissionSucceeded()
        } catch {
            submissionErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    func requiresInvalidation(
        videos: [SelectedTrainingVideo],
        clipSettings: ClipSettings,
    ) -> Bool {
        Self.makeFingerprint(videos: videos, clipSettings: clipSettings) != inputFingerprint
    }

    func cancelMediaLoading() {
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        filmstripTasks.values.forEach { $0.cancel() }
        filmstripTasks.removeAll()
        filmstripRequestIDs.removeAll()
        filmstripLoadingItemIDs.removeAll()
        mediaProvider.removeAllCachedResources()
        thumbnailStates.removeAll()
        thumbnailTargetSizes.removeAll()
        thumbnailRecency.removeAll()
        filmstripFramesByItemID.removeAll()
        filmstripWindowsByItemID.removeAll()
        unavailableItemIDs.removeAll()
        itemErrorMessages.removeAll()
        editingItemID = nil
    }

    private func refreshSummary() {
        do {
            summary = try HighlightClipReviewPlanner.makeSummary(items: items, videos: videos)
            planningErrorMessage = nil
        } catch {
            planningErrorMessage = Self.userFacingMessage(for: error)
        }
    }

    private func scheduleThumbnailRefreshIfNeeded(itemID: UUID) {
        guard let targetSize = thumbnailTargetSizes[itemID] else {
            return
        }

        _ = startThumbnailLoad(itemID: itemID, targetSize: targetSize)
    }

    @discardableResult
    private func startThumbnailLoad(
        itemID: UUID,
        targetSize: CGSize,
    ) -> Task<Void, Never>? {
        guard let item = items.first(where: { $0.id == itemID }),
              let video = videos.first(where: { $0.id == item.videoID })
        else {
            return nil
        }

        thumbnailTasks[itemID]?.cancel()
        thumbnailTargetSizes[itemID] = targetSize
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await performThumbnailLoad(
                item: item,
                video: video,
                targetSize: targetSize,
            )
        }
        thumbnailTasks[itemID] = task
        return task
    }

    private func performThumbnailLoad(
        item: HighlightClipReviewItem,
        video: SelectedTrainingVideo,
        targetSize: CGSize,
    ) async {
        let previousData: Data?
        if case .loaded(let data) = thumbnailStates[item.id] {
            previousData = data
        } else {
            previousData = nil
            thumbnailStates[item.id] = .loading
        }

        do {
            let data = try await mediaProvider.thumbnailData(
                for: item,
                video: video,
                targetSize: targetSize,
            )
            try Task.checkCancellation()
            thumbnailStates[item.id] = .loaded(data)
            thumbnailRecency.removeAll { $0 == item.id }
            thumbnailRecency.append(item.id)
            while thumbnailRecency.count > 64 {
                thumbnailStates[thumbnailRecency.removeFirst()] = .idle
            }
            if unavailableItemIDs.remove(item.id) != nil {
                itemErrorMessages[item.id] = nil
            }
        } catch is CancellationError {
            return
        } catch let error as HighlightClipReviewMediaError {
            if error == .sourceUnavailable {
                unavailableItemIDs.insert(item.id)
                itemErrorMessages[item.id] = Self.userFacingMessage(for: error)
            }
            if let previousData {
                thumbnailStates[item.id] = .loaded(previousData)
            } else {
                thumbnailStates[item.id] = .placeholder
            }
        } catch {
            if let previousData {
                thumbnailStates[item.id] = .loaded(previousData)
            } else {
                thumbnailStates[item.id] = .placeholder
            }
        }
    }

    private func performFilmstripLoad(
        itemID: UUID,
        video: SelectedTrainingVideo,
        window: HighlightClipTimelineWindow,
        count: Int,
        targetSize: CGSize,
        requestID: UUID,
    ) async {
        defer {
            if filmstripRequestIDs[itemID] == requestID {
                filmstripTasks[itemID] = nil
                filmstripRequestIDs[itemID] = nil
                filmstripLoadingItemIDs.remove(itemID)
            }
        }

        do {
            let frames = try await mediaProvider.filmstripFrames(
                for: video,
                timeRange: HighlightClipRange(
                    start: window.start,
                    duration: window.duration,
                ),
                count: count,
                targetSize: targetSize,
            )
            try Task.checkCancellation()
            guard filmstripRequestIDs[itemID] == requestID else {
                return
            }
            filmstripFramesByItemID[itemID] = frames
            filmstripWindowsByItemID[itemID] = window
            if unavailableItemIDs.remove(itemID) != nil {
                itemErrorMessages[itemID] = nil
            }
        } catch is CancellationError {
            return
        } catch let error as HighlightClipReviewMediaError {
            guard filmstripRequestIDs[itemID] == requestID else {
                return
            }
            if error == .sourceUnavailable {
                unavailableItemIDs.insert(itemID)
                itemErrorMessages[itemID] = Self.userFacingMessage(for: error)
            }
        } catch {
            return
        }
    }

    private func validateIncludedSources() async throws {
        let includedVideoIDs = Set(items.filter(\.isIncluded).map(\.videoID))
        for video in videos where includedVideoIDs.contains(video.id) {
            do {
                try await mediaProvider.validateSourceAvailability(for: video)
            } catch {
                if let mediaError = error as? HighlightClipReviewMediaError,
                   mediaError == .sourceUnavailable
                {
                    markSourceUnavailable(videoID: video.id)
                }
                throw error
            }
        }
    }

    private func markSourceUnavailable(videoID: String) {
        for item in items where item.videoID == videoID {
            markSourceUnavailable(itemID: item.id)
        }
    }

    private static func makeFingerprint(
        videos: [SelectedTrainingVideo],
        clipSettings: ClipSettings,
    ) -> HighlightClipReviewInputFingerprint {
        HighlightClipReviewInputFingerprint(
            videos: videos,
            clipSettings: clipSettings,
        )
    }

    private static func confirmationMessage(for error: Error) -> String {
        if error is HighlightClipReviewIdentityError
            || error is HighlightClipReviewPlanningError
            || error is HighlightClipReviewMediaError
            || error is HighlightClipReviewStoreError
            || error is HighlightTaskError
        {
            return userFacingMessage(for: error)
        }
        return "无法保存片段确认，请重试。"
    }

    private static func userFacingMessage(for error: Error) -> String {
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription
        {
            return description
        }

        return error.localizedDescription
    }
}

private nonisolated struct HighlightClipReviewConfirmationFailure: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
