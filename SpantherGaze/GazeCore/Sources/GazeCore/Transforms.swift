import Foundation

// All coordinate conversions live here (CLAUDE.md rule 2). Spaces used:
//  face   – ARFaceAnchor local space, metres. +z points out of the face towards the camera.
//  world  – ARKit world space, metres.
//  camera – ARCamera local space, metres, in SENSOR orientation (landscape): +x along the sensor's long side,
//           +y up in landscape, -z looking out of the camera. The screen is (approximately) the camera's z = 0 plane.
//  screen – SwiftUI/UIKit points, origin top-left, y down, in the orientation the app runs (`ScreenOrientation`).
//           Since 2026-11-05 that is landscape with the front camera on the left.

/// How the phone is held while the app runs. GazeCore does not import UIKit, so the app maps
/// UIInterfaceOrientation onto this.
public enum ScreenOrientation: String, Sendable, CaseIterable {
    /// Front camera at the top.
    case portrait
    /// Front camera on the left (UIInterfaceOrientation.landscapeRight). The app's only orientation.
    case landscapeRight
    /// Front camera on the right (UIInterfaceOrientation.landscapeLeft).
    case landscapeLeft
}

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
    /// How the phone was held, for the camera-plane -> screen axes step.
    public var orientation: ScreenOrientation
    /// Pupil centres from an image detector (Vision or MediaPipe), already expressed as offsets
    /// inside each eye opening. nil when the detector had no fresh result.
    public var pupils: PupilOffsets?

    public init(timestamp: Double, faceTransform: Mat4, leftEyeTransform: Mat4, rightEyeTransform: Mat4,
                lookAtPoint: Vec3, cameraTransform: Mat4, orientation: ScreenOrientation, pupils: PupilOffsets? = nil) {
        self.timestamp = timestamp; self.faceTransform = faceTransform
        self.leftEyeTransform = leftEyeTransform; self.rightEyeTransform = rightEyeTransform
        self.lookAtPoint = lookAtPoint; self.cameraTransform = cameraTransform; self.orientation = orientation
        self.pupils = pupils
    }
}

/// Pupil position inside the eye opening: u along the eye (corner to corner), v across it,
/// both divided by eye width. Image space, so the detector's orientation must be right. With the image stood
/// upright for the player (`Transforms.frontCameraImageOrientation`), u runs along the screen's x and v along its y
/// in every orientation, because the face is upright to the screen.
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

    /// Camera-plane metres (sensor axes) -> screen axes in metres: x right and y down as the player sees the screen,
    /// origin at the camera. Camera +x runs from the front camera toward the bottom of the phone, camera +y is to the
    /// right of it in portrait. Checked on the iPhone 13 (second session, portrait calibration, 2026-11-04): the hit's
    /// camera y followed the dots' screen x (r = 0.92) and camera x their screen y (r = 0.99). Turning the phone turns
    /// the screen axes with it. Before 2026-11-05 portrait features were logged as (-y, -x); the ridge model fits
    /// either sign, so old session CSVs replay the same.
    public static func cameraPlaneToScreen(_ p: Vec2, _ o: ScreenOrientation) -> Vec2 {
        switch o {
        case .portrait: return Vec2(p.y, p.x)
        case .landscapeRight: return Vec2(p.x, -p.y)
        case .landscapeLeft: return Vec2(-p.x, p.y)
        }
    }

    /// Rhythm mode: a note's place in the play area (0...1 from the left edge to the right one and from the top edge
    /// to the bottom one, as the player sees the screen) -> screen pt, for a screen `size` pt across and down.
    public static func playAreaToScreen(x: Double, y: Double, size: Vec2) -> Vec2 { Vec2(x * size.x, y * size.y) }

    /// EXIF orientation (the raw value of CGImagePropertyOrientation) that stands ARKit's front-camera image upright
    /// for a player facing the screen held this way (CLAUDE.md rule 3). Portrait is 5 (leftMirrored): with it Vision
    /// found pupils on 99-100% of frames on the iPhone 13. The landscape values come from Apple's Vision face tracking
    /// sample for the front camera, which uses leftMirrored for portrait as well: camera on the left 4 (downMirrored),
    /// camera on the right 2 (upMirrored). Not yet checked on a phone, so FaceTracker turns the image 180° when
    /// Vision finds no face with it.
    public static func frontCameraImageOrientation(_ o: ScreenOrientation) -> UInt32 {
        switch o {
        case .portrait: return 5
        case .landscapeRight: return 4
        case .landscapeLeft: return 2
        }
    }

    /// The EXIF orientation of the same image turned 180°.
    public static func rotated180(exif: UInt32) -> UInt32 {
        switch exif {
        case 1: return 3
        case 3: return 1
        case 2: return 4
        case 4: return 2
        case 5: return 7
        case 7: return 5
        case 6: return 8
        case 8: return 6
        default: return exif
        }
    }

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
    /// Average of both eyes' ray through `lookAtPoint`, hitting the screen plane (screen axes, metres from the camera).
    public var lookAtHit: Vec2
    /// Average of both eyes' own +z axis ray, hitting the screen plane (screen axes, metres from the camera).
    public var eyeAxisHit: Vec2
    public var yaw: Double, pitch: Double, roll: Double, distance: Double
    public var pupils: PupilOffsets?
    /// Eye centres in camera space (metres): ARKit eye transforms moved through face → world → camera.
    /// Not used by the model; shown in the debug overlay for the stage-0 check.
    public var leftEyeCamera: Vec3 = .zero
    public var rightEyeCamera: Vec3 = .zero

    public init(lookAtHit: Vec2, eyeAxisHit: Vec2, yaw: Double, pitch: Double, roll: Double, distance: Double,
                pupils: PupilOffsets?, leftEyeCamera: Vec3 = .zero, rightEyeCamera: Vec3 = .zero) {
        self.lookAtHit = lookAtHit; self.eyeAxisHit = eyeAxisHit
        self.yaw = yaw; self.pitch = pitch; self.roll = roll; self.distance = distance; self.pupils = pupils
        self.leftEyeCamera = leftEyeCamera; self.rightEyeCamera = rightEyeCamera
    }

    public enum FeatureSet: String, CaseIterable, Sendable {
        /// Baseline from CLAUDE.md stage 1: the lookAtPoint ray's hit on the screen.
        case lookAt
        /// lookAtPoint + eye axes.
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
            lookAtHit: Transforms.cameraPlaneToScreen((l1 + r1) * 0.5, f.orientation),
            eyeAxisHit: Transforms.cameraPlaneToScreen((l2 + r2) * 0.5, f.orientation),
            yaw: pose.yaw, pitch: pose.pitch, roll: pose.roll, distance: pose.distance, pupils: f.pupils,
            leftEyeCamera: lo, rightEyeCamera: ro)
    }

    /// Flat vector for the ridge model. The first two entries are always the lookAtPoint hit (screen axes, metres),
    /// which `RidgeModel.outOfRange` uses to spot a glance away from the screen. Quadratic terms on that ray let
    /// the model bend at the screen edges, where uncalibrated lookAtPoint error is largest.
    ///
    /// Head pose (yaw, pitch, roll, distance) is deliberately not a feature. The hits are computed in camera space,
    /// so they already move with the head and the phone. As separate features, the pose terms learned that the head
    /// turns a little toward each calibration dot, and when the phone moved during a game the aim moved with it
    /// (first iPhone session, 2026-11-04: the aim was over 1 cm off the screen 25% of the time in level 6).
    ///
    /// Missing pupils are NaN, not 0: the model treats NaN as "average", so a frame without a fresh pupil result
    /// does not make the aim jump.
    public func vector(_ set: FeatureSet) -> [Double] {
        let a = lookAtHit
        var v = [a.x, a.y, a.x * a.x, a.y * a.y, a.x * a.y]
        if set != .lookAt { v += [eyeAxisHit.x, eyeAxisHit.y] }
        if set == .eyesAndPupils {
            if let p = pupils {
                v += [(p.leftU + p.rightU) / 2, (p.leftV + p.rightV) / 2]
            } else {
                v += [.nan, .nan]
            }
        }
        return v
    }
}
