import SpriteKit
import UIKit

/// Score, shields and level for the SwiftUI HUD. Updated on game events, not every frame.
final class GameHUD: ObservableObject {
    @Published var score = 0
    @Published var shields = 5
    @Published var level = 1
    @Published var lookBack = false
    @Published var banner: String?
    @Published var energy = 0
    @Published var energyMax = 0
    /// Looking at a meteor the pool cannot pay for, or the pool is empty: show the reload hint.
    @Published var needsReload = false
    /// Blinks (or taps) counted toward the next reload, and how many a reload takes.
    @Published var reloadProgress = 0
    @Published var reloadNeeded = 3
    /// Bumped on every reload so the HUD can pulse.
    @Published var reloadCount = 0
}

/// Draws GameModel. Model space is screen pt with y down; SpriteKit is y up, so `sk(_:)` flips.
final class GameScene: SKScene {
    var gazeSource: () -> GazeInput = { .notLooking }
    var useTouch = false
    var marginPt = 30.0
    var config: BalanceConfig!
    var onRecord: ((AsteroidRecord) -> Void)?
    /// Returns true once per finished 3-blink reload (AppModel.consumeBlinkReload).
    var blinkReload: () -> Bool = { false }
    /// Blinks counted toward the next reload, for the HUD.
    var pendingBlinks: () -> Int = { 0 }
    /// CSV event rows: kind ("energy" per kill, "reload", "level" for a new level, "restart" when shields ran
    /// out), the energy left after it, and the level it happened on.
    var onGameEvent: ((_ kind: String, _ energy: Int, _ level: Int) -> Void)?
    /// Eye mode: the centre of the meteor taken as looked at on this frame (screen pt), or nil. The aim adapter
    /// learns from it.
    var onLookedAt: ((Vec2?) -> Void)?
    let hud = GameHUD()
    var paused_ = false

    private(set) var model: GameModel?
    private let world = SKNode()
    private var rocks: [Int: RockNode] = [:]
    private let reticle = SKShapeNode(circleOfRadius: 14)
    private static let reticleColor = UIColor(red: 0.44, green: 0.94, blue: 0.88, alpha: 0.7)
    private static let reticleStarvedColor = UIColor(red: 1, green: 0.35, blue: 0.21, alpha: 0.85)
    private var reticleStarved = false
    private var touchPoint: Vec2?
    private var lastTime: TimeInterval = 0
    private let boomHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let hitHaptic = UINotificationFeedbackGenerator()
    private var tapBurst = BurstCounter(count: 3, windowSec: 2)

    #if DEBUG
    /// Bot for the Simulator smoke test (see AppModel.autoplay).
    var autoplay = false
    private var botDrySince: Double?
    private var botNextPress = 0.0
    private var botBlinks = 0
    #endif

    override func didMove(to view: SKView) {
        backgroundColor = UIColor(red: 0.027, green: 0.043, blue: 0.11, alpha: 1)
        // SpriteView may present the scene again when SwiftUI rebuilds the view; keep the running game.
        guard world.parent == nil else { return }
        addChild(world)
        start()
    }

    func start() {
        world.removeAllChildren()
        rocks.removeAll()
        let m = GameModel(config: config, screen: Vec2(size.width, size.height), marginPt: marginPt)
        model = m
        addStars()
        // Earth: only the cap that shows above the bottom edge. In landscape the whole circle would be about
        // 3,100 pt across.
        let cap = CGMutablePath()
        let steps = 64
        for i in 0...steps {
            let x = -20 + (Double(size.width) + 40) * Double(i) / Double(steps)
            let p = sk(Vec2(x, m.earthSurfaceY(atX: x)))
            if i == 0 { cap.move(to: p) } else { cap.addLine(to: p) }
        }
        cap.addLine(to: CGPoint(x: size.width + 20, y: -20))
        cap.addLine(to: CGPoint(x: -20, y: -20))
        cap.closeSubpath()
        let earth = SKShapeNode(path: cap)
        earth.fillColor = UIColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1)
        earth.strokeColor = UIColor(red: 0.55, green: 0.75, blue: 1, alpha: 0.6)
        earth.lineWidth = 8
        earth.glowWidth = 6
        earth.name = "earth"
        world.addChild(earth)
        for i in 0..<7 {  // continents along the arc, tilted with it
            let x = Double(size.width) * (Double(i) + 0.5) / 7
            let slope = (x - m.earthCenter.x) / max(1, (m.earthRadius * m.earthRadius - pow(x - m.earthCenter.x, 2)).squareRoot())
            let c = SKShapeNode(ellipseOf: CGSize(width: 50 + 30 * Double(i % 3), height: 14))
            c.fillColor = UIColor(red: 0.25, green: 0.68, blue: 0.42, alpha: 1)
            c.strokeColor = .clear
            c.position = sk(Vec2(x + 12 * Double(i % 2), m.earthSurfaceY(atX: x) + 16 + 6 * Double(i % 2)))
            c.zRotation = CGFloat(-atan(slope))
            earth.addChild(c)
        }
        reticle.strokeColor = Self.reticleColor
        reticle.lineWidth = 2
        reticle.zPosition = 50
        reticle.isHidden = true
        world.addChild(reticle)
        hud.shields = m.shields; hud.level = m.level; hud.score = 0
        hud.energy = m.energy; hud.energyMax = m.energyMax
        if let e = config.energy {
            tapBurst = BurstCounter(count: e.touchReloadTaps, windowSec: e.reloadWindowSec)
            hud.reloadNeeded = useTouch ? e.touchReloadTaps : e.reloadBlinks
        }
        _ = blinkReload()   // drop a reload blinked on the menu
    }

    /// Touch mode: one tap on the energy bar. Three inside the window reload.
    func reloadTap() {
        guard useTouch, let m = model else { return }
        let now = CACurrentMediaTime()
        if tapBurst.press(at: now) { doReload(m) }
        hud.reloadProgress = tapBurst.pending(at: now)
    }

    private func doReload(_ m: GameModel) {
        guard m.reload() else { return }
        hitHaptic.notificationOccurred(.success)
        hud.energy = m.energy
        hud.reloadCount += 1
        onGameEvent?("reload", m.energy, m.level)
        let wave = SKShapeNode(circleOfRadius: 30)
        wave.position = CGPoint(x: size.width / 2, y: size.height - 120)
        wave.strokeColor = UIColor(red: 0.44, green: 0.94, blue: 0.88, alpha: 1)
        wave.lineWidth = 6
        wave.glowWidth = 8
        wave.zPosition = 60
        world.addChild(wave)
        wave.run(.sequence([.group([.scale(to: 9, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
    }

    private func addStars() {
        for _ in 0..<Int(size.width * size.height / 2600) {
            let s = SKShapeNode(circleOfRadius: CGFloat.random(in: 0.4...1.3))
            s.fillColor = .white
            s.strokeColor = .clear
            s.alpha = CGFloat.random(in: 0.3...0.9)
            s.position = CGPoint(x: CGFloat.random(in: 0...size.width), y: CGFloat.random(in: 0...size.height))
            world.addChild(s)
        }
    }

    private func sk(_ p: Vec2) -> CGPoint { CGPoint(x: p.x, y: size.height - p.y) }

    override func update(_ currentTime: TimeInterval) {
        let dt = lastTime == 0 ? 0 : currentTime - lastTime
        lastTime = currentTime
        let reloadBlinked = blinkReload()
        guard let m = model, !paused_ else { return }
        var botGaze: GazeInput?
        #if DEBUG
        if autoplay { botGaze = botStep(m) }
        #endif
        if botGaze == nil {
            if !useTouch {
                if reloadBlinked { doReload(m) }
                let pb = pendingBlinks()
                if hud.reloadProgress != pb { hud.reloadProgress = pb }
            } else if hud.reloadProgress > 0, tapBurst.pending(at: CACurrentMediaTime()) == 0 {
                hud.reloadProgress = 0
            }
        }
        let gaze: GazeInput = botGaze ?? (useTouch ? (touchPoint.map { .point($0) } ?? .notLooking) : gazeSource())

        for e in m.update(dt: dt, gaze: gaze) {
            switch e {
            case .spawned(let a):
                let n = RockNode(a)
                rocks[a.id] = n
                world.addChild(n)
            case .destroyed(let a, let rec):
                explode(at: sk(a.position), radius: CGFloat(a.radius))
                rocks.removeValue(forKey: a.id)?.removeFromParent()
                hud.score = m.score
                onRecord?(rec)
            case .energySpent(_, let left):
                hud.energy = left
                onGameEvent?("energy", left, m.level)
            case .starved:
                break
            case .hitEarth(let a, let rec):
                impact(at: sk(a.position), radius: CGFloat(a.radius))
                rocks.removeValue(forKey: a.id)?.removeFromParent()
                hud.shields = max(0, m.shields)
                onRecord?(rec)
            case .shieldsDepleted(let lvl):
                rocks.values.forEach { $0.removeFromParent() }
                rocks.removeAll()
                hud.shields = m.shields
                hud.energy = m.energy
                onGameEvent?("restart", m.energy, lvl)
                flash("Щиты кончились. Уровень \(lvl) ещё раз")
            case .levelEnded(_, let ratio, let next):
                hud.level = next
                hud.energy = m.energy
                onGameEvent?("level", m.energy, next)
                flash(String(format: "Сбито %.0f%% · Уровень %d", ratio * 100, next))
            case .pausedForFace(let on):
                hud.lookBack = on
            }
        }

        for a in m.asteroids { rocks[a.id]?.sync(a, at: sk(a.position)) }
        if !useTouch, botGaze == nil { onLookedAt?(m.asteroids.first { $0.isTargeted }?.position) }
        if hud.needsReload != m.needsReload { hud.needsReload = m.needsReload }

        if case .point(let p) = gaze {
            reticle.isHidden = false
            reticle.position = sk(p)
            let r = useTouch ? 14 : max(10, marginPt * 0.5)
            reticle.setScale(r / 14)
            // In eye mode the aim is about as big as the meteor's ring and sits right on it, so it would hide
            // the red "no energy" ring. The aim turns red as well while it rests on a meteor the pool can't pay for.
            if reticleStarved != m.starved {
                reticleStarved = m.starved
                reticle.strokeColor = m.starved ? Self.reticleStarvedColor : Self.reticleColor
            }
        } else {
            reticle.isHidden = true
        }
    }

    #if DEBUG
    /// Looks at the lowest meteor, even one it cannot afford (so the red ring and hint show). Two seconds
    /// after running dry it "blinks" (eyes) or taps the energy bar (touch) every 0.4 s until it reloads.
    private func botStep(_ m: GameModel) -> GazeInput {
        // Like a player: reacts once a meteor is well into view (a third of the way down), then follows the lowest.
        let target = m.asteroids.filter { $0.position.y > m.screen.y * 0.33 }.max { $0.position.y < $1.position.y }
        if m.needsReload {
            if botDrySince == nil { botDrySince = m.time; botBlinks = 0 }
            if m.time - (botDrySince ?? m.time) > 2, m.time >= botNextPress {
                botNextPress = m.time + 0.4
                if useTouch {
                    reloadTap()
                } else {
                    botBlinks += 1
                    hud.reloadProgress = botBlinks
                    if botBlinks >= hud.reloadNeeded { botBlinks = 0; hud.reloadProgress = 0; doReload(m) }
                }
            }
        } else {
            botDrySince = nil
            botBlinks = 0
            if hud.reloadProgress != 0 { hud.reloadProgress = 0 }
        }
        touchPoint = useTouch ? target?.position : nil
        return target.map { .point($0.position) } ?? .notLooking
    }
    #endif

    private func flash(_ s: String) {
        hud.banner = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            if self?.hud.banner == s { self?.hud.banner = nil }
        }
    }

    private func explode(at p: CGPoint, radius: CGFloat) {
        boomHaptic.impactOccurred()
        let ring = SKShapeNode(circleOfRadius: radius)
        ring.position = p
        ring.strokeColor = UIColor(red: 1, green: 0.8, blue: 0.5, alpha: 1)
        ring.lineWidth = 4
        world.addChild(ring)
        ring.run(.sequence([.group([.scale(to: 2.6, duration: 0.45), .fadeOut(withDuration: 0.45)]), .removeFromParent()]))
        for _ in 0..<(20 + Int(radius / 3)) {
            let q = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.5...max(2, radius * 0.1)))
            q.position = p
            q.fillColor = Bool.random() ? UIColor(red: 1, green: 0.75, blue: 0.35, alpha: 1) : UIColor(red: 0.55, green: 0.43, blue: 0.35, alpha: 1)
            q.strokeColor = .clear
            world.addChild(q)
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 0.6...2.2) * radius
            q.run(.sequence([.group([.moveBy(x: cos(a) * d, y: sin(a) * d, duration: 0.7), .fadeOut(withDuration: 0.7)]), .removeFromParent()]))
        }
    }

    private func impact(at p: CGPoint, radius: CGFloat) {
        hitHaptic.notificationOccurred(.error)
        let flash = SKShapeNode(circleOfRadius: radius * 1.4)
        flash.position = p
        flash.fillColor = UIColor(red: 1, green: 0.35, blue: 0.2, alpha: 0.8)
        flash.strokeColor = .clear
        world.addChild(flash)
        flash.run(.sequence([.group([.scale(to: 2, duration: 0.5), .fadeOut(withDuration: 0.5)]), .removeFromParent()]))
        let s: CGFloat = 10
        world.run(.sequence([.moveBy(x: s, y: 0, duration: 0.04), .moveBy(x: -2 * s, y: 0, duration: 0.08), .moveBy(x: s, y: 0, duration: 0.04)]))
    }

    // Touch fallback: a finger on a meteor counts as looking at it.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { setTouch(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { setTouch(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { touchPoint = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { touchPoint = nil }
    private func setTouch(_ touches: Set<UITouch>) {
        guard let t = touches.first, let v = view else { return }
        let p = t.location(in: v)   // UIKit: top-left origin, y down = model space
        touchPoint = Vec2(p.x, p.y)
    }
}

/// One asteroid: rocky body that heats up, a progress ring, cracks from 50%.
final class RockNode: SKNode {
    private let body: SKShapeNode
    private let ring = SKShapeNode()
    private let track: SKShapeNode
    private let cracks = SKShapeNode()
    private let radius: CGFloat

    init(_ a: Asteroid) {
        let radius = CGFloat(a.radius)
        self.radius = radius
        let path = CGMutablePath()
        let n = 11
        for i in 0..<n {
            let ang = CGFloat(i) / CGFloat(n) * 2 * .pi
            let k = CGFloat.random(in: 0.84...1.04)
            let pt = CGPoint(x: cos(ang) * radius * k, y: sin(ang) * radius * k)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        body = SKShapeNode(path: path)
        body.strokeColor = .clear
        track = SKShapeNode(circleOfRadius: radius + 10)
        super.init()
        track.strokeColor = UIColor(red: 0.44, green: 0.94, blue: 0.88, alpha: 0.18)
        track.lineWidth = 6
        track.isHidden = true
        ring.strokeColor = UIColor(red: 0.44, green: 0.94, blue: 0.88, alpha: 1)
        ring.lineWidth = 6
        ring.lineCap = .round
        ring.glowWidth = 3
        let cp = CGMutablePath()
        for i in 0..<4 {
            let ang = CGFloat(i) * 1.6 + 0.4
            cp.move(to: .zero)
            cp.addLine(to: CGPoint(x: cos(ang) * radius * 0.5, y: sin(ang) * radius * 0.5))
            cp.addLine(to: CGPoint(x: cos(ang + 0.4) * radius * 0.85, y: sin(ang + 0.4) * radius * 0.85))
        }
        cracks.path = cp
        cracks.strokeColor = UIColor(red: 1, green: 0.95, blue: 0.7, alpha: 1)
        cracks.lineWidth = max(1.5, radius * 0.05)
        cracks.alpha = 0
        body.addChild(cracks)
        addChild(body)
        addChild(track)
        addChild(ring)
        zPosition = 10
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private static let gazeColor = UIColor(red: 0.44, green: 0.94, blue: 0.88, alpha: 0.18)
    private static let starvedColor = UIColor(red: 1, green: 0.35, blue: 0.21, alpha: 0.75)

    private var showsStarved = false

    func sync(_ a: Asteroid, at p: CGPoint) {
        position = p
        // Looked at without enough energy: a red ring that says "reload first".
        if a.isStarved != showsStarved {
            showsStarved = a.isStarved
            track.strokeColor = a.isStarved ? Self.starvedColor : Self.gazeColor
        }
        body.zRotation = CGFloat(a.rotation)
        let t = CGFloat(min(1, a.progress))
        body.fillColor = UIColor(red: 0.45 + 0.55 * t, green: 0.33 - 0.1 * t, blue: 0.24 - 0.12 * t, alpha: 1)
        cracks.alpha = t < 0.5 ? 0 : (t - 0.5) * 2
        track.isHidden = t <= 0 && !a.isStarved
        if t > 0 {
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: radius + 10, startAngle: .pi / 2, endAngle: .pi / 2 - t * 2 * .pi, clockwise: true)
            ring.path = path
            if t > 0.3 { body.position = CGPoint(x: CGFloat.random(in: -1...1) * t * 2, y: CGFloat.random(in: -1...1) * t * 2) }
        } else {
            ring.path = nil
            body.position = .zero
        }
    }
}
