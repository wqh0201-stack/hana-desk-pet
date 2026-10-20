import AppKit
import Foundation

// Pixel-level checks on the REAL bubble view (PetBubbleController + its private view), not
// on a re-implementation: every subtitle line must be drawn in full, the two tiers must have
// the intended heights, the tail must really be inside the window, the accent must reach the
// pixels and the fill must be opaque.
//
// A long line is expected to wrap and truncate its last line; the check confirms the ink
// spans at least the full width then, instead of silently ellipsizing a short line.
//
// This is a rendering check. It creates a real NSPanel offscreen but never shows it.
@main
struct BubbleViewChecks {
    private static var checks = 0

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let pet = NSWindow(
            contentRect: NSRect(x: 400, y: 400, width: 176, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        pet.isOpaque = false
        pet.backgroundColor = .clear
        pet.orderFrontRegardless()

        let controller = PetBubbleController()
        checkSubtitleLinesAreNotEllipsized(controller: controller, pet: pet)
        checkTiersAndTail(controller: controller, pet: pet)
        checkAccentAndOpacity(controller: controller, pet: pet)
        print("BubbleViewChecks: \(checks) checks passed.")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("CHECK FAILED: " + message + "\n").utf8))
        exit(1)
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fail(message) }
    }

    private struct Bubble {
        let panel: NSPanel
        let view: NSView
        let label: NSTextField?
        let frame: NSRect
    }

    private static func show(_ content: PetBubbleContent, role: String, controller: PetBubbleController, pet: NSWindow) -> Bubble? {
        controller.apply(content: content, roleId: role, enabled: true, reduceMotion: true, petWindow: pet)
        for _ in 0..<4 { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        guard let panel = NSApp.windows.first(where: { $0 is PetBubblePanel }) as? NSPanel, panel.isVisible,
              let view = panel.contentView else { return nil }
        let label = view.subviews.compactMap { $0 as? NSTextField }.first { !$0.isHidden && !$0.stringValue.isEmpty }
        return Bubble(panel: panel, view: view, label: label, frame: panel.frame)
    }

    private static func rep(for view: NSView) -> NSBitmapImageRep? {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    /// Ink width of dark pixels inside `rect`. The bubble view is flipped (y grows downward);
    /// a reference bitmap is not, so the caller says which it is.
    private static func inkWidth(_ bitmap: NSBitmapImageRep, in rect: NSRect, flipped: Bool = true) -> Double {
        guard let data = bitmap.bitmapData else { return 0 }
        let x0 = max(0, Int(rect.minX)), x1 = min(bitmap.pixelsWide - 1, Int(rect.maxX))
        let rawY0 = Int(rect.minY), rawY1 = Int(rect.maxY)
        let y0: Int, y1: Int
        if flipped {
            y0 = max(0, rawY0); y1 = min(bitmap.pixelsHigh - 1, rawY1)
        } else {
            y0 = max(0, bitmap.pixelsHigh - rawY1); y1 = min(bitmap.pixelsHigh - 1, bitmap.pixelsHigh - rawY0)
        }
        guard x1 >= x0, y1 >= y0 else { return 0 }
        var minX = bitmap.pixelsWide, maxX = -1
        for y in y0...y1 {
            for x in x0...x1 {
                let pixel = data + y * bitmap.bytesPerRow + x * 4
                if pixel[0] < 180 {
                    minX = min(minX, x); maxX = max(maxX, x)
                }
            }
        }
        return maxX >= 0 ? Double(maxX - minX + 1) : 0
    }

    private static func naturalWidth(_ text: String, font: NSFont) -> Double {
        Double((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Ink width of the same string drawn unconstrained: the reference an un-ellipsized line
    /// must match. Comparing against the advance instead would be wrong, because a glyph's
    /// ink is always a little narrower than its advance (side bearings).
    private static func referenceInkWidth(_ text: String, font: NSFont) -> Double {
        let wide = ceil(naturalWidth(text, font: font)) + 8
        let height: CGFloat = 40
        let host = FilledView(frame: NSRect(x: 0, y: 0, width: wide, height: height))
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 0 }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (text as NSString).draw(
            at: NSPoint(x: 3, y: 3),
            withAttributes: [.font: font, .foregroundColor: NSColor.black]
        )
        NSGraphicsContext.restoreGraphicsState()
        return inkWidth(bitmap, in: NSRect(x: 0, y: 0, width: wide, height: height), flipped: false)
    }

    private final class FilledView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill()
            bounds.fill()
        }
    }

    /// The regression this locks down: with `wraps + truncatesLastVisibleLine` AppKit sizes a
    /// line against its width minus an ellipsis, so an ordinary short line was drawn as
    /// "跑一…". Every line that fits must now be drawn in full.
    private static func checkSubtitleLinesAreNotEllipsized(controller: PetBubbleController, pet: NSWindow) {
        let samples = [
            "跑一下～", "让我想想。", "（把橙花摆正）", "翻两页。", "zZ", "……咕噜咕噜",
            "脑子装不下了，收一收。", "先把上下文读全。", "尾巴、尾巴要断了！",
        ]
        for (index, text) in samples.enumerated() {
            let content = PetBubbleContent(id: "sub\(index)", style: .subtitle, title: "", status: text)
            guard let bubble = show(content, role: "claude", controller: controller, pet: pet),
                  let label = bubble.label, let bitmap = rep(for: bubble.view) else {
                fail("the bubble did not appear for \(text)")
            }
            let font = label.font ?? NSFont.systemFont(ofSize: 13)
            let natural = naturalWidth(text, font: font)
            let granted = Double(label.frame.width)
            let ink = inkWidth(bitmap, in: label.frame)
            let reference = referenceInkWidth(text, font: font)
            // The content box must be at least as wide as the text's advance.
            check(granted + 1e-9 >= natural,
                  "\(text): the label got \(granted) pt but the text needs \(natural) pt")
            // And the drawn ink must match the unconstrained reference, not stop early.
            check(abs(ink - reference) <= 1.5,
                  "\(text): drew \(ink) pt of ink but the reference ink is \(reference) pt (ellipsized)")
            check(bubble.frame.height == PetBubbleLayout.subtitleHeight(oneLine: true),
                  "\(text): a line that fits keeps the compact \(PetBubbleLayout.subtitleHeight(oneLine: true)) pt tier")
        }
    }

    /// A line too long for the maximum width must wrap into the two-line tier, use the whole
    /// content width, and never change the font size.
    private static func checkTiersAndTail(controller: PetBubbleController, pet: NSWindow) {
        let long = "这条台词故意写得非常非常长，用来确认超长时确实折行并在第二行尾部截断而不是缩字号。"
        guard let bubble = show(
            PetBubbleContent(id: "long", style: .subtitle, title: "", status: long),
            role: "gemini", controller: controller, pet: pet
        ), let label = bubble.label, let bitmap = rep(for: bubble.view) else {
            fail("the long subtitle did not appear")
        }
        check(bubble.frame.width == PetBubbleLayout.maxWidth, "a long line uses the maximum width")
        check(bubble.frame.height == PetBubbleLayout.subtitleHeight(oneLine: false),
              "a long line uses the two-line tier")
        check(label.frame.height >= CGFloat(PetBubbleLayout.subtitleLineHeight * 2),
              "a long line really wraps into two lines")
        check(label.font?.pointSize == CGFloat(PetBubbleLayout.subtitleFontSize),
              "the font size never changes to fit")
        let ink = inkWidth(bitmap, in: label.frame)
        check(ink >= Double(label.frame.width) * 0.9,
              "a wrapped line uses the full content width, got \(ink) of \(label.frame.width)")

        // The tail's outer ellipse must be inside the window on both tiers.
        for (name, height) in [("single", PetBubbleLayout.subtitleHeight(oneLine: true)),
                               ("wrapped", PetBubbleLayout.subtitleHeight(oneLine: false)),
                               ("notice", PetBubbleLayout.noticeHeight())] {
            let outer = PetBubbleLayout.tailOuterRect(width: PetBubbleLayout.maxWidth, height: height)
            check(outer.x >= 0 && outer.y >= 0, "\(name): the tail starts inside the window")
            check(outer.x + outer.width <= PetBubbleLayout.maxWidth,
                  "\(name): the tail stays inside the window's right edge")
            check(outer.y + outer.height <= height, "\(name): the tail stays inside the window's bottom edge")
        }
    }

    /// The accent must be the character's, and the fill must be opaque white.
    private static func checkAccentAndOpacity(controller: PetBubbleController, pet: NSWindow) {
        let expected: [(String, String)] = [
            ("claude", "#e8a33d"), ("gpt", "#7a8fa8"), ("deepseek", "#3b5bb5"),
            ("gemini", "#7b5cd6"), ("glm", "#4b5a8a"),
            ("deepseek-hoodie", "#e0b48a"), ("gpt-onesie", "#e0b48a"),
        ]
        for (role, hex) in expected {
            let content = PetBubbleContent(id: "accent-\(role)", style: .notice, title: "角色", status: "需要你确认")
            guard let bubble = show(content, role: role, controller: controller, pet: pet),
                  let bitmap = rep(for: bubble.view), let data = bitmap.bitmapData else {
                fail("the notice did not appear for \(role)")
            }
            let accent = PetBubbleTheme.accent(forRoleId: role)
            let want = (accent.red * 255, accent.green * 255, accent.blue * 255)
            let x = bitmap.pixelsWide / 2
            var best = Double.greatestFiniteMagnitude
            var sampled = ""
            for y in 0..<bitmap.pixelsHigh {
                let pixel = data + y * bitmap.bytesPerRow + x * 4
                // Only an opaque pixel can be the border; skip the white body and any
                // antialiased edge.
                guard pixel[3] == 255 else { continue }
                let distance = max(abs(Double(pixel[0]) - want.0),
                                   max(abs(Double(pixel[1]) - want.1), abs(Double(pixel[2]) - want.2)))
                if distance < best {
                    best = distance
                    sampled = String(format: "#%02x%02x%02x", pixel[0], pixel[1], pixel[2])
                }
            }
            // The bitmap is device-RGB, so the exact sRGB octets shift by a few units; the
            // nearest opaque pixel must still be unmistakably this character's accent.
            check(best <= 12, "\(role)'s border should be \(hex); nearest opaque pixel was \(sampled)")
        }
        // The interior is opaque white: no translucency like the previous 0.95 tint.
        let content = PetBubbleContent(id: "fill", style: .subtitle, title: "", status: "在。")
        guard let bubble = show(content, role: "glm", controller: controller, pet: pet),
              let bitmap = rep(for: bubble.view), let data = bitmap.bitmapData else {
            fail("the fill check could not render a bubble")
        }
        let body = PetBubbleLayout.bodyRect(width: Double(bubble.frame.width), height: Double(bubble.frame.height))
        let x = bitmap.pixelsWide / 2
        let y = max(1, Int(body.y + body.height) - 2)
        let pixel = data + y * bitmap.bytesPerRow + x * 4
        check(pixel[3] == 255, "the body fill is fully opaque, got alpha \(pixel[3])")
        // Sample the interior away from the label's glyphs: a text pixel is legitimately dark.
        let interiorRow = max(1, Int(body.y + body.height / 4))
        let leftPixel = data + interiorRow * bitmap.bytesPerRow + (Int(body.x) + 4) * 4
        check(leftPixel[3] == 255 && leftPixel[0] == 255 && leftPixel[1] == 255 && leftPixel[2] == 255,
              String(format: "the body fill is pure opaque white, got #%02x%02x%02x a%d",
                     leftPixel[0], leftPixel[1], leftPixel[2], leftPixel[3]))
        // The character does not sit under the bubble in this probe, so nothing paints below the
        // body except the tail: the bottom corners of the window are transparent.
        let bottomRow = bitmap.pixelsHigh - 1
        let leftCorner = data + bottomRow * bitmap.bytesPerRow
        let rightCorner = data + bottomRow * bitmap.bytesPerRow + (bitmap.pixelsWide - 1) * 4
        check(leftCorner[3] == 0, "the bottom-left corner stays transparent, got alpha \(leftCorner[3])")
        check(rightCorner[3] == 0, "the bottom-right corner stays transparent, got alpha \(rightCorner[3])")
        // And the accent halo really is painted above the body: the pixels between the window's
        // top edge and the body must carry some accent tint.
        var haloAlpha = 0
        for row in 0..<max(0, Int(body.y)) {
            let p = data + row * bitmap.bytesPerRow + x * 4
            haloAlpha = max(haloAlpha, Int(p[3]))
        }
        check(haloAlpha > 8, "the accent halo is visible above the body, got alpha \(haloAlpha)")
        // Below the body's bottom edge, outside the tail, nothing may be painted.
        let tail = PetBubbleLayout.tailOuterRect(width: Double(bubble.frame.width),
                                                 height: Double(bubble.frame.height))
        var belowBody = 0
        var belowBodyX = -1
        var belowBodyY = -1
        // The tail has its own small halo (4 pt blur, 22 % accent), bounded to the tail's own
        // neighbourhood and never past the tail tip. Its reach is what the margin below allows.
        let tailHaloLeft = tail.x - PetBubbleLayout.tailGlowInset - 2
        let tailHaloRight = tail.x + tail.width + PetBubbleLayout.tailGlowInset + 2
        for row in Int(body.y + body.height)..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let inTail = Double(column) >= tailHaloLeft && Double(column) <= tailHaloRight
                if inTail { continue }
                let a = Int(data[row * bitmap.bytesPerRow + column * 4 + 3])
                if a > belowBody { belowBody = a; belowBodyX = column; belowBodyY = row }
            }
        }
        if belowBody > 0 {
            print("  below-body leak at (\(belowBodyX),\(belowBodyY)) alpha \(belowBody), body bottom \(Int(body.y + body.height)), tail x \(tail.x)...\(tail.x + tail.width)")
        }
        // The tail's own halo is allowed inside its column; outside it, only the 1 pt
        // anti-aliased edge of the body's rounded corner may spill a hair. Anything stronger
        // would be the halo bleeding onto the character's head.
        check(belowBody <= 16, "no halo bleeds below the body (best alpha \(belowBody) outside the tail)")
        print("real-view halo: above=\(haloAlpha) below=\(belowBody)")
    }
}
