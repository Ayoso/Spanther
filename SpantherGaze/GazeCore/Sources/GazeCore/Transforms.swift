import Foundation

// All coordinate conversions live here (CLAUDE.md rule 2). Spaces used:
//  face   – ARFaceAnchor local space, metres. +z points out of the face towards the camera.
//  world  – ARKit world space, metres.
//  camera – ARCamera local space, metres, in SENSOR orientation (landscape): +x along the sensor's long side,
//           +y up in landscape, -z looking out of the camera. The screen is (approximately) the camera's z = 0 plane.
//  screen – SwiftUI/UIKit points, portrait, origin top-left, y down.

/// One tracked frame, already converted from ARKit/simd types by the Tracking adapter.
public struct FaceFrame: Sendable {
    public var timestamp: Double
    /// world <- face
    public var faceTransform: Mat4
    /// face <- left eye / face <- right eye. Each eye's +z axis is its gaze direction.
    public var leftEyeTransform: Mat4
    public var rightEyeTransform: Mat4
    /// face space
    public var lookAtPoint: Vec3
    /// world <- camera
    public var cameraTransform: Mat4
    /// Pupil centres from an image detector (Vision or MediaPipe), already expressed as offsets
    /// inside each eye opening. nil when the detector had no fresh result.
    public var pupils: PupilOffsets?

    public init(timestamp: Double, faceTransform: Mat4, leftEyeTransform: Mat4, rightEyeTransform: Mat4,
                lookAtPoint: Vec3, cameraTransform: Mat4, pupils: PupilOffsets? = nil) {
        self.timestamp = timestamp; self.faceTransform = faceTransform
        self.leftEyeTransform = leftEyeTransform; self.rightEyeTransform = rightEyeTransform
        self.lookAtPoint = lookAtPoint; self.cameraTransform = cameraTransform; self.pupils = pupils
    }
}

/// Pupil position inside the eye opening: u along the eye (corner to corner), v across it,
/// both divided by eye width. Image space, so the detector's orientation must be right.
public struct PupilOffsets: Sendable, Equatable {
    public var leftU: Double, leftV: Double, rightU: Double, rightV: Double
    public init(leftU: Double, leftV: Double, rightU: Double, rightV: Double) {
        self.leftU = leftU; self.leftV = leftV; self.rightU = rightU; self.rightV = rightV
    }
}

public enum Transforms {
    /// face -> camera
    public static func faceToCamera(_ f: FaceFrame) -> Mat4 { f.cameraTransform.rigidInverse * f.faceTransform }

    /// Eye centre in camera space, from face <- eye.
    public static func eyeOrigin(_ eye: Mat4, faceToCamera: Mat4) -> Vec3 { faceToCamera.point(eye.translation) }

    /// Intersection of a ray with the camera's z = 0 plane (≈ the screen). Camera space in, camera-plane metres out.
    /// Returns nil when the ray runs parallel to the screen or points away from it.
    public static func intersectScreenPlane(origin: Vec3, direction: Vec3) -> Vec2? {
        guard abs(direction.z) > 1e-9 else { return nil }
        let t = -origin.z / direction.z
        guard t > 0 else { return nil }
        let p = origin + direction * t
        return Vec2(p.x, p.y)
    }

    /// Camera-plane metres (sensor orientation) -> portrait screen axes in metres.
    /// The front camera's sensor is landscape; in portrait, sensor +y maps to screen +x and sensor +x to screen +y.
    /// Exact sign/axes still have to be checked on a device (debug overlay); calibration absorbs any residual
    /// rotation or offset, because the ridge model sees both axes for each output.
    public static func cameraPlaneToPortrait(_ p: Vec2) -> Vec2 { Vec2(-p.y, -p.x) }

    /// Head yaw, pitch, roll (radians) and distance (metres) of the face as seen from the camera.
    public static func headPose(_ f: FaceFrame) -> (yaw: Double, pitch: Double, roll: Double, distance: Double) {
        let m = faceToCamera(f)
        let z = m.zAxis.normalized, x = m.xAxis.normalized
        let yaw = atan2(z.x, z.z)
        let pitch = asin(max(-1, min(1, -z.y)))
        let roll = atan2(x.y, x.x)
        return (yaw, pitch, roll, m.translation.length)
    }
}

/// Gaze features handed to the calibration model. Two ray sources are kept side by side so the
/// baseline (lookAtPoint) and the eye-transform ray can be compared on the same recordings (rule 7).
public struct GazeFeatures: Sendable {
    /// Average of both eyes' ray through `lookAtPoint`, hitting the screen plane (portrait metres).
    public var lookAtHit: Vec2
    /// Average of both eyes' own +z axis ray, hitting the screen plane (portrait metres).
    public var eyeAxisHit: Vec2
    public var yaw: Double, pitch: Double, roll: Double, distance: Double
    public var pupils: PupilOffsets?
    /// Eye centres in camera space (metres): ARKit eye transforms moved through face → world → camera.
    /// Not used by the model; shown in the debug overlay for the stage-0 check.
    public var leftEyeCamera: Vec3 = .zero
    public var rightEyeCamera: Vec3 = .zero

    public enum FeatureSet: String, CaseIterable, Sendable {
        /// Baseline from CLAUDE.md stage 1: lookAtPoint + head pose.
        case lookAt
        /// lookAtPoint + eye axes + head pose.
        case eyes
        /// Everything above plus pupil offsets from the image detector (stage 2 direction).
        case eyesAndPupils
    }

    public static func make(_ f: FaceFrame) -> GazeFeatures? {
        let f2c = Transforms.faceToCamera(f)
        let lo = Transforms.eyeOrigin(f.leftEyeTransform, faceToCamera: f2c)
        let ro = Transforms.eyeOrigin(f.rightEyeTransform, faceToCamera: f2c)
        let target = f2c.point(f.lookAtPoint)
        guard let l1 = Transforms.intersectScreenPlane(origin: lo, direction: target - lo),
              let r1 = Transforms.intersectScreenPlane(origin: ro, direction: target - ro) else { return nil }
        let ld = f2c.direction(f.leftEyeTransform.zAxis), rd = f2c.direction(f.rightEyeTransform.zAxis)
        let l2 = Transforms.intersectScreenPlane(origin: lo, direction: ld) ?? l1
        let r2 = Transforms.intersectScreenPlane(origin: ro, direction: rd) ?? r1
        let pose = Transforms.headPose(f)
        return GazeFeatures(
            lookAtHit: Transforms.cameraPlaneToPortrait((l1 + r1) * 0.5),
            eyeAxisHit: Transforms.cameraPlaneToPortrait((l2 + r2) * 0.5),
            yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll, distance: pose.distance, pupils: f.pupils,
            leftEyeCamera: lo, rightEyeCamera: ro)
    }

    /// Flat vector for the ridge model. Quadratic terms on the main ray let the model bend at the screen edges,
    /// where uncalibrated lookAtPoint error is largest.
    public func vector(_ set: FeatureSet) -> [Double] {
        let a = lookAtHit
        var v = [a.x, a.y, a.x * a.x, a.y * a.y, a.x * a.y, yaw, pitch, roll, distance]
        if set != .lookAt { v += [eyeAxisHit.x, eyeAxisHit.y] }
        if set == .eyesAndPupils {
            let p = pupils
            v += [((p?.leftU ?? 0) + (p?.rightU ?? 0)) / 2, ((p?.leftV ?? 0) + (p?.rightV ?? 0)) / 2]
        }
        return v
    }
}
