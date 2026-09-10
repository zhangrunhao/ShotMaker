import Foundation
import WatchConnectivity

protocol PhoneWatchConnectivitySessionProtocol: AnyObject {
    var isSupported: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationStateDescription: String { get }

    func setDelegate(_ delegate: WCSessionDelegate)
    func activate()
    func transferUserInfo(_ userInfo: [String: Any]) throws
}

extension Notification.Name {
    static let trainingSessionsDidChange = Notification.Name("trainingSessionsDidChange")
}

struct PhoneWatchSyncDiagnosticsSnapshot: Equatable {
    let isSupported: Bool
    let isPaired: Bool
    let isWatchAppInstalled: Bool
    let activationState: String
    let lastActivationCompletedAt: Date?
    let lastActivationErrorDescription: String?
    let lastReceivedPayloadAt: Date?
    let lastReceivedTrainingSessionId: UUID?
    let lastImportErrorDescription: String?
    let lastAckSentAt: Date?
    let lastAckTrainingSessionId: UUID?
    let lastAckErrorDescription: String?
}

final class PhoneWatchSyncService: NSObject, WCSessionDelegate {
    static let userInfoTypeKey = "type"
    static let userInfoPayloadKey = "payload"
    static let completedTrainingSessionUserInfoType = "completedTrainingSession"
    static let trainingSessionSyncAckUserInfoType = "trainingSessionSyncAck"

    private let importer: TrainingSessionImporting
    private let session: PhoneWatchConnectivitySessionProtocol
    private let notificationCenter: NotificationCenter
    private let logger: AppLogging
    private let analytics: AnalyticsTracking
    private let dataCutoverAt: Date?
    private let now: () -> Date
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var lastActivationCompletedAt: Date?
    private var lastActivationErrorDescription: String?
    private var lastReceivedPayloadAt: Date?
    private var lastReceivedTrainingSessionId: UUID?
    private var lastImportErrorDescription: String?
    private var lastAckSentAt: Date?
    private var lastAckTrainingSessionId: UUID?
    private var lastAckErrorDescription: String?

    init(
        importer: TrainingSessionImporting,
        session: PhoneWatchConnectivitySessionProtocol? = nil,
        notificationCenter: NotificationCenter = .default,
        logger: AppLogging = AppLogger.shared,
        analytics: AnalyticsTracking = NoopAnalyticsTracker(),
        dataCutoverAt: Date? = nil,
        now: @escaping () -> Date = Date.init,
    ) {
        self.importer = importer
        self.session = session ?? PhoneWatchConnectivitySessionAdapter()
        self.notificationCenter = notificationCenter
        self.logger = logger
        self.analytics = analytics
        self.dataCutoverAt = dataCutoverAt
        self.now = now
    }

    func start() {
        guard session.isSupported else {
            lastActivationErrorDescription = "WCSession is not supported"
            logger.warning(
                "sync.session.unsupported",
                category: .sync,
                message: "当前设备不支持 WatchConnectivity",
                context: sessionContext(),
            )
            return
        }

        logger.info(
            "sync.session.activate.requested",
            category: .sync,
            message: "请求激活 WatchConnectivity",
            context: sessionContext(),
        )
        session.setDelegate(self)
        session.activate()
    }

    func diagnosticsSnapshot() -> PhoneWatchSyncDiagnosticsSnapshot {
        PhoneWatchSyncDiagnosticsSnapshot(
            isSupported: session.isSupported,
            isPaired: session.isPaired,
            isWatchAppInstalled: session.isWatchAppInstalled,
            activationState: session.activationStateDescription,
            lastActivationCompletedAt: lastActivationCompletedAt,
            lastActivationErrorDescription: lastActivationErrorDescription,
            lastReceivedPayloadAt: lastReceivedPayloadAt,
            lastReceivedTrainingSessionId: lastReceivedTrainingSessionId,
            lastImportErrorDescription: lastImportErrorDescription,
            lastAckSentAt: lastAckSentAt,
            lastAckTrainingSessionId: lastAckTrainingSessionId,
            lastAckErrorDescription: lastAckErrorDescription,
        )
    }

    func handleReceivedUserInfo(_ userInfo: [String: Any]) async {
        guard let userInfoType = userInfo[Self.userInfoTypeKey] as? String,
              userInfoType == Self.completedTrainingSessionUserInfoType
        else {
            logger.warning(
                "sync.training.userinfo.ignored",
                category: .sync,
                message: "忽略未知手表同步消息",
                context: [
                    "receivedType": (userInfo[Self.userInfoTypeKey] as? String) ?? "missing",
                ],
            )
            return
        }

        guard let payloadData = userInfo[Self.userInfoPayloadKey] as? Data else {
            lastImportErrorDescription = "Unable to decode completed training session payload"
            logger.error(
                "sync.training.payload.decode.failed",
                category: .sync,
                message: "训练记录同步数据解码失败",
                error: nil,
                context: ["reason": "missingPayload"],
            )
            return
        }

        let payload: TrainingSessionSyncPayload
        do {
            payload = try decoder.decode(TrainingSessionSyncPayload.self, from: payloadData)
        } catch {
            lastImportErrorDescription = String(describing: error)
            logger.error(
                "sync.training.payload.decode.failed",
                category: .sync,
                message: "训练记录同步数据解码失败",
                error: error,
                context: ["payloadByteCount": "\(payloadData.count)"],
            )
            return
        }

        if let dataCutoverAt, payload.endedAt <= dataCutoverAt {
            do { try transferAck(for: payload) }
            catch {
                logger.warning("sync.training.cutover.ack.failed", category: .sync,
                    message: "旧训练确认发送失败，将等待重试", context: ["errorCategory": "ackTransfer"])
                return
            }
            logger.info("sync.training.cutover.discarded", category: .sync,
                message: "已丢弃数据切割前的旧训练", context: ["discardedCount": "1", "reason": "beforeCutover"])
            return
        }

        lastReceivedPayloadAt = now()
        lastReceivedTrainingSessionId = payload.id
        logger.info(
            "sync.training.payload.received",
            category: .sync,
            message: "收到手表训练记录",
            context: trainingContext(for: payload),
        )

        do {
            try await importer.import(payload)
        } catch {
            lastImportErrorDescription = String(describing: error)
            logger.error(
                "sync.training.import.failed",
                category: .sync,
                message: "导入手表训练记录失败",
                error: error,
                context: trainingContext(for: payload),
            )
            return
        }

        lastImportErrorDescription = nil
        logger.info(
            "sync.training.import.succeeded",
            category: .sync,
            message: "导入手表训练记录成功",
            context: trainingContext(for: payload),
        )
        analytics.track(.trainingSyncSucceeded)
        notificationCenter.post(name: .trainingSessionsDidChange, object: nil)

        do {
            try transferAck(for: payload)
        } catch {
            lastAckErrorDescription = String(describing: error)
            logger.error(
                "sync.training.ack.failed",
                category: .sync,
                message: "发送训练记录 ACK 失败",
                error: error,
                context: trainingContext(for: payload),
            )
            return
        }

        logger.info(
            "sync.training.ack.sent",
            category: .sync,
            message: "已发送训练记录 ACK",
            context: trainingContext(for: payload),
        )
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            await self?.handleReceivedUserInfo(userInfo)
        }
    }

    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?,
    ) {
        lastActivationCompletedAt = now()
        lastActivationErrorDescription = error.map { String(describing: $0) }

        if let error {
            logger.error(
                "sync.session.activate.failed",
                category: .sync,
                message: "WatchConnectivity 激活失败",
                error: error,
                context: sessionContext(activationState: activationState.diagnosticsDescription),
            )
        } else {
            logger.info(
                "sync.session.activate.completed",
                category: .sync,
                message: "WatchConnectivity 激活完成",
                context: sessionContext(activationState: activationState.diagnosticsDescription),
            )
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        self.session.activate()
    }

    private func transferAck(for payload: TrainingSessionSyncPayload) throws {
        let ack = TrainingSessionSyncAckPayload(
            trainingSessionId: payload.id,
            importedAt: now(),
        )
        let ackData = try encoder.encode(ack)
        try session.transferUserInfo([
            Self.userInfoTypeKey: Self.trainingSessionSyncAckUserInfoType,
            Self.userInfoPayloadKey: ackData,
        ])
        lastAckSentAt = ack.importedAt
        lastAckTrainingSessionId = payload.id
        lastAckErrorDescription = nil
    }

    private func sessionContext(activationState: String? = nil) -> [String: String] {
        [
            "isSupported": "\(session.isSupported)",
            "isPaired": "\(session.isPaired)",
            "isWatchAppInstalled": "\(session.isWatchAppInstalled)",
            "activationState": activationState ?? session.activationStateDescription,
        ]
    }

    private func trainingContext(for payload: TrainingSessionSyncPayload) -> [String: String] {
        ["trainingMarkerCount": "\(payload.events.count)"]
    }
}

private final class PhoneWatchConnectivitySessionAdapter: PhoneWatchConnectivitySessionProtocol {
    private let session: WCSession

    init(session: WCSession = .default) {
        self.session = session
    }

    var isSupported: Bool {
        WCSession.isSupported()
    }

    var isPaired: Bool {
        session.isPaired
    }

    var isWatchAppInstalled: Bool {
        session.isWatchAppInstalled
    }

    var activationStateDescription: String {
        session.activationState.diagnosticsDescription
    }

    func setDelegate(_ delegate: WCSessionDelegate) {
        session.delegate = delegate
    }

    func activate() {
        session.activate()
    }

    func transferUserInfo(_ userInfo: [String: Any]) throws {
        session.transferUserInfo(userInfo)
    }
}

private extension WCSessionActivationState {
    var diagnosticsDescription: String {
        switch self {
        case .notActivated:
            "notActivated"
        case .inactive:
            "inactive"
        case .activated:
            "activated"
        @unknown default:
            "unknown"
        }
    }
}
