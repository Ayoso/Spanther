import AVFoundation
import Foundation
import QuartzCore

enum Route: Equatable {
    case menu
    case calibration
    case check
    case result
    case game
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
}

/// App state shared by all screens. Main thread only.
final class AppModel: ObservableObject {
    @Published var route: Route = .menu
    @Published var mode: ControlMode = .eyes
    @Published var report: AccuracyReport?
    @Published var showDebug = false
    @Published var usePupils = true

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
    /// Time of the last 3-blink reload not yet taken by the game.
    private var pendingReloadTime: Double?
    private var lastSampleTime = 0.0

    /// Points per centimetre. Current iPhones are about 60 pt/cm (163 pt per inch on 2x, ~153 on 3x Pro).
    let ptPerCm = 60.0
    var featureSet: GazeFeatures.FeatureSet { usePupils ? .eyesAndPupils : .eyes }

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
        blinkDetector = BlinkDetector(cfg.energy ?? EnergyConfig())
        status.reloadBlinksNeeded = (cfg.energy ?? EnergyConfig()).reloadBlinks
        if !FaceTracker.isSupported { mode = .touch }
        if let bot = autoplay {
            // CI smoke test in the Simulator: skip the menu and let the bot play.
            mode = bot == "eyes" ? .eyes : .touch
            route = .game
        }
        tracker.onSample = { [weak self] s in self?.handle(s) }
    }

    var eyeTrackingSupported: Bool { FaceTracker.isSupported }

    func startTracking() { if FaceTracker.isSupported { tracker.start() } }

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
                let raw = m.predict(f.vector(GazeFeatures.FeatureSet(rawValue: m.featureSet) ?? featureSet))
                let p = filter.filter(raw, t: s.timestamp)
                gaze = .point(p)
            } else {
                gaze = .notLooking
            }
            if let c = collecting {
                // Frames inside a blink are skipped above, so they never reach the calibration set.
                collectedFeatures.append(f)
                if case .point(let p) = gaze { collectedGaze.append(p) }
                distances.append(f.distance)
                logger.sample(kind: c.kind, time: s.timestamp, target: c.target, gaze: gazePoint, f: f, blink: s.blink, hold: false)
            }
        } else {
            gaze = .lost
        }
        if route == .game, mode == .eyes, let f = s.features {
            logger.sample(kind: "frame", time: s.timestamp, target: nil, gaze: gazePoint, f: f,
                          blink: s.blink, hold: blink.freezeGaze)
        }
        if s.timestamp - lastStatusPush > 0.1 {
            lastStatusPush = s.timestamp
            status.fps = s.fps
            status.processingMs = s.processingMs
            status.faceFound = s.features != nil
            status.features = s.features
            status.gaze = gazePoint
            status.blink = s.blink
            status.blinkBase = blinkDetector.openLevel()
            status.gazeFrozen = blink.freezeGaze
            status.pendingBlinks = blinkDetector.pendingBlinks(at: s.timestamp)
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

    func logEnergy(kind: String, energy: Int) { logger.event(kind: kind, time: CACurrentMediaTime(), energy: energy) }

    var gazePoint: Vec2? { if case .point(let p) = gaze { return p }; return nil }

    // MARK: calibration

    func beginCalibration() {
        model = nil
        filter.reset()
        calibrationSet = []
        checkSet = []
        distances = []
        report = nil
        logger = SessionLogger()
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
        }
        return true
    }

    /// Fits the ridge model on the 9 calibration dots, then moves to the check screen.
    func finishCalibration() {
        var X: [[Double]] = [], Y: [Vec2] = []
        for (t, fs) in calibrationSet { for f in fs { X.append(f.vector(featureSet)); Y.append(t) } }
        model = RidgeModel.fit(features: X, targets: Y, lambda: 0.01, featureSet: featureSet.rawValue)
        filter.reset()
        route = model == nil ? .menu : .check
    }

    func finishCheck() {
        let distCm = distances.isEmpty ? 30 : distances.reduce(0, +) / Double(distances.count) * 100
        report = Metrics.report(samples: checkSet, ptPerCm: ptPerCm, viewingDistanceCm: distCm)
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
