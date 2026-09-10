import SwiftUI

struct HighlightTaskReviewView: View {
    @ObservedObject var session: HighlightReviewSession
    let onExit: () -> Void
    @State private var confirmingReset = false
    @State private var resetError: String?

    var body: some View {
        HighlightClipReviewView(viewModel: session.viewModel,
            makePlaybackController: session.makePlaybackController, generationButtonTitle: "生成视频",
            onRequestVideoReselection: exit)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if session.viewModel.editingItemID == nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("退出到首页", action: exit).disabled(session.viewModel.isSubmitting)
                        .accessibilityIdentifier("highlight-task-exit-review")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("重置全部片段") { confirmingReset = true }
                        .disabled(session.viewModel.isSubmitting)
                        .accessibilityIdentifier("highlight-task-reset-clips")
                }
            }
        }
        .alert("重置全部片段？", isPresented: $confirmingReset) {
            Button("取消", role: .cancel) {}
            Button("重置全部", role: .destructive) {
                Task {
                    do { try await session.resetAll() }
                    catch { resetError = error.localizedDescription }
                }
            }
        } message: {
            Text("所有人工确认、调整和排除状态都将被覆盖，重新使用当前默认时长。")
        }
        .alert("无法重置片段", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(resetError ?? "") }
        .onDisappear {
            if session.viewModel.editingItemID == nil { session.release() }
        }
    }

    private func exit() {
        session.release()
        onExit()
    }
}
