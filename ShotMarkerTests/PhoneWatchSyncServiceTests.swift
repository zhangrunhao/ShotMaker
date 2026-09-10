@testable import ShotMarker
import WatchConnectivity
import XCTest

final class PhoneWatchSyncServiceTests: XCTestCase {
    func testCutoverAcknowledgesOldPayloadWithoutImportOrAnalytics() async throws {
        let payload = try makePayload()
        let importer = SpyTrainingSessionImporter()
        let analytics = SpyAnalyticsTracker()
        let connectivity = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(importer: importer, session: connectivity,
            analytics: analytics, dataCutoverAt: payload.endedAt)
        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))
        XCTAssertTrue(importer.importedPayloads.isEmpty)
        XCTAssertTrue(analytics.events.isEmpty)
        XCTAssertEqual(connectivity.transferredUserInfos.count, 1)
    }

    func testAfterCutoverPayloadImportsAndRecordsSuccess() async throws {
        let payload = try makePayload()
        let importer = SpyTrainingSessionImporter()
        let analytics = SpyAnalyticsTracker()
        let connectivity = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(importer: importer, session: connectivity,
            analytics: analytics, dataCutoverAt: payload.endedAt.addingTimeInterval(-0.001))
        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))
        XCTAssertEqual(importer.importedPayloads, [payload])
        XCTAssertEqual(analytics.events, [.trainingSyncSucceeded])
        XCTAssertEqual(connectivity.transferredUserInfos.count, 1)
    }

    func testStartActivatesSupportedSession() {
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: session,
        )

        service.start()

        XCTAssertEqual(session.setDelegateCallCount, 1)
        XCTAssertTrue(session.delegate === service)
        XCTAssertEqual(session.activateCallCount, 1)
    }

    func testStartLogsActivationRequested() {
        let logger = SpyAppLogger()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationStateDescription = "notActivated"
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: session,
            logger: logger,
        )

        service.start()

        let entry = logger.entry(named: "sync.session.activate.requested")
        XCTAssertEqual(entry?.level, .info)
        XCTAssertEqual(entry?.category, .sync)
        XCTAssertEqual(entry?.context["isSupported"], "true")
        XCTAssertEqual(entry?.context["isPaired"], "true")
        XCTAssertEqual(entry?.context["isWatchAppInstalled"], "true")
        XCTAssertEqual(entry?.context["activationState"], "notActivated")
    }

    func testStartDoesNotActivateUnsupportedSession() {
        let session = FakePhoneWatchConnectivitySession(isSupported: false)
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: session,
        )

        service.start()

        XCTAssertEqual(session.setDelegateCallCount, 0)
        XCTAssertEqual(session.activateCallCount, 0)
    }

    func testStartLogsUnsupportedSession() {
        let logger = SpyAppLogger()
        let session = FakePhoneWatchConnectivitySession(isSupported: false)
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: session,
            logger: logger,
        )

        service.start()

        let entry = logger.entry(named: "sync.session.unsupported")
        XCTAssertEqual(entry?.level, .warning)
        XCTAssertEqual(entry?.category, .sync)
        XCTAssertEqual(entry?.context["isSupported"], "false")
    }

    func testAckWaitsForTrainingImportAndReviewCleanupCompletion() async throws {
        let importer = GatedTrainingSessionImporter()
        let connectivity = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(
            importer: importer,
            session: connectivity,
            analytics: SpyAnalyticsTracker(),
        )

        let userInfo = try makeCompletedTrainingSessionUserInfo(payload: makePayload())
        async let handling: Void = service.handleReceivedUserInfo(userInfo)
        await importer.waitUntilEntered()
        XCTAssertTrue(connectivity.transferredUserInfos.isEmpty)

        await importer.release()
        await handling

        XCTAssertEqual(connectivity.transferredUserInfos.count, 1)
        XCTAssertEqual(
            connectivity.transferredUserInfos[0][PhoneWatchSyncService.userInfoTypeKey] as? String,
            PhoneWatchSyncService.trainingSessionSyncAckUserInfoType,
        )
    }

    func testCompletedTrainingSessionUserInfoImportsPostsNotificationAndTransfersAck() async throws {
        let payload = try makePayload()
        let importer = SpyTrainingSessionImporter()
        let analytics = SpyAnalyticsTracker()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        let notificationCenter = NotificationCenter()
        let notificationExpectation = expectation(description: "training sessions did change")
        let observer = notificationCenter.addObserver(
            forName: .trainingSessionsDidChange,
            object: nil,
            queue: .main,
        ) { _ in
            notificationExpectation.fulfill()
        }
        defer {
            notificationCenter.removeObserver(observer)
        }
        let service = PhoneWatchSyncService(
            importer: importer,
            session: session,
            notificationCenter: notificationCenter,
            analytics: analytics,
            now: { Date(timeIntervalSince1970: 20000) },
        )

        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))

        await fulfillment(of: [notificationExpectation], timeout: 1)
        XCTAssertEqual(importer.importedPayloads, [payload])
        XCTAssertEqual(analytics.events, [.trainingSyncSucceeded])
        XCTAssertEqual(session.transferredUserInfos.count, 1)
        let ackUserInfo = try XCTUnwrap(session.transferredUserInfos.first)
        XCTAssertEqual(
            ackUserInfo[PhoneWatchSyncService.userInfoTypeKey] as? String,
            PhoneWatchSyncService.trainingSessionSyncAckUserInfoType,
        )
        let ackData = try XCTUnwrap(ackUserInfo[PhoneWatchSyncService.userInfoPayloadKey] as? Data)
        XCTAssertEqual(
            try JSONDecoder().decode(TrainingSessionSyncAckPayload.self, from: ackData),
            TrainingSessionSyncAckPayload(
                trainingSessionId: payload.id,
                importedAt: Date(timeIntervalSince1970: 20000),
            ),
        )
    }

    func testDuplicateCompletedTrainingSessionUserInfoImportsAndAcksEachArrival() async throws {
        let payload = try makePayload()
        let importer = SpyTrainingSessionImporter()
        let analytics = SpyAnalyticsTracker()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(
            importer: importer,
            session: session,
            analytics: analytics,
        )
        let userInfo = try makeCompletedTrainingSessionUserInfo(payload: payload)

        await service.handleReceivedUserInfo(userInfo)
        await service.handleReceivedUserInfo(userInfo)

        XCTAssertEqual(importer.importedPayloads, [payload, payload])
        XCTAssertEqual(session.transferredUserInfos.count, 2)
        XCTAssertEqual(
            analytics.events,
            [.trainingSyncSucceeded, .trainingSyncSucceeded],
        )
    }

    func testSuccessfulSyncImportsThenTracksThenTransfersAck() async throws {
        let recorder = SyncOperationRecorder()
        let importer = SpyTrainingSessionImporter(
            onImport: { recorder.record(.imported) },
        )
        let analytics = OrderRecordingAnalyticsTracker(recorder: recorder)
        let session = FakePhoneWatchConnectivitySession(
            isSupported: true,
            onTransferUserInfo: { recorder.record(.ackTransferred) },
        )
        let service = PhoneWatchSyncService(
            importer: importer,
            session: session,
            analytics: analytics,
        )

        await service.handleReceivedUserInfo(
            try makeCompletedTrainingSessionUserInfo(payload: makePayload()),
        )

        XCTAssertEqual(
            recorder.operations,
            [.imported, .tracked(.trainingSyncSucceeded), .ackTransferred],
        )
    }

    func testCompletedTrainingSessionUserInfoLogsCountsWithoutTrainingIdentity() async throws {
        let payload = try makePayload()
        let logger = SpyAppLogger()
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: FakePhoneWatchConnectivitySession(isSupported: true),
            logger: logger,
        )

        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))

        XCTAssertEqual(logger.entry(named: "sync.training.payload.received")?.level, .info)
        XCTAssertEqual(logger.entry(named: "sync.training.payload.received")?.context[
            "trainingMarkerCount"
        ], "\(payload.events.count)")
        XCTAssertNil(logger.entry(named: "sync.training.payload.received")?.context[
            "trainingSessionId"
        ])
        XCTAssertEqual(logger.entry(named: "sync.training.import.succeeded")?.level, .info)
        XCTAssertEqual(logger.entry(named: "sync.training.import.succeeded")?.context[
            "trainingMarkerCount"
        ], "\(payload.events.count)")
        XCTAssertNil(logger.entry(named: "sync.training.import.succeeded")?.context[
            "trainingSessionId"
        ])
        XCTAssertEqual(logger.entry(named: "sync.training.ack.sent")?.level, .info)
        XCTAssertEqual(logger.entry(named: "sync.training.ack.sent")?.context[
            "trainingMarkerCount"
        ], "\(payload.events.count)")
        XCTAssertNil(logger.entry(named: "sync.training.ack.sent")?.context[
            "trainingSessionId"
        ])
    }

    func testUnknownUserInfoTypeDoesNothing() async throws {
        let importer = SpyTrainingSessionImporter()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(importer: importer, session: session)

        await service.handleReceivedUserInfo([
            PhoneWatchSyncService.userInfoTypeKey: "unknown",
            PhoneWatchSyncService.userInfoPayloadKey: Data(),
        ])

        XCTAssertEqual(importer.importedPayloads, [])
        XCTAssertEqual(session.transferredUserInfos.count, 0)
    }

    func testUnknownUserInfoTypeLogsWarning() async throws {
        let logger = SpyAppLogger()
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: FakePhoneWatchConnectivitySession(isSupported: true),
            logger: logger,
        )

        await service.handleReceivedUserInfo([
            PhoneWatchSyncService.userInfoTypeKey: "unknown",
            PhoneWatchSyncService.userInfoPayloadKey: Data(),
        ])

        let entry = logger.entry(named: "sync.training.userinfo.ignored")
        XCTAssertEqual(entry?.level, .warning)
        XCTAssertEqual(entry?.category, .sync)
        XCTAssertEqual(entry?.context["receivedType"], "unknown")
    }

    func testInvalidPayloadDoesNotImportOrAck() async {
        let importer = SpyTrainingSessionImporter()
        let analytics = SpyAnalyticsTracker()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        let service = PhoneWatchSyncService(
            importer: importer,
            session: session,
            analytics: analytics,
        )

        await service.handleReceivedUserInfo([
            PhoneWatchSyncService.userInfoTypeKey: PhoneWatchSyncService.completedTrainingSessionUserInfoType,
            PhoneWatchSyncService.userInfoPayloadKey: Data("invalid".utf8),
        ])

        XCTAssertEqual(importer.importedPayloads, [])
        XCTAssertEqual(session.transferredUserInfos.count, 0)
        XCTAssertTrue(analytics.events.isEmpty)
    }

    func testInvalidPayloadLogsDecodeFailure() async {
        let logger = SpyAppLogger()
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: FakePhoneWatchConnectivitySession(isSupported: true),
            logger: logger,
        )

        await service.handleReceivedUserInfo([
            PhoneWatchSyncService.userInfoTypeKey: PhoneWatchSyncService.completedTrainingSessionUserInfoType,
            PhoneWatchSyncService.userInfoPayloadKey: Data("invalid".utf8),
        ])

        let entry = logger.entry(named: "sync.training.payload.decode.failed")
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.category, .sync)
        XCTAssertEqual(entry?.context["payloadByteCount"], "7")
        XCTAssertNotNil(entry?.errorDescription)
    }

    func testImportFailureDoesNotPostNotificationOrAck() async throws {
        let importer = SpyTrainingSessionImporter(error: SyncImportError.failed)
        let analytics = SpyAnalyticsTracker()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        let notificationCenter = NotificationCenter()
        let service = PhoneWatchSyncService(
            importer: importer,
            session: session,
            notificationCenter: notificationCenter,
            analytics: analytics,
        )
        let payload = try makePayload()

        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))

        XCTAssertEqual(importer.importedPayloads, [payload])
        XCTAssertEqual(session.transferredUserInfos.count, 0)
        XCTAssertTrue(analytics.events.isEmpty)
    }

    func testSuccessfulImportTracksEvenWhenAckTransferFails() async throws {
        let payload = try makePayload()
        let analytics = SpyAnalyticsTracker()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        session.transferUserInfoError = SyncAckError.failed
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: session,
            analytics: analytics,
        )

        await service.handleReceivedUserInfo(
            try makeCompletedTrainingSessionUserInfo(payload: payload),
        )

        XCTAssertEqual(analytics.events, [.trainingSyncSucceeded])
        XCTAssertTrue(session.transferredUserInfos.isEmpty)
    }

    func testImportFailureLogsError() async throws {
        let payload = try makePayload()
        let logger = SpyAppLogger()
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(error: SyncImportError.failed),
            session: FakePhoneWatchConnectivitySession(isSupported: true),
            logger: logger,
        )

        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))

        let entry = logger.entry(named: "sync.training.import.failed")
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.category, .sync)
        XCTAssertEqual(entry?.context["trainingMarkerCount"], "\(payload.events.count)")
        XCTAssertNil(entry?.context["trainingSessionId"])
        XCTAssertNotNil(entry?.errorDescription)
    }

    func testAckTransferFailureLogsError() async throws {
        let payload = try makePayload()
        let logger = SpyAppLogger()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        session.transferUserInfoError = SyncAckError.failed
        let service = PhoneWatchSyncService(
            importer: SpyTrainingSessionImporter(),
            session: session,
            logger: logger,
        )

        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))

        XCTAssertEqual(session.transferredUserInfos.count, 0)
        let entry = logger.entry(named: "sync.training.ack.failed")
        XCTAssertEqual(entry?.level, .error)
        XCTAssertEqual(entry?.category, .sync)
        XCTAssertEqual(entry?.context["trainingMarkerCount"], "\(payload.events.count)")
        XCTAssertNil(entry?.context["trainingSessionId"])
        XCTAssertNotNil(entry?.errorDescription)
    }

    func testDiagnosticsSnapshotIncludesSessionStateAndLastSuccessfulImport() async throws {
        let payload = try makePayload()
        let importer = SpyTrainingSessionImporter()
        let session = FakePhoneWatchConnectivitySession(isSupported: true)
        session.isPaired = true
        session.isWatchAppInstalled = true
        session.activationStateDescription = "activated"
        let service = PhoneWatchSyncService(
            importer: importer,
            session: session,
            now: { Date(timeIntervalSince1970: 20_000) },
        )

        await service.handleReceivedUserInfo(try makeCompletedTrainingSessionUserInfo(payload: payload))

        XCTAssertEqual(
            service.diagnosticsSnapshot(),
            PhoneWatchSyncDiagnosticsSnapshot(
                isSupported: true,
                isPaired: true,
                isWatchAppInstalled: true,
                activationState: "activated",
                lastActivationCompletedAt: nil,
                lastActivationErrorDescription: nil,
                lastReceivedPayloadAt: Date(timeIntervalSince1970: 20_000),
                lastReceivedTrainingSessionId: payload.id,
                lastImportErrorDescription: nil,
                lastAckSentAt: Date(timeIntervalSince1970: 20_000),
                lastAckTrainingSessionId: payload.id,
                lastAckErrorDescription: nil,
            ),
        )
    }

    private func makeCompletedTrainingSessionUserInfo(payload: TrainingSessionSyncPayload) throws -> [String: Any] {
        [
            PhoneWatchSyncService.userInfoTypeKey: PhoneWatchSyncService.completedTrainingSessionUserInfoType,
            PhoneWatchSyncService.userInfoPayloadKey: try JSONEncoder().encode(payload),
        ]
    }

    private func makePayload() throws -> TrainingSessionSyncPayload {
        TrainingSessionSyncPayload(
            id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000801")),
            startedAt: Date(timeIntervalSince1970: 10000),
            endedAt: Date(timeIntervalSince1970: 10600),
            events: [
                ShotMarkerEventSyncPayload(
                    id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000802")),
                    markedAt: Date(timeIntervalSince1970: 10120),
                ),
            ],
        )
    }
}

private enum SyncImportError: Error {
    case failed
}

private enum SyncAckError: Error {
    case failed
}

private struct SpyLogEntry {
    let level: AppLogLevel
    let category: AppLogCategory
    let name: String
    let message: String
    let context: [String: String]
    let errorDescription: String?
}

private final class SpyAppLogger: AppLogging {
    private(set) var entries: [SpyLogEntry] = []

    func debug(_ name: String, category: AppLogCategory, message: String, context: [String: String]) {
        append(level: .debug, category: category, name: name, message: message, context: context)
    }

    func info(_ name: String, category: AppLogCategory, message: String, context: [String: String]) {
        append(level: .info, category: category, name: name, message: message, context: context)
    }

    func warning(_ name: String, category: AppLogCategory, message: String, context: [String: String]) {
        append(level: .warning, category: category, name: name, message: message, context: context)
    }

    func error(
        _ name: String,
        category: AppLogCategory,
        message: String,
        error: Error?,
        context: [String: String],
    ) {
        append(
            level: .error,
            category: category,
            name: name,
            message: message,
            context: context,
            errorDescription: error.map { String(describing: $0) },
        )
    }

    func entry(named name: String) -> SpyLogEntry? {
        entries.first { $0.name == name }
    }

    private func append(
        level: AppLogLevel,
        category: AppLogCategory,
        name: String,
        message: String,
        context: [String: String],
        errorDescription: String? = nil,
    ) {
        entries.append(
            SpyLogEntry(
                level: level,
                category: category,
                name: name,
                message: message,
                context: context,
                errorDescription: errorDescription,
            ),
        )
    }
}

private final class SpyTrainingSessionImporter: TrainingSessionImporting {
    private let error: Error?
    private let onImport: () -> Void
    private(set) var importedPayloads: [TrainingSessionSyncPayload] = []

    init(error: Error? = nil, onImport: @escaping () -> Void = {}) {
        self.error = error
        self.onImport = onImport
    }

    func `import`(_ payload: TrainingSessionSyncPayload) async throws {
        onImport()
        importedPayloads.append(payload)

        if let error {
            throw error
        }
    }
}

private actor GatedTrainingSessionImporter: TrainingSessionImporting {
    private var entered = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func `import`(_: TrainingSessionSyncPayload) async throws {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class FakePhoneWatchConnectivitySession: PhoneWatchConnectivitySessionProtocol {
    let isSupported: Bool
    private let onTransferUserInfo: () -> Void
    var isPaired = false
    var isWatchAppInstalled = false
    var activationStateDescription = "notActivated"
    private(set) var setDelegateCallCount = 0
    private(set) var activateCallCount = 0
    private(set) var transferredUserInfos: [[String: Any]] = []
    var transferUserInfoError: Error?
    weak var delegate: WCSessionDelegate?

    init(isSupported: Bool, onTransferUserInfo: @escaping () -> Void = {}) {
        self.isSupported = isSupported
        self.onTransferUserInfo = onTransferUserInfo
    }

    func setDelegate(_ delegate: WCSessionDelegate) {
        setDelegateCallCount += 1
        self.delegate = delegate
    }

    func activate() {
        activateCallCount += 1
    }

    func transferUserInfo(_ userInfo: [String: Any]) throws {
        onTransferUserInfo()
        if let transferUserInfoError {
            throw transferUserInfoError
        }

        transferredUserInfos.append(userInfo)
    }
}

nonisolated private enum SyncOperation: Equatable, Sendable {
    case imported
    case tracked(AnalyticsEvent)
    case ackTransferred
}

nonisolated private final class SyncOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedOperations: [SyncOperation] = []

    var operations: [SyncOperation] {
        lock.withLock { storedOperations }
    }

    func record(_ operation: SyncOperation) {
        lock.withLock {
            storedOperations.append(operation)
        }
    }
}

nonisolated private final class OrderRecordingAnalyticsTracker: AnalyticsTracking, @unchecked Sendable {
    private let recorder: SyncOperationRecorder

    init(recorder: SyncOperationRecorder) {
        self.recorder = recorder
    }

    func track(_ event: AnalyticsEvent) {
        recorder.record(.tracked(event))
    }
}
