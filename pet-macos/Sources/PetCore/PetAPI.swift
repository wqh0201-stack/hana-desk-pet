import CoreFoundation
import Foundation

public struct PetAPI: Sendable {
    private let store: PetStateStore

    public init(store: PetStateStore) {
        self.store = store
    }

    public func handle(_ request: PetHTTPRequest) -> PetHTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/v3/hello"):
            guard request.body.isEmpty else { return json(400, ["error": "invalid_request"]) }
            return json(200, ["service": "hana-desktop-pet", "protocolVersion": 3])
        case ("GET", "/v3/selection"):
            guard request.body.isEmpty else { return json(400, ["error": "invalid_request"]) }
            return json(200, selectionObject(store.currentSelection()))
        case ("POST", "/v3/snapshot"):
            guard hasJSONContentType(request) else { return json(415, ["error": "json_required"]) }
            do {
                let snapshot = try decodeSnapshot(request.body)
                switch store.ingest(snapshot) {
                case .accepted:
                    return json(200, ["schemaVersion": 3, "accepted": true])
                case .stale:
                    return json(409, ["schemaVersion": 3, "accepted": false])
                }
            } catch {
                return json(400, ["error": "invalid_snapshot"])
            }
        case ("POST", "/v3/selection"):
            guard hasJSONContentType(request) else { return json(415, ["error": "json_required"]) }
            do {
                let value = try object(
                    request.body,
                    allowed: ["schemaVersion", "characterId", "expectedRevision", "updatedAt"],
                    required: ["schemaVersion", "characterId", "expectedRevision", "updatedAt"]
                )
                guard integer(value["schemaVersion"]) == 3,
                      let characterId = try requiredText(value["characterId"], limit: 48),
                      validRoleID(characterId),
                      let expectedRevision = integer(value["expectedRevision"]),
                      let updatedAt = integer(value["updatedAt"]) else {
                    return json(400, ["error": "invalid_selection"])
                }
                switch store.writeRemoteSelection(
                    characterId: characterId,
                    expectedRevision: expectedRevision,
                    updatedAt: updatedAt
                ) {
                case .updated(let selection):
                    return json(200, ["selection": selectionObject(selection)])
                case .conflict(let selection):
                    return json(409, ["selection": selectionObject(selection)])
                case .unknownRole:
                    return json(400, ["error": "unknown_character"])
                }
            } catch {
                return json(400, ["error": "invalid_selection"])
            }
        case (_, "/v3/hello"), (_, "/v3/selection"), (_, "/v3/snapshot"):
            return json(405, ["error": "method_not_allowed"])
        default:
            return json(404, ["error": "not_found"])
        }
    }

    private func decodeSnapshot(_ body: Data) throws -> PetSnapshotDTO {
        let value = try object(
            body,
            allowed: ["schemaVersion", "revision", "characters", "activity"],
            required: ["schemaVersion", "revision", "characters", "activity"]
        )
        guard integer(value["schemaVersion"]) == 3,
              let revision = integer(value["revision"]),
              let rawCharacters = value["characters"] as? [Any],
              (1...PetRole.builtIns.count).contains(rawCharacters.count),
              let activityValue = value["activity"] as? [String: Any] else {
            throw PetAPIError.invalid
        }
        let characterKeys = Set(["id", "name"])
        var roles: [PetRole] = []
        var identifiers = Set<String>()
        for raw in rawCharacters {
            guard let item = raw as? [String: Any],
                  Set(item.keys).isSubset(of: characterKeys),
                  characterKeys.isSubset(of: Set(item.keys)),
                  let id = try requiredText(item["id"], limit: 48),
                  validRoleID(id),
                  let name = try requiredText(item["name"], limit: 40),
                  !name.isEmpty,
                  identifiers.insert(id).inserted else {
                throw PetAPIError.invalid
            }
            roles.append(PetRole(id: id, name: name))
        }
        guard roles == PetRole.builtIns else { throw PetAPIError.invalid }

        let requiredActivityKeys = Set([
            "sessionId", "title", "agentId", "agentName", "status", "toolName", "lastActivityAt",
        ])
        let activityKeys = requiredActivityKeys.union(["hint"])
        guard Set(activityValue.keys).isSubset(of: activityKeys),
              requiredActivityKeys.isSubset(of: Set(activityValue.keys)),
              let statusText = try requiredText(activityValue["status"], limit: 16),
              let status = PetActivityStatus(rawValue: statusText),
              let lastActivityAt = integer(activityValue["lastActivityAt"]) else {
            throw PetAPIError.invalid
        }
        let activity = PetActivity(
            sessionId: try optionalText(activityValue["sessionId"], limit: 256),
            title: try optionalText(activityValue["title"], limit: 120),
            agentId: try optionalText(activityValue["agentId"], limit: 128),
            agentName: try optionalText(activityValue["agentName"], limit: 80),
            status: status,
            toolName: try optionalText(activityValue["toolName"], limit: 80),
            lastActivityAt: lastActivityAt,
            hint: try optionalHint(activityValue["hint"])
        )
        return PetSnapshotDTO(revision: revision, characters: roles, activity: activity)
    }

    private func object(_ body: Data, allowed: Set<String>, required: Set<String>) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw PetAPIError.invalid
        }
        let keys = Set(value.keys)
        guard keys.isSubset(of: allowed), required.isSubset(of: keys) else {
            throw PetAPIError.invalid
        }
        return value
    }

    private func requiredText(_ value: Any?, limit: Int) throws -> String? {
        guard let value, !(value is NSNull), let text = value as? String,
              text.count <= limit,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PetAPIError.invalid
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func optionalText(_ value: Any?, limit: Int) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        let text = try requiredText(value, limit: limit)
        return text?.isEmpty == true ? nil : text
    }

    private func optionalHint(_ value: Any?) throws -> PetActivityHint? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rawValue = value as? String,
              let hint = PetActivityHint(rawValue: rawValue) else {
            throw PetAPIError.invalid
        }
        return hint
    }

    private func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double,
              double <= Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private func validRoleID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 48 && value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 97 && scalar.value <= 122) ||
            (scalar.value >= 48 && scalar.value <= 57) || scalar.value == 45
        }
    }

    private func hasJSONContentType(_ request: PetHTTPRequest) -> Bool {
        guard let value = request.headers["content-type"]?.lowercased() else { return false }
        return value == "application/json" || value.hasPrefix("application/json;")
    }

    private func selectionObject(_ selection: PetSelection) -> [String: Any] {
        [
            "schemaVersion": 3,
            "characterId": selection.characterId,
            "revision": selection.revision,
            "updatedAt": selection.updatedAt,
        ]
    }

    private func json(_ status: Int, _ object: [String: Any]) -> PetHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return PetHTTPResponse(statusCode: status, body: body)
    }
}

private enum PetAPIError: Error {
    case invalid
}
