#if os(iOS)
    import Foundation
    import AVFoundation
    import PhotosUI
    import SwiftUI
    import UIKit
    import UniformTypeIdentifiers

    struct TrainingSessionHighlightView: View {
        let session: TrainingSession
        @Environment(\.dismiss) private var dismiss

        private let logger: AppLogging
        private let highlightTaskManager: HighlightTaskManager?
        private let onExit: (() -> Void)?
        private let videoLoadingService: TrainingVideoLoadingService<PhotosPickerItem>
        private let photoLibraryAssetProvider: PhotoLibraryVideoAssetProvider
        private let temporaryFileStore: TrainingVideoTemporaryFileStore
        private let reviewStore: (any HighlightClipReviewStoring)?

        @State private var selectedItems: [PhotosPickerItem] = []
        @State private var selectedVideos: [SelectedTrainingVideo] = []
        @State private var isLoadingVideos = false
        @State private var isCreatingHighlightJob = false
        @State private var clipSettings = ClipSettingsStore.shared.load()
        @State private var isMarkerLabelSettingsExpanded = false
        @State private var selectedVideoItems: [SelectedTrainingVideoSelectionItem] = []
        @State private var preparationConfirmationItemID: String?
        @State private var preparationTasks: [String: Task<Void, Never>] = [:]
        @State private var preparationRunIDs: [String: UUID] = [:]
        @State private var alert: HighlightFlowAlert?
        @State private var reviewSession: HighlightReviewSession?
        @State private var taskBaseline: HighlightTask?
        @State private var creationID = UUID()
        @State private var confirmingDiscard = false
        @State private var selectionLoadRevision = UUID()
        @State private var selectionTask: Task<Void, Never>?
        @State private var availabilityTask: Task<Void, Never>?
        @State private var isImportingVideos = false
        @State private var outputPlaybackURL: URL?
        private var reviewViewModel: HighlightClipReviewViewModel? { reviewSession?.viewModel }
        @State private var isReviewPresented = false
        @State private var isPreparingReview = false
        @State private var reviewPreparationRevision = UUID()
        @State private var isExportingTrainingSession = false
        @State private var trainingSessionExportDocument: TrainingSessionJSONDocument?

        init(
            session: TrainingSession,
            logger: AppLogging = AppLogger.shared,
            highlightTaskManager: HighlightTaskManager? = nil,
            reviewStore: (any HighlightClipReviewStoring)? = nil,
            task: HighlightTask? = nil,
            onExit: (() -> Void)? = nil,
        ) {
            self.session = session
            self.logger = logger
            self.highlightTaskManager = highlightTaskManager
            self.onExit = onExit
            _taskBaseline = State(initialValue: task)
            _clipSettings = State(initialValue: task?.clipSettings ?? ClipSettingsStore.shared.load())
            if let task, let highlightTaskManager {
                let media = HighlightTaskMedia(fileStore: highlightTaskManager.fileStore)
                let videos = task.videos.compactMap { try? media.selectionVideo(for: $0) }
                _selectedVideos = State(initialValue: videos)
                _selectedVideoItems = State(initialValue: videos.enumerated().map { index, video in
                    .available(id: video.id, title: "视频 \(index + 1)", video: video, thumbnailData: nil)
                })
            }
            self.reviewStore = reviewStore

            let photoLibraryAssetProvider = PhotoLibraryVideoAssetProvider()
            let temporaryFileStore = TrainingVideoTemporaryFileStore()
            self.photoLibraryAssetProvider = photoLibraryAssetProvider
            self.temporaryFileStore = temporaryFileStore
            videoLoadingService = TrainingVideoLoadingService.live(
                photoLibraryAssetProvider: photoLibraryAssetProvider,
                temporaryFileStore: temporaryFileStore,
            )
        }

        private var plan: HighlightClipPlan {
            VideoClipSegmentPlanner.highlightPlan(
                for: session,
                videos: selectedVideos,
                clipSettings: clipSettings,
            )
        }

        var body: some View {
            alertedFlowView
        }

        private var baseFlowView: some View {
            List {
                trainingSummarySection
                currentOutputSection
                clipSettingsSection
                videoPickerSection
                selectedVideoItemsSection
                markerLabelSettingsSection
                coverageAndGenerationSections
            }
            .navigationTitle(taskBaseline == nil ? "新建集锦任务" : "编辑集锦任务")
            .navigationBarBackButtonHidden(taskBaseline != nil || isPreparingReview)
            .disabled(isPreparingReview)
            .toolbar {
                flowToolbarContent
            }
        }

        private var flowLifecycleView: some View {
            baseFlowView
            .fileExporter(
                isPresented: $isExportingTrainingSession,
                document: trainingSessionExportDocument,
                contentType: .json,
                defaultFilename: "ShotMarker-TrainingSession-\(session.id.uuidString).json",
            ) { result in
                handleTrainingSessionExport(result)
            }
            .onChange(of: selectedItems) { _, newItems in
                guard !newItems.isEmpty else { return }
                selectionTask?.cancel()
                selectionTask = Task { await loadSelectedVideos(from: newItems) }
            }
            .onAppear {
                logHighlightViewOpened()
                if taskBaseline != nil { availabilityTask = Task { await refreshExistingVideoAvailability() } }
            }
            .onChange(of: selectedVideos) { _, _ in
                logPlanUpdated()
            }
            .onChange(of: clipSettings) { _, newSettings in
                if taskBaseline == nil { ClipSettingsStore.shared.save(newSettings) }
                logPlanUpdated()
            }
            .navigationDestination(isPresented: $isReviewPresented) {
                reviewDestination
            }
        }

        private var alertedFlowView: some View {
            flowLifecycleView
            .alert(alert?.title ?? "", isPresented: isShowingAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alert?.message ?? "")
            }
            .alert("下载或准备视频？", isPresented: isShowingPreparationConfirmation) {
                Button("取消", role: .cancel) {}
                Button("开始") {
                    startPreparingConfirmedVideo()
                }
            } message: {
                Text("可能需要从 iCloud 下载原视频，过程中可能消耗流量。")
            }
            .alert("放弃本次调整？", isPresented: $confirmingDiscard) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃调整", role: .destructive) { finishFlow() }
            } message: { Text("未提交的视频和设置将被丢弃，已保存的任务保持不变。") }
            .fileImporter(isPresented: $isImportingVideos, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
                selectionTask?.cancel()
                selectionTask = Task { await importVideoFiles(result) }
            }
            .sheet(isPresented: Binding(get: { outputPlaybackURL != nil }, set: { if !$0 { outputPlaybackURL = nil } })) {
                if let outputPlaybackURL { HighlightJobVideoPlayerView(videoURL: outputPlaybackURL) }
            }
            .onDisappear {
                cleanupAfterWholeFlowDisappearsIfNeeded()
            }
        }

        @ToolbarContentBuilder
        private var flowToolbarContent: some ToolbarContent {
            if taskBaseline != nil {
                ToolbarItem(placement: .topBarLeading) {
                    Button("返回首页") {
                        if hasConfigurationChanges { confirmingDiscard = true } else { finishFlow() }
                    }.disabled(isPreparingReview)
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button { prepareTrainingSessionExport() } label: {
                        Label("导出记录", systemImage: "square.and.arrow.up")
                    }.disabled(isPreparingReview || isExportingTrainingSession)
                }
            }
        }

        @ViewBuilder
        private var reviewDestination: some View {
            if let reviewSession {
                HighlightTaskReviewView(session: reviewSession, onExit: finishFlow)
            }
        }

        private var trainingRangeText: String {
            let start = session.startedAt.formatted(.dateTime.month().day().hour().minute())
            let end = session.endedAt.formatted(.dateTime.month().day().hour().minute())
            return "\(start) -> \(end)"
        }

        private var isShowingAlert: Binding<Bool> {
            Binding(
                get: { alert != nil },
                set: { isPresented in
                    if !isPresented {
                        alert = nil
                    }
                },
            )
        }

        private var isShowingPreparationConfirmation: Binding<Bool> {
            Binding(
                get: { preparationConfirmationItemID != nil },
                set: { isPresented in
                    if !isPresented {
                        preparationConfirmationItemID = nil
                    }
                },
            )
        }

        private var guardedSelectedItems: Binding<[PhotosPickerItem]> {
            Binding(
                get: { selectedItems },
                set: { proposedItems in
                    guard proposedItems != selectedItems else {
                        return
                    }
                    invalidateCurrentReview()
                    selectedItems = proposedItems
                },
            )
        }

        private var guardedSecondsBeforeMarker: Binding<TimeInterval> {
            guardedRangeSetting(
                currentValue: { clipSettings.secondsBeforeMarker },
                apply: { clipSettings.secondsBeforeMarker = $0 },
            )
        }

        private var guardedSecondsAfterMarker: Binding<TimeInterval> {
            guardedRangeSetting(
                currentValue: { clipSettings.secondsAfterMarker },
                apply: { clipSettings.secondsAfterMarker = $0 },
            )
        }

        private func guardedRangeSetting(
            currentValue: @escaping () -> TimeInterval,
            apply: @escaping (TimeInterval) -> Void,
        ) -> Binding<TimeInterval> {
            Binding(
                get: currentValue,
                set: { proposedValue in
                    guard proposedValue != currentValue() else {
                        return
                    }
                    invalidateCurrentReview()
                    apply(proposedValue)
                },
            )
        }

        @MainActor
        private func invalidateCurrentReview() {
            reviewPreparationRevision = UUID()
            reviewSession?.release()
            reviewSession = nil
            isReviewPresented = false
        }

        private var trainingSummarySection: some View {
            Section("训练") {
                LabeledContent("时间", value: trainingRangeText)
                LabeledContent("打点", value: "\(session.markerCount) 个")
                Text("创建任务后训练记录不可更换").font(.footnote).foregroundStyle(.secondary)
            }
        }

        private var clipSettingsSection: some View {
            Section("剪辑范围") {
                Stepper(value: guardedSecondsBeforeMarker, in: 0 ... 20, step: 1) {
                    LabeledContent("打点前", value: "\(Int(clipSettings.secondsBeforeMarker)) 秒")
                }

                Stepper(value: guardedSecondsAfterMarker, in: 1 ... 20, step: 1) {
                    LabeledContent("打点后", value: "\(Int(clipSettings.secondsAfterMarker)) 秒")
                }
            }
            .disabled(isCreatingHighlightJob)
        }

        private var videoPickerSection: some View {
            Section {
                PhotosPicker(
                    selection: guardedSelectedItems,
                    maxSelectionCount: 20,
                    matching: .videos,
                    photoLibrary: .shared(),
                ) {
                    Label(selectedVideoItems.isEmpty ? "选择视频" : "继续选择视频", systemImage: "video.badge.plus")
                }
                .disabled(isLoadingVideos || isCreatingHighlightJob || selectedVideoItems.count >= 20)
                Button("从文件导入视频") { isImportingVideos = true }
                    .disabled(isLoadingVideos || selectedVideoItems.count >= 20)

                if isLoadingVideos {
                    ProgressView("读取视频")
                }
            }
        }

        @ViewBuilder
        private var coverageAndGenerationSections: some View {
            if !selectedVideos.isEmpty {
                coverageResultSection
                generateHighlightSection
            }
        }

        private var coverageResultSection: some View {
            Section("覆盖结果") {
                LabeledContent("已选择", value: "\(plan.selectedVideoCount) 个视频")
                LabeledContent("可剪辑", value: "\(plan.matchedMarkerCount) / \(plan.totalMarkerCount) 个打点")

                if plan.unmatchedMarkerCount > 0 {
                    Text("\(plan.unmatchedMarkerCount) 个打点不在所选视频范围内，生成时会跳过。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !plan.canGenerate {
                    Text("所选视频没有覆盖任何打点。请确认视频是否对应这次训练。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }

        private var generateHighlightSection: some View {
            Section {
                Button {
                    Task {
                        await prepareReview()
                    }
                } label: {
                    HStack {
                        if isPreparingReview {
                            ProgressView()
                        }

                        Text(isPreparingReview ? "正在准备审核…" : "下一步：审核片段")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !plan.canGenerate
                        || isLoadingVideos
                        || isCreatingHighlightJob
                        || isPreparingReview
                        || selectedVideoItems.contains(where: { $0.video == nil || $0.unavailableReason == .notReady }),
                )
            }
        }

        @ViewBuilder
        private var selectedVideoItemsSection: some View {
            if !selectedVideoItems.isEmpty {
                Section("已选视频（按此顺序匹配打点）") {
                    ForEach(Array(selectedVideoItems.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading) {
                            Text("视频 \(index + 1)").font(.headline)
                            selectedVideoItemCard(item)
                            HStack {
                                Button("上移") { moveVideo(at: index, by: -1) }.disabled(index == 0)
                                Button("下移") { moveVideo(at: index, by: 1) }.disabled(index == selectedVideoItems.count - 1)
                                Spacer()
                                Button("移除", role: .destructive) { removeVideo(at: index) }
                            }
                            .buttonStyle(.bordered)
                            .frame(minHeight: 44)
                        }
                    }
                }
            }
        }

        @ViewBuilder
        private var markerLabelSettingsSection: some View {
            if let firstSelectedItem = selectedVideoItems.first {
                Section("片段序数") {
                    DisclosureGroup(
                        "样式调整",
                        isExpanded: $isMarkerLabelSettingsExpanded,
                    ) {
                        MarkerLabelSettingsView(
                            thumbnailData: firstSelectedItem.thumbnailData,
                            previewLabel: plan.segments.first?.markerLabel ?? "1/1",
                            isDisabled: isCreatingHighlightJob,
                            style: $clipSettings.markerLabelStyle,
                        )
                    }
                }
            }
        }

        @MainActor
        private func prepareTrainingSessionExport() {
            logger.info(
                "training.session.export.started",
                category: .training,
                message: "开始导出单次训练记录",
                context: highlightContext(),
            )

            do {
                let data = try TrainingSessionJSONTransferService(
                    store: InMemoryTrainingSessionStore(sessions: []),
                    reviewStore: reviewStore,
                    logger: logger,
                )
                .exportData(for: [session])
                trainingSessionExportDocument = TrainingSessionJSONDocument(data: data)
                isExportingTrainingSession = true
            } catch {
                logger.error(
                    "training.session.export.failed",
                    category: .training,
                    message: "单次训练记录导出失败",
                    error: nil,
                    context: highlightContext(extra: [
                        "errorCategory": "serializationFailed",
                    ]),
                )
                alert = HighlightFlowAlert(
                    title: "导出失败",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                )
            }
        }

        @MainActor
        private func handleTrainingSessionExport(_ result: Result<URL, Error>) {
            switch result {
            case .success:
                logger.info(
                    "training.session.export.succeeded",
                    category: .training,
                    message: "单次训练记录导出成功",
                    context: highlightContext(),
                )
                alert = HighlightFlowAlert(title: "导出完成", message: "已导出这次训练记录。")
                trainingSessionExportDocument = nil
            case let .failure(error):
                guard !(error is CancellationError) else {
                    trainingSessionExportDocument = nil
                    return
                }

                logger.error(
                    "training.session.export.failed",
                    category: .training,
                    message: "单次训练记录导出失败",
                    error: nil,
                    context: highlightContext(extra: [
                        "errorCategory": "fileExportFailed",
                    ]),
                )
                alert = HighlightFlowAlert(
                    title: "导出失败",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                )
                trainingSessionExportDocument = nil
            }
        }

        @ViewBuilder
        private func selectedVideoItemCard(_ item: SelectedTrainingVideoSelectionItem) -> some View {
            if item.canControlPreparation {
                Button {
                    handlePreparationControlTapped(for: item)
                } label: {
                    selectedVideoItemCardContent(item)
                }
                .buttonStyle(.plain)
                .disabled(isLoadingVideos || isCreatingHighlightJob)
            } else {
                selectedVideoItemCardContent(item)
            }
        }

        private func selectedVideoItemCardContent(_ item: SelectedTrainingVideoSelectionItem) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    selectedVideoThumbnail(for: item)

                    if item.isAvailable {
                        VStack {
                            HStack {
                                Label("可用", systemImage: "checkmark.circle.fill")
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 4)
                                    .background(.green.opacity(0.9), in: Capsule())
                                    .foregroundStyle(.white)

                                Spacer()
                            }

                            Spacer()
                        }
                        .padding(6)
                    } else if item.isPreparing {
                        Color.black.opacity(0.62)

                        VStack(spacing: 6) {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .tint(.white)

                            Text(item.preparationProgressText ?? "0%")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                    } else if item.isPreparationPaused {
                        Color.black.opacity(0.62)

                        VStack(spacing: 6) {
                            Image(systemName: "pause.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white)

                            Text(item.statusText)
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                        }
                    } else {
                        Color.black.opacity(0.58)

                        Text(item.statusText)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                    }
                }
                .frame(width: 156, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Text(item.title)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 156, alignment: .leading)
        }

        @ViewBuilder
        private func selectedVideoThumbnail(for item: SelectedTrainingVideoSelectionItem) -> some View {
            if let thumbnailData = item.thumbnailData,
               let image = UIImage(data: thumbnailData)
            {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 156, height: 88)
                    .clipped()
            } else {
                ZStack {
                    Rectangle()
                        .fill(.secondary.opacity(0.16))

                    Image(systemName: "video")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 156, height: 88)
            }
        }

        private func logHighlightViewOpened() {
            logger.info(
                "highlight.view.opened",
                category: .video,
                message: "打开集锦生成页面",
                context: highlightContext(),
            )
        }

        private func logPlanUpdated() {
            logger.info(
                "highlight.plan.updated",
                category: .video,
                message: "集锦剪辑计划更新",
                context: highlightPlanContext(plan),
            )
        }

        @MainActor
        private func handlePreparationControlTapped(for item: SelectedTrainingVideoSelectionItem) {
            if item.isPreparing {
                pausePreparingVideo(withID: item.id)
                return
            }

            if item.canResumePreparation {
                startPreparingVideo(withID: item.id)
                return
            }

            if item.canPrepare {
                preparationConfirmationItemID = item.id
            }
        }

        @MainActor
        private func startPreparingConfirmedVideo() {
            guard let itemID = preparationConfirmationItemID else {
                return
            }

            preparationConfirmationItemID = nil
            startPreparingVideo(withID: itemID)
        }

        @MainActor
        private func startPreparingVideo(withID itemID: String) {
            guard preparationTasks[itemID] == nil else {
                return
            }

            let runID = UUID()
            preparationRunIDs[itemID] = runID

            let task = Task {
                await prepareSelectedVideoItem(withID: itemID, runID: runID)
            }
            preparationTasks[itemID] = task
        }

        @MainActor
        private func pausePreparingVideo(withID itemID: String) {
            guard let task = preparationTasks[itemID] else {
                return
            }

            task.cancel()
            preparationTasks[itemID] = nil
            preparationRunIDs[itemID] = nil

            guard let itemIndex = selectedVideoItems.firstIndex(where: { $0.id == itemID }) else {
                return
            }

            let item = selectedVideoItems[itemIndex]
            guard item.isPreparing else {
                return
            }

            selectedVideoItems[itemIndex] = item.pausedPreparation()

            logger.info(
                "video.prepare.paused",
                category: .video,
                message: "已暂停准备所选视频",
                context: videoPreparationContext(itemIndex: itemIndex, video: item.video),
            )
        }

        @MainActor
        private func cancelPreparationTasks(excluding retainedItemIDs: Set<String> = []) {
            for itemID in Array(preparationTasks.keys) where !retainedItemIDs.contains(itemID) {
                preparationTasks[itemID]?.cancel()
                preparationTasks[itemID] = nil
                preparationRunIDs[itemID] = nil
            }
        }

        @MainActor
        private func prepareSelectedVideoItem(withID itemID: String, runID: UUID) async {
            defer {
                if preparationRunIDs[itemID] == runID {
                    preparationTasks[itemID] = nil
                    preparationRunIDs[itemID] = nil
                }
            }

            guard let itemIndex = selectedVideoItems.firstIndex(where: { $0.id == itemID }) else {
                return
            }

            let item = selectedVideoItems[itemIndex]
            guard item.canPrepare || item.canResumePreparation, let video = item.video else {
                return
            }

            selectedVideoItems[itemIndex] = item.resumedPreparation()

            logger.info(
                "video.prepare.started",
                category: .video,
                message: "开始准备所选视频",
                context: videoPreparationContext(itemIndex: itemIndex, video: video),
            )

            do {
                let asset = try photoLibraryAssetProvider.photoAsset(with: video.id)
                _ = try await photoLibraryAssetProvider.requestAVAsset(
                    for: asset,
                    deliveryQuality: .high,
                    progressHandler: { progress in
                        Task { @MainActor in
                            updatePreparationProgress(for: itemID, runID: runID, progress: progress)
                        }
                    },
                )

                updatePreparationProgress(for: itemID, runID: runID, progress: 1)

                guard preparationRunIDs[itemID] == runID else {
                    return
                }
                guard let latestIndex = selectedVideoItems.firstIndex(where: { $0.id == itemID }),
                      let availableItem = selectedVideoItems[latestIndex].availableAfterPreparation()
                else {
                    return
                }

                selectedVideoItems[latestIndex] = availableItem
                selectedVideos = selectedVideoItems.compactMap(\.video)

                logger.info(
                    "video.prepare.succeeded",
                    category: .video,
                    message: "所选视频已准备完成",
                    context: videoPreparationContext(itemIndex: latestIndex, video: video),
                )
            } catch {
                guard preparationRunIDs[itemID] == runID,
                      !(error is CancellationError)
                else {
                    return
                }

                guard let latestIndex = selectedVideoItems.firstIndex(where: { $0.id == itemID }) else {
                    return
                }

                selectedVideoItems[latestIndex] = .unavailable(
                    id: item.id,
                    title: item.title,
                    video: video,
                    reason: .notReady,
                    thumbnailData: item.thumbnailData,
                )
                selectedVideos = selectedVideoItems.compactMap(\.video)
                alert = HighlightFlowAlert(
                    title: "准备失败",
                    message: "视频暂时没有准备好。请确认网络可用后再试。",
                )

                logger.warning(
                    "video.prepare.failed",
                    category: .video,
                    message: "所选视频准备失败",
                    context: videoPreparationContext(
                        itemIndex: latestIndex,
                        video: video,
                        extra: [
                            "errorCategory": Self.videoPreparationErrorCategory(error),
                        ],
                    ),
                )
            }
        }

        @MainActor
        private func updatePreparationProgress(for itemID: String, runID: UUID, progress: Double) {
            guard preparationRunIDs[itemID] == runID else {
                return
            }

            guard let itemIndex = selectedVideoItems.firstIndex(where: { $0.id == itemID }) else {
                return
            }

            let item = selectedVideoItems[itemIndex]
            guard item.isPreparing else {
                return
            }

            selectedVideoItems[itemIndex] = item.preparing(progress: progress)
        }

        @MainActor
        private func loadSelectedVideos(from items: [PhotosPickerItem]) async {
            guard !items.isEmpty else { return }
            let revision = UUID()
            selectionLoadRevision = revision
            isLoadingVideos = true
            defer { if selectionLoadRevision == revision { isLoadingVideos = false } }
            for item in items {
                guard selectionLoadRevision == revision else { return }
                if let id = item.itemIdentifier,
                   selectedVideoItems.contains(where: { $0.video?.reviewSourceIdentity == .photoLibraryAsset(id) }) { continue }
                guard selectedVideoItems.count < 20 else { break }
                let loaded = await loadSelectedVideoItem(from: item, at: selectedVideoItems.count)
                guard selectionLoadRevision == revision else {
                    if let video = loaded.video { cleanupTemporaryVideos([video]) }
                    return
                }
                if !selectedVideoItems.contains(where: { $0.video?.reviewSourceIdentity != nil && $0.video?.reviewSourceIdentity == loaded.video?.reviewSourceIdentity }) {
                    selectedVideoItems.append(loaded)
                } else if let video = loaded.video { cleanupTemporaryVideos([video]) }
            }
            selectedVideos = selectedVideoItems.compactMap(\.video)
            selectedItems = []
            reportVideoSelectionResultsIfNeeded(selectedVideoItems)
        }

        @MainActor
        private func prepareReview() async {
            guard !isPreparingReview, let manager = highlightTaskManager else { return }
            isPreparingReview = true
            availabilityTask?.cancel()
            availabilityTask = nil
            defer { isPreparingReview = false }
            let videos = selectedVideoItems.compactMap(\.video)
            do {
                var notice: String?
                let task: HighlightTask
                if let baseline = taskBaseline {
                    let result = try await manager.updateConfiguration(taskID: baseline.id,
                        expectedRevision: baseline.configurationRevision, selectedVideos: videos, settings: clipSettings.normalized)
                    guard let updated = manager.task(baseline.id) else { throw HighlightTaskError.notFound }
                    task = updated
                    if result.resetConfirmationCount > 0 {
                        notice = "视频变化后，\(result.resetConfirmationCount) 个已确认片段已恢复为默认范围。"
                    }
                } else {
                    task = try await manager.createTask(id: creationID, session: session,
                        selectedVideos: videos, settings: clipSettings.normalized)
                }
                taskBaseline = task
                reviewSession?.release()
                reviewSession = try HighlightReviewSession(task: task, manager: manager, notice: notice,
                    cleanupPreparation: { cleanupTemporaryVideos(videos) }, onExit: finishFlow)
                isReviewPresented = true
            } catch {
                alert = HighlightFlowAlert(title: "无法准备片段审核", message: (error as? LocalizedError)?.errorDescription ?? "无法保存任务，请重试。")
            }
        }

        private var hasConfigurationChanges: Bool {
            guard let taskBaseline, let highlightTaskManager else { return false }
            let media = HighlightTaskMedia(fileStore: highlightTaskManager.fileStore)
            let original = taskBaseline.videos.compactMap { try? media.selectionVideo(for: $0) }
            return original != selectedVideoItems.compactMap(\.video) || taskBaseline.clipSettings != clipSettings.normalized
        }

        @ViewBuilder
        private var currentOutputSection: some View {
            if let taskBaseline, let manager = highlightTaskManager, let task = manager.task(taskBaseline.id), task.currentOutput != nil {
                Section("当前成片") {
                    if task.outputIsOutdated { Text("当前成片不包含最新修改").foregroundStyle(.secondary) }
                    Button("播放当前成片") {
                        do { outputPlaybackURL = try manager.playbackURL(taskID: task.id) }
                        catch { alert = HighlightFlowAlert(title: "无法播放", message: error.localizedDescription) }
                    }
                    Button("保存到相册") {
                        Task {
                            do { try await manager.saveToPhotoLibrary(taskID: task.id) }
                            catch { alert = HighlightFlowAlert(title: "无法保存", message: "请检查照片权限和可用空间后重试。") }
                        }
                    }.disabled(manager.photoSavingTaskIDs.contains(task.id))
                }
            }
        }

        private func finishFlow() {
            cancelPreparationTasks()
            selectionLoadRevision = UUID()
            selectionTask?.cancel()
            availabilityTask?.cancel()
            selectionTask = nil
            availabilityTask = nil
            reviewSession?.release()
            cleanupTemporaryVideos(selectedVideoItems.compactMap(\.video))
            isReviewPresented = false
            reviewSession = nil
            if let onExit { onExit() } else { dismiss() }
        }

        private func cleanupAfterWholeFlowDisappearsIfNeeded() {
            availabilityTask?.cancel()
            availabilityTask = nil
            guard !isReviewPresented else { return }
            cancelPreparationTasks()
            selectionLoadRevision = UUID()
            selectionTask?.cancel()
            availabilityTask?.cancel()
            selectionTask = nil
            availabilityTask = nil
            reviewSession?.release()
            cleanupTemporaryVideos(selectedVideoItems.compactMap(\.video))
        }

        private func moveVideo(at index: Int, by offset: Int) {
            let destination = index + offset
            guard selectedVideoItems.indices.contains(destination) else { return }
            selectedVideoItems.swapAt(index, destination)
            selectedVideos = selectedVideoItems.compactMap(\.video)
        }

        private func removeVideo(at index: Int) {
            let item = selectedVideoItems.remove(at: index)
            preparationTasks[item.id]?.cancel()
            preparationTasks[item.id] = nil
            preparationRunIDs[item.id] = nil
            if let video = item.video { cleanupTemporaryVideos([video]) }
            selectedVideos = selectedVideoItems.compactMap(\.video)
        }

        private func refreshExistingVideoAvailability() async {
            guard let taskBaseline, let manager = highlightTaskManager else { return }
            let revision = selectionLoadRevision
            let media = HighlightTaskMedia(fileStore: manager.fileStore)
            for video in taskBaseline.videos {
                guard !Task.isCancelled, revision == selectionLoadRevision,
                      let selected = try? media.selectionVideo(for: video),
                      let index = selectedVideoItems.firstIndex(where: { $0.video?.reviewSourceIdentity == video.sourceIdentity }) else { continue }
                let original = selectedVideoItems[index]
                do {
                    let asset = try await media.asset(for: video)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = .init(width: 320, height: 180)
                    let image = try? await generator.image(at: .zero).image
                    guard !Task.isCancelled, revision == selectionLoadRevision,
                          let current = selectedVideoItems.firstIndex(where: { $0.id == original.id }) else { continue }
                    selectedVideoItems[current] = .available(id: original.id, title: original.title, video: selected,
                        thumbnailData: image.flatMap { UIImage(cgImage: $0).jpegData(compressionQuality: 0.72) })
                } catch {
                    guard !Task.isCancelled, revision == selectionLoadRevision,
                          let current = selectedVideoItems.firstIndex(where: { $0.id == original.id }) else { continue }
                    selectedVideoItems[current] = .unavailable(id: original.id, title: original.title,
                        video: selected, reason: error as? HighlightVideoSelectionError == .videoNotReady ? .notReady : .failedToLoad, thumbnailData: nil)
                }
            }
        }

        private func importVideoFiles(_ result: Result<[URL], Error>) async {
            guard case .success(let urls) = result else { return }
            let revision = UUID()
            selectionLoadRevision = revision
            isLoadingVideos = true
            defer { if selectionLoadRevision == revision { isLoadingVideos = false } }
            for url in urls.prefix(max(0, 20 - selectedVideoItems.count)) {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("ShotMarker-TrainingVideo-\(UUID()).\(url.pathExtension)")
                do {
                    try FileManager.default.copyItem(at: url, to: copy)
                    let metadata = try await temporaryFileStore.metadata(from: copy)
                    let digest = try await HighlightClipReviewContentHasher().sha256(for: copy)
                    let video = SelectedTrainingVideo(id: copy.absoluteString, recordedStartAt: metadata.recordedStartAt,
                        duration: metadata.duration, reviewSourceIdentity: .fileSHA256(digest))
                    if selectedVideoItems.contains(where: { $0.video?.reviewSourceIdentity == video.reviewSourceIdentity }) {
                        temporaryFileStore.removeTemporaryVideo(at: copy)
                        continue
                    }
                    let thumbnail = await temporaryFileStore.thumbnailData(from: copy)
                    try Task.checkCancellation()
                    guard selectionLoadRevision == revision else {
                        temporaryFileStore.removeTemporaryVideo(at: copy)
                        return
                    }
                    selectedVideoItems.append(.available(id: video.id, title: "视频 \(selectedVideoItems.count + 1)",
                        video: video, thumbnailData: thumbnail))
                } catch {
                    temporaryFileStore.removeTemporaryVideo(at: copy)
                    if error is CancellationError { return }
                    alert = HighlightFlowAlert(title: "无法导入视频", message: "视频需要包含有效的拍摄时间和时长。请检查文件后重试。")
                }
            }
            selectedVideos = selectedVideoItems.compactMap(\.video)
        }

        private func highlightContext(extra: [String: String] = [:]) -> [String: String] {
            var context = [
                "totalMarkerCount": "\(session.markerCount)",
            ]
            context.merge(extra) { _, newValue in newValue }
            return context
        }

        private func highlightPlanContext(
            _ plan: HighlightClipPlan,
            extra: [String: String] = [:],
        ) -> [String: String] {
            highlightContext(extra: [
                "selectedVideoCount": "\(plan.selectedVideoCount)",
                "matchedMarkerCount": "\(plan.matchedMarkerCount)",
                "unmatchedMarkerCount": "\(plan.unmatchedMarkerCount)",
                "segmentCount": "\(plan.segments.count)",
            ].merging(extra) { _, newValue in newValue })
        }

        private func videoPreparationContext(
            itemIndex: Int,
            video: SelectedTrainingVideo?,
            extra: [String: String] = [:],
        ) -> [String: String] {
            highlightContext(extra: [
                "itemIndex": "\(itemIndex + 1)",
                "source": Self.sourceCategory(for: video),
            ].merging(extra) { _, newValue in newValue })
        }

        @MainActor
        private func loadSelectedVideoItem(
            from item: PhotosPickerItem,
            at index: Int,
        ) async -> SelectedTrainingVideoSelectionItem {
            let title = "视频 \(index + 1)"
            let fallbackID = "selection-\(index + 1)"
            return await videoLoadingService.loadSelectionItem(
                from: item,
                title: title,
                fallbackID: fallbackID,
                session: session,
            )
        }

        private func reportVideoSelectionResultsIfNeeded(_ selectionItems: [SelectedTrainingVideoSelectionItem]) {
            let unavailableItems = selectionItems.filter { !$0.isAvailable }
            guard !unavailableItems.isEmpty else {
                return
            }

            let countByReason = Dictionary(grouping: unavailableItems.compactMap(\.unavailableReason)) { $0 }
                .mapValues(\.count)

            logger.info(
                "video.selection.filtered",
                category: .video,
                message: "已过滤不可用视频",
                context: highlightContext(extra: [
                    "requestedItemCount": "\(selectionItems.count)",
                    "retainedVideoCount": "\(selectionItems.availableVideos.count)",
                    "filteredVideoCount": "\(unavailableItems.count)",
                    "failedToLoadCount": "\(countByReason[.failedToLoad, default: 0])",
                    "missingRecordedStartAtCount": "\(countByReason[.missingRecordedStartAt, default: 0])",
                    "invalidDurationCount": "\(countByReason[.invalidDuration, default: 0])",
                    "notReadyCount": "\(countByReason[.notReady, default: 0])",
                    "noMarkerCoverageCount": "\(countByReason[.noMarkerCoverage, default: 0])",
                    "photoLibraryAccessDeniedCount": "\(countByReason[.photoLibraryAccessDenied, default: 0])",
                ]),
            )
        }

        private func cleanupTemporaryVideos(_ videos: [SelectedTrainingVideo]) {
            let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
            temporaryFileStore.cleanupTemporaryVideos(videos.filter {
                guard let url = URL(string: $0.id), url.isFileURL else { return false }
                return url.resolvingSymlinksInPath().path.hasPrefix(temporaryRoot)
                    && url.lastPathComponent.hasPrefix("ShotMarker-TrainingVideo-")
            })
        }

        private nonisolated static func sourceCategory(
            for video: SelectedTrainingVideo?,
        ) -> String {
            guard let video else {
                return "unknown"
            }
            if let url = URL(string: video.id), url.isFileURL {
                return "pickerFile"
            }
            return "photoLibrary"
        }

        private nonisolated static func videoPreparationErrorCategory(_ error: Error) -> String {
            error is CancellationError ? "cancelled" : "assetPreparationFailed"
        }

        private nonisolated static func secondsString(_ value: TimeInterval) -> String {
            String(format: "%.3f", value)
        }
    }

    private struct HighlightFlowAlert {
        let title: String
        let message: String
    }

    #if DEBUG
        #Preview {
            NavigationStack {
                TrainingSessionHighlightView(
                    session: TrainingSession.previewSessions[0],
                    reviewStore: InMemoryHighlightClipReviewStore(),
                )
            }
        }
    #endif
#endif
