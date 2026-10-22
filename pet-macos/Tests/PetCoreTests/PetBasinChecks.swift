import Foundation
import PetCore

/// Checks for the double-click basin pile: the pure stack model, its drop/settle/fade
/// animation, the shared window reserve and the double-click tracker. Everything runs on a
/// caller-supplied monotonic clock; nothing here touches AppKit or a real window.
enum PetBasinChecks {
    private static var checks = 0

    static func run() {
        checkDropAndSettle()
        checkStackGeometry()
        checkOverflowFadesTheBottomBasin()
        checkReducedMotion()
        checkDeadlines()
        checkWindowReserve()
        checkBasinConfig()
        checkDoubleClickTracker()
        print("PASS basin pile (\(checks) checks)")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else {
            FileHandle.standardError.write(Data("BASIN CHECK FAILED: \(message)\n".utf8))
            exit(1)
        }
    }

    private static func placement(_ list: [PetBasinPlacement], slot: Int) -> PetBasinPlacement? {
        list.first { $0.slot == slot }
    }

    // MARK: - 1. Drop and settle

    private static func checkDropAndSettle() {
        var stack = PetBasinStack()
        stack.add(at: 100)

        let firstFrame = stack.placements(at: 100, reduceMotion: false)
        expect(firstFrame.count == 1, "one click draws exactly one basin")
        expect(firstFrame[0].rise == PetBasinStack.baseDropHeight,
               "the basin starts one drop height above its slot")
        expect(firstFrame[0].opacity < 0.05, "the basin fades in instead of popping")

        let falling = stack.placements(at: 100 + PetBasinStack.dropDuration * 0.5, reduceMotion: false)
        expect(falling[0].rise > 0 && falling[0].rise < 20, "the basin is still above its slot halfway down")
        expect(falling[0].opacity > 0.9, "the basin is fully visible while falling")

        let landed = stack.placements(at: 100 + PetBasinStack.dropDuration, reduceMotion: false)
        expect(abs(landed[0].rise) < 1e-9, "the basin lands exactly on its slot")
        expect(landed[0].opacity == 1, "the landed basin is fully opaque")

        // The bounce must stay above the slot: a basin never sinks through the head.
        for step in 0...40 {
            let time = 100 + PetBasinStack.dropDuration * Double(step) / 40
            let list = stack.placements(at: time, reduceMotion: false)
            expect(list[0].rise >= -1e-9, "the drop never goes below the slot (step \(step))")
        }
    }

    // MARK: - 2. Stack geometry

    private static func checkStackGeometry() {
        var stack = PetBasinStack()
        for index in 0..<3 {
            stack.add(at: Double(index))
        }
        let settled = stack.placements(at: 10, reduceMotion: false)
        expect(stack.count == 3, "three clicks stack three basins")
        expect(settled.map(\.slot) == [0, 1, 2], "placements are listed bottom-up for draw order")
        for (index, item) in settled.enumerated() {
            expect(abs(item.rise - Double(index) * PetBasinStack.baseSpacing) < 1e-9,
                   "slot \(index) sits \(index) spacings above the head")
            expect(item.opacity == 1, "settled slot \(index) is opaque")
        }
        expect(settled.allSatisfy { $0.opacity > 0 }, "no settled basin is transparent")
    }

    // MARK: - 3. Overflow

    private static func checkOverflowFadesTheBottomBasin() {
        var stack = PetBasinStack()
        for index in 0..<PetBasinStack.maxCount {
            stack.add(at: Double(index))
        }
        expect(stack.count == PetBasinStack.maxCount, "the pile caps at the maximum count")

        stack.add(at: 20)
        expect(stack.count == PetBasinStack.maxCount, "an eleventh click keeps the pile at the cap")
        let overflowing = stack.placements(at: 20, reduceMotion: false)
        expect(overflowing.count == PetBasinStack.maxCount + 1,
               "the removed bottom basin is still drawn while it fades")
        expect(overflowing[0].opacity == 1, "the fading basin starts fully opaque")
        expect(abs(overflowing[1].rise - PetBasinStack.baseSpacing) < 1e-9,
               "the remaining pile starts one spacing high and settles down")

        let halfway = stack.placements(at: 20 + PetBasinStack.fadeOutDuration * 0.5, reduceMotion: false)
        expect(halfway[0].opacity > 0 && halfway[0].opacity < 1, "the bottom basin fades out over time")

        let after = stack.placements(at: 20 + PetBasinStack.fadeOutDuration + PetBasinStack.settleDuration, reduceMotion: false)
        expect(after.count == PetBasinStack.maxCount, "the faded basin is dropped from the draw list")
        for (index, item) in after.enumerated() {
            expect(abs(item.rise - Double(index) * PetBasinStack.baseSpacing) < 1e-9,
                   "slot \(index) rests on the head again after the pile settles")
        }

        stack.clear()
        expect(stack.count == 0, "clearing empties the pile")
        expect(stack.placements(at: 100, reduceMotion: false).isEmpty, "a cleared pile draws nothing")
        expect(stack.nextDeadline(after: 100, reduceMotion: false) == nil, "a cleared pile schedules no wake")
    }

    // MARK: - 4. Reduced motion

    private static func checkReducedMotion() {
        var stack = PetBasinStack()
        stack.add(at: 5)
        let immediate = stack.placements(at: 5, reduceMotion: true)
        expect(immediate.count == 1, "reduced motion still draws the basin")
        expect(immediate[0].rise == 0, "reduced motion skips the drop")
        expect(immediate[0].opacity == 1, "reduced motion skips the fade-in")
        expect(stack.nextDeadline(after: 5, reduceMotion: true) == nil, "reduced motion schedules no animation frame")
    }

    // MARK: - 5. Deadlines

    private static func checkDeadlines() {
        var stack = PetBasinStack()
        stack.add(at: 1)
        guard let first = stack.nextDeadline(after: 1, reduceMotion: false) else {
            expect(false, "a fresh drop schedules the next frame")
            return
        }
        expect(first > 1 && first <= 1 + PetBasinStack.frameInterval + 1e-9,
               "the drop wakes on the next animation frame")
        expect(stack.nextDeadline(after: 1 + PetBasinStack.dropDuration + PetBasinStack.settleDuration + 1,
                                 reduceMotion: false) == nil,
               "a settled pile stops asking for frames")
    }

    // MARK: - 6. Window reserve

    private static let config = PetBasinConfig.fallback

    private static func checkWindowReserve() {
        let required = PetBasinStack.requiredTopPadding(config)
        expect(required > 0, "the window reserves room for a full pile")
        let tallest = PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: config)
        expect(tallest > 0, "a full pile reaches above the artwork")
        expect(required > tallest, "the reserve also leaves the bubble gap above a full pile")
        expect(PetBasinStack.pileTopRise(count: 0, config: config) == 0, "an empty pile does not move the bubble")
        expect(PetBasinStack.pileTopRise(count: 1, config: config) > 0,
               "the first basin reaches above the artwork's top edge, covering the crown")
        expect(PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: config) <= required,
               "a full pile never outgrows the reserved room")
        expect(PetBasinStack.topReserve(artworkTopPadding: required, config: config) == 0,
               "a layout that already reserves enough adds nothing")
        expect(PetBasinStack.topReserve(artworkTopPadding: 0, config: config) == required,
               "a layout without top padding reserves the whole pile")

        let layout = PetCharacterLayout(maximumAspectRatio: 1.0)
        let artworkTopPadding = layout.windowSize.height - (layout.bottomInset + layout.displayHeight)
        let preReservePadding = artworkTopPadding - layout.basinTopReserve
        expect(abs(layout.basinTopReserve - PetBasinStack.topReserve(artworkTopPadding: preReservePadding, config: PetBasinStack.reserveConfig)) <= 1,
               "the layout reserve is the shortfall against the shared requirement")
        expect(artworkTopPadding >= PetBasinStack.requiredTopPadding(PetBasinStack.reserveConfig) - 1e-9,
               "the window keeps enough room for every config the debug panel can produce")
        expect(layout.artworkCenter.y == layout.bottomInset + layout.displayHeight / 2,
               "the artwork centre is the basin reference line")
    }

    // MARK: - 7. Per-character config

    private static func checkBasinConfig() {
        let narrow = PetBasinConfig(width: 60, xOffset: 0, yOffset: 30)
        let wide = PetBasinConfig(width: 120, xOffset: 0, yOffset: 30)
        expect(PetBasinStack.width(narrow) == 60, "the configured width is used as is")
        expect(PetBasinStack.width(wide) == 120, "a wide config keeps its width")
        expect(abs(PetBasinStack.height(narrow) - 60 / PetBasinStack.assetRatio) < 1e-9,
               "the height follows the fixed 117:47 asset ratio")
        expect(abs(PetBasinStack.height(wide) - 120 / PetBasinStack.assetRatio) < 1e-9,
               "the height is derived from the width, never stretched")
        expect(PetBasinStack.width(PetBasinConfig(width: 500, xOffset: 0, yOffset: 30)) == PetBasinStack.widthMaximum,
               "an oversized width clamps to the slider maximum")
        expect(PetBasinStack.width(PetBasinConfig(width: 10, xOffset: 0, yOffset: 30)) == PetBasinStack.widthMinimum,
               "an undersized width clamps to the slider minimum")

        let shifted = PetBasinConfig(width: 92, xOffset: 18, yOffset: 30)
        expect(shifted.clamped().xOffset == 18, "the horizontal offset survives clamping inside the range")
        expect(PetBasinConfig(width: 92, xOffset: 99, yOffset: 30).clamped().xOffset == PetBasinStack.xOffsetMaximum,
               "the horizontal offset clamps to its range")
        expect(PetBasinConfig(width: 92, xOffset: 0, yOffset: 200).clamped().yOffset == PetBasinStack.yOffsetMaximum,
               "the vertical offset clamps to its range")
        expect(PetBasinConfig(width: .nan, xOffset: .nan, yOffset: .nan).clamped().width == PetBasinStack.clampedWidth(.nan),
               "non-finite values fall back instead of trapping")

        // Deeper rim (larger y) => shorter pile above the artwork.
        let shallow = PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: PetBasinConfig(width: 92, xOffset: 0, yOffset: 10))
        let deep = PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: PetBasinConfig(width: 92, xOffset: 0, yOffset: 60))
        expect(shallow > deep, "a deeper rim leaves less pile above the artwork")
        expect(PetBasinStack.requiredTopPadding(PetBasinStack.reserveConfig) > PetBasinStack.requiredTopPadding(config),
               "the reserve config is the worst case of the slider ranges")

        // Every role has an explicit row and unknown IDs fall back instead of crashing.
        for role in ["claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"] {
            expect(PetBasinStack.characterConfigs[role] != nil, "\(role) has a built-in basin config")
        }
        expect(PetBasinStack.config(for: "unknown-role") == PetBasinConfig.fallback,
               "an unknown role uses the fallback config")
    }

    // MARK: - 8. Double click

    private static func checkDoubleClickTracker() {
        var tracker = PetDoubleClickTracker()
        expect(!tracker.register(at: 10, interval: 0.5), "the first click is a single click")
        expect(tracker.register(at: 10.3, interval: 0.5), "a second click inside the interval is a double click")
        expect(!tracker.register(at: 10.4, interval: 0.5), "a third click starts a new sequence")

        var slow = PetDoubleClickTracker()
        expect(!slow.register(at: 20, interval: 0.5), "the first click is a single click")
        expect(!slow.register(at: 20.9, interval: 0.5), "a click outside the interval is a new single click")
        expect(slow.register(at: 21.2, interval: 0.5), "the pair after a missed interval still pairs up")

        var dragged = PetDoubleClickTracker()
        expect(!dragged.register(at: 30, interval: 0.5), "the first click is a single click")
        dragged.reset()
        expect(!dragged.register(at: 30.2, interval: 0.5), "a drag between clicks breaks the pair")
        expect(dragged.register(at: 30.4, interval: 0.5), "the clicks after the drag pair with each other")

        var zero = PetDoubleClickTracker()
        expect(!zero.register(at: 40, interval: 0), "a zero interval still reports the first click as single")
        expect(zero.register(at: 40, interval: 0), "a zero interval pairs only clicks at the same instant")
        expect(!zero.register(at: 40.001, interval: 0), "a zero interval rejects a later click")
    }
}
