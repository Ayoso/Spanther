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
    /// Looked at, but the energy pool cannot pay for this class: no progress until a reload.
    public var isStarved = false
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

/// A red sign: it comes in like a meteor, does no harm and burns out at Earth by itself. The player is meant to
/// pass it by; a look that rests on it for `DecoyConfig.errorDwellSec` is an error, and the sign fades.
public struct Decoy: Sendable, Identifiable {
    public let id: Int
    public var position: Vec2
    public var velocity: Vec2
    /// Drawn radius, screen pt.
    public let radius: Double
    public let spawnTime: Double
    /// Seconds the gaze has rested on it without leaving.
    public var dwellSec = 0.0
    public var isLookedAt = false
    /// Game time at which the look that rests on it now began; nil while nobody looks at it.
    public var lookStart: Double?
}

/// How one red sign ended, for the report and the session CSV.
public struct DecoyRecord: Sendable, Codable, Equatable {
    public var level: Int
    public var lifetimeSec: Double
    /// The gaze rested on it past the threshold: an error. False: it was passed by, as asked.
    public var looked: Bool
    /// Seconds from its appearance to the start of the look that became the error.
    public var lookSec: Double?
}

public enum GameEvent: Sendable {
    case spawned(Asteroid)
    case destroyed(Asteroid, AsteroidRecord)
    case hitEarth(Asteroid, AsteroidRecord)
    case shieldsDepleted(restartLevel: Int)
    case levelEnded(level: Int, killRatio: Double, nextLevel: Int)
    case pausedForFace(Bool)
    /// A kill spent energy; `left` is what remains.
    case energySpent(cost: Int, left: Int)
    /// The player is looking at an asteroid they cannot afford (true) or no longer is (false).
    case starved(Bool)
    case decoySpawned(Decoy)
    /// The gaze rested on a red sign past the threshold (an error): the sign leaves the play.
    case decoyLooked(Decoy, DecoyRecord)
    /// A red sign reached Earth without being looked at that long: it burns out by itself.
    case decoyPassed(Decoy, DecoyRecord)
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
    /// Energy pool (only when `config.energy` is set; otherwise stays 0 and is ignored).
    public private(set) var energy = 0
    public var energyEnabled: Bool { config.energy != nil }
    public var energyMax: Int { config.energy?.max ?? 0 }
    /// True while the targeted asteroid costs more than the pool holds.
    public private(set) var starved = false
    public private(set) var reloadsThisLevel = 0
    /// Hit-zone margin E (screen pt). Set from the check screen, or a small value in touch mode.
    public var marginPt: Double
    /// «Мелкие цели»: drawn radii and hit zones times this (1: the BALANCE.md sizes).
    public let targetScale: Double
    /// With small targets, no hit zone is smaller than this (screen pt; `BalanceConfig.zoneFloor`).
    public let zoneFloorPt: Double
    /// The red signs to pass by (when the play has them and balance.json describes them).
    public private(set) var decoys: [Decoy] = []
    public let decoyConfig: DecoyConfig?
    public var time = 0.0

    public let earthCenter: Vec2
    public let earthRadius: Double

    private var rng: SeededRandom
    private var nextId = 1
    private var spawnTimer = 1.0
    private var lostSince: Double?
    private var recentHits: [Double] = []
    private var killStreak = 0
    private var decoyTimer = 0.0

    /// `targetScale`: 1 for the BALANCE.md sizes, `config.smallTargetScale` for small targets, with `zoneFloorPt`
    /// from `config.zoneFloor`. `decoys`: the play has red signs (if balance.json describes them).
    public init(config: BalanceConfig, screen: Vec2, marginPt: Double, targetScale: Double = 1, zoneFloorPt: Double = 0,
                decoys: Bool = false, seed: UInt64 = UInt64(Date().timeIntervalSince1970)) {
        self.config = config
        self.screen = screen
        self.marginPt = marginPt
        self.targetScale = min(1, max(0.4, targetScale))
        self.zoneFloorPt = max(0, zoneFloorPt)
        decoyConfig = decoys ? config.decoys : nil
        decoyTimer = config.decoys?.firstAfterSec ?? 0
        self.rng = SeededRandom(seed: seed)
        shields = config.earthShields
        // Earth is a low arc along the bottom edge through both bottom corners. Its top stands 15% of the screen
        // height above the edge (about 60 pt in landscape), so the meteors keep most of the height. The circle
        // through (±W/2, 0) and (0, h): R = (W²/4 + h²) / 2h.
        let h = screen.y * 0.15
        earthRadius = (screen.x * screen.x / 4 + h * h) / (2 * h)
        earthCenter = Vec2(screen.x / 2, screen.y - h + earthRadius)
        d = config.difficulty(level: 1)
        energy = config.energy?.max ?? 0
    }

    /// Energy one kill of this asteroid costs (0 when the mechanic is off). Never more than a full pool,
    /// so a mistuned balance.json cannot make a class impossible to kill.
    public func cost(_ a: Asteroid) -> Int { cost(className: a.className) }
    public func cost(className: String) -> Int {
        guard let e = config.energy else { return 0 }
        return min(e.cost(className), e.max)
    }

    /// Show the reload hint: looking at a meteor the pool cannot pay for, or not enough left for any class.
    public var needsReload: Bool {
        guard energyEnabled else { return false }
        let cheapest = BalanceConfig.classOrder.map { cost(className: $0) }.min() ?? 1
        return starved || energy < cheapest
    }

    /// The 3-blink (or 3-tap) reload: fills the pool. Returns false when it was already full.
    @discardableResult
    public func reload() -> Bool {
        guard energyEnabled, energy < energyMax else { return false }
        energy = energyMax
        reloadsThisLevel += 1
        return true
    }

    public var earthTopY: Double { earthCenter.y - earthRadius }

    /// Earth's surface at screen x (pt, y down): earthTopY in the middle, the bottom edge at the corners.
    public func earthSurfaceY(atX x: Double) -> Double {
        let dx = x - earthCenter.x
        let s = earthRadius * earthRadius - dx * dx
        return s > 0 ? earthCenter.y - s.squareRoot() : earthCenter.y
    }

    /// Hit-zone radius (screen pt) of a target drawn with `radius`: the radius plus E, both at the target scale,
    /// and with small targets never under the floor.
    public func zone(radius: Double) -> Double { max(radius + marginPt * targetScale, zoneFloorPt) }

    /// Distance of a point to an asteroid divided by the hit-zone radius (drawn radius + E). < 1 means inside.
    public func zoneRatio(_ p: Vec2, _ a: Asteroid) -> Double { p.distance(to: a.position) / zone(radius: a.radius) }

    /// Advances the game by `dt` seconds and returns what happened. `held`: the gaze point is the one kept from
    /// before an eyelid moved (a blink), not a fresh look. A meteor keeps burning under it; a red sign's look
    /// neither grows nor ends, so a blink cannot turn a passing glance into an error.
    @discardableResult
    public func update(dt: Double, gaze: GazeInput, held: Bool = false) -> [GameEvent] {
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

        // Pick at most one target: the asteroid with the smallest distance / zone-radius ratio. One that is already
        // charging counts with a zone `lockZone` times wider, so the lock holds while the aim wobbles (second iPhone
        // session: small fast meteors in level 6 slipped out of the aim 4-5 times each).
        var targetIndex: Int?
        // A red sign takes the look when it is the nearest thing to it: then no meteor is being looked at.
        var lookedDecoy: Int?
        if let p = point {
            var best = 1.0
            for (i, a) in asteroids.enumerated() {
                let r = zoneRatio(p, a) / (a.progress > 0 ? config.lockZone : 1)
                if r < best { best = r; targetIndex = i }
            }
            for (i, s) in decoys.enumerated() {
                let r = p.distance(to: s.position) / zone(radius: s.radius)
                if r < best { best = r; lookedDecoy = i; targetIndex = nil }
            }
        }

        // Energy: a target the pool cannot pay for does not charge.
        var nowStarved = false
        if let t = targetIndex, energyEnabled, cost(asteroids[t]) > energy {
            nowStarved = true
        }
        if nowStarved != starved { starved = nowStarved; events.append(.starved(nowStarved)) }

        let brake = config.brake(level: level)
        var i = 0
        while i < asteroids.count {
            var a = asteroids[i]
            let looked = i == targetIndex
            a.isTargeted = looked
            a.isStarved = looked && nowStarved
            // Reaction time counts the first look, whether or not there is energy to spend on it.
            if looked && a.firstLookTime == nil { a.firstLookTime = time }
            if looked && !nowStarved {
                a.progress += dt / a.dwellSec
            } else if looked {
                // Looked at but unaffordable: progress waits for the reload. It does not drain, and it is
                // not an attention slip, so the parent report stays about attention, not energy.
            } else if !freezeProgress && a.progress > 0 {
                a.progress = max(0, a.progress - dt / config.decayToZeroSec)
                if a.progress == 0 { a.slips += 1 }
            }
            // The gaze brake works with or without energy: slowing the meteor buys time to reload.
            let speed = looked ? 1 - brake : 1
            a.position = a.position + a.velocity * (dt * speed)
            a.rotation += dt * 0.6

            if a.progress >= 1 {
                let rec = record(a, destroyed: true)
                asteroids.remove(at: i)
                if let t = targetIndex, t > i { targetIndex = t - 1 }
                score += 10 * (BalanceConfig.classOrder.firstIndex(of: a.className).map { $0 + 1 } ?? 1)
                destroyedThisLevel += 1
                if energyEnabled {
                    let c = cost(a)
                    energy = max(0, energy - c)
                    events.append(.energySpent(cost: c, left: energy))
                }
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

        updateDecoys(dt: dt, looked: lookedDecoy, hold: held || freezeProgress, into: &events)

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

    /// Moves the red signs, counts the look on the one the gaze rests on, and sends in the next one. They are not
    /// part of a level: they keep flying when a level ends or restarts.
    private func updateDecoys(dt: Double, looked: Int?, hold: Bool, into events: inout [GameEvent]) {
        guard let cfg = decoyConfig else { return }
        var i = 0
        while i < decoys.count {
            var s = decoys[i]
            s.isLookedAt = i == looked
            if s.isLookedAt {
                if !hold {
                    if s.lookStart == nil { s.lookStart = time - dt }
                    s.dwellSec += dt
                }
            } else if !hold {
                s.dwellSec = 0
                s.lookStart = nil
            }
            s.position = s.position + s.velocity * dt
            if s.dwellSec >= cfg.errorDwellSec {
                decoys.remove(at: i)
                events.append(.decoyLooked(s, DecoyRecord(level: level, lifetimeSec: time - s.spawnTime, looked: true,
                                                          lookSec: max(0, (s.lookStart ?? time) - s.spawnTime))))
                continue
            }
            if s.position.distance(to: earthCenter) < earthRadius + s.radius * 0.3 {
                decoys.remove(at: i)
                events.append(.decoyPassed(s, DecoyRecord(level: level, lifetimeSec: time - s.spawnTime, looked: false,
                                                          lookSec: nil)))
                continue
            }
            decoys[i] = s
            i += 1
        }
        decoyTimer -= dt
        if decoyTimer <= 0, decoys.count < max(1, cfg.maxOnScreen) {
            let s = spawnDecoy()
            decoys.append(s)
            events.append(.decoySpawned(s))
            decoyTimer = BalanceConfig.lerp(cfg.intervalSec, d) * Double.random(in: 0.8...1.2, using: &rng)
        }
    }

    /// A red sign at one of the meteors' edges, aimed at Earth like them.
    public func spawnDecoy() -> Decoy {
        let cfg = decoyConfig ?? config.decoys ?? DecoyConfig()
        let r = cfg.sizePt / 2 * targetScale
        let (start, aimX) = entry(radius: r)
        let aim = Vec2(aimX, earthSurfaceY(atX: aimX))
        let v = (aim - start) * (1 / max(0.1, BalanceConfig.lerp(cfg.travelSec, d)))
        let s = Decoy(id: nextId, position: start, velocity: v, radius: r, spawnTime: time)
        nextId += 1
        return s
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
        energy = energyMax
        reloadsThisLevel = 0
        starved = false
    }

    private func record(_ a: Asteroid, destroyed: Bool) -> AsteroidRecord {
        AsteroidRecord(className: a.className, level: level, reactionSec: a.firstLookTime.map { $0 - a.spawnTime },
                       lifetimeSec: time - a.spawnTime, slips: a.slips, destroyed: destroyed)
    }

    /// Picks a class by the level's mix and an edge to come in from (see `entry`), and aims it at Earth so it
    /// arrives after the class's travel time.
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
        let r = cls.sizePt / 2 * targetScale
        let (start, aimX) = entry(radius: r)
        let aim = Vec2(aimX, earthSurfaceY(atX: aimX))
        let path = aim - start
        let travel = BalanceConfig.lerp(cls.travelSec, d)
        let v = path * (1 / max(0.1, travel))
        let a = Asteroid(id: nextId, className: name, position: start, velocity: v, radius: r, dwellSec: cls.dwellSec,
                         damage: cls.damage, spawnTime: time, rotation: Double.random(in: 0..<6.28, using: &rng))
        nextId += 1
        return a
    }

    public enum Edge: Sendable { case top, left, right }

    /// Where an asteroid of radius `r` comes in and the x of the Earth point it flies to. On a wide (landscape) screen
    /// 20% come in from each side, from the upper half of the height, and fly to the near half of Earth; the rest
    /// come in across the top and fly to a point halfway to the middle. A narrow screen only uses the top. Each keeps
    /// at least 2E from other fresh asteroids on its edge.
    func entry(radius r: Double, edge forced: Edge? = nil) -> (start: Vec2, aimX: Double) {
        let w = screen.x, h = screen.y
        var edge = forced ?? .top
        if forced == nil, w > h {
            let roll = Double.random(in: 0..<1, using: &rng)
            edge = roll < 0.2 ? .left : roll < 0.4 ? .right : .top
        }
        func spaced(_ lo: Double, _ hi: Double, crowded: (Double) -> Bool) -> Double {
            var v = Double.random(in: lo...max(lo + 1, hi), using: &rng)
            for _ in 0..<12 where crowded(v) { v = Double.random(in: lo...max(lo + 1, hi), using: &rng) }
            return v
        }
        switch edge {
        case .top:
            let x = spaced(r, w - r) { x in
                self.asteroids.contains { $0.position.y < h * 0.35 && abs($0.position.x - x) < 2 * self.marginPt }
                    || self.decoys.contains { $0.position.y < h * 0.35 && abs($0.position.x - x) < 2 * self.marginPt }
            }
            return (Vec2(x, -r), earthCenter.x + (x - earthCenter.x) * 0.5)
        case .left, .right:
            let left = edge == .left
            let y = spaced(min(r, h * 0.1), h * 0.45) { y in
                self.asteroids.contains {
                    (left ? $0.position.x < w * 0.25 : $0.position.x > w * 0.75) && abs($0.position.y - y) < 2 * self.marginPt
                } || self.decoys.contains {
                    (left ? $0.position.x < w * 0.25 : $0.position.x > w * 0.75) && abs($0.position.y - y) < 2 * self.marginPt
                }
            }
            let f = Double.random(in: 0.15...0.45, using: &rng)
            return (Vec2(left ? -r : w + r, y), left ? w * f : w * (1 - f))
        }
    }

    /// Test and debug hook: put an asteroid somewhere specific.
    public func insert(_ a: Asteroid) { asteroids.append(a) }
    public func insert(_ s: Decoy) { decoys.append(s) }
    public func removeAll() { asteroids.removeAll() }
}
