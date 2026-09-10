import SwiftUI

struct HighlightTaskRow: View {
    let task: HighlightTask
    @ObservedObject var manager: HighlightTaskManager
    let onEdit: () -> Void
    let onPlay: () -> Void
    @State private var confirmingDelete = false
    @State private var operationError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if task.activeExecution != nil {
                summary
                if let progress = task.activeExecution?.progress.fractionCompleted {
                    ProgressView(value: progress).accessibilityLabel("生成进度")
                } else { ProgressView().accessibilityLabel(task.state.title) }
                Button("停止") { perform { try await manager.stop(taskID: task.id) } }
                    .frame(minHeight: 44).accessibilityIdentifier("highlight-task-stop")
            } else {
                Button(action: onEdit) { summary }
                    .buttonStyle(.plain)
                    .accessibilityHint("进入任务配置")
                    .accessibilityIdentifier("highlight-task-edit")
                if let code = task.lastGenerationResult?.errorCode, task.state == .failed {
                    Text(code.message).font(.footnote).foregroundStyle(.secondary)
                }
                if let code = task.currentOutput?.photoLibrarySaveErrorCode {
                    Text(code.message).font(.footnote).foregroundStyle(.secondary)
                } else if task.currentOutput?.photoLibrarySavedAt != nil {
                    Text("已保存到相册").font(.footnote).foregroundStyle(.secondary)
                }
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading) { actions }
                }
                .buttonStyle(.bordered)
                .disabled(manager.photoSavingTaskIDs.contains(task.id))
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .alert("删除任务？", isPresented: $confirmingDelete) {
            Button("取消", role: .cancel) {}
            Button("删除任务", role: .destructive) { perform { try await manager.delete(taskID: task.id) } }
        } message: { Text("将删除任务、导入的视频副本和 App 内成片。训练记录、系统相册和已导出的文件保持不变。") }
        .alert("操作未完成", isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(operationError ?? "") }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(task.trainingSnapshot.startedAt.formatted(.dateTime.month().day().hour().minute()))
                .font(.headline)
            Text("创建于 \(task.createdAt.formatted(.dateTime.month().day().hour().minute().second())) · \(task.videos.count) 个视频")
                .font(.caption).foregroundStyle(.secondary)
            Text(task.state.title).font(.subheadline.weight(.semibold))
            if task.outputIsOutdated { Text("当前成片不包含最新修改").font(.footnote).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(HighlightTaskRowViewData(task: task).accessibilityLabel)
    }

    @ViewBuilder
    private var actions: some View {
        if task.allowedActions.contains(.play) {
            Button("播放", action: onPlay).frame(minHeight: 44)
            Button(manager.photoSavingTaskIDs.contains(task.id) ? "保存中…" : "保存相册") {
                perform { try await manager.saveToPhotoLibrary(taskID: task.id) }
            }.frame(minHeight: 44)
        }
        if task.canRegenerateDirectly {
            Button("重新生成") { perform { try await manager.restart(taskID: task.id) } }.frame(minHeight: 44)
        }
        Button("删除", role: .destructive) { confirmingDelete = true }.frame(minHeight: 44)
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task { do { try await operation() } catch { operationError = error.localizedDescription } }
    }
}

struct HighlightTaskRowViewData {
    let task: HighlightTask
    var accessibilityLabel: String {
        var text = "训练 \(task.trainingSnapshot.startedAt.formatted(date: .abbreviated, time: .shortened))，任务创建于 \(task.createdAt.formatted(.dateTime.month().day().hour().minute().second()))，\(task.videos.count) 个视频，\(task.state.title)"
        if task.outputIsOutdated { text += "，当前成片不包含最新修改" }
        if task.activeExecution != nil { text += "，唯一可用操作：停止" }
        return text
    }
}
