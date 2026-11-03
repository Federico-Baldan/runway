// CGRect, CGPoint and CGSize come with their members only from CoreGraphics on
// macOS, which has no such module on Linux, where Foundation has them all.
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

// Batch 5: a ski helmet with goggles, a forestry helmet with ear defenders and a mesh
// visor, a British custodian helmet and a fencing mask.

extension HelmetCollection {
    static let batch5: [(AvatarStyle, HelmetEntry)] = [
        (.ski, skiHelmet()),
        (.forestry, forestryHelmet()),
        (.custodian, custodianHelmet()),
        (.fencing, fencingMask()),
    ]
}

// MARK: - Ski

/// A ski helmet: the vented shell, the ear pads, the goggles on their strap, the neck
/// gaiter under them. The goggle lens tint is the lid.
private func skiHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -110, 0), (60, -106, 34), (100, -70, 30), (108, -24, 8), (124, -4, 10), (126, 50, 12), (100, 64, 0),
        (84, 88, 16), (0, 88, 0),
    ])
    let cyan: UInt32 = 0x22C3EE
    let slots: [CGFloat] = [-30, 0, 30]
    let slotPath: (CGFloat) -> HPath = { x in hBox(x, -80, 11, 30, 5) }
    let padR = hRound([(104, -14, 8), (126, -4, 10), (128, 50, 12), (102, 62, 6)])
    let padL = hMirror(padR)
    let buckle = hBox(46, 74, 18, 14, 4)

    var livery: [HDraw] = []
    livery.append(hFill(hBox(0, 70, 320, 40), 0x1B1D21, clip: true))
    livery.append(hFill(hBox(0, -10, 320, 36), 0x14161A, clip: true))
    livery.append(hFill(hBox(0, -10, 320, 8), cyan, clip: true))
    for x in slots { livery.append(hFill(slotPath(x), 0x0B0C0F, clip: true)) }
    livery.append(hLine(hCurve([(-72, 62), (0, 82), (72, 62)]), 0x0B0C0F, 8, clip: true))

    let above: [HDraw] = [hFill(buckle, cyan)]

    var dynamics: [HDynamic] = []
    // Gesture 0: the vent slots light, left to right.
    for (index, x) in slots.enumerated() {
        dynamics.append(hGlow([hFill(slotPath(x), 0xB8F0FF, clip: true)], gesture: 0, center: CGFloat(index + 1) / 4, width: 0.25))
    }
    // Gesture 1: the ear pads flex outwards and back. Drawn at rest.
    dynamics.append(HDynamic(draws: [hFill(padR, 0x23262B), hLine(padR, 0xBFE9F7, 7)], channel: .gesture(1), offsetX: HRamp(0, 6)))
    dynamics.append(HDynamic(draws: [hFill(padL, 0x23262B), hLine(padL, 0xBFE9F7, 7)], channel: .gesture(1), offsetX: HRamp(0, -6)))
    // Gesture 2: the strap buckle catches the light.
    dynamics.append(hLamp([hFill(buckle, 0xE6FAFF)], gesture: 2))


    // Gesture 4: powder spray: white flecks fly across the goggles out of a turn.
    dynamics.append(HDynamic(
        draws: [hFill(hTogether([
            hBox(-80, -34, 18, 8, 3), hBox(-50, -10, 26, 7, 3), hBox(-14, -38, 16, 8, 3),
            hBox(18, -4, 24, 7, 3), hBox(52, -26, 20, 8, 3), hBox(84, -8, 16, 7, 3),
        ]), 0xF4FBFF)],
        channel: .gesture(4), opacity: HRamp(0, 1), offsetX: HRamp(40, -50), insideWindow: true,
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 5: the mountains are reflected in the lens: two ranges of peaks.
    dynamics.append(hLamp([hFill(hPoly([(-92, 27), (-62, 6), (-44, 16), (-14, -4), (14, 14), (42, 2), (92, 27)]), 0x7FD8F5, 0.55)], gesture: 5, inside: true))
    // Gesture 6: a slalom gate flashes past: a red pole with a flag, from the left.
    dynamics.append(HDynamic(
        draws: [hFill(hBox(-10, -10, 14, 76, 2), 0xE23B3B), hFill(hPoly([(-3, -44), (30, -34), (-3, -24)]), 0xE23B3B)],
        channel: .gesture(6), opacity: HRamp(0, 1), offsetX: HRamp(-70, 90), insideWindow: true,
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 7: sun glare: a pale disc and its ring flash up in the corner of the lens.
    dynamics.append(HDynamic(
        draws: [hFill(hOval(70, -30, 34, 34), 0xFFF6C8), hLine(hOval(70, -30, 50, 50), 0xFFF6C8, 6)],
        channel: .gesture(7), opacity: HRamp(0, 1), scale: HRamp(0.5, 1), pivot: CGPoint(x: 70, y: -30), insideWindow: true
    ))

    let spec = hHelmet(
        shell: shell, base: 0x2D3036, light: 0x555A63,
        lightPath: hCurve([(-106, -30), (-98, -72), (-62, -102), (-26, -106)]), edge: 0xBFE9F7,
        livery: livery,
        window: hBox(0, -10, 190, 74, 32), top: -47, bottom: 27, width: 190,
        glass: 0x0B1014, rim: 0x101214, rimWidth: 11,
        eyes: (w: 32, h: 34, y: -10, dx: 46, tx: 12, ty: 5, dim: 0xEAF6FA, bright: 0xFFFFFF),
        glint: [hLine(hPoly([(-80, 14), (-80, -16), (-58, -34)], closed: false), 0xFFFFFF, 6, 0.16)],
        plate: (fill: 0x1E5A70, edge: cyan, width: 4, deco: [hFill(hPoly([(-92, -42), (-58, -42), (-80, 42), (-114, 42)]), 0x2C7C96)]),
        flash: 0xB8F0FF, flashGesture: 3,
        above: above, dynamics: dynamics,
        visorNudge: 0.5, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // The vents open one after the other.
        hWalk([0.25, 0.5, 0.75, 1], ch: 0, each: 0.1),
        // The ear pads flex.
        [
            hs(0.1, hold: 0.06, ch: 1, lv: 1),
            hs(0.14, .easeInOut, ch: 1, lv: 0),
        ],
        // The buckle catches the light, the eyes glancing down at it.
        [
            hs(0.07, hold: 0.12, ch: 2, lv: 1, gx: 0.4, gy: 0.8),
            hs(0.14, .easeIn, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // The lens tint comes down: the light has changed.
        [
            hs(0.12, hold: 0.18, ch: 3, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
        // Powder spray flies across the goggles and the eyes narrow.
        [
            hs(0.1, .linear, ch: 4, lv: 0.5, dil: 0.8),
            hs(0.12, .linear, ch: 4, lv: 1, dil: 1),
            hReset(4),
        ],
        // The mountains show in the lens and the eyes look up at them.
        [
            hs(0.14, hold: 0.24, ch: 5, lv: 1, gx: 0.3, gy: -0.3),
            hs(0.18, .easeIn, ch: 5, lv: 0, gx: 0, gy: 0),
        ],
        // A slalom gate flashes past and the eyes follow it.
        [
            hs(0.04, hold: 0.03, gx: -0.8),
            hs(0.14, .linear, ch: 6, lv: 0.5, gx: 0),
            hs(0.14, .linear, ch: 6, lv: 1, gx: 0.8),
            hReset(6),
            hs(0.08, gx: 0),
        ],
        // Sun glare: the eyes screw up hard.
        [
            hs(0.06, hold: 0.2, ch: 7, lv: 1, dil: 0.7),
            hs(0.14, .easeIn, ch: 7, lv: 0, dil: 1),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Ski helmet with goggles: vented shell, ear pads, goggle strap, neck gaiter")
}

// MARK: - Forestry

/// A forestry helmet system: the hard hat, the ear defenders at its sides and the
/// mesh visor in front of the face. The visor is the lid and it flips down.
private func forestryHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (48, -108, 30), (84, -76, 26), (88, -30, 8), (88, 40, 12), (80, 84, 14), (48, 108, 14), (0, 108, 0),
    ])
    let orange: UInt32 = 0xFF5A1F
    let cupR = hOval(118, 26, 62, 74)
    let cupL = hOval(-118, 26, 62, 74)
    let verticals: [CGFloat] = [-60, -36, -12, 12, 36, 60]
    let groups: [[CGFloat]] = [[-60, -36], [-12, 12], [36, 60]]
    let meshLine: (CGFloat) -> HPath = { x in hPoly([(x, -20), (x, 64)], closed: false) }

    var livery: [HDraw] = []
    livery.append(hLine(hCurve([(-90, -44), (-54, -72), (0, -80), (54, -72), (90, -44)]), orange, 14, clip: true))
    livery.append(hFill(hBox(0, 90, 320, 50), 0x202326, clip: true))

    var above: [HDraw] = []
    above.append(hLine(hTogether(verticals.map(meshLine)), 0x9AA3AE, 6, 0.55))
    above.append(hLine(hTogether([0, 22, 44].map { hPoly([(-68, CGFloat($0)), (68, CGFloat($0))], closed: false) }), 0x9AA3AE, 6, 0.55))

    var dynamics: [HDynamic] = []
    // Gesture 0: the ear defenders clamp in, towards the head. Drawn at rest.
    dynamics.append(HDynamic(draws: [hFill(cupR, 0x23272B), hLine(cupR, 0xFFC4AA, 7), hFill(hOval(120, 26, 34, 44), orange)],
                             channel: .gesture(0), offsetX: HRamp(0, -9)))
    dynamics.append(HDynamic(draws: [hFill(cupL, 0x23272B), hLine(cupL, 0xFFC4AA, 7), hFill(hOval(-120, 26, 34, 44), orange)],
                             channel: .gesture(0), offsetX: HRamp(0, 9)))
    // Gesture 1: a light runs across the mesh.
    for (index, xs) in groups.enumerated() {
        dynamics.append(hGlow([hLine(hTogether(xs.map(meshLine)), 0xFFFFFF, 6)], gesture: 1, center: CGFloat(index + 1) / 4, width: 0.25))
    }
    // Gesture 3: the high-visibility band strobes.
    dynamics.append(hLamp([hLine(hCurve([(-90, -44), (-54, -72), (0, -80), (54, -72), (90, -44)]), 0xFFE2D2, 14, clip: true)], gesture: 3))


    // Gesture 4: wood chips fly off to the upper right.
    for (x, y, dx, dy, turn) in [(-40, 70, 70, -80, 200), (-20, 84, 90, -50, -160), (0, 76, 60, -100, 240), (20, 88, 110, -30, -200)] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
        dynamics.append(HDynamic(
            draws: [hFill(hBox(x, y, 14, 8, 2), 0xC9985A)],
            channel: .gesture(4), opacity: HRamp(0, 1), offsetX: HRamp(0, dx), offsetY: HRamp(0, dy),
            rotation: HRamp(0, turn), pivot: CGPoint(x: x, y: y), pulse: HPulse(center: 0.5, width: 0.5)
        ))
    }
    // Gesture 5: timber! a pine falls across the front from the right.
    dynamics.append(HDynamic(
        draws: [
            hFill(hBox(120, 94, 10, 20), 0x6B4A2B),
            hFill(hPoly([(120, 8), (98, 48), (142, 48)]), 0x3FA34D),
            hFill(hPoly([(120, 28), (94, 72), (146, 72)]), 0x34903F),
        ],
        channel: .gesture(5), opacity: HRamp(0, 1), rotation: HRamp(-8, -80), pivot: CGPoint(x: 120, y: 104),
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 6: the radio crackles: the centres of both ear defenders light.
    dynamics.append(hLamp([hFill(hOval(120, 26, 34, 44), 0xFFE2D2), hFill(hOval(-120, 26, 34, 44), 0xFFE2D2)], gesture: 6))
    // Gesture 7: a small bird lands on the hat.
    dynamics.append(HDynamic(
        draws: [
            hFill(hOval(0, -92, 24, 16), 0xE8C46A),
            hFill(hPoly([(-12, -92), (-22, -86), (-12, -88)]), 0xC9A24A),
            hFill(hPoly([(11, -94), (20, -91), (11, -89)]), 0xFF8A3D),
            hFill(hOval(5, -95, 4, 4), 0x16181B),
        ],
        channel: .gesture(7), opacity: HRamp(0, 1), offsetY: HRamp(-8, 0)
    ))

    let spec = hHelmet(
        shell: shell, base: 0x2B2E32, light: 0x4D5258,
        lightPath: hCurve([(-88, -34), (-82, -76), (-52, -106), (-22, -110)]), edge: 0xFFD0BA,
        livery: livery,
        window: hBox(0, 22, 150, 88, 24), top: -22, bottom: 66, width: 150,
        glass: 0x0B0D0C, rim: 0x101213, rimWidth: 10,
        eyes: (w: 28, h: 28, y: 22, dx: 38, tx: 12, ty: 5, dim: 0xF4ECE2, bright: 0xFFFFFF),
        plate: (fill: 0x1F2A26, edge: orange, width: 4, deco: []),
        flash: 0xFFE2D2, flashGesture: 2,
        above: above, dynamics: dynamics,
        visorNudge: 0.6, visorGesture: 2
    )
    let gestures: [[SignatureStep]] = [
        // The ear defenders clamp in and are let go.
        [
            hs(0.1, hold: 0.08, ch: 0, lv: 1),
            hs(0.14, .easeInOut, ch: 0, lv: 0),
        ],
        // A light runs across the mesh.
        hWalk([0.25, 0.5, 0.75, 1], ch: 1, each: 0.1),
        // The mesh visor is flipped down over the face and back up.
        [
            hs(0.14, hold: 0.16, ch: 2, lv: 1, dil: 0.9),
            hs(0.18, .easeIn, ch: 2, lv: 0, dil: 1),
        ],
        // The hi-vis band strobes, twice.
        [
            hs(0.06, hold: 0.03, ch: 3, lv: 1),
            hs(0.1, hold: 0.04, .easeIn, ch: 3, lv: 0),
            hs(0.06, hold: 0.03, ch: 3, lv: 1),
            hs(0.12, .easeIn, ch: 3, lv: 0),
        ],
        // Wood chips fly off and the eyes narrow behind the visor.
        [
            hs(0.12, hold: 0.06, ch: 4, lv: 0.5, dil: 0.85),
            hs(0.16, .easeIn, ch: 4, lv: 1, dil: 1),
            hReset(4),
        ],
        // Timber! A pine falls across the front and the eyes look up, then follow it down.
        [
            hs(0.1, hold: 0.04, ch: 5, lv: 0.5, gx: 0.6, gy: -0.6),
            hs(0.14, .easeIn, ch: 5, lv: 1, gx: -0.2, gy: 0.5),
            hReset(5),
            hs(0.1, gx: 0, gy: 0),
        ],
        // The radio crackles: the ear defenders flash twice and the eyes glance aside.
        [
            hs(0.06, hold: 0.04, ch: 6, lv: 1, gx: 0.8),
            hs(0.08, hold: 0.04, .easeIn, ch: 6, lv: 0),
            hs(0.06, hold: 0.06, ch: 6, lv: 1),
            hs(0.12, .easeIn, ch: 6, lv: 0, gx: 0, gy: 0),
        ],
        // A small bird lands on the hat and the eyes look up at it.
        [
            hs(0.1, hold: 0.24, ch: 7, lv: 1, gx: 0, gy: -0.8),
            hs(0.14, .easeIn, ch: 7, lv: 0, gx: 0, gy: 0),
        ],
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Forestry helmet system: hard hat, ear defenders, mesh visor")
}

// MARK: - Custodian

/// The British police custodian helmet: the tall bell with its rose top, the plain
/// plate on the front, the brim and the chin strap. The brim's shade is the lid.
private func custodianHelmet() -> HelmetEntry {
    let shell = hSym([
        (0, -112, 0), (8, -112, 3), (10, -98, 0), (40, -94, 18), (78, -68, 22), (90, -28, 6), (100, -14, 0), (118, -8, 8),
        (120, 10, 6), (94, 14, 0), (88, 46, 14), (66, 92, 18), (30, 110, 12), (0, 110, 0),
    ])
    let chrome: UInt32 = 0xD6DCE8
    let plate = hPoly([(-24, -84), (24, -84), (30, -44), (0, -28), (-30, -44)])
    let strap = hCurve([(-86, 48), (-60, 76), (0, 96), (60, 76), (86, 48)])
    let buckle = hBox(66, 74, 18, 14, 4)
    let rose = hOval(0, -104, 16, 16)

    var livery: [HDraw] = []
    livery.append(hLine(hPoly([(-124, 2), (124, 2)], closed: false), chrome, 8, clip: true))
    livery.append(hFill(plate, chrome, clip: true))
    livery.append(hFill(hPoly([(-14, -70), (14, -70), (16, -50), (0, -40), (-16, -50)]), 0x1E2742, clip: true))
    livery.append(hLine(strap, 0x10131C, 9, clip: true))

    var above: [HDraw] = [hFill(buckle, chrome)]
    above.append(hFill(rose, chrome))

    var dynamics: [HDynamic] = []
    // Gesture 0: the rose top catches the light.
    dynamics.append(hLamp([hFill(rose, 0xFFFFFF)], gesture: 0))
    // Gesture 1: the plate on the front shines and fades.
    dynamics.append(hGlow([hFill(plate, 0xFFFFFF, 0.8, clip: true)], gesture: 1, center: 0.5, width: 0.5))
    // Gesture 2: the buckle of the chin strap catches the light.
    dynamics.append(hLamp([hFill(buckle, 0xFFFFFF)], gesture: 2))


    // Gesture 4: a patrol car's blue lights wash the helmet, left, right, left, right.
    dynamics.append(hGlow([hFill(hBox(-80, 0, 160, 230), 0x3C6BFF, 0.35, clip: true)], gesture: 4, center: 1.0 / 3, width: 1.0 / 3))
    dynamics.append(hGlow([hFill(hBox(80, 0, 160, 230), 0x3C6BFF, 0.35, clip: true)], gesture: 4, center: 2.0 / 3, width: 1.0 / 3))
    // Gesture 5: a cup of tea: a white cup at the lower left, and steam rising from it.
    dynamics.append(hLamp([hFill(hBox(-52, 94, 28, 20, 5), 0xF2F2F2), hLine(hOval(-33, 94, 12, 10), 0xF2F2F2, 4)], gesture: 5))
    dynamics.append(HDynamic(
        draws: [
            hLine(hCurve([(-58, 82), (-52, 72), (-58, 62)]), 0xFFFFFF, 5, 0.85),
            hLine(hCurve([(-46, 82), (-40, 72), (-46, 62)]), 0xFFFFFF, 5, 0.85),
        ],
        channel: .gesture(5), opacity: HRamp(0, 1), offsetY: HRamp(0, -14)
    ))
    // Gesture 6: the badge on the plate flashes.
    dynamics.append(hLamp([hFill(hPoly([(-14, -70), (14, -70), (16, -50), (0, -40), (-16, -50)]), 0x9DB4FF, clip: true)], gesture: 6))
    // Gesture 7: the helmet rings like a bell: arcs flare out either side.
    let ring = hTogether([hCurve([(-112, -4), (-122, 18), (-112, 40)]), hCurve([(-128, -14), (-142, 18), (-128, 50)])])
    dynamics.append(HDynamic(
        draws: [hLine(ring, 0xE6ECFF, 6), hLine(hMirror(ring), 0xE6ECFF, 6)],
        channel: .gesture(7), opacity: HRamp(0, 1), scale: HRamp(0.8, 1.15), pivot: CGPoint(x: 0, y: 18),
        pulse: HPulse(center: 0.5, width: 0.5)
    ))

    let spec = hHelmet(
        shell: shell, base: 0x1E2742, light: 0x45527F,
        lightPath: hCurve([(-90, -26), (-78, -68), (-40, -94), (-10, -98)]), edge: 0xB4C0EA,
        livery: livery,
        window: hBox(0, 34, 140, 58, 22), top: 5, bottom: 63, width: 140,
        rim: 0x0A0D16, rimWidth: 10,
        eyes: (w: 28, h: 30, y: 34, dx: 36, tx: 10, ty: 4, dim: 0xF2F4FA, bright: 0xFFFFFF),
        plate: (fill: 0x151A2E, edge: chrome, width: 4, deco: [hFill(hPoly([(-70, -34), (-40, -34), (-58, 34), (-88, 34)]), 0x232B48)]),
        flash: 0xFFFFFF, flashGesture: 3,
        above: above, dynamics: dynamics,
        visorNudge: 0.4, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // The rose top catches the light and the eyes look up.
        [
            hs(0.07, hold: 0.12, ch: 0, lv: 1, gx: 0, gy: -0.8),
            hs(0.14, .easeIn, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // The plate on the front shines and fades.
        hWalk([0.5, 1], ch: 1, each: 0.14),
        // The buckle catches the light, the eyes glancing down at it.
        [
            hs(0.07, hold: 0.12, ch: 2, lv: 1, gx: 0.5, gy: 0.8),
            hs(0.14, .easeIn, ch: 2, lv: 0, gx: 0, gy: 0),
        ],
        // The brim tips down over the eyes: a salute.
        [
            hs(0.12, hold: 0.18, ch: 3, lv: 1, dil: 0.85),
            hs(0.16, .easeIn, ch: 3, lv: 0, dil: 1),
        ],
        // The blue lights of a patrol car wash the helmet, and the eyes flick with them.
        [
            hs(0.07, .linear, ch: 4, lv: 1.0 / 3, gx: -0.8),
            hs(0.07, .linear, ch: 4, lv: 2.0 / 3, gx: 0.8),
            hs(0.07, .linear, ch: 4, lv: 1.0 / 3, gx: -0.8),
            hs(0.07, .linear, ch: 4, lv: 2.0 / 3, gx: 0.8),
            hs(0.10, .linear, ch: 4, lv: 1, gx: 0, gy: 0),
            hReset(4),
        ],
        // A cup of tea: the eyes look down at it, and narrow in the steam.
        [
            hs(0.12, hold: 0.22, ch: 5, lv: 1, gx: -0.5, gy: 0.8, dil: 0.9),
            hs(0.16, .easeIn, ch: 5, lv: 0, gx: 0, gy: 0, dil: 1),
        ],
        // The badge flashes twice.
        [
            hs(0.06, hold: 0.06, ch: 6, lv: 1),
            hs(0.08, hold: 0.05, .easeIn, ch: 6, lv: 0),
            hs(0.06, hold: 0.08, ch: 6, lv: 1),
            hs(0.12, .easeIn, ch: 6, lv: 0),
        ],
        // The helmet rings like a bell, twice.
        hWalk([0.5, 1], ch: 7, each: 0.08) + hWalk([0.5, 1], ch: 7, each: 0.08),
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "British police custodian helmet: tall bell, rose top, front plate, brim, chin strap")
}

// MARK: - Fencing

/// A fencing mask: the steel mesh over the face, the strap that goes over the crown,
/// the bib that covers the neck. The mask being lifted is the lid: a salute.
private func fencingMask() -> HelmetEntry {
    let shell = hSym([
        (0, -104, 0), (56, -100, 32), (96, -66, 28), (100, -20, 10), (98, 24, 8), (64, 50, 0), (132, 112, 6), (0, 112, 0),
    ])
    let violet: UInt32 = 0x9B7BFF
    let verticals: [CGFloat] = [-72, -48, -24, 0, 24, 48, 72]
    let meshLine: (CGFloat) -> HPath = { x in hPoly([(x, -46), (x, 38)], closed: false) }
    let groups: [[CGFloat]] = [[-72, -48], [-24, 0], [24, 48], [72]]
    let bib = hPoly([(-160, 52), (160, 52), (160, 116), (-160, 116)])
    let strap = hBox(0, -78, 26, 56)

    var livery: [HDraw] = []
    livery.append(hFill(bib, 0x20232A, clip: true))
    livery.append(hLine(hPoly([(-160, 56), (160, 56)], closed: false), violet, 8, clip: true))

    var above: [HDraw] = []
    above.append(hLine(hTogether(verticals.map(meshLine)), 0x9AA3B0, 6, 0.5))
    above.append(hLine(hTogether([-26, 0, 26].map { hPoly([(-84, CGFloat($0)), (84, CGFloat($0))], closed: false) }), 0x9AA3B0, 6, 0.5))

    var dynamics: [HDynamic] = []
    // Gesture 0: a hit registers: the bib flashes.
    dynamics.append(hLamp([hFill(bib, 0xD8CCFF, 0.7, clip: true), hLine(hPoly([(-160, 56), (160, 56)], closed: false), 0xFFFFFF, 8, clip: true)], gesture: 0))
    // Gesture 1: a light runs across the mesh.
    for (index, xs) in groups.enumerated() {
        dynamics.append(hGlow([hLine(hTogether(xs.map(meshLine)), 0xFFFFFF, 6)], gesture: 1, center: CGFloat(index + 1) / 5, width: 0.2))
    }
    // Gesture 2: the strap over the crown is pulled tight. Drawn at rest.
    dynamics.append(HDynamic(draws: [hFill(strap, 0x2E3038, clip: true), hFill(hBox(0, -78, 6, 56), violet, clip: true)],
                             channel: .gesture(2), scale: HRamp(1, 1.22), pivot: CGPoint(x: 0, y: -104)))


    // Gesture 4: a foil lunges at the face from the right, with its bell guard.
    dynamics.append(HDynamic(
        draws: [
            hLine(hCurve([(150, 24), (100, 14), (40, 0)]), 0xD7DCE6, 6),
            hFill(hOval(124, 22, 22, 22), 0x7A7F8C),
            hLine(hOval(124, 22, 22, 22), 0xD7DCE6, 4),
        ],
        channel: .gesture(4), opacity: HRamp(0, 1), offsetX: HRamp(40, -20), pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 5: the scoring lights: red at the upper left, green at the upper right.
    dynamics.append(hGlow([hFill(hBox(-62, -84, 24, 18, 5), 0xFF3B30)], gesture: 5, center: 1.0 / 3, width: 1.0 / 3))
    dynamics.append(hGlow([hFill(hBox(62, -84, 24, 18, 5), 0x2ECC71)], gesture: 5, center: 2.0 / 3, width: 1.0 / 3))
    // Gesture 6: the mesh flexes under the hit: a bright copy swells and settles.
    dynamics.append(HDynamic(
        draws: [
            hLine(hTogether(verticals.map(meshLine)), 0xFFFFFF, 6),
            hLine(hTogether([-26, 0, 26].map { hPoly([(-84, CGFloat($0)), (84, CGFloat($0))], closed: false) }), 0xFFFFFF, 6),
        ],
        channel: .gesture(6), opacity: HRamp(0, 1), scale: HRamp(1, 1.1), pivot: CGPoint(x: 0, y: -4),
        pulse: HPulse(center: 0.5, width: 0.5)
    ))
    // Gesture 7: a light runs along the violet band of the bib.
    dynamics += hChase(
        HShape.spans(hPoly([(-160, 56), (-80, 56), (0, 56), (80, 56), (160, 56)], closed: false)),
        hex: 0xE8E0FF, width: 8, gesture: 7, clip: true
    )

    let spec = hHelmet(
        shell: shell, base: 0x26282F, light: 0x4B4E59,
        lightPath: hCurve([(-98, -18), (-92, -62), (-56, -96), (-24, -100)]), edge: 0xD2C6F6,
        livery: livery,
        window: hBox(0, -4, 168, 90, 34), top: -49, bottom: 41, width: 168,
        glass: 0x0C0D11, rim: 0x14161B, rimWidth: 10, restFraction: 0.25,
        eyes: (w: 28, h: 30, y: -4, dx: 42, tx: 12, ty: 5, dim: 0xF0EEF8, bright: 0xFFFFFF),
        plate: (fill: 0x3A3D4E, edge: violet, width: 4, deco: [hFill(hPoly([(-70, -50), (-40, -50), (-56, 50), (-86, 50)]), 0x4B4F63)]),
        flash: 0xD8CCFF, flashGesture: 3,
        above: above, dynamics: dynamics,
        raisesVisor: true, visorGesture: 3
    )
    let gestures: [[SignatureStep]] = [
        // A hit registers: the bib flashes twice and the eyes shiver.
        [
            hs(0.05, hold: 0.02, ch: 0, lv: 1, gx: -0.8),
            hs(0.08, hold: 0.03, .easeIn, ch: 0, lv: 0, gx: 0.8),
            hs(0.05, hold: 0.02, ch: 0, lv: 1, gx: -0.8),
            hs(0.1, .easeIn, ch: 0, lv: 0, gx: 0, gy: 0),
        ],
        // A light runs across the mesh.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 1, each: 0.08),
        // The strap over the crown is pulled tight and let go.
        [
            hs(0.1, hold: 0.1, ch: 2, lv: 1),
            hs(0.14, .easeInOut, ch: 2, lv: 0),
        ],
        // The mask is lifted: a salute.
        [
            hs(0.14, hold: 0.18, ch: 3, lv: 1),
            hs(0.2, .easeIn, ch: 3, lv: 0),
        ],
        // A foil lunges at the face and the eyes recoil.
        [
            hs(0.1, .easeIn, ch: 4, lv: 0.5, gx: -0.8),
            hs(0.14, ch: 4, lv: 1, gx: 0, gy: 0),
            hReset(4),
        ],
        // The scoring lights: red, then green, and the eyes look up at each.
        [
            hs(0.08, .linear, ch: 5, lv: 1.0 / 3, gx: -0.8, gy: -0.5),
            hs(0.08, .linear, ch: 5, lv: 2.0 / 3, gx: 0.8, gy: -0.5),
            hs(0.10, .linear, ch: 5, lv: 1, gx: 0, gy: 0),
            hReset(5),
        ],
        // The mesh flexes under the hit and the eyes narrow.
        [
            hs(0.06, hold: 0.04, ch: 6, lv: 0.5, dil: 0.85),
            hs(0.12, .easeIn, ch: 6, lv: 1, dil: 1),
            hReset(6),
        ],
        // A light runs along the violet band.
        hWalk([0.2, 0.4, 0.6, 0.8, 1], ch: 7, each: 0.08),
    ]
    return HelmetEntry(spec: spec, gestures: gestures, reference: "Fencing mask: steel mesh, crown strap, bib")
}
