import Foundation

// Rhythm mode: notes fall on the beat of a track. The player looks at a note (the calibrated gaze aims) and winks
// when it lands. Times are seconds on the track clock: 0 is the first sample of the audio file, as heard.

/// Which eye a note asks for. `any` takes either eye (and, on the easy level, both eyes for players who cannot wink).
public enum NoteSide: String, Codable, Sendable, CaseIterable {
    case any, left, right
}

public struct RhythmNote: Equatable, Codable, Sendable {
    /// When the eye should close (track clock).
    public var time: Double
    /// Position in the play area, 0...1 from left to right and from top to bottom.
    public var x: Double
    public var y: Double
    public var side: NoteSide

    public init(time: Double, x: Double, y: Double, side: NoteSide = .any) {
        self.time = time; self.x = x; self.y = y; self.side = side
    }
}

public enum RhythmLevel: String, Codable, Sendable, CaseIterable {
    case easy, normal, hard

    /// Shortest gap between two notes and the most notes per second this level asks for. Winking faster than about
    /// twice a second is hard for anyone, and much slower for children.
    var minGapSec: Double { switch self { case .easy: return 1.0; case .normal: return 0.55; case .hard: return 0.4 } }
    var maxPerSec: Double { switch self { case .easy: return 0.8; case .normal: return 1.3; case .hard: return 2.0 } }
    /// How far one note is from the next, in screen widths.
    var step: Double { switch self { case .easy: return 0.17; case .normal: return 0.21; case .hard: return 0.25 } }
    /// The weakest accent this level plays (see `RhythmTrack.accents`).
    var minStrength: Int { switch self { case .easy: return 3; case .normal: return 2; case .hard: return 1 } }
    /// Seconds a note is on screen before it lands.
    public var leadSec: Double { switch self { case .easy: return 1.8; case .normal: return 1.35; case .hard: return 1.0 } }
}

/// One entry of tracks.json: an audio file in the app bundle and its beat grid. To use another song, put the file
/// in Resources and give its tempo and the second of its first beat; the notes are written from the grid, or from
/// the song's accents when it has them.
public struct RhythmTrack: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var author: String
    public var license: String
    /// File name in the bundle, with extension.
    public var file: String
    public var bpm: Double
    /// Second of the file where the first playable beat falls.
    public var firstBeatSec: Double
    /// Playable beats from the first one; the track ends a bar after them.
    public var beats: Int
    /// Beats per musical phrase (default 8): the note path takes a new direction at each phrase.
    public var phraseBeats: Int?
    /// Optional musical accents the notes follow, as [beat, strength] pairs. The beat counts from the first playable
    /// one (x.5 for an off-beat); the strength is 3 for the strongest moments (downbeats, long melody notes), 2 for
    /// melody notes on the beat and 1 for the rest. Easy plays the 3s, normal the 2s and up, hard all of them, as far
    /// as the level's gap and rate allow. Without accents the notes follow a fixed pattern on the beats.
    public var accents: [[Double]]?
    /// Optional hand-made notes per level ("easy", "normal", "hard"); a level without them is generated.
    public var notes: [String: [RhythmNote]]?

    public init(id: String, title: String, author: String, license: String, file: String, bpm: Double,
                firstBeatSec: Double, beats: Int, phraseBeats: Int? = nil, accents: [[Double]]? = nil,
                notes: [String: [RhythmNote]]? = nil) {
        self.id = id; self.title = title; self.author = author; self.license = license; self.file = file
        self.bpm = bpm; self.firstBeatSec = firstBeatSec; self.beats = beats; self.phraseBeats = phraseBeats
        self.accents = accents
        self.notes = notes
    }

    public var beatSec: Double { 60 / bpm }
    public var endSec: Double { firstBeatSec + Double(beats + 4) * beatSec }

    public static func load(from data: Data) throws -> [RhythmTrack] {
        try JSONDecoder().decode([RhythmTrack].self, from: data)
    }

    /// The notes for a level: hand-made ones if the track has them, otherwise generated.
    public func chart(_ level: RhythmLevel) -> [RhythmNote] {
        if let n = notes?[level.rawValue], !n.isEmpty { return n.sorted { $0.time < $1.time } }
        return ChartGenerator.notes(for: self, level: level)
    }
}

/// Writes notes from a track's accents or beat grid: which beats get a note (by level and tempo) and where each note
/// sits.
public enum ChartGenerator {
    /// Note patterns over an 8-beat phrase, sparse to dense.
    static let masks: [[Bool]] = ([
        [1, 0, 0, 0, 1, 0, 0, 0],
        [1, 0, 1, 0, 1, 0, 1, 0],
        [1, 0, 1, 0, 1, 0, 1, 1],
        [1, 1, 1, 0, 1, 1, 1, 0],
        [1, 1, 1, 1, 1, 1, 1, 0],
        [1, 1, 1, 1, 1, 1, 1, 1],
    ] as [[Int]]).map { $0.map { $0 == 1 } }

    /// Play area kept clear of the screen edges, the top bar and the bottom (fractions of the screen).
    static let area = (x: 0.1...0.9, y: 0.22...0.8)

    /// The densest pattern whose notes are never closer than the level's gap and never more than its rate.
    static func mask(level: RhythmLevel, beatSec: Double) -> Int {
        var best = 0
        for (i, m) in masks.enumerated() {
            let on = m.indices.filter { m[$0] }
            var gap = 8
            for (a, b) in zip(on, on.dropFirst() + [on[0] + 8]) { gap = min(gap, b - a) }
            let rate = Double(on.count) / (8 * beatSec)
            if Double(gap) * beatSec >= level.minGapSec - 1e-9, rate <= level.maxPerSec + 1e-9 { best = i }
        }
        return best
    }

    /// Height of a landscape phone screen in widths (844 x 390 pt on the iPhone 13), for distances between notes.
    static let aspect = 0.46
    /// Notes are at least this far from the three before them, which may still be on screen (screen widths).
    static let minSeparation = 0.12

    /// The next note's spot: about one step from the last, inside the play area and clear of the notes before it,
    /// turning as little as it can from the path's heading. Tries 24 headings all round at three step lengths.
    static func nextPosition(from pos: (x: Double, y: Double), heading: inout Double, step: Double,
                             after recent: ArraySlice<RhythmNote>, rng: inout Rng) -> (x: Double, y: Double) {
        var best: (x: Double, y: Double, dir: Double, score: Double)?
        let jitter = (rng.next() - 0.5) * 0.25
        for (scale, cost) in [(1.0, 0.0), (1.35, 1.0), (0.75, 1.5)] {
            for k in 0..<24 {
                // 0, +15°, -15°, +30°, ... so ties go to the straighter path.
                let turn = Double((k + 1) / 2) * (k % 2 == 0 ? -1 : 1) * Double.pi / 12 + jitter
                let dir = heading + turn
                let nx = pos.x + cos(dir) * step * scale, ny = pos.y + sin(dir) * step * scale / aspect
                guard area.x.contains(nx), area.y.contains(ny) else { continue }
                let sep = recent.map { hypot($0.x - nx, ($0.y - ny) * aspect) }.min() ?? 1
                // Clear of the recent notes first, then the usual step and the smallest turn; if nothing is clear,
                // the most clear.
                let score = sep >= minSeparation ? 100 - abs(turn) - cost : sep * 100
                if best == nil || score > best!.score { best = (nx, ny, dir, score) }
            }
        }
        guard let b = best else {
            // The step does not fit anywhere (a tiny area): stay inside it.
            return (min(max(pos.x, area.x.lowerBound), area.x.upperBound), min(max(pos.y, area.y.lowerBound), area.y.upperBound))
        }
        heading = b.dir
        return (b.x, b.y)
    }

    public static func notes(for track: RhythmTrack, level: RhythmLevel, seed: UInt64 = 1) -> [RhythmNote] {
        let phrase = Double(max(2, track.phraseBeats ?? 8))
        var rng = Rng(seed: seed &+ UInt64(level.rawValue.count) &* 7919 &+ UInt64(track.bpm * 100))
        var notes: [RhythmNote] = []
        var pos = (x: 0.5, y: 0.5)
        var heading = rng.next() * 2 * Double.pi
        var lastPhrase = -1
        for beat in beats(for: track, level: level) {
            // A new phrase starts somewhere new.
            let ph = Int((beat / phrase).rounded(.down))
            if ph != lastPhrase {
                heading += (rng.next() - 0.5) * 2.4
                lastPhrase = ph
            }
            if !notes.isEmpty {
                pos = nextPosition(from: pos, heading: &heading, step: level.step, after: notes.suffix(3), rng: &rng)
            }
            let side: NoteSide = level == .hard ? (pos.x < 0.5 ? .left : .right) : .any
            notes.append(RhythmNote(time: track.firstBeatSec + beat * track.beatSec, x: pos.x, y: pos.y, side: side))
        }
        return notes
    }

    /// The beats that get a note, counted from the first playable beat, in order.
    static func beats(for track: RhythmTrack, level: RhythmLevel) -> [Double] {
        if let accents = track.accents, !accents.isEmpty { return accentBeats(accents, track: track, level: level) }
        let phrase = max(2, track.phraseBeats ?? 8)
        let dense = mask(level: level, beatSec: track.beatSec)
        let phrases = (track.beats + phrase - 1) / phrase
        var out: [Double] = []
        for ph in 0..<phrases {
            // Every fourth phrase and the last one breathe: one pattern sparser. The first one is sparser too.
            let breathe = ph == 0 || ph % 4 == 3 || ph == phrases - 1
            let m = masks[max(0, dense - (breathe ? 1 : 0))]
            for b in 0..<phrase where ph * phrase + b < track.beats && m[b % 8] {
                out.append(Double(ph * phrase + b))
            }
        }
        return out
    }

    /// Notes are counted over stretches this long (s) for the level's rate.
    static let rateWindowSec = 4.0

    /// The accents the level plays: strongest first and earlier first within a strength, each kept when it is at
    /// least the level's gap from every kept one and no stretch of `rateWindowSec` would hold more than the level's
    /// rate. So the downbeats stay, and weaker accents fill in where the music leaves room.
    static func accentBeats(_ accents: [[Double]], track: RhythmTrack, level: RhythmLevel) -> [Double] {
        let p = track.beatSec
        let limit = max(1, Int(level.maxPerSec * rateWindowSec + 1e-9))
        let candidates = accents.compactMap { a -> (beat: Double, strength: Int)? in
            guard a.count >= 2, a[0].isFinite, a[0] >= 0, a[0] < Double(track.beats), a[1].isFinite else { return nil }
            return (a[0], Int(a[1].rounded()))
        }
        let ordered = candidates.filter { $0.strength >= level.minStrength }
            .sorted { $0.strength != $1.strength ? $0.strength > $1.strength : $0.beat < $1.beat }
        var kept: [Double] = []
        for c in ordered {
            let i = kept.firstIndex { $0 >= c.beat } ?? kept.count
            if i < kept.count, kept[i] == c.beat { continue }
            if i > 0, (c.beat - kept[i - 1]) * p < level.minGapSec - 1e-9 { continue }
            if i < kept.count, (kept[i] - c.beat) * p < level.minGapSec - 1e-9 { continue }
            var with = kept
            with.insert(c.beat, at: i)
            if crowded(with.map { $0 * p }, at: i, window: rateWindowSec, limit: limit) { continue }
            kept = with
        }
        return kept
    }

    /// True when a stretch of `window` seconds that holds `times[i]` holds more than `limit` of the sorted times.
    static func crowded(_ times: [Double], at i: Int, window: Double, limit: Int) -> Bool {
        var start = i
        while start > 0, times[start - 1] > times[i] - window { start -= 1 }
        for s in start...i {
            var e = s
            while e + 1 < times.count, times[e + 1] < times[s] + window { e += 1 }
            if e - s + 1 > limit { return true }
        }
        return false
    }
}

/// How a note was played.
public enum Judgement: String, Sendable, CaseIterable {
    case perfect, good, ok, miss
}

public struct RhythmRules: Equatable, Sendable {
    /// Windows around the beat, after the player's own delay is taken off.
    public var perfectSec = 0.09
    public var goodSec = 0.16
    public var okSec = 0.24
    /// A note counts only when the aim is this close to it as the eye closes (screen pt).
    public var aimRadiusPt: Double
    /// Both eyes closing counts on `any` notes: the easy level, for children who cannot wink one eye.
    public var acceptBlink: Bool

    public init(aimRadiusPt: Double, acceptBlink: Bool) {
        self.aimRadiusPt = aimRadiusPt
        self.acceptBlink = acceptBlink
    }

    /// The rules for a level, with the hit zone grown by the calibration's measured error. `scale` and
    /// `zoneFloorPt`: «Мелкие цели», the zone times the scale but never under the floor (BalanceConfig.zoneFloor).
    public static func level(_ l: RhythmLevel, measuredErrorPt: Double, scale: Double = 1,
                             zoneFloorPt: Double = 0) -> RhythmRules {
        let base: Double
        switch l {
        case .easy: base = 90
        case .normal: base = 70
        case .hard: base = 55
        }
        let zone = (base + max(0, min(measuredErrorPt, 90))) * min(1, max(0.4, scale))
        return RhythmRules(aimRadiusPt: max(zone, zoneFloorPt), acceptBlink: l == .easy)
    }
}

/// Judges eye closures against the notes, keeps score and learns how late the player's winks land.
public struct RhythmJudge: Sendable {
    public struct Hit: Equatable, Sendable {
        public var index: Int
        public var judgement: Judgement
        /// Closure time minus the note's time (s), before the learned delay is taken off.
        public var offsetSec: Double
        /// The aim was further than the hit zone: judged a miss.
        public var offTarget: Bool
    }

    public let notes: [RhythmNote]
    public var rules: RhythmRules
    /// The player's usual delay from the beat to the eye crossing the closed line (s), learned from each hit and
    /// carried to the next track.
    public private(set) var latencySec: Double
    public private(set) var results: [Judgement?]
    public private(set) var combo = 0
    public private(set) var maxCombo = 0
    public private(set) var score = 0
    /// Closures with the wrong eye on a side note, closures far from any note, and misses because the aim was off.
    public private(set) var wrongEye = 0
    public private(set) var stray = 0
    public private(set) var offTarget = 0
    /// The last closure that landed in a note's window but could not play it, so the screen can say why at that
    /// note: a blink on a level that needs one eye, or the wrong eye on a side note.
    public private(set) var lastRejected: Rejected?
    /// For each note a closure was judged against: the closure's time minus the note's (s) and the eye that
    /// closed. Nil for notes no closure reached.
    public private(set) var offsets: [Double?]
    public private(set) var playedBy: [WinkSide?]
    /// One-eye closures the judge has seen, per eye: the ones that played a note and the ones that did not.
    public private(set) var closuresLeft = 0
    public private(set) var closuresRight = 0
    private var first = 0

    public struct Rejected: Equatable, Sendable {
        public enum Reason: String, Sendable {
            /// Both eyes closed where the note needs one.
            case blink
            /// The other eye than the note asks for.
            case wrongEye
        }

        public var index: Int
        public var reason: Reason
        /// Track time of the closure.
        public var time: Double
        /// How far the closure was from the note's expected time (s).
        public var distanceSec: Double
    }

    public init(notes: [RhythmNote], rules: RhythmRules, latencySec: Double = 0.08) {
        self.notes = notes
        self.rules = rules
        self.latencySec = latencySec
        results = Array(repeating: nil, count: notes.count)
        offsets = Array(repeating: nil, count: notes.count)
        playedBy = Array(repeating: nil, count: notes.count)
    }

    /// The beat the next closure is judged against: the note's time plus the player's delay.
    public func expected(_ i: Int) -> Double { notes[i].time + latencySec }

    /// One eye closure at `time` (track clock). `aimDistance(i)`: how far the aim was from note `i` just before the
    /// lid came down (screen pt), nil when there was no aim. `prefer`: the note the aim is locked on (GazeLock); it
    /// is played when its window holds the closure and its eye matches, even if an earlier note's window holds the
    /// closure too. Otherwise the earliest such note is played. Returns the note it played, or nil when it played
    /// none.
    public mutating func closure(side: WinkSide, time: Double, aimDistance: (Int) -> Double?, prefer: Int? = nil) -> Hit? {
        if side == .left { closuresLeft += 1 } else if side == .right { closuresRight += 1 }
        var i = first
        while i < notes.count, expected(i) < time - rules.okSec { i += 1 }
        // The open notes whose window holds the closure and whose eye matches: the preferred one, or the earliest.
        var sawWrongEye = false
        var pick: Int?
        // The note a rejected closure was meant for: the preferred one, or the earliest in the window.
        var rejected: Int?
        while i < notes.count, expected(i) <= time + rules.okSec {
            defer { i += 1 }
            guard results[i] == nil else { continue }
            let n = notes[i]
            if side == .both {
                // A two-eye closure is an ordinary blink unless the level takes it.
                guard n.side == .any, rules.acceptBlink else {
                    if rejected == nil || i == prefer { rejected = i }
                    continue
                }
            } else if n.side != .any, n.side.rawValue != side.rawValue {
                sawWrongEye = true
                if rejected == nil || i == prefer { rejected = i }
                continue
            }
            if pick == nil || i == prefer { pick = i }
            if prefer == nil || i == prefer { break }
        }
        guard let k = pick else {
            if sawWrongEye { wrongEye += 1 } else if side != .both { stray += 1 }
            if let r = rejected {
                lastRejected = Rejected(index: r, reason: side == .both ? .blink : .wrongEye, time: time,
                                        distanceSec: abs(time - expected(r)))
            }
            return nil
        }
        let offset = time - notes[k].time
        let d = abs(time - expected(k))
        let aimed = aimDistance(k).map { $0 <= rules.aimRadiusPt } ?? false
        let j: Judgement = !aimed ? .miss : d <= rules.perfectSec ? .perfect : d <= rules.goodSec ? .good : .ok
        record(k, j)
        offsets[k] = offset
        playedBy[k] = side
        if aimed {
            // Learn the delay slowly and within reason, so one odd wink does not move the windows.
            latencySec = min(0.3, max(-0.05, latencySec + 0.15 * (offset - latencySec)))
        } else {
            offTarget += 1
        }
        return Hit(index: k, judgement: j, offsetSec: offset, offTarget: !aimed)
    }

    /// Notes whose window has closed by `time` without a closure are missed. Returns their indices.
    public mutating func advance(to time: Double) -> [Int] {
        var missed: [Int] = []
        while first < notes.count, expected(first) + rules.okSec < time {
            if results[first] == nil { record(first, .miss); missed.append(first) }
            first += 1
        }
        return missed
    }

    private mutating func record(_ i: Int, _ j: Judgement) {
        results[i] = j
        if j == .miss {
            combo = 0
        } else {
            combo += 1
            maxCombo = max(maxCombo, combo)
            let base = j == .perfect ? 100 : j == .good ? 70 : 40
            score += base * (20 + min(combo, 40)) / 20
        }
    }

    public var finished: Bool { results.allSatisfy { $0 != nil } }

    public func count(_ j: Judgement) -> Int { results.filter { $0 == j }.count }

    /// Share of the best possible play: perfect 1, good 0.7, ok 0.4, miss 0.
    public var accuracy: Double {
        guard !notes.isEmpty else { return 0 }
        let s = Double(count(.perfect)) + 0.7 * Double(count(.good)) + 0.4 * Double(count(.ok))
        return s / Double(notes.count)
    }

    /// 0 to 3 stars for the results screen.
    public var stars: Int { accuracy >= 0.9 ? 3 : accuracy >= 0.75 ? 2 : accuracy >= 0.5 ? 1 : 0 }

    /// Closure time minus note time (s) of every note that was played (perfect, good or ok), in note order.
    public var playedOffsets: [Double] {
        notes.indices.compactMap { i in
            guard let r = results[i], r != .miss else { return nil }
            return offsets[i]
        }
    }

    /// How late the played notes were on average (s; negative: early). It holds the player's own delay and the
    /// time the wink detector needs, so it says little by itself; the deviation below is measured from it.
    public var meanOffsetSec: Double? {
        let o = playedOffsets
        return o.isEmpty ? nil : o.reduce(0, +) / Double(o.count)
    }

    /// How far the played notes were from the player's own mean lateness, on average (s): the steadiness of the
    /// timing, free of a constant delay. Nil with fewer than two played notes.
    public var timingDeviationSec: Double? {
        let o = playedOffsets
        guard o.count >= 2, let mean = meanOffsetSec else { return nil }
        return o.reduce(0) { $0 + abs($1 - mean) } / Double(o.count)
    }

    /// Winks of one eye, and how many of them played a note (perfect, good or ok).
    public func winks(_ side: WinkSide) -> (played: Int, all: Int) {
        let all = side == .left ? closuresLeft : side == .right ? closuresRight : 0
        let played = notes.indices.filter { playedBy[$0] == side && results[$0] != nil && results[$0] != .miss }.count
        return (played, all)
    }

    /// Share of one eye's winks that played a note, 0...1; nil when that eye never winked.
    public func winkAccuracy(_ side: WinkSide) -> Double? {
        let w = winks(side)
        return w.all > 0 ? Double(w.played) / Double(w.all) : nil
    }
}

/// Small seeded generator (SplitMix64), so a track's notes are the same on every play.
struct Rng {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func nextUInt() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in 0..<1.
    mutating func next() -> Double { Double(nextUInt() >> 11) / Double(UInt64(1) << 53) }
}
