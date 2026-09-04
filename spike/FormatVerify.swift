// Does the blocked pill's counter survive the cadence it is drawn at — and
// does that cadence behave at all?
//
// `IslandModel.tickSeconds` drops a blocked island to a 15-second tick, on the
// stated grounds that a run parked on an approval "does not count anything".
// `RunLine.waitingLabel` was counting seconds against it, so the number people
// watch while a deploy waits on somebody went 0s -> 15s -> 30s -> 45s -> 1:00,
// with `.numericText()` rolling the digits through each leap. The label was the
// half that changed; this is what pins it.
//
// NOT wired into `make spikes-offline`. `IslandModel.swift` pulls in the whole
// monitor stack plus `IdleMarkPosition` and `IdleMarkTint`, and the full SRC
// list for that has not been checked against a Mac — a wrong one would break
// the target for everybody. Run it by hand, or wire it once the list is known
// good:
//
//   swiftc -o /tmp/formatverify spike/FormatVerify.swift \
//       Sources/Runway/UI/IslandModel.swift Sources/Runway/Core/RunMonitor.swift \
//       Sources/Runway/API/GitHubClient.swift Sources/Runway/API/Models.swift \
//       Sources/Runway/API/Approvals.swift Sources/Runway/API/DeployTarget.swift \
//       Sources/Runway/API/RunScope.swift Sources/Runway/API/ETagStore.swift \
//       Sources/Runway/Auth/Keychain.swift Sources/Runway/UI/Haptics.swift \
//       Sources/Runway/Core/ApprovalNotifier.swift Sources/Runway/UI/IdleMark.swift \
//       Sources/Runway/UI/IdleMarkTint.swift && /tmp/formatverify

import Foundation

@main
enum FormatVerify {
    static func run(_ id: Int, _ status: RunStatus,
                    pending: [PendingDeployment] = []) -> WorkflowRun {
        WorkflowRun(id: id, runNumber: id, status: status,
                    createdAt: Date().addingTimeInterval(-60),
                    updatedAt: Date().addingTimeInterval(-30),
                    repository: "acme/api", pendingDeployments: pending)
    }

    @MainActor
    static func main() async {
        var failures = 0
        func assert(_ label: String, _ condition: Bool) {
            if condition { print("  ok    \(label)") }
            else { print("  FAIL  \(label)"); failures += 1 }
        }

        print("── IslandFormat.waited — the blocked pill's counter ──")
        assert("a gate that just closed is <1m, never 0m", IslandFormat.waited(0) == "<1m")
        assert("and still <1m at 59s",                     IslandFormat.waited(59) == "<1m")
        assert("one minute exactly reads 1m",              IslandFormat.waited(60) == "1m")
        assert("89s is 1m, not 2m — truncates, never rounds up past the truth",
               IslandFormat.waited(89) == "1m")
        assert("59m is still minutes",                     IslandFormat.waited(59 * 60) == "59m")
        assert("an exact hour drops the minutes",          IslandFormat.waited(3600) == "1h")
        assert("and an inexact one keeps them",            IslandFormat.waited(3600 + 20 * 60) == "1h 20m")
        assert("a run waiting on you since this morning",  IslandFormat.waited(3 * 3600 + 1200) == "3h 20m")
        assert("a negative clock skew does not underflow", IslandFormat.waited(-500) == "<1m")

        print()
        print("── the 15s cadence it has to survive ──")
        // The bug this replaced: at a 15-second tick the old M:SS form printed
        // a different string on every tick. The new one must not.
        let base: TimeInterval = 600
        let ticks = (0..<4).map { IslandFormat.waited(base + Double($0) * 15) }
        assert("four consecutive 15s ticks inside one minute all read the same",
               Set(ticks).count == 1 && ticks[0] == "10m")
        assert("and the minute after it has moved on",
               IslandFormat.waited(base + 60) == "11m")

        print()
        print("── IslandFormat.duration is untouched ──")
        assert("short runs stay in seconds", IslandFormat.duration(42) == "42s")
        assert("and long ones in M:SS",      IslandFormat.duration(84) == "1:24")

        print()
        print("── and the ticker that counter is drawn against ──")
        // The whole reason `waited` counts in minutes. `IslandModel` runs a
        // timer only while something is actually moving, and each of these is
        // a wakeup-per-second the app is choosing not to schedule. None of it
        // had ever been exercised.
        func advanced(_ model: IslandModel, over seconds: Double) async -> Bool {
            let before = model.now
            try? await Task.sleep(for: .seconds(seconds))
            return model.now > before
        }

        let live = IslandModel()
        live.apply(MonitorState(runs: [run(1, .inProgress)], isPolling: true))
        assert("a live run puts something on the island", live.relevantRuns.count == 1)
        assert("and `now` advances — the one-second tick is running",
               await advanced(live, over: 1.4))

        live.setSuspended(true)
        assert("a dark screen stops it entirely", !(await advanced(live, over: 1.4)))
        live.setSuspended(false)

        let idle = IslandModel()
        idle.apply(MonitorState(runs: [], isPolling: true))
        // Bound first: `&&` takes its right operand as an autoclosure, and an
        // autoclosure cannot be async.
        let idleTicked = await advanced(idle, over: 1.4)
        assert("nothing on the island, and nothing counting",
               idle.relevantRuns.isEmpty && !idleTicked)

        let blocked = IslandModel()
        let gate = PendingDeployment(
            environment: .init(id: 1, name: "production"),
            currentUserCanApprove: false,
            reviewers: [DeploymentReviewer(kind: .user, name: "carol")])
        blocked.apply(MonitorState(runs: [run(2, .waiting, pending: [gate])], isPolling: true))
        assert("a run parked on a person is recognised as blocked",
               blocked.blockedRuns.count == 1)
        assert("and drops to the fifteen-second cadence — `now` does not move in "
               + "two seconds, which is the 3,600 wakeups an hour that saves",
               !(await advanced(blocked, over: 2.0)))

        print()
        print(failures == 0
              ? "RESULT: PASS — the counter is stable across a tick, and the tick "
                + "only runs when something is counting"
              : "RESULT: FAIL — \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
