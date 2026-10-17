import Foundation

public struct PetPointerPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Separates a click from a drag using a stable mouse-down origin.
/// The returned translation is always relative to that origin, so the window does not jump.
public struct PetDragClickGesture: Sendable {
    private var origin: PetPointerPoint?
    private var crossedDragThreshold = false

    public init() {}

    public mutating func begin(at point: PetPointerPoint) {
        origin = point
        crossedDragThreshold = false
    }

    /// Returns the total translation from mouse-down once the drag threshold is crossed.
    public mutating func drag(to point: PetPointerPoint, threshold: Double = 5) -> PetPointerPoint? {
        guard let origin else { return nil }
        if hasMoved(from: origin, to: point, threshold: threshold) {
            crossedDragThreshold = true
        }
        guard crossedDragThreshold else { return nil }
        return PetPointerPoint(x: point.x - origin.x, y: point.y - origin.y)
    }

    /// Returns true only for a release that remained below the drag threshold.
    public mutating func end(at point: PetPointerPoint, threshold: Double = 5) -> Bool {
        guard let origin else { return false }
        let isClick = !crossedDragThreshold && !hasMoved(from: origin, to: point, threshold: threshold)
        cancel()
        return isClick
    }

    public mutating func cancel() {
        origin = nil
        crossedDragThreshold = false
    }

    private func hasMoved(from start: PetPointerPoint, to end: PetPointerPoint, threshold: Double) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let safeThreshold = max(0, threshold)
        return dx * dx + dy * dy >= safeThreshold * safeThreshold
    }
}
