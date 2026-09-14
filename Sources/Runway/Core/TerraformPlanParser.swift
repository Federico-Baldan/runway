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
    static func parse(log: String) -> TerraformPlanSummary? {
        if let document = extractJSONDocument(from: log) {
            return summarize(document)
        }
        return parsePlainText(log)
    }

    // MARK: - JSON path

    /// Scans every line for one that decodes as a plan document, rather than
    /// trying to isolate the Terraform step's own slice of the log.
    ///
    /// GitHub's per-line timestamp prefix on raw job logs is not part of this
    /// endpoint's documented contract, so nothing here assumes its width or
    /// format — this only assumes Go's default JSON encoder never puts a bare
    /// newline inside the object it prints, which is what keeps a
    /// `terraform show -json` invocation to exactly one line regardless of
    /// what precedes it on that line.
    static func extractJSONDocument(from log: String) -> TerraformPlanDocument? {
        let decoder = JSONDecoder()
        for rawLine in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let brace = rawLine.firstIndex(of: "{") else { continue }
            let candidate = rawLine[brace...]
            guard candidate.contains("\"resource_changes\"") else { continue }
            guard let data = candidate.data(using: .utf8) else { continue }
            if let document = try? decoder.decode(TerraformPlanDocument.self, from: data) {
                return document
            }
        }
        return nil
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
    /// Two things this does *not* do, both on purpose, both found by review
    /// rather than assumed away:
    ///
    ///  * It never treats "No changes." as authoritative just because the
    ///    substring appears somewhere in the log. A job that loops
    ///    `terraform plan` over several directories can have one directory
    ///    print exactly that sentence while another, later in the same log,
    ///    prints real destroys — and a `contains` check that stops at the
    ///    first would draw a calm green line over a job about to tear
    ///    something down. The counts below come only from what was actually
    ///    matched; "no changes" is a conclusion this draws at the end, from
    ///    the same evidence a real change would have left, never a shortcut
    ///    taken from one sentence in the middle of the log.
    ///  * It de-duplicates by address. A workflow that both runs the plan and
    ///    then echoes it again for a PR comment produces every header line
    ///    twice, which would otherwise double every count and hand `ForEach`
    ///    the same id twice over — undefined behaviour in SwiftUI, not just a
    ///    cosmetic one.
    static func parsePlainText(_ log: String) -> TerraformPlanSummary? {
        guard log.contains("Plan:") || log.contains("No changes.") else { return nil }

        var toAdd = 0, toChange = 0, toDestroy = 0, toReplace = 0
        var byAddress: [String: TerraformPlanSummary.ResourceChange] = [:]
        var order: [String] = []

        let markers: [(String, TerraformPlanSummary.ResourceChange.Category)] = [
            (" will be created", .create),
            (" will be destroyed", .destroy),
            (" will be updated in-place", .update),
            (" must be replaced", .replace),
            (" will be read during apply", .read),
        ]

        for rawLine in log.split(separator: "\n") {
            // Not `hasPrefix("# ")` on a trimmed line: GitHub's own raw log
            // prefixes *every* line with its own timestamp
            // (`2026-09-14T10:23:45.1234567Z   # aws_instance.web will be
            // created`), so anchoring at the start never matches anything —
            // this endpoint's line format is exactly why `extractJSONDocument`
            // above already scans for its marker rather than assuming column
            // zero, and this fallback needs the same discipline.
            guard let hashRange = rawLine.range(of: "# ") else { continue }
            let rest = rawLine[hashRange.upperBound...]

            if let range = rest.range(of: " has moved to ") {
                let address = String(rest[rest.startIndex..<range.lowerBound])
                if byAddress[address] == nil { order.append(address) }
                byAddress[address] = TerraformPlanSummary.ResourceChange(
                    address: address, type: inferredType(fromAddress: address),
                    category: .moved, movedFrom: nil, actionReason: nil, attributes: []
                )
                continue
            }

            for (marker, category) in markers {
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
                    address: address, type: inferredType(fromAddress: address),
                    category: category, movedFrom: nil, actionReason: nil, attributes: []
                )
                break
            }
        }

        let resources = order.compactMap { byAddress[$0] }

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

    /// Best-effort resource type for a plain-text address, since there is no
    /// separate `type` field the way the JSON path has one: the
    /// second-to-last dot-separated component before any `[index]` —
    /// `aws_instance` out of `aws_instance.web[2]`, `aws_subnet` out of
    /// `module.vpc.aws_subnet.private`. Falls back to the full address if
    /// that shape does not hold, rather than guessing further.
    private static func inferredType(fromAddress address: String) -> String {
        var trimmed = Substring(address)
        if let bracket = trimmed.firstIndex(of: "[") { trimmed = trimmed[..<bracket] }
        let parts = trimmed.split(separator: ".")
        guard parts.count >= 2 else { return address }
        return String(parts[parts.count - 2])
    }
}
