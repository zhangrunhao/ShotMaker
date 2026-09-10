import Combine
import SwiftUI
import UIKit

@main
struct ShotMarkerApp: App {
    @StateObject private var bootstrap = ShotMarkerBootstrap()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if ProcessInfo.processInfo.environment["SHOTMARKER_UI_TEST_TIMELINE"] == "1" {
                    HighlightClipTimelineUITestHarnessView()
                } else if ProcessInfo.processInfo.environment["SHOTMARKER_UI_TEST_CLIP_CONFIRMATION"] == "1" {
                    HighlightClipConfirmationUITestHarnessView()
                } else if ProcessInfo.processInfo.environment["SHOTMARKER_UI_TEST_TASK_STATE"] != nil {
                    HighlightTaskUITestHarnessView()
                } else {
                    content
                }
            #else
                content
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { bootstrap.services?.highlightTaskManager.enterBackground() }
            else if phase == .active { bootstrap.services?.highlightTaskManager.enterForeground() }
        }
    }

    private var content: some View {
        Group {
            if let services = bootstrap.services {
                ContentView(store: services.store, syncService: services.syncService,
                    logger: services.logger, logExportService: services.logExportService,
                    highlightTaskManager: services.highlightTaskManager)
            } else if bootstrap.resetFailed {
                ContentUnavailableView {
                    Label("无法完成数据升级", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("本地数据升级尚未完成。请检查可用空间后重试。")
                } actions: {
                    Button("重试") { Task { await bootstrap.start() } }
                }
            } else { ProgressView("正在准备本地数据…") }
        }
        .task { await bootstrap.start() }
    }
}

@MainActor
final class ShotMarkerBootstrap: ObservableObject {
    @Published private(set) var services: ShotMarkerServices?
    @Published private(set) var resetFailed = false
    private var starting = false
    private let reset: @MainActor () throws -> Date?
    private let makeServices: @MainActor (Date?) -> ShotMarkerServices

    init(reset: @escaping @MainActor () throws -> Date? = { try AppDataResetCoordinator.live(platform: .phone).resetIfNeeded() },
        makeServices: @escaping @MainActor (Date?) -> ShotMarkerServices = ShotMarkerServices.init) {
        self.reset = reset
        self.makeServices = makeServices
    }

    func start() async {
        guard services == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let cutover = try reset()
            let ready = makeServices(cutover)
            await ready.highlightTaskManager.load()
            ready.start()
            services = ready
            resetFailed = false
        } catch { resetFailed = true }
    }
}

@MainActor
final class ShotMarkerServices {
    let store: TrainingSessionStore
    let syncService: PhoneWatchSyncService
    let logger: AppLogging
    let logExportService: AppLogExportService
    let highlightTaskManager: HighlightTaskManager
    private let analytics: AnalyticsTracking

    init(dataCutoverAt: Date?) {
        // This initializer is reachable only after the epoch transaction succeeds.
        GlitchTipCrashReporter.start()
        store = TrainingSessionStore()
        logger = AppLogger.shared
        #if DEBUG
            let isDebugBuild = true
        #else
            let isDebugBuild = false
        #endif
        analytics = AnalyticsRuntimePolicy.shouldSend(isDebugBuild: isDebugBuild,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone) ? AnalyticsClient.live() : NoopAnalyticsTracker()
        syncService = PhoneWatchSyncService(importer: TrainingSessionImporter(store: store, logger: logger),
            logger: logger, analytics: analytics, dataCutoverAt: dataCutoverAt)
        logExportService = AppLogExportService(store: AppLogStore.shared,
            diagnosticsSnapshotProvider: syncService.diagnosticsSnapshot)
        highlightTaskManager = .live(logger: logger, analytics: analytics)
    }

    func start() {
        logger.info("app.launch", category: .app, message: "应用启动")
        analytics.track(.appLaunch)
        syncService.start()
    }
}
