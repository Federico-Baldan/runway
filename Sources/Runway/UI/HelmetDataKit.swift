// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// The tools the helmets after the first five are drawn with. Plain Foundation,
// like `HelmetGeometry`, so the data files that use them compile and are checked
// by `spike/HelmetVerify.swift` on any machine.
//
// What is different from the first five: a helmet here owns its silhouette
// (`HelmetSpec.silhouette`) instead of wearing the notch, so a firefighter's brim
// or a samurai's crest is part of the shape and not a livery painted on a notch.
// Everything else is the same contract: a still drawn once, parts that are only
// moved, scaled, turned or faded, eight gestures with a channel each.

/// A corner of an outline: x, y, and the radius it is rounded to (0 is sharp).
typealias HV = (x: CGFloat, y: CGFloat, r: CGFloat)

/// A polygon with rounded corners. Each corner is replaced by a curve that starts
/// and ends `r` along its two edges, clamped to half of either edge so that
/// neighbouring corners can never overlap. Closed.
func hRound(_ points: [HV]) -> HPath {
    let n = points.count
    guard n >= 3 else { return [] }
    func at(_ i: Int) -> CGPoint {
        let p = points[((i % n) + n) % n]
        return CGPoint(x: p.x, y: p.y)
    }
    var entry = [CGPoint](), exit = [CGPoint](), c1 = [CGPoint](), c2 = [CGPoint](), curved = [Bool]()
    for i in 0..<n {
        let v = at(i), p = at(i - 1), q = at(i + 1)
        let dp = max(((p.x - v.x) * (p.x - v.x) + (p.y - v.y) * (p.y - v.y)).squareRoot(), 0.0001)
        let dq = max(((q.x - v.x) * (q.x - v.x) + (q.y - v.y) * (q.y - v.y)).squareRoot(), 0.0001)
        let r = min(points[i].r, dp / 2, dq / 2)
        if r < 0.01 {
            entry.append(v); exit.append(v); c1.append(v); c2.append(v); curved.append(false)
        } else {
            let a = CGPoint(x: v.x + (p.x - v.x) / dp * r, y: v.y + (p.y - v.y) / dp * r)
            let b = CGPoint(x: v.x + (q.x - v.x) / dq * r, y: v.y + (q.y - v.y) / dq * r)
            entry.append(a); exit.append(b); curved.append(true)
            let k = HShape.kappa
            c1.append(CGPoint(x: a.x + (v.x - a.x) * k, y: a.y + (v.y - a.y) * k))
            c2.append(CGPoint(x: b.x + (v.x - b.x) * k, y: b.y + (v.y - b.y) * k))
        }
    }
    var path: HPath = [.move(exit[0])]
    for i in 1..<n {
        path.append(.line(entry[i]))
        if curved[i] { path.append(.curve(to: exit[i], c1: c1[i], c2: c2[i])) }
    }
    path.append(.line(entry[0]))
    if curved[0] { path.append(.curve(to: exit[0], c1: c1[0], c2: c2[0])) }
    path.append(.close)
    return path
}

/// A symmetric outline, given by its right half from the top centre down to the
/// bottom centre; the left half is the mirror image.
func hSym(_ right: [HV]) -> HPath {
    var all = right
    for p in right.reversed() where p.x != 0 { all.append((-p.x, p.y, p.r)) }
    return hRound(all)
}

/// The same outline reflected about the vertical axis.
func hMirror(_ path: HPath) -> HPath {
    path.map { seg in
        switch seg {
        case .move(let p): return .move(CGPoint(x: -p.x, y: p.y))
        case .line(let p): return .line(CGPoint(x: -p.x, y: p.y))
        case .curve(let to, let c1, let c2):
            return .curve(to: CGPoint(x: -to.x, y: to.y), c1: CGPoint(x: -c1.x, y: c1.y), c2: CGPoint(x: -c2.x, y: c2.y))
        case .close: return .close
        }
    }
}

func hPoly(_ points: [(CGFloat, CGFloat)], closed: Bool = true) -> HPath { HShape.polygon(points, closed: closed) }
func hCurve(_ points: [(CGFloat, CGFloat)], closed: Bool = false, _ tension: CGFloat = 1.0 / 6) -> HPath {
    HShape.smooth(points, closed: closed, tension: tension)
}
func hOval(_ cx: CGFloat, _ cy: CGFloat, _ width: CGFloat, _ height: CGFloat) -> HPath {
    HShape.ellipse(cx: cx, cy: cy, width: width, height: height)
}
func hBox(_ cx: CGFloat, _ cy: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat = 0) -> HPath {
    HShape.box(cx: cx, cy: cy, width: width, height: height, radius: radius)
}
func hFill(_ path: HPath, _ hex: UInt32, _ alpha: Double = 1, clip: Bool = false) -> HDraw {
    .fill(path, HColor(hex, alpha), clip: clip)
}
func hLine(_ path: HPath, _ hex: UInt32, _ width: CGFloat, _ alpha: Double = 1, clip: Bool = false) -> HDraw {
    .line(path, HColor(hex, alpha), width, clip: clip)
}
func hTogether(_ paths: [HPath]) -> HPath { paths.flatMap { $0 } }
func hMove(_ path: HPath, _ dx: CGFloat, _ dy: CGFloat) -> HPath { HShape.translated(path, dx: dx, dy: dy) }

/// A row of dots.
func hDots(_ xs: [CGFloat], _ y: CGFloat, _ size: CGFloat) -> HPath { hTogether(xs.map { hOval($0, y, size, size) }) }

/// A light running along a path: one bright part per span, each its own tent of
/// the channel. See `HelmetSpec.chase`; the same, for the files that cannot see it.
func hChase(
    _ spans: [HPath], hex: UInt32, width: CGFloat, gesture: Int, alpha: Double = 1, clip: Bool = false
) -> [HDynamic] {
    let count = CGFloat(spans.count)
    return spans.enumerated().map { index, span in
        HDynamic(
            draws: [hLine(span, hex, width, alpha, clip: clip)], channel: .gesture(gesture),
            opacity: HRamp(0, 1), pulse: HPulse(center: (CGFloat(index) + 1) / (count + 1), width: 1 / (count + 1))
        )
    }
}

/// A part that lights and goes out as a tent of its channel, centred at `center`.
func hGlow(_ draws: [HDraw], gesture: Int, center: CGFloat, width: CGFloat, inside: Bool = false) -> HDynamic {
    HDynamic(draws: draws, channel: .gesture(gesture), opacity: HRamp(0, 1), insideWindow: inside,
             pulse: HPulse(center: center, width: width))
}

/// A part that lights with its channel, straight (0 at rest, 1 at the peak).
func hLamp(_ draws: [HDraw], gesture: Int, inside: Bool = false) -> HDynamic {
    HDynamic(draws: draws, channel: .gesture(gesture), opacity: HRamp(0, 1), insideWindow: inside)
}

/// The light on a helmet's shell: the shell colour, whatever is painted on it,
/// then a hard shadow on the lower right (the lit shape punched out of the
/// silhouette) and a thin light along the upper left.
func hFinish(
    shell: HPath, base: UInt32, light: UInt32, lightPath: HPath, shade: Double,
    lit: (CGFloat, CGFloat, CGFloat, CGFloat), livery: [HDraw]
) -> [HDraw] {
    let shadow = HDraw.fill(shell + hOval(lit.0, lit.1, lit.2, lit.3), HColor(0x000000, shade / 100), clip: true, evenOdd: true)
    return [.fill(shell, HColor(base))] + livery + [shadow, hLine(lightPath, light, 4.5, clip: true)]
}

/// A step of a gesture, written short. `gx` and `gy` take the eyes somewhere,
/// and a step that does is one that gives way to a hover.
func hs(
    _ duration: Double, hold: Double = 0, _ curve: SignatureStep.Curve = .easeOut,
    ch: Int = 0, lv: CGFloat? = nil, gx: CGFloat? = nil, gy: CGFloat = 0, dil: CGFloat? = nil
) -> SignatureStep {
    SignatureStep(
        duration: duration, hold: hold, curve: curve, channel: ch, level: lv,
        gaze: gx.map { CGSize(width: $0, height: gy) }, dilation: dil, looksAway: gx != nil
    )
}

/// The eyes only, for the move that opens or ends a gesture: a gaze (`gx`, `gy`),
/// no channel.
func hsEyes(_ duration: Double, hold: Double = 0, _ curve: SignatureStep.Curve = .easeOut, gx: CGFloat, gy: CGFloat = 0) -> SignatureStep {
    SignatureStep(duration: duration, hold: hold, curve: curve, gaze: CGSize(width: gx, height: gy), looksAway: true)
}

/// A run of steps that walks a channel through the levels where each part of a
/// chase has its peak, then drops it to 0 unseen. See `HelmetSignature.walk`.
func hWalk(_ levels: [CGFloat], ch: Int, each: Double, _ curve: SignatureStep.Curve = .linear) -> [SignatureStep] {
    levels.map { SignatureStep(duration: each, curve: curve, channel: ch, level: $0) }
        + [SignatureStep(duration: 0, curve: .instant, channel: ch, level: 0)]
}

/// The channel back to 0 without anybody seeing it go.
func hReset(_ ch: Int) -> SignatureStep { SignatureStep(duration: 0, curve: .instant, channel: ch, level: 0) }

/// One helmet of the collection: how it is drawn, what it does, and what it is
/// a picture of.
struct HelmetEntry: Sendable {
    let spec: HelmetSpec
    let gestures: [[SignatureStep]]
    /// The real object, in a few words. Not drawn or shown in the app: the README and the
    /// Artifact say what each helmet is a picture of, and this keeps it next to the drawing.
    let reference: String
}

/// A helmet that wears its own silhouette. The eyes are two LEDs, the window is
/// whatever the face looks out of, the plate is the lid that closes it.
func hHelmet(
    shell: HPath, base: UInt32, light: UInt32, lightPath: HPath, edge: UInt32, shade: Double = 34,
    lit: (CGFloat, CGFloat, CGFloat, CGFloat) = (-48, -46, 300, 236),
    livery: [HDraw],
    window: HPath, top: CGFloat, bottom: CGFloat, width: CGFloat,
    glass: UInt32 = 0x0B0C0F, rim: UInt32 = 0x050506, rimWidth: CGFloat = 10, restFraction: CGFloat = 0,
    eyes: (w: CGFloat, h: CGFloat, y: CGFloat, dx: CGFloat, tx: CGFloat, ty: CGFloat, dim: UInt32, bright: UInt32),
    glint: [HDraw] = [],
    plate: (fill: UInt32, edge: UInt32, width: CGFloat, deco: [HDraw]),
    flash: UInt32? = nil, flashGesture: Int = 0,
    above: [HDraw], dynamics: [HDynamic],
    raisesVisor: Bool = false, visorNudge: CGFloat = 0, visorGesture: Int = 0
) -> HelmetSpec {
    var spec = HelmetSpec(
        below: hFinish(shell: shell, base: base, light: light, lightPath: lightPath, shade: shade, lit: lit, livery: livery),
        edge: HColor(edge, 0.9),
        window: HWindow(
            path: window, glass: HColor(glass), rim: HColor(rim), rimWidth: rimWidth,
            top: top, bottom: bottom, width: width, restFraction: restFraction
        ),
        eyes: HEyes(
            width: eyes.w, height: eyes.h, xs: [-eyes.dx, eyes.dx], centerY: eyes.y,
            travelX: eyes.tx, travelY: eyes.ty, dim: HColor(eyes.dim), bright: HColor(eyes.bright)
        ),
        highlights: glint,
        plate: HPlate(
            fill: HColor(plate.fill), edge: HColor(plate.edge), edgeWidth: plate.width, deco: plate.deco,
            edgeFlash: flash.map { HColor($0) }, flashGesture: flashGesture
        ),
        above: above, dynamics: dynamics, raisesVisor: raisesVisor, visorNudge: visorNudge, visorGesture: visorGesture
    )
    spec.silhouette = shell
    return spec
}
