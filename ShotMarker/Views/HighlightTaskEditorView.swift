import SwiftUI

struct HighlightTaskEditorView: View {
    let task: HighlightTask
    @ObservedObject var manager: HighlightTaskManager
    let onExit: () -> Void

    var body: some View {
        TrainingSessionHighlightView(session: task.trainingSnapshot.planningSession,
            highlightTaskManager: manager, task: task, onExit: onExit)
    }
}
