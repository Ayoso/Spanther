import SpriteKit
import UIKit

/// Score, shields and level for the SwiftUI HUD. Updated on game events, not every frame.
final class GameHUD: ObservableObject {
    @Published var score = 0
    @Published var shields = 5
    @Published var level = 1
    @Published var lookBack = false
    @Published var banner: String?
}

/// Draws GameModel. Model space is screen pt with y down; SpriteKit is y up, so `sk(_:)` flips.
final class GameScene: SKScene {
    var gazeSource: () -> GazeInput = { .notLooking }
    var useTouch = false
    var marginPt = 30.0
    var config: BalanceConfig!
    var onRecord: ((AsteroidRecord) -> Void)?
    let hud = GameHUD()
    var paused_ = false

    private(set) var model: GameModel?
    private let world = SKNode()
    private var rocks: [Int: RockNode] = [:]
    private let reticle = SKShapeNode(circleOfRadius: 14)
    private var touchPoint: Vec2?
    private var lastTime: TimeInterval = 0
    private let boomHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let hitHaptic = UINotificationFeedbackGenerator()

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
        let earth = SKShapeNode(circleOfRadius: m.earthRadius)
        earth.position = sk(m.earthCenter)
        earth.fillColor = UIColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1)
        earth.strokeColor = UIColor(red: 0.55, green: 0.75, blue: 1, alpha: 0.6)
        earth.lineWidth = 10
        earth.glowWidth = 14
        earth.name = "earth"
        world.addChild(earth)
        for i in 0..<9 {  // continents
            let c = SKShapeNode(ellipseOf: CGSize(width: m.earthRadius * (0.25 + 0.05 * Double(i % 3)), height: m.earthRadius * 0.12))
            c.fillColor = UIColor(red: 0.25, green: 0.68, blue: 0.42, alpha: 1)
            c.strokeColor = .clear
            let a = Double.pi / 2 + (Double(i) - 4) * 0.22
            c.position = CGPoint(x: cos(a) * m.earthRadius * 0.82, y: sin(a) * m.earthRadius * 0.82)
            c.zRotation = CGFloat(a - .pi / 2)
            earth.addChild(c)
        }
        reticle.strokeColor = UIColor(red: 0.44, green: 0.94, blue: 0.88, alpha: 0.7)
        reticle.lineWidth = 2
        reticle.zPosition = 50
        reticle.isHidden = true
        world.addChild(reticle)
        hud.shields = m.shields; hud.level = m.level; hud.score = 0
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
        guard let m = model, !paused_ else { return }
        let gaze: GazeInput = useTouch ? (touchPoint.map { .point($0) } ?? .notLooking) : gazeSource()

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
            case .hitEarth(let a, let rec):
                impact(at: sk(a.position), radius: CGFloat(a.radius))
                rocks.removeValue(forKey: a.id)?.removeFromParent()
                hud.shields = max(0, m.shields)
                onRecord?(rec)
            case .shieldsDepleted(let lvl):
                rocks.values.forEach { $0.removeFromParent() }
                rocks.removeAll()
                hud.shields = m.shields
                flash("Щиты кончились. Уровень \(lvl) ещё раз")
            case .levelEnded(_, let ratio, let next):
                hud.level = next
                flash(String(format: "Сбито %.0f%% · Уровень %d", ratio * 100, next))
            case .pausedForFace(let on):
                hud.lookBack = on
            }
        }

        for a in m.asteroids { rocks[a.id]?.sync(a, at: sk(a.position)) }

        if case .point(let p) = gaze {
            reticle.isHidden = false
            reticle.position = sk(p)
            let r = useTouch ? 14 : max(10, marginPt * 0.5)
            reticle.setScale(r / 14)
        } else {
            reticle.isHidden = true
        }
    }

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

    func sync(_ a: Asteroid, at p: CGPoint) {
        position = p
        body.zRotation = CGFloat(a.rotation)
        let t = CGFloat(min(1, a.progress))
        body.fillColor = UIColor(red: 0.45 + 0.55 * t, green: 0.33 - 0.1 * t, blue: 0.24 - 0.12 * t, alpha: 1)
        cracks.alpha = t < 0.5 ? 0 : (t - 0.5) * 2
        track.isHidden = t <= 0
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
