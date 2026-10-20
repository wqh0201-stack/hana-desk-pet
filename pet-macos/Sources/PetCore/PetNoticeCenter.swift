import Foundation

/// One resolved bubble: exactly a title line and a status line.
public struct PetNoticePresentation: Equatable, Sendable {
    public let id: String
    public let kind: PetNoticeKind
    public let title: String
    public let status: String
    public let startedAt: TimeInterval
    public let endsAt: TimeInterval
    /// Whether the bubble may be shown. A completion that was hidden (or arrived while
    /// bubbles were off) can keep driving the pose with this false; it must never pop
    /// back as an old bubble when the setting is re-enabled.
    public let bubbleVisible: Bool

    public init(
        id: String,
        kind: PetNoticeKind,
        title: String,
        status: String,
        startedAt: TimeInterval,
        endsAt: TimeInterval,
        bubbleVisible: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.bubbleVisible = bubbleVisible
    }

    func withBubbleVisible(_ visible: Bool) -> PetNoticePresentation {
        PetNoticePresentation(
            id: id,
            kind: kind,
            title: title,
            status: status,
            startedAt: startedAt,
            endsAt: endsAt,
            bubbleVisible: visible
        )
    }
}

public struct PetNoticeTick: Equatable, Sendable {
    public let presentation: PetNoticePresentation?
    public let changed: Bool
    public let nextDeadline: TimeInterval?

    public init(presentation: PetNoticePresentation?, changed: Bool, nextDeadline: TimeInterval?) {
        self.presentation = presentation
        self.changed = changed
        self.nextDeadline = nextDeadline
    }
}

/// Bounded, deterministic presentation queue for confirmation and completion notices.
///
/// It only ever sees the already-sanitised `PetNotice` DTO. It owns no session state,
/// never writes activity and never invents an event: a confirmation must still be in
/// the latest snapshot to stay on screen, and a completion is consumed exactly once.
public struct PetNoticeCenter: Sendable {
    /// A confirmation bubble is a safety-limited prompt, not a permanent fixture.
    public static let confirmationDisplay: TimeInterval = 300
    /// A finished-turn celebration stays for six seconds, then the latest real state returns.
    public static let completionDisplay: TimeInterval = 6
    /// A completion older than this is history, even if the pet was busy when it happened.
    public static let completionTTL: TimeInterval = 20
    /// At most this many completions wait behind the current bubble.
    public static let maxCompletionQueue = 3
    private static let maxSeen = 64

    private var seen: [String: Int] = [:]
    private var seenOrder: [String] = []
    private var nextSeenOrder = 0
    private var suppressed: Set<String> = []
    private var suppressedOrder: [String] = []
    /// Completions queued before a setting/scope change: neither pose nor bubble may replay.
    private var retired: Set<String> = []
    private var retiredOrder: [String] = []
    private var active: PetNoticePresentation?
    private var pending: [PetNotice] = []
    private var initialized = false
    private var lastBubblesEnabled = true
    private var lastScope = "latest"

    public init() {}

    /// Ingests one snapshot's notices. `completionBlocked` is the renderer's honest
    /// answer to "is a confirmation, error, drawing hold or direct drag owning the
    /// artwork right now?"; a completion waits instead of interrupting those.
    public mutating func update(
        notices: [PetNotice],
        bubblesEnabled: Bool,
        completionBlocked: Bool,
        now: TimeInterval,
        wallNowMs: Int64,
        scope: String = "latest"
    ) -> PetNoticeTick {
        let time = max(0, now)
        let previous = active
        let valid = dedupe(notices)
        let byId = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0) })

        // A binding change replaces the allowed notice scope. Drop anything that is no
        // longer listed, but keep the new scope's own active notice and queue untouched.
        if scope != lastScope {
            lastScope = scope
            pending.removeAll { byId[$0.id] == nil }
            if let active, active.kind == .confirmation {
                self.active = nil
            }
            if let active, active.kind == .completion, byId[active.id] == nil {
                self.active = nil
            }
            // Still-pending confirmations are actionable in the new scope; let them
            // be shown again if they remain in the list. Completions stay consumed.
            for notice in valid where notice.kind == .confirmation {
                unmarkSeen(notice.id)
            }
        }

        if !initialized {
            initialized = true
            // Completions are one-shot. Anything already present at startup is history,
            // never a reason to replay a burst of old celebrations. A still-pending
            // confirmation is different: it is still actionable and may be shown.
            for notice in valid where notice.kind == .completion {
                markSeen(notice.id)
            }
        }

        if lastBubblesEnabled && !bubblesEnabled {
            // Turning bubbles off hides the current bubble only. A completion keeps its
            // pose but is marked suppressed, so re-enabling can never replay it. A
            // confirmation stays actionable, so its seen state is forgotten instead.
            if let active, active.kind == .completion, active.bubbleVisible {
                suppress(active.id)
                self.active = active.withBubbleVisible(false)
            }
            if let active, active.kind == .confirmation {
                self.active = nil
            }
            // Anything already queued before the setting changed is old: neither its pose
            // nor its bubble may replay. A completion that arrives while bubbles are off
            // is different (handled below): pose yes, bubble no.
            for notice in pending {
                retire(notice.id)
            }
            for notice in valid where notice.kind == .confirmation {
                unmarkSeen(notice.id)
            }
        }
        lastBubblesEnabled = bubblesEnabled

        // An active notice is valid only while its source is still present and fresh.
        // A completion that is already on screen is different: it must get its full
        // six seconds even if the console's notice TTL removes it from the wire list,
        // otherwise a notice queued near the TTL would be cut short mid-display.
        if let active {
            if active.endsAt <= time {
                self.active = nil
            } else if active.kind == .confirmation && (byId[active.id] == nil || !bubblesEnabled) {
                self.active = nil
            } else if active.kind == .completion && completionBlocked {
                self.active = nil
            }
        }

        // Consume each completion exactly once, within a short age window.
        for notice in valid where notice.kind == .completion {
            if seen[notice.id] != nil { continue }
            let age = (Double(wallNowMs) - Double(notice.at)) / 1_000
            if age < -1 || age > Self.completionTTL {
                markSeen(notice.id)
                continue
            }
            if pending.contains(where: { $0.id == notice.id }) { continue }
            if !bubblesEnabled {
                // A completion arriving while bubbles are off still drives the pose. Its
                // bubble is permanently suppressed for this event, even if the user
                // re-enables bubbles before a higher-priority block clears.
                suppress(notice.id)
                pending = [notice]
            } else {
                if pending.count >= Self.maxCompletionQueue {
                    pending.removeFirst()
                }
                pending.append(notice)
            }
            markSeen(notice.id)
        }
        // A queued completion must also be pruned when the follow scope changed: the
        // console stops listing another session's notice once the pet is bound.
        pending.removeAll { notice in
            if byId[notice.id] == nil { return true }
            let age = (Double(wallNowMs) - Double(notice.at)) / 1_000
            return age < -1 || age > Self.completionTTL
        }

        // A confirmation always preempts a completion. A new confirmation does not
        // preempt an already-showing confirmation: oldest-first is deterministic.
        if bubblesEnabled, let current = active, current.kind == .completion,
           let confirmation = nextConfirmation(in: valid) {
            active = nil
            activate(confirmation, display: Self.confirmationDisplay, now: time, bubblesEnabled: bubblesEnabled)
        }

        if active == nil {
            if bubblesEnabled, let confirmation = nextConfirmation(in: valid) {
                activate(confirmation, display: Self.confirmationDisplay, now: time, bubblesEnabled: bubblesEnabled)
            } else if !completionBlocked, let completion = pending.first {
                pending.removeFirst()
                if !retired.contains(completion.id) {
                    // The action always runs for a notice received while bubbles were off.
                    // Whether its bubble is visible was decided when it arrived.
                    activate(completion, display: Self.completionDisplay, now: time, bubblesEnabled: bubblesEnabled)
                }
            }
        }

        let changed = active?.id != previous?.id ||
            active?.endsAt != previous?.endsAt ||
            active?.status != previous?.status ||
            active?.title != previous?.title ||
            active?.bubbleVisible != previous?.bubbleVisible
        return PetNoticeTick(
            presentation: active,
            changed: changed,
            nextDeadline: active?.endsAt
        )
    }

    public func currentPresentation() -> PetNoticePresentation? {
        active
    }

    private mutating func activate(
        _ notice: PetNotice,
        display: TimeInterval,
        now: TimeInterval,
        bubblesEnabled: Bool
    ) {
        let visible = notice.kind == .confirmation ||
            (bubblesEnabled && !suppressed.contains(notice.id))
        active = PetNoticePresentation(
            id: notice.id,
            kind: notice.kind,
            title: normalizedTitle(notice.title),
            status: notice.kind == .confirmation ? "需要你确认" : "本轮完成了！",
            startedAt: now,
            endsAt: now + display,
            bubbleVisible: visible
        )
        if notice.kind == .confirmation {
            markSeen(notice.id)
        }
    }

    private func nextConfirmation(in notices: [PetNotice]) -> PetNotice? {
        notices
            .filter { $0.kind == .confirmation && seen[$0.id] == nil }
            .sorted { $0.at < $1.at || ($0.at == $1.at && $0.id < $1.id) }
            .first
    }

    private func normalizedTitle(_ title: String?) -> String {
        let cleaned = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "对话" }
        return String(cleaned.prefix(120))
    }

    private mutating func markSeen(_ id: String) {
        guard seen[id] == nil else { return }
        seen[id] = nextSeenOrder
        seenOrder.append(id)
        nextSeenOrder += 1
        while seenOrder.count > Self.maxSeen {
            let oldest = seenOrder.removeFirst()
            seen.removeValue(forKey: oldest)
        }
    }

    private mutating func unmarkSeen(_ id: String) {
        guard seen.removeValue(forKey: id) != nil else { return }
        seenOrder.removeAll { $0 == id }
    }

    private mutating func suppress(_ id: String) {
        guard suppressed.insert(id).inserted else { return }
        suppressedOrder.append(id)
        while suppressedOrder.count > Self.maxSeen {
            let oldest = suppressedOrder.removeFirst()
            suppressed.remove(oldest)
        }
    }

    private mutating func retire(_ id: String) {
        guard retired.insert(id).inserted else { return }
        retiredOrder.append(id)
        while retiredOrder.count > Self.maxSeen {
            let oldest = retiredOrder.removeFirst()
            retired.remove(oldest)
        }
    }

    private func dedupe(_ notices: [PetNotice]) -> [PetNotice] {
        var result: [PetNotice] = []
        var ids = Set<String>()
        for notice in notices where ids.insert(notice.id).inserted {
            result.append(notice)
        }
        return result
    }
}
