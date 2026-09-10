import SwiftUI

@main
struct ShotMarkerWatchApp: App {
    @State private var syncService: WatchTrainingSyncService?
    @State private var resetFailed = false

    var body: some Scene {
        WindowGroup {
            Group {
                if let syncService {
                    WatchTrainingView(syncService: syncService)
                } else if resetFailed {
                    ScrollView {
                        VStack {
                            Text("无法完成数据升级")
                            Button("重试", action: bootstrap).frame(minHeight: 44)
                        }
                    }
                } else { ProgressView("正在准备本地数据…") }
            }
            .task { bootstrap() }
        }
    }

    private func bootstrap() {
        guard syncService == nil else { return }
        do {
            _ = try AppDataResetCoordinator.live(platform: .watch).resetIfNeeded()
            syncService = WatchTrainingSyncService()
            resetFailed = false
        } catch { resetFailed = true }
    }
}
