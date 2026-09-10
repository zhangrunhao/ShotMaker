import Foundation

/// Runs before constructing any business, logging, telemetry or connectivity services.
struct AppDataResetCoordinator {
    enum Platform { case phone, watch }
    static let currentDataEpoch = 1
    static let epochKey = "ShotMarker.dataEpoch"
    static let cutoverKey = "ShotMarker.dataCutoverAt"

    private struct Journal: Codable {
        let targetEpoch: Int
        let dataCutoverAt: Date
    }

    let platform: Platform
    let applicationSupport: URL
    let caches: URL
    let temporary: URL
    let defaults: UserDefaults
    let domain: String
    var now: () -> Date = Date.init
    var removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }

    static func live(platform: Platform) -> Self {
        let manager = FileManager.default
        return Self(platform: platform,
            applicationSupport: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
            caches: manager.urls(for: .cachesDirectory, in: .userDomainMask)[0],
            temporary: manager.temporaryDirectory, defaults: .standard,
            domain: Bundle.main.bundleIdentifier!)
    }

    func resetIfNeeded() throws -> Date? {
        let manager = FileManager.default
        let journalDirectory = applicationSupport.appendingPathComponent("ShotMarkerReset", isDirectory: true)
        let journalURL = journalDirectory.appendingPathComponent("reset-state.json")
        let hasJournal = platform == .phone && manager.fileExists(atPath: journalURL.path)
        guard hasJournal || defaults.integer(forKey: Self.epochKey) < Self.currentDataEpoch else {
            return defaults.object(forKey: Self.cutoverKey) as? Date
        }

        let cutover: Date?
        if platform == .phone {
            let journal: Journal
            if hasJournal {
                journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
                guard journal.targetEpoch == Self.currentDataEpoch else { throw AppDataResetError.invalidJournal }
            } else {
                journal = Journal(targetEpoch: Self.currentDataEpoch, dataCutoverAt: now())
                try manager.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            }
            cutover = journal.dataCutoverAt
            try removeIfPresent(applicationSupport.appendingPathComponent("ShotMarker", isDirectory: true))
            try clearContents(caches)
            try clearContents(temporary)
            defaults.removePersistentDomain(forName: domain)
        } else {
            cutover = nil
            try clearContents(applicationSupport)
            defaults.removePersistentDomain(forName: domain)
            try clearContents(caches)
            try clearContents(temporary)
        }

        defaults.set(Self.currentDataEpoch, forKey: Self.epochKey)
        if let cutover { defaults.set(cutover, forKey: Self.cutoverKey) }
        guard defaults.synchronize() else { throw AppDataResetError.settingsWriteFailed }
        if platform == .phone { try removeIfPresent(journalDirectory) }
        return cutover
    }

    private func clearContents(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try removeItem(child)
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try removeItem(url) }
    }
}

enum AppDataResetError: Error { case invalidJournal, settingsWriteFailed }
