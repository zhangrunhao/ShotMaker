import CoreMedia
import Foundation

enum HighlightClipReviewPlanner {
    static let exportTimescale: CMTimeScale = 600
    private static let tenthSecondTicks: CMTimeValue = 60
    static let mergeGapTolerance: TimeInterval = 1

    static func normalizedTenths(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds.isFinite else {
            return seconds
        }

        let time = CMTime(seconds: seconds, preferredTimescale: exportTimescale)
        let tenths = (Double(time.value) / Double(tenthSecondTicks))
            .rounded(.toNearestOrAwayFromZero)
        return CMTime(
            value: CMTimeValue(tenths) * tenthSecondTicks,
            timescale: exportTimescale,
        ).seconds
    }

    static func apply(
        _ edit: HighlightClipRangeEdit,
        to item: HighlightClipReviewItem,
        videoDuration: TimeInterval,
    ) throws -> HighlightClipReviewItem {
        guard videoDuration.isFinite, videoDuration > 0 else {
            throw HighlightClipReviewPlanningError.invalidRange
        }

        _ = try validatedRange(item.range, videoDuration: videoDuration)

        let editValues: [TimeInterval]
        switch edit {
        case .setStart(let start), .setEnd(let start), .moveBy(let start):
            editValues = [start]
        case .replace(let start, let duration):
            editValues = [start, duration]
        }
        guard editValues.allSatisfy(\.isFinite) else {
            throw HighlightClipReviewPlanningError.invalidRange
        }

        var editedItem = item
        guard videoDuration >= 1 else {
            editedItem.start = 0
            editedItem.duration = videoDuration
            return editedItem
        }

        let minimumDuration: TimeInterval = 1
        switch edit {
        case .setStart(let requestedStart):
            let end = item.range.end
            let start = min(
                max(normalizedTenths(requestedStart), 0),
                end - minimumDuration,
            )
            editedItem.start = start
            editedItem.duration = end - start
        case .setEnd(let requestedEnd):
            let end = min(
                max(normalizedTenths(requestedEnd), item.start + minimumDuration),
                videoDuration,
            )
            editedItem.duration = end - item.start
        case .moveBy(let requestedDelta):
            let delta = normalizedTenths(requestedDelta)
            let start = normalizedTenths(item.start + delta)
            editedItem.start = min(max(start, 0), videoDuration - item.duration)
        case .replace(let requestedStart, let requestedDuration):
            let duration = min(
                max(normalizedTenths(requestedDuration), minimumDuration),
                videoDuration,
            )
            let start = min(
                max(normalizedTenths(requestedStart), 0),
                videoDuration - duration,
            )
            editedItem.start = start
            editedItem.duration = duration
        }

        _ = try validatedRange(editedItem.range, videoDuration: videoDuration)
        return editedItem
    }

    static func makeDraft(
        for session: TrainingSession,
        videos: [SelectedTrainingVideo],
        clipSettings: ClipSettings,
        markerOrder: [UUID: Int]? = nil,
    ) -> HighlightClipReviewDraft {
        let legacyPlan = VideoClipSegmentPlanner.highlightPlan(
            for: session,
            videos: videos,
            clipSettings: clipSettings,
            markerOrder: markerOrder,
        )
        let eventsByID = session.events.reduce(into: [UUID: ShotMarkerEvent]()) { result, event in
            result[event.id] = event
        }
        let videosByID = videos.reduce(into: [String: SelectedTrainingVideo]()) { result, video in
            result[video.id] = video
        }
        let items = legacyPlan.segments.compactMap { segment -> HighlightClipReviewItem? in
            guard let video = videosByID[segment.videoID] else {
                return nil
            }

            let markerReferences = segment.markerIDs.enumerated().compactMap { index, markerID in
                eventsByID[markerID].map { event in
                    HighlightClipMarkerReference(
                        id: event.id,
                        markedAt: event.markedAt,
                        timeInVideo: event.markedAt.timeIntervalSince(video.recordedStartAt),
                        originalMatchedNumber: segment.markerNumberRange.lowerBound + index,
                    )
                }
            }
            guard markerReferences.count == segment.markerIDs.count,
                  let itemID = segment.markerIDs.first
            else {
                return nil
            }

            return HighlightClipReviewItem(
                id: itemID,
                videoID: segment.videoID,
                markerReferences: markerReferences,
                defaultStart: segment.start,
                defaultDuration: segment.duration,
                start: segment.start,
                duration: segment.duration,
                isIncluded: true,
                confirmationState: .defaultValue,
            )
        }

        return HighlightClipReviewDraft(
            selectedVideoCount: legacyPlan.selectedVideoCount,
            totalMarkerCount: legacyPlan.totalMarkerCount,
            items: items,
        )
    }

    static func makeSummary(
        items: [HighlightClipReviewItem],
        videos: [SelectedTrainingVideo],
    ) throws -> HighlightClipReviewSummary {
        let videoIDs = videos.map(\.id)
        guard Set(videoIDs).count == videoIDs.count else {
            throw HighlightClipReviewPlanningError.duplicateIdentity
        }
        let videosByID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })

        var itemIDs = Set<UUID>()
        var markerIDs = Set<UUID>()
        for item in items {
            guard itemIDs.insert(item.id).inserted else {
                throw HighlightClipReviewPlanningError.duplicateIdentity
            }
            guard videosByID[item.videoID] != nil else {
                throw HighlightClipReviewPlanningError.sourceVideoMissing
            }
            guard !item.markerReferences.isEmpty else {
                throw HighlightClipReviewPlanningError.missingMarkers
            }
            for reference in item.markerReferences {
                guard markerIDs.insert(reference.id).inserted else {
                    throw HighlightClipReviewPlanningError.duplicateIdentity
                }
            }
        }

        let includedMarkerCount = items
            .filter(\.isIncluded)
            .reduce(0) { $0 + $1.markerReferences.count }
        let excludedMarkerCount = items
            .filter { !$0.isIncluded }
            .reduce(0) { $0 + $1.markerReferences.count }

        var displayNumberRangesByItemID: [UUID: ClosedRange<Int>] = [:]
        var finalSegments: [ConfirmedHighlightSegment] = []
        var mergingItemIDs = Set<UUID>()
        var nextIncludedNumber = 1
        var previousOriginalItemWasIncluded = false
        var previousIncludedItemID: UUID?

        for item in items {
            guard let originalNumberRange = item.originalNumberRange else {
                throw HighlightClipReviewPlanningError.missingMarkers
            }
            guard originalNumberRange.count == item.markerReferences.count else {
                throw HighlightClipReviewPlanningError.inconsistentNumbering
            }

            guard item.isIncluded else {
                displayNumberRangesByItemID[item.id] = originalNumberRange
                previousOriginalItemWasIncluded = false
                previousIncludedItemID = nil
                continue
            }

            guard let video = videosByID[item.videoID] else {
                throw HighlightClipReviewPlanningError.sourceVideoMissing
            }
            let normalizedStart = video.duration < 1 ? 0 : normalizedTenths(item.start)
            let normalizedEnd = video.duration < 1 ? video.duration : min(normalizedTenths(item.range.end), video.duration)
            let normalizedRange = try validatedRange(
                HighlightClipRange(
                    start: normalizedStart,
                    duration: normalizedEnd - normalizedStart,
                ),
                videoDuration: video.duration,
            )
            let numberRange = nextIncludedNumber
                ... (nextIncludedNumber + item.markerReferences.count - 1)
            nextIncludedNumber = numberRange.upperBound + 1
            displayNumberRangesByItemID[item.id] = numberRange

            let segment = ConfirmedHighlightSegment(
                id: item.id,
                videoID: item.videoID,
                markerIDs: item.markerReferences.map(\.id),
                start: normalizedRange.start,
                duration: normalizedRange.duration,
                markerNumberLowerBound: numberRange.lowerBound,
                markerNumberUpperBound: numberRange.upperBound,
                markerTotalCount: includedMarkerCount,
            )

            if previousOriginalItemWasIncluded,
               let previousSegment = finalSegments.last,
               previousSegment.videoID == segment.videoID,
               gap(between: previousSegment, and: segment) <= mergeGapTolerance
            {
                let mergedStart = min(previousSegment.start, segment.start)
                let mergedEnd = max(
                    previousSegment.start + previousSegment.duration,
                    segment.start + segment.duration,
                )
                finalSegments[finalSegments.count - 1] = ConfirmedHighlightSegment(
                    id: previousSegment.id,
                    videoID: previousSegment.videoID,
                    markerIDs: previousSegment.markerIDs + segment.markerIDs,
                    start: mergedStart,
                    duration: mergedEnd - mergedStart,
                    markerNumberLowerBound: previousSegment.markerNumberLowerBound,
                    markerNumberUpperBound: segment.markerNumberUpperBound,
                    markerTotalCount: includedMarkerCount,
                )
                if let previousIncludedItemID {
                    mergingItemIDs.insert(previousIncludedItemID)
                }
                mergingItemIDs.insert(item.id)
            } else {
                finalSegments.append(segment)
            }

            previousOriginalItemWasIncluded = true
            previousIncludedItemID = item.id
        }

        return HighlightClipReviewSummary(
            includedMarkerCount: includedMarkerCount,
            excludedMarkerCount: excludedMarkerCount,
            finalSegments: finalSegments,
            displayNumberRangesByItemID: displayNumberRangesByItemID,
            mergingItemIDs: mergingItemIDs,
        )
    }

    static func validateConfirmedSegments(
        _ segments: [ConfirmedHighlightSegment],
        videos: [SelectedTrainingVideo],
        validMarkerIDs: Set<UUID>,
    ) throws -> [ConfirmedHighlightSegment] {
        guard !segments.isEmpty else {
            throw HighlightClipReviewPlanningError.emptySelection
        }

        let videoIDs = videos.map(\.id)
        guard Set(videoIDs).count == videoIDs.count else {
            throw HighlightClipReviewPlanningError.duplicateIdentity
        }
        let videosByID = Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0) })
        let allMarkerIDs = segments.flatMap(\.markerIDs)
        let uniqueMarkerIDs = Set(allMarkerIDs)
        guard uniqueMarkerIDs.count == allMarkerIDs.count else {
            throw HighlightClipReviewPlanningError.duplicateIdentity
        }
        guard uniqueMarkerIDs.isSubset(of: validMarkerIDs) else {
            throw HighlightClipReviewPlanningError.missingMarkers
        }

        var segmentIDs = Set<UUID>()
        var expectedLowerBound = 1
        for segment in segments {
            guard segmentIDs.insert(segment.id).inserted else {
                throw HighlightClipReviewPlanningError.duplicateIdentity
            }
            guard !segment.markerIDs.isEmpty else {
                throw HighlightClipReviewPlanningError.missingMarkers
            }
            guard let video = videosByID[segment.videoID] else {
                throw HighlightClipReviewPlanningError.sourceVideoMissing
            }
            let range = try validatedRange(
                HighlightClipRange(start: segment.start, duration: segment.duration),
                videoDuration: video.duration,
            )
            guard isNormalizedTenth(range.start),
                  isNormalizedTenth(range.duration) || abs(range.end - video.duration) < 0.000_000_1
            else {
                throw HighlightClipReviewPlanningError.invalidRange
            }

            let expectedUpperBound = expectedLowerBound + segment.markerIDs.count - 1
            guard segment.markerNumberLowerBound == expectedLowerBound,
                  segment.markerNumberUpperBound == expectedUpperBound,
                  segment.markerTotalCount == uniqueMarkerIDs.count
            else {
                throw HighlightClipReviewPlanningError.inconsistentNumbering
            }
            expectedLowerBound = expectedUpperBound + 1
        }

        return segments
    }

    static func validatedRange(
        _ range: HighlightClipRange,
        videoDuration: TimeInterval,
    ) throws -> HighlightClipRange {
        guard videoDuration.isFinite,
              videoDuration > 0,
              range.start.isFinite,
              range.duration.isFinite,
              range.start >= 0,
              range.duration > 0,
              range.end <= videoDuration,
              range.duration >= min(1, videoDuration)
        else {
            throw HighlightClipReviewPlanningError.invalidRange
        }

        return range
    }

    private static func gap(
        between lhs: ConfirmedHighlightSegment,
        and rhs: ConfirmedHighlightSegment,
    ) -> TimeInterval {
        max(
            0,
            max(lhs.start, rhs.start)
                - min(lhs.start + lhs.duration, rhs.start + rhs.duration),
        )
    }

    static func isNormalizedTenth(_ value: TimeInterval) -> Bool {
        abs(normalizedTenths(value) - value) < 0.000_000_1
    }
}

extension ConfirmedHighlightSegment {
    var highlightClipSegment: HighlightClipSegment {
        HighlightClipSegment(
            markerIDs: markerIDs,
            videoID: videoID,
            start: start,
            duration: duration,
            markerNumberRange: markerNumberLowerBound ... markerNumberUpperBound,
            markerTotalCount: markerTotalCount,
        )
    }
}

enum HighlightClipReviewPlanningError: LocalizedError, Equatable {
    case emptySelection
    case sourceVideoMissing
    case invalidRange
    case missingMarkers
    case inconsistentNumbering
    case duplicateIdentity

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            "至少需要保留一个可用片段。"
        case .sourceVideoMissing:
            "找不到片段使用的视频，请重新选择视频。"
        case .invalidRange:
            "片段范围无效，请恢复默认范围后再试。"
        case .missingMarkers:
            "片段缺少关联打点，请重新创建任务。"
        case .inconsistentNumbering:
            "片段编号数据无效，请重新创建任务。"
        case .duplicateIdentity:
            "片段数据重复，请重新创建任务。"
        }
    }
}
