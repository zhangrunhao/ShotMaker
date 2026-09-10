import Foundation

struct HighlightJob: Identifiable, Codable, Equatable {
    let id: UUID
    var trainingSession: TrainingSession
    var selectedVideos: [HighlightJobVideo]
    var clipSettings: ClipSettings
    var clipPlanVersion: Int? = nil
    var confirmedSegments: [ConfirmedHighlightSegment]? = nil
    var status: HighlightJobStatus
    var progress: HighlightJobProgress
    var outputVideoPath: String?
    var photoLibrarySavedAt: Date? = nil
    var photoLibrarySaveErrorMessage: String? = nil
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    var canCancel: Bool {
        status == .queued || status == .running || status == .saving
    }

    var canRestart: Bool {
        status == .failed || status == .interrupted
    }

    var canClear: Bool {
        status == .completed || status == .failed || status == .interrupted
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trainingSession
        case selectedVideos
        case clipSettings
        case clipPlanVersion
        case confirmedSegments
        case status
        case progress
        case outputVideoPath
        case photoLibrarySavedAt
        case photoLibrarySaveErrorMessage
        case errorMessage
        case createdAt
        case updatedAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(trainingSession, forKey: .trainingSession)
        try container.encode(selectedVideos, forKey: .selectedVideos)
        try container.encode(clipSettings, forKey: .clipSettings)
        try container.encodeIfPresent(clipPlanVersion, forKey: .clipPlanVersion)
        try container.encodeIfPresent(confirmedSegments, forKey: .confirmedSegments)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encode(outputVideoPath, forKey: .outputVideoPath)
        try container.encode(photoLibrarySavedAt, forKey: .photoLibrarySavedAt)
        try container.encode(photoLibrarySaveErrorMessage, forKey: .photoLibrarySaveErrorMessage)
        try container.encode(errorMessage, forKey: .errorMessage)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}

extension HighlightJob {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        trainingSession = try container.decode(TrainingSession.self, forKey: .trainingSession)
        selectedVideos = try container.decode([HighlightJobVideo].self, forKey: .selectedVideos)
        clipSettings = try container.decode(ClipSettings.self, forKey: .clipSettings)
        clipPlanVersion = try container.decodeIfPresent(Int.self, forKey: .clipPlanVersion)

        if !container.contains(.confirmedSegments) {
            confirmedSegments = nil
        } else if try container.decodeNil(forKey: .confirmedSegments) {
            confirmedSegments = nil
        } else {
            do {
                confirmedSegments = try container.decode(
                    [ConfirmedHighlightSegment].self,
                    forKey: .confirmedSegments,
                )
            } catch {
                confirmedSegments = []
            }
        }

        status = try container.decode(HighlightJobStatus.self, forKey: .status)
        progress = try container.decode(HighlightJobProgress.self, forKey: .progress)
        outputVideoPath = try container.decodeIfPresent(String.self, forKey: .outputVideoPath)
        photoLibrarySavedAt = try container.decodeIfPresent(Date.self, forKey: .photoLibrarySavedAt)
        photoLibrarySaveErrorMessage = try container.decodeIfPresent(
            String.self,
            forKey: .photoLibrarySaveErrorMessage,
        )
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct HighlightJobVideo: Identifiable, Codable, Equatable {
    let id: String
    let recordedStartAt: Date
    let duration: TimeInterval
    let source: HighlightJobVideoSource

    var selectedTrainingVideo: SelectedTrainingVideo {
        SelectedTrainingVideo(id: id, recordedStartAt: recordedStartAt, duration: duration)
    }
}

enum HighlightJobVideoSource: Codable, Equatable {
    case photoLibraryAsset(localIdentifier: String)
    case jobInputFile(relativePath: String)
}

enum HighlightJobStatus: String, Codable, Equatable {
    case queued
    case running
    case saving
    case completed
    case failed
    case interrupted

    var isLaunchInterruptedState: Bool {
        self == .queued || self == .running || self == .saving
    }
}

nonisolated struct HighlightJobProgress: Codable, Equatable, Sendable {
    var completedMarkerCount: Int
    var totalMarkerCount: Int

    static let zero = HighlightJobProgress(completedMarkerCount: 0, totalMarkerCount: 0)

    var fractionCompleted: Double? {
        guard totalMarkerCount > 0 else {
            return nil
        }

        return min(max(Double(completedMarkerCount) / Double(totalMarkerCount), 0), 1)
    }
}
