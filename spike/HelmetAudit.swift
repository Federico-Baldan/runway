// Where each moving part of a gesture is, and where it goes.
//
// `HelmetVerify` checks a gesture as a list of steps; this checks what its parts do
// to the picture, against the rules SwiftUI imposes on the way they are drawn:
//
//   * A `Canvas` draws only inside its own frame. A part whose drawing lies outside
//     the 312 x 224 canvas at rest is cut there for good, however far it is moved
//     afterwards, so a part that moves must be drawn inside it. (The SVG frames do
//     not show this: an SVG has no such edge.)
//   * `clip: true` clips to the shell BEFORE the part is moved. A clipped shape that
//     is carried sideways leaves the helmet and floats over the black of the notch.
//   * A part that is not meant to be seen at rest must not be: its opacity is 0 or the
//     window it is clipped to does not reach it.
//   * While a part is visible it stays inside the box the mark is drawn in; what lies
//     beyond is drawn over whatever the island has next to it.
//
// They are held to the second four gestures (channels 4 to 7). The first four were
// drawn before these rules were written down, and some of them bend them by a few
// points; they are listed, not failed.
//
// Foundation only, like `HelmetVerify`, whose `check` it reports through.

// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

enum HelmetAudit {
    typealias Motion = (opacity: CGFloat, dx: CGFloat, dy: CGFloat, rotation: CGFloat, scale: CGFloat)

    /// The canvas, and the box the mark is drawn in (a few points of slack: a stroke's cap).
    static let canvas = CGRect(x: -156, y: -112, width: 312, height: 224)
    static let box = canvas.insetBy(dx: -4, dy: -4)
    /// Channels from which the rules are held.
    static let firstChecked = 4

    /// An outline as straight runs, curves cut into 12. Unlike `HelmetVerify.flatten`, which
    /// is for closed shapes and drops anything of fewer than three points, it keeps a line:
    /// a cable, a spark, an arrow are two points, and are what has to be looked at here.
    static func polygons(_ path: HPath) -> [[CGPoint]] {
        var runs: [[CGPoint]] = [], current: [CGPoint] = [], last = CGPoint.zero
        for seg in path {
            switch seg {
            case .move(let p):
                if current.count > 1 { runs.append(current) }
                current = [p]; last = p
            case .line(let p):
                current.append(p); last = p
            case .curve(let to, let c1, let c2):
                for i in 1...12 {
                    let t = CGFloat(i) / 12, u = 1 - t
                    current.append(CGPoint(
                        x: u * u * u * last.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * to.x,
                        y: u * u * u * last.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * to.y))
                }
                last = to
            case .close:
                break
            }
        }
        if current.count > 1 { runs.append(current) }
        return runs
    }

    static func inside(_ path: HPath, _ p: CGPoint, evenOdd: Bool) -> Bool {
        var winding = 0, crossings = 0
        for poly in polygons(path) {
            for i in 0..<poly.count {
                let a = poly[i], b = poly[(i + 1) % poly.count]
                if (a.y > p.y) != (b.y > p.y) {
                    let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                    if x > p.x { crossings += 1; winding += b.y > a.y ? 1 : -1 }
                }
            }
        }
        return evenOdd ? crossings % 2 == 1 : winding != 0
    }

    static func near(_ path: HPath, _ p: CGPoint, _ r: CGFloat) -> Bool {
        for poly in polygons(path) where poly.count > 1 {
            for i in 0..<(poly.count - 1) {
                let a = poly[i], b = poly[i + 1]
                let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
                let t = l2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
                let ex = a.x + t * dx - p.x, ey = a.y + t * dy - p.y
                if ex * ex + ey * ey <= r * r { return true }
            }
        }
        return false
    }

    /// Whether a draw paints the point `p`.
    static func covers(_ draw: HDraw, _ p: CGPoint) -> Bool {
        if draw.fill != nil, inside(draw.path, p, evenOdd: draw.evenOdd) { return true }
        if draw.stroke != nil, near(draw.path, p, max(draw.strokeWidth, 1) / 2) { return true }
        return false
    }

    /// Where a point of a part ends up: scaled and turned about the pivot, then offset,
    /// which is the order `HelmetMark.moving` applies them in.
    static func moved(_ p: CGPoint, _ part: HDynamic, _ m: Motion) -> CGPoint {
        let a = m.rotation * .pi / 180
        let x = (p.x - part.pivot.x) * m.scale, y = (p.y - part.pivot.y) * m.scale
        return CGPoint(x: part.pivot.x + x * cos(a) - y * sin(a) + m.dx, y: part.pivot.y + x * sin(a) + y * cos(a) + m.dy)
    }

    static func state(_ channel: Int, _ level: CGFloat) -> HelmetState {
        var s = HelmetState.rest
        s.gestures[channel] = level
        return s
    }

    /// The points of a draw as far as the canvas shows them: what lies outside it is cut.
    static func shown(_ draw: HDraw) -> [CGPoint] {
        polygons(draw.path).flatMap { $0 }.map {
            CGPoint(x: min(max($0.x, canvas.minX), canvas.maxX), y: min(max($0.y, canvas.minY), canvas.maxY))
        }
    }

    static func moves(_ part: HDynamic) -> Bool {
        part.offsetX.from != part.offsetX.to || part.offsetY.from != part.offsetY.to
            || part.rotation.from != part.rotation.to || part.scale.from != part.scale.to
    }

    static func run(_ helmets: [AvatarStyle]) {
        print()
        print("── where the moving parts are ──")
        var seenAtRest: [String] = [], cut: [String] = [], leaving: [String] = [], outside: [String] = []
        var parts = 0
        for style in helmets {
            guard let spec = style.helmet else { continue }
            for (index, part) in spec.dynamics.enumerated() {
                guard case .gesture(let channel) = part.channel, channel >= firstChecked else { continue }
                parts += 1
                let tag = "\(style.rawValue) gesture \(channel) part \(index)"
                let rest = spec.motion(of: part, in: state(channel, 0))

                // Seen at rest. The one part meant to be: the swivelling camera of the Orlan, a part of the helmet.
                if rest.opacity > 0.001, !(style == .orlan && channel == 4 && part.opacity.from == 1) {
                    let shows = part.draws.contains { draw in
                        shown(draw).contains { !part.insideWindow || inside(spec.window.path, moved($0, part, rest), evenOdd: false) }
                    }
                    if shows { seenAtRest.append(tag) }
                }

                // A part that moves, drawn partly outside the canvas: the rest is cut. A part
                // clipped to the shell may run off the edge: that edge is the shell's, and it is cut there anyway.
                if moves(part) {
                    for draw in part.draws where !draw.clipToShell {
                        let pts = polygons(draw.path).flatMap { $0 }
                        let r = draw.stroke != nil ? draw.strokeWidth / 2 : 0
                        if let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max(),
                           x0 - r < canvas.minX - 0.5 || x1 + r > canvas.maxX + 0.5 || y0 - r < canvas.minY - 0.5 || y1 + r > canvas.maxY + 0.5 {
                            cut.append(tag); break
                        }
                    }
                }

                // Clipped to the shell, then moved: how much of it is off the helmet while it can be seen.
                if moves(part), part.draws.contains(where: \.clipToShell) {
                    for step in 1...9 {
                        let m = spec.motion(of: part, in: state(channel, CGFloat(step) / 10))
                        guard m.opacity > 0.3 else { continue }
                        var total = 0, out = 0
                        var y = canvas.minY
                        while y < canvas.maxY {
                            var x = canvas.minX
                            while x < canvas.maxX {
                                let p = CGPoint(x: x, y: y)
                                if inside(spec.silhouette, p, evenOdd: false), part.draws.contains(where: { $0.clipToShell && covers($0, p) }) {
                                    total += 1
                                    if !inside(spec.silhouette, moved(p, part, m), evenOdd: false) { out += 1 }
                                }
                                x += 4
                            }
                            y += 4
                        }
                        if total > 0, Double(out) / Double(total) > 0.15 { leaving.append(tag); break }
                    }
                }

                // Visible, and drawn beyond the box of the mark.
                if !part.insideWindow {
                    levels: for step in 1...9 {
                        let m = spec.motion(of: part, in: state(channel, CGFloat(step) / 10))
                        guard m.opacity > 0.2 else { continue }
                        for draw in part.draws {
                            let pts = shown(draw).map { moved($0, part, m) }
                            if pts.contains(where: { !box.contains($0) }) { outside.append(tag); break levels }
                        }
                    }
                }
            }
        }
        print("  \(parts) moving parts of the second four gestures")
        HelmetVerify.check("none is seen at rest, but for the Orlan's camera \(seenAtRest.prefix(3))", seenAtRest.isEmpty)
        HelmetVerify.check("none that moves is drawn outside the canvas, where SwiftUI would cut it \(cut.prefix(3))", cut.isEmpty)
        HelmetVerify.check("none clipped to the shell is carried off the helmet \(leaving.prefix(3))", leaving.isEmpty)
        HelmetVerify.check("none is seen outside the box the mark is drawn in \(outside.prefix(3))", outside.isEmpty)
    }
}
