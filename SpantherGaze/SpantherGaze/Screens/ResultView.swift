import SwiftUI

struct ResultView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        // Landscape: the numbers on the left, the buttons on the right, so it fits in 390 pt of height.
        HStack(spacing: 28) {
            VStack(spacing: 14) {
                Text("Калибровка готова").font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                if let r = app.report {
                    HStack(spacing: 10) {
                        stat(String(format: "%.0f pt", r.meanErrorPt), String(format: "%.2f см · %.1f°", r.meanErrorCm, r.meanErrorDeg), "средний промах")
                        stat(String(format: "%.0f pt", r.jitterPt), String(format: "%.2f см · %.1f°", r.jitterCm, r.jitterDeg), "дрожание")
                    }
                    Text(verdict(r)).font(Atlas.body).multilineTextAlignment(.center).foregroundStyle(Atlas.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: "Зона попадания: радиус метеорита + %.0f pt", app.hitMarginPt))
                        .font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                }
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 12) {
                Button {
                    if app.afterCalibration == .rhythm { app.openRhythm() } else { app.route = .game }
                } label: {
                    Text(app.afterCalibration == .rhythm ? "К ритм-режиму" : "Играть")
                }
                    .buttonStyle(AtlasPrimaryButton())
                Button { app.beginCalibration(then: app.afterCalibration) } label: { Text("Откалибровать заново") }
                    .buttonStyle(AtlasSecondaryButton())
                ShareLink(item: app.logURL) { Label("Экспорт CSV", systemImage: "square.and.arrow.up") }
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.ink)
            }
            .frame(width: 260)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
    }

    private func verdict(_ r: AccuracyReport) -> String {
        if r.meanErrorCm <= 1.0 { return "Отлично: цель для взрослого (1,0 см) достигнута." }
        if r.meanErrorCm <= 1.5 { return "Хорошо: в пределах цели для ребёнка (1,5 см)." }
        return app.nightVision
            ? "Неточно. Без зрачков в темноте так бывает: поднеси телефон чуть ближе и откалибруй заново."
            : "Неточно. Попробуй откалибровать заново при хорошем свете."
    }

    private func stat(_ big: String, _ small: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(big).font(Atlas.display(30)).monospacedDigit().foregroundStyle(Atlas.ink)
            Text(small).font(Atlas.caption).monospacedDigit().foregroundStyle(Atlas.ink)
            Text(label).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
        }
        .frame(maxWidth: .infinity)
        .atlasPlate(padding: 12)
    }
}
