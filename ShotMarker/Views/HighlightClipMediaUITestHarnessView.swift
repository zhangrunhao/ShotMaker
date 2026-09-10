#if DEBUG
    import AVFoundation
    import SwiftUI

    /// Real task persistence, navigation, playback and frame extraction for UI regression tests.
    struct HighlightClipMediaUITestHarnessView: View {
        @State private var session: HighlightReviewSession?
        @State private var preparationError: String?

        var body: some View {
            Group {
                if let session {
                    HighlightClipMediaUITestContent(session: session)
                } else if let preparationError {
                    Text(preparationError)
                } else {
                    ProgressView("正在准备测试视频…")
                }
            }
            .task {
                guard session == nil else { return }
                do {
                    session = try await makeSession()
                } catch {
                    preparationError = error.localizedDescription
                }
            }
        }

        @MainActor
        private func makeSession() async throws -> HighlightReviewSession {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("ShotMarker-ClipMediaUI-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let first = root.appendingPathComponent("landscape.mov")
            let second = root.appendingPathComponent("portrait.mov")
            try await makeVideo(at: first, width: 160, height: 90, duration: 720)
            try await makeVideo(at: second, width: 90, height: 160, duration: 40)
            let files = HighlightTaskFileStore(baseDirectory: root, temporaryDirectory: root.appendingPathComponent("tmp"))
            let media = HighlightTaskMedia(fileStore: files)
            let manager = HighlightTaskManager(
                store: HighlightTaskStore(fileURL: root.appendingPathComponent("tasks.json")),
                fileStore: files,
                runner: HighlightRenderRunner(assetForVideo: { video, _ in try await media.asset(for: video) }, logger: AppLogger.shared),
                validateSource: { video in _ = try await media.asset(for: video).load(.duration) },
            )
            let start = Date(timeIntervalSince1970: 100_000)
            let training = TrainingSession(startedAt: start, endedAt: start.addingTimeInterval(760),
                events: [10.0, 12, 14, 700.1, 750].map { ShotMarkerEvent(markedAt: start.addingTimeInterval($0)) })
            let videos = [
                SelectedTrainingVideo(id: first.absoluteString, recordedStartAt: start, duration: 720),
                SelectedTrainingVideo(id: second.absoluteString, recordedStartAt: start.addingTimeInterval(720), duration: 40),
            ]
            let task = try await manager.createTask(session: training, selectedVideos: videos, settings: .default)
            return try HighlightReviewSession(task: task, manager: manager)
        }

        private func makeVideo(at url: URL, width: Int, height: Int, duration: Int) async throws {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            ])
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            writer.add(input)
            guard writer.startWriting() else { throw HighlightClipReviewMediaError.assetLoadFailed }
            writer.startSession(atSourceTime: .zero)
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer
            else { throw HighlightClipReviewMediaError.assetLoadFailed }
            CVPixelBufferLockBaseAddress(buffer, [])
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for offset in stride(from: 0, to: CVPixelBufferGetDataSize(buffer), by: 4) {
                pixels[offset] = width > height ? 40 : 220
                pixels[offset + 1] = 100
                pixels[offset + 2] = width > height ? 220 : 40
                pixels[offset + 3] = 255
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            for second in 0..<duration {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
                guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(second), timescale: 1)) else {
                    throw HighlightClipReviewMediaError.assetLoadFailed
                }
            }
            writer.endSession(atSourceTime: CMTime(value: Int64(duration), timescale: 1))
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw HighlightClipReviewMediaError.assetLoadFailed }
        }
    }

    private struct HighlightClipMediaUITestContent: View {
        @ObservedObject var session: HighlightReviewSession

        var body: some View {
            NavigationStack {
                HighlightTaskReviewView(session: session, onExit: {})
            }
                .overlay(alignment: .topLeading) {
                    if let itemID = session.viewModel.editingItemID {
                        let frames = session.viewModel.filmstripFramesByItemID[itemID] ?? []
                        Text("\(frames.compactMap { $0 }.count)")
                            .font(.caption2)
                            .accessibilityIdentifier("ClipMediaLoadedFrameCount")
                            .allowsHitTesting(false)
                    }
                }
        }
    }
#endif
