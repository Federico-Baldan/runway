import Foundation

/// Turns a job's raw log into the plan summary the panel draws.
///
/// Two paths, tried in order. The JSON one is Terraform's own machine format
/// and is exact — every case in `TerraformPlanSummary.ResourceChange.Category`
/// comes from it with no guessing. The text one reads the CLI's human output,
/// which HashiCorp does not version or guarantee the way it does `-json`: it
/// recovers *what* changed (create, update, destroy, replace, a plain
/// rename) from wording confirmed against a real `terraform plan` run
/// (Terraform 1.16), but not attribute-level diffs — those need the JSON a
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
        let documents = extractJSONDocuments(from: log)
        if !documents.isEmpty {
            return documents.map(summarize)
        }
        return parsePlainTextPlans(log)
    }

    /// Match parsed plans to the steps that printed them, by order.
    ///
    /// The log says what was planned but not which step printed it; the jobs
    /// API says which steps looked like plans but not what they printed. When
    /// the two counts agree, plan *n* belongs to step *n* and takes its name
    /// — "Terraform Plan (staging-dr)" is the one word that tells two rows of
    /// counts apart. When there are more plans than steps, the likeliest
    /// reason is the same plan printed twice (planned, then echoed again for a
    /// PR comment), so exact duplicates are dropped before trying again; two
    /// steps whose plans genuinely came out identical survive that, because
    /// then the counts already agree and nothing is dropped. Anything still
    /// ambiguous is numbered rather than named: a wrong environment name on a
    /// plan is worse than no name at all.
    static func reconcile(
        _ plans: [TerraformPlanSummary],
        stepNames: [String]
    ) -> [TerraformPlanSummary] {
        var plans = plans
        if plans.count > stepNames.count {
            var seen = Set<TerraformPlanSummary>()
            plans = plans.filter { seen.insert($0).inserted }
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
    static func extractJSONDocuments(from log: String) -> [TerraformPlanDocument] {
        let decoder = JSONDecoder()
        var documents: [TerraformPlanDocument] = []
        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let brace = rawLine.firstIndex(of: "{") else { continue }
            let candidate = rawLine[brace...]
            guard candidate.contains("\"resource_changes\"") else { continue }
            guard let data = candidate.data(using: .utf8) else { continue }
            if let document = try? decoder.decode(TerraformPlanDocument.self, from: data) {
                documents.append(document)
            }
        }
        return documents
    }

    static func summarize(_ document: TerraformPlanDocument) -> TerraformPlanSummary {
        var toAdd = 0, toChange = 0, toReplace = 0, toDestroy = 0, unchanged = 0
        var resources: [TerraformPlanSummary.ResourceChange] = []

        for entry in document.resourceChanges {
            let moved = entry.previousAddress != nil
            guard let category = category(for: entry.change.actions, moved: moved) else {
                if entry.change.actions == ["no-op"] { unchanged += 1 }
                continue
            }
            switch category {
            case .create: toAdd += 1
            case .update: toChange += 1
            case .replace: toReplace += 1
            case .destroy: toDestroy += 1
            case .read, .moved: break
            }
            let attributes: [TerraformPlanSummary.AttributeDiff]
            switch category {
            case .moved, .read:
                attributes = []
            case .create, .update, .replace, .destroy:
                attributes = attributeDiffs(for: entry.change)
            }
            resources.append(.init(
                address: entry.address,
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
                let unknown = change.afterUnknown?.boolFlag(for: name) ?? false
                let sensitive = (change.beforeSensitive?.boolFlag(for: name) ?? false)
                    || (change.afterSensitive?.boolFlag(for: name) ?? false)
                return TerraformPlanSummary.OutputChange(
                    name: name,
                    before: change.before.map { sensitive ? "(sensitive value)" : $0.displayString },
                    after: unknown
                        ? "(known after apply)"
                        : change.after.map { sensitive ? "(sensitive value)" : $0.displayString },
                    isUnknown: unknown
                )
            }
            .sorted { $0.name < $1.name }

        let drifted = (document.resourceDrift ?? []).map(\.address)

        return TerraformPlanSummary(
            toAdd: toAdd, toChange: toChange, toReplace: toReplace, toDestroy: toDestroy,
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
                && resources.isEmpty && outputs.isEmpty && drifted.isEmpty
        )
    }

    /// Terraform's `actions` arrays, matched exactly rather than by count or
    /// membership — `["delete","create"]` and `["create","delete"]` are both
    /// a replace, but the order tells the two ways of running it apart, and
    /// anything not in this list (a future action HashiCorp adds) is skipped
    /// rather than guessed at.
    private static func category(
        for actions: [String],
        moved: Bool
    ) -> TerraformPlanSummary.ResourceChange.Category? {
        switch actions {
        case ["no-op"]: return moved ? .moved : nil
        case ["create"]: return .create
        case ["update"]: return .update
        case ["delete"]: return .destroy
        case ["read"]: return .read
        case ["delete", "create"], ["create", "delete"]: return .replace
        default: return nil
        }
    }

    /// Top-level scalar attributes only — the same simplification real plan
    /// text makes when it prints "(2 unchanged attributes hidden)" rather
    /// than walking into a nested block. A list or map attribute is shown as
    /// one compact value rather than diffed element by element, and its
    /// per-element `after_unknown` / `replace_paths` entries (themselves
    /// arrays, confirmed against `terraform_data.rotator`'s real plan) are
    /// not walked into either.
    private static func attributeDiffs(
        for change: TerraformPlanDocument.ResourceChangeEntry.Change
    ) -> [TerraformPlanSummary.AttributeDiff] {
        let before = change.before?.objectValue ?? [:]
        let after = change.after?.objectValue ?? [:]
        guard !(before.isEmpty && after.isEmpty) else { return [] }

        let forcedKeys = Set(
            (change.replacePaths ?? []).compactMap { path -> String? in
                guard case .string(let key)? = path.first else { return nil }
                return key
            }
        )

        var keys = Set(before.keys).union(after.keys)
        keys.remove("id") // noise: every resource's own id, never worth a diff row

        return keys.sorted().compactMap { key in
            let unknown = change.afterUnknown?.boolFlag(for: key) ?? false
            let beforeValue = before[key]
            let afterValue = after[key]
            guard unknown || beforeValue != afterValue else { return nil }
            let sensitive = (change.beforeSensitive?.boolFlag(for: key) ?? false)
                || (change.afterSensitive?.boolFlag(for: key) ?? false)
            return TerraformPlanSummary.AttributeDiff(
                key: key,
                before: beforeValue.map { sensitive ? "(sensitive value)" : $0.displayString },
                after: unknown
                    ? "(known after apply)"
                    : afterValue.map { sensitive ? "(sensitive value)" : $0.displayString },
                isSensitive: sensitive,
                isUnknown: unknown,
                forcesReplacement: forcedKeys.contains(key)
            )
        }
    }

    // MARK: - Plain-text fallback

    /// Wording confirmed against a real `terraform plan` run (Terraform
    /// 1.16): the per-resource `#` header, the moved-resource line, the
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
        guard log.contains("Plan:") || log.contains("No changes.") else { return [] }

        var plans: [TerraformPlanSummary] = []
        var segment = PlainTextSegment()

        for rawLine in log.split(separator: "\n") {
            let line = withoutColour(rawLine)
            if isNoChangesLine(line) {
                plans.append(segment.summary())
                segment = PlainTextSegment()
                continue
            }
            if let counts = planLineCounts(line) {
                plans.append(segment.summary(closingCounts: counts))
                segment = PlainTextSegment()
                continue
            }
            segment.consume(line)
        }
        // Headers with no closing line after them — an outputs-only plan
        // prints none, and neither does a plan cut off by a failing step.
        // Still what was matched; dropping it would hide real changes.
        if !segment.order.isEmpty {
            plans.append(segment.summary())
        }
        return plans
    }

    /// The line with its ANSI colour codes (`ESC [ … m`, and any other CSI
    /// sequence) removed. Returns the line untouched — no copy — when there is
    /// no escape in it, which is every line of a `-no-color` log.
    static func withoutColour(_ line: Substring) -> Substring {
        guard line.contains("\u{1B}") else { return line }
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
    /// destroy.` line, or `nil` when this is not one.
    private static func planLineCounts(
        _ line: Substring
    ) -> (add: Int, change: Int, destroy: Int)? {
        guard let start = line.range(of: "Plan: "), line.contains(" to destroy") else {
            return nil
        }
        var add = 0, change = 0, destroy = 0
        for part in line[start.upperBound...].split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count >= 3, let count = Int(words[0]) else { continue }
            switch words[2].trimmingCharacters(in: .punctuationCharacters) {
            case "add": add = count
            case "change": change = count
            case "destroy": destroy = count
            default: break
            }
        }
        return (add, change, destroy)
    }

    /// The headers seen since the last closing line.
    private struct PlainTextSegment {
        var toAdd = 0, toChange = 0, toDestroy = 0, toReplace = 0
        var byAddress: [String: TerraformPlanSummary.ResourceChange] = [:]
        var order: [String] = []

        private static let markers: [(String, TerraformPlanSummary.ResourceChange.Category)] = [
            (" will be created", .create),
            (" will be destroyed", .destroy),
            (" will be updated in-place", .update),
            (" must be replaced", .replace),
            (" will be read during apply", .read),
        ]

        mutating func consume(_ rawLine: Substring) {
            // Not `hasPrefix("# ")` on a trimmed line: GitHub's own raw log
            // prefixes *every* line with its own timestamp
            // (`2026-09-14T10:23:45.1234567Z   # aws_instance.web will be
            // created`), so anchoring at the start never matches anything —
            // this endpoint's line format is exactly why `extractJSONDocuments`
            // above already scans for its marker rather than assuming column
            // zero, and this fallback needs the same discipline.
            guard let hashRange = rawLine.range(of: "# ") else { return }
            let rest = rawLine[hashRange.upperBound...]

            if let range = rest.range(of: " has moved to ") {
                let address = String(rest[rest.startIndex..<range.lowerBound])
                if byAddress[address] == nil { order.append(address) }
                byAddress[address] = TerraformPlanSummary.ResourceChange(
                    address: address, type: TerraformPlanParser.inferredType(fromAddress: address),
                    category: .moved, movedFrom: nil, actionReason: nil, attributes: []
                )
                return
            }

            for (marker, category) in Self.markers {
                guard let range = rest.range(of: marker) else { continue }
                let address = String(rest[rest.startIndex..<range.lowerBound])
                if byAddress[address] == nil {
                    order.append(address)
                    switch category {
                    case .create: toAdd += 1
                    case .update: toChange += 1
                    case .replace: toReplace += 1
                    case .destroy: toDestroy += 1
                    case .read, .moved: break
                    }
                }
                byAddress[address] = TerraformPlanSummary.ResourceChange(
                    address: address, type: TerraformPlanParser.inferredType(fromAddress: address),
                    category: category, movedFrom: nil, actionReason: nil, attributes: []
                )
                return
            }
        }

        func summary(
            closingCounts: (add: Int, change: Int, destroy: Int)? = nil
        ) -> TerraformPlanSummary {
            let resources = order.compactMap { byAddress[$0] }
            // The headers are the evidence whenever there are any. A `Plan:`
            // line with none above it still says what it counted, and
            // drawing "no changes" over "Plan: 2 to add" is the one answer
            // that is certainly wrong. A replace is one add plus one destroy
            // on that line, so it is left in those two rather than guessed at.
            if resources.isEmpty, let counts = closingCounts,
               counts.add + counts.change + counts.destroy > 0 {
                return TerraformPlanSummary(
                    toAdd: counts.add, toChange: counts.change, toDestroy: counts.destroy,
                    unchangedCount: nil,
                    isNoOpPlan: false
                )
            }
            return TerraformPlanSummary(
                toAdd: toAdd, toChange: toChange, toReplace: toReplace, toDestroy: toDestroy,
                unchangedCount: nil,
                resources: resources,
                outputChanges: [],
                driftedAddresses: [],
                isNoOpPlan: toAdd == 0 && toChange == 0 && toReplace == 0
                    && toDestroy == 0 && resources.isEmpty
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
