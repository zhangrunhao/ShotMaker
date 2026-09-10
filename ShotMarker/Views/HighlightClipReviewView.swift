import AVFoundation
import SwiftUI
import UIKit

struct HighlightClipReviewView: View {
    @ObservedObject var viewModel: HighlightClipReviewViewModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editorDestination: HighlightClipEditorDestination?

    private let makePlaybackController: () -> HighlightClipPlaybackController
    private let loadsMedia: Bool
    private let generationButtonTitle: String
    private let onRequestVideoReselection: () -> Void

    init(
        viewModel: HighlightClipReviewViewModel,
        makePlaybackController: @escaping () -> HighlightClipPlaybackController,
        loadsMedia: Bool = true,
        generationButtonTitle: String = "确认并生成",
        onRequestVideoReselection: @escaping () -> Void = {},
    ) {
        self.viewModel = viewModel
        self.makePlaybackController = makePlaybackController
        self.loadsMedia = loadsMedia
        self.generationButtonTitle = generationButtonTitle
        self.onRequestVideoReselection = onRequestVideoReselection
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18, pinnedViews: [.sectionHeaders]) {
                Section {
                    if let recoveryNoticeMessage = viewModel.recoveryNoticeMessage {
                        Label(
                            recoveryNoticeMessage,
                            systemImage: "exclamationmark.triangle",
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .accessibilityLabel(recoveryNoticeMessage)
                    }

                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(viewModel.items) { item in
                            thumbnailLoadingCard(for: item)
                        }
                    }
                    .padding(.horizontal)
                } header: {
                    summaryHeader
                }

                confirmationArea
                    .padding(.horizontal)
                    .padding(.bottom)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("审核集锦片段")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $editorDestination) { destination in
            HighlightClipEditorView(
                reviewViewModel: viewModel,
                editorViewModel: destination.editorViewModel,
                playbackController: destination.playbackController,
                loadsMedia: loadsMedia,
                onRequestVideoReselection: onRequestVideoReselection,
                onConfirmationNavigation: { navigation in
                    viewModel.cancelFilmstripLoading(itemID: destination.id)
                    destination.playbackController.reset()
                    switch navigation {
                    case .open(let itemID):
                        openEditor(itemID: itemID)
                    case .returnToReview:
                        editorDestination = nil
                        viewModel.closeEditor()
                    }
                },
            )
        }
        .onChange(of: editorDestination?.id) { previousID, currentID in
            guard let previousID, currentID == nil else {
                return
            }
            viewModel.closeEditor()
            guard loadsMedia else {
                return
            }
            Task { @MainActor in
                await viewModel.loadThumbnail(
                    itemID: previousID,
                    targetSize: .init(width: 360, height: 204),
                )
            }
        }
    }

    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: 14)]
        }
        return [GridItem(.adaptive(minimum: 160), spacing: 14)]
    }

    private var summaryHeader: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                summaryValue(
                    title: "保留打点",
                    value: "\(viewModel.summary.includedMarkerCount)",
                )
                summaryValue(
                    title: "排除打点",
                    value: "\(viewModel.summary.excludedMarkerCount)",
                )
            }
            GridRow {
                summaryValue(
                    title: "最终片段",
                    value: "\(viewModel.summary.finalSegmentCount)",
                )
                summaryValue(
                    title: "预计总时长",
                    value: durationText(viewModel.summary.totalDuration),
                )
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private func summaryValue(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    @ViewBuilder
    private func thumbnailLoadingCard(for item: HighlightClipReviewItem) -> some View {
        if loadsMedia {
            reviewCard(for: item)
                .task(id: ThumbnailLoadIdentity(viewModel: ObjectIdentifier(viewModel), range: item.range)) {
                    await viewModel.loadThumbnail(
                        itemID: item.id,
                        targetSize: .init(width: 360, height: 204),
                    )
                }
        } else {
            reviewCard(for: item)
        }
    }

    private struct ThumbnailLoadIdentity: Equatable {
        let viewModel: ObjectIdentifier
        let range: HighlightClipRange
    }

    private func reviewCard(for item: HighlightClipReviewItem) -> some View {
        let unavailable = viewModel.unavailableItemIDs.contains(item.id)
        let merging = viewModel.summary.mergingItemIDs.contains(item.id)
        let number = displayNumber(for: item)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Button {
                    openEditor(itemID: item.id)
                } label: {
                    Text(number)
                        .font(.headline.monospacedDigit())
                        .frame(minWidth: 44, minHeight: 44)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("片段 \(number)")
                .accessibilityHint("打开片段编辑")

                Spacer(minLength: 8)

                stateLabel(item: item, unavailable: unavailable)
            }

            Button {
                openEditor(itemID: item.id)
            } label: {
                VStack(alignment: .leading, spacing: 9) {
                    thumbnail(for: item)

                    HStack {
                        Label(durationText(item.duration), systemImage: "timer")
                            .font(.subheadline.monospacedDigit())
                        Spacer()
                        Label("编辑", systemImage: "slider.horizontal.3")
                            .font(.subheadline.weight(.semibold))
                    }

                    if merging {
                        Label("生成时将合并", systemImage: "arrow.triangle.merge")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    if unavailable {
                        Text(viewModel.itemErrorMessages[item.id] ?? "来源视频不可用")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(cardAccessibilityLabel(
                item: item,
                number: number,
                unavailable: unavailable,
                merging: merging,
            ))
            .accessibilityHint("打开片段编辑")
        }
        .padding(12)
        .background(
            item.isIncluded
                ? Color(uiColor: .secondarySystemGroupedBackground)
                : Color(uiColor: .systemGray5),
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    unavailable ? Color.red.opacity(0.75) : Color.clear,
                    lineWidth: 2,
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .foregroundStyle(item.isIncluded ? Color.primary : Color.secondary)
    }

    @ViewBuilder
    private func stateLabel(
        item: HighlightClipReviewItem,
        unavailable: Bool,
    ) -> some View {
        if unavailable {
            Label("视频不可用", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityValue("视频不可用")
        } else {
            switch (item.confirmationState, item.isIncluded) {
            case (.defaultValue, _):
                Label("默认", systemImage: "circle.dashed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue("默认")
            case (.confirmed, true):
                Label("已确认 · 保留", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue("已确认，保留")
            case (.confirmed, false):
                Label("已确认 · 排除", systemImage: "minus.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue("已确认，排除")
            }
        }
    }

    private func thumbnail(for item: HighlightClipReviewItem) -> some View {
        ZStack {
            Color.black
            switch viewModel.thumbnailStates[item.id] ?? .idle {
            case .loaded(let data):
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    thumbnailPlaceholder
                }
            case .loading:
                thumbnailPlaceholder
                ProgressView()
                    .tint(.white)
            case .idle, .placeholder:
                thumbnailPlaceholder
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityHidden(true)
    }

    private var thumbnailPlaceholder: some View {
        Color(uiColor: .secondarySystemFill)
            .overlay {
                Image(systemName: "film")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }

    private var confirmationArea: some View {
        VStack(spacing: 10) {
            if let submissionErrorMessage = viewModel.submissionErrorMessage {
                Text(submissionErrorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("生成失败，\(submissionErrorMessage)")
            }

            if let disabledReason {
                Text(disabledReason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { @MainActor in
                    await viewModel.submit()
                }
            } label: {
                HStack {
                    if viewModel.isSubmitting {
                        ProgressView()
                    }
                    Text(viewModel.isSubmitting ? "正在准备生成…" : generationButtonTitle)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canConfirm)
            .accessibilityHint(disabledReason ?? "使用当前审核结果创建集锦")
        }
        .padding()
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var disabledReason: String? {
        if viewModel.isSubmitting {
            return "正在创建集锦，请稍候。"
        }
        let includedItems = viewModel.items.filter(\.isIncluded)
        if includedItems.isEmpty || viewModel.summary.finalSegments.isEmpty {
            return "至少保留一个有效片段后才能生成。"
        }
        if includedItems.contains(where: { viewModel.unavailableItemIDs.contains($0.id) }) {
            return "有保留片段的来源视频不可用，请排除该片段或重新选择视频。"
        }
        if let planningErrorMessage = viewModel.planningErrorMessage {
            return planningErrorMessage
        }
        if let item = includedItems.first(where: { viewModel.itemErrorMessages[$0.id] != nil }) {
            return viewModel.itemErrorMessages[item.id]
        }
        return nil
    }

    private func openEditor(itemID: UUID) {
        guard let editorViewModel = viewModel.makeEditorViewModel(itemID: itemID) else {
            return
        }
        editorDestination = HighlightClipEditorDestination(
            id: itemID,
            editorViewModel: editorViewModel,
            playbackController: makePlaybackController(),
        )
    }

    private func displayNumber(for item: HighlightClipReviewItem) -> String {
        let range = item.isIncluded
            ? viewModel.summary.displayNumberRangesByItemID[item.id]
            : item.originalNumberRange
        guard let range else {
            return "—"
        }
        return range.lowerBound == range.upperBound
            ? "\(range.lowerBound)"
            : "\(range.lowerBound)–\(range.upperBound)"
    }

    private func cardAccessibilityLabel(
        item: HighlightClipReviewItem,
        number: String,
        unavailable: Bool,
        merging: Bool,
    ) -> String {
        var components = [
            "片段 \(number)",
            naturalDuration(item.duration),
            item.confirmationState == .confirmed ? "已确认状态" : "默认状态",
            item.isIncluded ? "保留" : "排除",
        ]
        if unavailable {
            components.append("视频不可用")
        }
        if merging {
            components.append("生成时将与相邻片段合并")
        }
        components.append("打开片段编辑")
        return components.joined(separator: "，")
    }

    private func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite else {
            return "—"
        }
        return String(format: "%.1fs", max(duration, 0))
    }

    private func naturalDuration(_ duration: TimeInterval) -> String {
        guard duration.isFinite else {
            return "时长不可用"
        }
        return "时长 \(max(duration, 0).formatted(.number.precision(.fractionLength(1)))) 秒"
    }
}

private struct HighlightClipEditorDestination: Identifiable, Hashable {
    let id: UUID
    let editorViewModel: HighlightClipEditorViewModel
    let playbackController: HighlightClipPlaybackController

    static func == (
        lhs: HighlightClipEditorDestination,
        rhs: HighlightClipEditorDestination,
    ) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

#if DEBUG
    @MainActor
    enum HighlightClipReviewPreviewFixtures {
        static func galleryViewModel(unavailable: Bool = false) -> HighlightClipReviewViewModel {
            let video = SelectedTrainingVideo(
                id: "preview-video",
                recordedStartAt: Date(timeIntervalSince1970: 100),
                duration: 60,
                reviewSourceIdentity: .photoLibraryAsset("preview-video"),
            )
            let items = [
                makeItem(number: 1, videoID: video.id, start: 5, duration: 4),
                makeItem(
                    number: 2,
                    videoID: video.id,
                    start: 9.5,
                    duration: 3,
                    state: .confirmed,
                ),
                makeItem(
                    number: 3,
                    videoID: video.id,
                    start: 20,
                    duration: 5,
                    included: false,
                    state: .confirmed,
                ),
                makeItem(
                    number: 4,
                    videoID: video.id,
                    start: 30,
                    duration: 4,
                    state: .confirmed,
                ),
            ]
            let viewModel = makeViewModel(items: items, video: video)
            viewModel.markSourceUnavailable(itemID: items[3].id)
            if unavailable {
                viewModel.markSourceUnavailable(itemID: items[0].id)
            }
            return viewModel
        }

        static func editorReviewViewModel() -> HighlightClipReviewViewModel {
            let video = SelectedTrainingVideo(
                id: "preview-video",
                recordedStartAt: Date(timeIntervalSince1970: 100),
                duration: 60,
                reviewSourceIdentity: .photoLibraryAsset("preview-video"),
            )
            let first = makeItem(number: 1, videoID: video.id, start: 2, duration: 2)
            let markerReferences: [HighlightClipMarkerReference] = [
                makePreviewMarker(suffix: 91_100, time: 12, number: 2),
                makePreviewMarker(suffix: 91_101, time: 14, number: 3),
                makePreviewMarker(suffix: 91_102, time: 16, number: 4),
            ]
            let editorItem = HighlightClipReviewItem(
                id: fixedUUID(91_000),
                videoID: video.id,
                markerReferences: markerReferences,
                defaultStart: 10,
                defaultDuration: 8,
                start: 10,
                duration: 8,
                isIncluded: true,
                confirmationState: .confirmed,
            )
            return makeViewModel(items: [first, editorItem], video: video)
        }

        static func editorViewModel(
            reviewViewModel: HighlightClipReviewViewModel,
        ) -> HighlightClipEditorViewModel {
            let item = reviewViewModel.items.last!
            return HighlightClipEditorViewModel(
                item: item,
                video: reviewViewModel.videos.first { $0.id == item.videoID }!,
                confirmWorkingCopy: { _ in .returnToReview },
            )
        }

        static func playbackController() -> HighlightClipPlaybackController {
            HighlightClipPlaybackController(
                engine: PreviewHighlightClipPlaybackEngine(),
                loadAsset: { _ in
                    throw HighlightClipReviewMediaError.assetLoadFailed
                },
            )
        }

        private static func makeViewModel(
            items: [HighlightClipReviewItem],
            video: SelectedTrainingVideo,
        ) -> HighlightClipReviewViewModel {
            let session = TrainingSession(
                id: fixedUUID(92_000),
                startedAt: video.recordedStartAt,
                endedAt: video.recordedEndAt,
                events: items.flatMap(\.markerReferences).map {
                    ShotMarkerEvent(id: $0.id, markedAt: $0.markedAt)
                },
            )
            return HighlightClipReviewViewModel(
                draft: HighlightClipReviewDraft(
                    selectedVideoCount: 1,
                    totalMarkerCount: items.reduce(0) { $0 + $1.markerReferences.count },
                    items: items,
                ),
                videos: [video],
                clipSettings: .default,
                combinationKey: try! HighlightClipReviewIdentityBuilder.combinationKey(
                    for: session,
                    videos: [video],
                ),
                reviewStore: InMemoryHighlightClipReviewStore(),
                mediaProvider: HighlightClipReviewMediaProvider(
                    cacheLimit: 0,
                    loadAsset: { _ in
                        throw HighlightClipReviewMediaError.assetLoadFailed
                    },
                    generateFrame: { _, _ in
                        throw HighlightClipReviewMediaError.frameUnavailable
                    },
                ),
                submitSegments: { _ in },
            )
        }

        private static func makeItem(
            number: Int,
            videoID: String,
            start: TimeInterval,
            duration: TimeInterval,
            included: Bool = true,
            state: HighlightClipConfirmationState = .defaultValue,
        ) -> HighlightClipReviewItem {
            let marker = HighlightClipMarkerReference(
                id: fixedUUID(90_100 + number),
                markedAt: Date(timeIntervalSince1970: 110 + Double(number * 4)),
                timeInVideo: 10 + Double(number * 4),
                originalMatchedNumber: number,
            )
            return HighlightClipReviewItem(
                id: fixedUUID(90_000 + number),
                videoID: videoID,
                markerReferences: [marker],
                defaultStart: start,
                defaultDuration: duration,
                start: start,
                duration: duration,
                isIncluded: included,
                confirmationState: state,
            )
        }

        private static func makePreviewMarker(
            suffix: Int,
            time: TimeInterval,
            number: Int,
        ) -> HighlightClipMarkerReference {
            HighlightClipMarkerReference(
                id: fixedUUID(suffix),
                markedAt: Date(timeIntervalSince1970: 100 + time),
                timeInVideo: time,
                originalMatchedNumber: number,
            )
        }

        private static func fixedUUID(_ suffix: Int) -> UUID {
            UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix),
            )!
        }
    }

    @MainActor
    private final class PreviewHighlightClipPlaybackEngine: HighlightClipPlaybackEngine {
        let player = AVPlayer()
        func replaceCurrentItem(with _: AVAsset) {}
        func clearCurrentItem() {}
        func play() {}
        func pause() {}
        func seek(to _: TimeInterval) async {}
        func addPeriodicTimeObserver(_: @escaping (TimeInterval) -> Void) -> Any { UUID() }
        func addBoundaryTimeObserver(at _: TimeInterval, _: @escaping () -> Void) -> Any { UUID() }
        func removeTimeObserver(_: Any) {}
    }

    #Preview("审核状态") {
        NavigationStack {
            HighlightClipReviewView(
                viewModel: HighlightClipReviewPreviewFixtures.galleryViewModel(),
                makePlaybackController: HighlightClipReviewPreviewFixtures.playbackController,
                loadsMedia: false,
            )
        }
    }

    #Preview("不可用占位") {
        NavigationStack {
            HighlightClipReviewView(
                viewModel: HighlightClipReviewPreviewFixtures.galleryViewModel(unavailable: true),
                makePlaybackController: HighlightClipReviewPreviewFixtures.playbackController,
                loadsMedia: false,
            )
        }
    }

    #Preview("最大动态字体") {
        NavigationStack {
            HighlightClipReviewView(
                viewModel: HighlightClipReviewPreviewFixtures.galleryViewModel(),
                makePlaybackController: HighlightClipReviewPreviewFixtures.playbackController,
                loadsMedia: false,
            )
            .environment(\.dynamicTypeSize, .accessibility5)
        }
    }
#endif
