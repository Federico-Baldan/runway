// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// The second four gestures of the first five helmets (channels 4 to 7), kept next
// to each other and away from `HelmetSpec`, where the helmets themselves are
// drawn: the sum of nine arrays in one `dynamics:` argument is the kind of
// expression the type checker gives up on, and a helmet's drawing is long enough.
//
// Each of them is a thing the real object does, or a thing that happens to it,
// and not a decoration: Earth rising in a visor, a camera swivelling, a chequered
// flag, a bug on the glass. They are drawn in the same flat vocabulary as the rest
// (no gradient, no glow) and their parts rest invisible or out of sight.

enum HelmetOriginals {
    static func dynamics(for style: AvatarStyle) -> [HDynamic] {
        switch style {
        case .apollo: return apolloDynamics
        case .orlan: return orlanDynamics
        case .stealth: return stealthDynamics
        case .papaya: return papayaDynamics
        case .endurance: return enduranceDynamics
        default: return []
        }
    }

    static func gestures(for style: AvatarStyle) -> [[SignatureStep]] {
        switch style {
        case .apollo: return apolloGestures
        case .orlan: return orlanGestures
        case .stealth: return stealthGestures
        case .papaya: return papayaGestures
        case .endurance: return enduranceGestures
        default: return []
        }
    }

    // MARK: - Apollo

    private static let apolloDynamics: [HDynamic] = {
        var parts: [HDynamic] = []
        // 4: the orange band flares, pale over orange.
        parts.append(hLamp([hLine(hCurve([(-166, -64), (-80, -94), (80, -94), (166, -64)]), 0xFFE2B8, 8, clip: true)], gesture: 4))
        // 5: the connector sends a message: its ring and its light, in mint.
        parts.append(hLamp([hLine(hOval(122, 70, 26, 26), 0xB6FFD2, 5), hFill(hOval(122, 70, 12, 12), 0xB6FFD2)], gesture: 5))
        // 6: Earth rises from under the left of the visor: blue, one green land, one cloud.
        parts.append(HDynamic(
            draws: [
                hFill(hOval(-92, 78, 38, 38), 0x2F6FD6),
                hFill(hPoly([(-102, 70), (-92, 66), (-84, 74), (-88, 84), (-100, 82)]), 0x4FB06A),
                hLine(hCurve([(-106, 76), (-94, 72), (-80, 80)]), 0xF2F6FF, 3.4),
            ],
            channel: .gesture(6), offsetY: HRamp(0, -80), insideWindow: true
        ))
        // 7: the glass fogs over, with the breath.
        parts.append(hLamp([hFill(hBox(0, -6, 260, 128), 0xDDE8EE, 0.32)], gesture: 7, inside: true))
        return parts
    }()

    private static let apolloGestures: [[SignatureStep]] = [
        // The band flares twice, like a beacon, and the eyes widen.
        [
            hs(0.05, hold: 0.07, ch: 4, lv: 1, dil: 1.15),
            hs(0.07, hold: 0.06, .easeIn, ch: 4, lv: 0),
            hs(0.05, hold: 0.07, ch: 4, lv: 1),
            hs(0.12, .easeIn, ch: 4, lv: 0, dil: 1),
        ],
        // The connector sends a message in Morse, dot dot dash, and the eyes watch it.
        [
            hs(0.04, hold: 0.05, ch: 5, lv: 1, gx: 0.6, gy: 0.6),
            hs(0.04, hold: 0.05, .easeIn, ch: 5, lv: 0),
            hs(0.04, hold: 0.05, ch: 5, lv: 1),
            hs(0.04, hold: 0.05, .easeIn, ch: 5, lv: 0),
            hs(0.05, hold: 0.18, ch: 5, lv: 1),
            hs(0.08, .easeIn, ch: 5, lv: 0, gx: 0, gy: 0),
        ],
        // Earth comes up over the rim of the visor and the eyes follow it up.
        [
            hs(0.14, ch: 6, lv: 0.5, gx: -0.5, gy: 0.5),
            hs(0.14, hold: 0.22, ch: 6, lv: 1, gx: -0.5, gy: -0.2),
            hs(0.18, .easeIn, ch: 6, lv: 0, gx: 0, gy: 0),
        ],
        // The visor fogs over, and clears.
        [
            hs(0.16, hold: 0.2, ch: 7, lv: 1, dil: 0.9),
            hs(0.22, .easeInOut, ch: 7, lv: 0, dil: 1),
        ],
    ]

    // MARK: - Orlan

    /// The camera, as a part that can swivel. It is drawn as the first dynamic, so
    /// the light and the ring that gestures 0 and 2 put on it come over it.
    static let orlanCamera = HDynamic(
        draws: [
            hFill(hBox(136, -48, 36, 26, 5), 0x15161A),
            hFill(hOval(140, -48, 13, 13), 0x46586A),
            hLine(hOval(140, -48, 20, 20), 0x3A3D44, 5.6),
        ],
        channel: .gesture(4), rotation: HRamp(0, -24), pivot: CGPoint(x: 136, y: -48)
    )

    private static let orlanDynamics: [HDynamic] = {
        var parts: [HDynamic] = []
        // 4, the cone: what the camera sees, a pale wedge that swings with it and the eyes follow.
        parts.append(HDynamic(
            draws: [hFill(hPoly([(140, -48), (-30, -104), (-30, 8)]), 0x9FD0FF, 0.24, clip: true)],
            channel: .gesture(4), opacity: HRamp(0, 1), rotation: HRamp(0, -24), pivot: CGPoint(x: 140, y: -48)
        ))
        // 5: a satellite crosses the porthole, from the upper left to the lower right,
        // a body between two solar panels. At rest it is off the glass on the left.
        // Everything a part draws is inside the canvas (312 x 224) at rest: a Canvas
        // clips to its frame, so what is outside it is never drawn, however far it is moved.
        let at: (CGFloat, CGFloat) = (-126, -44)
        parts.append(HDynamic(
            draws: [
                hFill(hBox(at.0 - 20, at.1, 18, 9), 0x4F86D8),
                hFill(hBox(at.0 + 20, at.1, 18, 9), 0x4F86D8),
                hFill(hBox(at.0, at.1, 15, 13, 2), 0xE9EEF3),
            ],
            channel: .gesture(5), offsetX: HRamp(0, 300), offsetY: HRamp(0, 70), insideWindow: true
        ))
        // 6: the ends of the red band flash in turn, left and right.
        let spans = HShape.spans(hCurve([(-166, -74), (-80, -90), (80, -90), (166, -74)]))
        parts.append(hGlow([hLine(spans[0], 0xFF9E92, 9, clip: true)], gesture: 6, center: 1.0 / 3, width: 1.0 / 3))
        parts.append(hGlow([hLine(spans[2], 0xFF9E92, 9, clip: true)], gesture: 6, center: 2.0 / 3, width: 1.0 / 3))
        // 7: the seal screws light green, both, twice.
        parts.append(hLamp([hFill(hTogether([hOval(-143, 8, 22, 22), hOval(143, 8, 22, 22)]), 0x7CFFB0)], gesture: 7))
        return parts
    }()

    private static let orlanGestures: [[SignatureStep]] = [
        // The camera swivels towards the lamp and searches, and the eyes follow it.
        [
            hs(0.10, hold: 0.04, ch: 4, lv: 1, gx: 0.8, gy: -0.2),
            hs(0.10, hold: 0.03, .easeInOut, ch: 4, lv: 0.25),
            hs(0.10, hold: 0.06, .easeInOut, ch: 4, lv: 0.8, gx: 0.8, gy: 0.1),
            hs(0.14, .easeInOut, ch: 4, lv: 0, gx: 0, gy: 0),
        ],
        // A satellite crosses the window and the eyes follow it, left to right.
        [
            hs(0.04, hold: 0.03, gx: -0.7, gy: -0.3),
            hs(0.17, .linear, ch: 5, lv: 0.5, gx: 0, gy: -0.05),
            hs(0.17, .linear, ch: 5, lv: 1, gx: 0.7, gy: 0.2),
            hReset(5),
            hs(0.08, gx: 0, gy: 0),
        ],
        // The warning band flashes left, right, left, right, and the eyes flick with it.
        [
            hs(0.07, .linear, ch: 6, lv: 1.0 / 3, gx: -0.6, gy: -0.4),
            hs(0.07, .linear, ch: 6, lv: 2.0 / 3, gx: 0.6, gy: -0.4),
            hs(0.07, .linear, ch: 6, lv: 1.0 / 3, gx: -0.6, gy: -0.4),
            hs(0.07, .linear, ch: 6, lv: 2.0 / 3, gx: 0.6, gy: -0.4),
            hs(0.10, .linear, ch: 6, lv: 1, gx: 0, gy: 0),
            hReset(6),
        ],
        // The seals check out: both screws light green twice.
        [
            hs(0.06, hold: 0.10, ch: 7, lv: 1, dil: 1.15),
            hs(0.07, hold: 0.06, .easeIn, ch: 7, lv: 0),
            hs(0.06, hold: 0.10, ch: 7, lv: 1),
            hs(0.12, .easeIn, ch: 7, lv: 0, dil: 1),
        ],
    ]

    // MARK: - Stealth

    private static let stealthDynamics: [HDynamic] = {
        var parts: [HDynamic] = []
        // 4: a radar arm sweeps the glass from the left to the right about the middle
        // of the window, brightest straight up.
        parts.append(HDynamic(
            draws: [hLine(hPoly([(0, -7), (0, -108)], closed: false), 0x8FD8FF, 8)],
            channel: .gesture(4), opacity: HRamp(0, 1), rotation: HRamp(-80, 80),
            pivot: CGPoint(x: 0, y: -7), insideWindow: true, pulse: HPulse(center: 0.5, width: 0.5)
        ))
        // 5: a reticle closes on the middle of the window.
        let ticks = hTogether([
            hPoly([(0, -40), (0, -27)], closed: false), hPoly([(0, 26), (0, 13)], closed: false),
            hPoly([(-33, -7), (-20, -7)], closed: false), hPoly([(33, -7), (20, -7)], closed: false),
        ])
        parts.append(HDynamic(
            draws: [hLine(hOval(0, -7, 44, 44), 0x9FD4FF, 6), hLine(ticks, 0x9FD4FF, 6)],
            channel: .gesture(5), opacity: HRamp(0, 1), scale: HRamp(1.6, 1),
            pivot: CGPoint(x: 0, y: -7), insideWindow: true
        ))
        // 6: the link light of the connector.
        parts.append(hLamp([hLine(hOval(122, 70, 26, 26), 0x9FD4FF, 7), hFill(hOval(122, 70, 9, 9), 0x9FD4FF)], gesture: 6))
        // 7: two readouts, three lines of text each, on the left of the glass and then on the right.
        let left = hTogether([hBox(-100, -30, 36, 8, 3), hBox(-104, -16, 28, 8, 3), hBox(-98, -2, 40, 8, 3)])
        let right = hTogether([hBox(100, -30, 32, 8, 3), hBox(96, -16, 40, 8, 3), hBox(104, -2, 24, 8, 3)])
        parts.append(hGlow([hFill(left, 0xA9DAFF, 0.9)], gesture: 7, center: 1.0 / 3, width: 1.0 / 3, inside: true))
        parts.append(hGlow([hFill(right, 0xA9DAFF, 0.9)], gesture: 7, center: 2.0 / 3, width: 1.0 / 3, inside: true))
        return parts
    }()

    private static let stealthGestures: [[SignatureStep]] = [
        // A radar arm sweeps the glass and the eyes follow it across.
        [
            hs(0.10, .linear, ch: 4, lv: 0.25, gx: -0.6, gy: 0),
            hs(0.10, .linear, ch: 4, lv: 0.5, gx: 0, gy: 0),
            hs(0.10, .linear, ch: 4, lv: 0.75, gx: 0.6, gy: 0),
            hs(0.10, .linear, ch: 4, lv: 1, gx: 0, gy: 0),
            hReset(4),
        ],
        // A reticle closes on the middle of the window while the eyes narrow.
        [
            hs(0.12, hold: 0.16, ch: 5, lv: 1, dil: 0.85),
            hs(0.14, .easeIn, ch: 5, lv: 0, dil: 1),
        ],
        // The link light blinks twice and the eyes glance down at it.
        [
            hs(0.05, hold: 0.08, ch: 6, lv: 1, gx: 0.7, gy: 0.6),
            hs(0.06, hold: 0.06, .easeIn, ch: 6, lv: 0),
            hs(0.05, hold: 0.10, ch: 6, lv: 1),
            hs(0.12, .easeIn, ch: 6, lv: 0, gx: 0, gy: 0),
        ],
        // Two readouts come up on the glass, the eyes reading each in turn.
        [
            hs(0.06, hold: 0.12, ch: 7, lv: 1.0 / 3, gx: -0.8, gy: -0.1),
            hs(0.08, hold: 0.12, ch: 7, lv: 2.0 / 3, gx: 0.8, gy: -0.1),
            hs(0.10, ch: 7, lv: 1, gx: 0, gy: 0),
            hReset(7),
        ],
    ]

    // MARK: - Papaya

    private static let papayaDynamics: [HDynamic] = {
        var parts: [HDynamic] = []
        // 4: the five red lights of a race start, in the top of the glass.
        let lights = hTogether([-80, -40, 0, 40, 80].map { hOval($0, -50, 16, 16) })
        parts.append(hLamp([hFill(lights, 0xFF3B30)], gesture: 4, inside: true))
        // 5: a chequered flag crosses the glass: two rows of squares, six across, that
        // fades in on the left, crosses, and fades out on the right.
        var squares: [HPath] = []
        for column in 0..<6 {
            for row in 0..<2 where (column + row) % 2 == 0 {
                squares.append(hBox(-120 + CGFloat(column) * 20, -16 + CGFloat(row) * 20, 20, 20))
            }
        }
        parts.append(HDynamic(
            draws: [hFill(hTogether(squares), 0xF1F1F1)],
            channel: .gesture(5), opacity: HRamp(0, 1), offsetX: HRamp(0, 240), insideWindow: true,
            pulse: HPulse(center: 0.5, width: 0.5)
        ))
        // 6: three drops of rain run down the glass, each its own way.
        for (x, y, run) in [(-72, -52, 44), (6, -40, 64), (78, -50, 50)] as [(CGFloat, CGFloat, CGFloat)] {
            parts.append(HDynamic(
                draws: [hFill(hOval(x, y, 15, 22), 0xCFEAFF, 0.95)],
                channel: .gesture(6), opacity: HRamp(0, 1), offsetY: HRamp(0, run),
                insideWindow: true, pulse: HPulse(center: 0.5, width: 0.5)
            ))
        }
        // 7: the number becomes a one: a white disc over the seven, a dark one on it, ringed in papaya.
        parts.append(HDynamic(
            draws: [
                hFill(hOval(112, 74, 44, 44), 0xF1F1F1),
                hFill(hPoly([(104, 66), (112, 60), (120, 60), (120, 88), (111, 88), (111, 69), (104, 72)]), 0x17181B),
                hLine(hOval(112, 74, 44, 44), 0xFF7A00, 5),
            ],
            channel: .gesture(7), opacity: HRamp(0, 1)
        ))
        return parts
    }()

    private static let papayaGestures: [[SignatureStep]] = [
        // The start lights come on, the eyes look up at them, they go out and the eyes are away.
        [
            hs(0.10, hold: 0.28, ch: 4, lv: 1, gx: 0, gy: -0.8),
            hs(0.03, .easeIn, ch: 4, lv: 0, gx: 0.9, gy: 0),
            hs(0.10, gx: 0, gy: 0),
        ],
        // The chequered flag, with the eyes on it.
        [
            hs(0.04, hold: 0.03, gx: -0.8, gy: 0),
            hs(0.12, .linear, ch: 5, lv: 0.33, gx: -0.3, gy: 0),
            hs(0.12, .linear, ch: 5, lv: 0.5, gx: 0, gy: 0),
            hs(0.12, .linear, ch: 5, lv: 1, gx: 0.8, gy: 0),
            hReset(5),
            hs(0.08, gx: 0, gy: 0),
        ],
        // It rains: the drops run down the glass and the eyes narrow.
        [
            hs(0.12, hold: 0.06, ch: 6, lv: 0.5, dil: 0.85),
            hs(0.16, .easeIn, ch: 6, lv: 1, dil: 1),
            hReset(6),
        ],
        // The number goes to a one, and the eyes glance down at it.
        [
            hs(0.06, hold: 0.24, ch: 7, lv: 1, gx: 0.6, gy: 0.6, dil: 1.15),
            hs(0.10, .easeIn, ch: 7, lv: 0, gx: 0, gy: 0, dil: 1),
        ],
    ]

    // MARK: - Endurance

    private static let enduranceDynamics: [HDynamic] = {
        var parts: [HDynamic] = []
        // 4: the lower chevron advances: a pale copy of it runs up over the black one and goes.
        parts.append(HDynamic(
            draws: [hLine(hCurve([(-176, -12), (0, -74), (176, -12)]), 0xF4FFB0, 9, clip: true)],
            channel: .gesture(4), opacity: HRamp(0, 1), offsetY: HRamp(0, -16),
            pulse: HPulse(center: 0.5, width: 0.5)
        ))
        // 5: the three vents light lime from the top down.
        for row in 0..<3 {
            parts.append(hGlow(
                [hFill(hBox(0, 84 + CGFloat(row) * 11, 46, 8, 4), 0xE6F6B4, clip: true)],
                gesture: 5, center: CGFloat(row + 1) / 4, width: 0.25
            ))
        }
        // 6: a bug hits the visor: a lime splat on the right, with a drip, that lands from large to life size.
        var rim: [(CGFloat, CGFloat)] = []
        let radii: [Double] = [27, 13, 19, 12, 29, 14, 18, 11, 24, 13]
        for (k, r) in radii.enumerated() {
            let a = Double(k) * 36 * Double.pi / 180
            rim.append((64 + CGFloat(r * cos(a)), -28 + CGFloat(r * sin(a))))
        }
        parts.append(HDynamic(
            draws: [hFill(hPoly(rim), 0xD2E04A, 0.92), hFill(hBox(64, 8, 7, 32, 3.5), 0xD2E04A, 0.92)],
            channel: .gesture(6), opacity: HRamp(0, 1), scale: HRamp(1.5, 1),
            pivot: CGPoint(x: 64, y: -28), insideWindow: true
        ))
        // 7: the badge inverts, lime with a dark seven, twice.
        let seven = HShape.translated(
            hPoly([(-10, -11), (11, -11), (11, -5), (0, 13), (-8, 13), (2, -3), (-10, -3)]), dx: -112, dy: 70
        )
        parts.append(hLamp([hFill(hOval(-112, 70, 38, 38), 0xD8FF1A), hFill(seven, 0x07080A)], gesture: 7))
        return parts
    }()

    private static let enduranceGestures: [[SignatureStep]] = [
        // The chevron advances, twice.
        hWalk([0.5, 1], ch: 4, each: 0.09) + hWalk([0.5, 1], ch: 4, each: 0.09),
        // The vents light from the top down and the eyes look down with them.
        [
            hs(0.09, .linear, ch: 5, lv: 0.25, gx: 0, gy: 0.7),
            hs(0.09, .linear, ch: 5, lv: 0.5),
            hs(0.09, .linear, ch: 5, lv: 0.75),
            hs(0.09, .linear, ch: 5, lv: 1, gx: 0, gy: 0),
            hReset(5),
        ],
        // A bug hits the visor: the eyes widen, squint at the splat, and it is wiped.
        [
            hs(0.05, hold: 0.10, ch: 6, lv: 1, dil: 1.2),
            hs(0.06, hold: 0.12, dil: 0.8),
            hs(0.20, .easeIn, ch: 6, lv: 0, dil: 1),
        ],
        // The badge inverts twice, and the eyes glance down to it.
        [
            hs(0.05, hold: 0.08, ch: 7, lv: 1, gx: -0.6, gy: 0.7),
            hs(0.07, hold: 0.06, .easeIn, ch: 7, lv: 0),
            hs(0.05, hold: 0.10, ch: 7, lv: 1),
            hs(0.12, .easeIn, ch: 7, lv: 0, gx: 0, gy: 0),
        ],
    ]
}
