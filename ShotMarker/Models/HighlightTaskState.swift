import Foundation

nonisolated enum HighlightTaskState: String, Sendable {
    case reviewing, queued, running, stopped, failed, completed, modified
    var title: String {
        switch self {
        case .reviewing: "审核中"
        case .queued: "排队中"
        case .running: "生成中"
        case .stopped: "已停止"
        case .failed: "生成失败"
        case .completed: "已完成"
        case .modified: "有未生成修改"
        }
    }
}

nonisolated enum HighlightTaskAction: Hashable { case stop, edit, review, regenerate, play, save, delete }

extension HighlightTask {
    nonisolated var state: HighlightTaskState {
        if let execution = activeExecution { return execution.status == .queued ? .queued : .running }
        if let result = lastGenerationResult, result.configurationRevision == configurationRevision {
            if result.status == .stopped { return .stopped }
            if result.status == .failed { return .failed }
        }
        if let output = currentOutput {
            return output.configurationRevision == configurationRevision ? .completed : .modified
        }
        return .reviewing
    }

    nonisolated var outputIsOutdated: Bool {
        currentOutput.map { $0.configurationRevision < configurationRevision } ?? false
    }

    nonisolated var canRegenerateDirectly: Bool {
        activeExecution == nil && [.stopped, .failed, .completed].contains(state)
    }

    nonisolated var allowedActions: Set<HighlightTaskAction> {
        guard activeExecution == nil else { return [.stop] }
        var actions: Set<HighlightTaskAction> = [.edit, .review, .delete]
        if canRegenerateDirectly { actions.insert(.regenerate) }
        if currentOutput != nil { actions.formUnion([.play, .save]) }
        return actions
    }
}
