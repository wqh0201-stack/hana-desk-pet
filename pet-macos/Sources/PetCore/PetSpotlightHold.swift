import Foundation

/// A display-only hold for an asynchronous tool that has already returned.
///
/// The console reports *when* a drawing tool was called, never that it is still
/// running. This type turns that timestamp into a local, monotonic deadline so the
/// artwork can keep the drawing pose for a short while without pretending the
/// session is still working. It never writes status, `running` or the work clock.
public struct PetSpotlightHold: Equatable, Sendable {
    /// The agreed minimum display time for an image-generation call.
    public static let drawingHold: TimeInterval = 4

    private var lastSpotlightAt: Int64?
    private var endsAt: TimeInterval?

    public init() {}

    /// Ingests the latest spotlight marker. A marker older than its hold (for
    /// example after the pet was closed) is ignored rather than replayed.
    public mutating func update(_ spotlight: PetActivitySpotlight?, now: TimeInterval, wallNowMs: Int64) {
        guard let spotlight,
              spotlight.kind == "drawing",
              spotlight.at > 0 else {
            lastSpotlightAt = nil
            endsAt = nil
            return
        }
        guard lastSpotlightAt != spotlight.at else { return }
        lastSpotlightAt = spotlight.at
        let remaining = (Double(spotlight.at) + Self.drawingHold * 1_000 - Double(wallNowMs)) / 1_000
        if remaining > 0, remaining <= Self.drawingHold {
            endsAt = max(0, now) + remaining
        } else {
            endsAt = nil
        }
    }

    public func isActive(at now: TimeInterval) -> Bool {
        guard let endsAt else { return false }
        return max(0, now) < endsAt
    }

    public func nextDeadline(after now: TimeInterval) -> TimeInterval? {
        guard isActive(at: now), let endsAt else { return nil }
        return endsAt
    }

    public mutating func reset() {
        lastSpotlightAt = nil
        endsAt = nil
    }
}
