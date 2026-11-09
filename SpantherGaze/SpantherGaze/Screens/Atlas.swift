import SwiftUI
import UIKit

/// The app's look: a star atlas printed on warm paper, first made for the rhythm mode and now used by every screen
/// but the wink test. Ink for everything, one vermilion for what matters now (the mark the dial hand reaches on the
/// beat, the main button, a perfect hit, the meteor being burned). Moss and amber belong to the living garden behind
/// the screens (leaves, light pulses, fireflies), never to something the player has to act on. Serif (New York) for
/// titles, numbers and judgements, SF Pro for the small print. Spacing on a 4/8 pt grid.
/// Light on purpose: the bright page also lights the player's face for the camera, which night vision relies on.
enum Atlas {
    static let paper = Color(red: 0.949, green: 0.925, blue: 0.882)       // F2ECE1
    static let paperShade = Color(red: 0.906, green: 0.875, blue: 0.820)  // E7DFD1
    static let ink = Color(red: 0.114, green: 0.141, blue: 0.220)         // 1D2438
    static let inkSoft = Color(red: 0.361, green: 0.384, blue: 0.459)     // 5C6275
    static let vermilion = Color(red: 0.761, green: 0.271, blue: 0.176)   // C2452D
    static let missGrey = Color(red: 0.639, green: 0.612, blue: 0.565)    // A39C90
    static let onAccent = Color(red: 1.0, green: 0.992, blue: 0.973)      // FFFDF8
    /// The garden's life: leaves and the light that runs along the lianas.
    static let moss = Color(red: 0.235, green: 0.478, blue: 0.420)        // 3C7A6B
    /// Fireflies, flowers and the other distractions.
    static let amber = Color(red: 0.851, green: 0.588, blue: 0.161)       // D99629

    /// The same colours for SpriteKit.
    enum UI {
        static let paper = UIColor(red: 0.949, green: 0.925, blue: 0.882, alpha: 1)
        static let paperShade = UIColor(red: 0.906, green: 0.875, blue: 0.820, alpha: 1)
        static let ink = UIColor(red: 0.114, green: 0.141, blue: 0.220, alpha: 1)
        static let vermilion = UIColor(red: 0.761, green: 0.271, blue: 0.176, alpha: 1)
        static let missGrey = UIColor(red: 0.639, green: 0.612, blue: 0.565, alpha: 1)
        static let amber = UIColor(red: 0.851, green: 0.588, blue: 0.161, alpha: 1)
    }

    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .serif) }
    static let title = Font.system(size: 22, weight: .semibold, design: .serif)
    static let body = Font.system(size: 17)
    static let caption = Font.system(size: 13)
    /// The wordmark: geometric and widely tracked (the caller adds the tracking), close to the brand's Michroma
    /// without bundling a font.
    static func wordmark(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold) }

    /// One garden for every screen, so the lianas and trees stay put while the screens change in front of them.
    static let gardenSeed: UInt64 = 2026

    static func levelName(_ l: RhythmLevel) -> String {
        switch l {
        case .easy: return "Лёгкий"
        case .normal: return "Средний"
        case .hard: return "Сложный"
        }
    }

    static func levelHint(_ l: RhythmLevel) -> String {
        switch l {
        case .easy: return "Сильные доли. Можно моргать."
        case .normal: return "Больше нот, любой глаз, но одним."
        case .hard: return "Слева левый глаз, справа правый."
        }
    }

    static func word(_ j: Judgement) -> String {
        switch j {
        case .perfect: return "Точно"
        case .good: return "Хорошо"
        case .ok: return "Есть"
        case .miss: return "Мимо"
        }
    }

    /// The point `radius` from `c` at `angle` (radians from 3 o'clock, clockwise on screen, where y points down).
    /// The cosine is taken in Double on purpose: with CGFloat around it, `cos` is ambiguous between the
    /// CoreGraphics and the Double overloads.
    static func polar(_ c: CGPoint, _ radius: CGFloat, _ angle: Double) -> CGPoint {
        let dx: Double = cos(angle), dy: Double = sin(angle)
        return CGPoint(x: c.x + CGFloat(dx) * radius, y: c.y + CGFloat(dy) * radius)
    }

    /// A four-pointed star with curved sides, the atlas's mark for a note.
    static func star(_ c: CGPoint, _ r: CGFloat) -> Path {
        var p = Path()
        let tips = (0..<4).map { k in polar(c, r, Double(k) * .pi / 2 - .pi / 2) }
        p.move(to: tips[0])
        for k in 0..<4 {
            let ctrl = polar(c, r * 0.2, Double(k) * .pi / 2 - .pi / 4)
            p.addQuadCurve(to: tips[(k + 1) % 4], control: ctrl)
        }
        p.closeSubpath()
        return p
    }

    /// A closed eyelid with three lashes, `w` wide: the eye a side note asks for.
    static func closedEye(_ c: CGPoint, _ w: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: c.x - w / 2, y: c.y))
        p.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y + w * 0.6))
        for k: CGFloat in [-1, 0, 1] {
            let x = c.x + k * w * 0.27, y = c.y + w * 0.3 * (1 - abs(k) * 0.4)
            p.move(to: CGPoint(x: x, y: y))
            p.addLine(to: CGPoint(x: x + k * w * 0.1, y: y + w * 0.24))
        }
        return p
    }

    /// Part of a circle from 12 o'clock, clockwise as the player sees it (y down), `fraction` of the way round.
    static func dial(_ c: CGPoint, _ r: CGFloat, _ fraction: Double) -> Path {
        var p = Path()
        let steps = max(2, Int(64 * fraction))
        for k in 0...steps {
            let pt = polar(c, r, -Double.pi / 2 + 2 * .pi * fraction * Double(k) / Double(steps))
            if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }

    /// A slim leaf from `base`, `length` long, pointing at `angle` (radians, y down): the garden's leaf and the
    /// petal of its flowers.
    static func leaf(_ base: CGPoint, _ length: CGFloat, _ angle: Double, width: CGFloat? = nil) -> Path {
        let w = width ?? length * 0.34
        let tip = polar(base, length, angle)
        let mid = polar(base, length * 0.45, angle)
        var p = Path()
        p.move(to: base)
        p.addLine(to: polar(mid, w / 2, angle - .pi / 2))
        p.addLine(to: tip)
        p.addLine(to: polar(mid, w / 2, angle + .pi / 2))
        p.closeSubpath()
        return p
    }

    /// The SPANTHER mark (concept C, "locked pupil"): an iris with a slit pupil cut out of it, inside a hold ring
    /// open at the lower right. Drawn from the brand SVG's geometry (a 256 unit box) at `size` pt around `c`.
    /// `ring`: how much of the ring is drawn, 0...1 (it draws itself in on the menu); `slit`: the pupil's width
    /// as a share of the brand's.
    static func mark(_ c: CGPoint, size: CGFloat, ring: Double = 1, slit: Double = 1) -> Path {
        let k = size / 256
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: c.x + CGFloat(x - 128) * k, y: c.y + CGFloat(y - 128) * k) }
        var p = Path()
        // The iris, and the slit as a hole in it (even-odd fill).
        p.addEllipse(in: CGRect(x: c.x - 72 * k, y: c.y - 72 * k, width: 144 * k, height: 144 * k))
        let half = 30 * slit
        p.move(to: pt(128, 62))
        p.addQuadCurve(to: pt(128, 194), control: pt(128 + half, 128))
        p.addQuadCurve(to: pt(128, 62), control: pt(128 - half, 128))
        p.closeSubpath()
        // The ring: from 6 o'clock clockwise (on screen) for up to 300°, leaving the gap at the lower right.
        let sweep = 300 * min(1, max(0, ring))
        if sweep > 1 {
            let steps = max(2, Int(sweep / 4))
            var outer: [CGPoint] = [], inner: [CGPoint] = []
            for s in 0...steps {
                let deg = 90 + sweep * Double(s) / Double(steps)
                let a = deg * .pi / 180
                outer.append(pt(128 + 116 * cos(a), 128 + 116 * sin(a)))
                inner.append(pt(128 + 96 * cos(a), 128 + 96 * sin(a)))
            }
            p.move(to: outer[0])
            for q in outer.dropFirst() { p.addLine(to: q) }
            for q in inner.reversed() { p.addLine(to: q) }
            p.closeSubpath()
        }
        return p
    }
}

// MARK: - Buttons

struct AtlasPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Atlas.onAccent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Atlas.vermilion.opacity(!enabled ? 0.4 : configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AtlasSecondaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Atlas.ink.opacity(!enabled ? 0.35 : configuration.isPressed ? 0.6 : 1))
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Atlas.paper.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Atlas.ink.opacity(0.25), lineWidth: 1))
    }
}

/// A plate of paper laid over the garden: a little lighter than the page, with a hairline edge.
struct AtlasPlate: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Atlas.paper.opacity(0.92), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Atlas.ink.opacity(0.14), lineWidth: 1))
    }
}

extension View {
    func atlasPlate(padding: CGFloat = 16) -> some View { modifier(AtlasPlate(padding: padding)) }
}
