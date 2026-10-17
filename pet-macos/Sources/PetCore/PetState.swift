import Foundation

public enum PetActivityStatus: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case tool
    case success
    case error
}

/// Strict optional host hint enum. It carries no content beyond one of the fixed values.
public enum PetActivityHint: String, Codable, CaseIterable, Sendable {
    case confirming
    case compacting
    case interrupted
}

public struct PetRole: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public static let builtIns: [PetRole] = [
        PetRole(id: "claude", name: "Claude"),
        PetRole(id: "gpt", name: "GPT 白龙"),
        PetRole(id: "deepseek", name: "DeepSeek 大肥鱼"),
        PetRole(id: "gemini", name: "Gemini"),
        PetRole(id: "glm", name: "GLM 黑狐狸"),
        PetRole(id: "deepseek-hoodie", name: "大肥鱼·Claude 卫衣"),
        PetRole(id: "gpt-onesie", name: "GPT 降智龙崽"),
    ]
}

public struct PetActivity: Codable, Equatable, Sendable {
    public var sessionId: String?
    public var title: String?
    public var agentId: String?
    public var agentName: String?
    public var status: PetActivityStatus
    public var toolName: String?
    public var lastActivityAt: Int64
    public var hint: PetActivityHint?

    public init(
        sessionId: String? = nil,
        title: String? = nil,
        agentId: String? = nil,
        agentName: String? = nil,
        status: PetActivityStatus = .idle,
        toolName: String? = nil,
        lastActivityAt: Int64 = 0,
        hint: PetActivityHint? = nil
    ) {
        self.sessionId = sessionId
        self.title = title
        self.agentId = agentId
        self.agentName = agentName
        self.status = status
        self.toolName = toolName
        self.lastActivityAt = lastActivityAt
        self.hint = hint
    }
}

public struct PetSelection: Codable, Equatable, Sendable {
    public var characterId: String
    public var revision: Int64
    public var updatedAt: Int64

    public init(characterId: String = "claude", revision: Int64 = 0, updatedAt: Int64 = 0) {
        self.characterId = characterId
        self.revision = max(0, revision)
        self.updatedAt = max(0, updatedAt)
    }
}

public struct PetViewState: Equatable, Sendable {
    public let roles: [PetRole]
    public let activity: PetActivity
    public let selection: PetSelection
    public let appConnected: Bool

    /// Stale activity remains available as data, but must not keep animating as live work.
    public var displayStatus: PetActivityStatus {
        appConnected ? activity.status : .idle
    }

    /// Host hints are stale too; hide them when the peer connection expires.
    public var displayHint: PetActivityHint? {
        appConnected ? activity.hint : nil
    }
}

public struct PetSnapshotDTO: Equatable, Sendable {
    public let revision: Int64
    public let characters: [PetRole]
    public let activity: PetActivity

    public init(revision: Int64, characters: [PetRole], activity: PetActivity) {
        self.revision = revision
        self.characters = characters
        self.activity = activity
    }
}

public enum SnapshotIngestResult: Sendable {
    case accepted
    case stale
}

public enum SelectionWriteResult: Sendable {
    case updated(PetSelection)
    case conflict(PetSelection)
    case unknownRole
}

/// In-memory state owner. It never reads or writes CrossPet or Hana configuration.
public final class PetStateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var roles = PetRole.builtIns
    private var activity = PetActivity()
    private var selection: PetSelection
    private var snapshotRevision: Int64 = 0
    private var lastSnapshotReceivedAt: Int64 = 0
    private let connectionTimeoutMs: Int64 = 8_000

    public init(selection: PetSelection = PetSelection()) {
        self.selection = selection
    }

    public func viewState(now: Int64 = PetStateStore.nowMilliseconds()) -> PetViewState {
        lock.lock()
        defer { lock.unlock() }
        return PetViewState(
            roles: roles,
            activity: activity,
            selection: selection,
            appConnected: lastSnapshotReceivedAt > 0 && now >= lastSnapshotReceivedAt && now - lastSnapshotReceivedAt <= connectionTimeoutMs
        )
    }

    public func currentSelection() -> PetSelection {
        lock.lock()
        defer { lock.unlock() }
        return selection
    }

    @discardableResult
    public func selectLocally(_ characterId: String, now: Int64 = PetStateStore.nowMilliseconds()) -> PetSelection? {
        lock.lock()
        defer { lock.unlock() }
        guard roles.contains(where: { $0.id == characterId }) else { return nil }
        guard selection.characterId != characterId else { return selection }
        selection = PetSelection(
            characterId: characterId,
            revision: selection.revision + 1,
            updatedAt: max(now, selection.updatedAt + 1)
        )
        return selection
    }

    public func ingest(_ snapshot: PetSnapshotDTO, receivedAt: Int64 = PetStateStore.nowMilliseconds()) -> SnapshotIngestResult {
        lock.lock()
        defer { lock.unlock() }
        guard snapshot.revision >= snapshotRevision else { return .stale }
        snapshotRevision = snapshot.revision
        roles = snapshot.characters
        activity = snapshot.activity
        lastSnapshotReceivedAt = max(receivedAt, lastSnapshotReceivedAt)
        if !roles.contains(where: { $0.id == selection.characterId }), let first = roles.first {
            selection = PetSelection(
                characterId: first.id,
                revision: selection.revision + 1,
                updatedAt: max(receivedAt, selection.updatedAt + 1)
            )
        }
        return .accepted
    }

    public func writeRemoteSelection(
        characterId: String,
        expectedRevision: Int64,
        updatedAt: Int64,
        now: Int64 = PetStateStore.nowMilliseconds()
    ) -> SelectionWriteResult {
        lock.lock()
        defer { lock.unlock() }
        guard expectedRevision == selection.revision else { return .conflict(selection) }
        guard roles.contains(where: { $0.id == characterId }) else { return .unknownRole }
        guard selection.characterId != characterId else { return .updated(selection) }
        selection = PetSelection(
            characterId: characterId,
            revision: selection.revision + 1,
            updatedAt: max(max(updatedAt, now), selection.updatedAt + 1)
        )
        return .updated(selection)
    }

    public static func nowMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }
}
