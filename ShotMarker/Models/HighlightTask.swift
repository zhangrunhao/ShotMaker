import Foundation

nonisolated struct HighlightTaskStoreDocument: Codable, Equatable, Sendable {
    let schemaVersion: Int
    var tasks: [HighlightTask]
    static let empty = Self(schemaVersion: 1, tasks: [])
}

nonisolated struct HighlightTask: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let trainingSnapshot: HighlightTaskTrainingSnapshot
    var configurationRevision: Int = 1
    var videos: [HighlightTaskVideo]
    var clipSettings: ClipSettings
    var reviewItems: [PersistedHighlightTaskClip]
    var activeExecution: HighlightRenderExecution?
    var lastGenerationResult: HighlightTaskGenerationResult?
    var currentOutput: HighlightTaskOutput?
    let createdAt: Date
    var updatedAt: Date
}

nonisolated struct HighlightTaskTrainingSnapshot: Codable, Equatable, Sendable {
    let startedAt: Date
    let endedAt: Date
    let markers: [HighlightTaskMarkerSnapshot]
}

nonisolated struct HighlightTaskMarkerSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let markedAt: Date
    let sourceOrder: Int
}

nonisolated struct HighlightTaskVideo: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sourceIdentity: HighlightClipReviewSourceIdentity
    var recordedStartAt: Date
    var duration: TimeInterval
    var source: HighlightTaskVideoSource
}

nonisolated enum HighlightTaskVideoSource: Codable, Equatable, Sendable {
    case photoLibraryAsset(localIdentifier: String)
    case taskInputFile(relativePath: String)
}

nonisolated struct PersistedHighlightTaskClip: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let videoID: UUID
    let markerIDs: [UUID]
    var defaultStart: TimeInterval
    var defaultDuration: TimeInterval
    var start: TimeInterval
    var duration: TimeInterval
    var isIncluded: Bool
    var confirmationState: HighlightClipConfirmationState
}

nonisolated struct HighlightRenderSnapshot: Codable, Equatable, Sendable {
    let trainingSnapshot: HighlightTaskTrainingSnapshot
    let videos: [HighlightTaskVideo]
    let clipSettings: ClipSettings
    let segments: [ConfirmedHighlightSegment]
}

nonisolated struct HighlightRenderExecution: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let configurationRevision: Int
    let snapshot: HighlightRenderSnapshot
    var status: HighlightRenderExecutionStatus = .queued
    var progress: HighlightJobProgress = .zero
    let createdAt: Date
    var updatedAt: Date
}

nonisolated enum HighlightRenderExecutionStatus: String, Codable, Sendable { case queued, running }
nonisolated enum HighlightTaskGenerationResultStatus: String, Codable, Sendable { case stopped, failed, succeeded }

nonisolated struct HighlightTaskGenerationResult: Codable, Equatable, Sendable {
    let executionID: UUID
    let configurationRevision: Int
    let status: HighlightTaskGenerationResultStatus
    let finishedAt: Date
    let errorCode: HighlightTaskGenerationErrorCode?
}

nonisolated enum HighlightTaskGenerationErrorCode: String, Codable, Sendable {
    case sourceUnavailable, invalidConfiguration, exportFailed, outputCommitFailed
    var message: String {
        switch self {
        case .sourceUnavailable: "原视频不可用，请重新选择或替换视频。"
        case .invalidConfiguration: "片段数据无效，请重新进入审核。"
        case .exportFailed: "视频生成失败，请重试。"
        case .outputCommitFailed: "无法保存新成片，原有成片已保留。请重试。"
        }
    }
}

nonisolated enum HighlightTaskPhotoSaveErrorCode: String, Codable, Sendable {
    case sourceUnavailable, saveFailed
    var message: String {
        switch self {
        case .sourceUnavailable: "本地成片不可用，请重新生成。"
        case .saveFailed: "无法保存到相册，请检查照片权限后重试。"
        }
    }
}

nonisolated struct HighlightTaskOutput: Codable, Equatable, Sendable {
    let id: UUID
    let relativePath: String
    let configurationRevision: Int
    let generatedAt: Date
    var photoLibrarySavedAt: Date?
    var photoLibrarySaveErrorCode: HighlightTaskPhotoSaveErrorCode?
}

nonisolated enum HighlightTaskError: LocalizedError, Equatable {
    case notFound, revisionConflict, busy, invalidTask, unsupportedSchema, corruptDocument
    case persistence, missingFile, invalidPath, sourceUnavailable, photoSaveFailed, mustReview, background
    var errorDescription: String? {
        switch self {
        case .notFound: "找不到任务，请返回首页刷新。"
        case .revisionConflict: "任务内容已变化，请返回首页重新打开。当前调整尚未保存。"
        case .busy: "任务正在生成，请先停止。"
        case .invalidTask: "任务配置无效，请检查视频和片段后重试。"
        case .unsupportedSchema: "任务来自更新版本，请更新 App 后再打开。"
        case .corruptDocument: "无法加载任务。已保留损坏数据备份和任务文件，请恢复数据后重试。"
        case .persistence: "无法保存任务，请检查可用空间后重试。"
        case .missingFile: "本地视频文件不存在，请重新选择来源或重新生成。"
        case .invalidPath: "任务文件路径无效。"
        case .sourceUnavailable: "原视频不可用，请重新选择或替换视频。"
        case .photoSaveFailed: "无法保存到相册，请检查照片权限后重试。"
        case .mustReview: "任务已有修改，请进入审核后再生成。"
        case .background: "请返回前台后再生成视频。"
        }
    }
}
