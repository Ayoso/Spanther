import QuartzCore
import SwiftUI

struct RhythmView: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    /// The whole screen (pt), which the notes and the gaze share.
    @State private var screen = CGSize(width: 844, height: 390)

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Atlas.paper
                    .onAppear { screen = geo.size }
                    .onChange(of: geo.size) { screen = $0 }
            }
            .ignoresSafeArea()
            if let s = app.rhythm {
                RhythmPlayView(session: s)
            } else {
                RhythmPicker(screen: screen)
            }
        }
        // Ink on paper: system controls in here take the light look, while the rest of the app stays dark.
        .environment(\.colorScheme, .light)
        .onChange(of: scenePhase) { p in if p != .active, app.rhythm?.phase == .playing { app.leaveRhythmPlay() } }
    }
}

// MARK: - Track and level

private struct RhythmPicker: View {
    @EnvironmentObject var app: AppModel
    let screen: CGSize
    @AppStorage("rhythm.track") private var trackID = ""
    @AppStorage("rhythm.level") private var levelRaw = RhythmLevel.normal.rawValue

    private var level: RhythmLevel { RhythmLevel(rawValue: levelRaw) ?? .normal }
    private var track: RhythmTrack? { app.rhythmTracks.first { $0.id == trackID } ?? app.rhythmTracks.first }
    private var needsCalibration: Bool { app.rhythmByEye && app.model == nil }

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                Button { app.route = .menu } label: { Label("Меню", systemImage: "chevron.left") }
                    .font(Atlas.body)
                    .foregroundStyle(Atlas.inkSoft)
                    .frame(minHeight: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ритм").font(Atlas.display(34)).foregroundStyle(Atlas.ink)
                    Text(app.rhythmByEye
                         ? "Смотри на звезду. Когда стрелка дойдёт до красной метки, подмигни."
                         : "Когда стрелка дойдёт до красной метки, коснись звезды.")
                        .font(Atlas.caption)
                        .foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 4) {
                    ForEach(app.rhythmTracks, id: \.id) { t in trackRow(t) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 16) {
                if let track {
                    ConstellationPreview(notes: Array(track.chart(level).prefix(14)))
                        .frame(height: 88)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    ForEach(RhythmLevel.allCases, id: \.self) { l in levelRow(l) }
                }
                HStack(spacing: 8) {
                    Button { play(byEye: app.rhythmByEye) } label: {
                        Text(needsCalibration ? "Калибровка и игра" : "Играть").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(AtlasPrimaryButton())
                    if app.rhythmByEye {
                        // Without the camera: a tap plays the note under the finger, as a wink of that side's eye.
                        Button { play(byEye: false) } label: { Image(systemName: "hand.point.up.left") }
                            .buttonStyle(AtlasSecondaryButton())
                            .frame(width: 56)
                            .accessibilityLabel("Играть пальцем")
                    }
                }
                .disabled(track == nil)
                .onAppear(perform: autoplay)
            }
            // 300 pt, narrower on a 4.7-inch phone so the track names keep their room.
            .frame(width: min(300, screen.width * 0.4))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LivingBackground(growFrom: app.launchTime).ignoresSafeArea())
    }

    private func trackRow(_ t: RhythmTrack) -> some View {
        let selected = t.id == track?.id
        let stars = RhythmRecords.bestStars(t, level)
        let length = Int((t.endSec + 2).rounded())
        return Button { trackID = t.id } label: {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    // A long name («Метеоритный дождь») shrinks a little instead of losing its end.
                    Text(t.title).font(Atlas.title).foregroundStyle(selected ? Atlas.ink : Atlas.inkSoft)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(String(format: "%.0f уд/мин · %ld:%02ld · %@", t.bpm, length / 60, length % 60, t.license))
                        .font(Atlas.caption)
                        .foregroundStyle(Atlas.inkSoft)
                        .monospacedDigit()
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        Image(systemName: i < stars ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(i < stars ? Atlas.vermilion : Atlas.missGrey)
                    }
                }
                .accessibilityLabel("Лучший результат: звёзд \(stars) из 3")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .background(selected ? Atlas.paperShade : .clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func levelRow(_ l: RhythmLevel) -> some View {
        let selected = l == level
        return Button { levelRaw = l.rawValue } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Atlas.levelName(l))
                        .font(.system(size: 17, weight: selected ? .semibold : .regular, design: .serif))
                        .foregroundStyle(Atlas.ink)
                    Text(Atlas.levelHint(l)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Atlas.vermilion)
                    .opacity(selected ? 1 : 0)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            if l != RhythmLevel.allCases.last { Rectangle().fill(Atlas.ink.opacity(0.1)).frame(height: 1) }
        }
    }

    /// Plays the chosen track by eye (calibrating first if there is no calibration yet) or by finger.
    private func play(byEye: Bool) {
        guard let track else { return }
        app.mode = byEye ? .eyes : .touch
        if byEye, app.model == nil {
            app.beginCalibration(then: .rhythm)
            return
        }
        app.prepareRhythm(track: track, level: level, screen: Vec2(screen.width, screen.height))
    }

    /// Simulator smoke test: the bot plays the fastest track on hard, once the list has been on screen for a
    /// screenshot (the CI job takes it 2 s after `simctl launch` returns, which can be seconds after launch).
    private func autoplay() {
        guard app.autoplay == "rhythm" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            guard app.rhythm == nil, let t = app.rhythmTracks.max(by: { $0.bpm < $1.bpm }) else { return }
            trackID = t.id
            levelRaw = RhythmLevel.hard.rawValue
            app.prepareRhythm(track: t, level: .hard, screen: Vec2(screen.width, screen.height))
        }
    }
}

/// The first notes of a chart as a small star map: where the eyes will travel.
private struct ConstellationPreview: View {
    let notes: [RhythmNote]

    var body: some View {
        Canvas { g, size in
            let area = ChartGeometry(size: size, inset: 8)
            var last: CGPoint?
            for n in notes {
                let p = area.point(n)
                if let l = last {
                    var line = Path()
                    line.move(to: l)
                    line.addLine(to: p)
                    g.stroke(line, with: .color(Atlas.ink.opacity(0.3)), lineWidth: 1)
                }
                last = p
            }
            for (i, n) in notes.enumerated() {
                let p = area.point(n)
                g.fill(Atlas.star(p, i == 0 ? 7 : 5), with: .color(i == 0 ? Atlas.vermilion : Atlas.ink))
            }
        }
        .background(Atlas.paperShade, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Maps the play area (the part of the screen notes are placed in, ChartGenerator.area) onto a smaller rectangle,
/// keeping its shape on an iPhone screen in landscape.
private struct ChartGeometry {
    private let x0: Double, y0: Double, scale: Double
    private static let xs = 0.1...0.9, ys = 0.22...0.8, aspect = 844.0 / 390

    init(size: CGSize, inset: Double) {
        let w = (Self.xs.upperBound - Self.xs.lowerBound) * Self.aspect
        let h = Self.ys.upperBound - Self.ys.lowerBound
        let availW = Double(size.width) - 2 * inset, availH = Double(size.height) - 2 * inset
        let k = min(availW / w, availH / h)
        scale = k
        x0 = inset + (availW - w * k) / 2
        y0 = inset + (availH - h * k) / 2
    }

    func point(_ n: RhythmNote) -> CGPoint {
        CGPoint(x: x0 + (n.x - Self.xs.lowerBound) * Self.aspect * scale, y: y0 + (n.y - Self.ys.lowerBound) * scale)
    }
}

// MARK: - Play

private struct RhythmPlayView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var status: TrackingStatus
    @ObservedObject var session: RhythmSession
    @State private var touching = false
    /// Where the close button is (screen pt, the same space as the canvas, which spans the whole screen). The
    /// button sits inside the safe area and the canvas does not, so the HUD is laid out from this frame.
    @State private var closeFrame = CGRect.zero

    /// The close button: a 44 pt square at the top right corner of the safe area, this far in from its right edge.
    private static let closeSize: CGFloat = 44, closeTrailing: CGFloat = 16

    var body: some View {
        if session.phase == .done {
            RhythmResults(session: session)
        } else {
            ZStack(alignment: .topTrailing) {
                // The garden behind the notes, in a layer of its own at 30 fps; in play its distractions try to
                // catch the eye.
                GardenLayer(garden: session.garden, distractions: session.distractions,
                            trackStart: session.phase == .playing ? session.startHost : nil)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                TimelineView(.animation) { _ in
                    // The time is read here, once per frame, and captured by the canvas. Read inside the canvas
                    // closure, it gave SwiftUI nothing that changed, so the canvas kept its first frame of play.
                    let now = CACurrentMediaTime()
                    Canvas { g, size in draw(&g, size, now) }
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard !touching else { return }
                        touching = true
                        app.rhythmTouch(at: Vec2(v.location.x, v.location.y))
                    }
                    .onEnded { _ in touching = false })
                if session.phase == .ready { readyText }
                Button { app.leaveRhythmPlay() } label: {
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
    }

    private var readyText: some View {
        VStack(spacing: 8) {
            Text("\(session.track.title) · \(Atlas.levelName(session.level))")
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
            Text(app.mode == .eyes ? "Посмотри на звезду и подмигни" : "Коснись звезды, чтобы начать")
                .font(Atlas.title)
                .foregroundStyle(Atlas.ink)
            Spacer()
            if app.mode == .eyes {
                Text(status.faceFound
                     ? "Звезда засветится под взглядом. Подмигни, и игра подстроится под то, как ты держишь телефон."
                     : "Камера не видит лицо. Держи телефон напротив глаз.")
                    .font(Atlas.caption)
                    .foregroundStyle(status.faceFound ? Atlas.inkSoft : Atlas.vermilion)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding(.top, 24)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// «Мелкие цели»: the scale of the stars, their dials and marks (1: the regular size).
    private var scale: CGFloat { CGFloat(session.targetScale) }

    /// A star's radius on a level (pt), with the target scale in it.
    private func noteRadius(_ l: RhythmLevel) -> CGFloat { (l == .easy ? 20 : l == .normal ? 18 : 16) * scale }

    private func draw(_ g: inout GraphicsContext, _ size: CGSize, _ host: Double) {
        let s = session
        // The aim itself is drawn only for debugging: a cursor that sits a little off where the player looks pulls
        // the eyes after it. The note (or the start star) the aim is locked on lights up instead.
        let aim = app.mode == .eyes && app.showDebug ? app.gazePoint : nil
        let lit = s.lock.locked
        let light = Self.lightUp(since: s.lock.since, host: host)
        let t = s.trackTime(host: host)
        if s.phase == .ready {
            drawStart(&g, s, host, light: lit == RhythmSession.startTarget ? light : 0)
            drawReticle(&g, aim, onTarget: lit != nil)
            return
        }
        let lead = s.level.leadSec
        let r = noteRadius(s.level), dialR = r + 12 * scale
        let next = s.nextOpen(after: t)

        // The constellation so far: lines between notes hit one after the other, under everything else.
        for i in s.notes.indices.dropFirst() {
            guard let a = s.judgedAt[i - 1], let b = s.judgedAt[i], a <= t, b <= t,
                  s.judge.results[i - 1].map({ $0 != .miss }) == true, s.judge.results[i].map({ $0 != .miss }) == true,
                  s.notes[i].time - s.notes[i - 1].time < 3 else { continue }
            let alpha = 0.22 * Self.settle(age: t - b, to: 0)
            guard alpha > 0 else { continue }
            var line = Path()
            line.move(to: cg(s.points[i - 1]))
            line.addLine(to: cg(s.points[i]))
            g.stroke(line, with: .color(Atlas.ink.opacity(alpha)), lineWidth: 1)
        }

        // Where to look after the next note.
        if let n = next, n + 1 < s.notes.count, s.notes[n + 1].time - t < lead {
            var link = Path()
            link.move(to: cg(s.points[n]))
            link.addLine(to: cg(s.points[n + 1]))
            g.stroke(link, with: .color(Atlas.ink.opacity(0.18)), style: StrokeStyle(lineWidth: 1, dash: [4, 6]))
        }

        for (i, n) in s.notes.enumerated() {
            let p = cg(s.points[i])
            if let judged = s.judgedAt[i], let result = s.judge.results[i] {
                drawJudged(&g, p, result, age: t - judged, r: r, dialR: dialR)
                continue
            }
            let dt = n.time - t
            guard dt <= lead else { continue }
            let a = min(1, max(0, 1 - dt / lead))
            var gg = g
            gg.opacity = min(1, a / 0.15)
            let k = i == lit ? light : 0
            if k > 0 { drawLight(&gg, p, (dialR - 3) * CGFloat(0.7 + 0.3 * k), k) }
            gg.stroke(Atlas.dial(p, dialR, 1), with: .color(Atlas.ink.opacity(0.12)), lineWidth: 1.5)
            gg.stroke(Atlas.dial(p, dialR, a), with: .color(Atlas.ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            // The hand's tip, and the mark it reaches on the beat.
            let ang = -Double.pi / 2 + 2 * .pi * a
            let tip = Atlas.polar(p, dialR, ang)
            gg.fill(Path(ellipseIn: CGRect(x: tip.x - 3.5, y: tip.y - 3.5, width: 7, height: 7)), with: .color(Atlas.ink))
            var mark = Path()
            mark.move(to: CGPoint(x: p.x, y: p.y - dialR - 6 * scale))
            mark.addLine(to: CGPoint(x: p.x, y: p.y - dialR + 6 * scale))
            gg.stroke(mark, with: .color(Atlas.vermilion), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            gg.fill(Atlas.star(p, r * CGFloat(1 + 0.15 * k)), with: .color(Atlas.ink))
            if n.side != .any {
                let x = n.side == .left ? p.x - dialR - 16 : p.x + dialR + 16
                gg.stroke(Atlas.closedEye(CGPoint(x: x, y: p.y), 16), with: .color(Atlas.ink),
                          style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }

        drawRejections(&g, s, t, dialR: dialR)

        if let first = s.notes.first, t < first.time - lead {
            g.draw(Text("Слушай ритм").font(Atlas.title).foregroundColor(Atlas.inkSoft),
                   at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        drawHUD(&g, s, t, size)
        drawReticle(&g, aim, onTarget: lit != nil)
    }

    /// Why a closure in a note's window did not play it, under that note for 0.9 s: the eye a side note needs, or
    /// "one eye" for a blink on a level that needs a wink. A blink is only answered when it came on the beat, so an
    /// ordinary blink between notes does not set off a hint.
    private func drawRejections(_ g: inout GraphicsContext, _ s: RhythmSession, _ t: Double, dialR: CGFloat) {
        for r in s.rejections {
            let age = t - r.time
            guard age >= 0, age < 0.9, r.index < s.points.count, r.reason == .wrongEye || r.onBeat else { continue }
            let text: String
            switch r.reason {
            case .blink: text = "одним глазом"
            case .wrongEye: text = s.notes[r.index].side == .left ? "левым глазом" : "правым глазом"
            }
            var gg = g
            gg.opacity = age < 0.6 ? 1 : 1 - (age - 0.6) / 0.3
            let p = cg(s.points[r.index])
            gg.draw(Text(text).font(.system(size: 15, weight: .semibold, design: .serif)).foregroundColor(Atlas.vermilion),
                    at: CGPoint(x: p.x, y: p.y + dialR + 16 + 6 * CGFloat(age)))
        }
    }

    /// How far the light on a locked target is up, 0 to 1: it opens over 0.12 s from the moment of the lock.
    private static func lightUp(since: Double?, host: Double) -> Double {
        guard let since else { return 0 }
        let k = min(1, max(0, (host - since) / 0.12))
        return 1 - (1 - k) * (1 - k)
    }

    /// A warm wash under a target the aim is locked on, like a lamp held over the chart.
    private func drawLight(_ g: inout GraphicsContext, _ p: CGPoint, _ radius: CGFloat, _ k: Double) {
        g.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)),
               with: .color(Atlas.vermilion.opacity(0.17 * k)))
    }

    /// How much of a played note's mark is left `age` seconds after it was judged: all of it for 4 s, then it fades
    /// to `rest` by 10 s. The whole constellation is on the results plate.
    private static func settle(age: Double, to rest: Double) -> Double {
        age < 4 ? 1 : max(rest, 1 - (1 - rest) * (age - 4) / 6)
    }

    private func drawJudged(_ g: inout GraphicsContext, _ p: CGPoint, _ j: Judgement, age: Double, r: CGFloat, dialR: CGFloat) {
        var mark = g
        mark.opacity = Self.settle(age: age, to: 0.3)
        if j == .miss {
            if age < 0.4 {
                var gg = g
                gg.opacity = 1 - age / 0.4
                gg.fill(Atlas.star(p, r * (1 - age)), with: .color(Atlas.missGrey))
            }
            mark.stroke(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)),
                        with: .color(Atlas.missGrey.opacity(0.5)), lineWidth: 1)
        } else {
            mark.fill(Atlas.star(p, 5), with: .color(j == .perfect ? Atlas.vermilion : Atlas.ink.opacity(0.6)))
            if age < 0.35 {
                let k = age / 0.35
                var gg = g
                gg.opacity = 1 - k
                let rr = dialR + 18 * scale * CGFloat(k)
                gg.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)),
                          with: .color(j == .perfect ? Atlas.vermilion : Atlas.ink), lineWidth: 2.5 * (1 - k) + 0.5)
            }
        }
        if age < 0.6 {
            var gg = g
            gg.opacity = 1 - age / 0.6
            let color = j == .perfect ? Atlas.vermilion : j == .miss ? Atlas.missGrey : Atlas.ink
            gg.draw(Text(Atlas.word(j)).font(.system(size: 17, weight: .semibold, design: .serif)).foregroundColor(color),
                    at: CGPoint(x: p.x, y: p.y - dialR - 18 - 12 * age / 0.6))
        }
    }

    private func drawStart(_ g: inout GraphicsContext, _ s: RhythmSession, _ host: Double, light: Double) {
        let p = cg(s.startPoint)
        let k = scale
        if light > 0 { drawLight(&g, p, 40 * k * CGFloat(0.7 + 0.3 * light), light) }
        // A dial that turns slowly while it waits, with the mark at the top.
        var dash = g
        dash.translateBy(x: p.x, y: p.y)
        dash.rotate(by: .radians(host.truncatingRemainder(dividingBy: 60) * 0.35))
        let ring = 44 * k
        dash.stroke(Path(ellipseIn: CGRect(x: -ring, y: -ring, width: 2 * ring, height: 2 * ring)),
                    with: .color(Atlas.ink.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, dash: [2, 7]))
        var mark = Path()
        mark.move(to: CGPoint(x: p.x, y: p.y - 50 * k))
        mark.addLine(to: CGPoint(x: p.x, y: p.y - 38 * k))
        g.stroke(mark, with: .color(Atlas.vermilion), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        g.fill(Atlas.star(p, 22 * k * CGFloat(1 + 0.12 * light)), with: .color(Atlas.ink))
    }

    private func drawHUD(_ g: inout GraphicsContext, _ s: RhythmSession, _ t: Double, _ size: CGSize) {
        // Progress through the track: a hairline across the top, level with the close button's cross. It stops just
        // short of the button, so the score under its right end stays clear of the cross. Its left end sits as far
        // in from the left edge as the cross's right side (15 pt inside the button) is from the right edge, so the
        // band looks the same on phones with and without a notch. Until the button has been laid out, assume it
        // sits at the top right with no safe area.
        let cross = closeFrame.isEmpty
            ? CGRect(x: size.width - Self.closeTrailing - Self.closeSize, y: 0, width: Self.closeSize, height: Self.closeSize)
            : closeFrame
        let x0 = size.width - cross.maxX + 15
        let x1 = cross.minX - 4
        let y = cross.midY
        let k = min(1, max(0, t / s.track.endSec))
        var all = Path(), done = Path()
        all.move(to: CGPoint(x: x0, y: y)); all.addLine(to: CGPoint(x: x1, y: y))
        done.move(to: CGPoint(x: x0, y: y)); done.addLine(to: CGPoint(x: x0 + (x1 - x0) * k, y: y))
        g.stroke(all, with: .color(Atlas.ink.opacity(0.12)), lineWidth: 2)
        g.stroke(done, with: .color(Atlas.ink.opacity(0.6)), lineWidth: 2)
        if s.judge.combo >= 2 {
            g.draw(Text("\(s.judge.combo)").font(Atlas.display(28)).foregroundColor(Atlas.ink),
                   at: CGPoint(x: x0, y: 46), anchor: .leading)
            g.draw(Text("подряд").font(Atlas.caption).foregroundColor(Atlas.inkSoft),
                   at: CGPoint(x: x0, y: 70), anchor: .leading)
        }
        g.draw(Text("\(s.judge.score)").font(Atlas.title.monospacedDigit()).foregroundColor(Atlas.ink),
               at: CGPoint(x: x1, y: 46), anchor: .trailing)
    }

    private func drawReticle(_ g: inout GraphicsContext, _ aim: Vec2?, onTarget: Bool) {
        guard let a = aim else { return }
        let p = cg(a)
        let circle = Path(ellipseIn: CGRect(x: p.x - 13, y: p.y - 13, width: 26, height: 26))
        if onTarget { g.fill(circle, with: .color(Atlas.vermilion.opacity(0.18))) }
        g.stroke(circle, with: .color(Atlas.ink.opacity(0.8)), lineWidth: 1.5)
        var ticks = Path()
        for k in 0..<4 {
            let ang = Double(k) * .pi / 2
            ticks.move(to: Atlas.polar(p, 17, ang))
            ticks.addLine(to: Atlas.polar(p, 22, ang))
        }
        g.stroke(ticks, with: .color(Atlas.ink.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private func cg(_ v: Vec2) -> CGPoint { CGPoint(x: v.x, y: v.y) }
}

// MARK: - Results

private struct RhythmResults: View {
    @EnvironmentObject var app: AppModel
    let session: RhythmSession
    /// The table of this play for the Share button (made when the results appear).
    @State private var exportURL: URL? = nil

    var body: some View {
        let j = session.judge
        HStack(alignment: .center, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                ConstellationPlate(session: session)
                    .aspectRatio(1.9, contentMode: .fit)
                Text("Созвездие «\(session.track.title)», \(Atlas.levelName(session.level).lowercased()) уровень")
                    .font(Atlas.caption.italic())
                    .foregroundStyle(Atlas.inkSoft)
                if let summary = app.rhythmSummary { numbers(summary) }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(verbatim: "\(Int((j.accuracy * 100).rounded()))%").font(Atlas.display(48)).foregroundStyle(Atlas.ink)
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { i in
                            Image(systemName: i < j.stars ? "star.fill" : "star")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(i < j.stars ? Atlas.vermilion : Atlas.missGrey)
                        }
                    }
                    .accessibilityLabel("Звёзд \(j.stars) из 3")
                }
                HStack(spacing: 0) {
                    ForEach(Judgement.allCases, id: \.self) { k in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(j.count(k))").font(Atlas.title).foregroundStyle(k == .perfect ? Atlas.vermilion : Atlas.ink)
                            Text(Atlas.word(k)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Лучшая серия \(j.maxCombo) · очки \(j.score)\(session.isNewBest ? " · новый рекорд" : "")")
                        .foregroundStyle(Atlas.ink)
                    ForEach(notes, id: \.self) { Text($0).foregroundStyle(Atlas.inkSoft) }
                }
                .font(Atlas.caption)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Треки") { app.leaveRhythmPlay() }
                        .buttonStyle(AtlasSecondaryButton())
                    Button("Ещё раз") {
                        app.prepareRhythm(track: session.track, level: session.level, screen: session.screen)
                    }
                    .buttonStyle(AtlasPrimaryButton())
                    if let url = exportURL {
                        ShareLink(item: url) { Label("CSV", systemImage: "square.and.arrow.up") }
                            .buttonStyle(AtlasSecondaryButton())
                            .frame(width: 88)
                            .accessibilityLabel("Поделиться таблицей CSV этой игры")
                    }
                }
            }
            .frame(width: 300)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LivingBackground(growFrom: app.launchTime).ignoresSafeArea())
        .onAppear { exportURL = app.rhythmSummary.flatMap { SessionStore.exportCSV(play: $0) } }
    }

    /// The four numbers of the report as a short list under the plate, in the order every summary has them.
    private func numbers(_ summary: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(ReportText.numbers(summary), id: \.self) { n in
                HStack(spacing: 8) {
                    Text(n.rowLabel).foregroundStyle(Atlas.inkSoft)
                    Spacer(minLength: 4)
                    Text(n.rowValue).foregroundStyle(Atlas.ink).monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
            Text("Это результаты игры, а не медицинские показатели.")
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .font(Atlas.caption)
    }

    /// What the numbers say, in a sentence each.
    private var notes: [String] {
        let j = session.judge
        var out = [String(format: "Подмигивание отстаёт от бита на %.0f мс, игра это учитывает.", j.latencySec * 1000)]
        if j.offTarget > 0 {
            out.append(app.mode == .eyes && j.offTarget >= max(3, session.notes.count / 10)
                       ? "Мимо из-за прицела: \(j.offTarget). Если так часто, откалибруй заново."
                       : "Мимо из-за прицела: \(j.offTarget).")
        }
        if j.wrongEye > 0 { out.append("Не тем глазом: \(j.wrongEye).") }
        if !app.currentChildCode.isEmpty { out.append("Игра сохранена в занятиях \(app.currentChildCode).") }
        return out
    }
}

/// The whole play as a plate from a star atlas: hit notes are stars joined in the order they were played (perfect
/// ones in vermilion), missed ones are small grey rings.
private struct ConstellationPlate: View {
    let session: RhythmSession

    var body: some View {
        Canvas { g, size in
            let area = ChartGeometry(size: size, inset: 16)
            let results = session.judge.results
            let n = session.notes
            for i in n.indices.dropFirst() {
                guard let a = results[i - 1], let b = results[i], a != .miss, b != .miss, n[i].time - n[i - 1].time < 3 else { continue }
                var line = Path()
                line.move(to: area.point(n[i - 1]))
                line.addLine(to: area.point(n[i]))
                g.stroke(line, with: .color(Atlas.ink.opacity(0.3)), lineWidth: 1)
            }
            for (i, note) in n.enumerated() {
                let p = area.point(note)
                switch results[i] {
                case .perfect?: g.fill(Atlas.star(p, 5), with: .color(Atlas.vermilion))
                case .good?, .ok?: g.fill(Atlas.star(p, 4), with: .color(Atlas.ink))
                default:
                    g.stroke(Path(ellipseIn: CGRect(x: p.x - 2.5, y: p.y - 2.5, width: 5, height: 5)),
                             with: .color(Atlas.missGrey), lineWidth: 1)
                }
            }
            // Registration marks in the corners, as on a printed plate.
            var marks = Path()
            let w = size.width, h = size.height, m: CGFloat = 6, l: CGFloat = 12
            let corners: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [(m, m, 1, 1), (w - m, m, -1, 1), (m, h - m, 1, -1), (w - m, h - m, -1, -1)]
            for (x, y, dx, dy) in corners {
                marks.move(to: CGPoint(x: x + dx * l, y: y))
                marks.addLine(to: CGPoint(x: x, y: y))
                marks.addLine(to: CGPoint(x: x, y: y + dy * l))
            }
            g.stroke(marks, with: .color(Atlas.ink.opacity(0.4)), lineWidth: 1)
        }
        .background(Atlas.paperShade, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityLabel("Созвездие этой игры")
    }
}
