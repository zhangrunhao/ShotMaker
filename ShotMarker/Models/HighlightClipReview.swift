import Foundation

struct HighlightClipRange: Equatable {
    let start: TimeInterval
    let duration: TimeInterval

    var end: TimeInterval { start + duration }
}

struct HighlightClipMarkerReference: Identifiable, Equatable {
    let id: UUID
    let markedAt: Date
    let timeInVideo: TimeInterval
    let originalMatchedNumber: Int
}

nonisolated enum HighlightClipConfirmationState: String, Codable, Equatable, Sendable {
    case defaultValue
    case confirmed
}

struct HighlightClipReviewItem: Identifiable, Equatable {
    let id: UUID
    let videoID: String
    let markerReferences: [HighlightClipMarkerReference]
    let defaultStart: TimeInterval
    let defaultDuration: TimeInterval
    var start: TimeInterval
    var duration: TimeInterval
    var isIncluded: Bool
    var confirmationState: HighlightClipConfirmationState

    init(
        id: UUID,
        videoID: String,
        markerReferences: [HighlightClipMarkerReference],
        defaultStart: TimeInterval,
        defaultDuration: TimeInterval,
        start: TimeInterval,
        duration: TimeInterval,
        isIncluded: Bool,
        confirmationState: HighlightClipConfirmationState = .defaultValue,
    ) {
        self.id = id
        self.videoID = videoID
        self.markerReferences = markerReferences
        self.defaultStart = defaultStart
        self.defaultDuration = defaultDuration
        self.start = start
        self.duration = duration
        self.isIncluded = isIncluded
        self.confirmationState = confirmationState
    }

    var range: HighlightClipRange {
        HighlightClipRange(start: start, duration: duration)
    }

    var defaultRange: HighlightClipRange {
        HighlightClipRange(start: defaultStart, duration: defaultDuration)
    }

    var originalNumberRange: ClosedRange<Int>? {
        guard let first = markerReferences.first,
              let last = markerReferences.last
        else {
            return nil
        }

        return first.originalMatchedNumber ... last.originalMatchedNumber
    }
}

nonisolated struct ConfirmedHighlightSegment: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let videoID: String
    let markerIDs: [UUID]
    let start: TimeInterval
    let duration: TimeInterval
    let markerNumberLowerBound: Int
    let markerNumberUpperBound: Int
    let markerTotalCount: Int
}

struct HighlightClipReviewDraft: Equatable {
    let selectedVideoCount: Int
    let totalMarkerCount: Int
    var items: [HighlightClipReviewItem]

    var matchedMarkerCount: Int {
        items.reduce(0) { $0 + $1.markerReferences.count }
    }

    var unmatchedMarkerCount: Int {
        totalMarkerCount - matchedMarkerCount
    }
}

struct HighlightClipReviewRestorationResult: Equatable {
    let draft: HighlightClipReviewDraft
    let discardedConfirmationCount: Int
}

struct HighlightClipReviewSummary: Equatable {
    let includedMarkerCount: Int
    let excludedMarkerCount: Int
    let finalSegments: [ConfirmedHighlightSegment]
    let displayNumberRangesByItemID: [UUID: ClosedRange<Int>]
    let mergingItemIDs: Set<UUID>

    var finalSegmentCount: Int {
        finalSegments.count
    }

    var totalDuration: TimeInterval {
        finalSegments.reduce(0) { $0 + $1.duration }
    }
}

enum HighlightClipRangeEdit: Equatable {
    case setStart(TimeInterval)
    case setEnd(TimeInterval)
    case moveBy(TimeInterval)
    case replace(start: TimeInterval, duration: TimeInterval)
}

struct HighlightClipReviewInputFingerprint: Equatable {
    let videos: [SelectedTrainingVideo]
    let secondsBeforeMarker: TimeInterval
    let secondsAfterMarker: TimeInterval

    init(videos: [SelectedTrainingVideo], clipSettings: ClipSettings) {
        let normalizedSettings = clipSettings.normalized
        self.videos = videos
        secondsBeforeMarker = normalizedSettings.secondsBeforeMarker
        secondsAfterMarker = normalizedSettings.secondsAfterMarker
    }
}

struct HighlightClipReviewPreparationSnapshot: Equatable {
    let inputFingerprint: HighlightClipReviewInputFingerprint
    let revision: UUID

    init(
        videos: [SelectedTrainingVideo],
        clipSettings: ClipSettings,
        revision: UUID,
    ) {
        inputFingerprint = HighlightClipReviewInputFingerprint(
            videos: videos,
            clipSettings: clipSettings,
        )
        self.revision = revision
    }

    func matches(
        videos: [SelectedTrainingVideo],
        clipSettings: ClipSettings,
        revision: UUID,
    ) -> Bool {
        self.revision == revision
            && inputFingerprint == HighlightClipReviewInputFingerprint(
                videos: videos,
                clipSettings: clipSettings,
            )
    }
}
