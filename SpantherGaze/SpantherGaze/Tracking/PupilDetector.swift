import CoreVideo
import ImageIO
import Vision

/// Finds pupil centres in a camera image. Swappable so Vision and MediaPipe can be compared on the same
/// recorded sessions (CLAUDE.md rule 7). Called off the main thread.
protocol PupilDetector: AnyObject {
    var name: String { get }
    /// `orientation` must describe how the sensor image relates to the upright face. ARKit's
    /// `capturedImage` comes in sensor orientation, not screen orientation (CLAUDE.md rule 3).
    func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> PupilOffsets?
}

/// Apple Vision: one pupil point per eye, no third-party SDK.
final class VisionPupilDetector: PupilDetector {
    let name = "Vision"
    private let handler = VNSequenceRequestHandler()
    private let request: VNDetectFaceLandmarksRequest = {
        let r = VNDetectFaceLandmarksRequest()
        r.revision = VNDetectFaceLandmarksRequestRevision3
        return r
    }()

    func detect(_ pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) -> PupilOffsets? {
        do { try handler.perform([request], on: pixelBuffer, orientation: orientation) } catch { return nil }
        guard let lm = request.results?.first?.landmarks,
              let le = lm.leftEye, let re = lm.rightEye,
              let lp = lm.leftPupil?.normalizedPoints.first, let rp = lm.rightPupil?.normalizedPoints.first
        else { return nil }
        let l = Self.offset(pupil: lp, eye: le.normalizedPoints)
        let r = Self.offset(pupil: rp, eye: re.normalizedPoints)
        return PupilOffsets(leftU: l.u, leftV: l.v, rightU: r.u, rightV: r.v)
    }

    /// Pupil relative to the centre of the eye contour, divided by the eye width.
    /// Points are normalised to the face bounding box, which is fine because we only use ratios.
    private static func offset(pupil: CGPoint, eye: [CGPoint]) -> (u: Double, v: Double) {
        guard let minX = eye.map(\.x).min(), let maxX = eye.map(\.x).max(), maxX > minX else { return (0, 0) }
        let cx = eye.map(\.x).reduce(0, +) / CGFloat(eye.count)
        let cy = eye.map(\.y).reduce(0, +) / CGFloat(eye.count)
        let w = maxX - minX
        return (Double((pupil.x - cx) / w), Double((pupil.y - cy) / w))
    }
}

// MediaPipe Face Landmarker (iris points 468–477) is the second candidate. It ships for iOS through
// CocoaPods (`MediaPipeTasksVision`), so it is not wired in yet. To compare it, add the pod and implement
// `PupilDetector` here using the iris centres 468 and 473 relative to eye corners 33/133 and 362/263,
// the same way the web prototype in spanther-demo/web does.
