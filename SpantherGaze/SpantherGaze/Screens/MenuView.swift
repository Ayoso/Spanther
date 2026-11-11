import QuartzCore
import SwiftUI

/// The main menu in the atlas look: the mark, the child's sessions and the settings in the top row, the three games
/// side by side under it, the living garden behind (RootView draws it). The switches live in a sheet behind the
/// gear, so the games keep the whole screen.
struct MenuView: View {
    @EnvironmentObject var app: AppModel
    /// The report sheet: the summary of the play that just ended, or the child's history.
    @State private var report: ReportPage?
    @State private var showSettings = false
    /// The wink test was asked for in the settings: it opens once their sheet has closed.
    @State private var winkTestAsked = false

    var body: some View {
        // The smallest screens (iPhone SE, 4.7") cannot fit the whole menu with a warning on it: there it
        // scrolls instead of clipping the title and the footer.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .sheet(item: $report) { page in ReportSheet(page: page).environmentObject(app) }
        .sheet(isPresented: $showSettings, onDismiss: {
            guard winkTestAsked else { return }
            winkTestAsked = false
            app.beginWinkTest()
        }) {
            SettingsSheet(onWinkTest: {
                winkTestAsked = true
                showSettings = false
            })
            .environmentObject(app)
        }
        .onAppear {
            // After a play ends: the sheet waits for the menu to be on screen.
            DispatchQueue.main.async { showLastSummary() }
            #if DEBUG
            if app.demoReport == "history" { DispatchQueue.main.async { report = .history } }
            if app.demoReport == "settings" { DispatchQueue.main.async { showSettings = true } }
            #endif
        }
        .onChange(of: app.lastSummary) { _ in showLastSummary() }
    }

    private func showLastSummary() {
        guard let s = app.lastSummary else { return }
        app.lastSummary = nil
        report = .summary(s)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Three plates of one height: the tallest text sets it, and the buttons line up along the bottom.
            HStack(alignment: .top, spacing: 12) {
                meteorPlate
                rhythmPlate
                pursuitPlate
            }
            .fixedSize(horizontal: false, vertical: true)
            warnings
            footer
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            BrandMark(since: app.launchTime)
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("SPANTHER")
                    .font(Atlas.wordmark(24))
                    .tracking(6)
                    .foregroundStyle(Atlas.ink)
                Text("Игры, в которые играют взглядом")
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
            }
            // The name keeps its whole width; the sessions button takes what is left.
            .layoutPriority(1)
            // The child's sessions, with the code they are saved under; just the icon where the row is narrow.
            ViewThatFits(in: .horizontal) {
                sessionsButton(withTitle: true)
                sessionsButton(withTitle: false)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Atlas.ink)
                    .frame(width: 44, height: 44)
                    .background(Atlas.paper.opacity(0.88), in: Capsule())
                    .overlay(Capsule().stroke(Atlas.ink.opacity(0.14), lineWidth: 1))
            }
            .accessibilityLabel("Настройки")
        }
    }

    private func sessionsButton(withTitle: Bool) -> some View {
        let code = app.currentChildCode
        return Button { report = .history } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                if withTitle { Text(code.isEmpty ? "Занятия" : "Занятия · \(code)").lineLimit(1) }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Atlas.ink)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(Atlas.paper.opacity(0.88), in: Capsule())
            .overlay(Capsule().stroke(Atlas.ink.opacity(0.14), lineWidth: 1))
            .fixedSize()
        }
        .accessibilityLabel(code.isEmpty ? "Занятия" : "Занятия ребёнка \(code)")
    }

    /// One game: its small moving picture and name, what to do in a sentence or two, and its buttons at the bottom.
    private func plate<Art: View, Actions: View>(_ title: String, _ text: String, @ViewBuilder art: () -> Art,
                                                 @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                art()
                    .frame(width: 48, height: 48)
                    .accessibilityHidden(true)
                Text(title).font(Atlas.title).foregroundStyle(Atlas.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(text)
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) { actions() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .atlasPlate(padding: 12)
    }

    /// A button's words on one line; they shrink a little on a narrow plate instead of breaking.
    private func buttonText(_ s: String) -> some View {
        Text(s).lineLimit(1).minimumScaleFactor(0.75).padding(.horizontal, 6)
    }

    /// The small square button that plays the same game by finger.
    private func fingerButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "hand.point.up.left") }
            .buttonStyle(AtlasSecondaryButton())
            .frame(width: 48)
            .accessibilityLabel(label)
    }

    private var meteorPlate: some View {
        plate("Метеориты",
              app.decoysOn
              ? "Держи взгляд на метеорите, пока он не сгорит. Красные знаки пропускай. Кончилась энергия? Моргни 3\u{00A0}раза."
              : "Держи взгляд на метеорите, пока он не сгорит. Кончилась энергия? Моргни 3\u{00A0}раза.",
              art: { MeteorVignette() },
              actions: {
                  Button {
                      app.mode = .eyes
                      app.beginCalibration()
                  } label: { buttonText("Играть глазами") }
                      .buttonStyle(AtlasPrimaryButton())
                      .disabled(!app.eyeTrackingSupported)
                  fingerButton("Играть пальцем") {
                      app.mode = .touch
                      app.route = .game
                  }
              })
    }

    private var rhythmPlate: some View {
        plate("Ритм", "Смотри на звезду и подмигивай, когда стрелка дойдёт до метки.",
              art: { NoteVignette() },
              actions: {
                  Button { app.openRhythm() } label: { buttonText("Выбрать трек") }
                      .buttonStyle(AtlasPrimaryButton())
                      .disabled(app.rhythmTracks.isEmpty)
              })
    }

    private var pursuitPlate: some View {
        plate("Разминка", "Минута для глаз: следи за точкой, пока она плывёт по экрану.",
              art: { PursuitVignette() },
              actions: {
                  Button { app.openPursuit(byEye: true) } label: { buttonText("Начать") }
                      .buttonStyle(AtlasPrimaryButton())
                      .disabled(!app.eyeTrackingSupported)
                  fingerButton("Разминка пальцем") { app.openPursuit(byEye: false) }
              })
    }

    @ViewBuilder private var warnings: some View {
        if app.eyeTrackingSupported && app.cameraDenied {
            VStack(alignment: .leading, spacing: 4) {
                Text("Нет доступа к камере, поэтому игра не видит взгляд. Разреши камеру в настройках и открой игру заново.")
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.vermilion)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Открыть настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(Atlas.caption.bold())
                .foregroundStyle(Atlas.ink)
            }
        }
        if !app.eyeTrackingSupported {
            Text("Этот iPhone не поддерживает отслеживание лица (нужен TrueDepth или чип A12 и новее). Доступна игра пальцем.")
                .font(Atlas.caption)
                .foregroundStyle(Atlas.vermilion)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let privacyPolicyURL = URL(string:
        "https://doc-hosting.flycricket.io/spanther-privacy-policy/117739f5-0c00-4d4e-ac2e-ec17666ddb66/privacy")!

    private var footer: some View {
        HStack(spacing: 12) {
            Text("Изображение с камеры остаётся на телефоне.")
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            // App Review 5.1.1: the privacy policy must be reachable inside the app, not only on the store page.
            Link("Политика конфиденциальности", destination: Self.privacyPolicyURL)
                .font(Atlas.caption.weight(.semibold))
                .foregroundStyle(Atlas.ink)
                .frame(minHeight: 44)
        }
    }
}

/// The switches, in a sheet behind the menu's gear: what the games are like on the left, the camera and the gaze
/// on the right, the tools under them.
private struct SettingsSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    /// Asks the menu to open the wink test once this sheet has closed.
    let onWinkTest: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Настройки").font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                Spacer()
                Button { dismiss() } label: { Text("Готово") }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(width: 130)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 24) {
                        column("Игры") {
                            setting("Мелкие цели", smallTargetsHint, $app.smallTargets, divider: true)
                            setting("Красные знаки", "В метеоритах летят знаки, на которые нельзя смотреть. Ошибки считаются.",
                                    $app.decoysOn, divider: true)
                            setting("Музыка в метеоритах", "Тихий фон без ударных. Кнопка звука есть и в самой игре.",
                                    $app.musicOn, divider: false)
                        }
                        column("Камера и взгляд") {
                            setting("Ночное зрение", "Для тёмной комнаты: экран подсвечивает лицо на полной яркости.",
                                    $app.nightVision, divider: true)
                            setting("Зрачки через Vision", app.nightVision ? "Выключены ночным зрением." : "Точнее при хорошем свете.",
                                    $app.usePupils, divider: true)
                                .disabled(app.nightVision)
                            setting("Подстройка под наклон", "Прицел держится, если наклонить телефон.", $app.adaptAim, divider: true)
                            setting("Отладка", "Цифры трекинга и точка взгляда.", $app.showDebug, divider: false)
                        }
                    }
                    HStack(spacing: 20) {
                        Button(action: onWinkTest) { Label("Тест подмигиваний", systemImage: "eye.slash") }
                            .disabled(!app.eyeTrackingSupported)
                        ShareLink(item: app.logURL) { Label("CSV последней сессии", systemImage: "square.and.arrow.up") }
                            .accessibilityLabel("Экспорт CSV последней сессии")
                        Spacer(minLength: 0)
                    }
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.ink)
                    .frame(minHeight: 44)
                    Text("Изображение с камеры остаётся на телефоне. Таблицы и CSV уходят с него только через кнопку «Поделиться».")
                        .font(Atlas.caption)
                        .foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Atlas.paper.ignoresSafeArea())
        .environment(\.colorScheme, .light)
    }

    /// «на 30% меньше», with the share from balance.json, and the floor under the hit zone.
    private var smallTargetsHint: String {
        let percent = Int(((1 - app.balance.smallTargetScale) * 100).rounded())
        let floor = SessionHistory.number(app.balance.zoneFloorFactor, 2)
        return "Метеориты, звёзды и зоны попадания на \(percent)% меньше. Зона не меньше \(floor) промаха калибровки."
    }

    private func column<Rows: View>(_ title: String, @ViewBuilder rows: () -> Rows) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(Atlas.caption.weight(.semibold))
                .foregroundStyle(Atlas.inkSoft)
                .textCase(.uppercase)
                .padding(.bottom, 4)
            rows()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atlasPlate(padding: 12)
    }

    private func setting(_ title: String, _ hint: String, _ isOn: Binding<Bool>, divider: Bool) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 16, design: .serif)).foregroundStyle(Atlas.ink)
                Text(hint).font(.system(size: 11)).foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Atlas.vermilion)
        .padding(.vertical, 5)
        .overlay(alignment: .bottom) {
            if divider { Rectangle().fill(Atlas.ink.opacity(0.1)).frame(height: 1) }
        }
    }
}

/// The SPANTHER mark: its ring draws itself in after launch, like a gaze being held, and the pupil breathes.
/// The menu's small animations run at 30 fps, like the garden behind them.
struct BrandMark: View {
    var since: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let now = CACurrentMediaTime()
            Canvas { g, size in
                let k = min(1, max(0, (now - since - 0.4) / 1.4))
                let ring = 1 - (1 - k) * (1 - k) * (1 - k)
                let slit = 0.85 + 0.15 * sin(now * 1.3)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                g.fill(Atlas.mark(c, size: min(size.width, size.height), ring: ring, slit: slit),
                       with: .color(Atlas.ink), style: FillStyle(eoFill: true))
            }
        }
    }
}

/// A meteor on the menu: the dial round it fills while it heats up, it bursts, and the next one begins.
private struct MeteorVignette: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let now = CACurrentMediaTime()
            Canvas { g, size in
                let cycle = 3.2, t = now.truncatingRemainder(dividingBy: cycle)
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) * 0.27
                let burn = min(1, t / 2.4)
                if t < 2.4 {
                    var rock = Path()
                    let n = 9
                    for i in 0..<n {
                        let a = Double(i) / Double(n) * 2 * .pi + now * 0.4
                        let rr = r * CGFloat(0.86 + 0.14 * sin(Double(i) * 2.7))
                        let p = Atlas.polar(c, rr, a)
                        if i == 0 { rock.move(to: p) } else { rock.addLine(to: p) }
                    }
                    rock.closeSubpath()
                    g.fill(rock, with: .color(Atlas.vermilion.opacity(0.15 + 0.6 * burn)))
                    g.stroke(rock, with: .color(Atlas.ink), lineWidth: 1.5)
                    let dialR = r + 8
                    g.stroke(Atlas.dial(c, dialR, 1), with: .color(Atlas.ink.opacity(0.12)), lineWidth: 1.5)
                    g.stroke(Atlas.dial(c, dialR, burn), with: .color(Atlas.ink),
                             style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                } else {
                    // The burst: a ring and four small stars flying out.
                    let k = (t - 2.4) / (cycle - 2.4)
                    var gg = g
                    gg.opacity = 1 - k
                    // The ring grows to the edge of the picture, whatever its size.
                    let rr = r + 8 + max(2, min(size.width, size.height) / 2 - r - 9) * CGFloat(k)
                    gg.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                              with: .color(Atlas.vermilion), lineWidth: 2)
                    for s in 0..<4 {
                        let p = Atlas.polar(c, r * CGFloat(0.4 + 1.2 * k), Double(s) * .pi / 2 + .pi / 4)
                        gg.fill(Atlas.star(p, 4), with: .color(Atlas.ink))
                    }
                }
            }
        }
    }
}

/// A rhythm note on the menu: the hand goes round once a beat and the star answers when it reaches the mark.
private struct NoteVignette: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let now = CACurrentMediaTime()
            Canvas { g, size in
                let beat = 1.2
                let a = now.truncatingRemainder(dividingBy: beat) / beat
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r: CGFloat = min(size.width, size.height) * 0.2, dialR = r + 9
                let hit = a < 0.18 ? 1 - a / 0.18 : 0
                if hit > 0 {
                    let rr = dialR + max(2, min(size.width, size.height) / 2 - dialR - 1) * CGFloat(1 - hit)
                    g.stroke(Path(ellipseIn: CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)),
                             with: .color(Atlas.vermilion.opacity(hit)), lineWidth: 2)
                }
                g.stroke(Atlas.dial(c, dialR, 1), with: .color(Atlas.ink.opacity(0.12)), lineWidth: 1.5)
                g.stroke(Atlas.dial(c, dialR, a), with: .color(Atlas.ink), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                let tip = Atlas.polar(c, dialR, -Double.pi / 2 + 2 * .pi * a)
                g.fill(Path(ellipseIn: CGRect(x: tip.x - 3, y: tip.y - 3, width: 6, height: 6)), with: .color(Atlas.ink))
                var mark = Path()
                mark.move(to: CGPoint(x: c.x, y: c.y - dialR - 5))
                mark.addLine(to: CGPoint(x: c.x, y: c.y - dialR + 5))
                g.stroke(mark, with: .color(Atlas.vermilion), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                g.fill(Atlas.star(c, r * CGFloat(1 + 0.18 * hit)), with: .color(Atlas.ink))
            }
        }
    }
}

/// The warm-up on the menu: a dot gliding along a figure of eight, as it does in the last part of the minute.
private struct PursuitVignette: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
            let now = CACurrentMediaTime()
            Canvas { g, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let rx = size.width * 0.4, ry = size.height * 0.24
                // The eight: once across while twice up and down.
                func at(_ a: Double) -> CGPoint {
                    let dx: Double = sin(a), dy: Double = sin(2 * a)
                    return CGPoint(x: c.x + rx * CGFloat(dx), y: c.y + ry * CGFloat(dy))
                }
                var eight = Path()
                for k in 0...48 {
                    let p = at(2 * Double.pi * Double(k) / 48)
                    if k == 0 { eight.move(to: p) } else { eight.addLine(to: p) }
                }
                g.stroke(eight, with: .color(Atlas.ink.opacity(0.25)), lineWidth: 1.5)
                let p = at(2 * Double.pi * now.truncatingRemainder(dividingBy: 6) / 6)
                g.stroke(Atlas.dial(p, 8, 1), with: .color(Atlas.ink.opacity(0.14)), lineWidth: 1.5)
                g.fill(Path(ellipseIn: CGRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)), with: .color(Atlas.vermilion))
            }
        }
    }
}

// The dark buttons of the wink test (the one screen left in the old dark look).

struct PrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 16)
            .background(Palette.gaze.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(Color(red: 0.02, green: 0.13, blue: 0.11))
    }
}

struct SecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.vertical, 16)
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.dim.opacity(0.4)))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.6 : 1))
    }
}
