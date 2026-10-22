import AppKit
import PetCore

/// Paints the metal basin that a double click drops on the character.
///
/// The shipped artwork (`CrossPet/shared/basin.png`, or a per-character `basin.png`) is
/// drawn when it can be read. If it is missing or damaged, a vector basin of the same size
/// is drawn instead, so the feature degrades to a drawn basin rather than to nothing.
/// The same renderer is used by the offscreen render check.
enum PetBasinRenderer {
    private static let rimLight = NSColor(white: 0.82, alpha: 1)
    private static let rimDark = NSColor(white: 0.40, alpha: 1)
    private static let wallDark = NSColor(white: 0.33, alpha: 1)
    private static let wallLight = NSColor(white: 0.66, alpha: 1)

    /// Draws a whole pile in one pass. `baseCenter` is the centre of the first basin.
    static func draw(_ placements: [PetBasinPlacement], baseCenter: NSPoint, image: NSImage?, config: PetBasinConfig) {
        for placement in placements {
            draw(placement, baseCenter: baseCenter, image: image, config: config)
        }
    }

    static func draw(_ placement: PetBasinPlacement, baseCenter: NSPoint, image: NSImage?, config: PetBasinConfig) {
        guard placement.opacity > 0.001, let context = NSGraphicsContext.current else { return }
        let width = CGFloat(PetBasinStack.width(config))
        let height = CGFloat(PetBasinStack.height(config))
        let rect = NSRect(
            x: baseCenter.x - width / 2,
            y: baseCenter.y + CGFloat(placement.rise) - height / 2,
            width: width,
            height: height
        )
        guard rect.width > 0, rect.height > 0 else { return }

        context.saveGraphicsState()
        context.cgContext.setAlpha(CGFloat(min(1, max(0, placement.opacity))))

        // Contact shadow: it seats the basin on the head and separates the layers of a pile.
        NSColor(white: 0, alpha: 0.18).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: rect.minX + rect.width * 0.10,
            y: rect.minY - rect.height * 0.02,
            width: rect.width * 0.80,
            height: rect.height * 0.08
        )).fill()

        if let image {
            image.draw(
                in: rect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: false,
                hints: nil
            )
        } else {
            drawVectorBasin(in: rect)
        }

        context.restoreGraphicsState()
    }

    /// Fallback shape: a dome with a rolled rim, close enough to the artwork to read as the
    /// same object when the PNG cannot be loaded.
    private static func drawVectorBasin(in rect: NSRect) {
        let rimHeight = rect.height * 0.22
        let dome = NSRect(
            x: rect.minX,
            y: rect.minY + rimHeight * 0.55,
            width: rect.width,
            height: rect.height - rimHeight * 0.55
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(
            x: rect.minX,
            y: rect.minY + rimHeight * 0.5,
            width: rect.width,
            height: rect.height
        )).addClip()
        fill(dome, from: rimLight, to: rimDark)
        NSGraphicsContext.restoreGraphicsState()

        let rim = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rimHeight)
        fill(rim, from: rimDark, to: rimLight)
        NSColor(white: 1, alpha: 0.42).setStroke()
        let rimPath = NSBezierPath(ovalIn: rim.insetBy(dx: 0.5, dy: 0.5))
        rimPath.lineWidth = 1
        rimPath.stroke()

        NSColor(white: 1, alpha: 0.62).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: rect.minX + rect.width * 0.18,
            y: rect.minY + rect.height * 0.42,
            width: rect.width * 0.26,
            height: rect.height * 0.16
        )).fill()
        NSColor(white: 0, alpha: 0.16).setFill()
        NSBezierPath(ovalIn: NSRect(
            x: rect.minX + rect.width * 0.14,
            y: rect.minY + rimHeight * 0.9,
            width: rect.width * 0.72,
            height: rimHeight * 1.1
        )).fill()
    }

    private static func fill(_ rect: NSRect, from start: NSColor, to end: NSColor) {
        let path = NSBezierPath(ovalIn: rect)
        if let gradient = NSGradient(starting: start, ending: end) {
            gradient.draw(in: path, angle: -45)
        } else {
            start.setFill()
            path.fill()
        }
    }
}
