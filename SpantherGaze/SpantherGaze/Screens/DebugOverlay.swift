import SwiftUI

/// Stage-0 debug readout: tracking FPS, frame processing time, head pose, distance, ray hits, pupils, gaze.
struct DebugOverlay: View {
    @EnvironmentObject var status: TrackingStatus

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let g = status.gaze {
                Circle().stroke(Palette.gaze, lineWidth: 2).frame(width: 22, height: 22).position(x: g.x, y: g.y)
            }
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.gaze)
                .padding(8)
                .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, 10).padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .ignoresSafeArea()
    }

    private var lines: [String] {
        var l = [String(format: "track %.0f fps  %.2f ms/frame  face %@", status.fps, status.processingMs, status.faceFound ? "yes" : "no")]
        if let f = status.features {
            l.append(String(format: "dist %.1f cm  yaw %.0f°  pitch %.0f°  roll %.0f°", f.distance * 100, f.yaw * 57.3, f.pitch * 57.3, f.roll * 57.3))
            l.append(String(format: "lookAt hit  %+.1f, %+.1f mm", f.lookAtHit.x * 1000, f.lookAtHit.y * 1000))
            l.append(String(format: "eye-axis hit %+.1f, %+.1f mm", f.eyeAxisHit.x * 1000, f.eyeAxisHit.y * 1000))
            if let p = f.pupils {
                l.append(String(format: "pupil L %+.3f %+.3f  R %+.3f %+.3f", p.leftU, p.leftV, p.rightU, p.rightV))
            } else {
                l.append("pupil –")
            }
        }
        if let g = status.gaze { l.append(String(format: "gaze %.0f, %.0f pt", g.x, g.y)) }
        return l
    }
}
