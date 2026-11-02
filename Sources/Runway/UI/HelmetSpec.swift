import Foundation

// The five helmets, described. See `HelmetGeometry` for why this is plain data.
//
// Coordinates are the ones they were designed in: a notch 312 wide and 224
// tall, origin at its centre, y down. Colours are flat; there is no gradient,
// glow or blur in any of them, and the only soft thing about a helmet is the
// hard-edged shadow on its lower right.
//
// How a helmet answers the animator, the same for all of them:
//
//   lid       a sun visor that slides down over the window and back
//   gaze      the two LED eyes move inside the window; the helmet leans a hair
//   dilation  how big the LEDs are
//   breath    the LEDs brighten (a brighter copy fades in, nothing is redrawn)
//   signature a short gesture only this helmet makes (see `HelmetSignature`)

/// The window a helmet's face shows through, and the sun visor that closes it.
struct HWindow: Sendable {
    var path: HPath
    var glass: HColor
    var rim: HColor
    var rimWidth: CGFloat
    /// The vertical extent the visor travels over, and how wide it is.
    var top: CGFloat
    var bottom: CGFloat
    var width: CGFloat
    /// How much of the window the visor covers when the lid is open. A strip at
    /// the top for the gold visor, nothing for a sun visor that is up.
    var restFraction: CGFloat
}

struct HEyes: Sendable {
    var width: CGFloat
    var height: CGFloat
    var xs: [CGFloat]
    var centerY: CGFloat
    /// How far a full gaze moves them.
    var travelX: CGFloat
    var travelY: CGFloat
    var dim: HColor
    var bright: HColor
}

struct HPlate: Sendable {
    var fill: HColor
    var edge: HColor
    var edgeWidth: CGFloat
    /// Drawn in the plate's own space, origin at its centre, so it travels with
    /// it: the gold visor's highlight and its shaded lip.
    var deco: [HDraw]
    /// A brighter copy of the edge that a gesture fades in, and which gesture.
    var edgeFlash: HColor?
    var flashGesture = 0
}

struct HelmetSpec: Sendable {
    /// The notch, and so the helmet's silhouette.
    static let designWidth: CGFloat = 312
    static let designHeight: CGFloat = 224
    /// Matches `BrandGeometry.topCornerRatio`; `HelmetView` checks it does.
    static let topCornerRatio: CGFloat = 0.103
    static let shell: HPath = HShape.notch(
        width: designWidth, height: designHeight,
        topRadius: designWidth * topCornerRatio, bottomRadius: designHeight / 2
    )

    /// Shell, livery, shadow and light, painted first and clipped to the shell.
    var below: [HDraw]
    var window: HWindow
    var eyes: HEyes
    /// A thin glint on the glass that slides against the gaze.
    var highlights: [HDraw]
    var plate: HPlate
    /// Hardware that sits over the window's rim and never moves.
    var above: [HDraw]
    var dynamics: [HDynamic]
    /// Whether a gesture lifts the visor (the gold one does), and which.
    var raisesVisor: Bool
    /// How much of the window a gesture pulls the visor down over, as a
    /// fraction of it: a sun visor that dips so its edge shows and can flash.
    var visorNudge: CGFloat = 0
    /// The gesture that moves the visor, when one does.
    var visorGesture = 0
}

// MARK: - State to geometry

extension HelmetSpec {
    var plateWidth: CGFloat { window.width + 16 }
    var plateHeight: CGFloat { window.bottom - window.top + 10 }

    /// Where the lower edge of the sun visor is.
    func plateEdgeY(_ s: HelmetState) -> CGFloat {
        let lid = min(max(s.lid, 0), 1)
        let gesture = min(max(s.gesture(visorGesture), 0), 1)
        let lifted = raisesVisor ? window.restFraction * (1 - gesture) : window.restFraction
        let rest = lifted + visorNudge * gesture
        let fraction = rest + (1 - rest) * lid
        return window.top + fraction * (window.bottom - window.top)
    }

    /// Where it sits with the lid open and nothing happening: the position the
    /// plate is drawn at, and everything after that is an offset from here.
    var plateRestEdgeY: CGFloat { plateEdgeY(.rest) }

    func plateOffsetY(_ s: HelmetState) -> CGFloat { plateEdgeY(s) - plateRestEdgeY }

    /// The visor and what it carries, drawn at its resting position.
    var plateDraws: [HDraw] {
        let edgeY = plateRestEdgeY
        let centerY = edgeY - plateHeight / 2
        var draws: [HDraw] = [
            .fill(HShape.box(cx: 0, cy: centerY, width: plateWidth, height: plateHeight), plate.fill),
        ]
        for deco in plate.deco {
            var moved = deco
            moved.path = HShape.translated(deco.path, dx: 0, dy: centerY)
            draws.append(moved)
        }
        draws.append(edgeDraw(plate.edge))
        return draws
    }

    /// The flash that rides on the edge, if this helmet has one.
    var edgeFlashDraw: HDraw? { plate.edgeFlash.map(edgeDraw) }

    private func edgeDraw(_ color: HColor) -> HDraw {
        .fill(
            HShape.box(cx: 0, cy: plateRestEdgeY - plate.edgeWidth / 2, width: plateWidth, height: plate.edgeWidth),
            color
        )
    }

    /// The LEDs. Wider as the eye opens, taller with its square root, so a
    /// squint narrows them less than it shrinks them.
    func eyeRects(_ s: HelmetState) -> [CGRect] {
        let dilation = max(s.dilation, 0)
        let width = eyes.width * min(dilation, 1.25)
        let height = eyes.height * dilation.squareRoot()
        return eyes.xs.map { x in
            CGRect(
                x: x + s.gazeX * eyes.travelX - width / 2,
                y: eyes.centerY + s.gazeY * eyes.travelY - height / 2,
                width: width,
                height: height
            )
        }
    }

    func eyeCornerRadius(for rect: CGRect) -> CGFloat { min(rect.width, rect.height) * 0.4 }

    /// What a dynamic part is doing at this instant.
    func motion(of part: HDynamic, in s: HelmetState) -> (opacity: CGFloat, dx: CGFloat, dy: CGFloat, rotation: CGFloat, scale: CGFloat) {
        let t: CGFloat
        switch part.channel {
        case .led: t = s.led
        case .gesture(let index): t = s.gesture(index)
        }
        // A pulse shapes only the fade; the rest of the ramps follow the channel.
        let fade = part.pulse.map { $0.at(t) } ?? t
        return (part.opacity.at(fade), part.offsetX.at(t), part.offsetY.at(t), part.rotation.at(t), part.scale.at(t))
    }
}

/// The pieces a helmet is drawn in, back to front. `HelmetView` draws each one
/// as its own still and only ever moves them, which is what keeps a helmet
/// cheap: nothing is redrawn when the eyes move.
enum HelmetLayerID: Hashable, Sendable {
    case below
    case glass
    case highlights
    case plate
    case plateFlash
    case rim
    case above
    case dynamic(Int)
}

extension HelmetSpec {
    func draws(for layer: HelmetLayerID) -> [HDraw] {
        switch layer {
        case .below: return below
        case .glass: return [.fill(window.path, window.glass)]
        case .highlights: return highlights
        case .plate: return plateDraws
        case .plateFlash: return edgeFlashDraw.map { [$0] } ?? []
        case .rim: return [.line(window.path, window.rim, window.rimWidth)]
        case .above: return above
        case .dynamic(let index): return dynamics.indices.contains(index) ? dynamics[index].draws : []
        }
    }
}

extension AvatarStyle {
    /// The helmet this style draws, or `nil` for the original eye.
    var helmet: HelmetSpec? {
        switch self {
        case .classic: return nil
        case .apollo: return .apollo
        case .orlan: return .orlan
        case .stealth: return .stealth
        case .papaya: return .papaya
        case .endurance: return .endurance
        }
    }
}

// MARK: - Small drawing helpers

private func poly(_ points: [(CGFloat, CGFloat)], closed: Bool = true) -> HPath {
    HShape.polygon(points, closed: closed)
}

private func curve(_ points: [(CGFloat, CGFloat)], closed: Bool = false, _ tension: CGFloat = 1.0 / 6) -> HPath {
    HShape.smooth(points, closed: closed, tension: tension)
}

private func oval(_ cx: CGFloat, _ cy: CGFloat, _ width: CGFloat, _ height: CGFloat) -> HPath {
    HShape.ellipse(cx: cx, cy: cy, width: width, height: height)
}

private func box(_ cx: CGFloat, _ cy: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat = 0) -> HPath {
    HShape.box(cx: cx, cy: cy, width: width, height: height, radius: radius)
}

private func paint(_ path: HPath, _ hex: UInt32, _ alpha: Double = 1, clip: Bool = false) -> HDraw {
    .fill(path, HColor(hex, alpha), clip: clip)
}

private func stroke(_ path: HPath, _ hex: UInt32, _ width: CGFloat, _ alpha: Double = 1, clip: Bool = false) -> HDraw {
    .line(path, HColor(hex, alpha), width, clip: clip)
}

private func together(_ paths: [HPath]) -> HPath { paths.flatMap { $0 } }

/// A light running along a path: one bright part per span. Part i peaks at
/// (i+1)/(count+1) and is gone a spacing either side, so all of them are dark at
/// 0 and at 1 and the gesture walks the channel through the peaks (see
/// `HelmetSignature.walk`): SwiftUI only draws straight lines between the levels
/// it is given.
private func chase(
    _ spans: [HPath], hex: UInt32, width: CGFloat, gesture: Int, alpha: Double = 1, clip: Bool = false
) -> [HDynamic] {
    let count = CGFloat(spans.count)
    return spans.enumerated().map { index, span in
        HDynamic(
            draws: [stroke(span, hex, width, alpha, clip: clip)], channel: .gesture(gesture),
            opacity: HRamp(0, 1), pulse: HPulse(center: (CGFloat(index) + 1) / (count + 1), width: 1 / (count + 1))
        )
    }
}

/// A screw head: a ring with a dot in it.
private func screw(_ x: CGFloat, _ y: CGFloat, ring: UInt32, dot: UInt32) -> [HDraw] {
    [paint(oval(x, y, 22, 22), ring), paint(oval(x, y, 9, 9), dot)]
}

/// Three slits cut in the chin.
private func vents(_ y: CGFloat, count: Int = 3, hex: UInt32 = 0x060607) -> HDraw {
    paint(together((0..<count).map { box(0, y + CGFloat($0) * 11, 46, 5.4, 2.7) }), hex)
}

/// A race number in a round badge.
private func badge(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, fill: UInt32, ink: UInt32, ring: UInt32? = nil) -> [HDraw] {
    let disc = oval(x, y, radius * 2, radius * 2)
    let seven = HShape.translated(poly([(-10, -11), (11, -11), (11, -5), (0, 13), (-8, 13), (2, -3), (-10, -3)]), dx: x, dy: y)
    let base = ring.map { HDraw.ring(disc, fill: HColor(fill), stroke: HColor($0), 3.4) } ?? paint(disc, fill)
    return [base, paint(seven, ink)]
}

/// The shell colour, then whatever is painted on it, then the hard shadow on
/// the lower right and a thin light on the upper left. The shadow is painted
/// over the livery on purpose, so a stripe is shaded like the shell it is on.
private func finish(base: UInt32, light: UInt32, shade: Double, livery: [HDraw]) -> [HDraw] {
    let shadow = HDraw.fill(
        HelmetSpec.shell + oval(-48, -46, 300, 236), HColor(0x000000, shade / 100), clip: true, evenOdd: true
    )
    let rim = stroke(curve([(-150, 24), (-150, -70), (-141, -95), (-118, -106), (-60, -106)]), light, 4.5, clip: true)
    return [.fill(HelmetSpec.shell, HColor(base))] + livery + [shadow, rim]
}

/// An astronaut: a big window with a sun visor that is also the eyelid.
private func astronaut(
    base: UInt32, light: UInt32, shade: Double = 30, rim: UInt32, rimWidth: CGFloat = 13,
    bands: [HDraw], window: HPath, top: CGFloat, bottom: CGFloat, width: CGFloat,
    visor: (fill: UInt32, edge: UInt32, hi: UInt32, lo: UInt32), eye: (dim: UInt32, bright: UInt32),
    above: [HDraw], dynamics: [HDynamic], raisesVisor: Bool = false
) -> HelmetSpec {
    let centerY = (top + bottom) / 2
    let half = (bottom - top + 10) / 2
    return HelmetSpec(
        below: finish(base: base, light: light, shade: shade, livery: bands),
        window: HWindow(
            path: window, glass: HColor(0x0A0B0D), rim: HColor(rim), rimWidth: rimWidth,
            top: top, bottom: bottom, width: width, restFraction: 0.2
        ),
        eyes: HEyes(
            width: 36, height: 44, xs: [-48, 48], centerY: centerY, travelX: 18, travelY: 10,
            dim: HColor(eye.dim), bright: HColor(eye.bright)
        ),
        highlights: [stroke(poly([(-102, centerY + 4), (-102, centerY - 16), (-80, centerY - 16)], closed: false), 0xFFFFFF, 5, 0.16)],
        plate: HPlate(
            fill: HColor(visor.fill), edge: HColor(visor.edge), edgeWidth: 3.4,
            deco: [
                paint(poly([(-110, -half), (-70, -half), (-96, half), (-136, half)]), visor.hi),
                paint(box(0, half - 9, width + 16, 18), visor.lo),
            ],
            edgeFlash: nil
        ),
        above: above, dynamics: dynamics, raisesVisor: raisesVisor
    )
}

/// A racing helmet: a livery, a visor with a precise outline, a sun visor.
private func racer(
    base: UInt32, light: UInt32, shade: Double = 34, livery: [HDraw],
    window: HPath, top: CGFloat, bottom: CGFloat, width: CGFloat, eyeY: CGFloat,
    glass: UInt32 = 0x0D0E11, rim: UInt32 = 0x040405, restFraction: CGFloat = 0,
    plate: (fill: UInt32, edge: UInt32, flash: UInt32), eye: (dim: UInt32, bright: UInt32),
    above: [HDraw], dynamics: [HDynamic], visorNudge: CGFloat = 0, visorGesture: Int = 0
) -> HelmetSpec {
    HelmetSpec(
        below: finish(base: base, light: light, shade: shade, livery: livery),
        window: HWindow(
            path: window, glass: HColor(glass), rim: HColor(rim), rimWidth: 11,
            top: top, bottom: bottom, width: width, restFraction: restFraction
        ),
        eyes: HEyes(
            width: 34, height: 40, xs: [-48, 48], centerY: eyeY, travelX: 17, travelY: 9,
            dim: HColor(eye.dim), bright: HColor(eye.bright)
        ),
        highlights: [stroke(poly([(-112, eyeY - 16), (-96, eyeY - 38), (-60, eyeY - 42)], closed: false), 0xFFFFFF, 5, 0.14)],
        plate: HPlate(fill: HColor(plate.fill), edge: HColor(plate.edge), edgeWidth: 4, deco: [], edgeFlash: HColor(plate.flash)),
        above: above, dynamics: dynamics, raisesVisor: false, visorNudge: visorNudge, visorGesture: visorGesture
    )
}

// MARK: - The helmets

extension HelmetSpec {
    /// Graphite, one orange band, a gold visor. The one everything else was
    /// measured against.
    static let apollo = astronaut(
        base: 0x2B2D32, light: 0x454951, rim: 0x17181C,
        bands: [stroke(curve([(-166, -64), (-80, -94), (80, -94), (166, -64)]), 0xE8580C, 8, clip: true)],
        window: box(0, -6, 238, 116, 52), top: -64, bottom: 52, width: 238,
        visor: (fill: 0xC4932D, edge: 0x6A4A10, hi: 0xE6C264, lo: 0x98701F),
        eye: (dim: 0xCFD6D4, bright: 0xFFFDF2),
        above: apolloHardware(),
        dynamics: [
            // The connector's light follows the breath, and flashes when the
            // visor is tapped.
            HDynamic(draws: [paint(oval(122, 70, 12, 12), 0xE8580C)], channel: .led, opacity: HRamp(0.55, 1)),
            HDynamic(draws: [paint(oval(122, 70, 12, 12), 0xFFD0A8)], channel: .gesture(0), opacity: HRamp(0, 1)),
        ]
            // Gesture 1: a light runs along the orange band, left to right.
            + chase(HShape.spans(curve([(-166, -64), (-80, -94), (80, -94), (166, -64)])),
                    hex: 0xFFD7A0, width: 8, gesture: 1, clip: true)
            // Gesture 2: a glint slides over the gold strip, and nowhere else.
            + [HDynamic(draws: [paint(poly([(-26, -64), (38, -64), (22, -38), (-42, -38)]), 0xFFF4C8, 0.95)],
                        channel: .gesture(2), offsetX: HRamp(-170, 170), insideWindow: true)]
            // Gesture 3: the latches at the sides light, left then right, as the eyes glance at each.
            + [HDynamic(draws: [paint(box(-139, -6, 22, 48, 6), 0xFF8A3D)], channel: .gesture(3),
                        opacity: HRamp(0, 1), pulse: HPulse(center: 0.25, width: 0.25)),
               HDynamic(draws: [paint(box(139, -6, 22, 48, 6), 0xFF8A3D)], channel: .gesture(3),
                        opacity: HRamp(0, 1), pulse: HPulse(center: 0.75, width: 0.25))],
        raisesVisor: true
    )

    /// A round window, a silver visor, a red band; a lamp on the left and a
    /// camera on the right that the signature switches on.
    static let orlan = astronaut(
        base: 0x25272C, light: 0x3F434B, rim: 0x15161A,
        bands: [
            stroke(curve([(-166, -74), (-80, -90), (80, -90), (166, -74)]), 0xD62828, 9, clip: true),
            stroke(curve([(-166, -63), (-80, -79), (80, -79), (166, -63)]), 0xE8E8E8, 3, clip: true),
        ],
        window: oval(0, -6, 246, 112), top: -62, bottom: 50, width: 246,
        visor: (fill: 0xAAB3BF, edge: 0x4A525C, hi: 0xE4E9EF, lo: 0x7D8793),
        eye: (dim: 0xD5DADB, bright: 0xFFFFFF),
        above: orlanHardware(),
        dynamics: [
            HDynamic(draws: [paint(oval(-138, -48, 13, 13), 0xF2D16B)], channel: .led, opacity: HRamp(0.55, 1)),
            // The lamp comes on, swelling a little, and the camera finds its focus.
            HDynamic(draws: [paint(oval(-138, -48, 13, 13), 0xFFF3B0)], channel: .gesture(0),
                     opacity: HRamp(0, 1), scale: HRamp(1, 1.5), pivot: CGPoint(x: -138, y: -48)),
            HDynamic(draws: [paint(oval(140, -48, 11, 11), 0x9FD0FF)], channel: .gesture(0),
                     opacity: HRamp(0, 1), scale: HRamp(0.6, 1.3), pivot: CGPoint(x: 140, y: -48)),
            // Gesture 2: the camera clicks, with a ring of light that opens and fades.
            HDynamic(draws: [paint(oval(140, -48, 13, 13), 0xCFE8FF)], channel: .gesture(2), opacity: HRamp(0, 1)),
            HDynamic(draws: [stroke(oval(140, -48, 20, 20), 0xFFFFFF, 4)], channel: .gesture(2),
                     opacity: HRamp(0, 1), scale: HRamp(0.6, 2.8), pivot: CGPoint(x: 140, y: -48),
                     pulse: HPulse(center: 0.5, width: 0.5)),
        ]
            // Gesture 1: a light runs once round the porthole, clockwise from the top.
            + chase(HShape.spans(oval(0, -6, 246, 112)), hex: 0xEAF6FF, width: 9, gesture: 1)
            // Gesture 3: the lamp lights and its beam sweeps down the face, both brightest half way.
            + [HDynamic(draws: [paint(oval(-138, -48, 13, 13), 0xFFF3B0)], channel: .gesture(3),
                        opacity: HRamp(0, 1), scale: HRamp(1, 1.5), pivot: CGPoint(x: -138, y: -48),
                        pulse: HPulse(center: 0.5, width: 0.5)),
               HDynamic(draws: [paint(poly([(-138, -48), (182, -110), (182, 14)]), 0xFFF3B0, 0.30, clip: true)],
                        channel: .gesture(3), opacity: HRamp(0, 1), rotation: HRamp(-12, 42),
                        pivot: CGPoint(x: -138, y: -48), pulse: HPulse(center: 0.5, width: 0.5))]
    )

    /// Nearly black, a single white line, an iridium-blue visor. The darkest.
    /// The signature is a glint that sweeps the glass.
    static let stealth = astronaut(
        base: 0x141519, light: 0x2B2D34, shade: 40, rim: 0x07080A, rimWidth: 12,
        bands: [stroke(curve([(-166, -66), (-80, -92), (80, -92), (166, -66)]), 0xE6E6E6, 3.4, clip: true)],
        window: box(0, -7, 250, 106, 46), top: -60, bottom: 46, width: 250,
        visor: (fill: 0x3F6F98, edge: 0x16293B, hi: 0x6EA2CC, lo: 0x2A4F70),
        eye: (dim: 0xE9E4D6, bright: 0xFFFDF4),
        above: stealthHardware(),
        dynamics: [
            HDynamic(draws: [paint(oval(122, 70, 9, 9), 0xE6E6E6)], channel: .led, opacity: HRamp(0.45, 1)),
            // A slanted band of light, from just off the left of the glass to just
            // off the right, clipped to the window, so it spends most of the
            // sweep on the glass; and the pinstripe flashes blue as it goes.
            HDynamic(draws: [paint(poly([(-22, -70), (22, -70), (2, 70), (-42, 70)]), 0xFFFFFF, 0.28)],
                     channel: .gesture(0), offsetX: HRamp(-175, 175), insideWindow: true),
            // It lights as the glint crosses the middle and is gone again when it leaves,
            // so the instant reset at the end of the sweep has nothing to cut off.
            HDynamic(draws: [stroke(curve([(-166, -66), (-80, -92), (80, -92), (166, -66)]), 0x9FD4FF, 5, clip: true)],
                     channel: .gesture(0), opacity: HRamp(0, 1), pulse: HPulse(center: 0.5, width: 0.5)),
            // Gesture 1: a line of light scans the window from top to bottom.
            HDynamic(draws: [paint(box(0, -67, 250, 9), 0x8FD8FF, 0.75)], channel: .gesture(1), opacity: HRamp(0, 1),
                     offsetY: HRamp(0, 116), insideWindow: true, pulse: HPulse(center: 0.5, width: 0.5)),
            // Gesture 2: the visor strip flashes while the eyes read down the glass.
            HDynamic(draws: [paint(box(0, -49.4, 250, 21.2), 0x9FE6FF, 0.6)], channel: .gesture(2),
                     opacity: HRamp(0, 1), insideWindow: true),
            // Gesture 3: targeting brackets close on the right eye while the eyes narrow.
            HDynamic(draws: [stroke(together([
                        poly([(36, -43), (16, -43), (16, -23)], closed: false),
                        poly([(60, -43), (80, -43), (80, -23)], closed: false),
                        poly([(36, 29), (16, 29), (16, 9)], closed: false),
                        poly([(60, 29), (80, 29), (80, 9)], closed: false),
                     ]), 0x9FD4FF, 10)],
                     channel: .gesture(3), opacity: HRamp(0, 1), scale: HRamp(1.55, 1),
                     pivot: CGPoint(x: 48, y: -7), insideWindow: true),
        ]
    )

    /// Black with a papaya band, a white pinstripe, a seven, and a visor with a
    /// notch for the nose. The tab on the visor flicks, and the sun visor dips so
    /// its papaya edge comes down into the window and flashes.
    static let papaya = racer(
        base: 0x17181B, light: 0x2F3138,
        livery: [
            stroke(curve([(-170, -34), (-90, -72), (0, -84), (90, -72), (170, -34)]), 0xF1F1F1, 4, clip: true),
            stroke(curve([(-170, -50), (-90, -88), (0, -100), (90, -88), (170, -50)]), 0xFF7A00, 18, clip: true),
            paint(poly([(-160, 46), (-120, 26), (-100, 60), (-132, 116), (-170, 116)]), 0xFF7A00, clip: true),
            stroke(poly([(-96, 28), (-70, 78), (-52, 116)], closed: false), 0xF1F1F1, 4, clip: true),
        ],
        window: curve([
            (-124, -26), (-104, -60), (0, -66), (104, -60), (124, -26), (118, 32),
            (86, 42), (26, 40), (0, 26), (-26, 40), (-86, 42), (-118, 32),
        ], closed: true, 0.1),
        top: -68, bottom: 44, width: 248, eyeY: -14,
        plate: (fill: 0x1F2126, edge: 0xFF7A00, flash: 0xFFD9A0),
        eye: (dim: 0xE7DFCF, bright: 0xFFFAF0),
        above: papayaHardware(),
        dynamics: [
            HDynamic(draws: [paint(box(100, -72, 32, 12, 5), 0x2A2C33)], channel: .gesture(0),
                     rotation: HRamp(-12, -50), pivot: CGPoint(x: 84, y: -72)),
            // Gesture 1: the number shines, ringed in papaya, and swells a little.
            HDynamic(draws: [stroke(oval(112, 74, 44, 44), 0xFF7A00, 5)], channel: .gesture(1),
                     opacity: HRamp(0, 1), scale: HRamp(1, 1.18), pivot: CGPoint(x: 112, y: 74)),
            // Gesture 2: the cheek flash lights with the engine.
            HDynamic(draws: [paint(poly([(-160, 46), (-120, 26), (-100, 60), (-132, 116), (-170, 116)]), 0xFFD9A0, clip: true)],
                     channel: .gesture(2), opacity: HRamp(0, 0.85)),
            // Gesture 3: a wink. A lid, in the colour of the glass, slides down over the left eye.
            HDynamic(draws: [paint(box(-48, -14, 44, 52, 9), 0x0D0E11)], channel: .gesture(3),
                     opacity: HRamp(0, 1), offsetY: HRamp(-34, 0), insideWindow: true),
            HDynamic(draws: [paint(box(-48, 10, 34, 5, 2.5), 0x3A3D45)], channel: .gesture(3),
                     opacity: HRamp(0, 1), offsetY: HRamp(-34, 0), insideWindow: true),
        ],
        visorNudge: 0.2
    )

    /// Matt gunmetal, hi-vis chevrons, a sun strip that never goes away. The
    /// signature is a pit-lane strobe.
    static let endurance = racer(
        base: 0x2A2D32, light: 0x42464D, shade: 38,
        livery: [
            stroke(curve([(-176, -44), (0, -106), (176, -44)]), 0xD8FF1A, 9, clip: true),
            stroke(curve([(-176, -28), (0, -90), (176, -28)]), 0x050607, 9, clip: true),
            stroke(curve([(-176, -12), (0, -74), (176, -12)]), 0xD8FF1A, 9, clip: true),
        ],
        window: box(0, -8, 262, 104, 48), top: -60, bottom: 44, width: 262, eyeY: -4,
        glass: 0x1D4259, rim: 0x0E0F12, restFraction: 0.2,
        plate: (fill: 0x0F1013, edge: 0xD8FF1A, flash: 0xF4FFB0),
        eye: (dim: 0xE6F6B4, bright: 0xFBFFE6),
        above: enduranceHardware(),
        dynamics: [
            HDynamic(draws: [
                stroke(curve([(-176, -44), (0, -106), (176, -44)]), 0xF4FFB0, 9, clip: true),
                stroke(curve([(-176, -12), (0, -74), (176, -12)]), 0xF4FFB0, 9, clip: true),
            ], channel: .gesture(0), opacity: HRamp(0, 1)),
            HDynamic(draws: [stroke(oval(-112, 70, 40, 40), 0xFFFFFF, 4.5)], channel: .gesture(0), opacity: HRamp(0, 1)),
        ]
            // Gesture 2: a light runs along both lime chevrons, left to right.
            + enduranceChase()
            // Gesture 3: the lights of a car behind fill the visor and the eyes look away.
            + [HDynamic(draws: [paint(box(0, -8, 280, 124), 0xDFF6FF, 0.42)], channel: .gesture(3),
                        opacity: HRamp(0, 1), insideWindow: true)],
        visorNudge: 0.3, visorGesture: 1
    )
}

// MARK: - Hardware
//
// Built a step at a time rather than as one long sum of arrays: a dozen calls
// joined with `+` is the kind of expression the type checker gives up on.

private func apolloHardware() -> [HDraw] {
    var parts: [HDraw] = []
    parts.append(paint(box(-139, -6, 16, 38, 5), 0x17181C))
    parts.append(paint(box(139, -6, 16, 38, 5), 0x17181C))
    parts += screw(-139, -14, ring: 0x3A3D44, dot: 0x17181C)
    parts += screw(139, 2, ring: 0x3A3D44, dot: 0x17181C)
    parts.append(stroke(curve([(-116, 90), (0, 106), (116, 90)]), 0x17181C, 4))
    parts.append(stroke(oval(122, 70, 26, 26), 0x17181C, 4))
    return parts
}

private func orlanHardware() -> [HDraw] {
    var parts: [HDraw] = []
    parts.append(paint(box(136, -48, 36, 26, 5), 0x15161A))
    parts.append(paint(oval(140, -48, 13, 13), 0x46586A))
    parts.append(stroke(oval(140, -48, 20, 20), 0x3A3D44, 2.4))
    parts.append(paint(oval(-138, -48, 24, 24), 0x15161A))
    parts += screw(-143, 8, ring: 0x3A3D44, dot: 0x15161A)
    parts += screw(143, 8, ring: 0x3A3D44, dot: 0x15161A)
    parts.append(stroke(curve([(-116, 92), (0, 108), (116, 92)]), 0x15161A, 5))
    return parts
}

private func stealthHardware() -> [HDraw] {
    var left: [HPath] = []
    var right: [HPath] = []
    for row in 0..<3 {
        let y = 6 + CGFloat(row) * 9
        left.append(box(-142, y, 16, 4.6, 2.3))
        right.append(box(142, y, 16, 4.6, 2.3))
    }
    var parts: [HDraw] = []
    parts.append(paint(together(left), 0x07080A))
    parts.append(paint(together(right), 0x07080A))
    parts.append(stroke(oval(122, 70, 26, 26), 0xE6E6E6, 3.4))
    parts.append(stroke(curve([(-116, 90), (0, 106), (116, 90)]), 0x07080A, 4))
    return parts
}

private func papayaHardware() -> [HDraw] {
    var parts: [HDraw] = []
    parts += screw(-141, -6, ring: 0x2A2C33, dot: 0x101113)
    parts += screw(141, -6, ring: 0x2A2C33, dot: 0x101113)
    parts += badge(112, 74, radius: 22, fill: 0xF1F1F1, ink: 0x17181B)
    parts.append(vents(70))
    return parts
}

private func enduranceHardware() -> [HDraw] {
    var parts: [HDraw] = []
    parts += screw(-141, -6, ring: 0x3A3E45, dot: 0x0E0F12)
    parts += screw(141, -6, ring: 0x3A3E45, dot: 0x0E0F12)
    parts += badge(-112, 70, radius: 20, fill: 0x07080A, ink: 0xD8FF1A, ring: 0xD8FF1A)
    parts.append(vents(84))
    return parts
}

/// The lime chevrons lit half at a time, left then right, so a light runs across.
private func enduranceChase() -> [HDynamic] {
    let upper = HShape.spans(curve([(-176, -44), (0, -106), (176, -44)]))
    let lower = HShape.spans(curve([(-176, -12), (0, -74), (176, -12)]))
    return (0..<min(upper.count, lower.count)).map { index in
        HDynamic(
            draws: [stroke(upper[index], 0xF4FFB0, 9, clip: true), stroke(lower[index], 0xF4FFB0, 9, clip: true)],
            channel: .gesture(2), opacity: HRamp(0, 1),
            pulse: HPulse(center: CGFloat(index + 1) / 3, width: 1.0 / 3)
        )
    }
}
