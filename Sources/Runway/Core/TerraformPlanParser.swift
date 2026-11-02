import Foundation

/// Turns a job's raw log into the plan summary the panel draws.
///
/// Three paths, tried in order. The JSON document is Terraform's own machine
/// format (`terraform show -json`) and is exact — every case in
/// `TerraformPlanSummary.ResourceChange.Category` comes from it with no
/// guessing. The stream (`terraform plan -json`) is the other documented
/// machine format: it names every resource and its action and carries the
/// counts, but not the attributes. The text one reads the CLI's human output,
/// which HashiCorp does not version or guarantee the way it does `-json`: it
/// recovers *what* changed (create, update, destroy, replace, a plain
/// rename) from wording confirmed against real `terraform plan` runs
/// (Terraform 1.17), but not attribute-level diffs — those need the JSON a
/// workflow can add with one extra step, and guessing at them from prose is
/// exactly the kind of "looks right, is wrong 10% of the time" this avoids.
enum TerraformPlanParser {
    /// Every plan in the log, in the order it was printed — empty when there
    /// is none.
    ///
    /// Plural because one job can plan more than once: `staging` and then
    /// `staging-dr` in two steps of the same job, or a loop over directories
    /// in one. Returning only the first used to be the whole bug — the second
    /// environment's plan was read, parsed and thrown away, and the one that
    /// was drawn looked like the job's only answer.
    static func parse(log: String) -> [TerraformPlanSummary] {
        // One contiguous UTF-8 buffer for everything below. A string the
        // platform bridged in rather than built natively would otherwise be
        // copied by each pass that wants bytes; for a native one — which is
        // what `String(data:encoding:)` makes — this does nothing at all.
        var log = log
        log.makeContiguousUTF8()
        let facts = LogFacts(log)
        if facts.mayHoldPlanDocument {
            let documents = extractJSONDocuments(from: log)
            if !documents.isEmpty {
                return documents.map(summarize)
            }
        }
        if facts.mayHoldMachineStream {
            let streamed = parseMachineStream(log)
            if !streamed.isEmpty {
                return streamed
            }
        }
        return parsePlainTextPlans(log, facts: facts)
    }

    /// Match parsed plans to the steps that printed them, by order.
    ///
    /// The log says what was planned but not which step printed it; the jobs
    /// API says which steps looked like plans but not what they printed. When
    /// the two counts agree, plan *n* belongs to step *n* and takes its name
    /// — "Terraform Plan (staging-dr)" is the one word that tells two rows of
    /// counts apart. When there are more plans than steps, the likeliest
    /// reason is the same plan printed twice (planned, then echoed again for a
    /// PR comment), so exact duplicates are dropped before trying again, and
    /// then so is a bare `Plan: …` line whose numbers a fuller plan already
    /// accounts for; two steps whose plans genuinely came out identical
    /// survive that, because then the counts already agree and nothing is
    /// dropped. Anything still ambiguous is numbered rather than named: a
    /// wrong environment name on a plan is worse than no name at all.
    static func reconcile(
        _ plans: [TerraformPlanSummary],
        stepNames: [String]
    ) -> [TerraformPlanSummary] {
        var plans = plans
        if plans.count > stepNames.count {
            var seen = Set<TerraformPlanSummary>()
            plans = plans.filter { seen.insert($0).inserted }
        }
        if plans.count > stepNames.count {
            plans = droppingEchoedCounts(plans)
        }
        guard plans.count > 1 else { return plans }
        let names = plans.count == stepNames.count
            ? stepNames
            : plans.indices.map { "plan \($0 + 1)" }
        return zip(plans, names).map { plan, name in
            var labelled = plan
            labelled.label = name
            return labelled
        }
    }

    /// A plan that is only a `Plan: …` line — no resources behind it — whose
    /// numbers a plan with resources already adds up to. Tools that comment a
    /// plan back onto a PR echo exactly that line into the log, and it parses
    /// as a plan of its own. A replace is one add and one destroy on that
    /// line, so the comparison counts it as both.
    private static func droppingEchoedCounts(
        _ plans: [TerraformPlanSummary]
    ) -> [TerraformPlanSummary] {
        func totals(_ plan: TerraformPlanSummary) -> [Int] {
            [plan.toAdd + plan.toReplace, plan.toChange, plan.toDestroy + plan.toReplace,
             plan.toImport, plan.toForget, plan.toInvoke]
        }
        // A set, not a list: a log of thousands of plans would otherwise make
        // this a comparison of every bare plan against every detailed one.
        let detailed = Set(plans.filter { !$0.resources.isEmpty }.map(totals))
        return plans.filter { plan in
            // Only a bare `Plan:` line with something in it. A plan that
            // carries outputs, drift or a failure is a plan of its own even
            // when its counts are zero, and zeros match any other zeros.
            guard plan.resources.isEmpty, plan.outputChanges.isEmpty,
                  plan.driftedAddresses.isEmpty, !plan.isErrored, !plan.isPartial,
                  totals(plan).contains(where: { $0 > 0 })
            else { return true }
            return !detailed.contains(totals(plan))
        }
    }

    // MARK: - What a log mentions at all

    /// What a log mentions at all, found with one byte-level pass each before
    /// any per-line work. A job log can be megabytes, and most of it is not
    /// Terraform: asking every line about every phrase it might contain made
    /// a log with no plan in it cost as much as one with several. Each phrase
    /// a path needs is looked up here once, and a path whose phrase is
    /// nowhere in the log never looks at a single line.
    private struct LogFacts {
        let mayHoldPlanDocument: Bool
        let mayHoldMachineStream: Bool
        let hasPlanLine: Bool
        let hasNoChanges: Bool
        let hasPlanningFailed: Bool
        let hasNoCurrentChanges: Bool
        let hasProblemSentence: Bool
        let hasEscape: Bool

        init(_ log: String) {
            var text = log
            self = text.withUTF8 { bytes in
                func has(_ needle: String) -> Bool {
                    TerraformPlanParser.contains(needle, in: bytes)
                }
                return LogFacts(
                    mayHoldPlanDocument: has("\"format_version\"")
                        && (has("\"resource_changes\"") || has("\"planned_values\"")
                            || has("\"applyable\"") || has("\"output_changes\"")),
                    mayHoldMachineStream: has("\"type\":\"change_summary\"")
                        || has("\"type\":\"planned_change\""),
                    hasPlanLine: has("Plan:"),
                    hasNoChanges: has("No changes."),
                    hasPlanningFailed: has("Planning failed."),
                    hasNoCurrentChanges: has("No current changes."),
                    hasProblemSentence: has(TerraformPlanParser.problemSentence),
                    hasEscape: bytes.contains(0x1B)
                )
            }
        }

        private init(
            mayHoldPlanDocument: Bool, mayHoldMachineStream: Bool, hasPlanLine: Bool,
            hasNoChanges: Bool, hasPlanningFailed: Bool, hasNoCurrentChanges: Bool,
            hasProblemSentence: Bool, hasEscape: Bool
        ) {
            self.mayHoldPlanDocument = mayHoldPlanDocument
            self.mayHoldMachineStream = mayHoldMachineStream
            self.hasPlanLine = hasPlanLine
            self.hasNoChanges = hasNoChanges
            self.hasPlanningFailed = hasPlanningFailed
            self.hasNoCurrentChanges = hasNoCurrentChanges
            self.hasProblemSentence = hasProblemSentence
            self.hasEscape = hasEscape
        }
    }

    /// Whether `needle` occurs in `haystack`, byte for byte — no `NSString`
    /// bridging and no grapheme segmentation, which are what make
    /// `String.contains` slow on a log this size.
    private static func contains(_ needle: String, in haystack: UnsafeBufferPointer<UInt8>) -> Bool {
        let target = Array(needle.utf8)
        guard let first = target.first else { return true }
        let count = haystack.count
        guard count >= target.count else { return false }
        let last = count - target.count
        var index = 0
        while index <= last {
            if haystack[index] == first {
                var offset = 1
                while offset < target.count && haystack[index + offset] == target[offset] {
                    offset += 1
                }
                if offset == target.count { return true }
            }
            index += 1
        }
        return false
    }

    /// The log's lines, split on the bytes rather than on `Character`s.
    /// `Character` view splitting is slow on a large string, and it also
    /// treats `"\r\n"` as one `Character` that is not `"\n"` — a log written
    /// with Windows line endings would not split at all. A lone `\r` (a
    /// progress line redrawn in place) is a break too.
    private static func lines(of log: String) -> [Substring] {
        log.utf8
            .split(whereSeparator: { $0 == 0x0A || $0 == 0x0D })
            .map { Substring($0) }
    }

    /// The largest count a `Plan:` line or a stream summary is believed to
    /// hold. Terraform's numbers are plain, but this reads a *log*: anything
    /// can print "Plan: -9223372036854775808 to add", and an `Int` that size
    /// subtracted from another traps the whole app. No real plan has a
    /// million of anything.
    private static let maxCount = 1_000_000

    private static func validCount(_ value: Int?) -> Int? {
        guard let value, (0...maxCount).contains(value) else { return nil }
        return value
    }

    private static func clampedCount(_ value: Int?) -> Int {
        min(max(value ?? 0, 0), maxCount)
    }

    /// A `Plan:` line counts a replace as one add plus one destroy; the
    /// headers (or the stream's rows) say how many of the adds and destroys
    /// really were replaces. Not every replace destroys, though: one that
    /// keeps the old object (`forget` then create) is an add and nothing
    /// else. So a replace is first matched against a destroy that no plain
    /// destroy row already explains, and what is left over is the kind that
    /// destroys nothing.
    private static func splitReplaces(
        replaceRows: Int, destroyRows: Int, add: Int, destroy: Int
    ) -> (replaced: Int, add: Int, destroy: Int) {
        let destroying = max(0, min(replaceRows, add, destroy - destroyRows))
        let keeping = max(0, min(replaceRows - destroying, add - destroying))
        return (destroying + keeping, add - destroying - keeping, destroy - destroying)
    }

    /// The deepest a JSON line may nest before it is not read. The whole line
    /// counts, not only the parts that are decoded: `show -json` carries
    /// `configuration` and `prior_state` too, and a chain of 25 nested modules
    /// is already 54 levels deep there. `JSONValue` recurses once per level of
    /// what it does decode, and a line built to be deep (this reads a *log*)
    /// could otherwise cost seconds or overflow a worker thread's stack:
    /// measured with a 512 KB stack, an optimised build survives 200 levels
    /// of a decoded attribute and crashes at 300. 100 leaves more than half of
    /// that as margin, and a real-shaped plan with fourteen nested WAF
    /// statements (71 deep) fits.
    private static let maxJSONDepth = 100

    /// Whether `text` nests `{`/`[` deeper than `limit`, counting only
    /// brackets outside strings, and stopping the moment it does.
    private static func nests(deeperThan limit: Int, _ text: Substring) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in text.utf8 {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                }
            } else if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                if depth > limit { return true }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
            }
        }
        return false
    }

    /// The longest a value is kept for display. The panel draws one line of
    /// monospaced text per value; a 40 KB policy document or a base64 blob
    /// would only sit in memory — in the cache, and in every copy of the job
    /// — for a row that truncates it anyway.
    private static let displayLimit = 240

    private static func clipped(_ text: String) -> String {
        guard let cut = text.index(text.startIndex, offsetBy: displayLimit, limitedBy: text.endIndex),
              cut < text.endIndex
        else { return text }
        return String(text[..<cut]) + "…"
    }

    // MARK: - JSON path

    /// Scans every line for ones that decode as a plan document, rather than
    /// trying to isolate the Terraform step's own slice of the log.
    ///
    /// GitHub's per-line timestamp prefix on raw job logs is not part of this
    /// endpoint's documented contract, so nothing here assumes its width or
    /// format — this only assumes Go's default JSON encoder never puts a bare
    /// newline inside the object it prints, which is what keeps a
    /// `terraform show -json` invocation to exactly one line regardless of
    /// what precedes it on that line.
    ///
    /// A line is a plan when it names a `format_version` *and* one of the
    /// fields only a plan has. `resource_changes` alone is not that test: it
    /// is omitted when no resource changes, so a plan that only moves an
    /// output would be invisible. A state (`terraform show -json` without a
    /// plan file) has a `format_version` too, and none of those fields.
    static func extractJSONDocuments(from log: String) -> [TerraformPlanDocument] {
        let decoder = JSONDecoder()
        var documents: [TerraformPlanDocument] = []
        for rawLine in lines(of: log) {
            guard let brace = rawLine.utf8.firstIndex(of: 0x7B) else { continue }
            let candidate = rawLine[brace...]
            guard candidate.contains("\"format_version\"") else { continue }
            guard candidate.contains("\"resource_changes\"")
                || candidate.contains("\"planned_values\"")
                || candidate.contains("\"applyable\"")
                || candidate.contains("\"output_changes\"")
            else { continue }
            guard !nests(deeperThan: maxJSONDepth, candidate) else { continue }
            guard let data = candidate.data(using: .utf8) else { continue }
            if let document = try? decoder.decode(TerraformPlanDocument.self, from: data),
               document.isSupportedFormat {
                documents.append(document)
            }
        }
        return documents
    }

    static func summarize(_ document: TerraformPlanDocument) -> TerraformPlanSummary {
        var toAdd = 0, toChange = 0, toReplace = 0, toDestroy = 0
        var toImport = 0, toForget = 0, unchanged = 0
        var resources: [TerraformPlanSummary.ResourceChange] = []

        for entry in document.resourceChanges {
            let moved = entry.previousAddress != nil
            let importing = entry.change.importing != nil
            guard let category = category(
                for: entry.change.actions, moved: moved, importing: importing
            ) else {
                if entry.change.actions == ["no-op"] { unchanged += 1 }
                continue
            }
            switch category {
            case .create: toAdd += 1
            case .update: toChange += 1
            case .replace: toReplace += 1
            case .destroy: toDestroy += 1
            case .forget: toForget += 1
            case .read, .moved, .imported: break
            }
            // An import can come with any action — usually an update, when
            // the configuration differs from what was imported — so it is
            // counted on its own rather than as a category.
            if importing { toImport += 1 }

            let attributes: [TerraformPlanSummary.AttributeDiff]
            switch category {
            case .moved, .read, .imported:
                attributes = []
            case .create, .update, .replace, .destroy, .forget:
                attributes = attributeDiffs(for: entry.change)
            }
            // A deposed object shares its address with the live instance; the
            // text renderer tells them apart the same way.
            let address = entry.deposed.map { "\(entry.address) (deposed object \($0))" }
                ?? entry.address
            resources.append(.init(
                address: address,
                type: entry.type,
                category: category,
                movedFrom: entry.previousAddress,
                actionReason: entry.actionReason,
                attributes: attributes
            ))
        }

        let outputs: [TerraformPlanSummary.OutputChange] = (document.outputChanges ?? [:])
            .compactMap { name, change -> TerraformPlanSummary.OutputChange? in
                guard change.actions != ["no-op"] else { return nil }
                // Either side being sensitive hides both: an output that
                // turns sensitive must not show what it was a moment ago.
                let sensitive = JSONValue.union(change.beforeSensitive, change.afterSensitive)
                let before = JSONValue.masked(change.before, sensitive: sensitive, unknown: nil)
                let after = JSONValue.masked(
                    change.after, sensitive: sensitive, unknown: change.afterUnknown
                )
                return TerraformPlanSummary.OutputChange(
                    name: name,
                    before: before.map { clipped($0.displayString) },
                    after: after.map { clipped($0.displayString) },
                    isUnknown: change.afterUnknown?.flagsAnything ?? false
                )
            }
            .sorted { $0.name < $1.name }

        let drifted = (document.resourceDrift ?? []).map(\.address)
        let errored = document.errored == true
        // An errored plan is also incomplete; that is the lesser statement,
        // so it is not made twice.
        let partial = !errored && (document.complete == false || document.hasDeferredChanges)

        let toInvoke = min(document.actionInvocations, maxCount)

        return TerraformPlanSummary(
            toAdd: toAdd, toChange: toChange, toReplace: toReplace, toDestroy: toDestroy,
            toImport: toImport, toForget: toForget, toInvoke: toInvoke,
            unchangedCount: unchanged,
            resources: resources,
            outputChanges: outputs,
            driftedAddresses: drifted,
            // All four counts alone are not enough: a plan that is purely
            // `moved` blocks, or purely a data-source read, or purely an
            // output change touches none of them but still has rows to draw
            // — and drawing "no changes" above a list of things that changed
            // is a worse answer than drawing nothing.
            isNoOpPlan: toAdd == 0 && toChange == 0 && toReplace == 0 && toDestroy == 0
                && toImport == 0 && toForget == 0 && toInvoke == 0
                && resources.isEmpty && outputs.isEmpty && drifted.isEmpty,
            isErrored: errored,
            isPartial: partial
        )
    }

    /// Terraform's `actions` arrays, matched exactly rather than by count or
    /// membership — `["delete","create"]` and `["create","delete"]` are both
    /// a replace, but the order tells the two ways of running it apart, and
    /// anything not in this list (a future action HashiCorp adds) is skipped
    /// rather than guessed at.
    ///
    /// `forget` is what a `removed` block with `destroy = false` plans: the
    /// object leaves the state and is left standing. Paired with a create it
    /// is a replace that does not destroy the old object; it is drawn as a
    /// replace, and counted as one, because the new object really is being
    /// created in its place.
    private static func category(
        for actions: [String],
        moved: Bool,
        importing: Bool
    ) -> TerraformPlanSummary.ResourceChange.Category? {
        switch actions {
        case ["no-op"]: return moved ? .moved : (importing ? .imported : nil)
        case ["create"]: return .create
        case ["update"]: return .update
        case ["delete"]: return .destroy
        case ["read"]: return .read
        case ["forget"]: return .forget
        case ["delete", "create"], ["create", "delete"],
             ["forget", "create"], ["create", "forget"]:
            return .replace
        default: return nil
        }
    }

    /// Top-level attributes only — the same simplification real plan text
    /// makes when it prints "(2 unchanged attributes hidden)" rather than
    /// walking into a nested block. A list or map attribute is shown as one
    /// compact value rather than diffed element by element, and its
    /// per-element `replace_paths` entries are not walked into either.
    ///
    /// What *is* walked is the masks. A secret or an unknown value can sit
    /// anywhere inside an attribute — `after_sensitive` of
    /// `{"input": {"password": true}}` flags one key of one attribute — and
    /// `JSONValue.masked` replaces exactly those leaves before anything is
    /// turned into text.
    private static func attributeDiffs(
        for change: TerraformPlanDocument.ResourceChangeEntry.Change
    ) -> [TerraformPlanSummary.AttributeDiff] {
        let before = change.before?.objectValue ?? [:]
        let after = change.after?.objectValue ?? [:]

        let forcedKeys = Set(
            (change.replacePaths ?? []).compactMap { path -> String? in
                guard case .string(let key)? = path.first else { return nil }
                return key
            }
        )

        // An unknown attribute is *absent* from `after`, so the keys that
        // exist only in `after_unknown` are attributes too.
        var keys = Set(before.keys).union(after.keys)
        if let flags = change.afterUnknown?.objectValue { keys.formUnion(flags.keys) }
        keys.remove("id") // noise: every resource's own id, never worth a diff row

        guard !keys.isEmpty else { return [] }
        let sensitiveMask = JSONValue.union(change.beforeSensitive, change.afterSensitive)

        /// `null` and absent are the same thing to a reader: a created
        /// resource's unset attributes arrive as `null` in `after`, and would
        /// otherwise each be a row that says "nothing → nothing".
        func present(_ value: JSONValue?) -> JSONValue? {
            if case .null? = value { return nil }
            return value
        }

        return keys.sorted().compactMap { key in
            let beforeValue = before[key]
            let afterValue = after[key]
            let unknownMask = change.afterUnknown?.maskChild(key)
            let unknown = unknownMask?.flagsAnything ?? false
            guard unknown || present(beforeValue) != present(afterValue) else { return nil }
            let sensitive = sensitiveMask?.maskChild(key)
            let shownBefore = JSONValue.masked(beforeValue, sensitive: sensitive, unknown: nil)
            let shownAfter = JSONValue.masked(afterValue, sensitive: sensitive, unknown: unknownMask)
            return TerraformPlanSummary.AttributeDiff(
                key: key,
                before: shownBefore.map { clipped($0.displayString) },
                after: shownAfter.map { clipped($0.displayString) },
                isSensitive: sensitive?.flagsAnything ?? false,
                isUnknown: unknown,
                forcesReplacement: forcedKeys.contains(key)
            )
        }
    }

    // MARK: - Machine stream (`terraform plan -json`)

    /// One plan's worth of the stream, before it is a summary.
    private struct StreamPlan {
        var rows: [TerraformPlanSummary.ResourceChange] = []
        var counts: TerraformUIMessage.Summary?
        var outputs: [TerraformPlanSummary.OutputChange] = []
        var isErrored = false
    }

    /// Reads `terraform plan -json`: one message per line, `planned_change`
    /// for each resource and then a `change_summary`, with the outputs and any
    /// diagnostics after it.
    ///
    /// Before this existed the stream fell through to the text path, which
    /// found the `Plan: …` inside each `@message` and drew counts with no
    /// rows — and a forget, or an outputs-only plan, as a green "no changes".
    ///
    /// A failure is only attributed to the plan when nothing has been applied
    /// since: after `apply_start` an error is the apply's, and the plan above
    /// it was fine.
    static func parseMachineStream(_ log: String) -> [TerraformPlanSummary] {
        let decoder = JSONDecoder()
        var finished: [StreamPlan] = []
        var pending: [TerraformPlanSummary.ResourceChange] = []
        /// Addresses already in `pending`. A deposed object is announced under
        /// the address of the live one, and a row is keyed by its address.
        var pendingAddresses = Set<String>()
        /// The plan the next `outputs` or `diagnostic` message belongs to.
        var current: Int?

        for rawLine in lines(of: log) {
            guard let brace = rawLine.utf8.firstIndex(of: 0x7B) else { continue }
            let candidate = rawLine[brace...]
            guard !nests(deeperThan: maxJSONDepth, candidate),
                  let data = candidate.data(using: .utf8),
                  let message = try? decoder.decode(TerraformUIMessage.self, from: data)
            else { continue }

            switch message.type {
            case "planned_change":
                current = nil
                if let change = message.change, let row = streamRow(change),
                   pendingAddresses.insert(row.address).inserted {
                    pending.append(row)
                }
            case "change_summary":
                let counts = message.changes
                if counts?.operation == nil || counts?.operation == "plan" {
                    finished.append(StreamPlan(rows: pending, counts: counts))
                    current = finished.count - 1
                } else {
                    current = nil
                }
                pending = []
                pendingAddresses = []
            case "outputs":
                guard let current else { break }
                finished[current].outputs = (message.outputs ?? [:])
                    .filter { $0.value.action != nil && $0.value.action != "noop" }
                    .map { entry in
                        TerraformPlanSummary.OutputChange(
                            name: entry.key, before: nil, after: nil, isUnknown: false
                        )
                    }
                    .sorted { $0.name < $1.name }
            case "apply_start":
                current = nil
            case "version":
                // The first message of every command. An error after it
                // belongs to *that* command — a `terraform apply -json` step
                // that cannot get the state lock fails before it plans, and
                // must not mark the plan an earlier step printed — and rows
                // still waiting for a summary were cut off by it.
                current = nil
                if !pending.isEmpty {
                    finished.append(StreamPlan(rows: pending, counts: nil))
                    pending = []
                    pendingAddresses = []
                }
            case "diagnostic":
                guard message.diagnostic?.severity == "error" else { break }
                if let current {
                    finished[current].isErrored = true
                } else if !pending.isEmpty {
                    finished.append(StreamPlan(rows: pending, counts: nil, isErrored: true))
                    pending = []
                    pendingAddresses = []
                }
            default:
                break
            }
        }
        // Rows with no summary after them — a plan cut off by a failing step.
        if !pending.isEmpty {
            finished.append(StreamPlan(rows: pending, counts: nil))
        }
        return finished.map(summary(of:))
    }

    private static func streamRow(
        _ change: TerraformUIMessage.Change
    ) -> TerraformPlanSummary.ResourceChange? {
        let category: TerraformPlanSummary.ResourceChange.Category
        switch change.action {
        case "create": category = .create
        case "update": category = .update
        case "replace": category = .replace
        case "delete": category = .destroy
        case "read": category = .read
        case "move": category = .moved
        case "import": category = .imported
        case "remove": category = .forget
        default: return nil // `noop`, and anything HashiCorp adds later
        }
        let address = change.resource.addr
        return TerraformPlanSummary.ResourceChange(
            address: address,
            type: change.resource.resourceType ?? inferredType(fromAddress: address),
            category: category,
            movedFrom: change.previousResource?.addr,
            actionReason: change.reason,
            attributes: []
        )
    }

    private static func summary(of plan: StreamPlan) -> TerraformPlanSummary {
        func rows(_ category: TerraformPlanSummary.ResourceChange.Category) -> Int {
            plan.rows.filter { $0.category == category }.count
        }
        var forgotten = rows(.forget)
        let toAdd: Int, toChange: Int, toReplace: Int, toDestroy: Int
        let toImport: Int, toInvoke: Int
        if let counts = plan.counts {
            // The summary counts a replace as one add and one destroy.
            let split = splitReplaces(
                replaceRows: rows(.replace), destroyRows: rows(.destroy),
                add: clampedCount(counts.add), destroy: clampedCount(counts.remove)
            )
            toReplace = split.replaced
            toAdd = split.add
            toDestroy = split.destroy
            toChange = clampedCount(counts.change)
            toImport = clampedCount(counts.imported)
            toInvoke = clampedCount(counts.invoked)
            // OpenTofu counts forgets itself; Terraform's summary has no such
            // field, and its rows are all there is.
            forgotten = max(forgotten, clampedCount(counts.forgotten))
        } else {
            toAdd = rows(.create)
            toChange = rows(.update)
            toReplace = rows(.replace)
            toDestroy = rows(.destroy)
            toImport = rows(.imported)
            toInvoke = 0
        }
        return TerraformPlanSummary(
            toAdd: toAdd, toChange: toChange, toReplace: toReplace, toDestroy: toDestroy,
            toImport: toImport, toForget: forgotten, toInvoke: toInvoke,
            unchangedCount: nil,
            resources: plan.rows,
            outputChanges: plan.outputs,
            driftedAddresses: [],
            isNoOpPlan: toAdd == 0 && toChange == 0 && toReplace == 0 && toDestroy == 0
                && toImport == 0 && forgotten == 0 && toInvoke == 0
                && plan.rows.isEmpty && plan.outputs.isEmpty,
            isErrored: plan.isErrored
        )
    }

    // MARK: - Plain-text fallback

    /// Wording confirmed against real `terraform plan` runs (Terraform
    /// 1.17): the per-resource `#` header, the moved-resource line, the
    /// deferred-data-source line, and the trailing `Plan:` summary.
    /// Attribute diffs are not attempted — see this type's own doc comment.
    ///
    /// One plan per closing line. Terraform ends every plan it prints with
    /// either `Plan: … to destroy.` (the `to import` / `to forget` variants
    /// included — `to destroy` is in all of them) or one of its full
    /// `No changes.` sentences, so each of those closes whatever headers came
    /// before it into one summary and starts the next. A job that plans two environments in a row prints two
    /// closing lines and gets two plans, instead of one plan whose counts are
    /// the two added together — or, when both environments share the same
    /// module addresses, the second silently de-duplicated into the first.
    ///
    /// A plan that fails prints one of two sentences — "Planning failed." when
    /// it had nothing to show, or "…but then encountered a problem:" ahead of
    /// what it had — and either one marks the plan errored, so that an empty
    /// plan that failed is not drawn as one that is fine.
    ///
    /// The numbers come from the `Plan:` line whenever there is one, not from
    /// tallying the headers. Terraform computes that line from the plan
    /// itself; the headers are wording this code has to recognise, and a
    /// phrasing it does not know (a replace "as requested", a forget) would
    /// otherwise silently shave a count off. The headers still supply the
    /// rows, and how many of the adds and destroys were really replaces.
    ///
    /// Two things this does *not* do, both on purpose, both found by review
    /// rather than assumed away:
    ///
    ///  * It never treats "No changes." as a verdict on the whole log. A job
    ///    that loops `terraform plan` over several directories can have one
    ///    directory print exactly that sentence while another, later in the
    ///    same log, prints real destroys — each gets its own plan here, so a
    ///    calm green line is only ever drawn for the plan that earned it.
    ///  * It de-duplicates by address *within* a plan. A header line printed
    ///    twice before the same closing line would otherwise double its count
    ///    and hand `ForEach` the same id twice over — undefined behaviour in
    ///    SwiftUI, not just a cosmetic one. The same plan echoed again whole,
    ///    closing line and all, is `reconcile`'s to drop.
    ///
    /// Every line is matched with its colour codes taken out first. Without
    /// `-no-color` Terraform wraps `Plan:` and each `# address` in bold, and
    /// GitHub keeps the escape sequences in the raw log, so the words this
    /// looks for are not contiguous until they are gone — which is how two
    /// coloured plans used to run together into one.
    static func parsePlainTextPlans(_ log: String) -> [TerraformPlanSummary] {
        parsePlainTextPlans(log, facts: LogFacts(log))
    }

    private static func parsePlainTextPlans(
        _ log: String,
        facts: LogFacts
    ) -> [TerraformPlanSummary] {
        // The problem sentence is on this list for the plan that was cut off
        // right after it: headers, and no `Plan:` line ever follows.
        guard facts.hasPlanLine || facts.hasNoChanges
            || facts.hasPlanningFailed || facts.hasNoCurrentChanges
            || facts.hasProblemSentence
        else { return [] }

        var plans: [TerraformPlanSummary] = []
        var segment = PlainTextSegment()

        for rawLine in lines(of: log) {
            let line = facts.hasEscape ? withoutColour(rawLine) : rawLine
            if facts.hasNoChanges, isNoChangesLine(line) {
                plans.append(segment.summary())
                segment = PlainTextSegment()
                continue
            }
            if facts.hasPlanningFailed, line.contains("Planning failed."),
               line.contains("encountered an error while generating this plan") {
                segment.isErrored = true
                plans.append(segment.summary())
                segment = PlainTextSegment()
                continue
            }
            if facts.hasNoCurrentChanges,
               line.contains("No current changes. This plan requires another plan") {
                segment.isPartial = true
                plans.append(segment.summary())
                segment = PlainTextSegment()
                continue
            }
            if facts.hasPlanLine, let counts = planLineCounts(line) {
                plans.append(segment.summary(closingCounts: counts))
                segment = PlainTextSegment()
                continue
            }
            segment.consume(line, checksProblemSentence: facts.hasProblemSentence)
        }
        // Headers with no closing line after them — an outputs-only plan
        // prints none, and neither does a plan cut off by a failing step.
        // Still what was matched; dropping it would hide real changes.
        if !segment.order.isEmpty {
            plans.append(segment.summary())
        }
        return plans
    }

    /// The sentence printed ahead of the changes a plan had listed when
    /// planning then failed. It opens with the tool's own name — "Terraform
    /// planned the following actions…", "OpenTofu planned…" — which is why the
    /// match starts after it, and why "Planning failed." above is matched on
    /// the words that follow the name as well.
    private static let problemSentence = " planned the following actions, but then encountered a problem"

    /// The line with its ANSI colour codes (`ESC [ … m`, and any other CSI
    /// sequence) removed. Returns the line untouched — no copy — when there is
    /// no escape in it, which is every line of a `-no-color` log.
    static func withoutColour(_ line: Substring) -> Substring {
        guard line.utf8.contains(0x1B) else { return line }
        var out = String.UnicodeScalarView()
        var scalars = line.unicodeScalars.makeIterator()
        while let scalar = scalars.next() {
            guard scalar == "\u{1B}" else {
                out.append(scalar)
                continue
            }
            guard let next = scalars.next() else { break }
            guard next == "[" else {
                out.append(next)
                continue
            }
            // Parameters until the final byte, which is consumed with them.
            while let byte = scalars.next(), !(0x40...0x7E).contains(byte.value) {}
        }
        return Substring(String(out))
    }

    /// Terraform's own no-change sentences, whole. A bare `No changes.` is not
    /// enough: GitHub prints every `run:` script into the log above its
    /// output, so a step that greps for that phrase would otherwise close an
    /// empty plan of its own and draw a green line nobody earned.
    private static func isNoChangesLine(_ line: Substring) -> Bool {
        line.contains("No changes. Your infrastructure")
            || line.contains("No changes. No objects")
            || line.contains("No changes. Infrastructure is up-to-date")
    }

    /// The counts on a `Plan: 1 to import, 2 to add, 0 to change, 1 to
    /// destroy.` line, or `nil` when this is not one. Terraform's line has no
    /// forget count, and OpenTofu's does; both read the same way. Terraform
    /// appends ` Actions: 1 to invoke.` when the plan runs provider actions.
    ///
    /// A number outside `0...maxCount` is not a count: `Int("-5")` parses,
    /// and a log is free to say anything.
    fileprivate struct PlanLineCounts {
        var add = 0, change = 0, destroy = 0, imported = 0, forgotten = 0, invoked = 0
    }

    private static func planLineCounts(_ line: Substring) -> PlanLineCounts? {
        guard let start = line.range(of: "Plan: "), line.contains(" to destroy") else {
            return nil
        }
        var counts = PlanLineCounts()
        for part in line[start.upperBound...].split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count >= 3, let count = validCount(Int(words[0])) else { continue }
            switch words[2].trimmingCharacters(in: .punctuationCharacters) {
            case "add": counts.add = count
            case "change": counts.change = count
            case "destroy": counts.destroy = count
            case "import": counts.imported = count
            case "forget": counts.forgotten = count
            default: break
            }
        }
        if let actions = line.range(of: "Actions: ") {
            let words = line[actions.upperBound...].split(separator: " ")
            if words.count >= 3, let count = validCount(Int(words[0])),
               words[2].trimmingCharacters(in: .punctuationCharacters) == "invoke" {
                counts.invoked = count
            }
        }
        return counts
    }

    /// Whether `text` could be a resource address. A comment that happens to
    /// read like a header — `# database will be created later`, inside a
    /// heredoc the plan is showing — would otherwise become a row, and its
    /// "address" is whatever came before the words. A real address has a dot
    /// and no space outside an `[index]`, apart from the ` (deposed object …)`
    /// tag Terraform appends.
    fileprivate static func looksLikeAddress(_ text: String) -> Bool {
        var address = Substring(text)
        if let tag = address.range(of: " (deposed object ") {
            address = address[..<tag.lowerBound]
        }
        guard address.contains(".") else { return false }
        // Inside an `[index]` anything goes — including a `]` or a space, in a
        // quoted `for_each` key — so quotes are followed there.
        var depth = 0
        var inQuote = false
        var escaped = false
        for character in address {
            if inQuote {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuote = false
                }
            } else if depth > 0, character == "\"" {
                inQuote = true
            } else if character == "[" {
                depth += 1
            } else if character == "]" {
                depth -= 1
            } else if depth <= 0, character.isWhitespace {
                return false
            }
        }
        return true
    }

    /// The headers seen since the last closing line.
    private struct PlainTextSegment {
        var toAdd = 0, toChange = 0, toDestroy = 0, toReplace = 0
        var toImport = 0, toForget = 0
        var isErrored = false
        var isPartial = false
        var byAddress: [String: TerraformPlanSummary.ResourceChange] = [:]
        var order: [String] = []
        /// The row a following `# (moved from …)` line belongs to.
        var lastAddress: String?

        /// Most specific first: ` must be replaced` is inside ` is tainted,
        /// so must be replaced`, and the two are not the same row — the
        /// address is whatever comes before the marker, so a marker that is
        /// too general leaves the rest of the sentence in it.
        ///
        /// A forget is worded differently by the two tools that are run in CI,
        /// and neither contains the other's name: Terraform says "will no
        /// longer be managed by Terraform", OpenTofu "will be removed from the
        /// OpenTofu state" (both confirmed against real runs). The marker
        /// stops before the tool's name.
        private static let markers: [(String, TerraformPlanSummary.ResourceChange.Category)] = [
            (" is tainted, so must be replaced", .replace),
            (" is tainted, so it must be replaced", .replace), // OpenTofu
            (" will be replaced, as requested", .replace),
            (" will be replaced due to changes in replace_triggered_by", .replace),
            (" must be replaced", .replace),
            (" will be created", .create),
            (" will be destroyed", .destroy),
            (" will be updated in-place", .update),
            (" will be read during apply", .read),
            (" will be imported", .imported),
            (" will no longer be managed by ", .forget),
            (" will be removed from ", .forget),
        ]

        /// Whether `rest` contains a word every header has: "will" (created,
        /// destroyed, updated, read, imported, no longer managed, removed),
        /// "must" (must be replaced, is tainted so must be replaced) or "has
        /// moved to". A byte search, so a line that is not a header costs
        /// three of them rather than a dozen string searches.
        private static func mayBeHeader(_ rest: Substring) -> Bool {
            rest.utf8.withContiguousStorageIfAvailable { buffer in
                TerraformPlanParser.contains(" will ", in: buffer)
                    || TerraformPlanParser.contains(" must ", in: buffer)
                    || TerraformPlanParser.contains(" has moved to ", in: buffer)
            } ?? true
        }

        mutating func consume(_ line: Substring, checksProblemSentence: Bool) {
            if checksProblemSentence, line.contains(TerraformPlanParser.problemSentence) {
                isErrored = true
                return
            }
            // Every header carries a `#`; a byte scan rules out nearly every
            // other line before any string search runs.
            guard line.utf8.contains(0x23) else { return }
            // Not `hasPrefix("# ")` on a trimmed line: GitHub's own raw log
            // prefixes *every* line with its own timestamp
            // (`2026-09-14T10:23:45.1234567Z   # aws_instance.web will be
            // created`), so anchoring at the start never matches anything —
            // this endpoint's line format is exactly why `extractJSONDocuments`
            // above already scans for its marker rather than assuming column
            // zero, and this fallback needs the same discipline.
            guard let hashRange = line.range(of: "# ") else { return }
            let rest = line[hashRange.upperBound...]

            // `# (moved from terraform_data.cache)` — printed under the
            // header of a resource that was both moved and changed.
            if rest.hasPrefix("(moved from "), let last = lastAddress, let row = byAddress[last] {
                var origin = rest.dropFirst("(moved from ".count)
                if origin.last == ")" { origin = origin.dropLast() }
                byAddress[last] = TerraformPlanSummary.ResourceChange(
                    address: row.address, type: row.type, category: row.category,
                    movedFrom: String(origin), actionReason: row.actionReason,
                    attributes: row.attributes
                )
                return
            }

            // Most lines with a `# ` in them are comments — a script, a config
            // file the job printed — and each one would otherwise be tried
            // against a dozen markers. Every header carries one of these.
            guard Self.mayBeHeader(rest) else { return }

            // Keyed by the *new* address, the way the JSON path's rows are —
            // the old one is only where it came from.
            if let range = rest.range(of: " has moved to ") {
                let origin = String(rest[rest.startIndex..<range.lowerBound])
                let address = rest[range.upperBound...].trimmingCharacters(in: .whitespaces)
                guard TerraformPlanParser.looksLikeAddress(address),
                      TerraformPlanParser.looksLikeAddress(origin)
                else { return }
                record(address: address, category: .moved, movedFrom: origin)
                return
            }

            for (marker, category) in Self.markers {
                guard let range = rest.range(of: marker) else { continue }
                let address = String(rest[rest.startIndex..<range.lowerBound])
                guard TerraformPlanParser.looksLikeAddress(address) else { continue }
                record(address: address, category: category, movedFrom: nil)
                return
            }
        }

        private mutating func record(
            address: String,
            category: TerraformPlanSummary.ResourceChange.Category,
            movedFrom: String?
        ) {
            let previous = byAddress[address]
            if previous == nil { order.append(address) }
            // Counted once per address. A bare move that is followed by a
            // real change for the same address is counted when the change
            // arrives, because the move itself counts for nothing.
            if previous == nil || previous?.category == .moved {
                switch category {
                case .create: toAdd += 1
                case .update: toChange += 1
                case .replace: toReplace += 1
                case .destroy: toDestroy += 1
                case .forget: toForget += 1
                case .imported: toImport += 1
                case .read, .moved: break
                }
            }
            byAddress[address] = TerraformPlanSummary.ResourceChange(
                address: address, type: TerraformPlanParser.inferredType(fromAddress: address),
                category: category, movedFrom: movedFrom ?? previous?.movedFrom,
                actionReason: nil, attributes: []
            )
            lastAddress = address
        }

        func summary(closingCounts: PlanLineCounts? = nil) -> TerraformPlanSummary {
            let resources = order.compactMap { byAddress[$0] }
            guard let counts = closingCounts else {
                // No `Plan:` line: the headers are all there is.
                return TerraformPlanSummary(
                    toAdd: toAdd, toChange: toChange, toReplace: toReplace, toDestroy: toDestroy,
                    toImport: toImport, toForget: toForget, toInvoke: 0,
                    unchangedCount: nil,
                    resources: resources,
                    outputChanges: [],
                    driftedAddresses: [],
                    isNoOpPlan: toAdd == 0 && toChange == 0 && toReplace == 0
                        && toDestroy == 0 && toImport == 0 && toForget == 0
                        && resources.isEmpty,
                    isErrored: isErrored,
                    isPartial: isPartial
                )
            }
            // The line counts a replace as one add and one destroy. How many
            // of those were replaces is the one thing only the headers know.
            let split = TerraformPlanParser.splitReplaces(
                replaceRows: toReplace, destroyRows: toDestroy,
                add: counts.add, destroy: counts.destroy
            )
            let replaced = split.replaced
            let toAdd = split.add
            let toDestroy = split.destroy
            let imported = max(counts.imported, toImport)
            let forgotten = max(counts.forgotten, toForget)
            return TerraformPlanSummary(
                toAdd: toAdd, toChange: counts.change, toReplace: replaced, toDestroy: toDestroy,
                toImport: imported, toForget: forgotten, toInvoke: counts.invoked,
                unchangedCount: nil,
                resources: resources,
                outputChanges: [],
                driftedAddresses: [],
                // A `Plan:` line with nothing above it still says what it
                // counted, and drawing "no changes" over "Plan: 2 to add" is
                // the one answer that is certainly wrong.
                isNoOpPlan: toAdd == 0 && counts.change == 0 && replaced == 0 && toDestroy == 0
                    && imported == 0 && forgotten == 0 && counts.invoked == 0
                    && resources.isEmpty,
                isErrored: isErrored,
                isPartial: isPartial
            )
        }
    }

    /// Best-effort resource type for a plain-text address, since there is no
    /// separate `type` field the way the JSON path has one: the
    /// second-to-last dot-separated component before any `[index]` —
    /// `aws_instance` out of `aws_instance.web[2]`, `aws_subnet` out of
    /// `module.vpc.aws_subnet.private`. Falls back to the full address if
    /// that shape does not hold, rather than guessing further.
    fileprivate static func inferredType(fromAddress address: String) -> String {
        var trimmed = Substring(address)
        if let bracket = trimmed.firstIndex(of: "[") { trimmed = trimmed[..<bracket] }
        let parts = trimmed.split(separator: ".")
        guard parts.count >= 2 else { return address }
        return String(parts[parts.count - 2])
    }
}
