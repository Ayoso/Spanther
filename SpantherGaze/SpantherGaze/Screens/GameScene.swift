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
    /// A quiet line under the top row («На красный знак не смотрим»); it fades in and out, nothing flashes.
    @Published var notice: String?
    /// Red signs that have left the play, and how many of them the player looked at. Shown on the pause plate.
    @Published var decoys = 0
    @Published var decoyErrors = 0
}

/// Draws GameModel in the atlas look: ink on paper, over the living garden (the scene is transparent and
/// GameView puts it on top of RootView's background). No aim is drawn, as in the rhythm mode: the meteor being
/// looked at gets a warm light under it and its dial fills. Model space is screen pt with y down; SpriteKit is
/// y up, so `sk(_:)` flips.
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
    /// «Мелкие цели»: the scale of the meteors, the red signs and their hit zones, and the smallest zone it may
    /// give (screen pt). From AppModel.targetScale and zoneFloorPt.
    var targetScale = 1.0
    var zoneFloorPt = 0.0
    /// The play has red signs to pass by.
    var decoysOn = false
    /// Eye mode: the gaze point is the one kept from before a blink (AppModel.gazeHeld).
    var gazeHeld: () -> Bool = { false }
    /// A red sign left the play (looked at or passed by), with where it was (screen pt).
    var onDecoy: ((DecoyRecord, Vec2) -> Void)?
    let hud = GameHUD()
    var paused_ = false
    /// Draw the aim (debugging only): a cursor a little off where the player looks pulls the eyes after it.
    var showAim = false

    private(set) var model: GameModel?
    private let world = SKNode()
    private var rocks: [Int: RockNode] = [:]
    private var signs: [Int: DecoyNode] = [:]
    /// Red signs sent in so far: the first one comes with a line that says what to do.
    private var signsSeen = 0
    private let reticle = SKShapeNode(circleOfRadius: 14)
    private static let reticleColor = Atlas.UI.ink.withAlphaComponent(0.7)
    private static let reticleStarvedColor = Atlas.UI.vermilion
    private var reticleStarved = false
    private var touchPoint: Vec2?
    private var lastTime: TimeInterval = 0
    private let boomHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let hitHaptic = UINotificationFeedbackGenerator()
    private var tapBurst = BurstCounter(count: 3, windowSec: 2)

    #if DEBUG
    /// Bot for the Simulator smoke test (see AppModel.autoplay).
    var autoplay = false
    /// The bot leaves for the menu after this many seconds of play, so the run also shows the summary. Nil: stays.
    var botQuitAfter: Double?
    var botQuit: (() -> Void)?
    private var botDrySince: Double?
    private var botNextPress = 0.0
    private var botBlinks = 0
    #endif

    override func didMove(to view: SKView) {
        // The paper and the garden behind are SwiftUI's (RootView); the scene draws only the game over them.
        backgroundColor = .clear
        view.allowsTransparency = true
        // SpriteView may present the scene again when SwiftUI rebuilds the view; keep the running game.
        guard world.parent == nil else { return }
        addChild(world)
        start()
    }

    func start() {
        world.removeAllChildren()
        rocks.removeAll()
        signs.removeAll()
        signsSeen = 0
        let m = GameModel(config: config, screen: Vec2(size.width, size.height), marginPt: marginPt,
                          targetScale: targetScale, zoneFloorPt: zoneFloorPt, decoys: decoysOn)
        model = m
        // Earth: only the cap that shows above the bottom edge, engraved like a globe on an old chart. In landscape
        // the whole circle would be about 3,100 pt across.
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
        earth.fillColor = Atlas.UI.paperShade
        earth.strokeColor = Atlas.UI.ink.withAlphaComponent(0.75)
        earth.lineWidth = 1.5
        earth.name = "earth"
        world.addChild(earth)
        // Parallels under the surface and short meridian ticks, in fine ink.
        for depth in [14.0, 32.0] {
            let line = CGMutablePath()
            for i in 0...steps {
                let x = -20 + (Double(size.width) + 40) * Double(i) / Double(steps)
                let p = sk(Vec2(x, m.earthSurfaceY(atX: x) + depth))
                if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
            }
            let n = SKShapeNode(path: line)
            n.strokeColor = Atlas.UI.ink.withAlphaComponent(depth < 20 ? 0.22 : 0.14)
            n.lineWidth = 0.8
            earth.addChild(n)
        }
        let ticks = CGMutablePath()
        for i in 0..<14 {
            let x = Double(size.width) * (Double(i) + 0.5) / 14
            ticks.move(to: sk(Vec2(x, m.earthSurfaceY(atX: x) + 3)))
            ticks.addLine(to: sk(Vec2(x, m.earthSurfaceY(atX: x) + 10)))
        }
        let tickNode = SKShapeNode(path: ticks)
        tickNode.strokeColor = Atlas.UI.ink.withAlphaComponent(0.3)
        tickNode.lineWidth = 0.8
        earth.addChild(tickNode)
        for i in 0..<7 {  // continents along the arc, tilted with it
            let x = Double(size.width) * (Double(i) + 0.5) / 7
            let slope = (x - m.earthCenter.x) / max(1, (m.earthRadius * m.earthRadius - pow(x - m.earthCenter.x, 2)).squareRoot())
            let c = SKShapeNode(ellipseOf: CGSize(width: 50 + 30 * Double(i % 3), height: 12))
            c.fillColor = UIColor(red: 0.235, green: 0.478, blue: 0.420, alpha: 0.28)
            c.strokeColor = Atlas.UI.ink.withAlphaComponent(0.35)
            c.lineWidth = 0.8
            c.position = sk(Vec2(x + 12 * Double(i % 2), m.earthSurfaceY(atX: x) + 20 + 6 * Double(i % 2)))
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
        wave.strokeColor = Atlas.UI.ink.withAlphaComponent(0.6)
        wave.lineWidth = 2
        wave.zPosition = 60
        world.addChild(wave)
        wave.run(.sequence([.group([.scale(to: 9, duration: 0.6), .fadeOut(withDuration: 0.6)]), .removeFromParent()]))
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
        let held = botGaze == nil && !useTouch && gazeHeld()

        for e in m.update(dt: dt, gaze: gaze, held: held) {
            switch e {
            case .spawned(let a):
                let n = RockNode(a, scale: CGFloat(m.targetScale))
                rocks[a.id] = n
                world.addChild(n)
            case .decoySpawned(let s):
                let n = DecoyNode(s)
                n.position = sk(s.position)
                signs[s.id] = n
                world.addChild(n)
                signsSeen += 1
                if signsSeen == 1 { notice(useTouch ? "Красный знак не трогаем" : "На красный знак не смотрим", seconds: 4) }
            case .decoyLooked(let s, let rec):
                // An error, said quietly: the sign fades and a line reminds the rule. No flash, no shake, no buzz.
                signs.removeValue(forKey: s.id)?.leave(seconds: 0.7)
                hud.decoys += 1
                hud.decoyErrors += 1
                notice(useTouch ? "Красный знак не трогаем" : "На красный знак не смотрим", seconds: 2.5)
                onDecoy?(rec, s.position)
            case .decoyPassed(let s, let rec):
                signs.removeValue(forKey: s.id)?.leave(seconds: 0.4)
                hud.decoys += 1
                onDecoy?(rec, s.position)
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
        for s in m.decoys { signs[s.id]?.position = sk(s.position) }
        if !useTouch, botGaze == nil { onLookedAt?(m.asteroids.first { $0.isTargeted }?.position) }
        if hud.needsReload != m.needsReload { hud.needsReload = m.needsReload }

        if showAim, case .point(let p) = gaze {
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
        if let after = botQuitAfter, m.time > after {
            botQuitAfter = nil
            botQuit?()
        }
        // Every third red sign catches the bot's eye once it is well into view, so a run has both kinds: signs
        // looked at and signs passed by.
        if signsSeen % 3 == 2, let s = m.decoys.first, s.position.y > m.screen.y * 0.2, s.position.x > 0, s.position.x < m.screen.x {
            touchPoint = useTouch ? s.position : nil
            return .point(s.position)
        }
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

    /// How many quiet lines have been shown: a line is taken away only if no newer one has replaced it.
    private var noticeCount = 0

    /// Shows the quiet line under the top row for a few seconds (the HUD fades it in and out).
    private func notice(_ s: String, seconds: Double) {
        noticeCount += 1
        let mine = noticeCount
        hud.notice = s
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.noticeCount == mine { self?.hud.notice = nil }
        }
    }

    /// A burnt meteor bursts like a star on the chart: an ink ring and a vermilion one, and small four-pointed
    /// stars thrown out.
    private func explode(at p: CGPoint, radius: CGFloat) {
        boomHaptic.impactOccurred()
        for (k, color) in [Atlas.UI.vermilion, Atlas.UI.ink].enumerated() {
            let ring = SKShapeNode(circleOfRadius: radius)
            ring.position = p
            ring.strokeColor = color
            ring.lineWidth = k == 0 ? 2.5 : 1
            world.addChild(ring)
            let grow: CGFloat = k == 0 ? 2.2 : 2.8
            ring.run(.sequence([.group([.scale(to: grow, duration: 0.5), .fadeOut(withDuration: 0.5)]), .removeFromParent()]))
        }
        for i in 0..<(10 + Int(radius / 5)) {
            let q = SKShapeNode(path: Self.starPath(CGFloat.random(in: 2.5...max(3, radius * 0.16))))
            q.position = p
            q.fillColor = i % 3 == 0 ? Atlas.UI.vermilion : Atlas.UI.ink
            q.strokeColor = .clear
            world.addChild(q)
            let a = CGFloat.random(in: 0...(2 * .pi)), d = CGFloat.random(in: 0.7...2.2) * radius
            q.run(.sequence([.group([.moveBy(x: cos(a) * d, y: sin(a) * d, duration: 0.7),
                                     .rotate(byAngle: CGFloat.random(in: -2...2), duration: 0.7),
                                     .fadeOut(withDuration: 0.7)]), .removeFromParent()]))
        }
    }

    /// The atlas's four-pointed star (Atlas.star) as a CGPath around the origin.
    static func starPath(_ r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        func pt(_ radius: CGFloat, _ angle: Double) -> CGPoint {
            let dx: Double = cos(angle), dy: Double = sin(angle)
            return CGPoint(x: CGFloat(dx) * radius, y: CGFloat(dy) * radius)
        }
        path.move(to: pt(r, Double.pi / 2))
        for k in 0..<4 {
            let tip = pt(r, Double.pi / 2 + Double(k + 1) * Double.pi / 2)
            let ctrl = pt(r * 0.2, Double.pi / 2 + Double(k) * Double.pi / 2 + Double.pi / 4)
            path.addQuadCurve(to: tip, control: ctrl)
        }
        path.closeSubpath()
        return path
    }

    private func impact(at p: CGPoint, radius: CGFloat) {
        hitHaptic.notificationOccurred(.error)
        let flash = SKShapeNode(circleOfRadius: radius * 1.4)
        flash.position = p
        flash.fillColor = Atlas.UI.vermilion.withAlphaComponent(0.45)
        flash.strokeColor = Atlas.UI.vermilion
        flash.lineWidth = 1.5
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

/// One meteor in the atlas look: an ink-outlined rock with engraved hatching that warms to vermilion as it burns,
/// a dial round it like a rhythm note's (a faint full circle, the ink arc of the burn, a vermilion mark at the
/// top), and a warm light under it while it is looked at, which stands in for the hidden aim. Cracks of paper show
/// from half way. Looked at without energy: a dashed vermilion ring that says "reload first".
final class RockNode: SKNode {
    private let body: SKShapeNode
    private let hatch = SKShapeNode()
    private let ring = SKShapeNode()
    private let track: SKShapeNode
    private let starvedRing: SKShapeNode
    private let mark = SKShapeNode()
    private let lamp: SKShapeNode
    private let cracks = SKShapeNode()
    private let radius: CGFloat
    /// How far the dial sits outside the rock (pt).
    private let dialGap: CGFloat

    private static let paperRGB: (CGFloat, CGFloat, CGFloat) = (0.906, 0.875, 0.820)
    private static let hotRGB: (CGFloat, CGFloat, CGFloat) = (0.761, 0.271, 0.176)

    /// `scale`: «Мелкие цели». The rock's radius already has it; the dial, the mark and the light round it shrink
    /// by it too, so the whole meteor is that much smaller, not only its body.
    init(_ a: Asteroid, scale k: CGFloat = 1) {
        let radius = CGFloat(a.radius)
        self.radius = radius
        dialGap = 10 * k
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
        body.strokeColor = Atlas.UI.ink.withAlphaComponent(0.9)
        body.lineWidth = 1.6
        let dial = radius + 10 * k
        track = SKShapeNode(circleOfRadius: dial)
        starvedRing = SKShapeNode(path: CGPath(ellipseIn: CGRect(x: -dial, y: -dial, width: 2 * dial, height: 2 * dial),
                                               transform: nil)
            .copy(dashingWithPhase: 0, lengths: [5, 5]))
        lamp = SKShapeNode(circleOfRadius: radius + 18 * k)
        super.init()
        lamp.fillColor = Atlas.UI.vermilion.withAlphaComponent(0.13)
        lamp.strokeColor = .clear
        lamp.isHidden = true
        track.strokeColor = Atlas.UI.ink.withAlphaComponent(0.14)
        track.lineWidth = 1.5
        track.isHidden = true
        starvedRing.strokeColor = Atlas.UI.vermilion
        starvedRing.lineWidth = 2
        starvedRing.isHidden = true
        ring.strokeColor = Atlas.UI.ink
        ring.lineWidth = 2.5
        ring.lineCap = .round
        let mp = CGMutablePath()
        mp.move(to: CGPoint(x: 0, y: radius + 4 * k))
        mp.addLine(to: CGPoint(x: 0, y: radius + 16 * k))
        mark.path = mp
        mark.strokeColor = Atlas.UI.vermilion
        mark.lineWidth = 3
        mark.lineCap = .round
        mark.isHidden = true
        // Engraved hatching: short parallel strokes on one side of the rock.
        let hp = CGMutablePath()
        for i in 0..<4 {
            let x = -radius * 0.5 + CGFloat(i) * radius * 0.22
            hp.move(to: CGPoint(x: x, y: -radius * 0.45))
            hp.addLine(to: CGPoint(x: x + radius * 0.18, y: -radius * 0.1))
        }
        hatch.path = hp
        hatch.strokeColor = Atlas.UI.ink.withAlphaComponent(0.35)
        hatch.lineWidth = 0.8
        body.addChild(hatch)
        let cp = CGMutablePath()
        for i in 0..<4 {
            let ang = CGFloat(i) * 1.6 + 0.4
            cp.move(to: .zero)
            cp.addLine(to: CGPoint(x: cos(ang) * radius * 0.5, y: sin(ang) * radius * 0.5))
            cp.addLine(to: CGPoint(x: cos(ang + 0.4) * radius * 0.85, y: sin(ang + 0.4) * radius * 0.85))
        }
        cracks.path = cp
        cracks.strokeColor = Atlas.UI.paper
        cracks.lineWidth = max(1.5, radius * 0.05)
        cracks.alpha = 0
        body.addChild(cracks)
        addChild(lamp)
        addChild(body)
        addChild(track)
        addChild(starvedRing)
        addChild(ring)
        addChild(mark)
        zPosition = 10
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var lastHeat: CGFloat = -1

    func sync(_ a: Asteroid, at p: CGPoint) {
        position = p
        starvedRing.isHidden = !a.isStarved
        body.zRotation = CGFloat(a.rotation)
        let t = CGFloat(min(1, a.progress))
        // The fill warms from the paper's shade to vermilion; recoloured only when it changes visibly.
        if abs(t - lastHeat) > 0.02 {
            lastHeat = t
            let (r0, g0, b0) = Self.paperRGB, (r1, g1, b1) = Self.hotRGB
            body.fillColor = UIColor(red: r0 + (r1 - r0) * t, green: g0 + (g1 - g0) * t, blue: b0 + (b1 - b0) * t, alpha: 1)
        }
        cracks.alpha = t < 0.5 ? 0 : (t - 0.5) * 2
        let looked = a.isTargeted || t > 0
        lamp.isHidden = !a.isTargeted
        track.isHidden = !looked
        mark.isHidden = !looked
        if t > 0 {
            // SpriteKit is y up: from 12 o'clock clockwise as the player sees it.
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: radius + dialGap, startAngle: .pi / 2, endAngle: .pi / 2 - t * 2 * .pi, clockwise: true)
            ring.path = path
            if t > 0.3 { body.position = CGPoint(x: CGFloat.random(in: -1...1) * t * 2, y: CGFloat.random(in: -1...1) * t * 2) }
        } else {
            ring.path = nil
            body.position = .zero
        }
    }
}

/// A red sign in the atlas look: a flat vermilion disc with a bar of paper across it, the "no entry" of road signs,
/// so it reads by its shape as well as by its colour. It drifts in like a meteor and is meant to be passed by.
/// Nothing on it moves or blinks: it appears and leaves by fading.
final class DecoyNode: SKNode {
    init(_ s: Decoy) {
        let r = CGFloat(s.radius)
        let disc = SKShapeNode(circleOfRadius: r)
        disc.fillColor = Atlas.UI.vermilion
        disc.strokeColor = Atlas.UI.ink.withAlphaComponent(0.55)
        disc.lineWidth = 1.2
        let bar = SKShapeNode(rectOf: CGSize(width: r * 1.15, height: r * 0.32), cornerRadius: r * 0.08)
        bar.fillColor = Atlas.UI.paper
        bar.strokeColor = .clear
        super.init()
        addChild(disc)
        addChild(bar)
        zPosition = 9
        alpha = 0
        run(.fadeIn(withDuration: 0.5))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Fades away where it is.
    func leave(seconds: Double) {
        removeAllActions()
        run(.sequence([.group([.fadeOut(withDuration: seconds), .scale(to: 0.85, duration: seconds)]), .removeFromParent()]))
    }
}
