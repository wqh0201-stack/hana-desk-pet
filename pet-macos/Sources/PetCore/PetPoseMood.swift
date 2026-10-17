import Foundation

/// Local, coarse-grained activity moods. These are derived from the existing status,
/// tool name, activity timestamp and monotonic local time; they are not protocol fields.
public enum PetPoseMood: String, Equatable, Sendable {
    case sleeping
    case tired
    case swampedLeft
    case swampedRight
    case proud

    /// Resolves each mood only against the selected character's catalog-listed poses.
    /// Each mood has its own intentional fallback chain and finishes at that character's idle.
    public static func resolvedPose(
        for mood: PetPoseMood,
        workPose: String,
        availablePoseNames: [String]
    ) -> String {
        guard !availablePoseNames.isEmpty else { return "idle" }
        let available = Set(availablePoseNames)
        let candidates: [String]
        switch mood {
        case .sleeping:
            candidates = ["sleeping", "sleeping-2", "idle"]
        case .tired:
            candidates = ["tired", "tired-2", workPose, "idle"]
        case .swampedLeft:
            candidates = ["swamped_left", "busy_left", "busy_right", "idle"]
        case .swampedRight:
            candidates = ["swamped_right", "busy_right", "busy_left", "idle"]
        case .proud:
            candidates = ["proud", "proud-2", "happy", "happy-2", "idle"]
        }
        if let match = candidates.first(where: { available.contains($0) }) { return match }
        if available.contains("idle") { return "idle" }
        return availablePoseNames[0]
    }
}

/// Deterministic local timing/frequency inference for the native artwork layer.
/// `update` and `advance` use a caller-supplied monotonic clock so every threshold is testable
/// without sleeping. Tool arguments, results and conversation content are never inspected.
public struct PetPoseMoodTracker: Sendable {
    public static let sleepAfterIdle: TimeInterval = 5 * 60
    public static let tiredAfterWork: TimeInterval = 10 * 60
    public static let busyToolWindow: TimeInterval = 10
    public static let busyToolStartThreshold = 5
    public static let proudAfterWork: TimeInterval = 60
    public static let shortFeedbackContinuation: TimeInterval = 2.5

    private var status: PetActivityStatus?
    private var hint: PetActivityHint?
    private var lastActivityAt: Int64?
    private var idleSince: TimeInterval?
    private var workSince: TimeInterval?
    private var feedbackContinuationEndsAt: TimeInterval?
    private var proudSuccess = false
    private var toolStartTimes: [TimeInterval] = []
    private var lastToolName: String?
    private var lastToolActivityAt: Int64?
    private var hasToolSignature = false
    private var lastSwampedMood: PetPoseMood?
    private var lastObservedAt: TimeInterval?

    private static let thresholdWakeEpsilon: TimeInterval = 0.001

    public init() {}

    /// Ingests the latest locally visible status. A changed activity timestamp while idle also
    /// restarts the idle dwell, so any new activity wakes a sleeping pose without protocol changes.
    @discardableResult
    public mutating func update(
        status newStatus: PetActivityStatus,
        toolName: String?,
        hint newHint: PetActivityHint? = nil,
        lastActivityAt newActivityAt: Int64,
        at time: TimeInterval
    ) -> PetPoseMood? {
        let now = normalizedTime(time)
        expireFeedbackContinuation(at: now)
        let previousStatus = status
        let activityTimestampChanged = lastActivityAt != newActivityAt

        switch newStatus {
        case .idle:
            if newHint != nil {
                idleSince = nil
            } else if previousStatus != .idle || activityTimestampChanged || hint != nil || idleSince == nil {
                idleSince = now
            }
            workSince = nil
            feedbackContinuationEndsAt = nil
            proudSuccess = false
            hasToolSignature = false

        case .working, .tool:
            let returningFromShortFeedback = (previousStatus == .success || previousStatus == .error) &&
                feedbackContinuationEndsAt.map { now < $0 } == true && workSince != nil
            if !Self.isWorkStatus(previousStatus) && !returningFromShortFeedback {
                workSince = now
            }
            idleSince = nil
            feedbackContinuationEndsAt = nil
            proudSuccess = false

            if newStatus == .tool {
                let isNewToolStart = previousStatus != .tool ||
                    lastToolName != toolName || lastToolActivityAt != newActivityAt || !hasToolSignature
                if isNewToolStart {
                    recordToolStart(at: now)
                }
                lastToolName = toolName
                lastToolActivityAt = newActivityAt
                hasToolSignature = true
            } else {
                hasToolSignature = false
            }

        case .success, .error:
            idleSince = nil
            if Self.isWorkStatus(previousStatus) {
                feedbackContinuationEndsAt = now + Self.shortFeedbackContinuation
            } else if (previousStatus == .success || previousStatus == .error),
                      activityTimestampChanged,
                      workSince != nil {
                // Consecutive short tool-result feedback can arrive without a sampled work frame.
                feedbackContinuationEndsAt = now + Self.shortFeedbackContinuation
            }
            hasToolSignature = false

            if newStatus == .success {
                let isNewFeedback = previousStatus != .success || activityTimestampChanged
                if isNewFeedback {
                    proudSuccess = workSince.map { now - $0 >= Self.proudAfterWork } ?? false
                }
            } else {
                proudSuccess = false
            }
        }

        status = newStatus
        hint = newHint
        lastActivityAt = newActivityAt
        lastObservedAt = now
        return mood(at: now)
    }

    /// Advances local deadlines (notably the end of the short-feedback continuity window).
    @discardableResult
    public mutating func advance(at time: TimeInterval) -> PetPoseMood? {
        let now = normalizedTime(time)
        expireFeedbackContinuation(at: now)
        lastObservedAt = now
        return mood(at: now)
    }

    public func mood(at time: TimeInterval) -> PetPoseMood? {
        let now = normalizedTime(time)
        guard hint == nil else { return nil }
        if status == .success, proudSuccess { return .proud }
        if status == .idle,
           let idleSince,
           now - idleSince > Self.sleepAfterIdle {
            return .sleeping
        }
        guard let status, Self.isWorkStatus(status), let workSince else { return nil }

        if status == .tool,
           recentToolStarts(at: now).count >= Self.busyToolStartThreshold {
            return lastSwampedMood ?? .swampedLeft
        }
        if now - workSince > Self.tiredAfterWork { return .tired }
        return nil
    }

    /// One-shot deadlines only. Once sleeping/tired settles there is no repeating wakeup,
    /// so long-duration moods do not turn idle rendering into a high-frequency loop.
    public func nextDeadline(after time: TimeInterval) -> TimeInterval? {
        let now = normalizedTime(time)
        var deadlines: [TimeInterval] = []

        if hint == nil {
            if status == .idle, let idleSince {
                let deadline = idleSince + Self.sleepAfterIdle + Self.thresholdWakeEpsilon
                if deadline > now { deadlines.append(deadline) }
            }
            if let status, Self.isWorkStatus(status), let workSince {
                let deadline = workSince + Self.tiredAfterWork + Self.thresholdWakeEpsilon
                if deadline > now { deadlines.append(deadline) }
            }
        }
        if hint == nil, status == .tool {
            let recent = recentToolStarts(at: now)
            if recent.count >= Self.busyToolStartThreshold,
               let oldestRelevantStart = recent.first {
                let deadline = oldestRelevantStart + Self.busyToolWindow + Self.thresholdWakeEpsilon
                if deadline > now { deadlines.append(deadline) }
            }
        }
        if let feedbackContinuationEndsAt, feedbackContinuationEndsAt > now {
            deadlines.append(feedbackContinuationEndsAt)
        }
        return deadlines.min()
    }

    private mutating func recordToolStart(at time: TimeInterval) {
        toolStartTimes.append(time)
        if toolStartTimes.count > Self.busyToolStartThreshold {
            toolStartTimes.removeFirst(toolStartTimes.count - Self.busyToolStartThreshold)
        }
        if recentToolStarts(at: time).count >= Self.busyToolStartThreshold {
            lastSwampedMood = lastSwampedMood == .swampedLeft ? .swampedRight : .swampedLeft
        }
    }

    private func recentToolStarts(at time: TimeInterval) -> [TimeInterval] {
        toolStartTimes.filter { $0 >= time - Self.busyToolWindow }
    }

    private mutating func expireFeedbackContinuation(at time: TimeInterval) {
        guard let deadline = feedbackContinuationEndsAt, time >= deadline else { return }
        workSince = nil
        feedbackContinuationEndsAt = nil
    }

    private func normalizedTime(_ time: TimeInterval) -> TimeInterval {
        let safe = time.isFinite ? max(0, time) : 0
        return max(safe, lastObservedAt ?? safe)
    }

    /// The start of the current continuous work segment, whether it is still open or has just
    /// been closed by a short tool-result feedback window. Read-only: it is the single work
    /// clock shared by fatigue and the ordinary-work rhythm.
    public var continuousWorkStart: TimeInterval? { workSince }

    private static func isWorkStatus(_ status: PetActivityStatus?) -> Bool {
        status == .working || status == .tool
    }
}
