import Foundation

/// One character's resolved ordinary-work poses. `PetPosePlanner.workPoseSet` builds it
/// strictly from catalog-listed artwork, so the scheduler can never name a pose the
/// character does not own.
public struct PetWorkPoseSet: Equatable, Sendable {
    public let thinking: String
    public let busyLeft: String
    public let thinkingVariant: String
    public let busyRight: String

    public init(thinking: String, busyLeft: String, thinkingVariant: String, busyRight: String) {
        self.thinking = thinking
        self.busyLeft = busyLeft
        self.thinkingVariant = thinkingVariant
        self.busyRight = busyRight
    }

    public var distinctPoses: [String] {
        var seen = Set<String>()
        return [thinking, busyLeft, thinkingVariant, busyRight].filter { seen.insert($0).inserted }
    }

    /// A rhythm needs at least two distinguishable poses; otherwise it would schedule a
    /// wake-up that can never change the artwork.
    public var supportsRhythm: Bool { distinctPoses.count >= 2 }
}

/// Identity of one continuous work segment: which session, and when the segment began.
/// `workSegmentStart` is read directly from `PetPoseMoodTracker.continuousWorkStart`;
/// the scheduler never invents, copies or writes a second work clock.
public struct PetWorkPoseIdentity: Equatable, Sendable {
    public let sessionId: String
    public let workSegmentStart: TimeInterval

    public init(sessionId: String, workSegmentStart: TimeInterval) {
        self.sessionId = sessionId
        self.workSegmentStart = workSegmentStart
    }
}

/// Everything the scheduler may look at for one render pass. It carries no conversation
/// content: only the bounded status fields the protocol already exposes plus local view
/// flags (visibility, reduced motion).
public struct PetWorkPoseSchedulerInput: Equatable, Sendable {
    public let sessionId: String?
    public let workSegmentStart: TimeInterval?
    public let status: PetActivityStatus
    public let hint: PetActivityHint?
    /// A mood or short feedback is already owning the artwork.
    public let hasPriorityState: Bool
    /// Window visible, app not hidden and "reduce motion" off.
    public let allowsAutonomousRotation: Bool
    /// A tap response is playing; ordinary rotation must let it finish.
    public let interactionIsActive: Bool
    /// The pose the real activity state resolves to right now (planner or mood result).
    public let realPose: String

    public init(
        sessionId: String?,
        workSegmentStart: TimeInterval?,
        status: PetActivityStatus,
        hint: PetActivityHint?,
        hasPriorityState: Bool,
        allowsAutonomousRotation: Bool,
        interactionIsActive: Bool,
        realPose: String
    ) {
        self.sessionId = sessionId
        self.workSegmentStart = workSegmentStart
        self.status = status
        self.hint = hint
        self.hasPriorityState = hasPriorityState
        self.allowsAutonomousRotation = allowsAutonomousRotation
        self.interactionIsActive = interactionIsActive
        self.realPose = realPose
    }
}

/// The scheduler's answer for one pass. `pose == nil` means "this layer does not own the
/// artwork"; the renderer keeps the pose the real state resolved to.
public struct PetWorkPoseSchedulerTick: Equatable, Sendable {
    public let pose: String?
    public let generation: UInt64
    public let identity: PetWorkPoseIdentity?
    public let nextDeadline: TimeInterval?
    public let discardedStaleTick: Bool

    public static let invalidated = PetWorkPoseSchedulerTick(
        pose: nil, generation: 0, identity: nil, nextDeadline: nil, discardedStaleTick: true
    )
}

/// Deterministic ordinary-work rhythm plus the bounded tool-return grace window.
///
/// This is a display clock only. It never writes the mood tracker's continuous-work
/// start, never counts a pose change as tool activity, and never invents a work segment
/// start. All timing uses a caller-supplied monotonic clock, so every rule is testable
/// without sleeping.
public struct PetWorkPoseScheduler: Sendable {
    /// Rhythm values for the first version. Tuning changes only these constants.
    public static let thinkingHold: TimeInterval = 6
    public static let busyLeftHold: TimeInterval = 4
    public static let thinkingVariantHold: TimeInterval = 7
    public static let busyRightHold: TimeInterval = 5

    /// A tool pose keeps at least this long on screen when it began just before returning.
    public static let toolMinimumVisible: TimeInterval = 2.0
    /// Ordinary work waits this long after a direct tool → working return.
    public static let toolReturnGrace: TimeInterval = 1.2

    public struct Phase: Equatable, Sendable {
        public let pose: String
        public let duration: TimeInterval

        public init(pose: String, duration: TimeInterval) {
            self.pose = pose
            self.duration = duration
        }
    }

    private enum Mode: Equatable {
        case dormant
        case rhythm
        case tool
        case grace
    }

    private var identity: PetWorkPoseIdentity?
    private var generation: UInt64 = 0
    private var mode: Mode = .dormant
    private var cycleStartedAt: TimeInterval?
    private var phases: [Phase] = []
    private var thinkingPose = "thinking"
    private var latestWorkPoses: PetWorkPoseSet?
    private var pauseStartedAt: TimeInterval?
    private var toolPose: String?
    private var toolEnteredAt: TimeInterval?
    private var gracePose: String?
    private var graceEndsAt: TimeInterval?
    private var lastObservedAt: TimeInterval?

    public init() {}

    public var currentGeneration: UInt64 { generation }
    public var currentIdentity: PetWorkPoseIdentity? { identity }
    public var isPausedForInteraction: Bool { pauseStartedAt != nil }

    public func matches(identity expectedIdentity: PetWorkPoseIdentity?, generation expectedGeneration: UInt64) -> Bool {
        identity == expectedIdentity && generation == expectedGeneration
    }

    /// Freezes the rhythm while a tap response plays, so an autonomous rotation cannot
    /// cancel it mid-response. Real state changes still own the artwork as usual.
    public mutating func beginInteraction(at time: TimeInterval) {
        guard pauseStartedAt == nil else { return }
        pauseStartedAt = normalizedTime(time)
    }

    /// Resumes the rhythm at the phase that was showing when the response started. The
    /// paused span is removed from the cycle, so no skipped phase is replayed.
    public mutating func endInteraction(at time: TimeInterval) {
        guard let pauseStartedAt else { return }
        let now = normalizedTime(max(time, pauseStartedAt))
        if let cycleStartedAt {
            self.cycleStartedAt = cycleStartedAt + (now - pauseStartedAt)
        }
        self.pauseStartedAt = nil
    }

    /// Ingests the latest real state and answers with the pose this layer wants.
    @discardableResult
    public mutating func update(
        _ input: PetWorkPoseSchedulerInput,
        workPoses: PetWorkPoseSet?,
        at time: TimeInterval
    ) -> PetWorkPoseSchedulerTick {
        let now = normalizedTime(time)
        var contextChanged = false
        if let workPoses { latestWorkPoses = workPoses }

        let resolvedIdentity: PetWorkPoseIdentity?
        if (input.status == .working || input.status == .tool),
           let segment = input.workSegmentStart,
           segment.isFinite, segment >= 0 {
            resolvedIdentity = PetWorkPoseIdentity(sessionId: input.sessionId ?? "", workSegmentStart: segment)
        } else {
            resolvedIdentity = nil
        }
        if resolvedIdentity != identity {
            identity = resolvedIdentity
            contextChanged = true
            enterDormant()
        }

        if input.interactionIsActive {
            beginInteraction(at: now)
        } else {
            endInteraction(at: now)
        }

        // Any hint, priority state, reduced motion or invisible window stops the autonomous
        // layers entirely. Reduced motion keeps real feedback, it only drops decoration.
        let suppressed = input.hint != nil || input.hasPriorityState || !input.allowsAutonomousRotation

        switch input.status {
        case .tool:
            if suppressed {
                if mode != .dormant {
                    enterDormant()
                    contextChanged = true
                }
            } else if mode != .tool || toolPose != input.realPose {
                toolPose = input.realPose
                toolEnteredAt = now
                gracePose = nil
                graceEndsAt = nil
                cycleStartedAt = nil
                phases = []
                mode = .tool
                contextChanged = true
            }

        case .working:
            if suppressed {
                if mode != .dormant {
                    enterDormant()
                    contextChanged = true
                }
            } else if let pose = toolPose, let enteredAt = toolEnteredAt {
                // A direct `.tool` → `.working` return: keep the observed pose briefly.
                // Repeated working heartbeats never extend this window.
                let endsAt = max(enteredAt + Self.toolMinimumVisible, now + Self.toolReturnGrace)
                gracePose = pose
                graceEndsAt = endsAt
                toolPose = nil
                toolEnteredAt = nil
                cycleStartedAt = nil
                phases = []
                mode = .grace
                contextChanged = true
            } else if mode == .grace, let endsAt = graceEndsAt, now >= endsAt {
                enterDormant()
                contextChanged = true
            }

            if mode == .dormant, !suppressed, let workPoses, workPoses.supportsRhythm {
                phases = Self.phases(for: workPoses)
                thinkingPose = workPoses.thinking
                cycleStartedAt = now
                mode = .rhythm
                contextChanged = true
            }

        case .idle, .success, .error:
            if mode != .dormant || toolPose != nil || graceEndsAt != nil {
                enterDormant()
                contextChanged = true
            }
        }

        if contextChanged {
            generation = generation == UInt64.max ? 0 : generation + 1
        }
        lastObservedAt = now
        return tick(at: now)
    }

    /// Timer-driven re-evaluation with no new source state. A tick carrying an
    /// identity/generation that no longer matches is discarded without touching pose,
    /// phase or deadlines, so a queued old callback can only spin empty.
    @discardableResult
    public mutating func advance(
        identity expectedIdentity: PetWorkPoseIdentity?,
        generation expectedGeneration: UInt64,
        at time: TimeInterval
    ) -> PetWorkPoseSchedulerTick {
        guard matches(identity: expectedIdentity, generation: expectedGeneration) else {
            return .invalidated
        }
        let now = normalizedTime(time)
        if mode == .grace, let endsAt = graceEndsAt, now >= endsAt {
            enterDormant()
            if let latestWorkPoses, latestWorkPoses.supportsRhythm {
                phases = Self.phases(for: latestWorkPoses)
                thinkingPose = latestWorkPoses.thinking
                cycleStartedAt = now
                mode = .rhythm
            }
            generation = generation == UInt64.max ? 0 : generation + 1
        }
        lastObservedAt = now
        return tick(at: now)
    }

    /// Current target without changing state; used by renderers that only read.
    public func currentPose(at time: TimeInterval) -> String? {
        let now = max(normalizedTime(time), lastObservedAt ?? 0)
        switch mode {
        case .dormant, .tool:
            return nil
        case .grace:
            guard let gracePose, let graceEndsAt, now < graceEndsAt else { return nil }
            return gracePose
        case .rhythm:
            return phase(at: now)?.pose ?? thinkingPose
        }
    }

    /// One-shot deadline for the merged wake timer. `nil` while paused, hidden, reduced
    /// motion, observing a tool, or already settled.
    public func nextDeadline(after time: TimeInterval) -> TimeInterval? {
        let now = max(normalizedTime(time), lastObservedAt ?? 0)
        switch mode {
        case .dormant, .tool:
            return nil
        case .grace:
            guard let graceEndsAt, graceEndsAt > now else { return nil }
            return graceEndsAt
        case .rhythm:
            guard pauseStartedAt == nil,
                  let cycleStartedAt,
                  !phases.isEmpty else { return nil }
            let cycle = Self.cycleDuration(phases)
            guard cycle > 0 else { return nil }
            let elapsed = max(0, now - cycleStartedAt)
            let completedCycles = (elapsed / cycle).rounded(.down)
            var cursor = cycleStartedAt + completedCycles * cycle
            for phase in phases {
                cursor += phase.duration
                if cursor > now { return cursor }
            }
            return cursor + cycle
        }
    }

    /// Rebuilds the cycle for a different character's artwork while keeping the same work
    /// segment identity. Changing outfit inside one session is not a new work segment, so
    /// the work clock and its fatigue accounting stay untouched; only the display phases
    /// restart from base thinking.
    @discardableResult
    public mutating func rebuildRhythm(workPoses: PetWorkPoseSet?, at time: TimeInterval) -> PetWorkPoseSchedulerTick {
        let now = normalizedTime(time)
        guard mode == .rhythm else {
            lastObservedAt = now
            return tick(at: now)
        }
        guard let workPoses, workPoses.supportsRhythm else {
            enterDormant()
            generation = generation == UInt64.max ? 0 : generation + 1
            lastObservedAt = now
            return tick(at: now)
        }
        phases = Self.phases(for: workPoses)
        thinkingPose = workPoses.thinking
        cycleStartedAt = now
        generation = generation == UInt64.max ? 0 : generation + 1
        lastObservedAt = now
        return tick(at: now)
    }

    private mutating func enterDormant() {
        mode = .dormant
        cycleStartedAt = nil
        phases = []
        pauseStartedAt = nil
        toolPose = nil
        toolEnteredAt = nil
        gracePose = nil
        graceEndsAt = nil
    }

    private func tick(at now: TimeInterval) -> PetWorkPoseSchedulerTick {
        PetWorkPoseSchedulerTick(
            pose: currentPose(at: now),
            generation: generation,
            identity: identity,
            nextDeadline: nextDeadline(after: now),
            discardedStaleTick: false
        )
    }

    private func phase(at now: TimeInterval) -> Phase? {
        guard !phases.isEmpty, let cycleStartedAt else { return nil }
        let effectiveNow = pauseStartedAt ?? now
        let elapsed = max(0, effectiveNow - cycleStartedAt)
        let cycle = Self.cycleDuration(phases)
        guard cycle > 0 else { return nil }
        var offset = elapsed.truncatingRemainder(dividingBy: cycle)
        for phase in phases {
            if offset < phase.duration { return phase }
            offset -= phase.duration
        }
        return phases.last
    }

    /// Builds the cycle, dropping a stage that would repeat the pose already on screen and
    /// a trailing stage that would repeat the pose the cycle restarts with.
    public static func phases(for workPoses: PetWorkPoseSet) -> [Phase] {
        let slots: [(String, TimeInterval)] = [
            (workPoses.thinking, thinkingHold),
            (workPoses.busyLeft, busyLeftHold),
            (workPoses.thinkingVariant, thinkingVariantHold),
            (workPoses.busyRight, busyRightHold),
        ]
        var built: [Phase] = []
        for slot in slots where slot.0 != built.last?.pose {
            built.append(Phase(pose: slot.0, duration: slot.1))
        }
        while built.count > 1, built.last?.pose == built.first?.pose {
            built.removeLast()
        }
        return built
    }

    private static func cycleDuration(_ phases: [Phase]) -> TimeInterval {
        phases.reduce(0) { $0 + $1.duration }
    }

    private func normalizedTime(_ time: TimeInterval) -> TimeInterval {
        let safe = time.isFinite ? max(0, time) : 0
        return max(safe, lastObservedAt ?? safe)
    }
}
