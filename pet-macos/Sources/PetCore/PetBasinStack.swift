import Foundation

/// One basin as it should be drawn right now.
///
/// `rise` is measured upwards from the base slot's centre (AppKit's y-up direction);
/// renderers on a top-down coordinate system subtract it. `slot` is the pile position
/// (0 = the basin resting on the head) and is also the draw order: a higher slot is
/// closer to the viewer and paints over the one below it.
public struct PetBasinPlacement: Equatable, Sendable {
    public let slot: Int
    public let rise: Double
    public let opacity: Double

    public init(slot: Int, rise: Double, opacity: Double) {
        self.slot = slot
        self.rise = rise
        self.opacity = opacity
    }
}

/// Per-character basin configuration.
public struct PetBasinConfig: Equatable, Sendable {
    public let width: Double
    public let xOffset: Double
    public let yOffset: Double
    
    public init(width: Double, xOffset: Double, yOffset: Double) {
        self.width = width
        self.xOffset = xOffset
        self.yOffset = yOffset
    }

    /// Clamped copy inside the debug-slider ranges.
    public func clamped() -> PetBasinConfig {
        PetBasinConfig(
            width: PetBasinStack.clampedWidth(width),
            xOffset: PetBasinStack.clampedXOffset(xOffset),
            yOffset: PetBasinStack.clampedYOffset(yOffset)
        )
    }
    
    /// Default config for characters without explicit settings. `yOffset` is measured from
    /// the artwork's top edge down to the basin's rim; it has to stay below the natural
    /// height (width / 2.49) or the crown would poke out above the basin.
    public static let fallback = PetBasinConfig(width: 92, xOffset: 0, yOffset: 30)
}

/// A pile of metal basins dropped on the character by double clicking.
///
/// This is a presentation-only interaction: it reads no activity state, writes no pose and
/// owns no timer. The renderer merges `nextDeadline` into its single wake timer and asks
/// for the placements of the current monotonic time, so a repeated click cannot restart an
/// animation and a stale callback cannot resurrect a finished one.
///
/// Geometry is per-character configurable: width, xOffset, yOffset. Height maintains the
/// original 117:47 asset ratio (~2.49:1). The window reserves room for the widest config.
public struct PetBasinStack: Equatable, Sendable {
    /// Original asset ratio (117:47 ≈ 2.49)
    public static let assetRatio: Double = 117.0 / 47.0
    
    /// Built-in per-character configs. The debug panel writes a user override on top of
    /// these; resetting drops the override and falls back to this table.
    /// Calibrated 2026-10-22 by user adjustment via the debug panel.
    public static let characterConfigs: [String: PetBasinConfig] = [
        "claude": PetBasinConfig(width: 112.66, xOffset: -3.44, yOffset: 43.39),
        "gpt": PetBasinConfig(width: 98.12, xOffset: -3.06, yOffset: 42.95),
        "deepseek": PetBasinConfig(width: 112.28, xOffset: -9.57, yOffset: 46.07),
        "gemini": PetBasinConfig(width: 107.69, xOffset: -4.59, yOffset: 41.61),
        "glm": PetBasinConfig(width: 97.36, xOffset: -3.44, yOffset: 37.59),
        "deepseek-hoodie": PetBasinConfig(width: 109.98, xOffset: -12.63, yOffset: 52.77),
        "gpt-onesie": PetBasinConfig(width: 112.66, xOffset: -5.36, yOffset: 42.50),
    ]

    /// Worst case across the slider ranges: the window reserves for this so dragging the
    /// debug sliders can never clip the pile or resize the window.
    public static let reserveConfig = PetBasinConfig(
        width: widthMaximum,
        xOffset: 0,
        yOffset: yOffsetMinimum
    )
    
    /// Vertical distance between two nested basins in the pile.
    public static let baseSpacing: Double = 7
    public static let maxCount = 10
    
    /// Range for debug sliders
    public static let widthMinimum: Double = 60
    public static let widthMaximum: Double = 120
    public static let xOffsetMinimum: Double = -30
    public static let xOffsetMaximum: Double = 30
    public static let yOffsetMinimum: Double = 10
    public static let yOffsetMaximum: Double = 80

    public static let baseDropHeight: Double = 20
    public static let dropDuration: TimeInterval = 0.42
    public static let fadeInDuration: TimeInterval = 0.08
    public static let settleDuration: TimeInterval = 0.18
    public static let fadeOutDuration: TimeInterval = 0.25
    public static let frameInterval: TimeInterval = 1.0 / 60.0
    public static let bubbleGap: Double = 6
    
    /// Get config for a character, falling back to default if not found.
    public static func config(for characterId: String) -> PetBasinConfig {
        characterConfigs[characterId] ?? .fallback
    }
    
    public static func clampedWidth(_ width: Double) -> Double {
        guard width.isFinite else { return PetBasinConfig.fallback.width }
        return min(widthMaximum, max(widthMinimum, width))
    }
    
    public static func clampedXOffset(_ x: Double) -> Double {
        guard x.isFinite else { return 0 }
        return min(xOffsetMaximum, max(xOffsetMinimum, x))
    }
    
    public static func clampedYOffset(_ y: Double) -> Double {
        guard y.isFinite else { return PetBasinConfig.fallback.yOffset }
        return min(yOffsetMaximum, max(yOffsetMinimum, y))
    }

    public static func width(_ config: PetBasinConfig) -> Double { clampedWidth(config.width) }
    public static func height(_ config: PetBasinConfig) -> Double { clampedWidth(config.width) / assetRatio }
    
    /// Distance from the artwork's top edge down to the centre of the first basin.
    public static func baseCenterOffsetBelowArtworkTop(_ config: PetBasinConfig) -> Double {
        clampedYOffset(config.yOffset) - height(config) / 2
    }
    
    /// How far the top of a pile reaches above the artwork's top edge.
    public static func pileTopRise(count: Int, config: PetBasinConfig) -> Double {
        guard count > 0 else { return 0 }
        let h = height(config)
        let y = clampedYOffset(config.yOffset)
        return max(0, Double(count - 1) * baseSpacing + h - y)
    }
    
    /// Room above the artwork that a full pile plus the bubble gap must have.
    public static func requiredTopPadding(_ config: PetBasinConfig) -> Double {
        pileTopRise(count: maxCount, config: config) + bubbleGap
    }
    
    /// Extra room the window must add above the artwork. The layout already reserves
    /// `artworkTopPadding` points for bobbing and rotation, so only the shortfall is added.
    public static func topReserve(artworkTopPadding: Double, config: PetBasinConfig) -> Double {
        max(0, requiredTopPadding(config) - max(0, artworkTopPadding))
    }

    private struct Entry: Equatable {
        let id: Int
        let spawnedAt: TimeInterval
    }

    private struct FadingEntry: Equatable {
        let id: Int
        let startedAt: TimeInterval
    }

    private var entries: [Entry] = []
    private var fading: [FadingEntry] = []
    private var nextID = 0
    private var shiftStartedAt: TimeInterval?
    private var shiftCount = 0

    public init() {}

    public var count: Int { entries.count }

    /// Drops one more basin. At `maxCount` the bottom basin fades out and the rest settle
    /// down one slot, so the pile keeps resting on the head instead of floating.
    public mutating func add(at time: TimeInterval) {
        let now = Self.safeTime(time)
        if entries.count >= Self.maxCount, !entries.isEmpty {
            let oldest = entries.removeFirst()
            fading.append(FadingEntry(id: oldest.id, startedAt: now))
            shiftStartedAt = now
            shiftCount = entries.count
        }
        entries.append(Entry(id: nextID, spawnedAt: now))
        nextID += 1
    }

    public mutating func clear() {
        entries.removeAll(keepingCapacity: true)
        fading.removeAll(keepingCapacity: true)
        shiftStartedAt = nil
        shiftCount = 0
    }

    /// Draw list for `time`: the fading bottom basin first, then the pile bottom-up.
    /// Expired fade entries are pruned here, so the renderer can call this every pass.
    public mutating func placements(at time: TimeInterval, reduceMotion: Bool) -> [PetBasinPlacement] {
        let now = Self.safeTime(time)
        prune(at: now)
        var result: [PetBasinPlacement] = []
        result.reserveCapacity(fading.count + entries.count)
        for fade in fading {
            let progress = Self.progress(now - fade.startedAt, Self.fadeOutDuration)
            if progress >= 1 { continue }
            result.append(PetBasinPlacement(slot: 0, rise: 0, opacity: 1 - progress))
        }
        for (index, entry) in entries.enumerated() {
            var rise = Double(index) * Self.baseSpacing
            var opacity = 1.0
            if !reduceMotion {
                let elapsed = max(0, now - entry.spawnedAt)
                if elapsed < Self.dropDuration {
                    // The basin starts above its slot and bounces into place.
                    rise += Self.baseDropHeight * (1 - Self.easeOutBounce(Self.progress(elapsed, Self.dropDuration)))
                }
                if index < shiftCount, let shiftStartedAt {
                    let settle = Self.progress(now - shiftStartedAt, Self.settleDuration)
                    if settle < 1 {
                        rise += Self.baseSpacing * (1 - Self.easeOutCubic(settle))
                    }
                }
                opacity = Self.progress(elapsed, Self.fadeInDuration)
            }
            result.append(PetBasinPlacement(slot: index, rise: rise, opacity: min(1, max(0, opacity))))
        }
        return result
    }

    /// Next frame boundary while a drop, settle or fade is running, otherwise `nil`.
    /// One frame at a time keeps the fall smooth without a second timer.
    public mutating func nextDeadline(after time: TimeInterval, reduceMotion: Bool) -> TimeInterval? {
        let now = Self.safeTime(time)
        prune(at: now)
        guard !reduceMotion else { return nil }
        var animating = !fading.isEmpty
        if !animating {
            for entry in entries where now - entry.spawnedAt < Self.dropDuration {
                animating = true
                break
            }
        }
        if !animating, shiftCount > 0, let shiftStartedAt, now - shiftStartedAt < Self.settleDuration {
            animating = true
        }
        guard animating else { return nil }
        return now + Self.frameInterval
    }

    private mutating func prune(at time: TimeInterval) {
        fading.removeAll { time - $0.startedAt >= Self.fadeOutDuration }
        if let shiftStartedAt, time - shiftStartedAt >= Self.settleDuration {
            self.shiftStartedAt = nil
            shiftCount = 0
        }
    }

    private static func safeTime(_ time: TimeInterval) -> TimeInterval {
        time.isFinite ? max(0, time) : 0
    }

    private static func progress(_ elapsed: TimeInterval, _ duration: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, elapsed / duration))
    }

    private static func easeOutCubic(_ value: Double) -> Double {
        let inverse = 1 - min(1, max(0, value))
        return 1 - inverse * inverse * inverse
    }

    /// Robert Penner's easeOutBounce: the basin decelerates in three shrinking bounces.
    private static func easeOutBounce(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        let n1 = 7.5625
        let d1 = 2.75
        if x < 1 / d1 {
            return n1 * x * x
        } else if x < 2 / d1 {
            let shifted = x - 1.5 / d1
            return n1 * shifted * shifted + 0.75
        } else if x < 2.5 / d1 {
            let shifted = x - 2.25 / d1
            return n1 * shifted * shifted + 0.9375
        }
        let shifted = x - 2.625 / d1
        return n1 * shifted * shifted + 0.984375
    }
}

/// Separates a double click from two single clicks on the character.
///
/// The caller feeds only clicks that were already classified as clicks (never a drag) and
/// passes the platform's own double-click interval, so the gesture follows the system
/// setting instead of a private constant. A completed double click is consumed, which
/// means a triple click starts a fresh sequence rather than dropping two basins.
public struct PetDoubleClickTracker: Equatable, Sendable {
    private var lastClickAt: TimeInterval?

    public init() {}

    /// Returns true when this click completes a double click.
    public mutating func register(at time: TimeInterval, interval: TimeInterval) -> Bool {
        let now = time.isFinite ? max(0, time) : 0
        let window = interval.isFinite ? max(0, interval) : 0
        if let last = lastClickAt, now >= last, now - last <= window {
            lastClickAt = nil
            return true
        }
        lastClickAt = now
        return false
    }

    public mutating func reset() {
        lastClickAt = nil
    }
}
