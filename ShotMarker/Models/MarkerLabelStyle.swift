import Foundation

nonisolated struct MarkerLabelStyle: Codable, Equatable, Sendable {
    var fontSizeRatio: Double
    var normalizedCenterX: Double
    var normalizedCenterY: Double
    var textOpacity: Double
    var backgroundOpacity: Double

    static let fontSizeRatioRange = 0.04 ... 0.16
    static let normalizedCenterRange = 0.0 ... 1.0
    static let opacityRange = 0.0 ... 1.0

    static let `default` = MarkerLabelStyle(
        fontSizeRatio: 0.10,
        normalizedCenterX: 0.15,
        normalizedCenterY: 0.10,
        textOpacity: 1.00,
        backgroundOpacity: 0.60,
    )

    private enum CodingKeys: String, CodingKey {
        case fontSizeRatio
        case normalizedCenterX
        case normalizedCenterY
        case textOpacity
        case backgroundOpacity
    }

    init(
        fontSizeRatio: Double,
        normalizedCenterX: Double,
        normalizedCenterY: Double,
        textOpacity: Double,
        backgroundOpacity: Double,
    ) {
        self.fontSizeRatio = fontSizeRatio
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.textOpacity = textOpacity
        self.backgroundOpacity = backgroundOpacity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MarkerLabelStyle.default

        self = MarkerLabelStyle(
            fontSizeRatio: try container.decodeIfPresent(Double.self, forKey: .fontSizeRatio)
                ?? defaults.fontSizeRatio,
            normalizedCenterX: try container.decodeIfPresent(Double.self, forKey: .normalizedCenterX)
                ?? defaults.normalizedCenterX,
            normalizedCenterY: try container.decodeIfPresent(Double.self, forKey: .normalizedCenterY)
                ?? defaults.normalizedCenterY,
            textOpacity: try container.decodeIfPresent(Double.self, forKey: .textOpacity)
                ?? defaults.textOpacity,
            backgroundOpacity: try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity)
                ?? defaults.backgroundOpacity,
        ).normalized
    }

    func encode(to encoder: Encoder) throws {
        let style = normalized
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(style.fontSizeRatio, forKey: .fontSizeRatio)
        try container.encode(style.normalizedCenterX, forKey: .normalizedCenterX)
        try container.encode(style.normalizedCenterY, forKey: .normalizedCenterY)
        try container.encode(style.textOpacity, forKey: .textOpacity)
        try container.encode(style.backgroundOpacity, forKey: .backgroundOpacity)
    }

    var normalized: MarkerLabelStyle {
        let defaults = MarkerLabelStyle.default

        return MarkerLabelStyle(
            fontSizeRatio: Self.normalize(
                fontSizeRatio,
                within: Self.fontSizeRatioRange,
                fallback: defaults.fontSizeRatio,
            ),
            normalizedCenterX: Self.normalize(
                normalizedCenterX,
                within: Self.normalizedCenterRange,
                fallback: defaults.normalizedCenterX,
            ),
            normalizedCenterY: Self.normalize(
                normalizedCenterY,
                within: Self.normalizedCenterRange,
                fallback: defaults.normalizedCenterY,
            ),
            textOpacity: Self.normalize(
                textOpacity,
                within: Self.opacityRange,
                fallback: defaults.textOpacity,
            ),
            backgroundOpacity: Self.normalize(
                backgroundOpacity,
                within: Self.opacityRange,
                fallback: defaults.backgroundOpacity,
            ),
        )
    }

    private static func normalize(
        _ value: Double,
        within range: ClosedRange<Double>,
        fallback: Double,
    ) -> Double {
        guard value.isFinite else {
            return fallback
        }

        return min(max(value, range.lowerBound), range.upperBound)
    }
}
