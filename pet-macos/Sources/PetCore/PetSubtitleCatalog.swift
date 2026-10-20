import Foundation

public enum PetSubtitleCatalogError: Error, Equatable {
    case unavailable
    case invalid
}

/// The bundled subtitle table: one or two original lines per character and logical state.
///
/// The table is a native-layer resource, not a protocol field. Which state applies is
/// decided by the pose that is actually on screen, so no session content is ever read
/// here. The wording is original to this project; no upstream CrossPet line is reused.
public struct PetSubtitleCatalog: Sendable {
    /// Ordered logical state keys. `dwell` only lists the states that retire themselves;
    /// every other state stays until the pose changes or a higher priority preempts it.
    public let stateOrder: [String]
    /// Pose name -> logical state key. Poses are artwork names, states are the wording
    /// buckets; the table is exhaustive for the bundled catalog and normalised again by
    /// `stateKey(forPose:)` so a numbered variant never loses its line.
    public let poseStates: [String: String]
    /// States that hide themselves after this many seconds. Absent = stays on screen.
    public let dwell: [String: TimeInterval]
    /// States that no bundled pose can reach (kept so the wording table stays complete).
    public let unreachableStates: [String]
    public let minDwellSeconds: TimeInterval
    private let linesByRole: [String: [String: [String]]]
    private let roleIds: [String]

    public static let maximumLineCharacters = 120

    /// Loads the bundled table from `<bundle resources>/CrossPet/pet-lines.json`. A missing
    /// or malformed file yields `nil`: the pet then shows notices only instead of a
    /// half-loaded table.
    public static func bundled(in bundle: Bundle = .main) -> PetSubtitleCatalog? {
        guard let resources = bundle.resourceURL else { return nil }
        return try? PetSubtitleCatalog(
            directoryURL: resources.appendingPathComponent("CrossPet", isDirectory: true)
        )
    }

    public init(directoryURL: URL) throws {
        let url = directoryURL.appendingPathComponent("pet-lines.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url) else { throw PetSubtitleCatalogError.unavailable }
        try self.init(jsonData: data)
    }

    public init(jsonData: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              root["schemaVersion"] as? Int == 1,
              let stateOrder = root["stateOrder"] as? [String],
              !stateOrder.isEmpty,
              Set(stateOrder).count == stateOrder.count,
              let poseStates = root["poseStates"] as? [String: String],
              let rawDwell = root["dwellSeconds"] as? [String: Any],
              let rawCharacters = root["characters"] as? [String: Any],
              stateOrder.allSatisfy({ rawDwell[$0] != nil }),
              Set(rawDwell.keys) == Set(stateOrder),
              poseStates.values.allSatisfy({ stateOrder.contains($0) }) else {
            throw PetSubtitleCatalogError.invalid
        }

        var dwell: [String: TimeInterval] = [:]
        for (state, raw) in rawDwell {
            if raw is NSNull { continue }
            guard let number = raw as? NSNumber else { throw PetSubtitleCatalogError.invalid }
            let seconds = number.doubleValue
            guard seconds.isFinite, seconds > 0, seconds <= 600 else { throw PetSubtitleCatalogError.invalid }
            dwell[state] = seconds
        }

        let roles = PetRole.builtIns.map(\.id)
        guard Set(rawCharacters.keys) == Set(roles) else { throw PetSubtitleCatalogError.invalid }

        var parsed: [String: [String: [String]]] = [:]
        for roleId in roles {
            guard let states = rawCharacters[roleId] as? [String: Any],
                  Set(states.keys) == Set(stateOrder) else { throw PetSubtitleCatalogError.invalid }
            var byState: [String: [String]] = [:]
            for state in stateOrder {
                guard let rawLines = states[state] as? [String], !rawLines.isEmpty, rawLines.count <= 8 else {
                    throw PetSubtitleCatalogError.invalid
                }
                let cleaned = rawLines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard cleaned.allSatisfy({ !$0.isEmpty && $0.count <= Self.maximumLineCharacters }),
                      Set(cleaned).count == cleaned.count else {
                    throw PetSubtitleCatalogError.invalid
                }
                byState[state] = cleaned
            }
            parsed[roleId] = byState
        }

        let rawUnreachable = root["unreachableStates"] as? [String] ?? []
        guard rawUnreachable.allSatisfy({ stateOrder.contains($0) }) else {
            throw PetSubtitleCatalogError.invalid
        }

        let rawMinDwell = (root["minDwellSeconds"] as? NSNumber)?.doubleValue ?? 2.5
        guard rawMinDwell.isFinite, rawMinDwell >= 0, rawMinDwell <= 60 else {
            throw PetSubtitleCatalogError.invalid
        }

        self.stateOrder = stateOrder
        self.poseStates = poseStates
        self.dwell = dwell
        self.unreachableStates = rawUnreachable
        self.minDwellSeconds = rawMinDwell
        self.linesByRole = parsed
        self.roleIds = roles
    }

    public var roles: [String] { roleIds }

    /// Normalises an artwork pose name to a logical state key.
    ///
    /// Exact table entry wins; then a numbered variant (`thinking-2`, `idle-3`,
    /// `sleeping-2`) drops its suffix; an unknown pose falls back to `idle`, and a
    /// catalog without `idle` reports `nil` so the caller shows no invented line.
    public func stateKey(forPose pose: String) -> String? {
        if let direct = poseStates[pose] { return direct }
        if let dash = pose.lastIndex(of: "-") {
            let base = String(pose[pose.startIndex..<dash])
            if base != pose, let stripped = poseStates[base] { return stripped }
        }
        return poseStates["idle"]
    }

    public func lines(roleId: String, state: String) -> [String] {
        linesByRole[roleId]?[state] ?? []
    }

    public func hasLines(roleId: String, state: String) -> Bool {
        !lines(roleId: roleId, state: state).isEmpty
    }

    /// Seconds this state stays on screen; `nil` means it persists until the pose changes.
    public func dwellSeconds(forState state: String) -> TimeInterval? {
        dwell[state]
    }
}
