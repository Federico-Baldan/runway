// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Batch 4: a kendo men, a murmillo's helmet, a hounskull bascinet and the
// spectacle helmet from Gjermundbu.

extension HelmetCollection {
    static let batch4: [(AvatarStyle, HelmetEntry)] = [
        (.kendo, kendoHelmet()),
        (.murmillo, murmilloHelmet()),
        (.bascinet, bascinetHelmet()),
        (.gjermundbu, gjermundbuHelmet()),
    ]
}

// MARK: - Kendo

/// A kendo men: the indigo cloth crown with its stitching, the steel grille over the
/// face, the padded flaps that fan out over the shoulders, the throat guard that hangs
/// below. The face towel under the grille is the lid.
private func kendoHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -100, 0), (58, -96, 30), (96, -62, 26), (104, -26, 4), (104, 56, 10), (86, 76, 6), (72, 92, 10), (0, 92, 0),
    ])
    let flapR = hRound([(100, -22, 6), (148, -8, 12), (154, 44, 14), (130, 70, 10), (98, 56, 4)])
    let flapL = hMirror(flapR)
    let steel: UInt32 = 0xC9CED8
    let bars: [CGFloat] = [-46, -26, 32, 52]
    let barPath: (CGFloat) -> HPath = { y in hPoly([(-86, y), (86, y)], closed: false) }
    let stitches: [[CGFloat]] = [[0], [-30, 30], [-60, 60]]
    let throat = hRound([(-30, 90, 4), (30, 90, 4), (26, 102, 8), (0, 106, 6), (-26, 102, 8)])

    var livery: [HDraw] = []
    for group in stitches {
        for x in group { livery.append(hLine(hPoly([(x, -100), (x * 1.15, -48)], closed: false), 0x5568A0, 6, clip: true)) }
    }
    livery.append(hFill(hBox(0, 80, 170, 30), 0x151B30, clip: true))

    // The grille: four horizontal bars of steel and one upright, over the face.
    var above: [HDraw] = []
    above.append(hLine(hTogether(bars.map(barPath)), steel, 7))
    above.append(hLine(hPoly([(0, -52), (0, 58)], closed: false), steel, 7))

    var dynamics: [HDynamic] = []
    // Gesture 0: the grille rings, bar by bar from the top.
    for (index, y) in bars.enumerated() {
        dynamics.append(hGlow([hLine(barPath(y), 0xFFFFFF, 7)], gesture: 0, center: CGFloat(index + 1) / 5, width: 0.2))
    }
    // Gesture 1: the shoulder flaps bob with a bow of the head.
    dynamics.append(HDynamic(draws: [hFill(flapR, 0x232C52), hLine(flapR, 0xBCCBF0, 7), hLine(hPoly([(108, 8), (140, 14)], closed: false), 0x5568A0, 6)],
                             channel: .gesture(1), offsetY: HRamp(0, 8)))
    dynamics.append(HDynamic(draws: [hFill(flapL, 0x232C52), hLine(flapL, 0xBCCBF0, 7), hLine(hPoly([(-108, 8), (-140, 14)], closed: false), 0x5568A0, 6)],
                             channel: .gesture(1), offsetY: HRamp(0, 8)))
    // Gesture 2: the throat guard swings from its top.
    dynamics.append(HDynamic(draws: [hFill(throat, 0x2B3560), hLine(throat, 0xBCCBF0, 6)], channel: .gesture(2),
                             rotation: HRamp(0, 22), pivot: CGPoint(x: 0, y: 90)))
    // Gesture 3: the stitching of the crown lights from the middle out.
    for (index, group) in stitches.enumerated() {
        let path = hTogether(group.map { hPoly([($0, -100), ($0 * 1.15, -48)], closed: false) })
        dynamics.append(hGlow([hLine(path, 0xE6EDFF, 6, clip: true)], gesture: 3, center: CGFloat(index + 1) / 4, width: 0.25))
    }

    let spec = hHelmet(
        shell: shell, base: 0x1C2440, light: 0x3B4A7A,
        lightPath: hCurve([(-100, -30), (-94, -66), (-58, -94), (-26, -98)]), edge: 0xB4C6F2,
        livery: livery,
        window: hBox(0, 4, 168, 96, 28), top: -44, bottom: 52, width: 168,
        glass: 0x0A0C14, rim: 0x0A0D18, rimWidth: 10,
        eyes: (w: 28, h: 30, y: 4, dx: 40, tx: 10, ty: 5, dim: 0xF0F2FA, bright: 0xFFFFFF),
        plate: (fill: 0x2B3560, edge: 0x9FB2E6, width: 4, deco: [hFill(hPoly([(-80, -48), (-46, -48), (-66, 48), (-100, 48)]), 0x3A4880)]),
        above: above, dynamics: dynamics
    )
    let gestures: [[SignatureStep]] = [
        // The grille rings, bar by bar.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 0, each: 0.08),
        // The head bows and the flaps bob.
        [
            hs(0.1, hold: 0.04, ch: 1, lv: 1, gx: 0, gy: 0.8),
            hs(0.14, hold: 0.02, .easeInOut, ch: 1, lv: 0, gx: 0, gy: 0),
        ],
        // The throat guard swings out and back.
        [
            hs(0.1, hold: 0.1, ch: 2, lv: 1),
            hs(0.18, .easeInOut, ch: 2, lv: 0),
        ],
        // The stitching lights from the middle outwards and the eyes widen: a kiai.
        [
            hs(0.1, .linear, ch: 3, lv: 0.25, dil: 1.2),
            hs(0.1, .linear, ch: 3, lv: 0.5),
            hs(0.1, .linear, ch: 3, lv: 0.75),
            hs(0.1, .linear, ch: 3, lv: 1, dil: 1),
            hReset(3),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Kendo men: indigo crown, steel grille (mengane), shoulder flaps, throat guard (tsuki-dare)")
}

// MARK: - Murmillo

/// A murmillo's helmet: the tall fin crest, the broad brim and the grille that closes
/// the face. The visor behind the grille is the lid.
private func murmilloHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (12, -110, 4), (18, -70, 0), (50, -66, 18), (90, -48, 20), (100, -18, 6), (124, -8, 6), (128, 8, 6),
        (100, 12, 0), (94, 60, 16), (70, 100, 16), (30, 112, 12), (0, 112, 0),
    ])
    let red: UInt32 = 0xC03A3A
    let bars: [CGFloat] = [-76, 0, 76]
    let barPath: (CGFloat) -> HPath = { x in hPoly([(x, -10), (x, 82)], closed: false) }
    let cross = hTogether([hPoly([(-90, 6), (90, 6)], closed: false), hPoly([(-90, 64), (90, 64)], closed: false)])
    let brim = hPoly([(-124, 2), (124, 2)], closed: false)

    var livery: [HDraw] = []
    livery.append(hFill(hPoly([(-24, -116), (24, -116), (24, -70), (-24, -70)]), red, clip: true))
    livery.append(hLine(brim, red, 7, clip: true))
    livery.append(hLine(hCurve([(-84, -30), (-40, -58), (0, -64), (40, -58), (84, -30)]), 0x59616F, 7, clip: true))

    var above: [HDraw] = []
    above.append(hLine(hTogether(bars.map(barPath)), 0xB7BEC9, 8))
    above.append(hLine(cross, 0xB7BEC9, 8, clip: true))

    var dynamics: [HDynamic] = []
    // Gesture 0: the fin catches the light.
    dynamics.append(hLamp([hFill(hPoly([(-24, -116), (24, -116), (24, -70), (-24, -70)]), 0xFFB4B0, clip: true)], gesture: 0))
    // Gesture 1: a light runs across the bars of the grille, left to right.
    for (index, x) in bars.enumerated() {
        dynamics.append(hGlow([hLine(barPath(x), 0xFFFFFF, 8)], gesture: 1, center: CGFloat(index + 1) / 4, width: 0.25))
    }
    // Gesture 3: the crowd roars: the edge of the brim flashes.
    dynamics.append(hLamp([hLine(brim, 0xFFB4B0, 7, clip: true)], gesture: 3))

    let spec = hHelmet(
        shell: shell, base: 0x3A3F4A, light: 0x636B7A,
        lightPath: hCurve([(-98, -20), (-90, -52), (-52, -66), (-18, -70)]), edge: 0xDCC2C0,
        livery: livery,
        window: hBox(0, 40, 164, 94, 28), top: -7, bottom: 87, width: 164,
        rim: 0x101115, rimWidth: 10,
        eyes: (w: 28, h: 32, y: 34, dx: 38, tx: 10, ty: 5, dim: 0xF2EEE8, bright: 0xFFFFFF),
        plate: (fill: 0x2A2D36, edge: red, width: 4, deco: [hFill(hPoly([(-80, -45), (-46, -45), (-66, 45), (-100, 45)]), 0x3E424E)]),
        flash: 0xFFB4B0, flashGesture: 2,
        above: above, dynamics: dynamics,
        visorNudge: 0.5, visorGesture: 2
    )
    let gestures: [[SignatureStep]] = [
        // The fin catches the light, the eyes looking up at it.
        [
            hs(0.07, hold: 0.1, ch: 0, lv: 1, gx: 0, gy: -0.8),
            hs(0.14, .easeIn, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // A light runs across the bars.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // The visor is slammed down.
        [
            hs(0.1, hold: 0.16, ch: 2, lv: 1, dil: 0.85),
            hs(0.14, .easeIn, ch: 2, lv: 0, dil: 1),
        ],
        // The crowd roars: the brim flashes twice and the eyes widen.
        [
            hs(0.06, hold: 0.03, ch: 3, lv: 1, dil: 1.2),
            hs(0.1, hold: 0.04, .easeIn, ch: 3, lv: 0),
            hs(0.06, hold: 0.03, ch: 3, lv: 1),
            hs(0.12, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Murmillo gladiator helmet: fin crest, broad brim, grille visor")
}

// MARK: - Bascinet

/// A hounskull bascinet: the tall pointed skull, the snout of the visor with its
/// slit and its breaths, the mail curtain that hangs from the rim. The visor is the lid
/// and it lifts on its pivots.
private func bascinetHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (20, -94, 4), (58, -60, 6), (90, -14, 8), (92, 44, 0), (118, 62, 0), (138, 112, 6), (0, 112, 0),
    ])
    let blue: UInt32 = 0x3B7DD8
    let laces: [CGFloat] = [70, 86, 102]
    let lace: (CGFloat) -> HPath = { y in hPoly([(-130, y), (130, y)], closed: false) }
    let breaths = hTogether([-46, 46].flatMap { x in [28, 44].map { y in hOval(CGFloat(x), CGFloat(y), 10, 10) } })
    let pins = hTogether([hOval(-88, -14, 14, 14), hOval(88, -14, 14, 14)])
    let tip = hOval(0, -100, 14, 14)

    var livery: [HDraw] = []
    livery.append(hFill(hPoly([(-140, 52), (140, 52), (140, 116), (-140, 116)]), 0x2A303B, clip: true))
    for y in laces { livery.append(hLine(lace(y), 0x5C6575, 6, clip: true)) }
    livery.append(hLine(hPoly([(-130, 56), (130, 56)], closed: false), blue, 8, clip: true))
    livery.append(hFill(breaths, 0x0B0C0F, clip: true))
    livery.append(hLine(hPoly([(0, -16), (0, 50)], closed: false), 0x7C8698, 7, clip: true))

    var above: [HDraw] = []
    above.append(hFill(pins, 0xD6A24A))

    var dynamics: [HDynamic] = []
    // Gesture 0: the pivots of the visor light as it lifts.
    dynamics.append(hLamp([hFill(pins, 0xFFE9A8)], gesture: 0))
    // Gesture 1: a light runs down the mail.
    for (index, y) in laces.enumerated() {
        dynamics.append(hGlow([hLine(lace(y), 0xE6EEFF, 6, clip: true)], gesture: 1, center: CGFloat(index + 1) / 4, width: 0.25))
    }
    // Gesture 2: the breaths puff.
    dynamics.append(hLamp([hFill(breaths, 0xDDEBFF, clip: true)], gesture: 2))
    // Gesture 3: the tip of the skull catches the light.
    dynamics.append(hLamp([hFill(tip, 0xFFFFFF)], gesture: 3))

    let spec = hHelmet(
        shell: shell, base: 0x4B5361, light: 0x8892A4,
        lightPath: hCurve([(-90, -12), (-84, -40), (-52, -70), (-16, -100)]), edge: 0xD6E2F0,
        shade: 38, lit: (-44, -50, 260, 236),
        livery: livery,
        window: hSym([(0, -30, 0), (60, -30, 6), (70, -6, 6), (60, 14, 6), (0, 14, 0)]), top: -30, bottom: 14, width: 140,
        rim: 0x12151A, rimWidth: 9, restFraction: 0.2,
        eyes: (w: 26, h: 20, y: -8, dx: 36, tx: 8, ty: 2, dim: 0xEDF1F6, bright: 0xFFFFFF),
        plate: (fill: 0x303744, edge: 0xBFD0E8, width: 4, deco: []),
        flash: 0xFFFFFF, flashGesture: 0,
        above: above, dynamics: dynamics,
        raisesVisor: true, visorGesture: 0
    )
    let gestures: [[SignatureStep]] = [
        // The visor is lifted on its pivots, held, and let down.
        [
            hs(0.14, hold: 0.16, .easeOut, ch: 0, lv: 1),
            hs(0.2, .easeIn, ch: 0, lv: 0),
        ],
        // A light runs down the mail.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // The breaths puff, twice, and the eyes narrow.
        [
            hs(0.07, hold: 0.04, ch: 2, lv: 1, dil: 0.85),
            hs(0.1, hold: 0.03, .easeIn, ch: 2, lv: 0),
            hs(0.07, hold: 0.04, ch: 2, lv: 1),
            hs(0.12, .easeIn, ch: 2, lv: 0, dil: 1),
        ],
        // The tip catches the light and the eyes look up.
        [
            hs(0.07, hold: 0.12, ch: 3, lv: 1, gx: 0, gy: -0.8),
            hs(0.14, .easeIn, ch: 3, lv: 0, gx: 0, gy: 0),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Hounskull bascinet: pointed skull, snouted visor on pivots, mail aventail")
}

// MARK: - Gjermundbu

/// The helmet from Gjermundbu: the rounded cap of riveted plates with its crest band,
/// the guard that goes round the eyes like spectacles and down over the nose, and
/// the rings of the mail below. The nose guard is the lid.
private func gjermundbuHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -86, 0), (56, -84, 30), (104, -52, 28), (112, -10, 8), (110, 36, 0), (126, 108, 6), (0, 108, 0),
    ])
    let copper: UInt32 = 0xC77B3A
    let eyesOpen = hTogether([hBox(-48, -6, 70, 58, 20), hBox(48, -6, 70, 58, 20)])
    let bandRivets: [CGFloat] = [-72, -44, -16, 16, 44, 72]
    let rings: [[CGFloat]] = [[-48, -16, 16, 48], [-32, 0, 32], [-48, -16, 16, 48]]
    let nose = hPoly([(-14, 24), (14, 24), (0, 64)])

    var livery: [HDraw] = []
    livery.append(hFill(hPoly([(-120, 52), (120, 52), (120, 116), (-120, 116)]), 0x2B2824, clip: true))
    for (row, xs) in rings.enumerated() { livery.append(hFill(hDots(xs, 70 + CGFloat(row) * 16, 11), 0x6C6459, clip: true)) }
    livery.append(hFill(hBox(0, -74, 22, 70), 0x5C564D, clip: true))
    livery.append(hLine(hPoly([(-130, -52), (130, -52)], closed: false), copper, 9, clip: true))
    livery.append(hFill(hDots(bandRivets, -52, 11), 0xE2B58A, clip: true))

    var dynamics: [HDynamic] = []
    // Gesture 0: the guard round the eyes flashes, twice.
    dynamics.append(hLamp([hLine(eyesOpen, 0xFFC890, 10)], gesture: 0))
    // Gesture 1: the nose guard swings. Drawn at rest.
    dynamics.append(HDynamic(draws: [hFill(nose, copper), hLine(nose, 0xE2B58A, 6)], channel: .gesture(1),
                             rotation: HRamp(0, 16), pivot: CGPoint(x: 0, y: 24)))
    // Gesture 2: a light runs through the rings of the mail, row by row.
    for (row, xs) in rings.enumerated() {
        dynamics.append(hGlow([hFill(hDots(xs, 70 + CGFloat(row) * 16, 11), 0xFFE9C8, clip: true)], gesture: 2,
                              center: CGFloat(row + 1) / 4, width: 0.25))
    }
    // Gesture 3: the rivets of the band light, left to right, two at a time.
    for pair in 0..<3 {
        let xs = [bandRivets[pair * 2], bandRivets[pair * 2 + 1]]
        dynamics.append(hGlow([hFill(hDots(xs, -52, 11), 0xFFF3DC, clip: true)], gesture: 3, center: CGFloat(pair + 1) / 4, width: 0.25))
    }

    let spec = hHelmet(
        shell: shell, base: 0x4A4640, light: 0x7C766B,
        lightPath: hCurve([(-106, -20), (-98, -58), (-62, -82), (-26, -85)]), edge: 0xE8D4C0,
        livery: livery,
        window: eyesOpen, top: -35, bottom: 23, width: 166,
        glass: 0x0C0B0A, rim: copper, rimWidth: 10,
        eyes: (w: 26, h: 30, y: -6, dx: 48, tx: 8, ty: 4, dim: 0xF1E9DC, bright: 0xFFFDF4),
        plate: (fill: 0x2A2723, edge: 0xE2B58A, width: 4, deco: []),
        above: [], dynamics: dynamics
    )
    let gestures: [[SignatureStep]] = [
        // The spectacle guard flashes, twice.
        [
            hs(0.06, hold: 0.03, ch: 0, lv: 1, dil: 0.9),
            hs(0.1, hold: 0.04, .easeIn, ch: 0, lv: 0),
            hs(0.06, hold: 0.03, ch: 0, lv: 1),
            hs(0.12, .easeIn, ch: 0, lv: 0, dil: 1),
        ],
        // The nose guard swings and settles.
        [
            hs(0.08, hold: 0.04, ch: 1, lv: 1),
            hs(0.1, hold: 0.02, .easeInOut, ch: 1, lv: 0),
            hs(0.06, hold: 0.02, ch: 1, lv: 0.5),
            hs(0.1, .easeInOut, ch: 1, lv: 0),
        ],
        // A light runs through the rings of the mail.
        hWalk([0.25, 0.5, 0.75, 1], ch: 2, each: 0.1),
        // The rivets of the band light in pairs.
        hWalk([0.25, 0.5, 0.75, 1], ch: 3, each: 0.1),
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Gjermundbu helmet (c. 970): riveted cap, crest band, spectacle guard, mail")
}
