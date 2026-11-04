import ARKit
import QuartzCore

/// One ARKit frame turned into GazeCore types, plus timing for the debug overlay.
struct TrackingSample {
    var timestamp: Double
    /// nil when no face is tracked this frame.
    var features: GazeFeatures?
    /// ARKit eyeBlinkLeft / eyeBlinkRight blend shapes, 0 open ... 1 closed. nil when no face.
    var blink: (left: Double, right: Double)?
    var processingMs: Double
    var fps: Double
}

/// The camera format ARKit runs and the device state that can lower its frame rate, for the debug overlay and
/// the session CSV (`tracking` rows). The first iPhone 13 session ran at 30 fps although `start()` asks for 60,
/// and nothing in its CSV said why.
struct TrackingInfo: Equatable {
    /// The format the session runs, width x height @ fps, for example "1280x720@60".
    var format = "-"
    /// Every face tracking format the device offers, in ARKit's order (best quality first).
    var offered = "-"
    /// ProcessInfo thermal state: nominal, fair, serious or critical.
    var thermal = "-"
    var lowPower = false
}

/// ARKit face tracking adapter (the `Tracking` module in CLAUDE.md). All ARKit work runs on `queue`;
/// samples are delivered to the main thread through `onSample`.
final class FaceTracker: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    var onSample: ((TrackingSample) -> Void)?
    /// Called on the main thread when tracking starts and whenever the thermal state or Low Power Mode changes.
    var onInfo: ((TrackingInfo) -> Void)?
    /// Main thread only.
    private(set) var info = TrackingInfo()
    var pupilDetector: PupilDetector? = VisionPupilDetector()

    private let session = ARSession()
    private let queue = DispatchQueue(label: "spanther.tracking", qos: .userInteractive)
    private let visionQueue = DispatchQueue(label: "spanther.pupils", qos: .userInitiated)
    private let lock = NSLock()
    private var latestPupils: (value: PupilOffsets, time: Double)?
    private var visionBusy = false
    private var frameCount = 0
    private var fpsWindowStart = 0.0
    private var fpsFrames = 0
    private var fps = 0.0

    /// Main thread.
    func start() {
        guard Self.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = false
        // CLAUDE.md asks for 60 fps. ARKit lists formats best first, and `max` keeps the first of the fastest,
        // so this is the best format at the highest frame rate the device offers.
        let formats = ARFaceTrackingConfiguration.supportedVideoFormats
        if let fastest = formats.max(by: { $0.framesPerSecond < $1.framesPerSecond }) {
            config.videoFormat = fastest
        }
        info.offered = formats.isEmpty ? "-" : formats.map { Self.describe($0) }.joined(separator: " ")
        info.format = Self.describe(config.videoFormat)
        let center = NotificationCenter.default
        center.removeObserver(self)
        center.addObserver(self, selector: #selector(deviceStateChanged),
                           name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceStateChanged),
                           name: .NSProcessInfoPowerStateDidChange, object: nil)
        updateDeviceState()
        session.delegateQueue = queue
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }

    static func describe(_ f: ARConfiguration.VideoFormat) -> String {
        "\(Int(f.imageResolution.width))x\(Int(f.imageResolution.height))@\(f.framesPerSecond)"
    }

    static func describe(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    /// The notifications arrive on any thread.
    @objc private func deviceStateChanged() {
        DispatchQueue.main.async { [weak self] in self?.updateDeviceState() }
    }

    /// Main thread.
    private func updateDeviceState() {
        let p = ProcessInfo.processInfo
        info.thermal = Self.describe(p.thermalState)
        info.lowPower = p.isLowPowerModeEnabled
        onInfo?(info)
    }

    // MARK: ARSessionDelegate (runs on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = CACurrentMediaTime()
        fpsFrames += 1
        if t0 - fpsWindowStart >= 1 { fps = Double(fpsFrames) / (t0 - fpsWindowStart); fpsFrames = 0; fpsWindowStart = t0 }

        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            deliver(TrackingSample(timestamp: frame.timestamp, features: nil, blink: nil, processingMs: 0, fps: fps))
            return
        }

        // Pupils: every second frame, never more than one Vision request in flight.
        frameCount += 1
        if let detector = pupilDetector, frameCount % 2 == 0 {
            lock.lock(); let busy = visionBusy; if !busy { visionBusy = true }; lock.unlock()
            if !busy {
                let buffer = frame.capturedImage
                let ts = frame.timestamp
                visionQueue.async { [weak self] in
                    // Front camera, phone held in portrait: the sensor image is rotated and mirrored relative
                    // to the upright face. Check this against the debug overlay on a real device.
                    let p = detector.detect(buffer, orientation: .leftMirrored)
                    guard let self else { return }
                    self.lock.lock()
                    if let p { self.latestPupils = (p, ts) }
                    self.visionBusy = false
                    self.lock.unlock()
                }
            }
        }
        // A pupil result stays usable for 0.3 s. With 0.1 s, the first iPhone session had pupils on only 54% of
        // calibration frames, because Vision runs on every second frame and a request can take longer than that.
        lock.lock()
        let pupils = latestPupils.flatMap { frame.timestamp - $0.time < 0.3 ? $0.value : nil }
        lock.unlock()

        let ff = FaceFrame(
            timestamp: frame.timestamp,
            faceTransform: Mat4(face.transform),
            leftEyeTransform: Mat4(face.leftEyeTransform),
            rightEyeTransform: Mat4(face.rightEyeTransform),
            lookAtPoint: Vec3(face.lookAtPoint),
            cameraTransform: Mat4(frame.camera.transform),
            pupils: pupils)
        let features = GazeFeatures.make(ff)
        let blink = (left: face.blendShapes[.eyeBlinkLeft]?.doubleValue ?? 0,
                     right: face.blendShapes[.eyeBlinkRight]?.doubleValue ?? 0)
        deliver(TrackingSample(timestamp: frame.timestamp, features: features, blink: blink,
                               processingMs: (CACurrentMediaTime() - t0) * 1000, fps: fps))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        deliver(TrackingSample(timestamp: CACurrentMediaTime(), features: nil, blink: nil, processingMs: 0, fps: 0))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        deliver(TrackingSample(timestamp: CACurrentMediaTime(), features: nil, blink: nil, processingMs: 0, fps: 0))
    }

    private func deliver(_ s: TrackingSample) {
        DispatchQueue.main.async { [weak self] in self?.onSample?(s) }
    }
}
