// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Batch 2: a gridiron football helmet, a motocross helmet, a Formula 1 helmet
// behind its halo and a leather flying helmet with goggles.

extension HelmetCollection {
    static let batch2: [(AvatarStyle, HelmetEntry)] = [
        (.gridiron, gridironHelmet()),
        (.moto, motoHelmet()),
        (.halo, haloHelmet()),
        (.aviator, aviatorHelmet()),
    ]
}

// MARK: - Gridiron

/// A football helmet: the shell with its centre stripe and ear holes, the jaw flaps
/// that hold the chin strap, the cage of the facemask. The tinted eye shield is the lid.
private func gridironHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (60, -108, 32), (104, -74, 32), (116, -20, 12), (124, 34, 10), (120, 64, 12),
        (92, 72, 0), (86, 100, 12), (50, 112, 8), (0, 112, 0),
    ])
    let blue: UInt32 = 0x3C68E6, steel: UInt32 = 0xE6E9EF
    let stripe: [(CGFloat, CGFloat)] = [(0, -108), (0, -82), (0, -58), (0, -32)]
    let cage = hTogether([
        hPoly([(-100, -2), (100, -2)], closed: false),
        hPoly([(-96, 60), (96, 60)], closed: false),
        hPoly([(-86, 86), (86, 86)], closed: false),
        hPoly([(0, -2), (0, 100)], closed: false),
        hPoly([(-100, -2), (-90, 60), (-84, 100)], closed: false),
        hPoly([(100, -2), (90, 60), (84, 100)], closed: false),
    ])
    let snaps = [CGPoint(x: -112, y: 50), CGPoint(x: 112, y: 50)]

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, -70, 26, 100), blue, clip: true))
    livery.append(hFill(hBox(-19, -70, 6, 100), 0xF2F4F8, clip: true))
    livery.append(hFill(hBox(19, -70, 6, 100), 0xF2F4F8, clip: true))
    livery.append(hFill(hOval(-100, 10, 20, 26), 0x0B0C0F, clip: true))
    livery.append(hFill(hOval(100, 10, 20, 26), 0x0B0C0F, clip: true))
    var above: [HDraw] = []
    above.append(hFill(hOval(snaps[0].x, snaps[0].y, 14, 14), 0x8D93A1))
    above.append(hFill(hOval(snaps[1].x, snaps[1].y, 14, 14), 0x8D93A1))

    var dynamics: [HDynamic] = []
    // Gesture 0: a light runs down the stripe.
    dynamics += hChase(HShape.spans(hPoly(stripe, closed: false)), hex: 0xB4C8FF, width: 26, gesture: 0, clip: true)
    // Gesture 1: the facemask rattles. Drawn at rest, shaken by its channel.
    dynamics.append(HDynamic(draws: [hLine(cage, steel, 8, clip: true)], channel: .gesture(1), offsetX: HRamp(0, 7)))
    // Gesture 2: the chin strap snaps, left then right.
    dynamics.append(hGlow([hFill(hOval(snaps[0].x, snaps[0].y, 14, 14), 0xFFF3C8)], gesture: 2, center: 1.0 / 3, width: 1.0 / 3))
    dynamics.append(hGlow([hFill(hOval(snaps[1].x, snaps[1].y, 14, 14), 0xFFF3C8)], gesture: 2, center: 2.0 / 3, width: 1.0 / 3))

    let spec = hHelmet(
        shell: shell, base: 0x25272D, light: 0x474A55,
        lightPath: hCurve([(-112, -22), (-104, -70), (-70, -104), (-30, -110)]), edge: 0xD0D6EC,
        livery: livery,
        window: hBox(0, 26, 176, 62, 20), top: -5, bottom: 57, width: 176,
        rim: 0x0C0D10, rimWidth: 10,
        eyes: (w: 30, h: 32, y: 26, dx: 46, tx: 12, ty: 5, dim: 0xEEF1F6, bright: 0xFFFFFF),
        plate: (fill: 0x24405E, edge: 0xA9C4E8, width: 4,
                deco: [hFill(hPoly([(-88, -36), (-54, -36), (-78, 36), (-112, 36)]), 0x365D87)]),
        flash: 0xDCEBFF, flashGesture: 3,
        above: above, dynamics: dynamics,
        visorNudge: 0.5, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // A light runs down the stripe.
        hWalk([0.25, 0.5, 0.75, 1], ch: 0, each: 0.1),
        // The facemask rattles from a hit: four quick shakes and the eyes shiver.
        [
            hs(0.04, hold: 0.02, ch: 1, lv: 1, gx: -0.8),
            hs(0.04, hold: 0.02, ch: 1, lv: 0, gx: 0.8),
            hs(0.04, hold: 0.02, ch: 1, lv: 1, gx: -0.8),
            hs(0.06, ch: 1, lv: 0, gx: 0),
        ],
        // The chin strap snaps shut on one side, then the other.
        hWalk([1.0 / 3, 2.0 / 3, 1], ch: 2, each: 0.1),
        // The eye shield comes down: game face.
        [
            hs(0.12, hold: 0.18, ch: 3, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "American football helmet: shell stripe, ear holes, jaw flaps, facemask, tinted eye shield")
}

// MARK: - Motocross

/// A motocross helmet: the long peak, the goggles on a strap over the eye port, the
/// chin bar with its mouthpiece. The goggle tint is the lid, and the goggles carry a
/// tear-off film.
private func motoHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -84, 0), (60, -82, 30), (104, -52, 26), (114, -14, 16), (112, 36, 18), (98, 66, 14),
        (74, 76, 0), (70, 104, 12), (40, 112, 10), (0, 112, 0),
    ])
    let yellow: UInt32 = 0xF2C200
    let peak = hSym([(0, -104, 0), (98, -102, 8), (142, -76, 6), (138, -62, 3), (110, -56, 0), (0, -56, 0)])
    let mouth = hBox(0, 92, 54, 26, 6)

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, -8, 320, 34), 0x16171B, clip: true))
    livery.append(hLine(hPoly([(-160, -25), (160, -25)], closed: false), yellow, 7, clip: true))
    livery.append(hLine(hPoly([(-160, 9), (160, 9)], closed: false), yellow, 7, clip: true))
    livery.append(hFill(hBox(0, -64, 22, 40), yellow, clip: true))

    var dynamics: [HDynamic] = []
    // Gesture 0: a tear-off film is peeled off the goggles, sliding out to the right.
    dynamics.append(HDynamic(
        draws: [hFill(hBox(0, -8, 206, 74, 30), 0xC9DDF2, 0.5)], channel: .gesture(0), opacity: HRamp(0, 1),
        offsetX: HRamp(0, 200), insideWindow: true, pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 1: the peak lifts. It is drawn at rest, and is this part and nothing else.
    dynamics.append(HDynamic(
        draws: [hFill(peak, yellow), hFill(hSym([(0, -64, 0), (138, -64, 0), (110, -56, 0), (0, -56, 0)]), 0x8A6C00),
                hLine(peak, 0xFFE27A, 7)],
        channel: .gesture(1), offsetY: HRamp(0, -14)
    ))
    // Gesture 2: the mouthpiece slides open, a dark slot of the chin bar showing behind it.
    dynamics.append(HDynamic(
        draws: [hFill(mouth, 0x0F1013), hFill(hTogether([-14, 0, 14].map { hBox(CGFloat($0), 92, 5, 16, 2) }), yellow)],
        channel: .gesture(2), offsetY: HRamp(0, 14)
    ))

    let spec = hHelmet(
        shell: shell, base: 0x25272D, light: 0x474A55,
        lightPath: hCurve([(-110, -30), (-104, -60), (-70, -80), (-30, -82)]), edge: 0xF2E3A0,
        livery: livery,
        window: hBox(0, -8, 206, 74, 30), top: -45, bottom: 29, width: 206,
        glass: 0x0C1116, rim: 0xF2C200, rimWidth: 11,
        eyes: (w: 34, h: 34, y: -8, dx: 50, tx: 12, ty: 5, dim: 0xE8F2F7, bright: 0xFFFFFF),
        plate: (fill: 0x3A2F0A, edge: yellow, width: 5, deco: [hFill(hPoly([(-96, -42), (-62, -42), (-86, 42), (-120, 42)]), 0x5C4A10)]),
        flash: 0xFFF0A8, flashGesture: 3,
        above: [], dynamics: dynamics,
        visorNudge: 0.5, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // The tear-off is peeled: it fades in over the lenses and slides away to the right.
        [
            hs(0.12, .linear, ch: 0, lv: 0.5, dil: 0.85),
            hs(0.12, .linear, ch: 0, lv: 1),
            hReset(0),
            hs(0.08, dil: 1),
        ],
        // The peak lifts a little and drops again.
        [
            hs(0.1, hold: 0.14, ch: 1, lv: 1),
            hs(0.16, .easeIn, ch: 1, lv: 0),
        ],
        // The mouthpiece slides open and shut, and the eyes look down at it.
        [
            hs(0.1, hold: 0.16, ch: 2, lv: 1, gx: 0, gy: 0.8),
            hs(0.14, .easeInOut, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // The goggles drop to the tint and flash.
        [
            hs(0.12, hold: 0.18, ch: 3, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Motocross helmet: long peak, goggles with tear-offs, chin bar with mouthpiece")
}

// MARK: - Halo

/// A Formula 1 helmet seen through the halo: the long visor, the carbon shell, the
/// ear pods of the radio, and in front of it the titanium arch with its pillar.
private func haloHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -96, 0), (56, -92, 30), (92, -62, 24), (98, -10, 14), (94, 46, 20), (66, 84, 22), (30, 98, 14), (0, 98, 0),
    ])
    let pink: UInt32 = 0xF0487F, titanium: UInt32 = 0x9AA3B0
    let arch: [(CGFloat, CGFloat)] = [(-136, 100), (-118, -40), (0, -104), (118, -40), (136, 100)]
    let pillar: [(CGFloat, CGFloat)] = [(0, 44), (0, -4), (0, -56), (0, -104)]
    let pods = hTogether([hOval(-100, 20, 20, 26), hOval(100, 20, 20, 26)])

    var livery: [HDraw] = []
    livery.append(hLine(hCurve([(-104, -56), (-60, -74), (0, -78), (60, -74), (104, -56)]), pink, 14, clip: true))
    livery.append(hLine(hCurve([(-104, -40), (-60, -58), (0, -62), (60, -58), (104, -40)]), 0xF2F2F4, 6, clip: true))
    livery.append(hFill(hTogether([-16, 0, 16].map { hBox(CGFloat($0), 82, 8, 16, 3) }), 0x0B0C0F, clip: true))

    var above: [HDraw] = []
    above.append(hFill(pods, 0x15161A))
    above.append(hLine(pods, 0x5A5F6B, 6))
    // The halo: the arch, the pillar and the foot of the pillar, over everything.
    above.append(hLine(hCurve(arch), titanium, 14))
    above.append(hLine(hPoly(pillar, closed: false), titanium, 16))
    above.append(hFill(hPoly([(-18, 44), (18, 44), (26, 72), (-26, 72)]), titanium))
    above.append(hLine(hPoly([(-3, -98), (-3, 36)], closed: false), 0xD5DBE4, 4))

    var dynamics: [HDynamic] = []
    // Gesture 0: a light runs up the arch, from one foot over the top to the other.
    dynamics += hChase(HShape.spans(hCurve(arch)), hex: 0xFFD0E2, width: 14, gesture: 0)
    // Gesture 2: the radio crackles in the ear pods.
    dynamics.append(hLamp([hFill(pods, pink)], gesture: 2))
    // Gesture 3: a light runs up the pillar.
    dynamics += hChase(HShape.spans(hPoly(pillar, closed: false)), hex: 0xFFD0E2, width: 16, gesture: 3)

    let spec = hHelmet(
        shell: shell, base: 0x1F2126, light: 0x434650,
        lightPath: hCurve([(-98, -20), (-94, -64), (-62, -90), (-30, -94)]), edge: 0xF4B8CC,
        shade: 40, lit: (-40, -40, 260, 220),
        livery: livery,
        window: hBox(0, -4, 176, 50, 20), top: -29, bottom: 21, width: 176,
        rim: 0x050506, rimWidth: 10,
        eyes: (w: 30, h: 22, y: -4, dx: 46, tx: 12, ty: 3, dim: 0xF0F2F5, bright: 0xFFFFFF),
        plate: (fill: 0x232830, edge: pink, width: 4, deco: [hFill(hPoly([(-88, -30), (-54, -30), (-74, 30), (-108, 30)]), 0x343A46)]),
        flash: 0xFFC2D8, flashGesture: 1,
        above: above, dynamics: dynamics,
        visorNudge: 0.55, visorGesture: 1
    )
    let gestures: [[SignatureStep]] = [
        // A light runs over the arch.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 0, each: 0.08),
        // The visor flicks down, the tear-off edge flashing.
        [
            hs(0.1, hold: 0.16, ch: 1, lv: 1, dil: 0.85),
            hs(0.14, .easeIn, ch: 1, lv: 0, dil: 1),
        ],
        // A radio call: the ear pods flash twice and the eyes look aside.
        [
            hs(0.06, hold: 0.03, ch: 2, lv: 1, gx: 0.8),
            hs(0.1, hold: 0.05, .easeIn, ch: 2, lv: 0),
            hs(0.06, hold: 0.03, ch: 2, lv: 1),
            hs(0.12, .easeIn, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // A light climbs the pillar.
        hWalk([0.25, 0.5, 0.75, 1], ch: 3, each: 0.1),
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Formula 1 helmet behind the halo: titanium arch and central pillar, long visor, radio ear pods")
}

// MARK: - Aviator

/// A leather flying helmet of the 1940s: the cap with its seams, the ear flaps, the
/// goggles with brass rims and the sun lenses that flip down. The sun lenses are the lid.
private func aviatorHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -110, 0), (54, -106, 36), (92, -74, 32), (102, -34, 12), (102, 40, 10), (90, 96, 22), (44, 110, 14), (0, 110, 0),
    ])
    let lenses = hTogether([hOval(-50, 0, 86, 80), hOval(50, 0, 86, 80)])
    let flapR = hRound([(98, -22, 6), (132, -8, 12), (138, 54, 18), (118, 88, 14), (98, 70, 4)])
    let flapL = hMirror(flapR)
    let seam: UInt32 = 0x35210F
    let buckle = hBox(62, 84, 18, 16, 4)
    let rims = lenses

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, 0, 320, 30), 0x2E1D10, clip: true))
    livery.append(hLine(hPoly([(0, -110), (0, -46)], closed: false), seam, 7, clip: true))
    livery.append(hLine(hCurve([(-98, -10), (-84, -62), (-40, -100), (-14, -108)]), seam, 7, clip: true))
    livery.append(hLine(hCurve([(98, -10), (84, -62), (40, -100), (14, -108)]), seam, 7, clip: true))
    livery.append(hLine(hCurve([(-84, 68), (0, 92), (84, 68)]), seam, 9, clip: true))

    var above: [HDraw] = []
    above.append(hFill(hBox(0, 0, 16, 18, 4), 0xB8893A))
    above.append(hFill(buckle, 0xB8893A))

    var dynamics: [HDynamic] = []
    // Gesture 0: the ear flaps flutter in the airstream.
    dynamics.append(HDynamic(
        draws: [hFill(flapR, 0x4A311C), hLine(flapR, 0xF0D2B4, 7)],
        channel: .gesture(0), rotation: HRamp(0, -13), pivot: CGPoint(x: 98, y: -14)
    ))
    dynamics.append(HDynamic(
        draws: [hFill(flapL, 0x4A311C), hLine(flapL, 0xF0D2B4, 7)],
        channel: .gesture(0), rotation: HRamp(0, 13), pivot: CGPoint(x: -98, y: -14)
    ))
    // Gesture 2: the chin strap buckle catches the light.
    dynamics.append(hLamp([hFill(buckle, 0xFFE2A0)], gesture: 2))
    // Gesture 3: the brass of the goggles flashes.
    dynamics.append(hLamp([hLine(rims, 0xFFE2A0, 12)], gesture: 3))

    let spec = hHelmet(
        shell: shell, base: 0x5A3C24, light: 0x8B6240,
        lightPath: hCurve([(-100, -30), (-90, -76), (-56, -104), (-24, -108)]), edge: 0xF0D2B4,
        shade: 36, lit: (-40, -44, 280, 236),
        livery: livery,
        window: lenses, top: -40, bottom: 40, width: 186,
        glass: 0x0C0D0F, rim: 0xB8893A, rimWidth: 12,
        eyes: (w: 30, h: 34, y: 0, dx: 50, tx: 9, ty: 5, dim: 0xEBE6D8, bright: 0xFFFDF2),
        plate: (fill: 0x8F6416, edge: 0xE2B050, width: 4, deco: [hFill(hPoly([(-96, -36), (-62, -36), (-82, 36), (-116, 36)]), 0xB88626)]),
        flash: 0xFFE2A0, flashGesture: 1,
        above: above, dynamics: dynamics,
        visorNudge: 0.6, visorGesture: 1
    )
    let gestures: [[SignatureStep]] = [
        // The flaps flutter, twice.
        [
            hs(0.07, hold: 0.03, ch: 0, lv: 1),
            hs(0.09, hold: 0.03, .easeInOut, ch: 0, lv: 0),
            hs(0.07, hold: 0.03, ch: 0, lv: 1),
            hs(0.1, .easeInOut, ch: 0, lv: 0),
        ],
        // The sun lenses flip down over the goggles.
        [
            hs(0.12, hold: 0.18, ch: 1, lv: 1, dil: 0.85),
            hs(0.14, .easeIn, ch: 1, lv: 0, dil: 1),
        ],
        // The eyes check the chin strap, whose buckle catches the light.
        [
            hs(0.07, hold: 0.12, ch: 2, lv: 1, gx: 0.4, gy: 0.8),
            hs(0.14, .easeIn, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // The brass of the goggles flashes twice.
        [
            hs(0.06, hold: 0.03, ch: 3, lv: 1),
            hs(0.1, hold: 0.05, .easeIn, ch: 3, lv: 0),
            hs(0.06, hold: 0.03, ch: 3, lv: 1),
            hs(0.12, .easeIn, ch: 3, lv: 0),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Leather flying helmet with brass-rimmed goggles, ear flaps and sun lenses")
}
