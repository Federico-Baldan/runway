// Is the island actually centred?
//
// It was not, in the project this is a port of: it sat 425pt off-centre on a
// MacBook. The cause is that `visibleFrame` excludes the Dock, so on a Mac with
// the Dock on the left its midX is half a Dock-width away from the screen's.
// Centring on the wrong one looks fine on the developer's machine and wrong on
// everybody else's.
//
//   swiftc -o /tmp/centering spike/CenteringVerify.swift \
//       Sources/Runway/UI/NotchMath.swift && /tmp/centering

import CoreGraphics
import Foundation

@main
enum CenteringVerify {
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

        // A 14" MacBook Pro with the Dock on the LEFT. The Dock is 80pt wide, so the
        // visible frame starts at x=80 and its midX is 40pt right of the screen's.
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleWithLeftDock = CGRect(x: 80, y: 0, width: 1432, height: 944)
        let size = CGSize(width: 620, height: 422)

        print("── notched Mac, Dock on the left ──")
        let notched = NotchMath.origin(
            screenFrame: screenFrame, visibleFrame: visibleWithLeftDock,
            size: size, hasNotch: true
        )
        let expectedX = (screenFrame.midX - size.width / 2).rounded()
        print("  screen midX  \(screenFrame.midX)")
        print("  visible midX \(visibleWithLeftDock.midX)   <- centring on this is the bug")
        print("  origin.x     \(notched.x), expected \(expectedX)")
        assert("centred on the SCREEN, not the visible frame", notched.x == expectedX)
        assert("island centre lands on the screen centre",
               notched.x + size.width / 2 == screenFrame.midX)
        assert("does NOT centre on the visible frame",
               notched.x + size.width / 2 != visibleWithLeftDock.midX)
        assert("flush with the top of the screen, under the cutout",
               notched.y == (screenFrame.maxY - size.height).rounded())

        print()
        print("── the same screen with the Dock at the bottom ──")
        // Horizontal placement must not change just because the Dock moved.
        let visibleWithBottomDock = CGRect(x: 0, y: 80, width: 1512, height: 864)
        let bottomDock = NotchMath.origin(
            screenFrame: screenFrame, visibleFrame: visibleWithBottomDock,
            size: size, hasNotch: true
        )
        assert("moving the Dock does not move the island sideways", bottomDock.x == notched.x)

        print()
        print("── notchless external display ──")
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let externalVisible = CGRect(x: 1512, y: 0, width: 2560, height: 1415)
        let pill = NotchMath.origin(
            screenFrame: external, visibleFrame: externalVisible, size: size, hasNotch: false
        )
        assert("centred horizontally on a non-zero-origin screen too",
               pill.x + size.width / 2 == external.midX)
        assert("sits 6pt under the menu bar, clear of it",
               pill.y == (externalVisible.maxY - size.height - 6).rounded())
        assert("below the top of the screen, not on top of the menu bar",
               pill.y + size.height < external.maxY)

        print()
        print("── integral coordinates ──")
        // A half-pixel origin makes the pill's edge blurry on a Retina display.
        let odd = CGRect(x: 0, y: 0, width: 1511, height: 981)
        let oddOrigin = NotchMath.origin(
            screenFrame: odd, visibleFrame: odd, size: CGSize(width: 621, height: 423), hasNotch: true
        )
        assert("origin.x is integral", oddOrigin.x == oddOrigin.x.rounded())
        assert("origin.y is integral", oddOrigin.y == oddOrigin.y.rounded())

        print()
        if failures == 0 {
            print("RESULT: PASS — the island is centred on every layout checked")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
