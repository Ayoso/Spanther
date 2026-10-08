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
        if !FaceTracker.isSupported { mode = .touch }
        tracker.onSample = { [weak self] s in self?.handle(s) }
    }

    var eyeTrackingSupported: Bool { FaceTracker.isSupported }

    func startTracking() { if FaceTracker.isSupported { tracker.start() } }

    private func handle(_ s: TrackingSample) {
        if let f = s.features {
            if let m = model {
                let raw = m.predict(f.vector(GazeFeatures.FeatureSet(rawValue: m.featureSet) ?? featureSet))
                let p = filter.filter(raw, t: s.timestamp)
                gaze = .point(p)
            } else {
                gaze = .notLooking
            }
            if let c = collecting {
                collectedFeatures.append(f)
                if case .point(let p) = gaze { collectedGaze.append(p) }
                distances.append(f.distance)
                logger.sample(kind: c.kind, time: s.timestamp, target: c.target, gaze: gazePoint, f: f)
            }
        } else {
            gaze = .lost
        }
        if s.timestamp - lastStatusPush > 0.1 {
            lastStatusPush = s.timestamp
            status.fps = s.fps
            status.processingMs = s.processingMs
            status.faceFound = s.features != nil
            status.features = s.features
            status.gaze = gazePoint
        }
    }

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

    var logURL: URL { logger.url }
    func log(_ r: AsteroidRecord) { logger.asteroid(r, time: CACurrentMediaTime()) }
}
