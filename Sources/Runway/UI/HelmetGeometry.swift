// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Everything a helmet is made of, as plain numbers and nothing else.
//
// No SwiftUI in here on purpose. The helmets are *described* in `HelmetSpec`
// and *interpreted* by `HelmetView`, and the description needs nothing but
// Foundation — which means it compiles, runs and is checked by
// `spike/HelmetVerify.swift` on any machine, Linux included, and can be drawn
// to SVG there and looked at. The SwiftUI file is left as thin as it can be:
// it turns these numbers into views and animations and decides nothing.

/// A colour, kept as the hex it was written in so a helmet reads like its design.
struct HColor: Sendable, Equatable {
    let hex: UInt32
    let alpha: Double

    init(_ hex: UInt32, _ alpha: Double = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    var red: Double { Double((hex >> 16) & 0xFF) / 255 }
    var green: Double { Double((hex >> 8) & 0xFF) / 255 }
    var blue: Double { Double(hex & 0xFF) / 255 }

}

/// One step of an outline. Absolute coordinates, `y` down, origin at the
/// centre of the notch — the same space the helmets were designed in.
enum HSeg: Sendable, Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(to: CGPoint, c1: CGPoint, c2: CGPoint)
    case close
}

typealias HPath = [HSeg]

/// Shapes, as outlines. A point is an `(x, y)` pair so a helmet's data reads as
/// a list of coordinates and not as a wall of `CGPoint(`.
enum HShape {
    /// The kappa of a quarter circle drawn with one cubic.
    static let kappa: CGFloat = 0.5523

    private static func pt(_ p: (CGFloat, CGFloat)) -> CGPoint { CGPoint(x: p.0, y: p.1) }

    static func polygon(_ points: [(CGFloat, CGFloat)], closed: Bool = true) -> HPath {
        guard let first = points.first else { return [] }
        var path: HPath = [.move(pt(first))]
        for p in points.dropFirst() { path.append(.line(pt(p))) }
        if closed { path.append(.close) }
        return path
    }

    /// A smooth curve through the points (Catmull-Rom, as cubic Béziers).
    ///
    /// The tangent at each point is the line between its two neighbours, scaled
    /// by `tension`; the ends of an open curve borrow their only neighbour, so
    /// it leaves the first point and arrives at the last one straight.
    static func smooth(_ points: [(CGFloat, CGFloat)], closed: Bool = false, tension t: CGFloat = 1.0 / 6) -> HPath {
        let n = points.count
        guard n >= 2 else { return polygon(points, closed: false) }
        let p = points.map(pt)

        func tangent(_ k: Int) -> CGPoint {
            let before = p[closed ? (k - 1 + n) % n : max(k - 1, 0)]
            let after = p[closed ? (k + 1) % n : min(k + 1, n - 1)]
            return CGPoint(x: (after.x - before.x) * t, y: (after.y - before.y) * t)
        }

        var path: HPath = [.move(p[0])]
        let segments = closed ? n : n - 1
        for k in 0..<segments {
            let next = (k + 1) % n
            let t0 = tangent(k), t1 = tangent(next)
            path.append(.curve(
                to: p[next],
                c1: CGPoint(x: p[k].x + t0.x, y: p[k].y + t0.y),
                c2: CGPoint(x: p[next].x - t1.x, y: p[next].y - t1.y)
            ))
        }
        if closed { path.append(.close) }
        return path
    }

    static func ellipse(cx: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat) -> HPath {
        let rx = width / 2, ry = height / 2, k = kappa
        return [
            .move(CGPoint(x: cx, y: cy - ry)),
            .curve(to: CGPoint(x: cx + rx, y: cy), c1: CGPoint(x: cx + k * rx, y: cy - ry), c2: CGPoint(x: cx + rx, y: cy - k * ry)),
            .curve(to: CGPoint(x: cx, y: cy + ry), c1: CGPoint(x: cx + rx, y: cy + k * ry), c2: CGPoint(x: cx + k * rx, y: cy + ry)),
            .curve(to: CGPoint(x: cx - rx, y: cy), c1: CGPoint(x: cx - k * rx, y: cy + ry), c2: CGPoint(x: cx - rx, y: cy + k * ry)),
            .curve(to: CGPoint(x: cx, y: cy - ry), c1: CGPoint(x: cx - rx, y: cy - k * ry), c2: CGPoint(x: cx - k * rx, y: cy - ry)),
            .close,
        ]
    }

    /// A rectangle with different radii on top and bottom. The notch is this
    /// with a hint of a corner above and a half circle below.
    static func notch(
        cx: CGFloat = 0, cy: CGFloat = 0,
        width: CGFloat, height: CGFloat,
        topRadius rt: CGFloat, bottomRadius rb: CGFloat
    ) -> HPath {
        let x = width / 2, y = height / 2, k = kappa
        func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: cx + dx, y: cy + dy) }
        return [
            .move(at(-x + rt, -y)),
            .line(at(x - rt, -y)),
            .curve(to: at(x, -y + rt), c1: at(x - rt + k * rt, -y), c2: at(x, -y + rt - k * rt)),
            .line(at(x, y - rb)),
            .curve(to: at(x - rb, y), c1: at(x, y - rb + k * rb), c2: at(x - rb + k * rb, y)),
            .line(at(-x + rb, y)),
            .curve(to: at(-x, y - rb), c1: at(-x + rb - k * rb, y), c2: at(-x, y - rb + k * rb)),
            .line(at(-x, -y + rt)),
            .curve(to: at(-x + rt, -y), c1: at(-x, -y + rt - k * rt), c2: at(-x + rt - k * rt, -y)),
            .close,
        ]
    }

    /// A rectangle with one radius all round, clamped so it can never exceed
    /// half of the shorter side.
    static func box(cx: CGFloat, cy: CGFloat, width: CGFloat, height: CGFloat, radius: CGFloat = 0) -> HPath {
        let r = min(max(radius, 0), width / 2, height / 2)
        if r == 0 {
            let x = width / 2, y = height / 2
            return polygon([(cx - x, cy - y), (cx + x, cy - y), (cx + x, cy + y), (cx - x, cy + y)])
        }
        return notch(cx: cx, cy: cy, width: width, height: height, topRadius: r, bottomRadius: r)
    }

    /// A path cut into its spans, each its own outline. A band or a rim drawn as
    /// one curve can then be lit a span at a time, which is how a light runs
    /// along it.
    static func spans(_ path: HPath) -> [HPath] {
        var result: [HPath] = []
        var current: CGPoint?
        for seg in path {
            switch seg {
            case .move(let p):
                current = p
            case .line(let p):
                if let from = current { result.append([.move(from), .line(p)]) }
                current = p
            case .curve(let to, let c1, let c2):
                if let from = current { result.append([.move(from), .curve(to: to, c1: c1, c2: c2)]) }
                current = to
            case .close:
                break
            }
        }
        return result
    }

    static func translated(_ path: HPath, dx: CGFloat, dy: CGFloat) -> HPath {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        return path.map { seg in
            switch seg {
            case .move(let p): return .move(move(p))
            case .line(let p): return .line(move(p))
            case .curve(let to, let c1, let c2): return .curve(to: move(to), c1: move(c1), c2: move(c2))
            case .close: return .close
            }
        }
    }
}

/// One thing to paint: an outline, filled and/or stroked.
///
/// A fill is painted first and the stroke on top of it. Several sub-paths in one
/// outline share the paint, which is how a row of rivets or three vents are one
/// draw and not thirty.
struct HDraw: Sendable {
    var path: HPath
    var fill: HColor?
    var stroke: HColor?
    var strokeWidth: CGFloat
    /// Even-odd instead of non-zero: the shadow is the shell with the lit shape
    /// punched out of it, which is two outlines and one rule.
    var evenOdd: Bool
    /// Clip to the helmet's silhouette. The livery runs off the edge on purpose
    /// and is cut by this and not by careful drawing.
    var clipToShell: Bool

    static func fill(_ path: HPath, _ color: HColor, clip: Bool = false, evenOdd: Bool = false) -> HDraw {
        HDraw(path: path, fill: color, stroke: nil, strokeWidth: 0, evenOdd: evenOdd, clipToShell: clip)
    }

    static func line(_ path: HPath, _ color: HColor, _ width: CGFloat, clip: Bool = false) -> HDraw {
        HDraw(path: path, fill: nil, stroke: color, strokeWidth: width, evenOdd: false, clipToShell: clip)
    }

    static func ring(_ path: HPath, fill: HColor, stroke: HColor, _ width: CGFloat) -> HDraw {
        HDraw(path: path, fill: fill, stroke: stroke, strokeWidth: width, evenOdd: false, clipToShell: false)
    }
}

/// A straight line from one value to another as a channel runs 0 to 1.
struct HRamp: Sendable, Equatable {
    var from: CGFloat
    var to: CGFloat

    init(_ from: CGFloat, _ to: CGFloat) {
        self.from = from
        self.to = to
    }

    static func fixed(_ value: CGFloat) -> HRamp { HRamp(value, value) }

    func at(_ t: CGFloat) -> CGFloat { from + (to - from) * min(max(t, 0), 1) }
}

/// A part of a helmet that answers to one of the animator's channels: the
/// breath, or the signature gesture.
///
/// Drawn once, as a still, and then only ever moved, scaled, turned or faded —
/// never redrawn — which is what keeps a gesture cheap enough for battery.
struct HDynamic: Sendable {
    enum Channel: Sendable, Equatable {
        /// The breath. Rises and falls with the beat.
        case led
        /// One of the helmet's gestures, by index. Every gesture has a channel
        /// of its own, 0 at rest and 1 at its peak, so a part moves for its
        /// gesture and for no other.
        case gesture(Int)
    }

    var draws: [HDraw]
    var channel: Channel
    var opacity: HRamp = .fixed(1)
    var offsetX: HRamp = .fixed(0)
    var offsetY: HRamp = .fixed(0)
    /// In degrees, clockwise, about `pivot`.
    var rotation: HRamp = .fixed(0)
    var scale: HRamp = .fixed(1)
    var pivot: CGPoint = .zero
    /// Clipped to the window, for a glint that must not leave the glass.
    var insideWindow = false
    /// Fades as a tent of the channel and not as a straight ramp. One channel
    /// running 0 to 1 then chases a light along several parts, each with its
    /// own centre: the opacity ramp says how bright the peak is.
    ///
    /// SwiftUI animates the opacity itself, in a straight line from the value it
    /// had to the value it will have, and knows nothing of the tent. A gesture
    /// that drives a pulsed part must therefore visit its corners — the centre
    /// and a width either side — one step each, so that the straight lines
    /// between steps add up to the tent. `HelmetSignature.walk` does that, and
    /// the spike fails a gesture that does not.
    var pulse: HPulse?
}

/// Full at `center`, gone `width` either side of it.
struct HPulse: Sendable, Equatable {
    var center: CGFloat
    var width: CGFloat

    func at(_ t: CGFloat) -> CGFloat {
        guard width > 0 else { return t == center ? 1 : 0 }
        return max(0, 1 - abs(t - center) / width)
    }
}

/// The four numbers the animator drives, plus the gestures, at one instant.
struct HelmetState: Sendable, Equatable {
    /// How many gesture channels a helmet can have. The animator keeps this
    /// many, all 0 at rest. Eight: a helmet has four gestures built around its
    /// visor and its lights and four more built around its own parts, and a
    /// gesture owns one channel, so no two can ever light the same thing.
    static let gestureSlots = 8

    /// How shut the lid is, 0 open to 1 closed.
    var lid: CGFloat = 0
    /// Where it is looking, -1...1 on each axis.
    var gazeX: CGFloat = 0
    var gazeY: CGFloat = 0
    /// How wide the light is open, as a multiple of its resting size.
    var dilation: CGFloat = 1
    /// The breath, 0...1.
    var led: CGFloat = 0
    /// One channel per gesture, each 0...1.
    var gestures = [CGFloat](repeating: 0, count: HelmetState.gestureSlots)

    func gesture(_ index: Int) -> CGFloat { gestures.indices.contains(index) ? gestures[index] : 0 }

    static let rest = HelmetState()
}
