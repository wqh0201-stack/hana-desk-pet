import Foundation

/// Two-frame "picked up" loop shown while the character is actually being dragged.
///
/// This is a presentation-only interaction: it never touches the activity status, the
/// tool name, `lastActivityAt`, the mood tracker's continuous-work clock or any follow
/// timing. It also owns no timer of its own — the renderer merges `nextDeadline` into its
/// single one-shot wake timer, and the current frame is derived from the monotonic clock,
/// so a repeated `mouseDragged` cannot restart the loop and a stale callback cannot
/// resurrect a finished one.
public struct PetPickUpAnimation: Equatable, Sendable {
    /// First version: 160 ms per frame, i.e. one full back-and-forth in 320 ms.
    public static let frameInterval: TimeInterval = 0.16

    /// Catalog pose names, in playback order.
    public static let framePoseNames = ["picked-up", "picked-up-2"]

    private var startedAt: TimeInterval?

    public init() {}

    public var isActive: Bool { startedAt != nil }

    /// Starts the loop (or keeps the running one). A repeated call during the same drag is
    /// idempotent: the first frame's timestamp is never rewritten, so the rhythm keeps
    /// advancing instead of restarting on every pointer event.
    public mutating func begin(at time: TimeInterval) {
        guard startedAt == nil else { return }
        startedAt = Self.safeTime(time)
    }

    /// Leaves the loop. The renderer immediately falls back to the latest real state; no
    /// pre-drag snapshot is restored.
    public mutating func end() {
        startedAt = nil
    }

    /// Index into `framePoseNames` for the given time. Reduced motion pins the first frame
    /// — the pick-up still reads as `picked-up`, it just stops flapping.
    public func frameIndex(at time: TimeInterval, reduceMotion: Bool) -> Int {
        guard let startedAt else { return 0 }
        guard !reduceMotion else { return 0 }
        let elapsed = max(0, Self.safeTime(time) - startedAt)
        let step = Int((elapsed / Self.frameInterval).rounded(.down))
        return step % Self.framePoseNames.count
    }

    /// Pose to display, resolved against the character's own catalog. `nil` means this
    /// interaction does not own the artwork right now.
    public func poseName(
        at time: TimeInterval,
        availablePoseNames: [String],
        reduceMotion: Bool
    ) -> String? {
        guard isActive else { return nil }
        let available = Set(availablePoseNames)
        let ordered = Self.framePoseNames.filter { available.contains($0) }
        guard !ordered.isEmpty else { return nil }
        guard !reduceMotion else { return ordered[0] }
        return ordered[frameIndex(at: time, reduceMotion: false) % ordered.count]
    }

    /// The exact decision the renderer makes: while the loop is active it owns the artwork,
    /// otherwise the caller's real pose is shown. It takes no status or hint on purpose — a
    /// drag covers every real state (idle, work, mood, a pending hint, an error) because the
    /// user is holding the character; nothing real is lost, only deferred to the release.
    public func displayPose(
        realPose: String,
        at time: TimeInterval,
        availablePoseNames: [String],
        reduceMotion: Bool
    ) -> String {
        poseName(at: time, availablePoseNames: availablePoseNames, reduceMotion: reduceMotion) ?? realPose
    }

    /// Next frame boundary, or `nil` when the loop is off or frozen by reduced motion.
    public func nextDeadline(after time: TimeInterval, reduceMotion: Bool) -> TimeInterval? {
        guard let startedAt, !reduceMotion else { return nil }
        let now = Self.safeTime(time)
        guard now >= startedAt else { return startedAt + Self.frameInterval }
        let elapsed = now - startedAt
        let completed = (elapsed / Self.frameInterval).rounded(.down)
        let next = startedAt + (completed + 1) * Self.frameInterval
        return next > now ? next : now + Self.frameInterval
    }

    private static func safeTime(_ time: TimeInterval) -> TimeInterval {
        time.isFinite ? max(0, time) : 0
    }
}

extension PetPickUpAnimation {
    /// The single gate for entering the loop. `translation` is what
    /// `PetDragClickGesture.drag(to:)` returned: `nil` means the pointer is still a click
    /// candidate, so a press, a plain click or an AXPress never starts the loop. A locked
    /// position can never move the window, so it never starts the loop either.
    public static func shouldBeginDrag(translation: PetPointerPoint?, positionLocked: Bool) -> Bool {
        guard !positionLocked, let translation else { return false }
        return translation.x != 0 || translation.y != 0
    }
}
