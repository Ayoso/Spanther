import AVFoundation
import Foundation
import QuartzCore
import UIKit

enum Route: Equatable {
    case menu
    case calibration
    case check
    case result
    case game
    /// Measures one-eye winks, the input of the rhythm mode.
    case winkTest
    /// Rhythm mode: notes land on the beat of a track; look at each one and wink as it lands.
    case rhythm
}

enum ControlMode { case eyes, touch }

/// Live tracking numbers for the debug overlay, refreshed about 10 times a second.
final class TrackingStatus: ObservableObject {
    @Published var fps = 0.0
    @Published var processingMs = 0.0
    @Published var faceFound = false
    @Published var features: GazeFeatures?
    @Published var gaze: Vec2?
    @Published var blink: (left: Double, right: Double)?
    /// Each eye's current open level, which the blink thresholds ride on.
    @Published var blinkBase: (left: Double, right: Double) = (0, 0)
    @Published var gazeFrozen = false
    /// Blinks counted toward the next reload (0...2).
    @Published var pendingBlinks = 0
    @Published var reloadBlinksNeeded = 3
    @Published var blinksTotal = 0
    /// Camera format, formats offered, thermal state and Low Power Mode.
    @Published var tracking = TrackingInfo()
    /// Wink test: the last closure the wink detector reported, and the level at which each eye counts as closed.
    @Published var lastWink: WinkEvent?
    @Published var winkCloseLevel: (left: Double, right: Double) = (0.6, 0.6)
    /// Aim adapter: the correction it adds now (screen pt), the labels it learned and the ones it left out.
    @Published var aimCorrection = Vec2.zero
    @Published var aimLabels = 0
    @Published var aimRejected = 0
    /// The light ARKit estimates around the face (lumens), for the "too dark" hint and the debug overlay.
    @Published var light: Double?
}

/// App state shared by all screens. Main thread only.
final class AppModel: ObservableObject {
    @Published var route: Route = .menu {
        didSet {
            lookedAtMeteor = nil
            applyBrightness()
        }
    }
    @Published var mode: ControlMode = .eyes
    @Published var report: AccuracyReport?
    @Published var showDebug = false
    @Published var usePupils = true
    /// Adds the aim adapter's correction to the gaze. Off: the adapter still learns and the CSV still shows its
    /// correction, but the aim is the calibrated model's alone, for comparing the two on the phone.
    @Published var adaptAim = true
    /// Night vision: for playing in a dark room. ARKit's face tracking needs some light (Apple says it does not
    /// work in total darkness), and there the only light on the face is the screen's. So the screen goes to full
    /// brightness on the play screens, the camera runs at its slowest frame rate for a longer exposure, and the
    /// gaze model drops the Vision pupils, which are not found in the dark. Switching it asks for a new
    /// calibration, since the model is fitted on the features it plays with. Kept between launches.
    @Published var nightVision = UserDefaults.standard.bool(forKey: "nightVision") {
        didSet {
            guard nightVision != oldValue else { return }
            UserDefaults.standard.set(nightVision, forKey: "nightVision")
            model = nil
            adapter = nil
            report = nil
            aimCorrection = .zero
            filter.reset()
            if FaceTracker.isSupported { tracker.setNightVision(nightVision) }
            logTracking()
            applyBrightness()
        }
    }
    /// Host time the app started, when the garden begins to grow.
    let launchTime = CACurrentMediaTime()
    /// The app is in front (scene phase active).
    private var active = true
    /// The screen brightness before night vision raised it, to give back on the menu or in the background.
    private var savedBrightness: CGFloat?
    /// Where «Играть» on the calibration result leads.
    private(set) var afterCalibration: Route = .game

    let status = TrackingStatus()
    let tracker = FaceTracker()
    let balance: BalanceConfig
    private(set) var logger = SessionLogger()

    /// Current gaze for the game (screen pt). Not @Published: read every frame by the scene.
    private(set) var gaze: GazeInput = .lost
    private(set) var model: RidgeModel?
    private var filter = OneEuroFilter2D()
    private var lastStatusPush = 0.0
    private var blinkDetector = BlinkDetector(EnergyConfig())
    private var winkDetector = WinkDetector()
    /// Closures the wink detector reported since the current wink test run started (tracking clock).
    private(set) var winks: [WinkEvent] = []
    /// Time of the last 3-blink reload not yet taken by the game.
    private var pendingReloadTime: Double?
    private var lastSampleTime = 0.0

    /// Keeps the calibrated aim on target when the phone is held at another tilt (GazeAdapter). Made at each
    /// calibration, warmed on the check dots, then taught by the meteors being burned and the rhythm notes winked.
    private(set) var adapter: GazeAdapter?
    /// The model's raw predictions (screen pt, before the correction) of the last 0.6 s with open eyes, with the
    /// head pose: where the player looked just before an eye closure or a tap.
    private var recentRaw: [(time: Double, raw: Vec2, pose: HeadPose)] = []
    /// What the adapter adds to the prediction right now (screen pt).
    private(set) var aimCorrection = Vec2.zero
    /// The meteor the game takes as looked at (screen pt), set by the scene on each frame of an eye game.
    var lookedAtMeteor: Vec2?
    /// A meteor being looked at teaches the adapter a little on every frame: 20 frames weigh as much as one note.
    static let meteorLabelWeight = 1.0 / 20
    private var checkPoses: [HeadPose] = []

    /// Rhythm mode: the tracks in the bundle (tracks.json) and the play in progress.
    let rhythmTracks: [RhythmTrack]
    @Published private(set) var rhythm: RhythmSession?
    private var rhythmTimer: Timer?

    /// Points per centimetre. Current iPhones are about 60 pt/cm (163 pt per inch on 2x, ~153 on 3x Pro).
    let ptPerCm = 60.0
    var featureSet: GazeFeatures.FeatureSet { usePupils && !nightVision ? .eyesAndPupils : .eyes }

    // Collection during calibration / check
    private var collecting: (target: Vec2, kind: String)?
    private var collectedFeatures: [GazeFeatures] = []
    private var collectedGaze: [Vec2] = []
    private var calibrationSet: [(target: Vec2, features: [GazeFeatures])] = []
    private var checkSet: [(target: Vec2, predictions: [Vec2])] = []
    private var distances: [Double] = []

    init() {
        guard let url = Bundle.main.url(forResource: "balance", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let cfg = try? BalanceConfig.load(from: data) else {
            fatalError("balance.json is missing or invalid")
        }
        balance = cfg
        rhythmTracks = Bundle.main.url(forResource: "tracks", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? RhythmTrack.load(from: $0) } ?? []
        blinkDetector = BlinkDetector(cfg.energy ?? EnergyConfig())
        status.reloadBlinksNeeded = (cfg.energy ?? EnergyConfig()).reloadBlinks
        if !FaceTracker.isSupported { mode = .touch }
        if let bot = autoplay {
            // CI smoke test in the Simulator: skip the menu and let the bot play.
            if bot == "wink" {
                route = .winkTest
                startWinkBot()
            } else if bot == "rhythm" {
                mode = .eyes
                route = .rhythm
            } else {
                mode = bot == "eyes" ? .eyes : .touch
                route = .game
            }
        }
        tracker.onSample = { [weak self] s in self?.handle(s) }
        tracker.onInfo = { [weak self] info in
            self?.status.tracking = info
            self?.logTracking()
        }
    }

    /// Writes the camera format and device state into the current session CSV.
    private func logTracking() {
        let i = tracker.info
        logger.tracking(format: i.format, offered: i.offered, thermal: i.thermal, lowPower: i.lowPower,
                        screen: i.screen, vision: i.vision, night: i.night, time: CACurrentMediaTime())
    }

    /// Night vision lights the face with the screen: full brightness on every screen but the menu, while the app
    /// is in front. The player's own brightness comes back on the menu and when the app leaves the screen.
    private func applyBrightness() {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.screen else { return }
        if nightVision && active && route != .menu {
            if savedBrightness == nil { savedBrightness = screen.brightness }
            screen.brightness = 1
        } else if let b = savedBrightness {
            screen.brightness = b
            savedBrightness = nil
        }
    }

    func scenePhaseChanged(active: Bool) {
        self.active = active
        applyBrightness()
    }

    var eyeTrackingSupported: Bool { FaceTracker.isSupported }

    /// The rhythm mode plays by eye where face tracking works, and for the Simulator bot, which aims by itself.
    var rhythmByEye: Bool { eyeTrackingSupported || autoplay == "rhythm" }

    /// The only way the app's screen is held (Info.plist: UIInterfaceOrientationLandscapeRight, front camera on the
    /// left). Gaze calibration does not survive turning the phone half a turn, because the camera moves to the other
    /// side of the screen, so the app does not offer the other landscape side.
    static let screenOrientation = ScreenOrientation.landscapeRight

    func startTracking() {
        if FaceTracker.isSupported { tracker.start(orientation: Self.screenOrientation, night: nightVision) }
    }

    private func handle(_ s: TrackingSample) {
        lastSampleTime = s.timestamp
        var blink = BlinkUpdate(freezeGaze: false, eyesClosed: false, blinkEnded: nil, reload: false)
        if s.features != nil, let b = s.blink {
            blink = blinkDetector.update(time: s.timestamp, left: b.left, right: b.right)
            if let dur = blink.blinkEnded {
                status.blinksTotal += 1
                if route == .game { logger.event(kind: "blink", time: s.timestamp, blinkSec: dur) }
            }
            if blink.reload { pendingReloadTime = s.timestamp }
        } else {
            blinkDetector.faceLost()
        }

        if route == .winkTest || route == .rhythm {
            if s.features != nil, let b = s.blink {
                if let e = winkDetector.update(time: s.timestamp, left: b.left, right: b.right) {
                    logger.wink(e)
                    if route == .winkTest {
                        winks.append(e)
                        status.lastWink = e
                    } else {
                        // The gaze is still held from before the lid moved (the blink detector froze it), so this
                        // is where the player aimed.
                        rhythmClosure(e)
                    }
                }
            } else {
                winkDetector.faceLost()
            }
        }

        if s.features != nil, blink.freezeGaze {
            // Eyelid closing: the pupils drift down and the prediction dips, so keep the last gaze point
            // (screen pt) and do not feed the filter. Eyes shut longer than a blink count as tracking lost.
            let maxBlink = (balance.energy ?? EnergyConfig()).blink.maxClosedSec
            if model == nil {
                gaze = .notLooking
            } else if blinkDetector.closedFor(at: s.timestamp) > maxBlink {
                gaze = .lost
            } else if case .point = gaze {
                // hold
            } else {
                gaze = .lost
            }
        } else if let f = s.features {
            if let m = model {
                let v = f.vector(GazeFeatures.FeatureSet(rawValue: m.featureSet) ?? featureSet)
                if m.outOfRange(v, features: 0..<2, margin: RidgeModel.lookingAwayMargin) {
                    // The eyes point well off the screen (a glance away). Hide the aim instead of extrapolating,
                    // and start the filter afresh so the aim does not swing back in from far away.
                    filter.reset()
                    gaze = .notLooking
                } else {
                    let raw = m.predict(v), pose = HeadPose(f)
                    recentRaw.append((s.timestamp, raw, pose))
                    if let i = recentRaw.firstIndex(where: { $0.time >= s.timestamp - 0.6 }), i > 0 {
                        recentRaw.removeFirst(i)
                    }
                    if route == .game, mode == .eyes, let target = lookedAtMeteor {
                        adapter?.learn(raw: raw, target: target, pose: pose, time: s.timestamp, weight: Self.meteorLabelWeight)
                    }
                    aimCorrection = adaptAim ? (adapter?.correction(pose: pose) ?? .zero) : .zero
                    gaze = .point(filter.filter(raw + aimCorrection, t: s.timestamp))
                }
            } else {
                gaze = .notLooking
            }
            if let c = collecting {
                // Frames inside a blink are skipped above, so they never reach the calibration set.
                collectedFeatures.append(f)
                if case .point(let p) = gaze { collectedGaze.append(p) }
                distances.append(f.distance)
                logger.sample(kind: c.kind, time: s.timestamp, target: c.target, gaze: gazePoint, f: f, blink: s.blink, hold: false,
                              processingMs: s.processingMs, light: s.light)
            }
        } else {
            gaze = .lost
        }
        if route == .game, mode == .eyes, let f = s.features {
            logger.sample(kind: "frame", time: s.timestamp, target: lookedAtMeteor, gaze: gazePoint, f: f,
                          blink: s.blink, hold: blink.freezeGaze, processingMs: s.processingMs,
                          correction: adapter == nil ? nil : aimCorrection, light: s.light)
        }
        if route == .rhythm, let f = s.features {
            logger.sample(kind: "rhythm_frame", time: s.timestamp, target: nil, gaze: gazePoint, f: f,
                          blink: s.blink, hold: blink.freezeGaze, processingMs: s.processingMs,
                          correction: adapter == nil ? nil : aimCorrection, locked: rhythm?.lock.locked, light: s.light)
        }
        if route == .winkTest, let f = s.features {
            logger.sample(kind: "wink_frame", time: s.timestamp, target: nil, gaze: gazePoint, f: f,
                          blink: s.blink, hold: false, processingMs: s.processingMs, light: s.light)
        }
        // The wink test draws the eyelids live, so it gets the numbers 30 times a second.
        if s.timestamp - lastStatusPush > (route == .winkTest ? 1.0 / 30 : 0.1) {
            lastStatusPush = s.timestamp
            status.fps = s.fps
            status.processingMs = s.processingMs
            status.faceFound = s.features != nil
            status.features = s.features
            status.light = s.light
            status.gaze = gazePoint
            status.blink = s.blink
            status.blinkBase = blinkDetector.openLevel()
            status.gazeFrozen = blink.freezeGaze
            status.pendingBlinks = blinkDetector.pendingBlinks(at: s.timestamp)
            if route == .winkTest { status.winkCloseLevel = winkDetector.closeLevel() }
            if showDebug {
                status.aimCorrection = aimCorrection
                status.aimLabels = adapter?.learned ?? 0
                status.aimRejected = adapter?.rejected ?? 0
            }
        }
    }

    /// The game takes a 3-blink reload once. A reload older than half a second is dropped, so blinks made
    /// on a menu or while paused do not fire later.
    func consumeBlinkReload() -> Bool {
        guard let t = pendingReloadTime else { return false }
        pendingReloadTime = nil
        return lastSampleTime - t < 0.5
    }

    /// Blinks counted so far toward the next reload, for the HUD.
    var pendingBlinks: Int { blinkDetector.pendingBlinks(at: lastSampleTime) }

    func logGameEvent(kind: String, energy: Int, level: Int) {
        logger.event(kind: kind, time: CACurrentMediaTime(), energy: energy, level: level)
    }

    var gazePoint: Vec2? {
        #if DEBUG
        if let a = botAim { return a }
        #endif
        if case .point(let p) = gaze { return p }
        return nil
    }

    // MARK: wink test

    /// Opens the wink test with a fresh session CSV, so «Экспорт CSV» sends just the test.
    func beginWinkTest() {
        logger = SessionLogger()
        logTracking()
        winkDetector = WinkDetector()
        winks = []
        status.lastWink = nil
        route = .winkTest
    }

    /// A run starts: its first click sounds at `time`. Closures from before it are dropped.
    func startWinkRun(plan: WinkTestPlan, time: Double, audioLatency: Double) {
        winks = []
        status.lastWink = nil
        logger.winkTest(time: time, periodSec: plan.periodSec, audioLatency: audioLatency)
        if autoplay == "wink" { winkBot = WinkBot(plan: plan, start: time) }
    }

    /// Simulator smoke test (`-SpantherAutoplay wink`): a scripted player's eyelids go through `handle` 60 times a
    /// second, as if ARKit had sent them, with a face that looks straight at the screen.
    private var winkBot: WinkBot?
    private var botTimer: Timer?

    private func startWinkBot() {
        let face = GazeFeatures(lookAtHit: .zero, eyeAxisHit: .zero, yaw: 0, pitch: 0, roll: 0, distance: 0.35, pupils: nil)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let t = CACurrentMediaTime()
            let lids = self.winkBot?.lids(at: t) ?? (left: 0.1, right: 0.1)
            self.handle(TrackingSample(timestamp: t, features: face, blink: lids, processingMs: 0.5, fps: 60))
        }
        RunLoop.main.add(timer, forMode: .common)
        botTimer = timer
    }

    func logWinkCue(side: WinkSide, time: Double) { logger.cue(side: side, time: time) }

    // MARK: rhythm mode

    /// Opens the rhythm mode's track list.
    func openRhythm() {
        rhythm?.stop()
        rhythm = nil
        route = .rhythm
    }

    /// Lays a track out for play on a screen this size (pt) and shows its start star.
    func prepareRhythm(track: RhythmTrack, level: RhythmLevel, screen: Vec2) {
        rhythm?.stop()
        winkDetector = WinkDetector()
        rhythm = RhythmSession(track: track, level: level, screen: screen,
                               measuredErrorPt: mode == .eyes ? report?.meanErrorPt : 0,
                               latencySec: RhythmRecords.latencySec)
        startRhythmTimer()
    }

    /// Back to the track list, from play or from the results.
    func leaveRhythmPlay() {
        rhythm?.stop()
        rhythm = nil
        rhythmTimer?.invalidate()
        rhythmTimer = nil
        #if DEBUG
        botAim = nil
        #endif
    }

    /// The start star was winked at or touched at `host`: the aim is recentred on it and the music starts.
    private func startRhythm(at host: Double) {
        guard let s = rhythm, s.phase == .ready else { return }
        if mode == .eyes { learnLabel(target: s.startPoint, before: host, source: "start") }
        guard s.begin(host: CACurrentMediaTime()), let start = s.startHost else { return }
        logger.rhythmStart(time: start, track: s.track.id, level: s.level.rawValue, beatSec: s.track.beatSec,
                           audioLatency: s.outputLatency, latency: s.judge.latencySec, notes: s.notes.count)
    }

    /// An eye closure from the wink detector, while the rhythm mode is open.
    private func rhythmClosure(_ e: WinkEvent) {
        guard let s = rhythm else { return }
        switch s.phase {
        case .ready:
            // A wink starts the track. An ordinary blink does not: everyone blinks while reading the screen.
            if e.side != .both { startRhythm(at: e.onset) }
        case .playing:
            // The gaze is still held from before the lid moved, so the lock is where the player aimed.
            let aim = gazePoint
            s.updateLock(aim: aim, host: CACurrentMediaTime())
            let rejectedBefore = s.judge.lastRejected
            if let hit = s.closure(side: e.side, host: e.onset, aim: aim) {
                record(hit, in: s, host: e.onset, side: e.side.rawValue, aim: aim, locked: s.lock.locked)
            } else if let r = s.judge.lastRejected, r != rejectedBefore {
                logger.rhythmReject(time: e.onset, index: r.index, reason: r.reason.rawValue, side: e.side.rawValue,
                                    distance: r.distanceSec)
            }
        case .done:
            break
        }
    }

    /// A finger on the rhythm screen: it starts the track on the start star, and plays the notes in touch mode.
    func rhythmTouch(at p: Vec2) {
        guard let s = rhythm else { return }
        let now = CACurrentMediaTime()
        switch s.phase {
        case .ready:
            if mode == .touch || p.distance(to: s.startPoint) < 100 { startRhythm(at: now) }
        case .playing:
            guard mode == .touch, let hit = s.tap(at: p, host: now) else { return }
            record(hit, in: s, host: now, side: p.x < s.screen.x / 2 ? "left" : "right", aim: p, locked: nil)
        case .done:
            break
        }
    }

    private func record(_ hit: RhythmJudge.Hit, in s: RhythmSession, host: Double, side: String, aim: Vec2?, locked: Int?) {
        let target = s.points[hit.index]
        logger.rhythmNote(hit: true, time: host, index: hit.index, target: target, judgement: hit.judgement.rawValue,
                          offset: hit.offsetSec, aimDistance: aim.map { $0.distance(to: target) }, side: side, locked: locked)
        // The closure landed in this note's window, so the note is where the player meant to look.
        if mode == .eyes { learnLabel(target: target, before: host, source: "rhythm") }
    }

    private func startRhythmTimer() {
        rhythmTimer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.rhythmTick() }
        RunLoop.main.add(t, forMode: .common)
        rhythmTimer = t
    }

    private func rhythmTick() {
        guard let s = rhythm, route == .rhythm else {
            rhythmTimer?.invalidate()
            rhythmTimer = nil
            return
        }
        let now = CACurrentMediaTime()
        #if DEBUG
        rhythmBotStep(s, now)
        #endif
        // The aim is not drawn: the note (or the start star) it is locked on lights up instead.
        s.updateLock(aim: mode == .eyes ? gazePoint : nil, host: now)
        guard s.phase == .playing else { return }
        for d in s.takeStartedDistractions(host: now) {
            let at: Vec2?
            switch d.kind {
            case .firefly, .seed: at = d.position(at: d.start)
            case .bloom, .swing: at = s.garden.lianaPoints(d.index, time: now).last
            case .surge: at = s.garden.path(tree: d.index, to: d.tip, time: now).last
            }
            logger.distraction(time: now, kind: d.kind.rawValue, at: at)
        }
        for i in s.tick(host: now) {
            logger.rhythmNote(hit: false, time: now, index: i, target: s.points[i], judgement: Judgement.miss.rawValue,
                              offset: nil, aimDistance: nil, side: nil)
        }
        if s.phase == .done {
            rhythmTimer?.invalidate()
            rhythmTimer = nil
            if s.judge.count(.perfect) + s.judge.count(.good) + s.judge.count(.ok) >= 5 {
                RhythmRecords.latencySec = s.judge.latencySec
            }
            s.isNewBest = RhythmRecords.save(s.track, s.level, score: s.judge.score, stars: s.judge.stars)
            logger.rhythmEnd(time: now, score: s.judge.score, accuracy: s.judge.accuracy, latency: s.judge.latencySec)
        }
    }

    /// Teaches the aim adapter that the player looked at `target` (screen pt) just before `host`, an eye closure
    /// or a tap: the raw predictions of the 0.3 s before it with open eyes (median per axis) and the pose then.
    @discardableResult
    private func learnLabel(target: Vec2, before host: Double, source: String) -> Bool {
        let frames = recentRaw.filter { $0.time <= host && $0.time >= host - 0.3 }
        guard adapter != nil, frames.count >= 3 else { return false }
        let raw = Vec2(Self.median(frames.map { $0.raw.x }), Self.median(frames.map { $0.raw.y }))
        let pose = HeadPose(pitch: Self.median(frames.map { $0.pose.pitch }), yaw: Self.median(frames.map { $0.pose.yaw }))
        let ok = adapter?.learn(raw: raw, target: target, pose: pose, time: host) ?? false
        logger.label(time: host, source: source, target: target, raw: raw, pitch: pose.pitch, yaw: pose.yaw,
                     accepted: ok, correction: adapter?.correction(pose: pose) ?? .zero)
        return ok
    }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// The wink test's mean delay from the click to the eye closing seeds the rhythm judge's delay.
    func rememberWinkDelay(_ stats: WinkStats) {
        let hits = stats.left.hits + stats.right.hits
        guard hits >= 10 else { return }
        let mean = (stats.left.meanOffsetMs * Double(stats.left.hits) + stats.right.meanOffsetMs * Double(stats.right.hits)) / Double(hits)
        RhythmRecords.latencySec = mean / 1000
    }

    #if DEBUG
    /// Simulator smoke test (`-SpantherAutoplay rhythm`): looks a little off each note's centre and winks the asked
    /// eye about 0.1 s after the beat, misses every eleventh note and, on hard, winks the wrong eye now and then.
    private(set) var botAim: Vec2?
    private var botPlayed = Set<Int>()
    private var botReadySince: Double?

    private func rhythmBotStep(_ s: RhythmSession, _ now: Double) {
        guard autoplay == "rhythm" else { return }
        switch s.phase {
        case .ready:
            botAim = s.startPoint + Vec2(10, -6)
            botPlayed = []
            if botReadySince == nil { botReadySince = now }
            if now - (botReadySince ?? now) > 6 {
                botReadySince = nil
                rhythmClosure(WinkEvent(side: .left, onset: now - 0.02, decided: now, otherPeak: 0.2))
            }
        case .playing:
            let t = s.trackTime(host: now)
            if let i = s.nextOpen(after: t) {
                botAim = s.points[i] + Vec2(Double(i % 5) * 6 - 12, Double(i % 3) * 8 - 8)
            }
            for (i, n) in s.notes.enumerated() where !botPlayed.contains(i) {
                let late = 0.1 + Double((i * 37) % 13 - 6) * 0.01
                guard t >= n.time + late else { break }
                botPlayed.insert(i)
                if i % 11 == 7 { continue }
                var side: WinkSide = n.side == .right ? .right : n.side == .left ? .left : (i % 2 == 0 ? .left : .right)
                if s.level == .hard, i % 17 == 9 { side = side == .left ? .right : .left }
                rhythmClosure(WinkEvent(side: side, onset: now, decided: now + 0.03, otherPeak: 0.2))
            }
        case .done:
            botAim = nil
        }
    }
    #endif

    // MARK: calibration

    /// Starts a calibration; «Играть» on its result then leads to `next`.
    func beginCalibration(then next: Route = .game) {
        afterCalibration = next
        model = nil
        adapter = nil
        aimCorrection = .zero
        filter.reset()
        calibrationSet = []
        checkSet = []
        checkPoses = []
        distances = []
        report = nil
        logger = SessionLogger()
        logTracking()
        route = .calibration
    }

    func beginCollecting(target: Vec2, kind: String) {
        collecting = (target, kind)
        collectedFeatures = []
        collectedGaze = []
    }

    /// Drops the dot being collected (calibration cancelled).
    func cancelCollecting() {
        collecting = nil
        collectedFeatures = []
        collectedGaze = []
    }

    /// Camera access was refused in Settings, so face tracking cannot start.
    var cameraDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .video)
        return s == .denied || s == .restricted
    }

    /// Ends collection for one dot. Returns false when too few frames had a face (the dot is repeated).
    @discardableResult
    func endCollecting(minSamples: Int = 20) -> Bool {
        guard let c = collecting else { return false }
        collecting = nil
        guard collectedFeatures.count >= minSamples else { return false }
        if c.kind == "calibration" {
            calibrationSet.append((c.target, collectedFeatures))
        } else {
            checkSet.append((c.target, collectedGaze))
            checkPoses.append(HeadPose.mean(collectedFeatures) ?? HeadPose(pitch: 0, yaw: 0))
        }
        return true
    }

    /// Fits the ridge model on the 9 calibration dots, then moves to the check screen.
    func finishCalibration() {
        var X: [[Double]] = [], Y: [Vec2] = []
        for (t, fs) in calibrationSet { for f in fs { X.append(f.vector(featureSet)); Y.append(t) } }
        model = RidgeModel.fit(features: X, targets: Y, lambda: 0.01, featureSet: featureSet.rawValue)
        filter.reset()
        // The adapter's tilt terms are measured from the grip the model was fitted at.
        let calibrated = calibrationSet.flatMap { $0.features }
        let distanceM = calibrated.isEmpty ? 0.28 : calibrated.map(\.distance).reduce(0, +) / Double(calibrated.count)
        adapter = model == nil ? nil : HeadPose.mean(calibrated).map { GazeAdapter(reference: $0, distanceM: distanceM) }
        route = model == nil ? .menu : .check
    }

    func finishCheck() {
        let distCm = distances.isEmpty ? 30 : distances.reduce(0, +) / Double(distances.count) * 100
        report = Metrics.report(samples: checkSet, ptPerCm: ptPerCm, viewingDistanceCm: distCm)
        // The report above is the model's own accuracy. Then the check dots warm the adapter up: they say where the
        // player looked at the calibration grip, which takes out a steady offset before the game starts.
        let now = CACurrentMediaTime()
        for (i, c) in checkSet.enumerated() where i < checkPoses.count && !c.predictions.isEmpty {
            let mean = c.predictions.reduce(Vec2.zero, +) * (1 / Double(c.predictions.count))
            let ok = adapter?.learn(raw: mean, target: c.target, pose: checkPoses[i], time: now) ?? false
            logger.label(time: now, source: "check", target: c.target, raw: mean, pitch: checkPoses[i].pitch,
                         yaw: checkPoses[i].yaw, accepted: ok, correction: adapter?.correction(pose: checkPoses[i]) ?? .zero)
        }
        route = .result
    }

    /// Hit-zone margin E for the game.
    var hitMarginPt: Double {
        switch mode {
        case .touch: return balance.hitMarginPt.min
        case .eyes: return balance.hitMargin(measuredErrorPt: report?.meanErrorPt ?? balance.hitMarginPt.max)
        }
    }

    /// Debug builds only: launch argument `-SpantherAutoplay eyes|touch` starts a game played by a bot that
    /// looks at (or touches) the lowest meteor and reloads after running dry. Used by the Simulator smoke test
    /// in CI, where there is no face tracking.
    #if DEBUG
    let autoplay: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-SpantherAutoplay"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()
    #else
    let autoplay: String? = nil
    #endif

    var logURL: URL { logger.url }
    func log(_ r: AsteroidRecord) { logger.asteroid(r, time: CACurrentMediaTime()) }
}
