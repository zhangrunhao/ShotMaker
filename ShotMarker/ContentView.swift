//
//  ContentView.swift
//  ShotMarker
//
//  Created by runhao zhang on 2026/5/1.
//

import SwiftUI

struct ContentView: View {
    private let store: TrainingSessionStoreProtocol
    private let syncService: PhoneWatchSyncService?
    private let logger: AppLogging
    private let logExportService: AppLogExportService?
    #if os(iOS)
        private let highlightTaskManager: HighlightTaskManager?
        private let reviewStore: (any HighlightClipReviewStoring)?
    #endif

    @MainActor
    init(
        store: TrainingSessionStoreProtocol,
        syncService: PhoneWatchSyncService? = nil,
        logger: AppLogging = AppLogger.shared,
        logExportService: AppLogExportService? = nil,
        highlightTaskManager: HighlightTaskManager? = nil,
        reviewStore: (any HighlightClipReviewStoring)? = nil,
    ) {
        self.store = store
        self.syncService = syncService
        self.logger = logger
        self.logExportService = logExportService
        #if os(iOS)
            self.highlightTaskManager = highlightTaskManager
            self.reviewStore = reviewStore
        #endif
    }

    var body: some View {
        TrainingSessionListView(
            store: store,
            diagnosticsSnapshotProvider: syncService?.diagnosticsSnapshot,
            logger: logger,
            logExportService: logExportService,
            highlightTaskManager: highlightTaskManager,
            reviewStore: reviewStore,
        )
    }
}

#if DEBUG
    #Preview {
        ContentView(
            store: InMemoryTrainingSessionStore(sessions: TrainingSession.previewSessions),
            reviewStore: InMemoryHighlightClipReviewStore(),
        )
    }
#endif
