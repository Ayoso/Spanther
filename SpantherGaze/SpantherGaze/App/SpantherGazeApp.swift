import SwiftUI

@main
struct SpantherGazeApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.status)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .persistentSystemOverlays(.hidden)
                .onAppear {
                    app.startTracking()
                    UIApplication.shared.isIdleTimerDisabled = true
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            Palette.space.ignoresSafeArea()
            switch app.route {
            case .menu: MenuView()
            case .calibration: CalibrationView(kind: .calibration)
            case .check: CalibrationView(kind: .check)
            case .result: ResultView()
            case .game: GameView()
            }
            if app.showDebug { DebugOverlay().allowsHitTesting(false) }
        }
    }
}

enum Palette {
    static let space = Color(red: 0.027, green: 0.043, blue: 0.11)
    static let panel = Color(red: 0.067, green: 0.10, blue: 0.23)
    static let gaze = Color(red: 0.44, green: 0.94, blue: 0.88)
    static let fire = Color(red: 1.0, green: 0.70, blue: 0.28)
    static let dim = Color(red: 0.60, green: 0.64, blue: 0.78)
}
