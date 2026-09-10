import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
    import UIKit
#endif

struct TrainingSessionPressFeedbackState: Equatable {
    private(set) var pressedSessionID: UUID?

    func isPressing(_ sessionID: UUID) -> Bool {
        pressedSessionID == sessionID
    }

    mutating func setPressing(_ sessionID: UUID, isPressing: Bool) {
        if isPressing {
            pressedSessionID = sessionID
        } else if pressedSessionID == sessionID {
            pressedSessionID = nil
        }
    }

    mutating func clear() {
        pressedSessionID = nil
    }
}

struct TrainingSessionTitlePressFeedbackState: Equatable {
    private(set) var isPressing = false

    mutating func setPressing(_ isPressing: Bool) {
        self.isPressing = isPressing
    }

    mutating func clear() {
        isPressing = false
    }
}

struct TrainingSessionNavigationTarget: Identifiable, Hashable {
    let id: UUID
}

struct TrainingSessionNavigationState: Equatable {
    private(set) var target: TrainingSessionNavigationTarget?

    mutating func open(_ sessionID: UUID) {
        target = TrainingSessionNavigationTarget(id: sessionID)
    }

    mutating func clear() {
        target = nil
    }
}

struct TrainingSessionListView: View {
    @StateObject private var viewModel: TrainingSessionListViewModel
    @ObservedObject private var highlightTaskManager: HighlightTaskManager
    @State private var isImportingTrainingSessions = false
    @State private var isExportingTrainingSessions = false
    @State private var isConfirmingTrainingSessionDeletion = false
    @State private var trainingSessionExportDocument: TrainingSessionJSONDocument?
    @State private var trainingSessionExportCount = 0
    @State private var trainingSessionTransferAlert: TrainingSessionTransferAlert?
    @State private var isExportingLogs = false
    @State private var isConfirmingLogExport = false
    @State private var exportedLogURL: URL?
    @State private var logExportErrorMessage: String?
    @State private var highlightPlaybackURL: URL?
    @State private var highlightPlaybackErrorMessage: String?
    @State private var pressFeedbackState = TrainingSessionPressFeedbackState()
    @State private var titlePressFeedbackState = TrainingSessionTitlePressFeedbackState()
    @State private var taskNavigationTarget: TrainingSessionNavigationTarget?
    @State private var navigationState = TrainingSessionNavigationState()
    private let diagnosticsSnapshotProvider: (() -> PhoneWatchSyncDiagnosticsSnapshot)?
    private let logger: AppLogging
    private let logExportService: AppLogExportService?
    private let reviewStore: (any HighlightClipReviewStoring)?

    @MainActor
    init(
        store: TrainingSessionStoreProtocol,
        diagnosticsSnapshotProvider: (() -> PhoneWatchSyncDiagnosticsSnapshot)? = nil,
        logger: AppLogging = AppLogger.shared,
        logExportService: AppLogExportService? = nil,
        highlightTaskManager: HighlightTaskManager? = nil,
        reviewStore: (any HighlightClipReviewStoring)? = nil,
    ) {
        self.diagnosticsSnapshotProvider = diagnosticsSnapshotProvider
        self.logger = logger
        self.logExportService = logExportService
        self.reviewStore = reviewStore
        let resolvedHighlightTaskManager = Self.resolvedHighlightTaskManager(highlightTaskManager, logger: logger)
        _highlightTaskManager = ObservedObject(wrappedValue: resolvedHighlightTaskManager)
        _viewModel = StateObject(wrappedValue: TrainingSessionListViewModel(
            store: store,
            reviewStore: reviewStore,
            logger: logger,
        ))
    }

    @MainActor
    init(
        viewModel: TrainingSessionListViewModel,
        diagnosticsSnapshotProvider: (() -> PhoneWatchSyncDiagnosticsSnapshot)? = nil,
        logger: AppLogging = AppLogger.shared,
        logExportService: AppLogExportService? = nil,
        highlightTaskManager: HighlightTaskManager? = nil,
        reviewStore: (any HighlightClipReviewStoring)? = nil,
    ) {
        self.diagnosticsSnapshotProvider = diagnosticsSnapshotProvider
        self.logger = logger
        self.logExportService = logExportService
        self.reviewStore = reviewStore
        let resolvedHighlightTaskManager = Self.resolvedHighlightTaskManager(highlightTaskManager, logger: logger)
        _highlightTaskManager = ObservedObject(wrappedValue: resolvedHighlightTaskManager)
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                if viewModel.isSelectionMode {
                    selectionActionBar
                }
            }
            .navigationTitle("训练记录")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: navigationTargetBinding) { target in
                destination(for: target.id)
            }
            .navigationDestination(item: $taskNavigationTarget) { target in
                if let task = highlightTaskManager.task(target.id) {
                    HighlightTaskEditorView(task: task, manager: highlightTaskManager) { taskNavigationTarget = nil }
                }
            }
            .task {
                if !highlightTaskManager.isLoaded { await highlightTaskManager.load() }
                await viewModel.load()
            }
            .toolbar {
                if logExportService != nil {
                    ToolbarItem(placement: .principal) {
                        diagnosticsLogExportTitle
                    }
                }

                if viewModel.isSelectionMode {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") {
                            viewModel.clearSelection()
                        }
                    }
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            isImportingTrainingSessions = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .accessibilityLabel("导入训练记录")

                        Button {
                            prepareAllTrainingSessionExport()
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("导出全部训练记录")
                        .disabled(isExportingTrainingSessions || viewModel.isEmpty)
                    }
                }
            }
            .fileImporter(
                isPresented: $isImportingTrainingSessions,
                allowedContentTypes: [.json],
            ) { result in
                Task {
                    await handleTrainingSessionImport(result)
                }
            }
            .fileExporter(
                isPresented: $isExportingTrainingSessions,
                document: trainingSessionExportDocument,
                contentType: .json,
                defaultFilename: "ShotMarker-TrainingSessions.json",
            ) { result in
                handleTrainingSessionExport(result)
            }
            .alert(trainingSessionTransferAlert?.title ?? "", isPresented: trainingSessionTransferAlertBinding) {
                Button("好", role: .cancel) {}
            } message: {
                Text(trainingSessionTransferAlert?.message ?? "")
            }
            .alert("删除训练记录？", isPresented: $isConfirmingTrainingSessionDeletion) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    Task {
                        await viewModel.deleteSelectedSessions()
                    }
                }
            } message: {
                Text("将删除已选择的 \(viewModel.selectedSessionIDs.count) 条训练记录。")
            }
            #if os(iOS)
            .sheet(isPresented: exportedLogSheetBinding) {
                if let exportedLogURL {
                    AppLogShareSheet(fileURL: exportedLogURL)
                }
            }
            .sheet(isPresented: highlightPlaybackSheetBinding) {
                if let highlightPlaybackURL {
                    HighlightJobVideoPlayerView(videoURL: highlightPlaybackURL)
                }
            }
            #endif
            .alert("导出日志失败", isPresented: logExportErrorBinding) {
                Button("好", role: .cancel) {
                    logExportErrorMessage = nil
                }
            } message: {
                Text(logExportErrorMessage ?? "未知错误")
            }
            .alert("无法打开集锦", isPresented: highlightPlaybackErrorBinding) {
                Button("好", role: .cancel) {
                    highlightPlaybackErrorMessage = nil
                }
            } message: {
                Text(highlightPlaybackErrorMessage ?? "未知错误")
            }
            .alert("是否导出诊断日志？", isPresented: $isConfirmingLogExport) {
                Button("取消", role: .cancel) {}
                Button("导出") {
                    Task { await exportLogs() }
                }
            } message: {
                Text("导出文件将包含应用诊断日志。")
            }
        }
    }

    private var diagnosticsLogExportTitle: some View {
        let isPressing = titlePressFeedbackState.isPressing

        return Text("训练记录")
            .font(.headline)
            .foregroundStyle(isPressing ? Color.accentColor : Color.primary)
            .scaleEffect(isPressing ? 0.94 : 1)
            .animation(.easeInOut(duration: 0.16), value: isPressing)
            .contentShape(Rectangle())
            .onLongPressGesture(
                minimumDuration: 5,
                maximumDistance: 20,
                perform: {
                    handleDiagnosticsTitleLongPress()
                },
                onPressingChanged: { isPressing in
                    setDiagnosticsTitlePressFeedback(isPressing)
                },
            )
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage = viewModel.errorMessage {
            if highlightTaskManager.tasks.isEmpty && highlightTaskManager.errorMessage == nil {
                ContentUnavailableView("无法加载训练记录", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
            } else {
                List {
                    highlightJobSection
                    unavailableRow("无法加载训练记录", systemImage: "exclamationmark.triangle", description: errorMessage)
                }
            }
        } else if viewModel.isEmpty {
            if highlightTaskManager.tasks.isEmpty && highlightTaskManager.errorMessage == nil {
                ContentUnavailableView("暂无训练记录", systemImage: "applewatch", description: Text("结束一次手表训练后，训练记录会显示在这里。"))
            } else {
                List {
                    highlightJobSection
                    unavailableRow("暂无训练记录", systemImage: "applewatch", description: "结束一次手表训练后，训练记录会显示在这里。")
                }
            }
        } else {
            List {
                highlightJobSection

                ForEach(viewModel.rows) { row in
                    if viewModel.isSelectionMode {
                        TrainingSessionRow(
                            row: row,
                            isSelectionMode: true,
                            isSelected: viewModel.isSelected(row.id),
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.toggleSelection(for: row.id)
                        }
                        .listRowBackground(viewModel.isSelected(row.id) ? Color.accentColor.opacity(0.12) : Color.clear)
                    } else {
                        trainingSessionNavigationRow(for: row)
                    }
                }
            }
        }
    }

    private var highlightJobSection: some View {
        Section("集锦任务") {
            if let error = highlightTaskManager.errorMessage {
                Text(error).foregroundStyle(.secondary)
                Button("重新加载任务") { Task { await highlightTaskManager.load() } }
            }
            ForEach(highlightTaskManager.tasks) { task in
                HighlightTaskRow(task: task, manager: highlightTaskManager,
                    onEdit: { taskNavigationTarget = TrainingSessionNavigationTarget(id: task.id) },
                    onPlay: { playHighlightJob(task.id) })
            }
        }
    }

    private func unavailableRow(_ title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
            .frame(maxWidth: .infinity, minHeight: 280)
            .listRowSeparator(.hidden)
    }

    private func trainingSessionNavigationRow(for row: TrainingSessionRowViewData) -> some View {
        let isPressing = pressFeedbackState.isPressing(row.id)

        return TrainingSessionRow(row: row)
            .scaleEffect(isPressing ? 0.98 : 1)
            .animation(.easeInOut(duration: 0.12), value: isPressing)
            .contentShape(Rectangle())
            .onTapGesture {
                navigationState.open(row.id)
            }
            .onLongPressGesture(
                minimumDuration: 0.5,
                maximumDistance: 20,
                perform: {
                    handleTrainingSessionLongPress(row.id)
                },
                onPressingChanged: { isPressing in
                    setTrainingSessionPressFeedback(row.id, isPressing: isPressing)
                },
            )
            .accessibilityAddTraits(.isButton)
            .listRowBackground(isPressing ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private var navigationTargetBinding: Binding<TrainingSessionNavigationTarget?> {
        Binding(
            get: { navigationState.target },
            set: { target in
                if let target {
                    navigationState.open(target.id)
                } else {
                    navigationState.clear()
                }
            },
        )
    }

    @MainActor
    private func setDiagnosticsTitlePressFeedback(_ isPressing: Bool) {
        withAnimation(.easeInOut(duration: 0.16)) {
            titlePressFeedbackState.setPressing(isPressing)
        }
    }

    @MainActor
    private func handleDiagnosticsTitleLongPress() {
        guard !isExportingLogs else {
            setDiagnosticsTitlePressFeedback(false)
            return
        }

        playSelectionFeedback()

        withAnimation(.easeInOut(duration: 0.16)) {
            titlePressFeedbackState.clear()
            isConfirmingLogExport = true
        }
    }

    @ViewBuilder
    private func destination(for sessionID: UUID) -> some View {
        #if os(iOS)
            if let session = viewModel.session(for: sessionID) {
                TrainingSessionHighlightView(
                    session: session,
                    highlightTaskManager: highlightTaskManager,
                    reviewStore: reviewStore,
                    onExit: { navigationState.clear() },
                )
            } else {
                ContentUnavailableView("无法加载训练记录", systemImage: "exclamationmark.triangle")
            }
        #else
            ContentUnavailableView("无法生成集锦", systemImage: "video.slash")
        #endif
    }

    @MainActor
    private func setTrainingSessionPressFeedback(_ sessionID: UUID, isPressing: Bool) {
        withAnimation(.easeInOut(duration: 0.12)) {
            pressFeedbackState.setPressing(sessionID, isPressing: isPressing)
        }
    }

    @MainActor
    private func handleTrainingSessionLongPress(_ sessionID: UUID) {
        playSelectionFeedback()

        withAnimation(.easeInOut(duration: 0.12)) {
            pressFeedbackState.clear()
            viewModel.beginSelection(with: sessionID)
        }
    }

    private func playSelectionFeedback() {
        #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    @MainActor
    private func playHighlightJob(_ jobID: UUID) {
        do {
            highlightPlaybackURL = try highlightTaskManager.playbackURL(taskID: jobID)
        } catch {
            highlightPlaybackErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    @MainActor
    private static func resolvedHighlightTaskManager(
        _ highlightTaskManager: HighlightTaskManager?,
        logger: AppLogging,
    ) -> HighlightTaskManager {
        guard let highlightTaskManager else {
            let manager = HighlightTaskManager.live(logger: logger)
            Task { await manager.load() }
            return manager
        }

        return highlightTaskManager
    }

    private var selectionActionBar: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                isConfirmingTrainingSessionDeletion = true
            } label: {
                Text("删除")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.selectedSessionIDs.isEmpty)

            Button {
                Task {
                    await viewModel.mergeSelectedSessions()
                }
            } label: {
                Text("合并")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canMergeSelectedSessions)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var exportedLogSheetBinding: Binding<Bool> {
        Binding(
            get: { exportedLogURL != nil },
            set: { isPresented in
                if !isPresented {
                    exportedLogURL = nil
                }
            },
        )
    }

    private var logExportErrorBinding: Binding<Bool> {
        Binding(
            get: { logExportErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    logExportErrorMessage = nil
                }
            },
        )
    }

    private var highlightPlaybackSheetBinding: Binding<Bool> {
        Binding(
            get: { highlightPlaybackURL != nil },
            set: { isPresented in
                if !isPresented {
                    highlightPlaybackURL = nil
                }
            },
        )
    }

    private var highlightPlaybackErrorBinding: Binding<Bool> {
        Binding(
            get: { highlightPlaybackErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    highlightPlaybackErrorMessage = nil
                }
            },
        )
    }

    private var trainingSessionTransferAlertBinding: Binding<Bool> {
        Binding(
            get: { trainingSessionTransferAlert != nil },
            set: { isPresented in
                if !isPresented {
                    trainingSessionTransferAlert = nil
                }
            },
        )
    }

    @MainActor
    private func prepareAllTrainingSessionExport() {
        let exportCount = viewModel.allSessionsForExport().count
        logger.info(
            "training.sessions.export.started",
            category: .training,
            message: "开始导出训练记录",
            context: [
                "exportScope": "all",
                "trainingSessionCount": "\(exportCount)",
            ],
        )

        do {
            let data = try viewModel.exportAllSessionsData()
            trainingSessionExportDocument = TrainingSessionJSONDocument(data: data)
            trainingSessionExportCount = exportCount
            isExportingTrainingSessions = true
        } catch {
            logger.error(
                "training.sessions.export.failed",
                category: .training,
                message: "训练记录导出失败",
                error: error,
                context: [
                    "exportScope": "all",
                    "trainingSessionCount": "\(exportCount)",
                ],
            )
            trainingSessionTransferAlert = .exportFailed(error)
        }
    }

    @MainActor
    private func handleTrainingSessionExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            logger.info(
                "training.sessions.export.succeeded",
                category: .training,
                message: "训练记录导出成功",
                context: ["exportedTrainingSessionCount": "\(trainingSessionExportCount)"],
            )
            trainingSessionTransferAlert = .exportSucceeded(count: trainingSessionExportCount)
            trainingSessionExportDocument = nil
            trainingSessionExportCount = 0
            viewModel.clearSelection()
        case let .failure(error):
            guard !(error is CancellationError) else {
                trainingSessionExportDocument = nil
                trainingSessionExportCount = 0
                return
            }

            logger.error(
                "training.sessions.export.failed",
                category: .training,
                message: "训练记录导出失败",
                error: error,
                context: ["exportedTrainingSessionCount": "\(trainingSessionExportCount)"],
            )
            trainingSessionTransferAlert = .exportFailed(error)
            trainingSessionExportDocument = nil
            trainingSessionExportCount = 0
        }
    }

    @MainActor
    private func handleTrainingSessionImport(_ result: Result<URL, Error>) async {
        switch result {
        case let .success(fileURL):
            logger.info(
                "training.sessions.import.started",
                category: .training,
                message: "开始导入训练记录",
            )

            do {
                let importResult = try await viewModel.importTrainingSessions(from: fileURL)
                logger.info(
                    "training.sessions.import.succeeded",
                    category: .training,
                    message: "训练记录导入成功",
                    context: [
                        "importedTrainingSessionCount": "\(importResult.importedCount)",
                        "insertedTrainingSessionCount": "\(importResult.insertedCount)",
                        "replacedTrainingSessionCount": "\(importResult.replacedCount)",
                    ],
                )
                trainingSessionTransferAlert = .importSucceeded(importResult)
            } catch {
                logger.error(
                    "training.sessions.import.failed",
                    category: .training,
                    message: "训练记录导入失败",
                    error: error,
                )
                trainingSessionTransferAlert = .importFailed(error)
            }
        case let .failure(error):
            guard !(error is CancellationError) else {
                return
            }

            logger.error(
                "training.sessions.import.failed",
                category: .training,
                message: "训练记录导入失败",
                error: error,
            )
            trainingSessionTransferAlert = .importFailed(error)
        }
    }

    @MainActor
    private func exportLogs() async {
        guard let logExportService else {
            return
        }

        isExportingLogs = true
        logger.info(
            "diagnostics.export.started",
            category: .diagnostics,
            message: "开始导出诊断日志",
        )

        do {
            exportedLogURL = try await logExportService.export()
        } catch {
            logExportErrorMessage = (error as NSError).localizedDescription
            logger.error(
                "diagnostics.export.failed",
                category: .diagnostics,
                message: "诊断日志导出失败",
                error: error,
            )
        }

        isExportingLogs = false
    }
}

struct TrainingSessionJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.json]
    }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct TrainingSessionTransferAlert {
    let title: String
    let message: String

    static func importSucceeded(_ result: TrainingSessionJSONImportResult) -> TrainingSessionTransferAlert {
        let message = "已导入 \(result.importedCount) 条训练记录，"
            + "其中新增 \(result.insertedCount) 条，覆盖 \(result.replacedCount) 条。"

        return TrainingSessionTransferAlert(
            title: "导入完成",
            message: message,
        )
    }

    static func importFailed(_ error: Error) -> TrainingSessionTransferAlert {
        TrainingSessionTransferAlert(
            title: "导入失败",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        )
    }

    static func exportSucceeded(count: Int) -> TrainingSessionTransferAlert {
        TrainingSessionTransferAlert(
            title: "导出完成",
            message: "已导出 \(count) 条训练记录。",
        )
    }

    static func exportFailed(_ error: Error) -> TrainingSessionTransferAlert {
        TrainingSessionTransferAlert(
            title: "导出失败",
            message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
        )
    }
}

#if DEBUG
    #Preview {
        let reviewStore = InMemoryHighlightClipReviewStore()
        TrainingSessionListView(
            viewModel: TrainingSessionListViewModel(
                store: InMemoryTrainingSessionStore(sessions: TrainingSession.previewSessions),
                reviewStore: reviewStore,
            ),
            reviewStore: reviewStore,
        )
    }
#endif
