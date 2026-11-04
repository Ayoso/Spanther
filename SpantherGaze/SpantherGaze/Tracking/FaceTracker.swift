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
    /// How the screen is held (ScreenOrientation), which the gaze transforms use.
    var screen = "-"
    /// The image orientation Vision runs with, for example "downMirrored"; "turned" when the tracker turned it 180°
    /// because Vision found no face with the expected one.
    var vision = "-"
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
    /// Guarded by `lock`. Set on the main thread in `start`, read on `queue`.
    private var orientation = ScreenOrientation.landscapeRight
    /// Guarded by `lock`. The landscape image orientations are not yet checked on a phone, so Vision's results are
    /// counted in windows of 30 requests (about 1 s): almost no face in a window turns the image 180°, a mostly
    /// successful window keeps the orientation for good.
    private var visionTurned = false
    private var visionTrusted = false
    private var visionAttempts = 0
    private var visionHits = 0
    private var frameCount = 0
    private var fpsWindowStart = 0.0
    private var fpsFrames = 0
    private var fps = 0.0

    /// Main thread. `orientation` is how the app's screen is held; it has to match Info.plist.
    func start(orientation: ScreenOrientation) {
        guard Self.isSupported else { return }
        lock.lock(); self.orientation = orientation; let vision = visionDescriptionLocked; lock.unlock()
        info.screen = orientation.rawValue
        info.vision = vision
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

    /// Names of the EXIF orientations 1...8, as CGImagePropertyOrientation spells them.
    static func describeImageOrientation(_ raw: UInt32) -> String {
        let names = ["up", "upMirrored", "down", "downMirrored", "leftMirrored", "right", "rightMirrored", "left"]
        return (1...8).contains(raw) ? names[Int(raw) - 1] : "\(raw)"
    }

    /// Caller holds `lock`.
    private var visionOrientationLocked: UInt32 {
        let raw = Transforms.frontCameraImageOrientation(orientation)
        return visionTurned ? Transforms.rotated180(exif: raw) : raw
    }

    /// Caller holds `lock`.
    private var visionDescriptionLocked: String {
        Self.describeImageOrientation(visionOrientationLocked) + (visionTurned ? " turned" : "")
    }

    /// Caller holds `lock`. Returns true when this result turned the image orientation.
    private func recordVisionLocked(found: Bool) -> Bool {
        guard !visionTrusted else { return false }
        visionAttempts += 1
        if found { visionHits += 1 }
        guard visionAttempts >= 30 else { return false }
        defer { visionAttempts = 0; visionHits = 0 }
        if visionHits >= 20 { visionTrusted = true; return false }
        guard visionHits <= 3 else { return false }
        visionTurned.toggle()
        return true
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
            lock.lock()
            let busy = visionBusy
            if !busy { visionBusy = true }
            let raw = visionOrientationLocked
            lock.unlock()
            if !busy {
                let buffer = frame.capturedImage
                let ts = frame.timestamp
                // The sensor image is rotated and mirrored relative to the upright face; Transforms says how
                // for the way the phone is held (CLAUDE.md rule 3).
                let imageOrientation = CGImagePropertyOrientation(rawValue: raw) ?? .leftMirrored
                visionQueue.async { [weak self] in
                    let p = detector.detect(buffer, orientation: imageOrientation)
                    guard let self else { return }
                    self.lock.lock()
                    if let p { self.latestPupils = (p, ts) }
                    self.visionBusy = false
                    let turned = self.recordVisionLocked(found: p != nil)
                    let vision = self.visionDescriptionLocked
                    self.lock.unlock()
                    if turned {
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            self.info.vision = vision
                            self.onInfo?(self.info)
                        }
                    }
                }
            }
        }
        // A pupil result stays usable for 0.3 s. With 0.1 s, the first iPhone session had pupils on only 54% of
        // calibration frames, because Vision runs on every second frame and a request can take longer than that.
        lock.lock()
        let pupils = latestPupils.flatMap { frame.timestamp - $0.time < 0.3 ? $0.value : nil }
        let orientation = self.orientation
        lock.unlock()

        let ff = FaceFrame(
            timestamp: frame.timestamp,
            faceTransform: Mat4(face.transform),
            leftEyeTransform: Mat4(face.leftEyeTransform),
            rightEyeTransform: Mat4(face.rightEyeTransform),
            lookAtPoint: Vec3(face.lookAtPoint),
            cameraTransform: Mat4(frame.camera.transform),
            orientation: orientation,
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
