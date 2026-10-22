import AppKit
import Foundation

// Offscreen render probe for the double-click basin pile.
//
// The pile is painted with the same `PetBasinRenderer` the pet view uses — the shipped
// basin artwork and the vector fallback — over a real decoded pose, into an
// NSBitmapImageRep. The numbers below come from painted pixels, not from arithmetic, and
// the PNGs are written to .build/pose-basin-render/ so the result can be looked at.
@main
struct PoseBasinRenderChecks {
    private static var checks = 0

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            fail("usage: PoseBasinRenderChecks <assets-dir> <basin.png>")
        }
        let assets = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let basinImage = NSImage(contentsOf: URL(fileURLWithPath: arguments[2]))
        check(basinImage != nil, "the shipped basin artwork decodes")

        let catalog = try PetArtworkCatalog(directoryURL: assets)
        let layout = PetCharacterLayout(maximumAspectRatio: catalog.maximumAspectRatio)
        let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/pose-basin-render", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let pose = try loadPose(assets.appendingPathComponent("claude/idle.webp"))
        let artworkRect = layout.imageRect(
            containerWidth: layout.windowSize.width,
            sourceWidth: Double(pose.width),
            sourceHeight: Double(pose.height)
        )
        let artworkTop = layout.bottomInset + layout.displayHeight
        let headTopRow = Int((layout.windowSize.height - artworkTop).rounded())
        let config = PetBasinConfig.fallback
        let baseCenter = center(for: config, layout: layout, artworkTop: artworkTop)

        var empty = PetBasinStack()
        let emptyShot = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                              placements: empty.placements(at: 0, reduceMotion: true),
                              baseCenter: baseCenter, basin: basinImage, config: config)
        check(abs(topmostOpaqueRow(emptyShot, above: 0) - headTopRow) <= 2,
              "an empty pile paints nothing above the head")

        var one = PetBasinStack()
        one.add(at: 0)
        let oneShot = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                            placements: one.placements(at: 10, reduceMotion: true),
                            baseCenter: baseCenter, basin: basinImage, config: config)
        write(oneShot, to: outputDirectory.appendingPathComponent("one-basin.png"))
        let oneTop = topmostOpaqueRow(oneShot, above: 0)
        let expectedOneTop = row(for: artworkTop + PetBasinStack.pileTopRise(count: 1, config: config), layout: layout)
        check(abs(oneTop - expectedOneTop) <= 3, "one basin is painted on the crown, inside the window")
        check(oneTop <= headTopRow, "one basin covers the crown instead of floating above it")

        var pile = PetBasinStack()
        for index in 0..<PetBasinStack.maxCount {
            pile.add(at: Double(index))
        }
        let settledPile = pile.placements(at: 100, reduceMotion: true)
        check(settledPile.count == PetBasinStack.maxCount, "the pile holds ten basins")
        let pileShot = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                             placements: settledPile, baseCenter: baseCenter, basin: basinImage, config: config)
        write(pileShot, to: outputDirectory.appendingPathComponent("ten-basins.png"))

        let pileTop = topmostOpaqueRow(pileShot, above: 0)
        check(pileTop > 0, "a full pile is not clipped by the window's top edge")
        let expectedPileTop = row(for: artworkTop + PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: config), layout: layout)
        check(abs(pileTop - expectedPileTop) <= 3,
              "the painted pile top matches the reserved geometry (\(pileTop) vs \(expectedPileTop))")

        // The pile has to be worn, not hovered: down the middle column the paint must go
        // basin → hair without a transparent strip, and the hand-over has to happen at the
        // rim depth the config promises.
        let handOver = firstHairRowBelowBasin(pileShot, x: Int(layout.windowSize.width / 2))
        let expectedHandOver = headTopRow + Int(config.yOffset.rounded())
        check(abs(handOver - expectedHandOver) <= 12,
              "the pile's rim meets the hair at the configured depth (\(handOver) vs \(expectedHandOver))")
        check(handOver > headTopRow, "the basin covers the crown instead of hanging above it")

        // The bubble gap must stay clear so a notice never lands on the pile.
        let bubbleInset = (layout.windowSize.height - artworkTop) - PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: config)
        check(bubbleInset >= PetBasinStack.bubbleGap - 1,
              "the bubble keeps its gap above a full pile")

        // The drop starts above the slot and lands on it; both frames must be painted.
        var dropping = PetBasinStack()
        dropping.add(at: 0)
        let airborne = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                             placements: dropping.placements(at: PetBasinStack.fadeInDuration, reduceMotion: false),
                             baseCenter: baseCenter, basin: basinImage, config: config)
        let landed = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                           placements: dropping.placements(at: PetBasinStack.dropDuration, reduceMotion: false),
                           baseCenter: baseCenter, basin: basinImage, config: config)
        check(topmostOpaqueRow(airborne, above: 0) < topmostOpaqueRow(landed, above: 0),
              "the falling basin is painted above its final slot")
        check(abs(topmostOpaqueRow(landed, above: 0) - expectedOneTop) <= 3, "the landed basin sits on the head line")

        // The fallback must draw the same footprint when the artwork cannot be loaded.
        let fallbackShot = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                                 placements: settledPile, baseCenter: baseCenter, basin: nil, config: config)
        write(fallbackShot, to: outputDirectory.appendingPathComponent("ten-basins-fallback.png"))
        check(abs(topmostOpaqueRow(fallbackShot, above: 0) - pileTop) <= 3,
              "the vector fallback occupies the same pile footprint")
        check(opaquePixels(fallbackShot, in: topBasinRect(layout: layout, artworkTop: artworkTop, count: PetBasinStack.maxCount, config: config)) > 0,
              "the vector fallback paints a visible basin")

        // The pile must actually be metal, not a hole: sample the middle of the top basin.
        let sample = topBasinRect(layout: layout, artworkTop: artworkTop, count: PetBasinStack.maxCount, config: config)
        let color = colorAt(pileShot, x: Int(sample.midX), yAppKit: Int(sample.midY))
        check(color != nil && (color?.alphaComponent ?? 0) > 0.8, "the top basin is opaque")
        if let color = color?.usingColorSpace(.sRGB) {
            let spread = max(color.redComponent, color.greenComponent, color.blueComponent)
                - min(color.redComponent, color.greenComponent, color.blueComponent)
            check(spread < 0.25, "the basin reads as cool grey metal, not a saturated colour")
        }

        // The horizontal offset has to move the painted pile, not just the geometry.
        let shifted = PetBasinConfig(width: config.width, xOffset: 20, yOffset: config.yOffset).clamped()
        let shiftedShot = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                                placements: settledPile,
                                baseCenter: center(for: shifted, layout: layout, artworkTop: artworkTop),
                                basin: basinImage, config: shifted)
        write(shiftedShot, to: outputDirectory.appendingPathComponent("x-offset-20.png"))
        let shiftedCenter = basinHorizontalCenter(shiftedShot,
                                                 top: artworkTop + PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: shifted) - PetBasinStack.height(shifted),
                                                 height: PetBasinStack.height(shifted))
        let neutralCenter = basinHorizontalCenter(pileShot,
                                                 top: artworkTop + PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: config) - PetBasinStack.height(config),
                                                 height: PetBasinStack.height(config))
        check(abs((shiftedCenter - neutralCenter) - 20) <= 2,
              "the x offset moves the painted pile by the configured amount (\(shiftedCenter - neutralCenter))")

        // Every config the debug sliders can produce must fit the window, keep the rim on the
        // head and stay inside the reserved room.
        let sweep = [
            PetBasinConfig(width: 60, xOffset: 0, yOffset: 30),
            PetBasinConfig(width: 92, xOffset: 0, yOffset: 30),
            PetBasinConfig(width: 120, xOffset: 0, yOffset: 30),
            PetBasinConfig(width: 120, xOffset: -30, yOffset: 10),
            PetBasinConfig(width: 92, xOffset: 25, yOffset: 60),
        ]
        for candidate in sweep {
            let clamped = candidate.clamped()
            let shot = paint(layout: layout, pose: pose, artworkRect: artworkRect,
                             placements: settledPile,
                             baseCenter: center(for: clamped, layout: layout, artworkTop: artworkTop),
                             basin: basinImage, config: clamped)
            let name = String(format: "config-w%.0f-x%.0f-y%.0f.png", clamped.width, clamped.xOffset, clamped.yOffset)
            write(shot, to: outputDirectory.appendingPathComponent(name))
            let top = topmostOpaqueRow(shot, above: 0)
            check(top > 0, "a full pile fits at \(name)")
            let expectedTop = row(for: artworkTop + PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: clamped), layout: layout)
            check(abs(top - expectedTop) <= 3, "the pile top follows the config at \(name)")
            let hand = firstHairRowBelowBasin(shot, x: Int(layout.windowSize.width / 2 + clamped.xOffset))
            let expectedHand = headTopRow + Int(clamped.yOffset.rounded())
            check(abs(hand - expectedHand) <= 14, "the rim still meets the head at \(name) (\(hand) vs \(expectedHand))")
            let width = PetBasinStack.width(clamped)
            check(width <= layout.windowSize.width - 2 * layout.horizontalInset + 1,
                  "the basin fits the window width at \(name)")
            check(abs(clamped.xOffset) + width / 2 <= layout.windowSize.width / 2,
                  "a shifted basin stays inside the window at \(name)")
        }

        // The tuned per-character configs must all land on their own character: the pile has
        // to fit the window, the rim has to meet the head at the configured depth and the
        // horizontal offset has to stay inside the window.
        for roleId in ["claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"] {
            guard let roleFrame = catalog.frame(characterID: roleId, poseName: "idle") else {
                fail("the catalog must list idle for \(roleId)")
            }
            let roleRect = layout.imageRect(
                containerWidth: layout.windowSize.width,
                sourceWidth: Double(roleFrame.width),
                sourceHeight: Double(roleFrame.height)
            )
            let roleConfig = PetBasinStack.config(for: roleId).clamped()
            let shot = paint(layout: layout, pose: roleFrame.image, artworkRect: roleRect,
                             placements: settledPile,
                             baseCenter: center(for: roleConfig, layout: layout, artworkTop: artworkTop),
                             basin: basinImage, config: roleConfig)
            write(shot, to: outputDirectory.appendingPathComponent("role-\(roleId).png"))
            let top = topmostOpaqueRow(shot, above: 0)
            check(top > 0, "\(roleId): a full pile fits the window")
            let expectedTop = row(for: artworkTop + PetBasinStack.pileTopRise(count: PetBasinStack.maxCount, config: roleConfig), layout: layout)
            check(abs(top - expectedTop) <= 3, "\(roleId): the pile top matches its config (\(top) vs \(expectedTop))")
            // The saturation-based hand-over probe only works on warm-haired characters
            // (gpt's white hair is desaturated), so for the per-role sweep it is reported
            // rather than asserted; the depth contract is asserted on claude above.
            let hand = firstHairRowBelowBasin(shot, x: Int(layout.windowSize.width / 2 + roleConfig.xOffset))
            let expectedHand = headTopRow + Int(roleConfig.yOffset.rounded())
            let roleWidth = PetBasinStack.width(roleConfig)
            check(abs(roleConfig.xOffset) + roleWidth / 2 <= layout.windowSize.width / 2,
                  "\(roleId): the shifted basin stays inside the window")
            print(String(format: "  %@: %.2f x %.2f (x %.2f, y %.2f) top=%d handOver=%d expected=%d",
                         roleId, roleConfig.width, PetBasinStack.height(roleConfig), roleConfig.xOffset, roleConfig.yOffset,
                         top, hand, expectedHand))
        }

        // The dangling pick-up frames must be fitted by their visible content: the character
        // stays the same size as when idle and its head stays on the artwork line, so the
        // pile keeps sitting on it while the user holds the pet.
        guard let pickUpFrame = catalog.frame(characterID: "claude", poseName: "picked-up") else {
            fail("the catalog must list the pick-up frame")
        }
        let pickUpRect = layout.contentFittedImageRect(
            containerWidth: layout.windowSize.width,
            frameWidth: Double(pickUpFrame.width),
            frameHeight: Double(pickUpFrame.height),
            contentTop: Double(pickUpFrame.contentTop),
            contentHeight: Double(pickUpFrame.contentHeight)
        )
        let pickUpBare = paint(layout: layout, pose: pickUpFrame.image, artworkRect: pickUpRect,
                               placements: [], baseCenter: baseCenter, basin: basinImage, config: config)
        write(pickUpBare, to: outputDirectory.appendingPathComponent("picked-up.png"))
        let pickUpTop = topmostOpaqueRow(pickUpBare, above: 0)
        check(abs(pickUpTop - headTopRow) <= 3, "the picked-up character's head stays on the artwork line")
        let pickUpBottom = bottommostOpaqueRow(pickUpBare)
        let idleBottom = bottommostOpaqueRow(emptyShot)
        check(pickUpBottom - pickUpTop >= idleBottom - headTopRow - 2,
              "the picked-up character is drawn at least as tall as the idle one")
        let pickUpPile = paint(layout: layout, pose: pickUpFrame.image, artworkRect: pickUpRect,
                               placements: settledPile, baseCenter: baseCenter, basin: basinImage, config: config)
        write(pickUpPile, to: outputDirectory.appendingPathComponent("picked-up-with-pile.png"))
        let pickUpHandOver = firstHairRowBelowBasin(pickUpPile, x: Int(layout.windowSize.width / 2))
        check(abs(pickUpHandOver - expectedHandOver) <= 12,
              "the pile still meets the head while the character is held")

        print("PoseBasinRenderProbe: \(checks) checks passed. Images: .build/pose-basin-render/")
    }

    // MARK: - Painting

    private struct Shot {
        let rep: NSBitmapImageRep
        let width: Int
        let height: Int
    }

    private static func center(for config: PetBasinConfig, layout: PetCharacterLayout, artworkTop: Double) -> NSPoint {
        NSPoint(
            x: layout.windowSize.width / 2 + config.xOffset,
            y: artworkTop - PetBasinStack.baseCenterOffsetBelowArtworkTop(config)
        )
    }

    private static func row(for y: Double, layout: PetCharacterLayout) -> Int {
        Int((layout.windowSize.height - y).rounded(.down))
    }

    private static func paint(
        layout: PetCharacterLayout,
        pose: CGImage,
        artworkRect: PetPoseRect,
        placements: [PetBasinPlacement],
        baseCenter: NSPoint,
        basin: NSImage?,
        config: PetBasinConfig
    ) -> Shot {
        let width = Int(layout.windowSize.width.rounded())
        let height = Int(layout.windowSize.height.rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("could not allocate a bitmap") }
        rep.size = NSSize(width: layout.windowSize.width, height: layout.windowSize.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        let image = NSImage(cgImage: pose, size: NSSize(width: pose.width, height: pose.height))
        image.draw(
            in: NSRect(x: artworkRect.x, y: artworkRect.y, width: artworkRect.width, height: artworkRect.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil
        )
        PetBasinRenderer.draw(placements, baseCenter: baseCenter, image: basin, config: config)
        NSGraphicsContext.restoreGraphicsState()
        return Shot(rep: rep, width: width, height: height)
    }

    private static func topBasinRect(layout: PetCharacterLayout, artworkTop: Double, count: Int, config: PetBasinConfig) -> NSRect {
        let width = PetBasinStack.width(config)
        let height = PetBasinStack.height(config)
        let top = artworkTop + PetBasinStack.pileTopRise(count: count, config: config)
        return NSRect(
            x: (layout.windowSize.width - width) / 2 + config.xOffset,
            y: top - height,
            width: width,
            height: height
        )
    }

    // MARK: - Pixel readback

    /// Topmost row (bitmap coordinates, y down) that has an opaque pixel, searching only
    /// above the head line so the character itself never answers for the pile.
    private static func topmostOpaqueRow(_ shot: Shot, above minimumRow: Int) -> Int {
        let minimum = max(0, minimumRow)
        for row in minimum..<shot.height {
            for x in 0..<shot.width {
                if (shot.rep.colorAt(x: x, y: row)?.alphaComponent ?? 0) > 0.5 { return row }
            }
        }
        return shot.height
    }

    /// Bottommost row (bitmap coordinates, y down) that has an opaque pixel.
    private static func bottommostOpaqueRow(_ shot: Shot) -> Int {
        for row in stride(from: shot.height - 1, through: 0, by: -1) {
            for x in 0..<shot.width {
                if (shot.rep.colorAt(x: x, y: row)?.alphaComponent ?? 0) > 0.5 { return row }
            }
        }
        return 0
    }

    /// Horizontal centre of the paint inside one row band, in points.
    private static func basinHorizontalCenter(_ shot: Shot, top: Double, height: Double) -> Double {
        let topRow = max(0, Int((Double(shot.height) - top).rounded(.down)))
        let bottomRow = min(shot.height - 1, Int((Double(shot.height) - (top - height)).rounded(.up)))
        guard bottomRow >= topRow else { return 0 }
        var minimum = shot.width
        var maximum = -1
        for row in topRow...bottomRow {
            for x in 0..<shot.width where (shot.rep.colorAt(x: x, y: row)?.alphaComponent ?? 0) > 0.5 {
                minimum = min(minimum, x)
                maximum = max(maximum, x)
            }
        }
        guard maximum >= minimum else { return 0 }
        return Double(minimum + maximum) / 2
    }

    private static func opaquePixels(_ shot: Shot, in rect: NSRect) -> Int {
        var count = 0
        for row in Int(rect.minY)..<min(shot.height, Int(rect.maxY.rounded(.up))) where row >= 0 {
            for x in Int(rect.minX)..<min(shot.width, Int(rect.maxX.rounded(.up))) where x >= 0 {
                if (shot.rep.colorAt(x: x, y: row)?.alphaComponent ?? 0) > 0.5 { count += 1 }
            }
        }
        return count
    }

    /// Walks down one column and returns the first row where the hair shows through after
    /// the metal: the basin is desaturated, the character's hair is warm. A transparent strip
    /// in between would leave the basin looking like it hovers, so the caller asserts the
    /// hand-over happens at the depth the config promises.
    private static func firstHairRowBelowBasin(_ shot: Shot, x: Int) -> Int {
        guard x >= 0, x < shot.width else { return shot.height }
        var sawBasin = false
        for row in 0..<shot.height {
            guard let color = shot.rep.colorAt(x: x, y: row)?.usingColorSpace(.sRGB), color.alphaComponent > 0.5 else {
                continue
            }
            let maximum = max(color.redComponent, max(color.greenComponent, color.blueComponent))
            let minimum = min(color.redComponent, min(color.greenComponent, color.blueComponent))
            let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
            if saturation < 0.20 {
                sawBasin = true
            } else if sawBasin {
                return row
            }
        }
        return shot.height
    }

    private static func colorAt(_ shot: Shot, x: Int, yAppKit: Int) -> NSColor? {
        let row = shot.height - 1 - yAppKit
        guard row >= 0, row < shot.height, x >= 0, x < shot.width else { return nil }
        return shot.rep.colorAt(x: x, y: row)
    }

    private static func write(_ shot: Shot, to url: URL) {
        guard let data = shot.rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }

    // MARK: - Helpers

    private static func loadPose(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "PoseBasinRender", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot decode \(url.path)"])
        }
        return image
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("PROBE FAILED: " + message + "\n").utf8))
        exit(1)
    }
}
