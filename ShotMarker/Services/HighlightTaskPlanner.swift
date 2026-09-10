import Foundation

struct HighlightTaskReconciliation {
    let items: [PersistedHighlightTaskClip]
    let resetConfirmationCount: Int
}

enum HighlightTaskPlanner {
    static func makeTask(id: UUID, session: TrainingSession, videos: [HighlightTaskVideo],
        settings: ClipSettings, now: Date = Date()) throws -> HighlightTask {
        let orderedEvents = session.events.sorted {
            let lhs = HighlightClipReviewIdentityBuilder.milliseconds($0.markedAt)
            let rhs = HighlightClipReviewIdentityBuilder.milliseconds($1.markedAt)
            return lhs == rhs ? $0.id.uuidString < $1.id.uuidString : lhs < rhs
        }
        let snapshot = HighlightTaskTrainingSnapshot(startedAt: normalizedDate(session.startedAt),
            endedAt: normalizedDate(session.endedAt), markers: orderedEvents.enumerated().map { order, event in
                HighlightTaskMarkerSnapshot(id: UUID(), markedAt: normalizedDate(event.markedAt), sourceOrder: order)
            })
        let items = try defaultItems(snapshot: snapshot, videos: videos, settings: settings)
        let task = HighlightTask(id: id, trainingSnapshot: snapshot, videos: videos,
            clipSettings: settings.normalized, reviewItems: items, createdAt: now, updatedAt: now)
        try HighlightTaskValidation.validate(task)
        return task
    }

    static func reconcile(task: HighlightTask, videos: [HighlightTaskVideo], settings: ClipSettings,
        resetAll: Bool = false) throws -> HighlightTaskReconciliation {
        let videoChanged = videos != task.videos
        let durationChanged = settings.secondsBeforeMarker != task.clipSettings.secondsBeforeMarker
            || settings.secondsAfterMarker != task.clipSettings.secondsAfterMarker
        if !resetAll && !videoChanged && !durationChanged {
            return HighlightTaskReconciliation(items: task.reviewItems, resetConfirmationCount: 0)
        }
        let defaults = try defaultItems(snapshot: task.trainingSnapshot, videos: videos, settings: settings)
        if resetAll {
            return HighlightTaskReconciliation(items: defaults,
                resetConfirmationCount: task.reviewItems.filter { $0.confirmationState == .confirmed }.count)
        }

        var kept: [PersistedHighlightTaskClip] = []
        var occupied = Set<UUID>()
        var resetCount = 0
        for confirmation in task.reviewItems where confirmation.confirmationState == .confirmed {
            guard let oldVideo = task.videos.first(where: { $0.id == confirmation.videoID }),
                  let video = videos.first(where: { $0.sourceIdentity == oldVideo.sourceIdentity }),
                  video.recordedStartAt == oldVideo.recordedStartAt, video.duration == oldVideo.duration,
                  HighlightTaskValidation.validRange(confirmation.start, confirmation.duration, video.duration),
                  !videoChanged || defaults.contains(where: {
                      $0.videoID == video.id && Set($0.markerIDs) == Set(confirmation.markerIDs)
                  })
            else { resetCount += 1; continue }
            let group = Set(confirmation.markerIDs)
            let partial = HighlightTaskTrainingSnapshot(startedAt: task.trainingSnapshot.startedAt,
                endedAt: task.trainingSnapshot.endedAt, markers: task.trainingSnapshot.markers.filter { group.contains($0.id) })
            let baseline = try defaultItems(snapshot: partial, videos: videos, settings: settings)
            guard baseline.flatMap(\.markerIDs).count == confirmation.markerIDs.count,
                  baseline.allSatisfy({ $0.videoID == video.id }),
                  let start = baseline.map(\.start).min(), let end = baseline.map({ $0.start + $0.duration }).max()
            else { resetCount += 1; continue }
            kept.append(PersistedHighlightTaskClip(id: confirmation.id, videoID: video.id,
                markerIDs: confirmation.markerIDs, defaultStart: start, defaultDuration: normalized(end - start),
                start: confirmation.start, duration: confirmation.duration, isIncluded: confirmation.isIncluded,
                confirmationState: .confirmed))
            occupied.formUnion(group)
        }

        // Confirmed groups (including exclusions) break the default merge chain.
        let ordered = orderedMarkers(task.trainingSnapshot)
        var runs: [[HighlightTaskMarkerSnapshot]] = [[]]
        for marker in ordered {
            if occupied.contains(marker.id) {
                if !(runs.last?.isEmpty ?? true) { runs.append([]) }
            } else { runs[runs.count - 1].append(marker) }
        }
        let remaining = try runs.filter { !$0.isEmpty }.flatMap { markers in
            try defaultItems(snapshot: HighlightTaskTrainingSnapshot(startedAt: task.trainingSnapshot.startedAt,
                endedAt: task.trainingSnapshot.endedAt, markers: markers), videos: videos, settings: settings)
        }
        let order = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.id, $0) })
        let items = (kept + remaining).sorted { (order[$0.markerIDs[0]] ?? .max) < (order[$1.markerIDs[0]] ?? .max) }
        var candidate = task
        candidate.videos = videos
        candidate.clipSettings = settings.normalized
        candidate.reviewItems = items
        try HighlightTaskValidation.validate(candidate)
        return HighlightTaskReconciliation(items: items, resetConfirmationCount: resetCount)
    }

    static func reviewDraft(for task: HighlightTask) throws -> HighlightClipReviewDraft {
        try HighlightTaskValidation.validate(task)
        let occupied = Set(task.reviewItems.flatMap(\.markerIDs))
        let markers = orderedMarkers(task.trainingSnapshot).filter { occupied.contains($0.id) }
        let references = Dictionary(uniqueKeysWithValues: markers.enumerated().map { ($1.id, ($1, $0 + 1)) })
        let items = try task.reviewItems.map { item -> HighlightClipReviewItem in
            guard let video = task.videos.first(where: { $0.id == item.videoID }) else { throw HighlightTaskError.invalidTask }
            return HighlightClipReviewItem(id: item.id, videoID: video.id.uuidString,
                markerReferences: try item.markerIDs.map { id in
                    guard let (marker, number) = references[id] else { throw HighlightTaskError.invalidTask }
                    return HighlightClipMarkerReference(id: id, markedAt: marker.markedAt,
                        timeInVideo: marker.markedAt.timeIntervalSince(video.recordedStartAt), originalMatchedNumber: number)
                }, defaultStart: item.defaultStart, defaultDuration: item.defaultDuration,
                start: item.start, duration: item.duration, isIncluded: item.isIncluded, confirmationState: item.confirmationState)
        }
        return HighlightClipReviewDraft(selectedVideoCount: task.videos.count,
            totalMarkerCount: task.trainingSnapshot.markers.count, items: items)
    }

    static func execution(for task: HighlightTask, now: Date = Date()) throws -> HighlightRenderExecution {
        let draft = try reviewDraft(for: task)
        let videos = task.videos.map(\.selectedTrainingVideo)
        let summary = try HighlightClipReviewPlanner.makeSummary(items: draft.items, videos: videos)
        let segments = try HighlightClipReviewPlanner.validateConfirmedSegments(summary.finalSegments,
            videos: videos, validMarkerIDs: Set(task.trainingSnapshot.markers.map(\.id)))
        return HighlightRenderExecution(id: UUID(), configurationRevision: task.configurationRevision,
            snapshot: HighlightRenderSnapshot(trainingSnapshot: task.trainingSnapshot, videos: task.videos,
                clipSettings: task.clipSettings.normalized, segments: segments), createdAt: now, updatedAt: now)
    }

    static func persisted(_ item: HighlightClipReviewItem) throws -> PersistedHighlightTaskClip {
        guard let videoID = UUID(uuidString: item.videoID) else { throw HighlightTaskError.invalidTask }
        return PersistedHighlightTaskClip(id: item.id, videoID: videoID, markerIDs: item.markerReferences.map(\.id),
            defaultStart: item.defaultStart, defaultDuration: item.defaultDuration, start: item.start,
            duration: item.duration, isIncluded: item.isIncluded, confirmationState: item.confirmationState)
    }

    private static func defaultItems(snapshot: HighlightTaskTrainingSnapshot, videos: [HighlightTaskVideo],
        settings: ClipSettings) throws -> [PersistedHighlightTaskClip] {
        guard (1...20).contains(videos.count), Set(videos.map(\.id)).count == videos.count,
              Set(videos.map(\.sourceIdentity)).count == videos.count,
              videos.allSatisfy({ $0.duration.isFinite && $0.duration > 0 }) else { throw HighlightTaskError.invalidTask }
        let draft = HighlightClipReviewPlanner.makeDraft(for: snapshot.planningSession,
            videos: videos.map(\.selectedTrainingVideo), clipSettings: settings.normalized,
            markerOrder: Dictionary(uniqueKeysWithValues: snapshot.markers.map { ($0.id, $0.sourceOrder) }))
        return try draft.items.map { item in
            guard let video = videos.first(where: { $0.id.uuidString == item.videoID }) else { throw HighlightTaskError.invalidTask }
            let start = min(max(normalized(item.start), 0), max(0, video.duration - min(1, video.duration)))
            let end = min(max(normalized(item.start + item.duration), start + min(1, video.duration)), video.duration)
            return PersistedHighlightTaskClip(id: item.id, videoID: video.id, markerIDs: item.markerReferences.map(\.id),
                defaultStart: start, defaultDuration: end - start, start: start, duration: end - start,
                isIncluded: true, confirmationState: .defaultValue)
        }
    }

    private static func orderedMarkers(_ snapshot: HighlightTaskTrainingSnapshot) -> [HighlightTaskMarkerSnapshot] {
        snapshot.markers.sorted { $0.markedAt == $1.markedAt ? $0.sourceOrder < $1.sourceOrder : $0.markedAt < $1.markedAt }
    }

    private static func normalized(_ time: Double) -> Double { HighlightClipReviewPlanner.normalizedTenths(time) }
    private static func normalizedDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: Double(HighlightClipReviewIdentityBuilder.milliseconds(date)) / 1_000)
    }
}

extension HighlightTaskVideo {
    @MainActor var selectedTrainingVideo: SelectedTrainingVideo {
        SelectedTrainingVideo(id: id.uuidString, recordedStartAt: recordedStartAt,
            duration: duration, reviewSourceIdentity: sourceIdentity)
    }
}

extension HighlightTaskTrainingSnapshot {
    /// Ephemeral adapter for pure planning and read-only UI; never a training-store key.
    @MainActor var planningSession: TrainingSession {
        TrainingSession(id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
            startedAt: startedAt, endedAt: endedAt,
            events: markers.map { ShotMarkerEvent(id: $0.id, markedAt: $0.markedAt) })
    }
}
