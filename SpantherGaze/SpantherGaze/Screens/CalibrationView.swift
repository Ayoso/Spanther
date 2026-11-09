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
                    Dot(collecting: collecting, color: kind == .calibration ? Atlas.vermilion : Atlas.ink)
                        .position(x: p.x, y: p.y)
                        .id(index)
                }
                if started {
                    // Landscape: the dot rows sit at 10, 50 and 90% of a 390 pt high screen, so the text and the
                    // button go between the dot columns (30% and 70% across), clear of every calibration and check dot.
                    Text(message).font(.system(size: 16, weight: .semibold, design: .serif)).foregroundStyle(Atlas.inkSoft)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                        .frame(width: 240)
                        .position(x: size.x * 0.3, y: 34)
                    Button {
                        app.cancelCollecting()
                        app.route = .menu
                    } label: { Text("Отмена").font(.footnote.bold()).padding(.horizontal, 18) }
                        .buttonStyle(AtlasSecondaryButton())
                        .fixedSize()
                        .position(x: size.x * 0.7, y: size.y - 40)
                } else {
                    intro.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .task(id: started) {
                guard started else { return }
                await run(size: size)
            }
        }
        .ignoresSafeArea()
    }

    private var intro: some View {
        VStack(spacing: 14) {
            Text(kind == .calibration ? "Научим игру твоим глазам" : "Проверка точности")
                .font(Atlas.display(28))
                .foregroundStyle(Atlas.ink)
            Text(kind == .calibration
                 ? "Держи телефон двумя руками примерно в 30 см от лица, камерой слева, и не закрывай её пальцем. Смотри на каждую точку, пока вокруг неё бежит кружок. Голову можно чуть-чуть поворачивать."
                 : "Ещё 13 точек в новых местах. По ним игра узнает, насколько точно видит твой взгляд.")
                .font(Atlas.body)
                .multilineTextAlignment(.center).foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            if app.nightVision {
                Text("Ночное зрение: экран светит на лицо на полной яркости, зрачки не нужны.")
                    .font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Circle().fill(status.faceFound ? Atlas.moss : Atlas.vermilion).frame(width: 10, height: 10)
                Text(faceLine).font(Atlas.caption).foregroundStyle(status.faceFound ? Atlas.ink : Atlas.vermilion)
            }
            HStack(spacing: 12) {
                Button { app.route = .menu } label: { Text("Назад") }
                    .buttonStyle(AtlasSecondaryButton())
                Button { started = true } label: { Text("Начать") }
                    .buttonStyle(AtlasPrimaryButton())
                    .disabled(!status.faceFound)
            }
        }
        .frame(maxWidth: 520)
        .padding(24)
    }

    /// Whether the camera sees the face, and a word about the light when it is dim (ARKit's estimate, lumens;
    /// about 1000 in a lit room).
    private var faceLine: String {
        let dark = (status.light ?? 1000) < 120
        if !status.faceFound {
            return app.nightVision || dark
                ? "Не видно лица. Если темно, поднеси телефон ближе: экран подсветит лицо."
                : "Не видно лица"
        }
        return dark && !app.nightVision ? "Лицо найдено, но темно. Включи ночное зрение в меню." : "Лицо найдено"
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
            Circle().fill(Atlas.paper).frame(width: 5, height: 5)
            Circle().stroke(Atlas.ink.opacity(0.12), lineWidth: 1.5).frame(width: 34, height: 34)
            Circle().trim(from: 0, to: sweep).stroke(Atlas.ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: 34, height: 34).rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { shrink = true } }
        .onChange(of: collecting) { on in
            if on { withAnimation(.linear(duration: 1.0)) { sweep = 1 } }
        }
    }
}
