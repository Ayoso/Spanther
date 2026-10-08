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
                            canRecalibrate: app.mode == .eyes)
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
        let model = app
        s.gazeSource = { [weak model] in model?.gaze ?? .lost }
        s.onRecord = { [weak model] r in model?.log(r) }
        return s
    }
}

private struct HUDView: View {
    @ObservedObject var hud: GameHUD
    @Binding var paused: Bool
    let onQuit: () -> Void
    let onRecalibrate: () -> Void
    let canRecalibrate: Bool

    var body: some View {
        ZStack {
            VStack {
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
                Spacer()
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
