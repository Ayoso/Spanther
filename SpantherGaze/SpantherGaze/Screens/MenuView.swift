import QuartzCore
import SwiftUI

/// The main menu in the atlas look: the mark and the two games on the left, the switches on the right, the living
/// garden behind (RootView draws it).
struct MenuView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        // The smallest screens (iPhone SE, 4.7") cannot fit the whole menu with a warning on it: there it
        // scrolls instead of clipping the title and the footer.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                header
                meteorPlate
                rhythmPlate
                warnings
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            settings
                .frame(width: 270)
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
        }
    }

    private var meteorPlate: some View {
        HStack(alignment: .center, spacing: 16) {
            MeteorVignette()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Метеориты").font(Atlas.title).foregroundStyle(Atlas.ink)
                    Text("Держи взгляд на метеорите, пока он не сгорит. Кончилась энергия? Моргни 3\u{00A0}раза.")
                        .font(Atlas.caption)
                        .foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button {
                        app.mode = .eyes
                        app.beginCalibration()
                    } label: { Text("Играть глазами") }
                        .buttonStyle(AtlasPrimaryButton())
                        .disabled(!app.eyeTrackingSupported)
                    Button {
                        app.mode = .touch
                        app.route = .game
                    } label: { Image(systemName: "hand.point.up.left") }
                        .buttonStyle(AtlasSecondaryButton())
                        .frame(width: 56)
                        .accessibilityLabel("Играть пальцем")
                }
            }
        }
        .atlasPlate(padding: 12)
    }

    private var rhythmPlate: some View {
        HStack(alignment: .center, spacing: 16) {
            NoteVignette()
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ритм").font(Atlas.title).foregroundStyle(Atlas.ink)
                    Text("Смотри на звезду и подмигивай, когда стрелка дойдёт до метки.")
                        .font(Atlas.caption)
                        .foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { app.openRhythm() } label: { Text("Выбрать трек") }
                    .buttonStyle(AtlasPrimaryButton())
                    .disabled(app.rhythmTracks.isEmpty)
            }
        }
        .atlasPlate(padding: 12)
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

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Настройки")
                .font(Atlas.caption.weight(.semibold))
                .foregroundStyle(Atlas.inkSoft)
                .textCase(.uppercase)
                .padding(.bottom, 4)
            setting("Ночное зрение", "Для тёмной комнаты: экран подсвечивает лицо на полной яркости.", $app.nightVision, divider: true)
            setting("Зрачки через Vision", app.nightVision ? "Выключены ночным зрением." : "Точнее при хорошем свете.",
                    $app.usePupils, divider: true)
                .disabled(app.nightVision)
            setting("Подстройка под наклон", "Прицел держится, если наклонить телефон.", $app.adaptAim, divider: true)
            setting("Отладка", "Цифры трекинга и точка взгляда.", $app.showDebug, divider: false)
            HStack(spacing: 16) {
                Button { app.beginWinkTest() } label: { Label("Тест подмигиваний", systemImage: "eye.slash") }
                    .disabled(!app.eyeTrackingSupported)
                ShareLink(item: app.logURL) { Label("CSV", systemImage: "square.and.arrow.up") }
                    .accessibilityLabel("Экспорт CSV последней сессии")
            }
            .font(Atlas.caption.weight(.semibold))
            .foregroundStyle(Atlas.ink)
            .frame(minHeight: 44)
            Text("Изображение с камеры остаётся на телефоне.")
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            // App Review 5.1.1: the privacy policy must be reachable inside the app, not only on the store page.
            Link("Политика конфиденциальности", destination: Self.privacyPolicyURL)
                .font(Atlas.caption.weight(.semibold))
                .foregroundStyle(Atlas.ink)
                .frame(minHeight: 44, alignment: .leading)
        }
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
                    let rr = r + 8 + 14 * k
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
                    let rr = dialR + CGFloat(10 * (1 - hit))
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
