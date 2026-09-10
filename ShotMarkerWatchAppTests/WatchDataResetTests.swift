@testable import ShotMarkerWatchApp
import XCTest

final class WatchDataResetTests: XCTestCase {
    func testEpochResetRemovesOldOutboxButNotNewOutboxOnRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let support = root.appendingPathComponent("support")
        let domain = "WatchDataResetTests.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let outbox = support.appendingPathComponent("watch-training-sync-outbox.json")
        try Data("old".utf8).write(to: outbox)
        let coordinator = AppDataResetCoordinator(platform: .watch, applicationSupport: support,
            caches: root.appendingPathComponent("caches"), temporary: root.appendingPathComponent("tmp"),
            defaults: defaults, domain: domain)
        _ = try coordinator.resetIfNeeded()
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.path))
        try Data("new".utf8).write(to: outbox)
        _ = try coordinator.resetIfNeeded()
        XCTAssertEqual(try Data(contentsOf: outbox), Data("new".utf8))
    }
}
