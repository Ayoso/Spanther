import SpriteKit
import SwiftUI

struct GameView: View {
    @EnvironmentObject var app: AppModel
    @State private var scene: GameScene?
    @State private var paused = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let scene {
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder])
                    HUDView(hud: scene.hud, paused: $paused, onQuit: { app.route = .menu }, onRecalibrate: { app.beginCalibration() },
                            canRecalibrate: app.mode == .eyes, touchMode: app.mode == .touch,
                            onEnergyTap: { [weak scene] in scene?.reloadTap() })
                }
            }
            .onAppear { if scene == nil { scene = makeScene(size: geo.size) } }
            .onChange(of: paused) { p in scene?.paused_ = p }
        }
        .ignoresSafeArea()
    }

    private func makeScene(size: CGSize) -> GameScene {
        let s = GameScene(size: size)
        s.scaleMode = .resizeFill
        s.config = app.balance
        s.marginPt = app.hitMarginPt
        s.useTouch = app.mode == .touch
        #if DEBUG
        s.autoplay = app.autoplay != nil
        #endif
        let model = app
        s.gazeSource = { [weak model] in model?.gaze ?? .lost }
        s.onRecord = { [weak model] r in model?.log(r) }
        s.blinkReload = { [weak model] in model?.consumeBlinkReload() ?? false }
        s.pendingBlinks = { [weak model] in model?.pendingBlinks ?? 0 }
        s.onGameEvent = { [weak model] kind, energy, level in model?.logGameEvent(kind: kind, energy: energy, level: level) }
        return s
    }
}

private struct HUDView: View {
    @ObservedObject var hud: GameHUD
    @Binding var paused: Bool
    let onQuit: () -> Void
    let onRecalibrate: () -> Void
    let canRecalibrate: Bool
    let touchMode: Bool
    let onEnergyTap: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    pill { Text("\(hud.score)").monospacedDigit() }
                    pill {
                        HStack(spacing: 4) {
                            ForEach(0..<5, id: \.self) { i in
                                Circle().fill(i < hud.shields ? Color(red: 0.24, green: 0.55, blue: 1) : .clear)
                                    .overlay(Circle().stroke(Palette.dim.opacity(0.5)))
                                    .frame(width: 11, height: 11)
                            }
                        }
                    }
                    pill { Text("Ур. \(hud.level)") }
                    Spacer()
                    Button { paused = true } label: { pill { Image(systemName: "pause.fill") } }
                }
                .padding(.horizontal, 14)
                .padding(.top, 54)
                if hud.energyMax > 0 {
                    EnergyBar(energy: hud.energy, max: hud.energyMax, reloadProgress: hud.reloadProgress,
                              needsReload: hud.needsReload, pulse: hud.reloadCount, touchMode: touchMode, onTap: onEnergyTap)
                        .padding(.horizontal, 14)
                }
                Spacer()
                if hud.needsReload && !paused && !hud.lookBack {
                    ReloadHint(touchMode: touchMode, progress: hud.reloadProgress, needed: hud.reloadNeeded)
                        .padding(.bottom, 150)
                }
            }
            if let b = hud.banner {
                Text(b).font(.title3.bold()).padding(14)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
            }
            if hud.lookBack && !paused {
                Text("Посмотри на экран").font(.title2.bold()).padding(16)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 14))
            }
            if paused {
                VStack(spacing: 12) {
                    Text("Пауза").font(.title2.bold())
                    Button { paused = false } label: { Text("Продолжить").frame(maxWidth: .infinity) }.buttonStyle(PrimaryButton())
                    if canRecalibrate {
                        Button(action: onRecalibrate) { Text("Калибровка").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButton())
                    }
                    Button(action: onQuit) { Text("Главное меню").frame(maxWidth: .infinity) }.buttonStyle(SecondaryButton())
                }
                .padding(22)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
                .padding(28)
            }
        }
    }

    private func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().font(.subheadline.bold())
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.45), in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Energy pool as segments. In touch mode the whole bar is the reload button (3 taps).
private struct EnergyBar: View {
    let energy: Int
    let max: Int
    let reloadProgress: Int
    let needsReload: Bool
    let pulse: Int
    let touchMode: Bool
    let onTap: () -> Void
    @State private var glow = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .foregroundStyle(energy > 0 ? Palette.gaze : Palette.hot)
            HStack(spacing: 3) {
                ForEach(0..<max, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i < energy ? Palette.gaze : Palette.dim.opacity(0.18))
                        .frame(height: 14)
                }
            }
            Text("\(energy)").font(.subheadline.bold()).monospacedDigit().foregroundStyle(.white)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().stroke(needsReload ? Palette.hot : Palette.gaze.opacity(glow ? 0.9 : 0), lineWidth: 2))
        .scaleEffect(glow ? 1.04 : 1)
        .contentShape(Capsule())
        .onTapGesture { if touchMode { onTap() } }
        .accessibilityLabel("Энергия \(energy) из \(max)")
        .onChange(of: pulse) { _ in
            withAnimation(.easeOut(duration: 0.15)) { glow = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { withAnimation(.easeIn(duration: 0.3)) { glow = false } }
        }
    }
}

/// "Blink 3 times" with one icon per blink (or tap) that lights up as they are counted.
private struct ReloadHint: View {
    let touchMode: Bool
    let progress: Int
    let needed: Int

    /// 2, 3, 4, 22... раза; 5...20, 25... раз.
    private var times: String {
        let n = needed % 100
        return (2...4).contains(n % 10) && !(12...14).contains(n) ? "\(needed) раза" : "\(needed) раз"
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(touchMode ? "Нажми на энергию \(times)" : "Моргни \(times)").font(.title3.bold())
            HStack(spacing: 10) {
                ForEach(0..<needed, id: \.self) { i in
                    Image(systemName: touchMode ? "hand.tap.fill" : (i < progress ? "eye.slash.fill" : "eye.fill"))
                        .foregroundStyle(i < progress ? Palette.gaze : Palette.dim.opacity(0.6))
                }
            }
            .font(.title2)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.hot.opacity(0.7), lineWidth: 1.5))
        .allowsHitTesting(false)
    }
}
