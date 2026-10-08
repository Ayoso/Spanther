import ARKit
import QuartzCore

/// One ARKit frame turned into GazeCore types, plus timing for the debug overlay.
struct TrackingSample {
    var timestamp: Double
    /// nil when no face is tracked this frame.
    var features: GazeFeatures?
    var processingMs: Double
    var fps: Double
}

/// ARKit face tracking adapter (the `Tracking` module in CLAUDE.md). All ARKit work runs on `queue`;
/// samples are delivered to the main thread through `onSample`.
final class FaceTracker: NSObject, ARSessionDelegate {
    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    var onSample: ((TrackingSample) -> Void)?
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

    func start() {
        guard Self.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = false
        if let f60 = ARFaceTrackingConfiguration.supportedVideoFormats.first(where: { $0.framesPerSecond == 60 }) {
            config.videoFormat = f60
        }
        session.delegateQueue = queue
        session.delegate = self
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }

    // MARK: ARSessionDelegate (runs on `queue`)

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let t0 = CACurrentMediaTime()
        fpsFrames += 1
        if t0 - fpsWindowStart >= 1 { fps = Double(fpsFrames) / (t0 - fpsWindowStart); fpsFrames = 0; fpsWindowStart = t0 }

        guard let face = frame.anchors.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked else {
            deliver(TrackingSample(timestamp: frame.timestamp, features: nil, processingMs: 0, fps: fps))
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
        lock.lock()
        let pupils = latestPupils.flatMap { frame.timestamp - $0.time < 0.1 ? $0.value : nil }
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
        deliver(TrackingSample(timestamp: frame.timestamp, features: features,
                               processingMs: (CACurrentMediaTime() - t0) * 1000, fps: fps))
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        deliver(TrackingSample(timestamp: CACurrentMediaTime(), features: nil, processingMs: 0, fps: 0))
    }

    func sessionWasInterrupted(_ session: ARSession) {
        deliver(TrackingSample(timestamp: CACurrentMediaTime(), features: nil, processingMs: 0, fps: 0))
    }

    private func deliver(_ s: TrackingSample) {
        DispatchQueue.main.async { [weak self] in self?.onSample?(s) }
    }
}
