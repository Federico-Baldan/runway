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
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
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

    /// Whether `key` is flagged, in whichever of the shapes above this value
    /// actually arrived in. A bare `true` / `false` answers for every key at
    /// once — the shape a root-module *output*'s `after_unknown` uses, since
    /// an output has no attributes of its own to distinguish between.
    func boolFlag(for key: String) -> Bool {
        switch self {
        case .bool(let value): return value
        case .object(let dict): return dict[key]?.boolValue ?? false
        default: return false
        }
    }

    /// Compact, human-readable rendering for the diff view — Terraform's own
    /// display conventions (an unquoted string, `true`/`false`, a `{ … }`
    /// summary for anything nested), not a JSON re-serialization.
    var displayString: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(value)) : String(value)
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

            enum CodingKeys: String, CodingKey {
                case actions, before, after
                case afterUnknown = "after_unknown"
                case beforeSensitive = "before_sensitive"
                case afterSensitive = "after_sensitive"
                case replacePaths = "replace_paths"
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

        enum CodingKeys: String, CodingKey {
            case address, type, change
            case previousAddress = "previous_address"
            case actionReason = "action_reason"
        }
    }

    let resourceChanges: [ResourceChangeEntry]
    /// Absent whenever nothing drifted, which is nearly always — decoded as
    /// an optional rather than defaulted to `[]` so "no key" and "empty
    /// array" read the same way to every caller.
    let resourceDrift: [ResourceChangeEntry]?
    let outputChanges: [String: ResourceChangeEntry.Change]?

    enum CodingKeys: String, CodingKey {
        case resourceChanges = "resource_changes"
        case resourceDrift = "resource_drift"
        case outputChanges = "output_changes"
    }
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
    /// Which plan this is, when one job printed more than one — a job that
    /// plans `staging` and then `staging-dr` in two steps has two of these,
    /// and without a name they are two anonymous rows of counts. `nil` for
    /// the ordinary one-plan job, whose row above already names it. Set by
    /// `TerraformPlanParser.reconcile`, never by the parse itself: the log
    /// does not say which step printed what, the jobs API does.
    public var label: String?

    public init(
        toAdd: Int = 0, toChange: Int = 0, toReplace: Int = 0, toDestroy: Int = 0,
        unchangedCount: Int? = nil,
        resources: [ResourceChange] = [],
        outputChanges: [OutputChange] = [],
        driftedAddresses: [String] = [],
        isNoOpPlan: Bool = false,
        label: String? = nil
    ) {
        self.toAdd = toAdd
        self.toChange = toChange
        self.toReplace = toReplace
        self.toDestroy = toDestroy
        self.unchangedCount = unchangedCount
        self.resources = resources
        self.outputChanges = outputChanges
        self.driftedAddresses = driftedAddresses
        self.isNoOpPlan = isNoOpPlan
        self.label = label
    }
}
