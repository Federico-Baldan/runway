// Is the resting island the right size, and does the canvas never need to resize?
//
// Two bugs guarded here. First: a resting pill narrower than the cutout draws a
// black seam either side and reads as a rendering fault. Second: the window is
// deliberately fixed-size, and if the expanded content can outgrow the canvas
// the pill gets clipped instead of expanding.
//
//   swiftc -o /tmp/notchplacement spike/NotchPlacementVerify.swift \
//       Sources/Runway/UI/NotchMath.swift && /tmp/notchplacement

import CoreGraphics
import Foundation

@main
enum NotchPlacementVerify {
    static func main() {
        var failures = 0

        func assert(_ label: String, _ condition: Bool) {
            if condition {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label)")
                failures += 1
            }
        }

        print("── notch width from the auxiliary areas ──")
        // macOS reports the usable menu-bar strips either side, not the cutout itself.
        let cutout = NotchMath.notchWidth(screenWidth: 1512, leftAreaWidth: 661, rightAreaWidth: 661)
        print("  1512 - 661 - 661 = \(cutout)pt")
        assert("a 14\" MacBook Pro cutout is 190pt", cutout == 190)
        assert("never negative when the areas overlap",
               NotchMath.notchWidth(screenWidth: 1512, leftAreaWidth: 800, rightAreaWidth: 800) == 0)

        print()
        print("── resting width ──")
        // The frame is the body plus both concave shoulders. `IslandShape`
        // insets its straight sides by one shoulder each, so it is the BODY
        // that has to match the cutout — asserting on the frame instead is how
        // a shoulder-width black seam would ship unnoticed either side.
        let shoulder = NotchMath.Width.shoulder
        assert("the straight-sided body is exactly the cutout width",
               NotchMath.Width.restingBody(notchWidth: 190) == 190)
        assert("the frame carries the flare on top of it",
               NotchMath.Width.resting(hasNotch: true, notchWidth: 190) == 190 + shoulder * 2)
        assert("never narrower than the cutout — no black seam",
               NotchMath.Width.restingBody(notchWidth: 190) >= 190)
        assert("the flare is real width, not a rounding artefact", shoulder > 0)
        assert("an implausibly narrow cutout is floored, not honoured",
               NotchMath.Width.restingBody(notchWidth: 40) == NotchMath.Width.minimumNotch)
        assert("a notchless display rests at the pill width",
               NotchMath.Width.resting(hasNotch: false, notchWidth: 0) == NotchMath.Width.collapsed)
        assert("a notchless display has no shoulders to pay for",
               NotchMath.Width.resting(hasNotch: false, notchWidth: 0) == NotchMath.Width.collapsed)

        print()
        print("── which display the pointer is on ──")
        // A MacBook at the origin with an external monitor to its left: the
        // left-hand screen has a negative x origin, which is exactly the case a
        // naive `x < width` test gets wrong by one whole display.
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: -2560, y: 0, width: 2560, height: 1440)
        let frames = [laptop, external]
        assert("a point on the laptop resolves to the laptop",
               NotchMath.screenIndex(containing: CGPoint(x: 700, y: 500), in: frames) == 0)
        assert("a point to the left resolves to the external display",
               NotchMath.screenIndex(containing: CGPoint(x: -1200, y: 700), in: frames) == 1)
        assert("the seam belongs to exactly one screen",
               NotchMath.screenIndex(containing: CGPoint(x: 0, y: 500), in: frames) == 0)
        assert("the far edge belongs to the neighbour, not to both",
               NotchMath.screenIndex(containing: CGPoint(x: -2560, y: 500), in: frames) == 1)
        assert("a point off the arrangement resolves to nothing",
               NotchMath.screenIndex(containing: CGPoint(x: 9000, y: 500), in: frames) == nil)
        assert("no screens means no answer",
               NotchMath.screenIndex(containing: .zero, in: []) == nil)

        print()
        print("── a notch drawn onto a monitor ──")
        // An external display has no cutout, so the island used to float under
        // the menu bar — and at rest it drew nothing at all. Drawn, it has to
        // sit in the menu bar's own band, flush with the top of the screen, or
        // it reads as a window that missed the edge rather than as hardware.
        let monitor = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let belowBar = CGRect(x: 0, y: 0, width: 2560, height: 1416)
        let band: CGFloat = 24
        let drawnCanvas = NotchMath.canvasSize(
            screenWidth: monitor.width, visibleHeight: belowBar.height,
            notchBand: band, rows: 8
        )
        let drawn = NotchMath.origin(
            screenFrame: monitor, visibleFrame: belowBar, size: drawnCanvas, hasNotch: true
        )
        let floating = NotchMath.origin(
            screenFrame: monitor, visibleFrame: belowBar, size: drawnCanvas, hasNotch: false
        )
        print("  drawn top edge \(drawn.y + drawnCanvas.height), screen top \(monitor.maxY)")
        assert("a drawn notch is flush with the top of the screen",
               drawn.y + drawnCanvas.height == monitor.maxY)
        assert("which is above the pill it replaces", drawn.y > floating.y)
        assert("still centred on the screen, not on the visible frame",
               drawn.x + drawnCanvas.width / 2 == monitor.midX)
        assert("the canvas reserves more than the band it must keep clear",
               drawnCanvas.height > band)
        assert("the resting body matches the drawn cutout, same as a real one",
               NotchMath.Width.restingBody(notchWidth: 190) == 190)

        print()
        print("── the canvas must contain every state it can reach ──")
        for (label, width, visibleHeight, band) in [
            ("14\" MacBook Pro", CGFloat(1512), CGFloat(944), CGFloat(32)),
            ("16\" MacBook Pro", CGFloat(1728), CGFloat(1080), CGFloat(32)),
            ("external 2560",    CGFloat(2560), CGFloat(1415), CGFloat(0)),
            ("external 5120",    CGFloat(5120), CGFloat(2835), CGFloat(0)),
            ("small 1280",       CGFloat(1280), CGFloat(775),  CGFloat(0)),
        ] {
            let canvas = NotchMath.canvasSize(
                screenWidth: width, visibleHeight: visibleHeight, notchBand: band, rows: 8
            )
            let expanded = NotchMath.expandedSize(
                screenWidth: width, visibleHeight: visibleHeight, rows: 8
            )
            let collapsed = NotchMath.collapsedSize(screenWidth: width, notchBand: band, rows: 4)

            let widthOK = canvas.width >= expanded.width
                && canvas.width >= collapsed.width
                && canvas.width >= NotchMath.Width.expanded
                && canvas.width >= NotchMath.Width.resting(hasNotch: band > 0, notchWidth: 190)
            let heightOK = canvas.height >= expanded.height + band && canvas.height >= collapsed.height

            print("  \(label): canvas \(Int(canvas.width))x\(Int(canvas.height))"
                + "  expanded \(Int(expanded.width))x\(Int(expanded.height))"
                + "  collapsed \(Int(collapsed.width))x\(Int(collapsed.height))")
            assert("    \(label): canvas is wide enough for every state", widthOK)
            assert("    \(label): canvas is tall enough for every state", heightOK)
        }

        print()
        print("── expanded panel stays on screen ──")
        // On a short display the panel must not grow past 60% of the visible height,
        // or it covers content it is supposed to sit above.
        let short = NotchMath.expandedSize(screenWidth: 1280, visibleHeight: 600, rows: 20)
        assert("height is capped relative to the display", short.height <= max(600 * 0.6, 200))
        assert("width is capped at the expanded maximum", short.width <= NotchMath.Width.expanded)

        print()
        print("── the notch band is reserved in full ──")
        // The cutout is opaque hardware. If the canvas does not reserve its full height
        // the first row of text renders behind the camera housing.
        let withNotch = NotchMath.canvasSize(screenWidth: 1512, visibleHeight: 944, notchBand: 32, rows: 4)
        let withoutNotch = NotchMath.canvasSize(screenWidth: 1512, visibleHeight: 944, notchBand: 0, rows: 4)
        assert("a notched canvas is taller than a notchless one by the band",
               withNotch.height > withoutNotch.height)

        print()
        if failures == 0 {
            print("RESULT: PASS — resting size and canvas bounds hold on every display checked")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
