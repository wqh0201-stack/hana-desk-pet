import Foundation

public struct PetPoseLayer: Equatable, Sendable {
    public let poseName: String
    public let opacity: Double

    public init(poseName: String, opacity: Double) {
        self.poseName = poseName
        self.opacity = opacity
    }
}

public struct PetPoseSize: Equatable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct PetPoseRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// Shared, deterministic geometry for the artwork, its hit mask, and the floating window.
public struct PetCharacterLayout: Equatable, Sendable {
    public let maximumAspectRatio: Double
    public let displayHeight: Double
    public let bottomInset: Double
    public let horizontalInset: Double
    public let windowSize: PetPoseSize

    public init(maximumAspectRatio: Double) {
        let safeAspectRatio = maximumAspectRatio.isFinite
            ? max(0.1, maximumAspectRatio)
            : 0.75
        let height = 176.0
        let scale = 1.055
        let radians = 4.0 * Double.pi / 180.0
        let cosine = cos(radians)
        let sine = sin(radians)
        let maximumWidth = height * safeAspectRatio
        let halfWidth = maximumWidth / 2
        let sideInset = 10.0
        let bottom = ceil(scale * halfWidth * sine + 8)
        let top = ceil(max(18, scale * (height * cosine + halfWidth * sine) - height + 8))
        let rotatedWidth = scale * (maximumWidth * cosine + height * sine)

        self.maximumAspectRatio = safeAspectRatio
        self.displayHeight = height
        self.bottomInset = bottom
        self.horizontalInset = sideInset
        self.windowSize = PetPoseSize(
            width: ceil(rotatedWidth + 2 * sideInset),
            height: ceil(height + bottom + top)
        )
    }

    /// Keeps every catalog pose at the same natural height and foot line. If a corrupt or
    /// stale aspect-ratio header exceeds the catalog bound, fit within the reserved width.
    public func imageRect(
        containerWidth: Double,
        sourceWidth: Double,
        sourceHeight: Double
    ) -> PetPoseRect {
        guard containerWidth.isFinite, sourceWidth > 0, sourceHeight > 0 else {
            return PetPoseRect(x: 0, y: bottomInset, width: 0, height: 0)
        }
        let availableWidth = max(0, containerWidth - 2 * horizontalInset)
        let scale = min(displayHeight / sourceHeight, availableWidth / sourceWidth)
        let width = sourceWidth * scale
        let height = sourceHeight * scale
        return PetPoseRect(
            x: (containerWidth - width) / 2,
            y: bottomInset,
            width: width,
            height: height
        )
    }

    public var artworkAnchor: PetPosePoint {
        PetPosePoint(x: windowSize.width / 2, y: bottomInset)
    }
}

public struct PetPosePoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Deterministic pose scheduling and interruptible opacity cross-fades.
/// It contains no image or UI framework dependencies, so timing can be tested directly.
public struct PetPoseTimeline: Sendable {
    private static let crossfadeDuration = 0.20
    private static let reducedMotionCrossfadeDuration = 0.08
    private static let idleIntervals = [5.8, 6.6, 5.4, 7.2]
    private static let blinkDuration = 0.18
    private static let maximumSourceLayers = 3

    private var isInitialized = false
    private var status: PetActivityStatus = .idle
    private var hint: PetActivityHint?
    private var basePose = "idle"
    private var availablePoseNames: Set<String> = ["idle"]
    private var reduceMotion = false
    private var allowsIdleAnimation = true

    private var idlePose: String?
    private var idleCandidateIndex = 0
    private var idleScheduleIndex = 0
    private var nextIdleAt: TimeInterval?
    private var blinkUntil: TimeInterval?

    private var reactionPose: String?
    private var reactionEndsAt: TimeInterval?

    private var settledPose = "idle"
    private var transitionSource: [PetPoseLayer] = []
    private var transitionTarget: String?
    private var transitionStartedAt: TimeInterval = 0
    private var transitionDuration = Self.crossfadeDuration

    public init(initialPose: String = "idle") {
        settledPose = initialPose
    }

    public var isTransitioning: Bool {
        transitionTarget != nil
    }

    public var hasActiveReaction: Bool {
        reactionEndsAt != nil
    }

    /// Updates the latest source state. A changed state cancels any temporary tap reaction,
    /// and any new target starts from the currently visible blend rather than a stale pose.
    @discardableResult
    public mutating func update(
        status newStatus: PetActivityStatus,
        basePose newBasePose: String,
        availablePoseNames newAvailablePoseNames: [String],
        reduceMotion newReduceMotion: Bool = false,
        allowsIdleAnimation newAllowsIdleAnimation: Bool = true,
        hint newHint: PetActivityHint? = nil,
        at time: TimeInterval
    ) -> [PetPoseLayer] {
        let now = Self.safeTime(time)
        let firstUpdate = !isInitialized
        let stateChanged = status != newStatus || basePose != newBasePose || hint != newHint
        let motionPreferenceChanged = reduceMotion != newReduceMotion
        let idleAnimationChanged = allowsIdleAnimation != newAllowsIdleAnimation

        status = newStatus
        hint = newHint
        basePose = newBasePose
        availablePoseNames = Set(newAvailablePoseNames)
        reduceMotion = newReduceMotion
        allowsIdleAnimation = newAllowsIdleAnimation
        isInitialized = true

        if firstUpdate {
            settledPose = newBasePose
            resetIdleCycle(at: now, schedule: newStatus == .idle && !newReduceMotion && newAllowsIdleAnimation)
        } else if stateChanged || idleAnimationChanged {
            reactionPose = nil
            reactionEndsAt = nil
            resetIdleCycle(at: now, schedule: newStatus == .idle && !newReduceMotion && newAllowsIdleAnimation)
        } else if motionPreferenceChanged {
            if newReduceMotion {
                idlePose = nil
                nextIdleAt = nil
                blinkUntil = nil
                reactionPose = nil
                reactionEndsAt = nil
            } else if newStatus == .idle {
                scheduleNextIdle(at: now)
            }
        }

        if newStatus == .idle && !newReduceMotion && newAllowsIdleAnimation && nextIdleAt == nil && blinkUntil == nil {
            scheduleNextIdle(at: now)
        }
        if let idlePose, !availablePoseNames.contains(idlePose) {
            self.idlePose = nil
        }

        retarget(to: effectivePose, at: now)
        return advance(at: now)
    }

    /// Briefly shows a catalogued response pose (if available) without taking ownership of
    /// the underlying activity. A later state update cancels it; timeout restores latest state.
    @discardableResult
    public mutating func beginReaction(
        pose: String?,
        duration: TimeInterval = 0.52,
        at time: TimeInterval
    ) -> [PetPoseLayer] {
        let now = Self.safeTime(time)
        guard isInitialized else { return visibleLayers(at: now) }
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        reactionPose = pose
        reactionEndsAt = now + safeDuration
        retarget(to: effectivePose, at: now)
        return advance(at: now)
    }

    /// Cancels the temporary tap response at pointer-down, leaving the latest activity in control.
    @discardableResult
    public mutating func interruptReaction(at time: TimeInterval) -> [PetPoseLayer] {
        let now = Self.safeTime(time)
        guard reactionEndsAt != nil else { return advance(at: now) }
        reactionPose = nil
        reactionEndsAt = nil
        retarget(to: effectivePose, at: now)
        return advance(at: now)
    }

    /// Cancels an in-flight blend/reaction at pointer-down and settles on the latest source state.
    /// It does not clear the current activity hint; the artwork remains responsive to its alpha hit mask.
    @discardableResult
    public mutating func interruptTransition(at time: TimeInterval) -> [PetPoseLayer] {
        let now = Self.safeTime(time)
        reactionPose = nil
        reactionEndsAt = nil
        settledPose = effectivePose
        transitionTarget = nil
        transitionSource = []
        return visibleLayers(at: now)
    }

    /// Advances scheduled idle changes, temporary reactions, and cross-fades to an absolute time.
    @discardableResult
    public mutating func advance(at time: TimeInterval) -> [PetPoseLayer] {
        let now = Self.safeTime(time)

        if let reactionEndsAt, now >= reactionEndsAt {
            reactionPose = nil
            self.reactionEndsAt = nil
            retarget(to: effectivePose, at: reactionEndsAt)
        }

        if let blinkUntil, now >= blinkUntil {
            self.blinkUntil = nil
            if status == .idle && !reduceMotion && allowsIdleAnimation {
                scheduleNextIdle(at: blinkUntil)
            }
            retarget(to: effectivePose, at: blinkUntil)
        } else if let nextIdleAt, now >= nextIdleAt,
                  status == .idle, !reduceMotion, allowsIdleAnimation, reactionEndsAt == nil {
            startNextIdlePose(at: now)
        }

        retarget(to: effectivePose, at: now)
        if let target = transitionTarget,
           now >= transitionStartedAt + transitionDuration {
            settledPose = target
            transitionTarget = nil
            transitionSource = []
        }
        return visibleLayers(at: now)
    }

    public func visibleLayers(at time: TimeInterval) -> [PetPoseLayer] {
        let now = Self.safeTime(time)
        guard let target = transitionTarget else {
            return [PetPoseLayer(poseName: settledPose, opacity: 1)]
        }
        let rawProgress = transitionDuration <= 0
            ? 1
            : min(1, max(0, (now - transitionStartedAt) / transitionDuration))
        let progress = rawProgress * rawProgress * (3 - 2 * rawProgress)
        var weights: [String: Double] = [:]
        for layer in transitionSource {
            weights[layer.poseName, default: 0] += layer.opacity * (1 - progress)
        }
        weights[target, default: 0] += progress
        return Self.normalizedLayers(weights)
    }

    /// The next deadline for a one-shot wakeup. During visible animation callers should tick
    /// at no more than 30 Hz; otherwise the timer can sleep until the next idle or reaction event.
    public func nextWakeAt(after time: TimeInterval) -> TimeInterval? {
        let now = Self.safeTime(time)
        if isTransitioning {
            let end = transitionStartedAt + transitionDuration
            return min(end, now + 1.0 / 30.0)
        }
        if let reactionEndsAt { return reactionEndsAt }
        if let nextIdleAt { return nextIdleAt }
        return nil
    }

    private var effectivePose: String {
        if reactionEndsAt != nil, let reactionPose { return reactionPose }
        if status == .idle, !reduceMotion, allowsIdleAnimation {
            if blinkUntil != nil { return "idle-blink" }
            if let idlePose { return idlePose }
        }
        return basePose
    }

    private mutating func resetIdleCycle(at time: TimeInterval, schedule: Bool) {
        idlePose = nil
        idleCandidateIndex = 0
        idleScheduleIndex = 0
        blinkUntil = nil
        nextIdleAt = nil
        if schedule { scheduleNextIdle(at: time) }
    }

    private mutating func scheduleNextIdle(at time: TimeInterval) {
        guard status == .idle, !reduceMotion, allowsIdleAnimation else {
            nextIdleAt = nil
            return
        }
        let candidates = availableIdleCandidates
        guard !candidates.isEmpty else {
            nextIdleAt = nil
            return
        }
        let interval = Self.idleIntervals[idleScheduleIndex % Self.idleIntervals.count]
        nextIdleAt = time + interval
        idleScheduleIndex += 1
    }

    private mutating func startNextIdlePose(at time: TimeInterval) {
        let candidates = availableIdleCandidates
        guard !candidates.isEmpty else {
            nextIdleAt = nil
            return
        }
        let candidate = candidates[idleCandidateIndex % candidates.count]
        idleCandidateIndex += 1
        if candidate == "idle-blink" {
            blinkUntil = time + Self.blinkDuration
            nextIdleAt = blinkUntil
        } else {
            idlePose = candidate
            scheduleNextIdle(at: time)
        }
    }

    private var availableIdleCandidates: [String] {
        ["idle-2", "idle-3", "idle-blink"].filter { availablePoseNames.contains($0) }
    }

    private mutating func retarget(to pose: String, at time: TimeInterval) {
        if transitionTarget == pose { return }
        if transitionTarget == nil && settledPose == pose { return }

        let source = Self.trimmedLayers(visibleLayers(at: time), maximumCount: Self.maximumSourceLayers)
        if source.count == 1, source[0].poseName == pose, source[0].opacity >= 0.999 {
            settledPose = pose
            transitionSource = []
            transitionTarget = nil
            return
        }

        transitionSource = source
        transitionTarget = pose
        transitionStartedAt = time
        transitionDuration = reduceMotion ? Self.reducedMotionCrossfadeDuration : Self.crossfadeDuration
    }

    private static func trimmedLayers(_ layers: [PetPoseLayer], maximumCount: Int) -> [PetPoseLayer] {
        let combined = normalizedLayers(Dictionary(layers.map { ($0.poseName, $0.opacity) }, uniquingKeysWith: +))
        let retained = combined.sorted { lhs, rhs in
            if lhs.opacity == rhs.opacity { return lhs.poseName < rhs.poseName }
            return lhs.opacity > rhs.opacity
        }.prefix(max(1, maximumCount))
        let sum = retained.reduce(0) { $0 + $1.opacity }
        guard sum > 0 else { return [] }
        return retained.map { PetPoseLayer(poseName: $0.poseName, opacity: $0.opacity / sum) }
            .sorted { $0.poseName < $1.poseName }
    }

    private static func normalizedLayers(_ weights: [String: Double]) -> [PetPoseLayer] {
        let positive = weights.filter { $0.value > 0.0001 }
        let sum = positive.values.reduce(0, +)
        guard sum > 0 else { return [] }
        return positive.keys.sorted().map { key in
            PetPoseLayer(poseName: key, opacity: positive[key, default: 0] / sum)
        }
    }

    private static func safeTime(_ time: TimeInterval) -> TimeInterval {
        time.isFinite ? time : 0
    }
}
