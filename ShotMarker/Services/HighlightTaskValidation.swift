import Foundation

nonisolated enum HighlightTaskValidation {
    static func validate(_ task: HighlightTask) throws {
        let markers = task.trainingSnapshot.markers
        guard task.configurationRevision > 0,
              task.trainingSnapshot.startedAt.timeIntervalSince1970.isFinite,
              task.trainingSnapshot.endedAt >= task.trainingSnapshot.startedAt,
              Set(markers.map(\.id)).count == markers.count,
              markers.map(\.sourceOrder).sorted() == Array(0..<markers.count),
              markers.allSatisfy({ $0.markedAt.timeIntervalSince1970.isFinite }),
              (1...20).contains(task.videos.count),
              Set(task.videos.map(\.id)).count == task.videos.count,
              Set(task.videos.map(\.sourceIdentity)).count == task.videos.count,
              (0...20).contains(task.clipSettings.secondsBeforeMarker),
              (1...20).contains(task.clipSettings.secondsAfterMarker), !task.reviewItems.isEmpty
        else { throw HighlightTaskError.invalidTask }
        for video in task.videos {
            guard video.duration.isFinite, video.duration > 0, video.recordedStartAt.timeIntervalSince1970.isFinite,
                  !video.sourceIdentity.value.isEmpty else { throw HighlightTaskError.invalidTask }
            switch video.source {
            case .photoLibraryAsset(let identifier):
                guard video.sourceIdentity == .photoLibraryAsset(identifier) else { throw HighlightTaskError.invalidTask }
            case .taskInputFile(let path):
                guard video.sourceIdentity.kind == .fileSHA256,
                      path.hasPrefix("HighlightTasks/\(task.id)/Inputs/\(video.id)."), isSafePath(path)
                else { throw HighlightTaskError.invalidPath }
            }
        }
        let videos = Dictionary(uniqueKeysWithValues: task.videos.map { ($0.id, $0) })
        let validMarkers = Set(markers.map(\.id))
        var occupied = Set<UUID>()
        var itemIDs = Set<UUID>()
        for item in task.reviewItems {
            guard itemIDs.insert(item.id).inserted, let video = videos[item.videoID], !item.markerIDs.isEmpty,
                  Set(item.markerIDs).isSubset(of: validMarkers) else { throw HighlightTaskError.invalidTask }
            for marker in item.markerIDs {
                guard occupied.insert(marker).inserted else { throw HighlightTaskError.invalidTask }
            }
            guard validRange(item.start, item.duration, video.duration), validRange(item.defaultStart, item.defaultDuration, video.duration)
            else { throw HighlightTaskError.invalidTask }
        }
        if let output = task.currentOutput {
            guard (1...task.configurationRevision).contains(output.configurationRevision),
                  output.relativePath == "HighlightTasks/\(task.id)/Outputs/\(output.id)/highlight.mov"
            else { throw HighlightTaskError.invalidPath }
        }
        if let result = task.lastGenerationResult {
            guard (1...task.configurationRevision).contains(result.configurationRevision),
                  (result.status == .failed) == (result.errorCode != nil) else { throw HighlightTaskError.invalidTask }
        }
        if let execution = task.activeExecution {
            guard execution.configurationRevision == task.configurationRevision,
                  execution.snapshot.trainingSnapshot == task.trainingSnapshot,
                  execution.snapshot.videos == task.videos, execution.snapshot.clipSettings == task.clipSettings,
                  !execution.snapshot.segments.isEmpty else { throw HighlightTaskError.invalidTask }
            var executionMarkers = Set<UUID>()
            let total = execution.snapshot.segments.reduce(0) { $0 + $1.markerIDs.count }
            for segment in execution.snapshot.segments {
                guard let videoID = UUID(uuidString: segment.videoID), let video = videos[videoID],
                      !segment.markerIDs.isEmpty, Set(segment.markerIDs).isSubset(of: validMarkers),
                      segment.markerNumberLowerBound == executionMarkers.count + 1,
                      segment.markerNumberUpperBound == executionMarkers.count + segment.markerIDs.count,
                      segment.markerTotalCount == total, validRange(segment.start, segment.duration, video.duration)
                else { throw HighlightTaskError.invalidTask }
                for id in segment.markerIDs {
                    guard executionMarkers.insert(id).inserted else { throw HighlightTaskError.invalidTask }
                }
            }
        }
    }

    static func validRange(_ start: Double, _ duration: Double, _ videoDuration: Double) -> Bool {
        guard start.isFinite, duration.isFinite, start >= 0, duration >= min(1, videoDuration),
              start + duration <= videoDuration + 0.000_000_1 else { return false }
        if videoDuration < 1 { return start == 0 && abs(duration - videoDuration) < 0.000_000_1 }
        return abs(start * 10 - (start * 10).rounded()) < 0.000_001
            && (abs(duration * 10 - (duration * 10).rounded()) < 0.000_001
                || abs(start + duration - videoDuration) < 0.000_000_1)
    }

    static func isSafePath(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
