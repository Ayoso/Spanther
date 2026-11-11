import AVFoundation
import Foundation
import QuartzCore

/// One play of a rhythm track: the music, the notes, the judge and the clock that ties them to the tracking.
/// Two clocks: host time (CACurrentMediaTime, which ARKit frame timestamps and so wink onsets share) and track time
/// (seconds of the audio file as heard, 0 = its first sample). `startHost` links them.
final class RhythmSession: ObservableObject {
    enum Phase: Equatable {
        /// The start star: the player looks at it and winks (or taps it), which also recentres the aim.
        case ready
        case playing
        case done
    }

    @Published private(set) var phase: Phase = .ready

    let track: RhythmTrack
    let level: RhythmLevel
    let notes: [RhythmNote]
    /// Screen size (pt) the notes are laid out on, and each note's spot on it (screen pt).
    let screen: Vec2
    let points: [Vec2]
    /// Where the start star sits (screen pt).
    let startPoint: Vec2
    private(set) var judge: RhythmJudge
    /// Host time at which the track's first sample is heard.
    private(set) var startHost: Double?
    /// Track time at which each note was judged, for the hit and miss animations.
    private(set) var judgedAt: [Double?]
    /// Latency of the audio route when the music started (s): about 0.01 on the speaker, 0.15-0.25 on Bluetooth.
    private(set) var outputLatency = 0.0
    /// The score beat the best one kept for this track and level (set when the play ends).
    var isNewBest = false
    /// The note (its index) or the start star (`startTarget`) the hidden aim is locked on. The screen lights it up
    /// instead of drawing the aim, and a wink plays the locked note.
    private(set) var lock = GazeLock()
    static let startTarget = -1
    /// The garden behind the play (the same one as on the other screens) and the distractions of this track and
    /// level: the same on every play, like the notes.
    let garden: Garden
    let distractions: [Distraction]
    private var nextDistraction = 0

    /// An eye closure that landed in a note's window but could not play it, for the hint at that note.
    struct Rejection {
        var index: Int
        var reason: RhythmJudge.Rejected.Reason
        /// Track time of the closure.
        var time: Double
        /// Within the good window of the note: it looks like an attempt to play it, not a stray blink.
        var onBeat: Bool
    }

    private(set) var rejections: [Rejection] = []

    private var player: AVAudioPlayer?
    /// «Мелкие цели»: the scale the stars are drawn at and the hit zone was made with (1: the regular size).
    let targetScale: Double

    /// Seconds between the start wink and the first sample of the music.
    static let leadIn = 1.0

    init(track: RhythmTrack, level: RhythmLevel, screen: Vec2, measuredErrorPt: Double?, latencySec: Double,
         targetScale: Double = 1, zoneFloorPt: Double = 0) {
        self.track = track
        self.level = level
        self.screen = screen
        self.targetScale = min(1, max(0.4, targetScale))
        notes = track.chart(level)
        points = notes.map { Transforms.playAreaToScreen(x: $0.x, y: $0.y, size: screen) }
        startPoint = Transforms.playAreaToScreen(x: 0.5, y: 0.52, size: screen)
        judge = RhythmJudge(notes: notes,
                            rules: .level(level, measuredErrorPt: measuredErrorPt ?? 60, scale: targetScale,
                                          zoneFloorPt: zoneFloorPt),
                            latencySec: latencySec)
        judgedAt = Array(repeating: nil, count: notes.count)
        garden = Garden(size: screen, seed: Atlas.gardenSeed)
        distractions = DistractionPlan.make(level: level, garden: garden, from: 0, to: max(0, track.endSec - 1),
                                            seed: DistractionPlan.seed(track.id + "/" + level.rawValue))
    }

    /// Track time of a host time; -infinity before the music is scheduled.
    func trackTime(host: Double) -> Double { startHost.map { host - $0 } ?? -.infinity }

    /// The start wink (or tap) came: the music starts `leadIn` seconds later. Returns false when the audio file
    /// cannot be played.
    @discardableResult
    func begin(host: Double) -> Bool {
        guard phase == .ready else { return false }
        let name = (track.file as NSString).deletingPathExtension, ext = (track.file as NSString).pathExtension
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let p = try? AVAudioPlayer(contentsOf: url) else { return false }
        let session = AVAudioSession.sharedInstance()
        // Playback: the music plays with the ring/silent switch off, and other audio stops for it.
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        outputLatency = session.outputLatency
        p.prepareToPlay()
        player = p
        let start = host + Self.leadIn
        startHost = start
        // Started on the audio device clock, earlier by the route's latency, so the first sample is heard at `start`.
        let delay = start - CACurrentMediaTime() - outputLatency
        p.play(atTime: p.deviceCurrentTime + max(0.02, delay))
        phase = .playing
        return true
    }

    /// Moves the lock with the aim (screen pt, nil when there is none) at `host`. What can be locked: the start
    /// star before the music, then the notes on screen that are not played yet, each within the level's hit zone.
    func updateLock(aim: Vec2?, host: Double) {
        let reach = judge.rules.aimRadiusPt
        var targets: [GazeLock.Target] = []
        switch phase {
        case .ready:
            targets = [GazeLock.Target(id: Self.startTarget, position: startPoint, reach: reach)]
        case .playing:
            let t = trackTime(host: host)
            for i in notes.indices {
                if notes[i].time - level.leadSec > t { break }
                if judgedAt[i] == nil { targets.append(GazeLock.Target(id: i, position: points[i], reach: reach)) }
            }
        case .done:
            break
        }
        lock.update(aim: aim, time: host, targets: targets)
    }

    /// An eye closure with its onset (host time) and the aim as the lid came down (screen pt, nil if none).
    /// The locked note counts as aimed at, and it is the one played when an earlier note's window holds the
    /// closure too. Returns the note it played, if any.
    func closure(side: WinkSide, host: Double, aim: Vec2?) -> RhythmJudge.Hit? {
        play(side: side, host: host, aim: aim, locked: lock.locked)
    }

    /// A tap plays like a wink of the eye on that side of the screen, aimed where the finger is (touch mode).
    func tap(at p: Vec2, host: Double) -> RhythmJudge.Hit? {
        play(side: p.x < screen.x / 2 ? .left : .right, host: host, aim: p, locked: nil)
    }

    private func play(side: WinkSide, host: Double, aim: Vec2?, locked: Int?) -> RhythmJudge.Hit? {
        guard phase == .playing else { return nil }
        let t = trackTime(host: host)
        let pts = points
        let before = judge.lastRejected
        let hit = judge.closure(side: side, time: t, aimDistance: { i in i == locked ? 0 : aim.map { $0.distance(to: pts[i]) } },
                                prefer: locked)
        if let h = hit { judgedAt[h.index] = t }
        if hit == nil, let r = judge.lastRejected, r != before {
            rejections.append(Rejection(index: r.index, reason: r.reason, time: r.time, onBeat: r.distanceSec <= judge.rules.goodSec))
            if rejections.count > 8 { rejections.removeFirst() }
        }
        return hit
    }

    /// The distractions that began since the last call, up to `host`, for the CSV.
    func takeStartedDistractions(host: Double) -> [Distraction] {
        let t = trackTime(host: host)
        var out: [Distraction] = []
        while nextDistraction < distractions.count, distractions[nextDistraction].start <= t {
            out.append(distractions[nextDistraction])
            nextDistraction += 1
        }
        return out
    }

    /// Marks the notes whose window has passed as missed and ends the play when the music is over. Returns the
    /// missed notes.
    @discardableResult
    func tick(host: Double) -> [Int] {
        guard phase == .playing else { return [] }
        let t = trackTime(host: host)
        let missed = judge.advance(to: t)
        for i in missed { judgedAt[i] = t }
        if t >= track.endSec { finish() }
        return missed
    }

    /// The note the player should look at next: the first one not judged yet.
    func nextOpen(after t: Double) -> Int? {
        notes.indices.first { judgedAt[$0] == nil && notes[$0].time + judge.rules.okSec >= t }
    }

    func finish() {
        guard phase != .done else { return }
        _ = judge.advance(to: .infinity)
        for i in judgedAt.indices where judgedAt[i] == nil { judgedAt[i] = notes[i].time }
        player?.setVolume(0, fadeDuration: 0.6)
        let p = player
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { p?.stop() }
        phase = .done
    }

    /// Stops the music at once (the player left the screen).
    func stop() {
        player?.stop()
        if phase == .playing { phase = .done }
    }
}

/// Best results per track and level, and the player's wink delay, kept between launches.
enum RhythmRecords {
    private static let defaults = UserDefaults.standard

    static func bestStars(_ track: RhythmTrack, _ level: RhythmLevel) -> Int {
        defaults.integer(forKey: "rhythm.stars.\(track.id).\(level.rawValue)")
    }

    static func bestScore(_ track: RhythmTrack, _ level: RhythmLevel) -> Int {
        defaults.integer(forKey: "rhythm.score.\(track.id).\(level.rawValue)")
    }

    /// Saves a result; returns true when it is a new best score.
    @discardableResult
    static func save(_ track: RhythmTrack, _ level: RhythmLevel, score: Int, stars: Int) -> Bool {
        let s = "rhythm.score.\(track.id).\(level.rawValue)", st = "rhythm.stars.\(track.id).\(level.rawValue)"
        defaults.set(max(stars, defaults.integer(forKey: st)), forKey: st)
        guard score > defaults.integer(forKey: s) else { return false }
        defaults.set(score, forKey: s)
        return true
    }

    /// Delay from the beat to the eye crossing the closed line (s), learned in play and seeded by the wink test.
    static var latencySec: Double {
        get { defaults.object(forKey: "rhythm.latency") as? Double ?? 0.12 }
        set { defaults.set(min(0.3, max(-0.05, newValue)), forKey: "rhythm.latency") }
    }
}
