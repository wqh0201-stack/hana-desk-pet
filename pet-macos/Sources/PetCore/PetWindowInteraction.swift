import Foundation

/// Window-level event policy. A cursor over the character or an active interaction keeps
/// the panel receptive; otherwise the caller can enable NSWindow.ignoresMouseEvents.
public struct PetWindowEventPolicy: Equatable, Sendable {
    private var pointerSequenceActive = false
    private var menuTrackingDepth = 0

    public init() {}

    public var isInteractionHeld: Bool {
        pointerSequenceActive || menuTrackingDepth > 0
    }

    public mutating func beginPointerSequence() {
        pointerSequenceActive = true
    }

    public mutating func endPointerSequence() {
        pointerSequenceActive = false
    }

    public mutating func cancelPointerSequence() {
        pointerSequenceActive = false
    }

    public mutating func reset() {
        pointerSequenceActive = false
        menuTrackingDepth = 0
    }

    public mutating func menuDidOpen() {
        menuTrackingDepth += 1
    }

    public mutating func menuDidClose() {
        menuTrackingDepth = max(0, menuTrackingDepth - 1)
    }

    public func ignoresMouseEvents(pointerIsOnCharacter: Bool) -> Bool {
        !isInteractionHeld && !pointerIsOnCharacter
    }
}

/// The single motion transform shared by AppKit drawing and hit testing.
/// Coordinates are view-local points in a y-up AppKit coordinate system.
public struct PetCharacterMotion: Equatable, Sendable {
    public let center: PetPointerPoint
    public let bobY: Double
    public let scale: Double
    public let rotationDegrees: Double

    public init(
        width: Double,
        height: Double,
        phase: Double,
        reactionProgress: Double?,
        isError: Bool,
        anchor: PetPointerPoint? = nil
    ) {
        center = anchor ?? PetPointerPoint(x: width / 2, y: height / 2)
        bobY = sin(phase) * 4
        if let reactionProgress {
            let boundedProgress = min(1, max(0, reactionProgress))
            scale = 1 + sin(boundedProgress * 2 * Double.pi) * 0.055
        } else {
            scale = 1
        }
        rotationDegrees = isError ? sin(phase) * 4 : 0
    }

    public func applying(to point: PetPointerPoint) -> PetPointerPoint {
        let radians = rotationDegrees * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let x = (point.x - center.x) * scale
        let y = (point.y - center.y) * scale
        return PetPointerPoint(
            x: center.x + x * cosine - y * sine,
            y: center.y + x * sine + y * cosine + bobY
        )
    }

    public func unapplying(to point: PetPointerPoint) -> PetPointerPoint {
        let radians = -rotationDegrees * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let x = point.x - center.x
        let y = point.y - center.y - bobY
        return PetPointerPoint(
            x: center.x + (x * cosine - y * sine) / scale,
            y: center.y + (x * sine + y * cosine) / scale
        )
    }
}
