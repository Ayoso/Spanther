import QuartzCore
import SwiftUI

/// The 60-second warm-up: one dot glides along a horizontal line, then a vertical one, then a figure of eight, and
/// the player follows it with the eyes (or a finger). Plain paper and no garden: nothing else on the screen moves.
/// The canvas spans the whole screen, so its points are screen pt, the space the gaze is in.
struct PursuitView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Atlas.paper
                    .onAppear { app.beginPursuit(screen: Vec2(geo.size.width, geo.size.height)) }
            }
            .ignoresSafeArea()
            if let p = app.pursuit { PursuitPlayView(session: p) }
        }
        .environment(\.colorScheme, .light)
    }
}

private struct PursuitPlayView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var status: TrackingStatus
    @ObservedObject var session: PursuitSession
    /// Where the close button is (screen pt, the same space as the canvas, which spans the whole screen). The
    /// button sits inside the safe area and the canvas does not, so the progress line is laid out from this frame.
    @State private var closeFrame = CGRect.zero

    /// The close button: a 44 pt square at the top right corner of the safe area, this far in from its right edge.
    private static let closeSize: CGFloat = 44, closeTrailing: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TimelineView(.animation) { _ in
                // The time is read once per frame and captured by the canvas (see RhythmPlayView).
                let now = CACurrentMediaTime()
                Canvas { g, size in draw(&g, size, now) }
            }
            .ignoresSafeArea()
            .contentShape(Rectangle())
            // By finger: where the finger is, in the canvas's space (screen pt).
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in app.pursuitTouch = Vec2(v.location.x, v.location.y) }
                .onEnded { _ in app.pursuitTouch = nil })
            if session.phase == .countdown { intro }
            Button { app.route = .menu } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Atlas.inkSoft)
                    .frame(width: Self.closeSize, height: Self.closeSize)
            }
            .accessibilityLabel("Закончить")
            .background(GeometryReader { b in
                Color.clear
                    .onAppear { closeFrame = b.frame(in: .global) }
                    .onChange(of: b.frame(in: .global)) { closeFrame = $0 }
            })
            .padding(.trailing, Self.closeTrailing)
        }
    }

    /// What to do, while the dot rests in the centre before it moves.
    private var intro: some View {
        let noFace = session.byEye && !status.faceFound
        return VStack(spacing: 8) {
            Text("Разминка · 1 минута")
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
            Text(session.byEye ? "Следи за точкой одними глазами" : "Веди палец за точкой")
                .font(Atlas.title)
                .foregroundStyle(Atlas.ink)
            Spacer()
            Text(noFace
                 ? "Камера не видит лицо. Держи телефон напротив глаз."
                 : "Точка поплывёт влево и вправо, потом вверх и вниз, потом по восьмёрке.")
                .font(Atlas.caption)
                .foregroundStyle(noFace ? Atlas.vermilion : Atlas.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// Draws one frame at `host` (host time). Everything is in screen pt.
    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ host: Double) {
        let s = session
        let k = CGFloat(s.targetScale)
        let target = s.target(host: host)
        let p = cg(target)
        let t = s.time(host: host)
        // Where the player is: the gaze by eye, the finger otherwise.
        let at = s.byEye ? app.gazePoint : app.pursuitTouch
        let ringR = 22 * k

        if s.phase == .running, let at {
            // A warm light under the dot while the player is near it. It opens and closes with the distance, over
            // the last third of the radius, so nothing blinks when the gaze wavers at the edge.
            let d = at.distance(to: target)
            let near = min(1, max(0, (s.radiusPt - d) / (s.radiusPt * 0.3)))
            if near > 0 {
                let r = 32 * k
                g.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(Atlas.vermilion.opacity(0.17 * near)))
            }
        }
        g.stroke(Atlas.dial(p, ringR, 1), with: .color(Atlas.ink.opacity(0.14)), lineWidth: 1.5)
        if s.phase == .countdown {
            // The ring closes while the dot waits; it starts to move when the ring is whole.
            let waited = min(1, max(0, 1 + t / PursuitSession.countdownSec))
            g.stroke(Atlas.dial(p, ringR, waited), with: .color(Atlas.ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        let dotR = 10 * k
        g.fill(Path(ellipseIn: CGRect(x: p.x - dotR, y: p.y - dotR, width: 2 * dotR, height: 2 * dotR)),
               with: .color(Atlas.vermilion))
        g.fill(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)), with: .color(Atlas.paper))

        if s.phase == .running { drawProgress(&g, size, min(1, max(0, t / s.plan.durationSec))) }

        if app.showDebug {
            // Debugging only: the distance that counts as "on the dot", and the gaze itself.
            g.stroke(Atlas.dial(p, CGFloat(s.radiusPt), 1), with: .color(Atlas.ink.opacity(0.25)),
                     style: StrokeStyle(lineWidth: 1, dash: [3, 6]))
            if let at {
                let a = cg(at)
                g.stroke(Path(ellipseIn: CGRect(x: a.x - 13, y: a.y - 13, width: 26, height: 26)),
                         with: .color(Atlas.ink.opacity(0.8)), lineWidth: 1.5)
            }
        }
    }

    /// The minute as a hairline across the top, level with the close button's cross (as in the rhythm mode).
    private func drawProgress(_ g: inout GraphicsContext, _ size: CGSize, _ k: Double) {
        let cross = closeFrame.isEmpty
            ? CGRect(x: size.width - Self.closeTrailing - Self.closeSize, y: 0, width: Self.closeSize, height: Self.closeSize)
            : closeFrame
        let x0 = size.width - cross.maxX + 15
        let x1 = cross.minX - 4
        let y = cross.midY
        var all = Path(), done = Path()
        all.move(to: CGPoint(x: x0, y: y)); all.addLine(to: CGPoint(x: x1, y: y))
        done.move(to: CGPoint(x: x0, y: y)); done.addLine(to: CGPoint(x: x0 + (x1 - x0) * CGFloat(k), y: y))
        g.stroke(all, with: .color(Atlas.ink.opacity(0.12)), lineWidth: 2)
        g.stroke(done, with: .color(Atlas.ink.opacity(0.6)), lineWidth: 2)
    }

    private func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
}
