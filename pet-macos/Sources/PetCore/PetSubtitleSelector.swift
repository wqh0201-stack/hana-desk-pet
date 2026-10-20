import Foundation

/// Deterministic SplitMix64. The selector never touches system randomness, so a check can
/// assert exactly which line a given seed produces.
public struct PetSubtitleRandom: Sendable {
    private var state: UInt64

    public init(seed: UInt64) {
        self.state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform value in `0..<upperBound`; `upperBound <= 1` yields 0.
    public mutating func next(in upperBound: Int) -> Int {
        guard upperBound > 1 else { return 0 }
        return Int(next() % UInt64(upperBound))
    }
}

/// What the bubble window is asked to draw.
public enum PetBubbleStyle: String, Equatable, Sendable {
    /// Two lines: session title + `需要你确认` / `本轮完成了！`.
    case notice
    /// One line of dialogue, keyed off the pose that is actually on screen.
    case subtitle
}

public struct PetBubbleContent: Equatable, Sendable {
    public let id: String
    public let style: PetBubbleStyle
    /// Notice only: the session title. Empty for a subtitle.
    public let title: String
    /// Notice: its status word. Subtitle: the dialogue line itself.
    public let status: String

    public init(id: String, style: PetBubbleStyle, title: String, status: String) {
        self.id = id
        self.style = style
        self.title = title
        self.status = status
    }
}

public struct PetSubtitleFrame: Equatable, Sendable {
    public let content: PetBubbleContent?
    /// True when the visible words changed, so the window re-measures its size.
    public let changed: Bool
    /// The next moment this selector has to be ticked. `nil` means nothing is scheduled.
    public let nextDeadline: TimeInterval?

    public init(content: PetBubbleContent?, changed: Bool, nextDeadline: TimeInterval?) {
        self.content = content
        self.changed = changed
        self.nextDeadline = nextDeadline
    }

    public static let hidden = PetSubtitleFrame(content: nil, changed: false, nextDeadline: nil)
}

/// Turns "which pose is on screen right now" into one line of dialogue.
///
/// Priority, highest first:
/// 1. the pick-up loop (the user is literally holding the character),
/// 2. a confirmation notice (its existing two-line format is unchanged),
/// 3. a completion notice (likewise),
/// 4. the subtitle for the pose's logical state.
///
/// Every subtitle stays at least `minDwellSeconds`; states that arrive inside that window
/// queue and merge, so only the last one is shown, mirroring the upstream `show()` dwell.
/// States with a `dwellSeconds` entry retire on their own; `null` states persist until the
/// pose changes or something higher preempts them. The pick-up line and both notices are
/// never delayed by that dwell: they are different priorities, not later subtitles.
///
/// Pure logic: no session, tool name, tool argument or file path is ever read here.
public struct PetSubtitleSelector: Sendable {
    public let minDwellSeconds: TimeInterval
    private let catalog: PetSubtitleCatalog
    private var random: PetSubtitleRandom

    private struct Showing: Equatable {
        let content: PetBubbleContent
        let roleId: String
        let state: String
        let shownAt: TimeInterval
        /// `nil` when the state persists until the pose changes.
        let retireAt: TimeInterval?
        var isSubtitle: Bool { content.style == .subtitle }
    }

    private struct Queued: Equatable {
        let content: PetBubbleContent
        let roleId: String
        let state: String
        let readyAt: TimeInterval
    }

    private var showing: Showing?
    private var queued: Queued?
    /// The last resolved (role, state) pair: re-entering a state draws a new line, while a
    /// variant pose inside one state (`thinking` -> `thinking-2`) keeps the current one.
    private var appliedKey: String?
    /// A state whose line already retired while its pose stayed on screen. It may not pop
    /// back until the pose actually changes.
    private var retiredKey: String?
    /// One entry per (role, state): the last line index used, so a state never repeats the
    /// same sentence twice in a row. Bounded by roles × states, never grows at runtime.
    private var lastLineIndex: [String: Int] = [:]

    public init(catalog: PetSubtitleCatalog, seed: UInt64 = 0x6861_6E61_7065_7421) {
        self.catalog = catalog
        self.minDwellSeconds = max(0, catalog.minDwellSeconds)
        self.random = PetSubtitleRandom(seed: seed)
    }

    public var currentContent: PetBubbleContent? { showing?.content }

    /// Resolves the bubble for the newest displayed pose.
    ///
    /// - Parameters:
    ///   - pose: the final artwork pose the renderer settled on.
    ///   - roleId: the selected character; lines never cross characters.
    ///   - notice: the notice centre's resolved presentation, or `nil`.
    ///   - isPickUp: whether the pick-up loop currently owns the artwork.
    ///   - enabled: the one bubble switch. Off hides every bubble and changes nothing else.
    ///   - time: caller-supplied monotonic seconds.
    public mutating func update(
        pose: String?,
        roleId: String,
        notice: PetNoticePresentation?,
        isPickUp: Bool,
        enabled: Bool,
        at time: TimeInterval
    ) -> PetSubtitleFrame {
        let now = time.isFinite ? max(0, time) : 0
        let previous = showing?.content

        guard enabled else {
            clear()
            return PetSubtitleFrame(content: nil, changed: previous != nil, nextDeadline: nil)
        }

        // 1. The pick-up loop wins outright: the user is holding the character, so this is
        // an escalation, not a queued subtitle. It shows at once.
        if isPickUp, let state = catalog.stateKey(forPose: "picked-up"),
           catalog.hasLines(roleId: roleId, state: state) {
            if appliedKey != "\(roleId)|\(state)" {
                appliedKey = "\(roleId)|\(state)"
                retiredKey = nil
                let content = drawLine(roleId: roleId, state: state)!
                show(content, roleId: roleId, state: state, now: now)
            }
            queued = nil
            return frame(previous)
        }

        // 2./3. A notice keeps its exact existing two-line format.
        if let notice, notice.bubbleVisible {
            let content = PetBubbleContent(
                id: notice.id,
                style: .notice,
                title: notice.title,
                status: notice.status
            )
            showing = Showing(
                content: content,
                roleId: roleId,
                state: "notice",
                shownAt: now,
                retireAt: nil
            )
            queued = nil
            // A notice is a different owner of the bubble: when it ends, the pose's state
            // is re-entered and speaks again instead of resuming a retired line.
            appliedKey = nil
            retiredKey = nil
            return PetSubtitleFrame(content: content, changed: content != previous, nextDeadline: notice.endsAt)
        }

        // 4. The subtitle for the pose's logical state.
        guard let pose, let state = catalog.stateKey(forPose: pose),
              catalog.hasLines(roleId: roleId, state: state) else {
            clear()
            return PetSubtitleFrame(content: nil, changed: previous != nil, nextDeadline: nil)
        }
        return advance(roleId: roleId, state: state, now: now, previous: previous)
    }

    private mutating func advance(
        roleId: String,
        state: String,
        now: TimeInterval,
        previous: PetBubbleContent?
    ) -> PetSubtitleFrame {
        let key = "\(roleId)|\(state)"

        if appliedKey == key {
            // Same state. A queued line becomes visible once the minimum dwell is over.
            if let waiting = queued, waiting.state == state, now >= waiting.readyAt {
                show(waiting.content, roleId: roleId, state: state, now: now)
                queued = nil
                return frame(previous)
            }
            if let current = showing, current.state == state, current.roleId == roleId,
               let retireAt = current.retireAt, now >= retireAt {
                showing = nil
                queued = nil
                retiredKey = key
                return PetSubtitleFrame(content: nil, changed: true, nextDeadline: nil)
            }
            return frame(previous)
        }

        appliedKey = key
        // This state already retired and its pose never went away: stay silent.
        if retiredKey == key {
            queued = nil
            return PetSubtitleFrame(content: showing?.content, changed: false, nextDeadline: showing?.retireAt)
        }
        retiredKey = nil

        let content = drawLine(roleId: roleId, state: state)!
        // A subtitle already on screen gets its full minimum dwell; the newcomer waits and
        // only the last arrival survives. Notices, the pick-up line and a character switch
        // are exempt: they are not "the same character moved on".
        if let current = showing, current.isSubtitle, current.roleId == roleId {
            let notBefore = current.shownAt + minDwellSeconds
            if now < notBefore {
                queued = Queued(content: content, roleId: roleId, state: state, readyAt: notBefore)
                return PetSubtitleFrame(content: current.content, changed: false, nextDeadline: notBefore)
            }
        }
        show(content, roleId: roleId, state: state, now: now)
        queued = nil
        return frame(previous)
    }

    private mutating func show(_ content: PetBubbleContent, roleId: String, state: String, now: TimeInterval) {
        showing = Showing(
            content: content,
            roleId: roleId,
            state: state,
            shownAt: now,
            retireAt: catalog.dwellSeconds(forState: state).map { now + $0 }
        )
    }

    private mutating func clear() {
        showing = nil
        queued = nil
        appliedKey = nil
        retiredKey = nil
    }

    /// Draws the line for one state entry. The same state never shows the same sentence
    /// twice in a row.
    private mutating func drawLine(roleId: String, state: String) -> PetBubbleContent? {
        let lines = catalog.lines(roleId: roleId, state: state)
        guard !lines.isEmpty else { return nil }
        let key = "\(roleId)|\(state)"
        var index = 0
        if lines.count > 1 {
            if let last = lastLineIndex[key] {
                // Uniform over every *other* line, so a repeat is impossible for two candidates.
                let offset = random.next(in: lines.count - 1)
                index = offset >= last ? offset + 1 : offset
            } else {
                index = random.next(in: lines.count)
            }
        }
        lastLineIndex[key] = index
        return PetBubbleContent(
            id: "subtitle:\(roleId):\(state):\(index)",
            style: .subtitle,
            title: "",
            status: lines[index]
        )
    }

    private func frame(_ previous: PetBubbleContent?) -> PetSubtitleFrame {
        var deadlines: [TimeInterval] = []
        if let retireAt = showing?.retireAt { deadlines.append(retireAt) }
        if let readyAt = queued?.readyAt { deadlines.append(readyAt) }
        let content = showing?.content
        return PetSubtitleFrame(content: content, changed: content != previous, nextDeadline: deadlines.min())
    }
}
