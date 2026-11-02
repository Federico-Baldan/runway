import Foundation

// MARK: - Terraform's own JSON

/// A JSON value of unknown shape, for the handful of `terraform show -json`
/// fields whose type depends on what they describe rather than being fixed
/// by the schema.
///
/// `before` / `after` are whatever the resource's own attributes are, and
/// `after_unknown` / `before_sensitive` / `after_sensitive` are, confirmed
/// against a real plan: sometimes a bare `false`, sometimes `{}`, sometimes a
/// map of attribute name to flag, and — for a list-typed attribute like
/// `triggers_replace` — an array of per-element flags. One decodable type
/// that tries every shape in turn is simpler and safer than several that each
/// assume a shape the field does not always have.
enum JSONValue: Decodable, Sendable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        // Strings first: they are most of a plan's leaves, and every shape
        // tried before the right one costs a thrown `DecodingError`.
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .null
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    // MARK: Masks

    // `after_unknown`, `before_sensitive` and `after_sensitive` are *masks*:
    // the same shape as the value they describe, with `true` where the flag
    // applies and — in real plans — `false`, `{}` or nothing where it does
    // not. A bare `true` anywhere means "everything beneath this point".
    // Reading them one level deep was how a nested secret reached the screen:
    // `after_sensitive` of `{"input": {"password": true}}` says nothing about
    // `input` as a whole, only about a key inside it.

    static let sensitivePlaceholder = "(sensitive value)"
    static let unknownPlaceholder = "(known after apply)"

    /// Whether this mask flags anything at all — a `true` at this point or
    /// anywhere beneath it.
    var flagsAnything: Bool {
        switch self {
        case .bool(let value): return value
        case .object(let dict): return dict.values.contains { $0.flagsAnything }
        case .array(let items): return items.contains { $0.flagsAnything }
        default: return false
        }
    }

    /// The part of this mask that covers `key`. A bare `true` covers every
    /// key beneath it; anything that is not an object says nothing.
    func maskChild(_ key: String) -> JSONValue? {
        switch self {
        case .bool(true): return self
        case .object(let dict): return dict[key]
        default: return nil
        }
    }

    /// The part of this mask that covers element `index` of an array.
    func maskChild(at index: Int) -> JSONValue? {
        switch self {
        case .bool(true): return self
        case .array(let items): return items.indices.contains(index) ? items[index] : nil
        default: return nil
        }
    }

    /// Two masks merged so that anything either one flags stays flagged — for
    /// a value whose `before` side and `after` side each have a mask and
    /// neither side should show what the other would hide.
    static func union(_ first: JSONValue?, _ second: JSONValue?) -> JSONValue? {
        guard let first else { return second }
        guard let second else { return first }
        switch (first, second) {
        case (.bool(true), _), (_, .bool(true)):
            return .bool(true)
        case (.bool(false), _):
            return second
        case (_, .bool(false)):
            // A bare `false` flags nothing, and Terraform writes exactly that
            // for the side a change does not have: `after_sensitive: false` on
            // every delete, `before_sensitive: false` on every create. Merging
            // it with the other side's mask must leave that mask as it was —
            // treating it as "unlike" hid every attribute of a destroyed
            // resource to protect the one that was actually secret.
            return first
        case (.object(let left), .object(let right)):
            var merged = left
            for (key, value) in right {
                merged[key] = union(left[key], value)
            }
            return .object(merged)
        case (.array(let left), .array(let right)):
            let count = max(left.count, right.count)
            var merged: [JSONValue] = []
            merged.reserveCapacity(count)
            for index in 0..<count {
                let combined = union(
                    index < left.count ? left[index] : nil,
                    index < right.count ? right[index] : nil
                )
                merged.append(combined ?? .bool(false))
            }
            return .array(merged)
        default:
            // Two masks of different kinds — an attribute that was a map and
            // is now a list, say — cannot be laid over each other. Keeping
            // either one alone would leave the other side's flags unread, so
            // anything flagged on either side hides the whole value.
            return (first.flagsAnything || second.flagsAnything) ? .bool(true) : first
        }
    }

    /// `value` with every flagged leaf replaced by what Terraform itself
    /// prints there: a sensitive one by "(sensitive value)", an unknown one by
    /// "(known after apply)". Sensitive wins when both apply, the same way
    /// Terraform's own output does, because an unknown sensitive value must
    /// not turn into a place to leak the one it becomes.
    ///
    /// An unknown leaf is *absent* from `after` — that is what unknown means
    /// there — so keys and elements that exist only in the mask are put back,
    /// or `(known after apply)` would never be drawn for the attributes that
    /// are most often exactly that.
    ///
    /// `nil` when there is nothing to show: no value and no unknown flag.
    static func masked(
        _ value: JSONValue?,
        sensitive: JSONValue?,
        unknown: JSONValue?
    ) -> JSONValue? {
        if sensitive?.boolValue == true {
            // Nothing to hide where there is no value: the side a change does
            // not have (a create's `before`, a delete's `after`) is absent, and
            // a mask that covers both sides must not invent a value there. An
            // unknown one is a value, and its placeholder is still the
            // sensitive one.
            // (A JSON `null` at the top of a side already arrives here as
            // `nil`: `decodeIfPresent` does not tell it from a missing key.)
            let hasValue = value != nil || (unknown?.flagsAnything ?? false)
            return hasValue ? .string(sensitivePlaceholder) : nil
        }
        if unknown?.boolValue == true { return .string(unknownPlaceholder) }

        let hasSensitive = sensitive?.flagsAnything ?? false
        let hasUnknown = unknown?.flagsAnything ?? false
        guard hasSensitive || hasUnknown else { return value }

        var base = value
        if base == nil, hasUnknown, let unknown {
            switch unknown {
            case .object: base = .object([:])
            case .array: base = .array([])
            default: break
            }
        }

        // A mask is meant to have the shape of its value. One that flags
        // something but does not — a list mask over a map, or anything but a
        // bare `true` over a scalar — cannot be followed down, and following
        // it as far as it goes would show the rest unmasked. A secret shown
        // is worse than a value hidden, so the whole value goes.
        func misfits(_ mask: JSONValue?, expectingObject: Bool) -> Bool {
            guard let mask, mask.flagsAnything else { return false }
            switch mask {
            case .object: return !expectingObject
            case .array: return expectingObject
            default: return true
            }
        }

        switch base {
        case .object(let dict)?:
            if misfits(sensitive, expectingObject: true) { return .string(sensitivePlaceholder) }
            var keys = Set(dict.keys)
            if let unknown, case .object(let flags) = unknown { keys.formUnion(flags.keys) }
            var result: [String: JSONValue] = [:]
            for key in keys {
                if let child = masked(
                    dict[key],
                    sensitive: sensitive?.maskChild(key),
                    unknown: unknown?.maskChild(key)
                ) {
                    result[key] = child
                }
            }
            return .object(result)
        case .array(let items)?:
            if misfits(sensitive, expectingObject: false) { return .string(sensitivePlaceholder) }
            var count = items.count
            if let unknown, case .array(let flags) = unknown { count = max(count, flags.count) }
            var result: [JSONValue] = []
            result.reserveCapacity(count)
            for index in 0..<count {
                let child = masked(
                    index < items.count ? items[index] : nil,
                    sensitive: sensitive?.maskChild(at: index),
                    unknown: unknown?.maskChild(at: index)
                )
                result.append(child ?? .null)
            }
            return .array(result)
        default:
            // A scalar (or nothing) under a mask that flags something below
            // it: there is nothing to descend into, so what is there is
            // hidden rather than shown.
            if base != nil, hasSensitive { return .string(sensitivePlaceholder) }
            return base
        }
    }

    /// Compact, human-readable rendering for the diff view — Terraform's own
    /// display conventions (an unquoted string, `true`/`false`, a `{ … }`
    /// summary for anything nested), not a JSON re-serialization.
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            // `Int(value)` traps outside `Int`'s range, and Terraform's numbers
            // are arbitrary precision: a `1e30` attribute is a valid plan and
            // would have taken the whole app down with it.
            if value.truncatingRemainder(dividingBy: 1) == 0, abs(value) < 1e15 {
                return String(Int(value))
            }
            return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .array(let items):
            return "[" + items.map(\.displayString).joined(separator: ", ") + "]"
        case .object(let dict):
            let pairs = dict.sorted { $0.key < $1.key }
                .map { "\($0.key) = \($0.value.displayString)" }
            return "{ " + pairs.joined(separator: ", ") + " }"
        }
    }
}

/// The document `terraform show -json <planfile>` prints — one line of
/// compact JSON, decoded for exactly the fields `TerraformPlanParser` turns
/// into a `TerraformPlanSummary`.
///
/// Every other field HashiCorp's reference documents (`configuration`,
/// `prior_state`, `relevant_attributes`, `planned_values`, …) is left
/// undecoded on purpose: `JSONDecoder` ignores keys a type does not ask for,
/// and declaring fields nothing here reads would just be more of HashiCorp's
/// schema to keep in sync for no benefit.
struct TerraformPlanDocument: Decodable, Sendable {
    struct ResourceChangeEntry: Decodable, Sendable {
        struct Change: Decodable, Sendable {
            let actions: [String]
            let before: JSONValue?
            let after: JSONValue?
            let afterUnknown: JSONValue?
            let beforeSensitive: JSONValue?
            let afterSensitive: JSONValue?
            /// Which changed top-level attribute(s) forced a replace, e.g.
            /// `[["triggers_replace"]]`. Only the first element of each path
            /// is read — see `TerraformPlanParser`'s scope note on nested
            /// attributes.
            let replacePaths: [[JSONValue]]?
            /// Present only when the object is being brought under
            /// management by an `import` block — `{"id": "…"}`. The shape
            /// inside is, by HashiCorp's own note, subject to change, so only
            /// its presence is read.
            let importing: JSONValue?

            enum CodingKeys: String, CodingKey {
                case actions, before, after, importing
                case afterUnknown = "after_unknown"
                case beforeSensitive = "before_sensitive"
                case afterSensitive = "after_sensitive"
                case replacePaths = "replace_paths"
            }

            /// A no-op's values are never read — nothing is drawn for a
            /// resource the plan leaves alone — and in a real plan they are
            /// most of the document: every untouched resource carries its
            /// whole `before` and `after` trees, and `JSONValue` pays for
            /// each node it decodes. Skipping them is most of the difference
            /// between decoding a large state's plan in a fraction of a
            /// second and in several.
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                actions = try container.decode([String].self, forKey: .actions)
                importing = try container.decodeIfPresent(JSONValue.self, forKey: .importing)
                guard actions != ["no-op"] else {
                    before = nil
                    after = nil
                    afterUnknown = nil
                    beforeSensitive = nil
                    afterSensitive = nil
                    replacePaths = nil
                    return
                }
                before = try container.decodeIfPresent(JSONValue.self, forKey: .before)
                after = try container.decodeIfPresent(JSONValue.self, forKey: .after)
                afterUnknown = try container.decodeIfPresent(JSONValue.self, forKey: .afterUnknown)
                beforeSensitive = try container.decodeIfPresent(
                    JSONValue.self, forKey: .beforeSensitive
                )
                afterSensitive = try container.decodeIfPresent(
                    JSONValue.self, forKey: .afterSensitive
                )
                replacePaths = try container.decodeIfPresent(
                    [[JSONValue]].self, forKey: .replacePaths
                )
            }
        }

        let address: String
        /// Set when a `moved` block retargeted this resource — present
        /// alongside `["no-op"]` for a pure rename, or alongside a real
        /// change when a move and an update land in the same plan.
        let previousAddress: String?
        let type: String
        let change: Change
        /// Why Terraform chose this action —
        /// `"replace_because_cannot_update"`,
        /// `"delete_because_no_resource_config"` — surfaced as a tooltip,
        /// never parsed. Absent more often than not, which is the normal
        /// case for this field, not a decoding gap.
        let actionReason: String?
        /// Present only for a deposed object — one a failed replace left
        /// behind. It shares its address with the live instance, so the pair
        /// is only unique together; the value itself is opaque.
        let deposed: String?

        enum CodingKeys: String, CodingKey {
            case address, type, change, deposed
            case previousAddress = "previous_address"
            case actionReason = "action_reason"
        }
    }

    /// `resource_drift` entries share the shape above, but only the address
    /// is read — decoding every drifted resource's full values to throw them
    /// away would just be cost.
    struct DriftEntry: Decodable, Sendable {
        let address: String
    }

    /// `"1.2"`-style. HashiCorp's rule for readers: accept any minor of a
    /// major you understand, reject a major you do not.
    let formatVersion: String?
    /// Planning failed. HashiCorp's own flag — an errored plan is never
    /// applyable, and whatever it lists is only what was planned before the
    /// failure.
    let errored: Bool?
    /// Whether applying this plan would leave the real infrastructure
    /// matching the configuration. `false` means another plan/apply round is
    /// needed first. *Not* `applyable`: a plan with nothing to do is
    /// `applyable: false` and perfectly fine, which is why that field is not
    /// read at all.
    let complete: Bool?
    /// Whether anything was deferred to a later round. Only emptiness is
    /// read; an entry carries a whole resource change.
    let hasDeferredChanges: Bool
    /// How many provider actions the plan will invoke. An action changes
    /// nothing in the state, so a plan that only invokes one touches no
    /// resource — and was drawn as a green "no changes".
    let actionInvocations: Int
    /// Absent whenever the plan changes no resource — the key is omitted
    /// rather than written as `[]` — so an outputs-only plan is a plan with
    /// no `resource_changes`, not a document that fails to decode.
    let resourceChanges: [ResourceChangeEntry]
    /// Absent whenever nothing drifted, which is nearly always — decoded as
    /// an optional rather than defaulted to `[]` so "no key" and "empty
    /// array" read the same way to every caller.
    let resourceDrift: [DriftEntry]?
    let outputChanges: [String: ResourceChangeEntry.Change]?

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case errored, complete
        case deferredChanges = "deferred_changes"
        case deferredActionInvocations = "deferred_action_invocations"
        case actionInvocations = "action_invocations"
        case resourceChanges = "resource_changes"
        case resourceDrift = "resource_drift"
        case outputChanges = "output_changes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decodeIfPresent(String.self, forKey: .formatVersion)
        errored = try container.decodeIfPresent(Bool.self, forKey: .errored)
        complete = try container.decodeIfPresent(Bool.self, forKey: .complete)
        /// How many entries an array holds, without decoding them: each is a
        /// whole resource change, and only the count is wanted.
        struct Counted: Decodable {
            init(from decoder: Decoder) throws {}
        }
        /// A key that is not an array at all counts as none: a count must not
        /// be the reason a whole plan fails to decode.
        func entries(_ key: CodingKeys) -> Int {
            (try? container.decodeIfPresent([Counted].self, forKey: key))?.count ?? 0
        }
        hasDeferredChanges = entries(.deferredChanges) > 0
            || entries(.deferredActionInvocations) > 0
        actionInvocations = entries(.actionInvocations)
        resourceChanges = try container.decodeIfPresent(
            [ResourceChangeEntry].self, forKey: .resourceChanges
        ) ?? []
        resourceDrift = try container.decodeIfPresent([DriftEntry].self, forKey: .resourceDrift)
        outputChanges = try container.decodeIfPresent(
            [String: ResourceChangeEntry.Change].self, forKey: .outputChanges
        )
    }

    /// Whether this is a major version of the format this code reads.
    /// HashiCorp: minor bumps only add fields, a major bump is a break, and a
    /// reader should refuse what it does not know rather than draw it wrong.
    ///
    /// Major `0` is the form `terraform show -json` had before 1.1 ("0.1",
    /// "0.2"). It carries the same `resource_changes` and `change` this reads,
    /// and a pipeline still on such a Terraform was read before this check
    /// existed, so it keeps being read.
    var isSupportedFormat: Bool {
        guard let version = formatVersion,
              let major = version.split(separator: ".").first.flatMap({ Int($0) })
        else { return false }
        return major == 0 || major == 1
    }
}

// MARK: - Terraform's machine-readable UI (`plan -json`)

/// One line of `terraform plan -json`'s stream — a different format from the
/// plan document above, documented and versioned separately. Only the
/// message types a plan summary needs are decoded: `planned_change` (one per
/// resource), `change_summary` (the counts), `outputs`, and `diagnostic`
/// (whether anything failed).
///
/// Every field is optional on purpose. The stream is one decoder call per
/// line, and a message that fails to decode is skipped — which must never
/// take a whole plan with it because one unrelated message grew a field.
struct TerraformUIMessage: Decodable, Sendable {
    struct Resource: Decodable, Sendable {
        let addr: String
        let resourceType: String?

        enum CodingKeys: String, CodingKey {
            case addr
            case resourceType = "resource_type"
        }
    }

    struct Change: Decodable, Sendable {
        let resource: Resource
        /// Set for a configuration-driven move.
        let previousResource: Resource?
        /// `noop`, `create`, `read`, `update`, `replace`, `delete`, `move`,
        /// `import`, or `remove` (a resource forgotten, not destroyed).
        let action: String
        let reason: String?

        enum CodingKeys: String, CodingKey {
            case resource, action, reason
            case previousResource = "previous_resource"
        }
    }

    struct Summary: Decodable, Sendable {
        /// Includes the creates inside a replace.
        let add: Int?
        let change: Int?
        /// Includes the destroys inside a replace. Does *not* count forgets.
        let remove: Int?
        /// `plan`, `apply` or `destroy`.
        let operation: String?
        let imported: Int?
        /// OpenTofu's own count of forgotten objects. Terraform has none.
        let forgotten: Int?
        let invoked: Int?

        enum CodingKeys: String, CodingKey {
            case add, change, remove, operation
            case imported = "import"
            case forgotten = "forget"
            case invoked = "action_invocation"
        }
    }

    struct Output: Decodable, Sendable {
        let action: String?
    }

    struct Diagnostic: Decodable, Sendable {
        let severity: String?
    }

    let type: String
    let change: Change?
    let changes: Summary?
    let outputs: [String: Output]?
    let diagnostic: Diagnostic?
}

// MARK: - The distilled summary Runway actually draws

/// A Terraform plan's shape, reduced to what the notch draws.
///
/// Deliberately smaller than what `terraform show -json` reports: attribute
/// diffs cover top-level scalar values only (see `AttributeDiff`), and a
/// resource entirely unaffected by the plan is folded into `unchangedCount`
/// rather than carried as a value nobody would look at.
///
/// Stamped onto a `Job` by `RunMonitor`, not decoded — built from the job's
/// raw log the same way `WorkflowRun.deployTarget` is derived rather than
/// sent by GitHub. See `TerraformPlanParser`.
public struct TerraformPlanSummary: Sendable, Equatable, Hashable {
    public struct AttributeDiff: Sendable, Equatable, Hashable {
        public let key: String
        public let before: String?
        public let after: String?
        public let isSensitive: Bool
        public let isUnknown: Bool
        public let forcesReplacement: Bool

        public init(
            key: String, before: String?, after: String?,
            isSensitive: Bool, isUnknown: Bool, forcesReplacement: Bool
        ) {
            self.key = key
            self.before = before
            self.after = after
            self.isSensitive = isSensitive
            self.isUnknown = isUnknown
            self.forcesReplacement = forcesReplacement
        }
    }

    public struct ResourceChange: Sendable, Equatable, Hashable, Identifiable {
        public enum Category: String, Sendable {
            case create, update, replace, destroy, read, moved
            /// Brought under management by an `import` block with nothing
            /// else changing. An import that also updates the object is an
            /// `.update` — the import itself is counted in `toImport`.
            case imported
            /// Dropped from state without being destroyed — a `removed`
            /// block with `destroy = false`. Nothing is deleted, but
            /// Terraform stops managing the object, which is why it is not
            /// drawn as a silent no-op.
            case forget
        }

        public var id: String { address }
        public let address: String
        public let type: String
        public let category: Category
        /// Set only when this resource also moved — a `moved` block is not
        /// mutually exclusive with a real change, so this rides alongside
        /// `category` rather than replacing it.
        public let movedFrom: String?
        public let actionReason: String?
        public let attributes: [AttributeDiff]

        public init(
            address: String, type: String, category: Category,
            movedFrom: String?, actionReason: String?, attributes: [AttributeDiff]
        ) {
            self.address = address
            self.type = type
            self.category = category
            self.movedFrom = movedFrom
            self.actionReason = actionReason
            self.attributes = attributes
        }
    }

    public struct OutputChange: Sendable, Equatable, Hashable {
        public let name: String
        public let before: String?
        public let after: String?
        public let isUnknown: Bool

        public init(name: String, before: String?, after: String?, isUnknown: Bool) {
            self.name = name
            self.before = before
            self.after = after
            self.isUnknown = isUnknown
        }
    }

    public let toAdd: Int
    public let toChange: Int
    public let toReplace: Int
    public let toDestroy: Int
    /// Objects an `import` block brings under management.
    public let toImport: Int
    /// Objects dropped from state without being destroyed.
    public let toForget: Int
    /// Provider actions the plan will run. They change no resource, so a plan
    /// with only these has none of the counts above and is still not a plan
    /// that does nothing.
    public let toInvoke: Int
    /// Resources the plan does not touch. Only ever accurate from the JSON
    /// path — Terraform's plain-text output omits unchanged resources
    /// entirely rather than counting them, so the text fallback leaves this
    /// `nil` instead of asserting a zero it cannot back up.
    public let unchangedCount: Int?
    /// In plan order: `.moved`, plus everything that is not a silent no-op.
    public let resources: [ResourceChange]
    public let outputChanges: [OutputChange]
    /// Addresses Terraform found changed outside itself since the last
    /// apply — the banner, not the full diff.
    public let driftedAddresses: [String]
    public let isNoOpPlan: Bool
    /// Terraform said planning failed. The counts and rows are then only what
    /// was planned before the failure, so a plan like this is never drawn as
    /// a clean "no changes" however empty it is.
    public let isErrored: Bool
    /// Terraform said applying this plan will not finish the job — another
    /// plan is needed first, because something was deferred or `-target`
    /// narrowed the run. Same rule as above: never a clean "no changes".
    public let isPartial: Bool
    /// Which plan this is, when one job printed more than one — a job that
    /// plans `staging` and then `staging-dr` in two steps has two of these,
    /// and without a name they are two anonymous rows of counts. `nil` for
    /// the ordinary one-plan job, whose row above already names it. Set by
    /// `TerraformPlanParser.reconcile`, never by the parse itself: the log
    /// does not say which step printed what, the jobs API does.
    public var label: String?

    public init(
        toAdd: Int = 0, toChange: Int = 0, toReplace: Int = 0, toDestroy: Int = 0,
        toImport: Int = 0, toForget: Int = 0, toInvoke: Int = 0,
        unchangedCount: Int? = nil,
        resources: [ResourceChange] = [],
        outputChanges: [OutputChange] = [],
        driftedAddresses: [String] = [],
        isNoOpPlan: Bool = false,
        isErrored: Bool = false,
        isPartial: Bool = false,
        label: String? = nil
    ) {
        self.toAdd = toAdd
        self.toChange = toChange
        self.toReplace = toReplace
        self.toDestroy = toDestroy
        self.toImport = toImport
        self.toForget = toForget
        self.toInvoke = toInvoke
        self.unchangedCount = unchangedCount
        self.resources = resources
        self.outputChanges = outputChanges
        self.driftedAddresses = driftedAddresses
        self.isNoOpPlan = isNoOpPlan
        self.isErrored = isErrored
        self.isPartial = isPartial
        self.label = label
    }
}
