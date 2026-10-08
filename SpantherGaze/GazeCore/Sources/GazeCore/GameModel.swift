import Foundation

/// What the player is looking at this frame (screen pt, origin top-left, y down).
public enum GazeInput: Sendable, Equatable {
    case point(Vec2)
    /// Tracking is fine but the player is not on the screen (touch mode with no finger down).
    case notLooking
    /// Tracking lost (blink, dropped frame, face out of view).
    case lost
}

public struct Asteroid: Sendable, Identifiable {
    public let id: Int
    public let className: String
    public var position: Vec2
    public var velocity: Vec2
    /// Drawn radius, screen pt.
    public let radius: Double
    public let dwellSec: Double
    public let damage: Int
    /// 0...1, the ring around the asteroid.
    public var progress: Double = 0
    public var isTargeted = false
    public let spawnTime: Double
    public var firstLookTime: Double?
    public var slips = 0
    public var rotation: Double
}

/// One line of the per-asteroid log for the parent report (BALANCE.md, last section).
public struct AsteroidRecord: Sendable, Codable {
    public var className: String
    public var level: Int
    public var reactionSec: Double?
    public var lifetimeSec: Double
    public var slips: Int
    public var destroyed: Bool
}

public enum GameEvent: Sendable {
    case spawned(Asteroid)
    case destroyed(Asteroid, AsteroidRecord)
    case hitEarth(Asteroid, AsteroidRecord)
    case shieldsDepleted(restartLevel: Int)
    case levelEnded(level: Int, killRatio: Double, nextLevel: Int)
    case pausedForFace(Bool)
}

/// SplitMix64, so tests can replay a game exactly.
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// The whole game without any drawing. SpriteKit (GameScene) only renders this state.
public final class GameModel {
    public let config: BalanceConfig
    public let screen: Vec2
    public private(set) var asteroids: [Asteroid] = []
    public private(set) var level = 1
    /// Current difficulty 0...1. Starts at the level's curve value and is nudged by the adaptation rules.
    public private(set) var d: Double = 0
    public private(set) var shields: Int
    public private(set) var score = 0
    public private(set) var levelTime = 0.0
    public private(set) var destroyedThisLevel = 0
    public private(set) var reachedThisLevel = 0
    public private(set) var pausedForFace = false
    /// Hit-zone margin E (screen pt). Set from the check screen, or a small value in touch mode.
    public var marginPt: Double
    public var time = 0.0

    public let earthCenter: Vec2
    public let earthRadius: Double

    private var rng: SeededRandom
    private var nextId = 1
    private var spawnTimer = 1.0
    private var lostSince: Double?
    private var recentHits: [Double] = []
    private var killStreak = 0

    public init(config: BalanceConfig, screen: Vec2, marginPt: Double, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        self.config = config
        self.screen = screen
        self.marginPt = marginPt
        self.rng = SeededRandom(seed: seed)
        shields = config.earthShields
        earthRadius = screen.x * 0.8
        earthCenter = Vec2(screen.x / 2, screen.y + earthRadius * 0.62)
        d = config.difficulty(level: 1)
    }

    public var earthTopY: Double { earthCenter.y - earthRadius }

    /// Distance of a point to an asteroid divided by the hit-zone radius (drawn radius + E). < 1 means inside.
    public func zoneRatio(_ p: Vec2, _ a: Asteroid) -> Double { p.distance(to: a.position) / (a.radius + marginPt) }

    /// Advances the game by `dt` seconds and returns what happened.
    @discardableResult
    public func update(dt: Double, gaze: GazeInput) -> [GameEvent] {
        var events: [GameEvent] = []
        let dt = min(dt, 0.1)

        // Tracking dropouts: short ones freeze progress, long ones pause the whole game.
        var freezeProgress = false
        var point: Vec2?
        switch gaze {
        case .point(let p): point = p; lostSince = nil
        case .notLooking: lostSince = nil
        case .lost:
            if lostSince == nil { lostSince = time }
            freezeProgress = time - (lostSince ?? time) < config.dropoutGraceSec
        }
        let lostFor = lostSince.map { time - $0 } ?? 0
        let shouldPause = lostFor >= (config.pauseWhenFaceLostSec ?? 1.0)
        if shouldPause != pausedForFace { pausedForFace = shouldPause; events.append(.pausedForFace(shouldPause)) }
        if pausedForFace { time += dt; return events }
        time += dt
        levelTime += dt

        // Pick at most one target: the asteroid with the smallest distance / zone-radius ratio.
        var targetIndex: Int?
        if let p = point {
            var best = 1.0
            for (i, a) in asteroids.enumerated() {
                let r = zoneRatio(p, a)
                if r < best { best = r; targetIndex = i }
            }
        }

        let brake = config.brake(level: level)
        var i = 0
        while i < asteroids.count {
            var a = asteroids[i]
            let targeted = i == targetIndex
            a.isTargeted = targeted
            if targeted {
                if a.firstLookTime == nil { a.firstLookTime = time }
                a.progress += dt / a.dwellSec
            } else if !freezeProgress && a.progress > 0 {
                a.progress = max(0, a.progress - dt / config.decayToZeroSec)
                if a.progress == 0 { a.slips += 1 }
            }
            let speed = targeted ? 1 - brake : 1
            a.position = a.position + a.velocity * (dt * speed)
            a.rotation += dt * 0.6

            if a.progress >= 1 {
                let rec = record(a, destroyed: true)
                asteroids.remove(at: i)
                if let t = targetIndex, t > i { targetIndex = t - 1 }
                score += 10 * (BalanceConfig.classOrder.firstIndex(of: a.className).map { $0 + 1 } ?? 1)
                destroyedThisLevel += 1
                killStreak += 1
                if killStreak >= config.rules.streakToHarden {
                    d = min(config.difficulty(level: level), d + config.rules.hardenStep)
                    killStreak = 0
                }
                events.append(.destroyed(a, rec))
                continue
            }
            if a.position.distance(to: earthCenter) < earthRadius + a.radius * 0.3 {
                let rec = record(a, destroyed: false)
                asteroids.remove(at: i)
                reachedThisLevel += 1
                shields -= a.damage
                killStreak = 0
                recentHits.append(time)
                recentHits.removeAll { time - $0 > config.rules.hitsWindowSec }
                if recentHits.count >= config.rules.hitsToEase {
                    d = max(0, d - config.rules.easeStep)
                    recentHits.removeAll()
                }
                events.append(.hitEarth(a, rec))
                if shields <= 0 {
                    // No game over for kids: restart the level a bit easier.
                    d = max(0, config.difficulty(level: level) - config.rules.failEaseStep)
                    restartLevel()
                    events.append(.shieldsDepleted(restartLevel: level))
                    return events
                }
                continue
            }
            asteroids[i] = a
            i += 1
        }

        // Level end: stop spawning after levelLengthSec, finish when the sky is clear.
        if levelTime >= config.levelLengthSec {
            if asteroids.isEmpty {
                let total = destroyedThisLevel + reachedThisLevel
                let ratio = total > 0 ? Double(destroyedThisLevel) / Double(total) : 1
                let finished = level
                if ratio >= config.rules.advanceKillRatio {
                    level = min(config.levelCount, level + 1)
                    d = config.difficulty(level: level)
                } else if ratio < config.rules.easeKillRatio {
                    d = max(0, d - config.rules.failEaseStep)
                }
                restartLevel(keepShields: true)
                events.append(.levelEnded(level: finished, killRatio: ratio, nextLevel: level))
            }
            return events
        }

        spawnTimer -= dt
        if spawnTimer <= 0, asteroids.count < config.maxAsteroids(d: d, marginPt: marginPt) {
            let a = spawn()
            asteroids.append(a)
            events.append(.spawned(a))
            spawnTimer = BalanceConfig.lerp(config.spawnIntervalSec, d)
        }
        return events
    }

    private func restartLevel(keepShields: Bool = false) {
        asteroids.removeAll()
        levelTime = 0
        destroyedThisLevel = 0
        reachedThisLevel = 0
        spawnTimer = 1.5
        killStreak = 0
        recentHits.removeAll()
        if !keepShields { shields = config.earthShields }
    }

    private func record(_ a: Asteroid, destroyed: Bool) -> AsteroidRecord {
        AsteroidRecord(className: a.className, level: level, reactionSec: a.firstLookTime.map { $0 - a.spawnTime },
                       lifetimeSec: time - a.spawnTime, slips: a.slips, destroyed: destroyed)
    }

    /// Picks a class by the level's mix, places it with at least 2E horizontal spacing from other fresh asteroids,
    /// and aims it at Earth so it arrives after the class's travel time.
    public func spawn(className forced: String? = nil) -> Asteroid {
        let mix = config.classMix(level: level)
        var name = forced ?? "S"
        if forced == nil {
            let total = mix.reduce(0, +)
            var roll = Double.random(in: 0..<max(total, 1e-9), using: &rng)
            for (k, w) in mix.enumerated() where k < BalanceConfig.classOrder.count {
                if roll < w { name = BalanceConfig.classOrder[k]; break }
                roll -= w
            }
        }
        let cls = config.classes[name] ?? config.classes["S"]!
        let r = cls.sizePt / 2
        let lo = r, hi = max(r + 1, screen.x - r)
        var x = Double.random(in: lo...hi, using: &rng)
        for _ in 0..<12 {
            let crowded = asteroids.contains { $0.position.y < screen.y * 0.35 && abs($0.position.x - x) < 2 * marginPt }
            if !crowded { break }
            x = Double.random(in: lo...hi, using: &rng)
        }
        let start = Vec2(x, -r)
        let aim = Vec2(earthCenter.x + (x - earthCenter.x) * 0.5, earthTopY)
        let path = aim - start
        let travel = BalanceConfig.lerp(cls.travelSec, d)
        let v = path * (1 / max(0.1, travel))
        let a = Asteroid(id: nextId, className: name, position: start, velocity: v, radius: r, dwellSec: cls.dwellSec,
                         damage: cls.damage, spawnTime: time, rotation: Double.random(in: 0..<6.28, using: &rng))
        nextId += 1
        return a
    }

    /// Test and debug hook: put an asteroid somewhere specific.
    public func insert(_ a: Asteroid) { asteroids.append(a) }
    public func removeAll() { asteroids.removeAll() }
}
