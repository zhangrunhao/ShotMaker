@testable import ShotMarker
import XCTest

final class AppDataResetCoordinatorTests: XCTestCase {
    func testBootstrapDoesNotConstructAnyServicesIfResetFails() async {
        var serviceCreationCount = 0
        let bootstrap = ShotMarkerBootstrap(reset: { throw CocoaError(.fileWriteOutOfSpace) }, makeServices: { cutover in
            serviceCreationCount += 1
            return ShotMarkerServices(dataCutoverAt: cutover)
        })
        await bootstrap.start()
        XCTAssertEqual(serviceCreationCount, 0)
        XCTAssertNil(bootstrap.services)
        XCTAssertTrue(bootstrap.resetFailed)
    }

    func testPhoneResetClearsOnlySandboxAndSecondLaunchPreservesNewData() throws {
        let fixture = try ResetFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set("old", forKey: "setting")
        let outside = fixture.root.appendingPathComponent("external.mov")
        try Data([1]).write(to: outside)
        let coordinator = fixture.coordinator(platform: .phone)
        let cutover = try coordinator.resetIfNeeded()
        XCTAssertEqual(cutover, Date(timeIntervalSince1970: 100))
        XCTAssertNil(fixture.defaults.string(forKey: "setting"))
        XCTAssertEqual(fixture.defaults.integer(forKey: "ShotMarker.dataEpoch"), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.businessFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.caches.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.temporary.path), [])
        try FileManager.default.createDirectory(at: fixture.businessFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([2]).write(to: fixture.businessFile)
        XCTAssertEqual(try coordinator.resetIfNeeded(), cutover)
        XCTAssertEqual(try Data(contentsOf: fixture.businessFile), Data([2]))
    }

    func testRetryKeepsFirstCutoverAndJournalTakesPrecedenceOverEpoch() throws {
        let fixture = try ResetFixture()
        defer { fixture.cleanup() }
        let first = fixture.coordinator(platform: .phone, remove: { _ in throw CocoaError(.fileWriteNoPermission) })
        XCTAssertThrowsError(try first.resetIfNeeded())
        XCTAssertEqual(fixture.defaults.integer(forKey: "ShotMarker.dataEpoch"), 0)
        let journal = fixture.support.appendingPathComponent("ShotMarkerReset/reset-state.json")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["targetEpoch", "dataCutoverAt"])
        fixture.defaults.set(1, forKey: "ShotMarker.dataEpoch")
        let retry = fixture.coordinator(platform: .phone, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try retry.resetIfNeeded(), Date(timeIntervalSince1970: 100))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.businessFile.path))
    }

    func testWatchResetClearsOutboxAndPreservesNewOutboxOnNextLaunch() throws {
        let fixture = try ResetFixture()
        defer { fixture.cleanup() }
        let outbox = fixture.support.appendingPathComponent("watch-training-sync-outbox.json")
        try Data([1]).write(to: outbox)
        XCTAssertNil(try fixture.coordinator(platform: .watch).resetIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: outbox.path))
        try Data([2]).write(to: outbox)
        _ = try fixture.coordinator(platform: .watch).resetIfNeeded()
        XCTAssertEqual(try Data(contentsOf: outbox), Data([2]))
    }
}

private struct ResetFixture {
    let root: URL
    let support: URL
    let caches: URL
    let temporary: URL
    let businessFile: URL
    let domain: String
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        support = root.appendingPathComponent("Application Support")
        caches = root.appendingPathComponent("Caches")
        temporary = root.appendingPathComponent("tmp")
        businessFile = support.appendingPathComponent("ShotMarker/training-sessions.json")
        domain = "ShotMarkerResetTests.\(UUID())"
        defaults = UserDefaults(suiteName: domain)!
        for directory in [businessFile.deletingLastPathComponent(), caches, temporary] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data([0]).write(to: directory.appendingPathComponent("old"))
        }
        try Data([0]).write(to: businessFile)
    }

    func coordinator(
        platform: AppDataResetCoordinator.Platform,
        now: Date = Date(timeIntervalSince1970: 100),
        remove: @escaping (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> AppDataResetCoordinator {
        AppDataResetCoordinator(platform: platform, applicationSupport: support,
            caches: caches, temporary: temporary, defaults: defaults, domain: domain,
            now: { now }, removeItem: remove)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: root)
    }
}
