import Foundation

nonisolated struct ClipSettings: Codable, Equatable, Sendable {
    var secondsBeforeMarker: TimeInterval
    var secondsAfterMarker: TimeInterval
    var markerLabelStyle: MarkerLabelStyle

    static let `default` = ClipSettings(
        secondsBeforeMarker: 9,
        secondsAfterMarker: 4,
        markerLabelStyle: .default,
    )

    private enum CodingKeys: String, CodingKey {
        case secondsBeforeMarker
        case secondsAfterMarker
        case markerLabelStyle
    }

    init(
        secondsBeforeMarker: TimeInterval,
        secondsAfterMarker: TimeInterval,
        markerLabelStyle: MarkerLabelStyle = .default,
    ) {
        self.secondsBeforeMarker = secondsBeforeMarker
        self.secondsAfterMarker = secondsAfterMarker
        self.markerLabelStyle = markerLabelStyle
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self = ClipSettings(
            secondsBeforeMarker: try container.decode(
                TimeInterval.self,
                forKey: .secondsBeforeMarker,
            ),
            secondsAfterMarker: try container.decode(
                TimeInterval.self,
                forKey: .secondsAfterMarker,
            ),
            markerLabelStyle: try container.decodeIfPresent(
                MarkerLabelStyle.self,
                forKey: .markerLabelStyle,
            ) ?? .default,
        ).normalized
    }

    func encode(to encoder: Encoder) throws {
        let settings = normalized
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(settings.secondsBeforeMarker, forKey: .secondsBeforeMarker)
        try container.encode(settings.secondsAfterMarker, forKey: .secondsAfterMarker)
        try container.encode(settings.markerLabelStyle, forKey: .markerLabelStyle)
    }

    var normalized: ClipSettings {
        ClipSettings(
            secondsBeforeMarker: secondsBeforeMarker,
            secondsAfterMarker: secondsAfterMarker,
            markerLabelStyle: markerLabelStyle.normalized,
        )
    }
}

struct ClipSettingsStore {
    static let shared = ClipSettingsStore()

    private let userDefaults: UserDefaults
    private let key: String

    init(
        userDefaults: UserDefaults = .standard,
        key: String = "ShotMarker.clipSettings",
    ) {
        self.userDefaults = userDefaults
        self.key = key
    }

    func load() -> ClipSettings {
        guard let data = userDefaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ClipSettings.self, from: data)
        else {
            return .default
        }

        return settings
    }

    func save(_ settings: ClipSettings) {
        guard let data = try? JSONEncoder().encode(settings.normalized) else {
            return
        }

        userDefaults.set(data, forKey: key)
    }
}
