#if os(iOS)
    import Foundation
    import Photos

    struct VideoClipPhotoLibrarySaver {
        private let requestAuthorization: () async -> PHAuthorizationStatus
        private let saveVideoToLibrary: (URL) async throws -> Void
        private let logger: AppLogging

        init(
            requestAuthorization: @escaping () async -> PHAuthorizationStatus = {
                await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            },
            saveVideoToLibrary: @escaping (URL) async throws -> Void = { videoURL in
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
                }
            },
            logger: AppLogging = AppLogger.shared,
        ) {
            self.requestAuthorization = requestAuthorization
            self.saveVideoToLibrary = saveVideoToLibrary
            self.logger = logger
        }

        func saveVideo(at videoURL: URL) async throws {
            logger.info(
                "photos.save.authorization.requested",
                category: .photos,
                message: "请求相册保存权限",
            )
            let status = await requestAuthorization()
            guard status == .authorized || status == .limited else {
                logger.warning(
                    "photos.save.authorization.denied",
                    category: .photos,
                    message: "相册保存权限被拒绝",
                    context: ["authorizationStatus": status.logDescription],
                )
                throw VideoClipPhotoLibraryError.accessDenied
            }

            do {
                try await saveVideoToLibrary(videoURL)
                logger.info(
                    "photos.save.succeeded",
                    category: .photos,
                    message: "视频已保存到相册",
                    context: ["authorizationStatus": status.logDescription],
                )
            } catch {
                logger.error(
                    "photos.save.failed",
                    category: .photos,
                    message: "视频保存到相册失败",
                    error: VideoClipPhotoLibraryError.saveFailed,
                    context: ["authorizationStatus": status.logDescription, "errorCategory": "saveFailed"],
                )
                throw error
            }
        }
    }

    enum VideoClipPhotoLibraryError: LocalizedError {
        case accessDenied
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .accessDenied: "没有相册保存权限。请允许 ShotMarker 添加照片后再试。"
            case .saveFailed: "无法保存到相册，请重试。"
            }
        }
    }

    enum PhotoLibraryVideoAccessError: LocalizedError, Equatable {
        case networkUnavailable

        var errorDescription: String? {
            switch self {
            case .networkUnavailable:
                "无法从 iCloud 读取所选视频。请确认网络可用，或先在照片 App 打开这个视频让它下载完成后再试。"
            }
        }
    }

    enum PhotoLibraryVideoAccess {
        private static let networkErrorCode = 3169

        static func shouldFallbackToPickerFile(for error: Error) -> Bool {
            isPhotoLibraryNetworkError(error)
        }

        static func userFacingError(for error: Error) -> Error {
            if isPhotoLibraryNetworkError(error) {
                return PhotoLibraryVideoAccessError.networkUnavailable
            }

            return error
        }

        private static func isPhotoLibraryNetworkError(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == PHPhotosErrorDomain && nsError.code == networkErrorCode
        }
    }

    private extension PHAuthorizationStatus {
        var logDescription: String {
            switch self {
            case .notDetermined:
                "notDetermined"
            case .restricted:
                "restricted"
            case .denied:
                "denied"
            case .authorized:
                "authorized"
            case .limited:
                "limited"
            @unknown default:
                "unknown"
            }
        }
    }
#endif
