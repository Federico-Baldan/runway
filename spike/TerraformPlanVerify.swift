// Does a Terraform plan survive being read out of a job log?
//
// `TerraformPlanParser` turns a log into the rows and counts the island draws,
// and it had no test at all. Every claim in its comments — "confirmed against
// a real plan" — rested on someone having looked once. This runs it against
// output captured from a real Terraform (see `TerraformPlanFixtures`), in every
// shape a workflow can print the same plan in, and holds the shapes to agree:
//
//   text, text with colour, text behind GitHub's per-line timestamp, text with
//   Windows line endings, `terraform show -json`, and `terraform plan -json`.
//
// One plan, six ways to print it, one answer. Where they disagreed, the answer
// was wrong somewhere — and these are the disagreements it found:
//
//   * a `removed { destroy = false }` plan, drawn as a green "no changes" by
//     every route, because Terraform's own `Plan:` line says "0 to destroy";
//   * `is tainted, so must be replaced`, read as a resource whose address ends
//     in "is tainted, so";
//   * a secret one key deep inside an attribute, shown in the clear because the
//     mask that hides it was only read one level down;
//   * `plan -json`, whose lines contain `Plan: …` inside each message, drawn as
//     counts with no rows — and as "no changes" whenever only an output or a
//     forgotten object had changed.
//
// The hand-written cases below cover what a real run here cannot produce: a
// failed or partial plan in `show -json`, a deposed object, a number past
// `Int`'s range, and the masks nested inside attributes.
//
//   swiftc -o /tmp/tfplan spike/TerraformPlanVerify.swift \
//       spike/TerraformPlanFixtures.swift \
//       Sources/Runway/API/TerraformPlan.swift \
//       Sources/Runway/Core/TerraformPlanParser.swift && /tmp/tfplan

import Foundation

@main
enum TerraformPlanVerify {
    static func main() {
        var failures = 0

        func check(_ label: String, _ condition: Bool) {
            if condition {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label)")
                failures += 1
            }
        }

        func equal<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
            if actual == expected {
                print("  ok    \(label)")
            } else {
                print("  FAIL  \(label): got \(actual), expected \(expected)")
                failures += 1
            }
        }

        // ── helpers ─────────────────────────────────────────────────────────

        func parse(_ log: String) -> [TerraformPlanSummary] {
            TerraformPlanParser.parse(log: log)
        }

        func onlyPlan(_ log: String) -> TerraformPlanSummary? {
            let all = parse(log)
            return all.count == 1 ? all[0] : nil
        }

        /// GitHub puts its own timestamp in front of every raw log line.
        func prefixed(_ log: String) -> String {
            log.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "2026-09-14T10:23:45.1234567Z " + $0 }
                .joined(separator: "\n")
        }

        func counts(_ plan: TerraformPlanSummary) -> [Int] {
            [plan.toAdd, plan.toChange, plan.toReplace, plan.toDestroy, plan.toImport, plan.toForget]
        }

        func rows(_ plan: TerraformPlanSummary) -> [String] {
            plan.resources.map { "\($0.category.rawValue):\($0.address)" }.sorted()
        }

        func attribute(
            _ plan: TerraformPlanSummary, _ address: String, _ key: String
        ) -> TerraformPlanSummary.AttributeDiff? {
            plan.resources.first { $0.address == address }?.attributes.first { $0.key == key }
        }

        /// A plan document with the fields every real one has.
        func document(
            _ body: String,
            flags: String = #""applyable":true,"complete":true,"errored":false"#
        ) -> String {
            #"{"format_version":"1.2",\#(flags),"planned_values":{},\#(body)}"#
        }

        func entry(
            _ address: String, _ actions: String,
            change extra: String = "", top: String = ""
        ) -> String {
            #"{"address":"\#(address)","mode":"managed","type":"t","name":"n"\#(top),"change":{"actions":\#(actions),"before":{"a":"1"},"after":{"a":"2"}\#(extra)}}"#
        }

        // ── the same plan, every way a workflow can print it ───────────────

        struct Scenario {
            let name: String
            let text: String?
            let colourText: String?
            let json: String?
            let stream: String?
            /// add, change, replace, destroy, import, forget
            let counts: [Int]
            let rows: [String]
            var isNoOp = false
            var isErrored = false
        }

        typealias F = TerraformFixtures
        let scenarios: [Scenario] = [
            Scenario(
                name: "create", text: F.createText, colourText: nil,
                json: F.createJSON, stream: F.createStream,
                counts: [3, 0, 0, 0, 0, 0],
                rows: ["create:terraform_data.db", "create:terraform_data.pw",
                       "create:terraform_data.web"]
            ),
            Scenario(
                name: "no changes", text: F.noopText, colourText: nil,
                json: F.noopJSON, stream: F.noopStream,
                counts: [0, 0, 0, 0, 0, 0], rows: [], isNoOp: true
            ),
            Scenario(
                name: "create + replace + destroy + update",
                text: F.mixedText, colourText: F.mixedColourText,
                json: F.mixedJSON, stream: F.mixedStream,
                counts: [1, 1, 1, 1, 0, 0],
                rows: ["create:terraform_data.cache", "destroy:terraform_data.pw",
                       "replace:terraform_data.db", "update:terraform_data.web"]
            ),
            Scenario(
                name: "tainted", text: F.taintedText, colourText: nil,
                json: F.taintedJSON, stream: F.taintedStream,
                counts: [0, 0, 1, 0, 0, 0], rows: ["replace:terraform_data.db"]
            ),
            Scenario(
                name: "replace requested", text: F.replaceRequestedText, colourText: nil,
                json: F.replaceRequestedJSON, stream: F.replaceRequestedStream,
                counts: [0, 0, 1, 0, 0, 0], rows: ["replace:terraform_data.cache"]
            ),
            Scenario(
                name: "moved", text: F.movedText, colourText: nil,
                json: F.movedJSON, stream: F.movedStream,
                counts: [0, 0, 0, 0, 0, 0], rows: ["moved:terraform_data.store"]
            ),
            Scenario(
                name: "moved and updated", text: F.movedAndUpdatedText, colourText: nil,
                json: F.movedAndUpdatedJSON, stream: F.movedAndUpdatedStream,
                counts: [0, 1, 0, 0, 0, 0], rows: ["update:terraform_data.store"]
            ),
            Scenario(
                name: "forget", text: F.forgetText, colourText: nil,
                json: F.forgetJSON, stream: F.forgetStream,
                counts: [0, 0, 0, 0, 0, 1], rows: ["forget:terraform_data.store"]
            ),
            Scenario(
                name: "import (and forget)", text: F.importedText, colourText: nil,
                json: F.importedJSON, stream: F.importedStream,
                counts: [0, 1, 0, 0, 1, 1],
                rows: ["forget:terraform_data.store", "update:terraform_data.imp"]
            ),
            // A failed plan only exists as text and as a stream: `show -json`
            // needs a saved plan, and a failed one is never saved.
            Scenario(
                name: "planning failed", text: F.erroredText, colourText: nil,
                json: nil, stream: F.erroredStream,
                counts: [0, 0, 0, 2, 0, 0],
                rows: ["destroy:terraform_data.db", "destroy:terraform_data.store"],
                isErrored: true
            ),
            // The same three scenarios from OpenTofu, whose words differ.
            Scenario(
                name: "OpenTofu forget", text: F.tofuForgetText, colourText: nil,
                json: F.tofuForgetJSON, stream: F.tofuForgetStream,
                counts: [0, 0, 0, 0, 0, 1], rows: ["forget:terraform_data.store"]
            ),
            Scenario(
                name: "OpenTofu import (and forget)", text: F.tofuImportedText, colourText: nil,
                json: F.tofuImportedJSON, stream: F.tofuImportedStream,
                counts: [0, 1, 0, 0, 1, 1],
                rows: ["forget:terraform_data.store", "update:terraform_data.imp"]
            ),
            Scenario(
                name: "OpenTofu planning failed", text: F.tofuErroredText, colourText: nil,
                json: nil, stream: F.tofuErroredStream,
                counts: [0, 0, 0, 2, 0, 0],
                rows: ["destroy:terraform_data.db", "destroy:terraform_data.store"],
                isErrored: true
            ),
            // And the rest of them. OpenTofu words "is tainted, so it must be
            // replaced"; nothing else here differs, which is what this keeps true.
            Scenario(
                name: "OpenTofu create", text: F.tofuCreateText, colourText: nil,
                json: F.tofuCreateJSON, stream: F.tofuCreateStream,
                counts: [3, 0, 0, 0, 0, 0],
                rows: ["create:terraform_data.db", "create:terraform_data.pw",
                       "create:terraform_data.web"]
            ),
            Scenario(
                name: "OpenTofu no changes", text: F.tofuNoopText, colourText: nil,
                json: F.tofuNoopJSON, stream: F.tofuNoopStream,
                counts: [0, 0, 0, 0, 0, 0], rows: [], isNoOp: true
            ),
            Scenario(
                name: "OpenTofu create + replace + destroy + update",
                text: F.tofuMixedText, colourText: nil,
                json: F.tofuMixedJSON, stream: F.tofuMixedStream,
                counts: [1, 1, 1, 1, 0, 0],
                rows: ["create:terraform_data.cache", "destroy:terraform_data.pw",
                       "replace:terraform_data.db", "update:terraform_data.web"]
            ),
            Scenario(
                name: "OpenTofu tainted", text: F.tofuTaintedText, colourText: nil,
                json: F.tofuTaintedJSON, stream: F.tofuTaintedStream,
                counts: [0, 0, 1, 0, 0, 0], rows: ["replace:terraform_data.db"]
            ),
            Scenario(
                name: "OpenTofu replace requested", text: F.tofuReplaceRequestedText,
                colourText: nil, json: F.tofuReplaceRequestedJSON,
                stream: F.tofuReplaceRequestedStream,
                counts: [0, 0, 1, 0, 0, 0], rows: ["replace:terraform_data.cache"]
            ),
            Scenario(
                name: "OpenTofu moved", text: F.tofuMovedText, colourText: nil,
                json: F.tofuMovedJSON, stream: F.tofuMovedStream,
                counts: [0, 0, 0, 0, 0, 0], rows: ["moved:terraform_data.store"]
            ),
            Scenario(
                name: "OpenTofu moved and updated", text: F.tofuMovedAndUpdatedText,
                colourText: nil, json: F.tofuMovedAndUpdatedJSON,
                stream: F.tofuMovedAndUpdatedStream,
                counts: [0, 1, 0, 0, 0, 0], rows: ["update:terraform_data.store"]
            ),
        ]

        print("── one plan, every shape it can be printed in ──")
        for scenario in scenarios {
            var shapes: [(String, String)] = []
            if let text = scenario.text {
                shapes.append(("text", text))
                shapes.append(("text behind timestamps", prefixed(text)))
                shapes.append(("text with CRLF", text.replacingOccurrences(of: "\n", with: "\r\n")))
            }
            if let colour = scenario.colourText { shapes.append(("coloured text", colour)) }
            if let json = scenario.json {
                shapes.append(("show -json", json))
                shapes.append(("show -json behind timestamp", prefixed(json)))
            }
            if let stream = scenario.stream {
                shapes.append(("plan -json", stream))
                shapes.append(("plan -json behind timestamps", prefixed(stream)))
            }

            var problems: [String] = []
            for (shape, log) in shapes {
                guard let plan = onlyPlan(log) else {
                    problems.append("\(shape): not exactly one plan (got \(parse(log).count))")
                    continue
                }
                if counts(plan) != scenario.counts {
                    problems.append("\(shape): counts \(counts(plan)), expected \(scenario.counts)")
                }
                if rows(plan) != scenario.rows {
                    problems.append("\(shape): rows \(rows(plan)), expected \(scenario.rows)")
                }
                if plan.isNoOpPlan != scenario.isNoOp {
                    problems.append("\(shape): isNoOpPlan \(plan.isNoOpPlan), expected \(scenario.isNoOp)")
                }
                if plan.isErrored != scenario.isErrored {
                    problems.append("\(shape): isErrored \(plan.isErrored), expected \(scenario.isErrored)")
                }
                if plan.isPartial {
                    problems.append("\(shape): drawn as partial")
                }
            }
            if problems.isEmpty {
                print("  ok    \(scenario.name): \(shapes.count) shapes agree")
            } else {
                for problem in problems {
                    print("  FAIL  \(scenario.name) — \(problem)")
                    failures += 1
                }
            }
        }

        print()
        print("── what moved, and from where ──")
        for (shape, log) in [("text", F.movedText), ("show -json", F.movedJSON),
                             ("plan -json", F.movedStream), ("tofu text", F.tofuMovedText),
                             ("tofu show -json", F.tofuMovedJSON),
                             ("tofu plan -json", F.tofuMovedStream)] {
            let row = onlyPlan(log)?.resources.first
            equal("moved / \(shape): origin", row?.movedFrom, "terraform_data.cache")
            equal("moved / \(shape): keyed by the new address", row?.address, "terraform_data.store")
        }
        for (shape, log) in [("text", F.movedAndUpdatedText), ("show -json", F.movedAndUpdatedJSON),
                             ("plan -json", F.movedAndUpdatedStream),
                             ("tofu text", F.tofuMovedAndUpdatedText),
                             ("tofu show -json", F.tofuMovedAndUpdatedJSON),
                             ("tofu plan -json", F.tofuMovedAndUpdatedStream)] {
            let row = onlyPlan(log)?.resources.first
            equal("moved+updated / \(shape): origin", row?.movedFrom, "terraform_data.cache")
        }

        print()
        print("── an outputs-only plan is never a green \"no changes\" ──")
        for (shape, log) in [("show -json", F.outputsOnlyJSON), ("plan -json", F.outputsOnlyStream),
                             ("tofu show -json", F.tofuOutputsOnlyJSON),
                             ("tofu plan -json", F.tofuOutputsOnlyStream)] {
            let plan = onlyPlan(log)
            check("outputs only / \(shape): drawn as a change",
                  plan.map { !$0.isNoOpPlan && $0.outputChanges.map(\.name) == ["x"] } ?? false)
        }
        // Text carries no output rows, so there is nothing true to draw: it
        // must be nothing, not "no changes".
        check("outputs only / text: not drawn at all", parse(F.outputsOnlyText).isEmpty)
        check("outputs only / tofu text: not drawn at all", parse(F.tofuOutputsOnlyText).isEmpty)

        print()
        print("── a secret is not shown, however deep it sits ──")
        if let plan = onlyPlan(F.createJSON) {
            let input = attribute(plan, "terraform_data.pw", "input")
            check("nested sensitive key is masked",
                  input?.after?.contains("hunter2") == false
                      && input?.after?.contains("(sensitive value)") == true)
            check("its sibling is still shown", input?.after?.contains("user = admin") == true)
            check("the attribute is marked sensitive", input?.isSensitive == true)
            check("no attribute anywhere carries the secret",
                  plan.resources.flatMap(\.attributes).allSatisfy {
                      !(($0.before ?? "") + ($0.after ?? "")).contains("hunter2")
                  })
            let output = attribute(plan, "terraform_data.pw", "output")
            check("an unknown attribute is drawn as unknown",
                  output?.after == "(known after apply)" && output?.isUnknown == true)
            equal("a null attribute is not a row",
                  plan.resources.first { $0.address == "terraform_data.db" }?.attributes.map(\.key),
                  ["triggers_replace"])
            equal("only what changed on a created resource",
                  plan.resources.first { $0.address == "terraform_data.web" }?.attributes.map(\.key),
                  ["input", "output"])
            let outputs = Dictionary(uniqueKeysWithValues: plan.outputChanges.map { ($0.name, $0) })
            check("an unknown output is drawn as unknown",
                  outputs["greeting"]?.isUnknown == true
                      && outputs["greeting"]?.after == "(known after apply)")
            equal("a known output keeps its value", outputs["x"]?.after, "one")
        } else {
            check("create.json parses to one plan", false)
        }
        if let plan = onlyPlan(F.mixedJSON) {
            let db = plan.resources.first { $0.address == "terraform_data.db" }
            check("the attribute that forced a replace says so",
                  attribute(plan, "terraform_data.db", "triggers_replace")?.forcesReplacement == true)
            equal("the reason is kept", db?.actionReason, "replace_because_cannot_update")
            equal("unchanged resources are counted by the JSON path", plan.unchangedCount, 0)
        }
        equal("no-op resources are counted, not drawn", onlyPlan(F.noopJSON)?.unchangedCount, 3)

        let masking = [
            ("a bare true hides the whole value",
             JSONValue.masked(.string("x"), sensitive: .bool(true), unknown: nil),
             JSONValue.string("(sensitive value)")),
            ("sensitive wins over unknown",
             JSONValue.masked(.string("x"), sensitive: .bool(true), unknown: .bool(true)),
             JSONValue.string("(sensitive value)")),
            ("a mask that flags nothing changes nothing",
             JSONValue.masked(.object(["a": .string("1")]),
                              sensitive: .object(["a": .bool(false)]), unknown: .object([:])),
             JSONValue.object(["a": .string("1")])),
            ("a list is masked element by element",
             JSONValue.masked(.array([.string("a"), .string("b")]),
                              sensitive: .array([.bool(false), .bool(true)]), unknown: nil),
             JSONValue.array([.string("a"), .string("(sensitive value)")])),
            ("an unknown key that is absent from the value is put back",
             JSONValue.masked(.object([:]), sensitive: nil, unknown: .object(["k": .bool(true)])),
             JSONValue.object(["k": .string("(known after apply)")])),
            ("a whole unknown attribute with no value at all",
             JSONValue.masked(nil, sensitive: nil, unknown: .bool(true)),
             JSONValue.string("(known after apply)")),
            ("masks of two sides merge, flagged wins",
             JSONValue.union(.object(["a": .bool(true)]), .object(["b": .bool(true)])),
             JSONValue.object(["a": .bool(true), "b": .bool(true)])),
            ("masks of unlike kinds that flag something hide everything",
             JSONValue.union(.object([:]), .array([.bool(false), .bool(true)])),
             JSONValue.bool(true)),
            ("masks of unlike kinds that flag nothing stay as they were",
             JSONValue.union(.object([:]), .array([.bool(false)])),
             JSONValue.object([:])),
            ("a list mask over a map value hides the map",
             JSONValue.masked(.object(["a": .string("S")]),
                              sensitive: .array([.bool(true)]), unknown: nil),
             JSONValue.string("(sensitive value)")),
            ("a map mask over a scalar hides the scalar",
             JSONValue.masked(.string("S"), sensitive: .object(["a": .bool(true)]), unknown: nil),
             JSONValue.string("(sensitive value)")),
        ]
        for (label, actual, expected) in masking {
            equal(label, actual, expected)
        }

        print()
        print("── failed and partial plans in show -json ──")
        do {
            let failed = onlyPlan(document(
                #""resource_changes":[]"#,
                flags: #""applyable":false,"complete":false,"errored":true"#))
            check("errored: flagged, and not a green no-change",
                  failed?.isErrored == true && failed?.isPartial == false)
            let incomplete = onlyPlan(document(
                #""resource_changes":[]"#,
                flags: #""applyable":true,"complete":false,"errored":false"#))
            check("incomplete: flagged partial", incomplete?.isPartial == true
                  && incomplete?.isErrored == false)
            let deferred = onlyPlan(document(
                #""resource_changes":[],"deferred_changes":[{"reason":"x","resource_change":{"address":"a.b"}}]"#))
            check("deferred changes: flagged partial", deferred?.isPartial == true)
            let calm = onlyPlan(document(
                #""resource_changes":[]"#,
                flags: #""applyable":false,"complete":true,"errored":false"#))
            check("applyable:false alone is not a problem — it is what \"no changes\" looks like",
                  calm?.isErrored == false && calm?.isPartial == false && calm?.isNoOpPlan == true)
        }

        print()
        print("── what is and is not a plan document ──")
        check("a major version this code does not know is refused",
              parse(#"{"format_version":"2.0","applyable":true,"complete":true,"errored":false,"planned_values":{},"resource_changes":[]}"#).isEmpty)
        check("a state is not a plan",
              parse(#"{"format_version":"1.0","terraform_version":"1.17.1","values":{"root_module":{}}}"#).isEmpty)
        do {
            let plan = onlyPlan(document(
                #""output_changes":{"x":{"actions":["update"],"before":"a","after":"b","after_unknown":false,"before_sensitive":false,"after_sensitive":false}}"#))
            check("no resource_changes key at all is still a plan",
                  plan?.outputChanges.first?.before == "a" && plan?.outputChanges.first?.after == "b"
                      && plan?.isNoOpPlan == false)
        }
        do {
            let both = parse(prefixed(F.createJSON) + "\nother output\n" + prefixed(F.mixedJSON))
            equal("two plans in one log are two plans", both.count, 2)
        }

        print()
        print("── actions, imports, deposed objects ──")
        do {
            let entries = [
                entry("a.replace_forget", #"["forget","create"]"#),
                entry("a.forget_replace", #"["create","forget"]"#),
                entry("a.forget", #"["forget"]"#),
                entry("a.update", #"["update"]"#),
            ].joined(separator: ",")
            let plan = onlyPlan(document(#""resource_changes":[\#(entries)]"#))
            equal("forget + create is a replace that destroys nothing",
                  plan.map { [$0.toReplace, $0.toForget, $0.toChange, $0.toDestroy] } ?? [],
                  [2, 1, 1, 0])
            equal("their categories", plan.map(rows) ?? [],
                  ["forget:a.forget", "replace:a.forget_replace", "replace:a.replace_forget",
                   "update:a.update"])
        }
        do {
            let imp = entry("a.imp", #"["no-op"]"#, change: #","importing":{"id":"x"}"#)
            let plan = onlyPlan(document(#""resource_changes":[\#(imp)]"#))
            check("an import that changes nothing is still drawn",
                  plan.map { rows($0) == ["imported:a.imp"] && $0.toImport == 1 && !$0.isNoOpPlan } ?? false)
        }
        do {
            let entries = [
                entry("a.web", #"["delete","create"]"#),
                entry("a.web", #"["delete"]"#, top: #","deposed":"abcd1234""#),
            ].joined(separator: ",")
            let plan = onlyPlan(document(#""resource_changes":[\#(entries)]"#))
            equal("a deposed object has an address of its own",
                  plan?.resources.map(\.address) ?? [],
                  ["a.web", "a.web (deposed object abcd1234)"])
            equal("so every row has its own id",
                  Set(plan?.resources.map(\.id) ?? []).count, 2)
        }

        print()
        print("── values the display must survive ──")
        do {
            let plan = onlyPlan(document(#""resource_changes":[{"address":"x.y","mode":"managed","type":"t","name":"n","change":{"actions":["update"],"before":{"n":1},"after":{"n":1e30,"m":18446744073709551615,"k":2.5,"s":"text","b":true}}}]"#))
            check("a number past Int's range does not trap",
                  attribute(plan ?? TerraformPlanSummary(), "x.y", "n")?.after != nil
                      && attribute(plan ?? TerraformPlanSummary(), "x.y", "m")?.after != nil)
            equal("a fractional number", attribute(plan ?? TerraformPlanSummary(), "x.y", "k")?.after, "2.5")
            equal("a string", attribute(plan ?? TerraformPlanSummary(), "x.y", "s")?.after, "text")
            equal("a bool", attribute(plan ?? TerraformPlanSummary(), "x.y", "b")?.after, "true")
        }
        do {
            let plan = onlyPlan(document(#""resource_changes":[{"address":"x.y","mode":"managed","type":"t","name":"n","change":{"actions":["update"],"before":{"tags":{"env":"x"}},"after":{"tags":{"env":"x"}},"after_unknown":{"tags":{"name":true}}}}]"#))
            let tags = attribute(plan ?? TerraformPlanSummary(), "x.y", "tags")
            equal("an unknown inside an attribute is drawn where it sits",
                  tags?.after, "{ env = x, name = (known after apply) }")
            check("and marks the attribute unknown", tags?.isUnknown == true)
        }
        do {
            let plan = onlyPlan(document(#""resource_changes":[{"address":"x.y","mode":"managed","type":"t","name":"n","change":{"actions":["update"],"before":{"a":"1"},"after":{"a":"1"}}}]"#))
            equal("an update that changes no attribute lists none",
                  plan?.resources.first?.attributes.count, 0)
        }
        do {
            let plan = onlyPlan(document(#""output_changes":{"o":{"actions":["update"],"before":"old","after":"new","after_unknown":false,"before_sensitive":false,"after_sensitive":true}}"#))
            let output = plan?.outputChanges.first
            check("an output that turns sensitive hides what it was too",
                  output?.before == "(sensitive value)" && output?.after == "(sensitive value)")
        }
        do {
            let long = String(repeating: "x", count: 1000)
            let plan = onlyPlan(document(#""resource_changes":[{"address":"x.y","mode":"managed","type":"t","name":"n","change":{"actions":["create"],"after":{"blob":"\#(long)"}}}]"#))
            let after = attribute(plan ?? TerraformPlanSummary(), "x.y", "blob")?.after ?? ""
            check("a long value is clipped for display", after.count < 300 && after.hasSuffix("…"))
        }

        print()
        print("── the text path, where Terraform's wording is all there is ──")
        do {
            let echoed = F.mixedText + "\nPlan: 2 to add, 1 to change, 2 to destroy.\n"
            let all = parse(echoed)
            equal("an echoed Plan: line parses as a plan of its own", all.count, 2)
            let merged = TerraformPlanParser.reconcile(all, stepNames: ["Terraform Plan"])
            equal("and reconcile drops it", merged.count, 1)
            check("without inventing a label for the one that is left", merged.first?.label == nil)
            equal("the one that is left has the rows", merged.first?.resources.count, 4)

            let a = parse(F.mixedText)[0]
            let b = parse(F.createText)[0]
            let kept = TerraformPlanParser.reconcile(
                [a, b, parse("Plan: 2 to add, 1 to change, 2 to destroy.")[0]],
                stepNames: ["staging", "staging-dr"])
            equal("two real plans and an echo are two plans, named", kept.map(\.label), ["staging", "staging-dr"])
        }
        do {
            let both = parse(F.noopText + "\n" + F.mixedText)
            equal("a calm plan before a real one does not speak for the log", both.count, 2)
            check("the first is calm, the second is not",
                  both.first?.isNoOpPlan == true && both.last?.isNoOpPlan == false)
            let named = TerraformPlanParser.reconcile(
                both, stepNames: ["Terraform Plan (staging)", "Terraform Plan (staging-dr)"])
            equal("each takes its step's name", named.map(\.label),
                  ["Terraform Plan (staging)", "Terraform Plan (staging-dr)"])
        }
        do {
            let doubled = F.mixedText.replacingOccurrences(
                of: "  # terraform_data.cache will be created\n",
                with: "  # terraform_data.cache will be created\n  # terraform_data.cache will be created\n")
            let plan = onlyPlan(doubled)
            check("a header printed twice is counted once",
                  plan.map { $0.toAdd == 1 && $0.resources.count == 4 } ?? false)
            let script = onlyPlan("+ grep 'No changes.' plan.txt\n" + F.mixedText)
            check("a script echoing \"No changes.\" does not close a plan of its own", script != nil)
        }
        do {
            let unknown = onlyPlan("  # aws_x.y will be frobnicated\nPlan: 1 to add, 0 to change, 0 to destroy.")
            check("the Plan: line wins over headers it cannot read",
                  unknown.map { $0.toAdd == 1 && $0.resources.isEmpty && !$0.isNoOpPlan } ?? false)
            let short = onlyPlan("  # a.b will be created\nPlan: 2 to add, 0 to change, 0 to destroy.")
            check("including when the headers are fewer than the line says",
                  short.map { $0.toAdd == 2 && $0.resources.count == 1 } ?? false)
            let tofu = onlyPlan("Plan: 1 to add, 0 to change, 0 to destroy, 1 to forget.")
            check("OpenTofu's forget count is read", tofu?.toForget == 1 && tofu?.toAdd == 1)
            let imported = onlyPlan("  # a.b will be imported\nPlan: 1 to import, 0 to add, 0 to change, 0 to destroy.")
            check("an import header is not counted twice with the line",
                  imported.map { $0.toImport == 1 && rows($0) == ["imported:a.b"] } ?? false)
            let failed = onlyPlan("Planning failed. Terraform encountered an error while generating this plan.\n\nError: boom")
            check("\"Planning failed.\" is an errored plan, not a calm one",
                  failed.map { $0.isErrored && $0.isNoOpPlan } ?? false)
            let partial = onlyPlan("No current changes. This plan requires another plan to be applied first.")
            check("\"requires another plan\" is a partial plan, not a calm one",
                  partial?.isPartial == true)
            let module = onlyPlan("  # module.vpc.aws_subnet.private[0] will be created\nPlan: 1 to add, 0 to change, 0 to destroy.")
            equal("a module address still gives its type", module?.resources.first?.type, "aws_subnet")
            let deposed = onlyPlan("  # aws_instance.web (deposed object abc123) will be destroyed\nPlan: 0 to add, 0 to change, 1 to destroy.")
            equal("a deposed object keeps its tag", deposed?.resources.first?.address,
                  "aws_instance.web (deposed object abc123)")
            equal("a bare CR is a line break too",
                  onlyPlan(F.mixedText.replacingOccurrences(of: "\n", with: "\r"))?.resources.count, 4)
            check("a step named \"Plan: staging\" is not a plan",
                  parse("##[group]Run terraform plan\nPlan: staging\n##[endgroup]").isEmpty)
            check("a log with no Terraform in it has no plan",
                  parse("building...\nall done\n").isEmpty)
            equal("colour is stripped, nothing else is", TerraformPlanParser.withoutColour("\u{1B}[1mPlan:\u{1B}[0m ok"[...]), "Plan: ok")
        }

        print()
        print("── plan -json, including when the job also applies ──")
        do {
            let success = onlyPlan(F.applySuccessStream)
            check("apply -json: the plan is read from before the apply",
                  success.map { rows($0) == ["create:terraform_data.a"] && !$0.isErrored } ?? false)
            let failure = onlyPlan(F.applyFailureStream)
            check("apply -json: an error after apply_start is the apply's, not the plan's",
                  failure.map { counts($0) == [1, 1, 0, 0, 0, 0] && !$0.isErrored } ?? false)
            let noisy = onlyPlan("not json at all\n{broken\n{\"not\":\"terraform\"}\n" + F.mixedStream)
            check("lines that are not stream messages are skipped", noisy != nil)
            let cut = onlyPlan(#"{"type":"planned_change","change":{"resource":{"addr":"a.b","resource_type":"a"},"action":"create"}}"#)
            check("rows with no summary after them are still a plan",
                  cut.map { rows($0) == ["create:a.b"] && $0.toAdd == 1 } ?? false)
        }

        print()
        print("── a mask that does not line up with its value is not trusted ──")
        do {
            // Each side has its own mask and they disagree about the shape: a
            // map before, a list after. Reading one and dropping the other
            // showed the list's secret in clear.
            let plan = onlyPlan(document(#""resource_changes":[{"address":"terraform_data.t","mode":"managed","type":"terraform_data","name":"t","change":{"actions":["update"],"before":{"input":{"a":"x"}},"after":{"input":["a","MORPH2SECRET"]},"before_sensitive":{"input":{}},"after_sensitive":{"input":[false,true]}}}]"#))
            let shown = attribute(plan ?? TerraformPlanSummary(), "terraform_data.t", "input")
            check("a map that became a list does not leak the list's secret",
                  shown != nil && shown?.isSensitive == true
                      && !((shown?.before ?? "") + (shown?.after ?? "")).contains("MORPH2SECRET"))
            let output = onlyPlan(document(#""output_changes":{"o":{"actions":["update"],"before":{"k":"1"},"after":["MORPH3SECRET"],"after_unknown":false,"before_sensitive":{},"after_sensitive":[true]}}"#))?.outputChanges.first
            check("and neither does an output",
                  output != nil
                      && !((output?.before ?? "") + (output?.after ?? "")).contains("MORPH3SECRET"))
        }

        print()
        print("── a mask over both sides leaves alone the side a change does not have ──")
        do {
            // Terraform writes `after_sensitive: false` on every delete and
            // `before_sensitive: false` on every create. Merging that with the
            // other side's mask used to hide every attribute of a destroyed
            // resource, to protect the one that was secret.
            let destroy = onlyPlan(document(#""resource_changes":[{"address":"a.b","mode":"managed","type":"a","name":"b","change":{"actions":["delete"],"before":{"name":"n","port":"80","password":"p"},"after_sensitive":false,"before_sensitive":{"password":true}}}]"#))
            let target = destroy ?? TerraformPlanSummary()
            check("a destroy hides the secret",
                  attribute(target, "a.b", "password")?.before == "(sensitive value)"
                      && attribute(target, "a.b", "password")?.isSensitive == true)
            check("and only the secret",
                  attribute(target, "a.b", "name")?.before == "n"
                      && attribute(target, "a.b", "port")?.before == "80"
                      && attribute(target, "a.b", "name")?.isSensitive == false)
            let create = onlyPlan(document(#""resource_changes":[{"address":"a.b","mode":"managed","type":"a","name":"b","change":{"actions":["create"],"after":{"name":"n","secret":"s"},"before_sensitive":false,"after_sensitive":{"secret":true}}}]"#))
            let secret = attribute(create ?? TerraformPlanSummary(), "a.b", "secret")
            check("a create's secret has no value before it", secret?.before == nil
                  && secret?.after == "(sensitive value)")
            // The same on an output, with an explicit null as well as an absent key.
            let gone = onlyPlan(document(#""output_changes":{"o":{"actions":["delete"],"before":"old","after_unknown":false,"before_sensitive":true,"after_sensitive":false}}"#))?.outputChanges.first
            check("a sensitive output that is deleted hides what it was and shows nothing after",
                  gone?.before == "(sensitive value)" && gone?.after == nil)
            let goneNull = onlyPlan(document(#""output_changes":{"o":{"actions":["delete"],"before":"old","after":null,"after_unknown":false,"before_sensitive":true,"after_sensitive":false}}"#))?.outputChanges.first
            check("also when `after` is an explicit null", goneNull?.after == nil)
            let made = onlyPlan(document(#""output_changes":{"o":{"actions":["create"],"after":"new","after_unknown":false,"before_sensitive":false,"after_sensitive":true}}"#))?.outputChanges.first
            check("a sensitive output that is created has nothing before",
                  made?.before == nil && made?.after == "(sensitive value)")
            let turned = onlyPlan(document(#""output_changes":{"o":{"actions":["update"],"before":"old","after":"new","after_unknown":false,"before_sensitive":true,"after_sensitive":false}}"#))?.outputChanges.first
            check("one that only WAS sensitive hides both sides",
                  turned?.before == "(sensitive value)" && turned?.after == "(sensitive value)")
        }

        print()
        print("── one stream, several commands ──")
        do {
            let version = #"{"type":"version","terraform":"1.17.1","ui":"1.2"}"#
            let create = #"{"type":"planned_change","change":{"resource":{"addr":"a.b","resource_type":"a"},"action":"create"}}"#
            let summary = #"{"type":"change_summary","changes":{"add":1,"change":0,"remove":0,"import":0,"operation":"plan"}}"#
            let lockError = #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"Error acquiring the state lock"}}"#
            let planThenFailedCommand = onlyPlan([version, create, summary, version, lockError].joined(separator: "\n"))
            check("an error in the NEXT command is not the plan's",
                  planThenFailedCommand.map { $0.toAdd == 1 && !$0.isErrored } ?? false)
            let cut = parse([version, create, version].joined(separator: "\n"))
            check("rows cut off by the next command are still a plan",
                  cut.count == 1 && cut[0].toAdd == 1)
            let warning = onlyPlan([version, create, summary,
                                    #"{"type":"diagnostic","diagnostic":{"severity":"warning","summary":"w"}}"#].joined(separator: "\n"))
            check("a warning after the plan is not a failure", warning.map { !$0.isErrored } ?? false)
            let failedAfterPlan = onlyPlan([version, create, summary, lockError].joined(separator: "\n"))
            check("an error right after the plan, in the same command, is", failedAfterPlan?.isErrored == true)
            let deepKey = String(repeating: "[", count: 150) + String(repeating: "]", count: 150)
            let deepRow = #"{"type":"planned_change","extra":\#(deepKey),"change":{"resource":{"addr":"a.deep","resource_type":"a"},"action":"create"}}"#
            equal("a stream line nested too deep is skipped and the rest is read",
                  onlyPlan([version, create, deepRow, summary].joined(separator: "\n")).map(rows) ?? [],
                  ["create:a.b"])
            let interrupted = onlyPlan([version, create, #"{"type":"diagnostic","diagnostic":{"severity":"error","summary":"x"}}"#].joined(separator: "\n"))
            check("rows still waiting for their summary when an error arrives are an errored plan",
                  interrupted.map { $0.isErrored && $0.toAdd == 1 } ?? false)
        }

        print()
        print("── addresses, and the one sentence a cut-off plan leaves ──")
        do {
            let quoted = onlyPlan("  # aws_x.y[\"a]b c\"] will be created\n  # aws_x.z[\"k k\"] will be created\nPlan: 2 to add, 0 to change, 0 to destroy.")
            equal("a quoted key with a bracket or a space is still an address",
                  quoted.map(rows) ?? [], ["create:aws_x.y[\"a]b c\"]", "create:aws_x.z[\"k k\"]"])
            let cutOff = onlyPlan("Terraform planned the following actions, but then encountered a problem:\n\n  # a.b will be created\n  + resource \"a\" \"b\" {\n")
            check("a plan cut off after the problem sentence is errored, with its row",
                  cutOff.map { $0.isErrored && $0.resources.count == 1 } ?? false)
            let tofuCutOff = onlyPlan("OpenTofu planned the following actions, but then encountered a problem:\n\n  # a.b will be created\n")
            check("OpenTofu's sentence too", tofuCutOff?.isErrored == true)
            let tainted = onlyPlan("  # a.b is tainted, so it must be replaced\nPlan: 1 to add, 0 to change, 1 to destroy.")
            equal("OpenTofu's \"is tainted, so it must be replaced\"", tainted.map(rows) ?? [], ["replace:a.b"])
        }

        print()
        print("── a log can say anything about its numbers ──")
        do {
            let negative = onlyPlan("Plan: -9223372036854775808 to add, 0 to change, 5 to destroy.")
            check("a negative count is not a count, and does not trap",
                  negative.map { $0.toAdd == 0 && $0.toDestroy == 5 } ?? false)
            let huge = onlyPlan("Plan: 9223372036854775807 to add, 1 to change, 0 to destroy.")
            check("a count no plan has is ignored",
                  huge.map { $0.toAdd == 0 && $0.toChange == 1 } ?? false)
            let stream = onlyPlan(#"{"type":"change_summary","changes":{"add":-9223372036854775808,"change":0,"remove":5,"import":0,"operation":"plan"}}"#)
            check("a stream summary too",
                  stream.map { $0.toAdd == 0 && $0.toDestroy == 5 } ?? false)
            equal("a count at the limit is a count",
                  onlyPlan("Plan: 1000000 to add, 0 to change, 0 to destroy.")?.toAdd, 1_000_000)
            equal("one past it is not",
                  onlyPlan("Plan: 1000001 to add, 1 to change, 0 to destroy.")?.toAdd, 0)
            let both = onlyPlan("  # a.x must be replaced\nPlan: -1 to add, 0 to change, -1 to destroy.")
            check("a replace over two bad counts still has its row",
                  both.map { $0.resources.count == 1 && $0.toAdd == 0 && $0.toDestroy == 0 } ?? false)
        }

        print()
        print("── a replace that keeps the old object ──")
        do {
            let text = onlyPlan("  # a.x must be replaced, but the existing object will not be destroyed\n  # b.y will be destroyed\nPlan: 1 to add, 0 to change, 1 to destroy.")
            equal("text: replace + a separate destroy", text.map(counts) ?? [], [0, 0, 1, 1, 0, 0])
            let stream = onlyPlan([
                #"{"type":"planned_change","change":{"resource":{"addr":"a.x","resource_type":"a"},"action":"replace"}}"#,
                #"{"type":"planned_change","change":{"resource":{"addr":"b.y","resource_type":"b"},"action":"delete"}}"#,
                #"{"type":"change_summary","changes":{"add":1,"change":0,"remove":1,"import":0,"operation":"plan"}}"#,
            ].joined(separator: "\n"))
            equal("stream: the same", stream.map(counts) ?? [], [0, 0, 1, 1, 0, 0])
            let alone = onlyPlan("  # a.x must be replaced, but the existing object will not be destroyed\nPlan: 1 to add, 0 to change, 0 to destroy.")
            equal("text: by itself it is a replace, not an add", alone.map(counts) ?? [], [0, 0, 1, 0, 0, 0])
        }
        do {
            let one = #"{"type":"planned_change","change":{"resource":{"addr":"a.web","resource_type":"a"},"action":"replace"}}"#
            let two = #"{"type":"planned_change","change":{"resource":{"addr":"a.web","resource_type":"a"},"action":"delete"}}"#
            let sum = #"{"type":"change_summary","changes":{"add":1,"change":0,"remove":2,"import":0,"operation":"plan"}}"#
            let ids = onlyPlan([one, two, sum].joined(separator: "\n"))?.resources.map(\.id) ?? []
            check("an address announced twice by a stream is one row", ids == ["a.web"])
        }

        print()
        print("── what is not a header, and what is not a plan ──")
        do {
            let heredoc = onlyPlan("      + user_data = <<-EOT\n          # database will be created later\n          # the web.server will be created too\n        EOT\n  # aws_instance.real will be created\nPlan: 1 to add, 0 to change, 0 to destroy.")
            equal("a comment that reads like a header is not a row", heredoc.map(rows) ?? [],
                  ["create:aws_instance.real"])
            check("a format 0.x document is still read",
                  onlyPlan(#"{"format_version":"0.2","applyable":true,"complete":true,"errored":false,"planned_values":{},"resource_changes":[{"address":"a.b","mode":"managed","type":"a","name":"b","change":{"actions":["create"],"before":null,"after":{"x":"1"}}}]}"#)?.toAdd == 1)

            let movedOnly = TerraformPlanSummary(resources: [
                .init(address: "a.new", type: "a", category: .moved, movedFrom: "a.old",
                      actionReason: nil, attributes: []),
            ])
            let outputsOnly = TerraformPlanSummary(outputChanges: [
                .init(name: "x", before: "1", after: "2", isUnknown: false),
            ])
            equal("a plan with only zeros is not an echo of any other plan with zeros",
                  TerraformPlanParser.reconcile([movedOnly, outputsOnly], stepNames: ["Terraform Plan"]).count, 2)

            // Two guards protect a plan from being taken for an echo: it must
            // have something counted, and nothing else of its own. Each needs
            // a case that the other does not already cover.
            let row = TerraformPlanSummary.ResourceChange(
                address: "a.b", type: "a", category: .create, movedFrom: nil,
                actionReason: nil, attributes: [])
            let detailed = TerraformPlanSummary(toAdd: 2, resources: [row])
            let withOutputs = TerraformPlanSummary(
                toAdd: 2,
                outputChanges: [.init(name: "x", before: nil, after: "1", isUnknown: false)])
            equal("a counted plan that also changes an output is not an echo",
                  TerraformPlanParser.reconcile([detailed, withOutputs], stepNames: ["Terraform Plan"]).count, 2)
            let bare = TerraformPlanSummary(toAdd: 2)
            equal("while a bare counted one with the same numbers is",
                  TerraformPlanParser.reconcile([detailed, bare], stepNames: ["Terraform Plan"]).count, 1)
            equal("a bare counted plan that failed is not an echo",
                  TerraformPlanParser.reconcile(
                      [detailed, TerraformPlanSummary(toAdd: 2, isErrored: true)],
                      stepNames: ["Terraform Plan"]).count, 2)
            equal("nor one that carries drift",
                  TerraformPlanParser.reconcile(
                      [detailed, TerraformPlanSummary(toAdd: 2, driftedAddresses: ["a.b"])],
                      stepNames: ["Terraform Plan"]).count, 2)
            equal("two identical plans from one step are one plan",
                  TerraformPlanParser.reconcile([detailed, detailed], stepNames: ["Terraform Plan"]).count, 1)

            func nested(_ depth: Int) -> String {
                var value = #""leaf""#
                for _ in 0..<depth { value = #"{"k":"# + value + "}" }
                return value
            }
            func nestedPlan(_ depth: Int) -> String {
                let value = nested(depth)
                return document(#""resource_changes":[{"address":"a.b","mode":"managed","type":"a","name":"b","change":{"actions":["create"],"after":{"x":\#(value)}}}]"#)
            }
            equal("a line nested 20 deep is read", parse(nestedPlan(20)).count, 1)
            // A real-shaped plan with fourteen nested WAF statements is 71 deep
            // (configuration and prior_state count too), and was refused when
            // the limit was 64.
            equal("one nested 80 deep is read too", parse(nestedPlan(80)).count, 1)
            equal("one nested 150 deep is refused before it is decoded", parse(nestedPlan(150)).count, 0)
            // Brackets inside a string are not nesting, escaped quotes do not end it.
            let brackets = String(repeating: "[", count: 200)
            let quoted = document(#""resource_changes":[{"address":"a.b","mode":"managed","type":"a","name":"b","change":{"actions":["create"],"after":{"x":"\#(brackets)"}}}]"#)
            equal("200 opening brackets inside a string are just a string", parse(quoted).count, 1)
            let escaped = document(#""resource_changes":[{"address":"a.b","mode":"managed","type":"a","name":"b","change":{"actions":["create"],"after":{"x":"\"\#(brackets)"}}}]"#)
            equal("and an escaped quote does not end that string early", parse(escaped).count, 1)
        }

        print()
        print("── actions, which change no resource ──")
        do {
            let text = onlyPlan("Plan: 0 to add, 0 to change, 0 to destroy. Actions: 1 to invoke.")
            check("text: an actions-only plan is not \"no changes\"",
                  text.map { $0.toInvoke == 1 && !$0.isNoOpPlan } ?? false)
            let json = onlyPlan(document(#""resource_changes":[],"action_invocations":[{"address":"action.x.y"}]"#))
            check("show -json: the same", json.map { $0.toInvoke == 1 && !$0.isNoOpPlan } ?? false)
            let stream = onlyPlan(#"{"type":"change_summary","changes":{"add":0,"change":0,"remove":0,"import":0,"action_invocation":1,"operation":"plan"}}"#)
            check("plan -json: the same", stream.map { $0.toInvoke == 1 && !$0.isNoOpPlan } ?? false)
            let deferred = onlyPlan(document(#""resource_changes":[],"deferred_action_invocations":[{"reason":"x"}]"#))
            check("a deferred action makes the plan partial", deferred?.isPartial == true)
        }

        print()
        print("── both tools say \"Planning failed.\" ──")
        for tool in ["Terraform", "OpenTofu"] {
            let failed = onlyPlan("Planning failed. \(tool) encountered an error while generating this plan.\n\nError: boom")
            check("\(tool): an empty plan that failed is errored, not calm",
                  failed.map { $0.isErrored && $0.isNoOpPlan } ?? false)
        }

        print()
        print("── a big log still reads right ──")
        do {
            let noise = (0..<50_000).map { "2026-09-14T10:23:45Z building module \($0) ok" }
            check("no plan in 50k lines", parse(noise.joined(separator: "\n")).isEmpty)
            var withPlan = noise
            withPlan.insert(F.mixedText, at: 25_000)
            check("one plan in the middle of 50k lines",
                  onlyPlan(withPlan.joined(separator: "\n"))?.resources.count == 4)
        }

        print()
        if failures == 0 {
            print("RESULT: PASS — one plan reads the same however it was printed")
        } else {
            print("RESULT: FAIL — \(failures) case(s) wrong")
            exit(1)
        }
    }
}
