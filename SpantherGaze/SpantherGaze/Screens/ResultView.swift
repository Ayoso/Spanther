import SwiftUI

struct ResultView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Калибровка готова").font(.title2.bold())
            if let r = app.report {
                HStack(spacing: 10) {
                    stat(String(format: "%.0f pt", r.meanErrorPt), String(format: "%.2f см · %.1f°", r.meanErrorCm, r.meanErrorDeg), "средний промах")
                    stat(String(format: "%.0f pt", r.jitterPt), String(format: "%.2f см · %.1f°", r.jitterCm, r.jitterDeg), "дрожание")
                }
                Text(verdict(r)).multilineTextAlignment(.center).foregroundStyle(Palette.dim)
                Text(String(format: "Зона попадания: радиус метеорита + %.0f pt", app.hitMarginPt))
                    .font(.footnote).foregroundStyle(Palette.dim)
            }
            Button { app.route = .game } label: { Text("Играть").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButton())
            Button { app.beginCalibration() } label: { Text("Откалибровать заново").frame(maxWidth: .infinity) }
                .buttonStyle(SecondaryButton())
            ShareLink(item: app.logURL) { Label("Экспорт CSV", systemImage: "square.and.arrow.up") }
                .font(.footnote)
            Spacer()
        }
        .padding(24)
    }

    private func verdict(_ r: AccuracyReport) -> String {
        if r.meanErrorCm <= 1.0 { return "Отлично: цель для взрослого (1,0 см) достигнута." }
        if r.meanErrorCm <= 1.5 { return "Хорошо: в пределах цели для ребёнка (1,5 см)." }
        return "Неточно. Попробуй откалибровать заново при хорошем свете."
    }

    private func stat(_ big: String, _ small: String, _ label: String) -> some View {
        VStack(spacing: 4) {
            Text(big).font(.title.bold()).monospacedDigit()
            Text(small).font(.caption).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}
