import SwiftUI

struct MenuView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("SPANTHER")
                .font(.system(size: 46, weight: .black, design: .rounded))
                .tracking(4)
                .foregroundStyle(LinearGradient(colors: [.white, Palette.fire], startPoint: .top, endPoint: .bottom))
            Text("Метеориты летят на Землю. Посмотри на метеорит и держи взгляд, пока он не взорвётся.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.dim)
            sizes
            VStack(spacing: 12) {
                Button {
                    app.mode = .eyes
                    app.beginCalibration()
                } label: { Text("Играть глазами").frame(maxWidth: .infinity) }
                    .buttonStyle(PrimaryButton())
                    .disabled(!app.eyeTrackingSupported)
                Button {
                    app.mode = .touch
                    app.route = .game
                } label: { Text("Играть пальцем").frame(maxWidth: .infinity) }
                    .buttonStyle(SecondaryButton())
            }
            if app.eyeTrackingSupported && app.cameraDenied {
                VStack(spacing: 8) {
                    Text("Нет доступа к камере, поэтому игра не видит взгляд. Разреши камеру в настройках и открой игру заново.")
                        .font(.footnote).multilineTextAlignment(.center).foregroundStyle(Palette.fire)
                    Button("Открыть настройки") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .font(.footnote.bold())
                }
            }
            if !app.eyeTrackingSupported {
                Text("Этот iPhone не поддерживает отслеживание лица (нужен TrueDepth или чип A12 и новее). Доступна игра пальцем.")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(Palette.fire)
            }
            Toggle("Зрачки через Vision", isOn: $app.usePupils).font(.footnote).foregroundStyle(Palette.dim)
            Toggle("Отладка", isOn: $app.showDebug).font(.footnote).foregroundStyle(Palette.dim)
            ShareLink(item: app.logURL) { Label("Экспорт CSV последней сессии", systemImage: "square.and.arrow.up") }
                .font(.footnote)
            Spacer()
            Text("Изображение с камеры остаётся на телефоне.").font(.footnote).foregroundStyle(Palette.dim)
        }
        .padding(24)
    }

    private var sizes: some View {
        HStack(spacing: 10) {
            ForEach(BalanceConfig.classOrder, id: \.self) { name in
                if let c = app.balance.classes[name] {
                    VStack(spacing: 6) {
                        Circle().fill(RadialGradient(colors: [Color(red: 0.79, green: 0.64, blue: 0.48), Color(red: 0.42, green: 0.29, blue: 0.2)], center: .topLeading, startRadius: 2, endRadius: 30))
                            .frame(width: c.sizePt / 6, height: c.sizePt / 6)
                            .frame(height: 38)
                        Text(String(format: "%.1f с", c.dwellSec)).font(.subheadline.bold()).monospacedDigit()
                        Text(name).font(.caption).foregroundStyle(Palette.dim)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}

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
