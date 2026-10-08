import Foundation

/// Gameplay numbers from docs/BALANCE.md. Loaded from balance.json so they can be tuned without code changes.
/// Pairs `[a, b]` are the value at difficulty d = 0 and d = 1.
public struct BalanceConfig: Codable, Sendable {
    public struct AsteroidClass: Codable, Sendable {
        /// Drawn diameter, screen pt.
        public var sizePt: Double
        public var dwellSec: Double
        public var travelSec: [Double]
        public var damage: Int
    }
    public struct HitMargin: Codable, Sendable { public var source: String; public var min: Double; public var max: Double }
    public struct GazeBrake: Codable, Sendable { public var levels1to3: Double; public var later: Double }
    public struct ErrorCap: Codable, Sendable { public var errorPt: Double; public var max: Int }
    /// Adaptation rules from the "Адаптация под ребёнка" section.
    public struct Adaptation: Codable, Sendable {
        public var hitsWindowSec: Double = 10
        public var hitsToEase: Int = 2
        public var easeStep: Double = 0.1
        public var streakToHarden: Int = 6
        public var hardenStep: Double = 0.05
        public var advanceKillRatio: Double = 0.8
        public var easeKillRatio: Double = 0.5
        public var failEaseStep: Double = 0.1
        public init() {}
    }

    public var minDwellSec: Double
    public var classes: [String: AsteroidClass]
    public var hitMarginPt: HitMargin
    public var dropoutGraceSec: Double
    public var decayToZeroSec: Double
    public var gazeBrake: GazeBrake
    public var spawnIntervalSec: [Double]
    public var maxOnScreen: [Double]
    public var maxOnScreenIfErrorAbovePt: ErrorCap
    public var levelLengthSec: Double
    public var earthShields: Int
    // Not in the BALANCE.md JSON block, taken from its tables. Optional so the original block still decodes.
    public var levels: Int?
    /// Percent of S / M / L / XL per level (row 0 = level 1).
    public var classMixByLevel: [[Double]]?
    public var adaptation: Adaptation?
    /// Freeze the game when the face has been lost this long (prototype addition, not in BALANCE.md).
    public var pauseWhenFaceLostSec: Double?

    public static let classOrder = ["S", "M", "L", "XL"]

    public static func load(from data: Data) throws -> BalanceConfig {
        try JSONDecoder().decode(BalanceConfig.self, from: data)
    }

    public var levelCount: Int { levels ?? 10 }
    public var rules: Adaptation { adaptation ?? Adaptation() }

    /// Smooth S-curve from BALANCE.md: d = t²(3 − 2t), t = (level − 1) / (levels − 1).
    public func difficulty(level: Int) -> Double {
        let t = Double(max(1, min(levelCount, level)) - 1) / Double(max(1, levelCount - 1))
        return t * t * (3 - 2 * t)
    }

    public static func lerp(_ pair: [Double], _ d: Double) -> Double {
        guard let a = pair.first else { return 0 }
        guard pair.count > 1 else { return a }
        return a + (pair[1] - a) * max(0, min(1, d))
    }

    /// Hit-zone margin E from the measured mean error on the check screen, clamped to [min, max].
    public func hitMargin(measuredErrorPt: Double) -> Double {
        max(hitMarginPt.min, min(hitMarginPt.max, measuredErrorPt.isFinite ? measuredErrorPt : hitMarginPt.max))
    }

    public func brake(level: Int) -> Double { level <= 3 ? gazeBrake.levels1to3 : gazeBrake.later }

    public func maxAsteroids(d: Double, marginPt: Double) -> Int {
        let n = Int(Self.lerp(maxOnScreen, d).rounded())
        return marginPt > maxOnScreenIfErrorAbovePt.errorPt ? min(n, maxOnScreenIfErrorAbovePt.max) : n
    }

    /// Class weights (S, M, L, XL) for a level.
    public func classMix(level: Int) -> [Double] {
        guard let rows = classMixByLevel, !rows.isEmpty else { return [50, 50, 0, 0] }
        return rows[max(0, min(rows.count - 1, level - 1))]
    }
}
