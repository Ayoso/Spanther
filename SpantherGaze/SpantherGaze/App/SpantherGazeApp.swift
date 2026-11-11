import SwiftUI

@main
struct SpantherGazeApp: App {
    @StateObject private var app = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.status)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    app.startTracking()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
        .onChange(of: scenePhase) { phase in app.scenePhaseChanged(active: phase == .active) }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            background
            switch app.route {
            case .menu: MenuView()
            case .calibration: CalibrationView(kind: .calibration)
            case .check: CalibrationView(kind: .check)
            case .result: ResultView()
            case .game: GameView()
            case .winkTest: WinkTestView()
            case .rhythm: RhythmView()
            case .pursuit: PursuitView()
            }
            if app.showDebug { DebugOverlay().allowsHitTesting(false) }
        }
        // Ink on paper everywhere but the wink test, which keeps the old dark look.
        .preferredColorScheme(app.route == .winkTest ? .dark : .light)
    }

    /// Paper with the living garden behind the menu, the meteors and the calibration result; plain paper where
    /// the eyes must not wander (calibration, check) or where the screen draws its own garden (rhythm).
    @ViewBuilder private var background: some View {
        switch app.route {
        case .winkTest:
            Palette.space.ignoresSafeArea()
        case .calibration, .check, .rhythm, .pursuit:
            Atlas.paper.ignoresSafeArea()
        case .menu, .result, .game:
            ZStack {
                Atlas.paper
                LivingBackground(growFrom: app.launchTime)
            }
            .ignoresSafeArea()
        }
    }
}

/// The old dark palette, still used by the wink test and the debug overlay.
enum Palette {
    static let space = Color(red: 0.027, green: 0.043, blue: 0.11)
    static let panel = Color(red: 0.067, green: 0.10, blue: 0.23)
    static let gaze = Color(red: 0.44, green: 0.94, blue: 0.88)
    static let fire = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let dim = Color(red: 0.60, green: 0.64, blue: 0.78)
    static let hot = Color(red: 1.0, green: 0.35, blue: 0.21)
}
