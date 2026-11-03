// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Batch 3: a fighter pilot's helmet with its oxygen mask, a miner's hard hat with
// its lamp, an auto-darkening welding helmet and a Corinthian bronze helm.

extension HelmetCollection {
    static let batch3: [(AvatarStyle, HelmetEntry)] = [
        (.fighter, fighterHelmet()),
        (.miner, minerHelmet()),
        (.welder, welderHelmet()),
        (.corinthian, corinthianHelmet()),
    ]
}

// MARK: - Fighter

/// A fixed-wing pilot's helmet with the oxygen mask clipped to it: the tinted visor
/// under its housing, the bayonet receivers at the cheeks, the mask and its hose.
/// The sun visor is the lid.
private func fighterHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -108, 0), (60, -104, 34), (98, -72, 30), (106, -24, 16), (102, 30, 12), (80, 46, 6),
        (72, 90, 24), (36, 108, 16), (0, 108, 0),
    ])
    let yellow: UInt32 = 0xE8D13A
    let mask = hRound([(-50, 38, 4), (50, 38, 4), (48, 78, 22), (0, 98, 14), (-48, 78, 22)])
    let hose: [(CGFloat, CGFloat)] = [(40, 76), (86, 92), (120, 84), (130, 56)]
    let receivers = hTogether([hBox(-102, 22, 16, 22, 4), hBox(102, 22, 16, 22, 4)])

    var livery: [HDraw] = []
    livery.append(hLine(hCurve([(-104, -56), (-60, -78), (0, -84), (60, -78), (104, -56)]), yellow, 10, clip: true))

    var above: [HDraw] = []
    above.append(hLine(hCurve(hose), 0x8B9385, 12))
    above.append(hFill(receivers, 0xB4BBB0))

    var dynamics: [HDynamic] = []
    // Gesture 1: the oxygen flow runs along the hose.
    dynamics += hChase(HShape.spans(hCurve(hose)), hex: 0xDFF3FF, width: 12, gesture: 1)
    // Gesture 2: the bayonet receivers click.
    dynamics.append(hLamp([hFill(receivers, 0xFFF4A8)], gesture: 2))
    // Gesture 3: the mask is breathed into: it swells and settles. Drawn at rest.
    dynamics.append(HDynamic(
        draws: [hFill(mask, 0x262A27), hLine(mask, 0x8B9385, 7), hFill(hTogether([hOval(-44, 58, 15, 15), hOval(44, 58, 15, 15)]), 0xCDD4C6)],
        channel: .gesture(3), scale: HRamp(1, 1.16), pivot: CGPoint(x: 0, y: 68)
    ))

    let spec = hHelmet(
        shell: shell, base: 0x3C413B, light: 0x6A7066,
        lightPath: hCurve([(-104, -20), (-98, -64), (-64, -100), (-30, -104)]), edge: 0xD2DAC6,
        livery: livery,
        window: hBox(0, -8, 176, 74, 32), top: -45, bottom: 29, width: 176,
        glass: 0x0B0D0C, rim: 0x151715, rimWidth: 10, restFraction: 0.18,
        eyes: (w: 32, h: 34, y: -8, dx: 44, tx: 12, ty: 5, dim: 0xEAF0DC, bright: 0xFFFFF0),
        plate: (fill: 0x4A3C14, edge: yellow, width: 4, deco: [hFill(hPoly([(-86, -42), (-52, -42), (-72, 42), (-106, 42)]), 0x6B5A22)]),
        flash: 0xFFF4A8, flashGesture: 0,
        above: above, dynamics: dynamics,
        visorNudge: 0.45, visorGesture: 0
    )
    let gestures: [[SignatureStep]] = [
        // The sun visor comes down and its edge flashes.
        [
            hs(0.14, hold: 0.18, ch: 0, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 0, lv: 0, dil: 1),
        ],
        // The oxygen flow runs along the hose.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // The bayonet receivers click, and the eyes look down at them.
        [
            hs(0.06, hold: 0.12, ch: 2, lv: 1, gx: 0, gy: 0.8),
            hs(0.12, .easeIn, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // The mask breathes: it swells and settles, twice.
        [
            hs(0.1, hold: 0.04, .easeInOut, ch: 3, lv: 1, dil: 0.9),
            hs(0.12, hold: 0.02, .easeInOut, ch: 3, lv: 0),
            hs(0.1, hold: 0.04, .easeInOut, ch: 3, lv: 1),
            hs(0.12, .easeInOut, ch: 3, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Fixed-wing pilot's flight helmet: visor housing, sun visor, bayonet receivers, oxygen mask and hose")
}

// MARK: - Miner

/// A miner's hard hat: the ribbed crown and short brim, the cap lamp with its cable
/// over the crown, and a respirator whose cartridges stand out at the cheeks.
private func minerHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -110, 0), (58, -106, 36), (96, -76, 30), (104, -52, 6), (126, -42, 8), (128, -22, 8), (98, -12, 4),
        (90, 36, 12), (112, 52, 14), (116, 84, 14), (84, 96, 12), (40, 110, 12), (0, 110, 0),
    ])
    let orange: UInt32 = 0xFF7A1A
    let cable: [(CGFloat, CGFloat)] = [(0, -90), (40, -104), (80, -84), (96, -42)]
    let ribs: [[(CGFloat, CGFloat)]] = [
        [(-70, -90), (-76, -52)], [(-34, -104), (-38, -54)], [(34, -104), (38, -54)], [(70, -90), (76, -52)],
    ]
    let cartridge: HPath = hTogether([hOval(0, 0, 30, 30)])

    var livery: [HDraw] = []
    for rib in ribs { livery.append(hLine(hPoly(rib, closed: false), 0x4A4D54, 8, clip: true)) }
    livery.append(hLine(hPoly([(-130, -17), (130, -17)], closed: false), orange, 7, clip: true))
    livery.append(hFill(hBox(0, -70, 46, 38, 8), 0x1B1C1F, clip: true))
    livery.append(hLine(hPoly(cable, closed: false), 0x101113, 7, clip: true))
    livery.append(hFill(hOval(0, -70, 28, 28), 0x8A6A30, clip: true))

    var dynamics: [HDynamic] = []
    // The lamp's lens follows the breath.
    dynamics.append(HDynamic(draws: [hFill(hOval(0, -70, 28, 28), 0xFFE9A8)], channel: .led, opacity: HRamp(0.4, 1)))
    // Gesture 0: the lamp comes on bright and swells.
    dynamics.append(HDynamic(draws: [hFill(hOval(0, -70, 28, 28), 0xFFF6D0)], channel: .gesture(0),
                             opacity: HRamp(0, 1), scale: HRamp(1, 1.5), pivot: CGPoint(x: 0, y: -70)))
    // Gesture 1: power runs along the cable.
    dynamics += hChase(HShape.spans(hPoly(cable, closed: false)), hex: 0xFFE9A8, width: 7, gesture: 1, clip: true)
    // Gesture 2: the respirator cartridges are turned a quarter, one each way.
    for (x, degrees) in [(-106, CGFloat(40)), (106, CGFloat(-40))] {
        let dx = CGFloat(x)
        dynamics.append(HDynamic(
            draws: [hFill(hMove(cartridge, dx, 68), 0x1D1F23), hLine(hMove(cartridge, dx, 68), 0x8A8F9A, 6),
                    hFill(hBox(dx, 68, 20, 7, 3), orange)],
            channel: .gesture(2), rotation: HRamp(0, degrees), pivot: CGPoint(x: dx, y: 68)
        ))
    }
    // Gesture 3: the ribs of the crown light from one side to the other.
    for (index, rib) in ribs.enumerated() {
        dynamics.append(hGlow([hLine(hPoly(rib, closed: false), 0xFFD7A8, 8, clip: true)], gesture: 3,
                              center: CGFloat(index + 1) / 5, width: 0.2))
    }

    let spec = hHelmet(
        shell: shell, base: 0x2D2F34, light: 0x4F5259,
        lightPath: hCurve([(-102, -50), (-96, -82), (-62, -106), (-30, -110)]), edge: 0xFFC9A0,
        livery: livery,
        window: hBox(0, 24, 156, 52, 20), top: -2, bottom: 50, width: 156,
        rim: 0x0E0F11, rimWidth: 10,
        eyes: (w: 28, h: 28, y: 24, dx: 40, tx: 12, ty: 5, dim: 0xF3EBDC, bright: 0xFFFDF2),
        plate: (fill: 0x2A3A44, edge: orange, width: 4, deco: [hFill(hPoly([(-80, -31), (-48, -31), (-68, 31), (-100, 31)]), 0x3E5462)]),
        above: [], dynamics: dynamics
    )
    let gestures: [[SignatureStep]] = [
        // The lamp is switched on: it flares and the eyes look up at it.
        [
            hs(0.06, hold: 0.04, ch: 0, lv: 1, gx: 0, gy: -0.8),
            hs(0.08, hold: 0.03, .easeIn, ch: 0, lv: 0),
            hs(0.06, hold: 0.04, ch: 0, lv: 1),
            hs(0.14, .easeIn, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // Power runs along the cable.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // The cartridges are turned and turned back.
        [
            hs(0.1, hold: 0.16, ch: 2, lv: 1, dil: 0.9),
            hs(0.14, .easeInOut, ch: 2, lv: 0, dil: 1),
        ],
        // The ribs of the crown light, left to right.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 3, each: 0.08),
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Miner's hard hat with a cap lamp and cable, and a half-mask respirator")
}

// MARK: - Welder

/// An auto-darkening welding helmet: the deep square shell, the lens with its arc
/// sensors above it, the shade dial at the side and the power light below. The lens
/// shade is the lid, and it goes dark when the arc strikes.
private func welderHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -108, 0), (108, -108, 16), (122, -66, 4), (116, 56, 8), (98, 100, 14), (0, 100, 0),
    ])
    let green: UInt32 = 0x38E37B
    let sensors = hTogether([-76, -48, 48, 76].map { hOval(CGFloat($0), -68, 13, 13) })
    let led = hOval(-74, 50, 11, 11)
    let dial = hOval(128, 0, 26, 26)
    let lens = hRound([(-86, -54, 6), (86, -54, 6), (96, 26, 8), (-96, 26, 8)])

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, -90, 260, 22, 6), 0x3A3D44, clip: true))
    livery.append(hLine(hPoly([(-130, -90), (130, -90)], closed: false), green, 7, clip: true))
    livery.append(hFill(hBox(0, 66, 320, 40), 0x1E2024, clip: true))

    var above: [HDraw] = []
    above.append(hFill(sensors, 0x0A0B0D))
    above.append(hFill(led, 0x1E3B2A))
    above.append(hFill(hOval(-128, 0, 26, 26), 0x3A3D44))

    var dynamics: [HDynamic] = []
    // Gesture 0: the arc strikes: the sensors flash and the lens goes dark (the plate).
    dynamics.append(hLamp([hFill(sensors, 0xDFFFEA)], gesture: 0))
    // Gesture 1: the shade dial is turned.
    dynamics.append(HDynamic(
        draws: [hFill(dial, 0x4A4E57), hFill(hBox(128, -6, 7, 12, 2), 0xE6E9EF)],
        channel: .gesture(1), rotation: HRamp(0, 120), pivot: CGPoint(x: 128, y: 0)
    ))
    // Gesture 2: the power light blinks.
    dynamics.append(hLamp([hFill(led, green)], gesture: 2))
    // Gesture 3: the arc is seen through the lens, in three tack welds.
    dynamics.append(hLamp([hFill(lens, 0xBFFFD8, 0.55)], gesture: 3, inside: true))

    let spec = hHelmet(
        shell: shell, base: 0x2A2C32, light: 0x4C4F58,
        lightPath: hCurve([(-114, 40), (-116, -40), (-110, -90), (-90, -104)]), edge: 0xB9F0D0,
        shade: 38, lit: (-40, -44, 290, 240),
        livery: livery,
        window: lens, top: -54, bottom: 26, width: 192,
        glass: 0x10261A, rim: 0x101113, rimWidth: 12,
        eyes: (w: 30, h: 36, y: -14, dx: 42, tx: 12, ty: 5, dim: 0xE4F7EA, bright: 0xFFFFFF),
        plate: (fill: 0x0B1A12, edge: green, width: 4, deco: [hFill(hPoly([(-90, -45), (-56, -45), (-76, 45), (-110, 45)]), 0x14301F)]),
        flash: 0xB8FFD0, flashGesture: 0,
        above: above, dynamics: dynamics,
        visorNudge: 0.9, visorGesture: 0
    )
    let gestures: [[SignatureStep]] = [
        // The arc strikes: the sensors flash, the lens goes dark and clears.
        [
            hs(0.05, hold: 0.24, ch: 0, lv: 1, dil: 0.8),
            hs(0.16, .easeIn, ch: 0, lv: 0, dil: 1),
        ],
        // The shade dial is turned and turned back, the eyes watching it.
        [
            hs(0.12, hold: 0.1, ch: 1, lv: 1, gx: 0.8),
            hs(0.16, .easeInOut, ch: 1, lv: 0, gx: 0, gy: 0),
        ],
        // The power light blinks twice.
        [
            hs(0.06, hold: 0.04, ch: 2, lv: 1),
            hs(0.1, hold: 0.04, .easeIn, ch: 2, lv: 0),
            hs(0.06, hold: 0.04, ch: 2, lv: 1),
            hs(0.1, .easeIn, ch: 2, lv: 0),
        ],
        // Three tack welds light the lens.
        [
            hs(0.04, hold: 0.05, .linear, ch: 3, lv: 1, dil: 0.8),
            hs(0.04, hold: 0.05, .linear, ch: 3, lv: 0),
            hs(0.04, hold: 0.05, .linear, ch: 3, lv: 1),
            hs(0.04, hold: 0.05, .linear, ch: 3, lv: 0),
            hs(0.04, hold: 0.05, .linear, ch: 3, lv: 1),
            hs(0.04, .linear, ch: 3, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Auto-darkening welding helmet: arc sensors, shade lens, shade dial, power light")
}

// MARK: - Corinthian

/// A Corinthian helm of bronze: the cheek-pieces closing to the chin, the T-shaped
/// opening with its nasal bar, the brow, and the crest that sways. The helm slipping
/// down over the eyes is the lid.
private func corinthianHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -86, 0), (56, -84, 26), (98, -58, 26), (102, -10, 14), (96, 30, 10), (80, 74, 12), (36, 108, 14), (0, 108, 0),
    ])
    let red: UInt32 = 0xB3322A
    let crest = hSym([(0, -108, 0), (30, -106, 14), (56, -90, 6), (60, -76, 0), (0, -72, 0)])
    let window = hSym([(0, -36, 0), (72, -36, 10), (84, -6, 10), (78, 18, 8), (24, 18, 0), (24, 74, 8), (0, 74, 0)])
    let brow: [(CGFloat, CGFloat)] = [(-70, -44), (-36, -54), (0, -56), (36, -54), (70, -44)]
    let nasal: [(CGFloat, CGFloat)] = [(0, -44), (0, -16), (0, 12), (0, 40)]

    var livery: [HDraw] = []
    livery.append(hLine(hCurve(brow), 0x5C8A7B, 8, clip: true))
    livery.append(hLine(hCurve([(-98, -20), (-84, 20), (-50, 76), (-20, 100)]), 0x5C8A7B, 7, clip: true))
    livery.append(hLine(hCurve([(98, -20), (84, 20), (50, 76), (20, 100)]), 0x5C8A7B, 7, clip: true))

    var above: [HDraw] = []
    above.append(hFill(hPoly([(-12, -46), (12, -46), (9, 42), (-9, 42)]), 0x4F7A6C))

    var dynamics: [HDynamic] = []
    // Gesture 0: the crest sways. It is drawn at rest.
    dynamics.append(HDynamic(
        draws: [hFill(crest, red), hLine(crest, 0xF2A59E, 6)],
        channel: .gesture(0), offsetX: HRamp(0, 6), rotation: HRamp(0, 8), pivot: CGPoint(x: 0, y: -74)
    ))
    // Gesture 1: a light runs down the nasal bar.
    dynamics += hChase(HShape.spans(hPoly(nasal, closed: false)), hex: 0xE6FFF4, width: 14, gesture: 1)
    // Gesture 2: the brow lights as the eyes narrow.
    dynamics.append(hLamp([hLine(hCurve(brow), 0xE6FFF4, 8, clip: true)], gesture: 2))

    let spec = hHelmet(
        shell: shell, base: 0x3E5A52, light: 0x6C9A8A,
        lightPath: hCurve([(-100, -16), (-96, -56), (-66, -82), (-30, -85)]), edge: 0xBFE6D8,
        livery: livery,
        window: window, top: -36, bottom: 74, width: 168,
        rim: 0x101A17, rimWidth: 10,
        eyes: (w: 28, h: 32, y: -10, dx: 44, tx: 10, ty: 4, dim: 0xE8F3EE, bright: 0xFFFFFF),
        plate: (fill: 0x24352F, edge: 0xBFE6D8, width: 4, deco: []),
        flash: 0xE6FFF4, flashGesture: 3,
        above: above, dynamics: dynamics,
        visorNudge: 0.4, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // The crest sways one way, back, and rests.
        [
            hs(0.12, hold: 0.04, .easeInOut, ch: 0, lv: 1),
            hs(0.18, hold: 0.02, .easeInOut, ch: 0, lv: 0),
        ],
        // A light runs down the nasal bar.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // A frown: the brow lights and the eyes narrow.
        [
            hs(0.08, hold: 0.2, ch: 2, lv: 1, dil: 0.8),
            hs(0.14, .easeIn, ch: 2, lv: 0, dil: 1),
        ],
        // The helm slips down over the eyes and is pushed back.
        [
            hs(0.12, hold: 0.18, ch: 3, lv: 1),
            hs(0.16, .easeIn, ch: 3, lv: 0),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Corinthian bronze helm: crest, cheek-pieces, T-shaped opening, nasal bar")
}
