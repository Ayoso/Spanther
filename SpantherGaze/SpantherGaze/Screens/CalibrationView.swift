import SwiftUI

/// 9-dot calibration or 13-dot check. Positions are in screen pt (full-screen, top-left origin).
struct CalibrationView: View {
    enum Kind { case calibration, check }
    let kind: Kind

    @EnvironmentObject var app: AppModel
    @EnvironmentObject var status: TrackingStatus
    @State private var index = 0
    @State private var collecting = false
    @State private var started = false
    @State private var message = ""

    private let settle: UInt64 = 700_000_000     // eyes travel to the dot
    private let collect: UInt64 = 1_000_000_000  // ~60 frames per dot

    private var points: [Vec2] { kind == .calibration ? CalibrationLayout.calibration : CalibrationLayout.validation }

    var body: some View {
        GeometryReader { geo in
            let size = Vec2(geo.size.width, geo.size.height)
            ZStack {
                if started && index < points.count {
                    let p = CalibrationLayout.point(points[index], in: size)
                    Dot(collecting: collecting, color: kind == .calibration ? Palette.fire : Palette.gaze)
                        .position(x: p.x, y: p.y)
                        .id(index)
                }
                VStack(spacing: 14) {
                    if !started {
                        intro
                    } else {
                        Text(message).font(.callout.bold()).foregroundStyle(Palette.dim)
                            .multilineTextAlignment(.center).padding(.top, 8)
                    }
                    Spacer()
                    if started {
                        Button {
                            app.cancelCollecting()
                            app.route = .menu
                        } label: { Text("Отмена").font(.footnote.bold()).padding(.horizontal, 18).padding(.vertical, 10) }
                            .buttonStyle(SecondaryButton())
                            .padding(.bottom, 24)
                    }
                }
                .padding(20)
            }
            .task(id: started) {
                guard started else { return }
                await run(size: size)
            }
        }
        .ignoresSafeArea()
    }

    private var intro: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 120)
            Text(kind == .calibration ? "Научим игру твоим глазам" : "Проверка точности")
                .font(.title2.bold())
            Text(kind == .calibration
                 ? "Держи телефон примерно в 30 см от лица. Смотри на каждую точку, пока вокруг неё бежит кружок. Голову можно чуть-чуть поворачивать."
                 : "Ещё 13 точек в новых местах. По ним игра узнает, насколько точно видит твой взгляд.")
                .multilineTextAlignment(.center).foregroundStyle(Palette.dim)
            HStack(spacing: 8) {
                Circle().fill(status.faceFound ? Palette.gaze : Palette.fire).frame(width: 10, height: 10)
                Text(status.faceFound ? "Лицо найдено" : "Не видно лица").font(.footnote)
            }
            Button { started = true } label: { Text("Начать").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButton())
                .disabled(!status.faceFound)
            Button { app.route = .menu } label: { Text("Назад").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButton())
        }
        .padding(8)
    }

    @MainActor
    private func run(size: Vec2) async {
        let label = kind == .calibration ? "calibration" : "check"
        index = 0
        while index < points.count {
            message = kind == .calibration ? "Смотри на точку · \(index + 1) из \(points.count)" : "Проверка · \(index + 1) из \(points.count)"
            collecting = false
            try? await Task.sleep(nanoseconds: settle)
            if Task.isCancelled { return }
            collecting = true
            app.beginCollecting(target: CalibrationLayout.point(points[index], in: size), kind: label)
            try? await Task.sleep(nanoseconds: collect)
            if Task.isCancelled { return }
            if app.endCollecting() {
                index += 1
            } else {
                message = "Лицо пропало. Повторим эту точку."
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
        if kind == .calibration { app.finishCalibration() } else { app.finishCheck() }
    }
}

private struct Dot: View {
    let collecting: Bool
    let color: Color
    @State private var shrink = false
    @State private var sweep: CGFloat = 0

    var body: some View {
        ZStack {
            Circle().fill(color).frame(width: shrink ? 14 : 40, height: shrink ? 14 : 40)
            Circle().fill(Palette.space).frame(width: 5, height: 5)
            Circle().trim(from: 0, to: sweep).stroke(.white.opacity(0.8), lineWidth: 2.5)
                .frame(width: 34, height: 34).rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { shrink = true } }
        .onChange(of: collecting) { on in
            if on { withAnimation(.linear(duration: 1.0)) { sweep = 1 } }
        }
    }
}
