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
    /// A meteor that is already charging keeps a hit zone this many times wider, so aim wobble does not drop it
    /// (prototype addition, not in BALANCE.md). Default 1.4.
    public var lockZoneScale: Double?
    /// Energy pool spent on kills and refilled by 3 blinks. nil turns the mechanic off (original BALANCE.md rules).
    public var energy: EnergyConfig?
    /// «Мелкие цели»: the drawn size of every target and its hit zone, in both games, times this (0.7 is 30%
    /// smaller). nil: 1. The app passes 1 when the switch is off.
    public var targetScale: Double?
    /// A scaled hit zone never gets smaller than the calibration's measured miss times this: below that a look at
    /// the very centre of a target would often land outside its zone, and the game would measure the tracker, not
    /// the player. nil: 1.25. 0 turns the floor off.
    public var minZonePerError: Double?
    /// Red signs the player must not look at, in the meteor game. nil: none.
    public var decoys: DecoyConfig?

    public static let classOrder = ["S", "M", "L", "XL"]

    public static func load(from data: Data) throws -> BalanceConfig {
        try JSONDecoder().decode(BalanceConfig.self, from: data)
    }

    public var levelCount: Int { levels ?? 10 }
    /// The small-target scale, kept within reason so a mistuned balance.json cannot make targets vanish or grow.
    public var smallTargetScale: Double { min(1, max(0.4, targetScale ?? 1)) }
    public var zoneFloorFactor: Double { max(0, minZonePerError ?? 1.25) }

    /// The smallest hit zone (screen pt) for a calibration that missed by `measuredErrorPt` on the check screen.
    /// 0 with regular targets, where the zone is the full radius plus the miss, and without a measured miss (touch).
    public func zoneFloor(measuredErrorPt: Double?, scale: Double) -> Double {
        guard scale < 1, let e = measuredErrorPt, e.isFinite, e > 0 else { return 0 }
        return zoneFloorFactor * e
    }
    public var rules: Adaptation { adaptation ?? Adaptation() }
    public var lockZone: Double { max(1, lockZoneScale ?? 1.4) }

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

/// The red signs of the meteor game: they come in like meteors, do no harm and burn out by themselves. Looking at
/// one for longer than `errorDwellSec` counts as an error (the player was meant to pass it by). Lives in
/// balance.json under "decoys"; a key left out keeps its default.
public struct DecoyConfig: Codable, Sendable {
    /// Drawn diameter before the small-target scale, screen pt.
    public var sizePt: Double = 84
    /// Seconds from the edge to Earth at difficulty 0 and 1.
    public var travelSec: [Double] = [7.0, 5.0]
    /// Seconds between two signs at difficulty 0 and 1, and before the first one of a play.
    public var intervalSec: [Double] = [8.0, 6.0]
    public var firstAfterSec: Double = 6
    public var maxOnScreen: Int = 1
    /// A look at a sign that lasts this long is an error (s).
    public var errorDwellSec: Double = 0.25
    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sizePt = try c.decodeIfPresent(Double.self, forKey: .sizePt) ?? sizePt
        travelSec = try c.decodeIfPresent([Double].self, forKey: .travelSec) ?? travelSec
        intervalSec = try c.decodeIfPresent([Double].self, forKey: .intervalSec) ?? intervalSec
        firstAfterSec = try c.decodeIfPresent(Double.self, forKey: .firstAfterSec) ?? firstAfterSec
        maxOnScreen = try c.decodeIfPresent(Int.self, forKey: .maxOnScreen) ?? maxOnScreen
        errorDwellSec = try c.decodeIfPresent(Double.self, forKey: .errorDwellSec) ?? errorDwellSec
    }
}
