#if DEBUG
    import AVFoundation
    import Combine
    import SwiftUI

    struct HighlightClipConfirmationUITestHarnessView: View {
        @StateObject private var harnessState: HighlightClipConfirmationUITestHarnessState
        @StateObject private var reviewViewModel: HighlightClipReviewViewModel

        init() {
            let harnessState = HighlightClipConfirmationUITestHarnessState()
            _harnessState = StateObject(wrappedValue: harnessState)
            _reviewViewModel = StateObject(
                wrappedValue: Self.makeReviewViewModel(harnessState: harnessState),
            )
        }

        var body: some View {
            if ProcessInfo.processInfo.environment["SHOTMARKER_UI_TEST_CLIP_MEDIA"] == "1" {
                HighlightClipMediaUITestHarnessView()
            } else {
                gallery
            }
        }

        private var gallery: some View {
            NavigationStack {
                HighlightClipReviewView(
                    viewModel: reviewViewModel,
                    makePlaybackController: {
                        HighlightClipPlaybackController { _ in
                            AVMutableComposition()
                        }
                    },
                    loadsMedia: false,
                )
            }
            .overlay(alignment: .top) {
                if let submissionMessage = harnessState.submissionMessage {
                    Text(submissionMessage)
                        .padding(10)
                        .background(.regularMaterial, in: Capsule())
                        .accessibilityIdentifier("ClipConfirmationSubmissionStatus")
                }
            }
        }

        @MainActor
        private static func makeReviewViewModel(
            harnessState: HighlightClipConfirmationUITestHarnessState,
        ) -> HighlightClipReviewViewModel {
            let video = SelectedTrainingVideo(
                id: "ui-test-video",
                recordedStartAt: Date(timeIntervalSince1970: 100_000),
                duration: 90,
                reviewSourceIdentity: .photoLibraryAsset("ui-test-asset"),
            )
            let items = [
                makeItem(number: 1, videoID: video.id, start: 5),
                makeItem(
                    number: 2,
                    videoID: video.id,
                    start: 20,
                    confirmationState: .confirmed,
                ),
                makeItem(number: 3, videoID: video.id, start: 35),
                makeItem(
                    number: 4,
                    videoID: video.id,
                    start: 50,
                    isIncluded: false,
                    confirmationState: .confirmed,
                ),
                makeItem(
                    number: 5,
                    videoID: video.id,
                    start: 65,
                    isIncluded: false,
                    confirmationState: .confirmed,
                ),
            ]
            let session = TrainingSession(
                id: fixedUUID(80_001),
                startedAt: video.recordedStartAt,
                endedAt: video.recordedEndAt,
                events: items.flatMap(\.markerReferences).map {
                    ShotMarkerEvent(id: $0.id, markedAt: $0.markedAt)
                },
            )
            let reviewStore = InMemoryHighlightClipReviewStore()
            let viewModel = HighlightClipReviewViewModel(
                draft: HighlightClipReviewDraft(
                    selectedVideoCount: 1,
                    totalMarkerCount: items.count,
                    items: items,
                ),
                videos: [video],
                clipSettings: .default,
                combinationKey: try! HighlightClipReviewIdentityBuilder.combinationKey(
                    for: session,
                    videos: [video],
                ),
                reviewStore: reviewStore,
                mediaProvider: HighlightClipReviewMediaProvider(
                    cacheLimit: 0,
                    loadAsset: { _ in AVMutableComposition() },
                    generateFrame: { _, _ in Data() },
                ),
                submitSegments: { _ in
                    harnessState.submissionMessage = "任务已创建"
                },
            )
            viewModel.markSourceUnavailable(itemID: items[4].id)
            return viewModel
        }

        private static func makeItem(
            number: Int,
            videoID: String,
            start: TimeInterval,
            isIncluded: Bool = true,
            confirmationState: HighlightClipConfirmationState = .defaultValue,
        ) -> HighlightClipReviewItem {
            let marker = HighlightClipMarkerReference(
                id: fixedUUID(81_000 + number),
                markedAt: Date(timeIntervalSince1970: 100_000 + start + 2),
                timeInVideo: start + 2,
                originalMatchedNumber: number,
            )
            return HighlightClipReviewItem(
                id: fixedUUID(82_000 + number),
                videoID: videoID,
                markerReferences: [marker],
                defaultStart: start,
                defaultDuration: 4,
                start: start,
                duration: 4,
                isIncluded: isIncluded,
                confirmationState: confirmationState,
            )
        }

        private static func fixedUUID(_ suffix: Int) -> UUID {
            UUID(
                uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix),
            )!
        }
    }

    @MainActor
    private final class HighlightClipConfirmationUITestHarnessState: ObservableObject {
        @Published var submissionMessage: String?
    }
#endif
