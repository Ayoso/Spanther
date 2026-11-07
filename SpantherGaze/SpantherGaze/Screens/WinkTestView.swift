import SwiftUI
import QuartzCore

/// Measures one-eye winks before the rhythm mode is built. A click sounds every second and the screen shows which
/// eye to wink on it: 20 left, 20 right, then 20 alternating. The results show how many winks the detector saw on
/// the asked eye, how late they landed, how much the other eye squinted and how often a wink looked like a blink.
/// The session CSV gets `wink_test`, `cue`, `wink` and `wink_frame` rows, which GazeReplay reads.
struct WinkTestView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var status: TrackingStatus

    private enum Phase { case intro, running, done }
    @State private var phase: Phase = .intro
    @State private var plan = WinkTestPlan()
    /// Host time (CACurrentMediaTime) of the first count-in click.
    @State private var start = 0.0
    /// Clicks handed to the audio player, and cues written to the CSV.
    @State private var scheduled = 0
    @State private var cuesLogged = 0
    @State private var stats: WinkStats?
    @State private var clicks: ClickPlayer?
    @State private var ticker = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            switch phase {
            case .intro: intro
            case .running: running
            case .done: results
            }
        }
        .onReceive(ticker) { _ in tick() }
        .onAppear { autoBegin() }
        .onDisappear { clicks?.stop() }
    }

    /// Simulator smoke test: the bot starts the run itself, once the intro has been on screen for a screenshot.
    private func autoBegin() {
        guard app.autoplay == "wink" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { if phase == .intro { begin() } }
    }

    // MARK: intro

    private var intro: some View {
        HStack(spacing: 32) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Тест подмигиваний").font(.title2.bold())
                Text("Каждую секунду щёлкает метроном. На каждый щелчок подмигни глазом, который горит на экране: сначала 20 раз левым, потом 20 раз правым, потом по очереди. Это чуть больше минуты.")
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Держи телефон как в игре. Сначала попробуй: когда подмигиваешь, полоска этого глаза доходит до черты, а вторая остаётся ниже.")
                    .font(.footnote)
                    .foregroundStyle(Palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button { app.route = .menu } label: { Text("Назад").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButton())
                    Button { begin() } label: { Text("Начать").frame(maxWidth: .infinity) }
                        .buttonStyle(PrimaryButton())
                        .disabled(!status.faceFound)
                }
            }
            .frame(maxWidth: 420)
            VStack(spacing: 16) {
                HStack(spacing: 32) {
                    lid("Левый", status.blink?.left ?? 0, close: status.winkCloseLevel.left)
                    lid("Правый", status.blink?.right ?? 0, close: status.winkCloseLevel.right)
                }
                Text(status.faceFound ? lastWinkText : "Не видно лица")
                    .font(.footnote)
                    .foregroundStyle(status.faceFound ? Palette.dim : Palette.hot)
            }
        }
        .padding(24)
    }

    private var lastWinkText: String {
        guard let w = status.lastWink else { return "Подмигни, чтобы проверить" }
        switch w.side {
        case .left: return "Последнее: левый глаз"
        case .right: return "Последнее: правый глаз"
        case .both: return "Последнее: оба глаза"
        }
    }

    /// One eyelid, 0 open at the bottom to 1 closed at the top, with the level at which it counts as closed.
    private func lid(_ title: String, _ value: Double, close: Double) -> some View {
        let h = 120.0
        return VStack(spacing: 8) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 6)
                    .fill(value >= close ? Palette.gaze : Palette.dim.opacity(0.7))
                    .frame(height: h * min(1, max(0, value)))
                Rectangle().fill(Palette.fire).frame(height: 2).offset(y: -h * min(1, close))
            }
            .frame(width: 24, height: h)
            Text(title).font(.footnote).foregroundStyle(Palette.dim)
        }
    }

    // MARK: run

    private var running: some View {
        TimelineView(.animation) { _ in
            let now = CACurrentMediaTime()
            let next = nextCue(after: now - 0.3)
            ZStack {
                HStack(spacing: 0) {
                    target(.left, next: next, now: now)
                    Rectangle().fill(Palette.dim.opacity(0.15)).frame(width: 1)
                    target(.right, next: next, now: now)
                }
                VStack {
                    HStack {
                        Text(caption(next: next, now: now)).font(.headline.monospacedDigit())
                        Spacer()
                        Button("Стоп") { stopRun() }.font(.headline)
                    }
                    Spacer()
                }
                .padding(24)
            }
        }
    }

    /// The cue being approached, or just passed (until 0.3 s after its beat). nil after the last one.
    private func nextCue(after t: Double) -> WinkTestPlan.Cue? {
        plan.cues.first { start + $0.offset > t }
    }

    private func nearestCue(to t: Double) -> (cue: WinkTestPlan.Cue, time: Double)? {
        plan.cues.map { (cue: $0, time: start + $0.offset) }.min { abs($0.time - t) < abs($1.time - t) }
    }

    /// One half of the screen: the user's left eye on the left. The asked side lights up and a ring closes onto it
    /// over the last beat before its click.
    private func target(_ side: WinkSide, next: WinkTestPlan.Cue?, now: Double) -> some View {
        let beat = next.map { start + $0.offset } ?? 0
        let active = next?.side == side
        let p = max(0, min(1, (beat - now) / plan.periodSec))
        let size = 104.0
        return ZStack {
            Circle().stroke(Palette.dim.opacity(0.25), lineWidth: 2).frame(width: size, height: size)
            if active {
                Circle().fill(Palette.gaze.opacity(0.16)).frame(width: size, height: size)
                if now <= beat {
                    Circle().stroke(Palette.gaze, lineWidth: 4)
                        .frame(width: size * (1 + 1.2 * p), height: size * (1 + 1.2 * p))
                }
            }
            VStack(spacing: 8) {
                Image(systemName: active ? "eye.slash.fill" : "eye")
                    .font(.system(size: 30, weight: .semibold))
                Text(side == .left ? "левый" : "правый").font(.footnote)
            }
            .foregroundStyle(active ? Palette.gaze : Palette.dim.opacity(0.5))
            feedback(side, now: now)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A flash for half a second after a wink on this side: cyan on the asked eye, red on the wrong one, amber when
    /// both eyes closed. The number is how late (+) or early (-) it landed against the nearest click.
    @ViewBuilder
    private func feedback(_ side: WinkSide, now: Double) -> some View {
        if let w = status.lastWink, now - w.onset < 0.5, w.side == side || w.side == .both,
           let near = nearestCue(to: w.onset) {
            let age = max(0, now - w.onset) / 0.5
            let onTime = abs(w.onset - near.time) <= 0.45
            let color = w.side == .both ? Palette.fire : (near.cue.side == side && onTime ? Palette.gaze : Palette.hot)
            ZStack {
                Circle().stroke(color, lineWidth: 6)
                    .frame(width: 104 * (1 + 0.4 * age), height: 104 * (1 + 0.4 * age))
                    .opacity(1 - age)
                Text(String(format: "%+.0f мс", (w.onset - near.time) * 1000))
                    .font(.subheadline.bold().monospacedDigit())
                    .foregroundStyle(color)
                    .offset(y: 90)
                    .opacity(1 - age)
            }
        }
    }

    private func caption(next: WinkTestPlan.Cue?, now: Double) -> String {
        guard let next, let first = plan.cues.first else { return "Готово" }
        if now < start + first.offset - 0.3 {
            return "Приготовься: \(Int((start + first.offset - now).rounded(.up)))"
        }
        let block = plan.cues.filter { $0.block == next.block }
        let n = (block.firstIndex(of: next) ?? 0) + 1
        let name = ["Левый глаз", "Правый глаз", "По очереди"][min(next.block, 2)]
        return "\(name) · \(n) из \(block.count)"
    }

    private func begin() {
        let player = clicks ?? ClickPlayer()
        clicks = player
        start = CACurrentMediaTime() + 0.8
        scheduled = 0
        cuesLogged = 0
        stats = nil
        app.startWinkRun(plan: plan, time: start, audioLatency: player.outputLatency)
        phase = .running
    }

    private func tick() {
        guard phase == .running, let player = clicks else { return }
        let now = CACurrentMediaTime()
        let times = plan.clicks
        // Clicks go to the audio player a little ahead, so each one starts on the audio clock.
        while scheduled < times.count, start + times[scheduled] < now + 0.35 {
            let offset = times[scheduled]
            let cue = plan.cues.first { abs($0.offset - offset) < 1e-6 }
            let pan: Float = cue.map { $0.side == .left ? -0.8 : 0.8 } ?? 0
            player.play(at: start + offset, pan: pan, accent: cue == nil)
            scheduled += 1
        }
        while cuesLogged < plan.cues.count, start + plan.cues[cuesLogged].offset <= now {
            let c = plan.cues[cuesLogged]
            app.logWinkCue(side: c.side, time: start + c.offset)
            cuesLogged += 1
        }
        if now > start + plan.durationSec + 0.5 {
            stats = WinkStats.compute(cues: plan.cues, beats: plan.cues.map { start + $0.offset }, events: app.winks)
            phase = .done
        }
    }

    private func stopRun() {
        clicks?.stop()
        phase = .intro
    }

    // MARK: results

    private var results: some View {
        let s = stats ?? WinkStats()
        return VStack(alignment: .leading, spacing: 16) {
            Text("Результат теста").font(.title2.bold())
            HStack(alignment: .top, spacing: 24) {
                eye("Левый глаз", s.left)
                eye("Правый глаз", s.right)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Лишние подмигивания: \(s.strayOneEye) · моргания: \(s.strayBoth)")
                        .font(.footnote)
                        .foregroundStyle(Palette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    ShareLink(item: app.logURL) {
                        Label("Отправить CSV", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButton())
                    Button { begin() } label: { Text("Ещё раз").frame(maxWidth: .infinity) }
                        .buttonStyle(SecondaryButton())
                    Button("В меню") { app.route = .menu }.font(.footnote)
                }
                .frame(width: 200)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    private func eye(_ title: String, _ e: WinkStats.Eye) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            row("Попал этим глазом", "\(e.hits) из \(e.cues)")
            row("Другим глазом", "\(e.wrongEye)")
            row("Обоими глазами", "\(e.bothEyes)")
            row("Средний сдвиг", String(format: "%+.0f мс", e.meanOffsetMs))
            row("Разброс", String(format: "±%.0f мс", e.sdOffsetMs))
            row("В окне 100/180/250 мс", "\(e.within100)/\(e.within180)/\(e.within250)")
            row("Прищур второго глаза", String(format: "%.2f", e.medianOtherPeak).replacingOccurrences(of: ".", with: ","))
        }
        .frame(width: 220, alignment: .leading)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).foregroundStyle(Palette.dim)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.footnote)
    }
}
