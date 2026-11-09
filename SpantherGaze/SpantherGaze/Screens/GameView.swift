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
                    // Transparent, over RootView's paper and garden.
                    SpriteView(scene: scene, options: [.ignoresSiblingOrder, .allowsTransparency])
                    HUDView(hud: scene.hud, paused: $paused, onQuit: { app.route = .menu }, onRecalibrate: { app.beginCalibration() },
                            canRecalibrate: app.mode == .eyes, touchMode: app.mode == .touch,
                            onEnergyTap: { [weak scene] in scene?.reloadTap() })
                }
            }
            .onAppear { if scene == nil { scene = makeScene(size: geo.size) } }
            .onChange(of: paused) { p in scene?.paused_ = p }
            .onChange(of: app.showDebug) { d in scene?.showAim = d }
        }
        .ignoresSafeArea()
    }

    private func makeScene(size: CGSize) -> GameScene {
        let s = GameScene(size: size)
        s.scaleMode = .resizeFill
        s.config = app.balance
        s.marginPt = app.hitMarginPt
        s.useTouch = app.mode == .touch
        s.showAim = app.showDebug
        #if DEBUG
        s.autoplay = app.autoplay != nil
        #endif
        let model = app
        s.gazeSource = { [weak model] in model?.gaze ?? .lost }
        s.onRecord = { [weak model] r in model?.log(r) }
        s.blinkReload = { [weak model] in model?.consumeBlinkReload() ?? false }
        s.pendingBlinks = { [weak model] in model?.pendingBlinks ?? 0 }
        s.onGameEvent = { [weak model] kind, energy, level in model?.logGameEvent(kind: kind, energy: energy, level: level) }
        s.onLookedAt = { [weak model] p in model?.lookedAtMeteor = p }
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
                    pill { Text("\(hud.score)").font(Atlas.title.monospacedDigit()) }
                    pill {
                        HStack(spacing: 4) {
                            ForEach(0..<5, id: \.self) { i in
                                Circle().fill(i < hud.shields ? Atlas.ink : .clear)
                                    .overlay(Circle().stroke(Atlas.ink.opacity(0.5), lineWidth: 1))
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .accessibilityLabel("Щиты: \(hud.shields) из 5")
                    }
                    pill { Text("Уровень \(hud.level)").font(.system(size: 15, weight: .semibold, design: .serif)) }
                    // Landscape: one row, so the meteors keep the height. The energy bar sits in it.
                    if hud.energyMax > 0 {
                        EnergyBar(energy: hud.energy, max: hud.energyMax, reloadProgress: hud.reloadProgress,
                                  needsReload: hud.needsReload, pulse: hud.reloadCount, touchMode: touchMode, onTap: onEnergyTap)
                            .frame(maxWidth: 300)
                    }
                    Spacer()
                    Button { paused = true } label: {
                        pill { Image(systemName: "pause.fill").font(.system(size: 15, weight: .semibold)) }
                    }
                    .accessibilityLabel("Пауза")
                }
                // The front camera's notch is on the left.
                .padding(.leading, 56)
                .padding(.trailing, 20)
                .padding(.top, 10)
                Spacer()
                if hud.needsReload && !paused && !hud.lookBack {
                    ReloadHint(touchMode: touchMode, progress: hud.reloadProgress, needed: hud.reloadNeeded)
                        .padding(.bottom, 80)
                }
            }
            if let b = hud.banner {
                Text(b).font(Atlas.title).foregroundStyle(Atlas.ink)
                    .atlasPlate(padding: 14)
            }
            if hud.lookBack && !paused {
                Text("Посмотри на экран").font(Atlas.display(26)).foregroundStyle(Atlas.ink)
                    .atlasPlate(padding: 16)
            }
            if paused {
                VStack(spacing: 12) {
                    Text("Пауза").font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                    Button { paused = false } label: { Text("Продолжить") }.buttonStyle(AtlasPrimaryButton())
                    if canRecalibrate {
                        Button(action: onRecalibrate) { Text("Калибровка") }.buttonStyle(AtlasSecondaryButton())
                    }
                    Button(action: onQuit) { Text("Главное меню") }.buttonStyle(AtlasSecondaryButton())
                }
                .frame(maxWidth: 320)
                .atlasPlate(padding: 22)
                .padding(16)
            }
        }
    }

    private func pill<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c().font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(minHeight: 36)
            .background(Atlas.paper.opacity(0.88), in: Capsule())
            .overlay(Capsule().stroke(Atlas.ink.opacity(0.14), lineWidth: 1))
            .foregroundStyle(Atlas.ink)
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
                .foregroundStyle(energy > 0 ? Atlas.ink : Atlas.vermilion)
            HStack(spacing: 3) {
                ForEach(0..<max, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i < energy ? Atlas.ink : Atlas.ink.opacity(0.12))
                        .frame(height: 12)
                }
            }
            Text("\(energy)").font(.system(size: 15, weight: .semibold, design: .serif)).monospacedDigit()
                .foregroundStyle(Atlas.ink)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Atlas.paper.opacity(0.88), in: Capsule())
        .overlay(Capsule().stroke(needsReload ? Atlas.vermilion : Atlas.ink.opacity(glow ? 0.6 : 0.14),
                                  lineWidth: needsReload || glow ? 2 : 1))
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

/// "Blink 3 times" with one icon per blink (or tap) that fills as they are counted.
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
            Text(touchMode ? "Нажми на энергию \(times)" : "Моргни \(times)")
                .font(Atlas.title)
                .foregroundStyle(Atlas.ink)
            HStack(spacing: 10) {
                ForEach(0..<needed, id: \.self) { i in
                    Image(systemName: touchMode ? "hand.tap.fill" : (i < progress ? "eye.slash.fill" : "eye"))
                        .foregroundStyle(i < progress ? Atlas.vermilion : Atlas.ink.opacity(0.5))
                }
            }
            .font(.title2)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Atlas.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Atlas.vermilion.opacity(0.8), lineWidth: 1.5))
        .allowsHitTesting(false)
    }
}
