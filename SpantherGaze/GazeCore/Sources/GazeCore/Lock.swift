import Foundation

// Target lock for a hidden aim. The screen does not show where the gaze lands: a cursor that sits a little off the
// spot the player looks at pulls the eyes after it, and the eyes and the cursor drift off together. Instead the
// target the aim is near lights up and holds the aim, the way gaze menus highlight the item under the eyes.

public struct GazeLockConfig: Equatable, Sendable {
    /// A locked target lets go when the aim is further from it than its reach times this, so an aim that wavers
    /// at the edge of the reach does not make the highlight flicker.
    public var releaseFactor = 1.4
    /// Another target in reach takes the lock when the aim is closer to it than this share of the distance to the
    /// locked one (both in reaches).
    public var switchRatio = 0.6
    /// The lock holds this long without an aim (s): the face lost for a moment, or a glance off the screen.
    public var graceSec = 0.35

    public init() {}
}

/// Which target the aim is locked on. Each frame the caller passes the targets that can be locked then, each with
/// an id, its spot and its reach (screen pt), and the aim (screen pt).
public struct GazeLock: Sendable {
    public struct Target: Equatable, Sendable {
        public var id: Int
        /// Screen pt.
        public var position: Vec2
        /// The aim locks the target when it is this close (screen pt).
        public var reach: Double

        public init(id: Int, position: Vec2, reach: Double) {
            self.id = id; self.position = position; self.reach = reach
        }
    }

    public let config: GazeLockConfig
    /// The locked target's id, and the time the lock began (s).
    public private(set) var locked: Int?
    public private(set) var since: Double?
    /// Last time the aim was within the locked target's release distance (s).
    private var lastNear: Double?

    public init(config: GazeLockConfig = GazeLockConfig()) { self.config = config }

    /// One frame: the aim (screen pt, nil when there is none) at `time` (s), and the targets that can be locked now.
    /// The nearest target in reach takes the lock; it keeps it until the aim moves past its release distance,
    /// another target in reach is clearly closer, the target is no longer passed, or the aim has been gone longer
    /// than the grace time. Returns the locked target's id.
    @discardableResult
    public mutating func update(aim: Vec2?, time: Double, targets: [Target]) -> Int? {
        let current = locked.flatMap { id in targets.first { $0.id == id } }
        if locked != nil, current == nil { release() }
        guard let a = aim else {
            if let near = lastNear, time - near > config.graceSec { release() }
            return locked
        }
        // Distances in reaches, so a target with a bigger reach is as easy to lock from its edge.
        func reaches(_ t: Target) -> Double { a.distance(to: t.position) / t.reach }
        var best: (id: Int, d: Double)?
        for t in targets where t.reach > 0 {
            let d = reaches(t)
            if d <= 1, d < best?.d ?? .infinity { best = (t.id, d) }
        }
        if let c = current {
            let d = reaches(c)
            if d <= config.releaseFactor {
                lastNear = time
                if let b = best, b.id != c.id, b.d < config.switchRatio * d { lock(b.id, time) }
                return locked
            }
            release()
        }
        if let b = best { lock(b.id, time) }
        return locked
    }

    public mutating func reset() { release() }

    private mutating func lock(_ id: Int, _ time: Double) {
        locked = id
        since = time
        lastNear = time
    }

    private mutating func release() {
        locked = nil
        since = nil
        lastNear = nil
    }
}
