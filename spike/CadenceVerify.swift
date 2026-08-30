// What does the poll loop actually do when two power signals disagree?
//
// The cadence has five inputs — retry backoff, screen sleep, Low Power Mode,
// rate-limit headroom, and whether anything is building — and they are checked
// in an order that decides the answer. That ordering is exactly the kind of
// thing that reads as obviously correct and is not: a `return` in the wrong
// branch silently drops a slower constraint on the floor, and the symptom is a
// battery complaint weeks later, on somebody else's laptop.
//
//   swiftc -o /tmp/cadence spike/CadenceVerify.swift \
//       Sources/Runway/Core/RunMonitor.swift Sources/Runway/API/GitHubClient.swift \
//       Sources/Runway/API/Models.swift Sources/Runway/API/RunScope.swift \
//       Sources/Runway/API/ETagStore.swift Sources/Runway/Auth/Keychain.swift \
//       && /tmp/cadence

import Foundation

@main
enum CadenceVerify {
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

        let cadence = RunMonitor.Cadence()

        func interval(
            failures failureCount: Int = 0,
            suspended: Bool = false,
            lowPower: Bool = false,
            tight: Bool = false,
            active: Bool = false
        ) -> TimeInterval {
            RunMonitor.interval(
                cadence: cadence,
                failureCount: failureCount,
                isSuspended: suspended,
                isLowPower: lowPower,
                isRateLimitTight: tight,
                hasActiveRun: active
            )
        }

        print("── the ordinary cases ──")
        assert("idle polls at \(Int(cadence.idle))s", interval() == cadence.idle)
        assert("a live run polls at \(Int(cadence.active))s", interval(active: true) == cadence.active)

        print()
        print("── backoff outranks everything ──")
        // A failing request retried faster helps nobody, and the reason it is
        // failing may be the very thing the other signals are about.
        assert("one failure -> backoffBase", interval(failures: 1) == cadence.backoffBase)
        assert("four failures -> 40s", interval(failures: 4) == 40)
        assert("backoff is capped", interval(failures: 20) == cadence.backoffCeiling)
        assert(
            "backoff wins over a live run",
            interval(failures: 3, active: true) == cadence.backoffBase * 4
        )

        print()
        print("── a dark screen outranks the rest ──")
        assert("suspended -> \(Int(cadence.suspended))s", interval(suspended: true) == cadence.suspended)
        assert(
            "suspended wins over a live run",
            interval(suspended: true, active: true) == cadence.suspended
        )
        assert(
            "suspended wins over Low Power Mode",
            interval(suspended: true, lowPower: true) == cadence.suspended
        )

        print()
        print("── floors, not replacements ──")
        // This is the regression the whole spike exists for. Both Low Power Mode
        // and a nearly-spent rate-limit budget slow the loop down. If either is
        // written as `return` rather than as a floor, whichever is checked first
        // wins and the other is silently discarded — including when it was the
        // slower, and therefore the binding, one.
        assert(
            "Low Power Mode raises an idle poll to \(Int(cadence.lowPower))s",
            interval(lowPower: true) == cadence.lowPower
        )
        assert(
            "Low Power Mode raises an ACTIVE poll to \(Int(cadence.lowPower))s too",
            interval(lowPower: true, active: true) == cadence.lowPower
        )
        assert(
            "a tight budget raises an active poll to \(Int(cadence.conserving))s",
            interval(tight: true, active: true) == cadence.conserving
        )
        assert(
            "with both, the SLOWER one wins",
            interval(lowPower: true, tight: true, active: true)
                == max(cadence.conserving, cadence.lowPower)
        )

        print()
        print("── the floors never speed anything up ──")
        // A floor that could lower the interval would turn a battery-saving
        // signal into a battery-spending one.
        for lowPower in [false, true] {
            for tight in [false, true] {
                for active in [false, true] {
                    let base = active ? cadence.active : cadence.idle
                    let got = interval(lowPower: lowPower, tight: tight, active: active)
                    assert(
                        "lowPower=\(lowPower) tight=\(tight) active=\(active) -> \(Int(got))s >= \(Int(base))s",
                        got >= base
                    )
                }
            }
        }

        print()
        if failures == 0 {
            print("RESULT: PASS — cadence precedence holds on every combination checked")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
