import SwiftUI

// The report for the specialist and the parent: the summary after a meteor play, and the child's history with the
// table the Share button sends. Game results only, said as such on the screen: no diagnosis, no health claims.

/// What the menu's report sheet opens on.
enum ReportPage: Identifiable {
    case history
    case summary(SessionSummary)

    var id: String {
        switch self {
        case .history: return "history"
        case .summary(let s): return s.id
        }
    }
}

struct ReportSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State var page: ReportPage

    var body: some View {
        Group {
            switch page {
            case .summary(let s):
                PlaySummaryView(summary: s, onHistory: { page = .history }, onDone: { dismiss() })
            case .history:
                HistoryView(onDone: { dismiss() })
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Atlas.paper.ignoresSafeArea())
        .environment(\.colorScheme, .light)
    }
}

// MARK: - After a meteor play

private struct PlaySummaryView: View {
    let summary: SessionSummary
    let onHistory: () -> Void
    let onDone: () -> Void

    var body: some View {
        let s = summary
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Итог игры").font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                    if !s.childCode.isEmpty {
                        Text(s.childCode).font(Atlas.title).foregroundStyle(Atlas.vermilion)
                    }
                }
                Text(ReportText.setup(s)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft)
                HStack(spacing: 10) {
                    ReportTile(big: ReportText.percent(s.burnedShare), small: "\(s.burned ?? 0) из \(s.meteors ?? 0)",
                               label: "сбито")
                    ReportTile(big: ReportText.seconds(s.meanFirstLookSec), small: "в среднем",
                               label: s.byEye ? "первый взгляд" : "первое касание")
                    ReportTile(big: SessionHistory.number(s.slipsPerMeteor, 1), small: "на метеорит",
                               label: s.byEye ? "срывы взгляда" : "срывы пальца")
                    ReportTile(big: s.maxLevel.map(String.init) ?? "–", small: "высший", label: "уровень")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.byEye
                         ? "Первый взгляд: сколько проходит от появления метеорита до первого взгляда на него."
                         : "Первое касание: сколько проходит от появления метеорита до касания.")
                    Text(s.byEye
                         ? "Срыв: взгляд ушёл с метеорита, и тот успел остыть."
                         : "Срыв: палец ушёл с метеорита, и тот успел остыть.")
                    Text("Это результаты игры, а не медицинские показатели.")
                }
                .font(Atlas.caption)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 12) {
                Button(action: onDone) { Text("Готово") }
                    .buttonStyle(AtlasPrimaryButton())
                Button(action: onHistory) { Text("Все занятия") }
                    .buttonStyle(AtlasSecondaryButton())
            }
            .frame(width: 200)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ReportTile: View {
    let big: String
    let small: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(big).font(Atlas.display(28)).monospacedDigit().foregroundStyle(Atlas.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(small).font(Atlas.caption).foregroundStyle(Atlas.ink).lineLimit(1).minimumScaleFactor(0.8)
            Text(label).font(Atlas.caption).foregroundStyle(Atlas.inkSoft).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .atlasPlate(padding: 10)
    }
}

// MARK: - History

private struct HistoryView: View {
    @EnvironmentObject var app: AppModel
    let onDone: () -> Void
    @State private var exportURL: URL? = nil
    @State private var confirmDelete = false
    @FocusState private var editingCode: Bool

    private var plays: [SessionSummary] { SessionHistory.plays(of: app.childCode, in: app.sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Занятия").font(Atlas.display(28)).foregroundStyle(Atlas.ink)
                Spacer()
                if let url = exportURL, !app.sessions.isEmpty {
                    ShareLink(item: url) { Label("Таблица", systemImage: "square.and.arrow.up") }
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Atlas.ink)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityLabel("Поделиться таблицей всех занятий для Excel")
                }
                Button(action: onDone) { Text("Готово") }
                    .buttonStyle(AtlasPrimaryButton())
                    .frame(width: 130)
            }
            HStack(alignment: .top, spacing: 24) {
                child
                    .frame(width: 270, alignment: .leading)
                list
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onAppear { exportURL = SessionStore.exportCSV(app.sessions) }
        .onChange(of: app.sessions) { exportURL = SessionStore.exportCSV($0) }
    }

    /// The code field, what changed since the first play, and deleting.
    private var child: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Код ребёнка")
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.inkSoft)
                    .textCase(.uppercase)
                TextField("Например, К-07", text: $app.childCode)
                    .font(.system(size: 20, weight: .semibold, design: .serif))
                    .foregroundStyle(Atlas.ink)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingCode)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Atlas.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Atlas.ink.opacity(editingCode ? 0.5 : 0.2), lineWidth: 1))
                Text("Новые игры сохраняются под этим кодом. Без имени: кто под каким кодом, знает только центр.")
                    .font(Atlas.caption)
                    .foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(ReportText.progress(plays).enumerated()), id: \.offset) { item in
                    Text(item.element)
                        .font(Atlas.caption)
                        .foregroundStyle(Atlas.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
                Text("Это результаты игры, а не медицинские показатели.")
                    .font(Atlas.caption.italic())
                    .foregroundStyle(Atlas.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                if !plays.isEmpty {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Text(app.currentChildCode.isEmpty ? "Удалить все занятия" : "Удалить занятия \(app.currentChildCode)")
                    }
                    .font(Atlas.caption.weight(.semibold))
                    .foregroundStyle(Atlas.vermilion)
                    .frame(minHeight: 44)
                }
            }
        }
        .confirmationDialog(deleteQuestion, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { app.deleteSessions(of: app.childCode) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var deleteQuestion: String {
        app.currentChildCode.isEmpty ? "Удалить все занятия с телефона?" : "Удалить занятия \(app.currentChildCode) с телефона?"
    }

    @ViewBuilder private var list: some View {
        if plays.isEmpty {
            Text(app.currentChildCode.isEmpty
                 ? "Здесь появятся сыгранные игры: метеориты, когда игра закрыта, ритм, когда трек доигран."
                 : "Под кодом \(app.currentChildCode) игр пока нет. Они появятся здесь, когда ребёнок сыграет.")
                .font(Atlas.body)
                .foregroundStyle(Atlas.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(plays.reversed())) { s in row(s) }
                }
                .padding(.bottom, 12)
            }
        }
    }

    private func row(_ s: SessionSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(ReportText.when(s.start)).font(Atlas.caption.weight(.semibold)).foregroundStyle(Atlas.ink)
                Text(ReportText.setup(s)).font(Atlas.caption).foregroundStyle(Atlas.inkSoft).lineLimit(1)
                Spacer(minLength: 0)
                if app.currentChildCode.isEmpty, !s.childCode.isEmpty {
                    Text(s.childCode).font(Atlas.caption.weight(.semibold)).foregroundStyle(Atlas.vermilion)
                }
            }
            Text(ReportText.results(s))
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(Atlas.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .atlasPlate(padding: 10)
    }
}

// MARK: - Words

/// The report's numbers in words, the Russian way: decimal commas, minutes and seconds, plural forms.
enum ReportText {
    static func percent(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }

    static func seconds(_ v: Double?) -> String { v.map { SessionHistory.number($0, 1) + " с" } ?? "–" }

    static func duration(_ sec: Double) -> String {
        let total = Int(sec.rounded())
        return total < 60 ? "\(total) с" : "\(total / 60) мин \(total % 60) с"
    }

    /// 1 игра, 2 игры, 5 игр, 21 игра.
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let d = n % 10, h = n % 100
        if d == 1 && h != 11 { return one }
        if (2...4).contains(d) && !(12...14).contains(h) { return few }
        return many
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM, HH:mm"
        return f.string(from: d)
    }

    private static func level(_ s: SessionSummary) -> String {
        Atlas.levelName(RhythmLevel(rawValue: s.rhythmLevel ?? "") ?? .normal).lowercased()
    }

    /// The game, how it was played, for how long, and the calibration before it.
    static func setup(_ s: SessionSummary) -> String {
        var parts = [s.game == .meteors ? "Метеориты" : "Ритм", s.byEye ? "взглядом" : "пальцем", duration(s.durationSec)]
        if let e = s.calibrationErrorCm { parts.append("промах калибровки \(SessionHistory.number(e, 1)) см") }
        return parts.joined(separator: " · ")
    }

    /// One play's results in a line.
    static func results(_ s: SessionSummary) -> String {
        switch s.game {
        case .meteors:
            var parts = ["Сбито \(s.burned ?? 0) из \(s.meteors ?? 0) (\(percent(s.burnedShare)))"]
            if let v = s.meanFirstLookSec { parts.append("\(s.byEye ? "первый взгляд" : "первое касание") \(seconds(v))") }
            if let v = s.slipsPerMeteor { parts.append("срывов на метеорит \(SessionHistory.number(v, 1))") }
            if let l = s.maxLevel { parts.append("уровень \(l)") }
            return parts.joined(separator: " · ")
        case .rhythm:
            var parts = ["«\(s.track ?? "")», \(level(s))", "точность \(percent(s.accuracy))",
                         "сыграно \(s.hits ?? 0) из \(s.notes ?? 0)", "лучшая серия \(s.maxCombo ?? 0)"]
            if let w = s.extraWinks { parts.append("лишних подмигиваний \(w)") }
            return parts.joined(separator: " · ")
        }
    }

    /// The first and the newest of the plays that compare (SessionHistory.progress), per game.
    static func progress(_ plays: [SessionSummary]) -> [String] {
        var out: [String] = []
        let m = SessionHistory.progress(plays, game: .meteors)
        if let a = m.first, let b = m.last {
            let games = plural(m.count, "игра", "игры", "игр"), how = b.byEye ? "взглядом" : "пальцем"
            out.append("Метеориты, \(m.count) \(games) \(how), первая и последняя:")
            out.append("сбито \(percent(a.burnedShare)) и \(percent(b.burnedShare))")
            if a.meanFirstLookSec != nil, b.meanFirstLookSec != nil {
                let look = b.byEye ? "первый взгляд" : "первое касание"
                out.append("\(look) \(seconds(a.meanFirstLookSec)) и \(seconds(b.meanFirstLookSec))")
            }
        }
        let r = SessionHistory.progress(plays, game: .rhythm)
        if let a = r.first, let b = r.last {
            let games = plural(r.count, "игра", "игры", "игр")
            out.append("Ритм, \(level(b)) уровень, \(r.count) \(games), первая и последняя:")
            out.append("точность \(percent(a.accuracy)) и \(percent(b.accuracy))")
        }
        return out
    }
}
