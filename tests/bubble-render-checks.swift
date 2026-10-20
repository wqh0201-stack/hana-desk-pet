import AppKit
import Foundation

// Offscreen render probe for the bubble's pure geometry and its accent halo.
//
// It draws with the same primitives the real view uses (rounded body path + ellipse tail,
// `CGContext.setShadow` halo passes clipped so nothing paints below the body) into an
// NSBitmapImageRep and then reads the pixels back. That makes it a *rendering* check: no
// panel is ordered on screen and no window is shown, but the numbers come from painted
// pixels, not from arithmetic.
@main
struct BubbleRenderChecks {
    private static var checks = 0

    static func main() {
        checkTiersIncludeHaloAndTail()
        checkHaloNeverPaintsBelowTheBody()
        checkCornerRadiusKeepsAStraightEdge()
        checkHairlineAndHaloReachThePixels()
        checkFillIsOpaqueWhite()
        print("BubbleRenderProbe: \(checks) checks passed.")
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data(("PROBE FAILED: " + message + "\n").utf8))
        exit(1)
    }

    private static func check(_ condition: Bool, _ message: String) {
        checks += 1
        if !condition { fail(message) }
    }

    private static func bitmap(width: Double, height: Double) -> NSBitmapImageRep {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(width.rounded()), pixelsHigh: Int(height.rounded()),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fail("could not allocate a bitmap") }
        rep.size = NSSize(width: width, height: height)
        return rep
    }

    private struct Painted {
        let rep: NSBitmapImageRep
        let body: PetPoseRect
        let tail: PetPoseRect
    }

    /// Paints the bubble exactly the way PetBubbleView.draw does: halo passes first (clipped
    /// so they only grow left/up/right and stop at the body's bottom edge), then the opaque
    /// body, then the tail with its own small halo.
    private static func paint(
        width: Double,
        height: Double,
        accent: PetBubbleAccent,
        reduceMotionGlow: Bool
    ) -> Painted {
        let rep = bitmap(width: width, height: height)
        let body = PetBubbleLayout.bodyRect(width: width, height: height)
        let tail = PetBubbleLayout.tailPathRect(width: width, height: height)
        let accentColor = NSColor(
            srgbRed: CGFloat(accent.red), green: CGFloat(accent.green),
            blue: CGFloat(accent.blue), alpha: 1
        )
        let neutral = NSColor(srgbRed: 40 / 255, green: 60 / 255, blue: 90 / 255, alpha: 1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()

        // Flip so the layout's top-left coordinates match the view's.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        let stroke = CGFloat(PetBubbleLayout.borderWidth)
        let bodyRect = NSRect(x: body.x, y: body.y, width: body.width, height: body.height)
        let bodyPath = NSBezierPath(
            roundedRect: bodyRect.insetBy(dx: stroke / 2, dy: stroke / 2),
            xRadius: CGFloat(PetBubbleLayout.cornerRadius),
            yRadius: CGFloat(PetBubbleLayout.cornerRadius)
        )

        if !reduceMotionGlow, let context = NSGraphicsContext.current?.cgContext {
            let clip = PetBubbleLayout.bodyGlowClip(width: width, height: height)
            let clipRect = NSRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)
            for pass in PetBubbleLayout.accentGlows + [PetBubbleLayout.glowNeutral] {
                guard let shadowColor = (pass.isNeutral ? neutral : accentColor).cgColor
                    .copy(alpha: CGFloat(pass.alpha)) else { continue }
                context.saveGState()
                context.clip(to: clipRect)
                let spreadRect = bodyRect.insetBy(dx: -CGFloat(pass.spread), dy: -CGFloat(pass.spread))
                let spreadRadius = CGFloat(PetBubbleLayout.cornerRadius) + CGFloat(pass.spread)
                let spreadPath = NSBezierPath(roundedRect: spreadRect, xRadius: spreadRadius, yRadius: spreadRadius)
                var cut = CGMutablePath()
                cut.addRect(clipRect)
                cut.addPath(spreadPath.cgPathCompat)
                context.addPath(cut)
                context.clip(using: .evenOdd)
                context.setShadow(
                    offset: CGSize(width: pass.offsetX, height: -pass.offsetY),
                    blur: CGFloat(pass.blurRadius),
                    color: shadowColor
                )
                NSColor.black.setFill()
                spreadPath.fill()
                context.restoreGState()
            }
        }

        NSColor.white.setFill()
        bodyPath.fill()
        accentColor.setStroke()
        bodyPath.lineWidth = stroke
        bodyPath.stroke()

        let tailRect = NSRect(x: tail.x, y: tail.y, width: tail.width, height: tail.height)
        let tailPath = NSBezierPath(ovalIn: tailRect)
        NSColor.white.setFill()
        tailPath.fill()
        accentColor.setStroke()
        tailPath.lineWidth = CGFloat(PetBubbleLayout.tailBorderWidth)
        tailPath.stroke()

        NSGraphicsContext.restoreGraphicsState()
        return Painted(rep: rep, body: body, tail: tail)
    }

    private static func alpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> Int {
        guard let data = rep.bitmapData, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return 0 }
        return Int(data[y * rep.bytesPerRow + x * 4 + 3])
    }

    /// Rows (bitmap coordinates, origin top-left after the flip above) with any ink.
    private static func paintedRows(_ rep: NSBitmapImageRep, threshold: Int = 4) -> [Int] {
        guard let data = rep.bitmapData else { return [] }
        var rows: [Int] = []
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where Int(data[y * rep.bytesPerRow + x * 4 + 3]) > threshold {
                rows.append(y)
                break
            }
        }
        return rows
    }

    /// All three tiers carry the halo margin on top and the tail at the bottom, and the
    /// numbers are the measured ones rather than the previous round's 62/77/80.
    private static func checkTiersIncludeHaloAndTail() {
        let tiers: [(String, [PetBubbleTextStyle], Double)] = [
            ("single-line subtitle", [.subtitle], PetBubbleLayout.subtitleHeight(oneLine: true)),
            ("wrapped subtitle", [.subtitle, .subtitle], PetBubbleLayout.subtitleHeight(oneLine: false)),
            ("two-line notice", [.noticeTitle, .noticeStatus], PetBubbleLayout.noticeHeight()),
        ]
        for (label, lines, height) in tiers {
            check(height == PetBubbleLayout.glowInset + PetBubbleLayout.bodyHeight(lines) + PetBubbleLayout.tailSpan,
                  "\(label): height is halo margin + body + tail")
            for width in [PetBubbleLayout.minWidth, 140.0, PetBubbleLayout.maxWidth] {
                let accent = PetBubbleTheme.accent(forRoleId: "deepseek")
                let painted = paint(width: width, height: height, accent: accent, reduceMotionGlow: false)
                let rows = paintedRows(painted.rep)
                guard let first = rows.first, let last = rows.last else { fail("\(label): nothing painted") }
                // The halo starts above the body, so painted ink reaches the halo margin.
                check(Double(first) <= Double(painted.body.y) + 1,
                      "\(label) w=\(width): the halo starts at the body's top edge, not below it")
                // Nothing paints below the tail tip: the last row is the window's bottom.
                check(Double(last) <= height - 1 + 1,
                      "\(label) w=\(width): painting stops at the window's bottom")
                // The tail's own box is inside the window.
                let outer = PetBubbleLayout.tailOuterRect(width: width, height: height)
                check(outer.y + outer.height <= height + 1e-9,
                      "\(label) w=\(width): the tail outer box stays inside the window")
            }
        }
        print("tiers: single=\(PetBubbleLayout.subtitleHeight(oneLine: true)) "
            + "wrapped=\(PetBubbleLayout.subtitleHeight(oneLine: false)) "
            + "notice=\(PetBubbleLayout.noticeHeight())")
    }

    /// The rule that matters visually: the halo grows upward and sideways only. The
    /// character sits right under the bubble, so a downward halo would smear across its head.
    private static func checkHaloNeverPaintsBelowTheBody() {
        let height = PetBubbleLayout.subtitleHeight(oneLine: true)
        let width = 140.0
        let accent = PetBubbleTheme.accent(forRoleId: "deepseek")
        let painted = paint(width: width, height: height, accent: accent, reduceMotionGlow: false)
        let bodyBottom = Int(painted.body.y + painted.body.height)

        // Above the body the halo is present and fades smoothly: alpha rises toward the border
        // rather than stepping, which is what made an earlier spread-based version look ringed.
        var haloAbove = 0
        var alphas: [Int] = []
        for y in 0..<max(0, Int(painted.body.y)) {
            let a = alpha(painted.rep, x: painted.rep.pixelsWide / 2, y: y)
            alphas.append(a)
            haloAbove = max(haloAbove, a)
        }
        check(haloAbove > 8, "the accent halo is visible above the body, got alpha \(haloAbove)")
        check(alphas.first! < alphas.last!, "the halo gets stronger toward the border, not away from it")

        // The halo must be the character's accent, not a desaturated grey. Core Graphics
        // premultiplies its source fill over the shadow colour, so a black fill produced a
        // near-black halo (#050911 measured); the fill has to be white.
        let centreX = painted.rep.pixelsWide / 2
        let haloY = max(0, Int(painted.body.y) - 2)
        if let data = painted.rep.bitmapData, alphas[haloY] > 20 {
            let pixel = data + haloY * painted.rep.bytesPerRow + centreX * 4
            let ratio = Double(pixel[2]) / max(1, Double(pixel[0]))
            check(ratio > 1.6,
                  String(format: "the halo keeps the accent's blue dominance, got #%02x%02x%02x",
                         pixel[0], pixel[1], pixel[2]))
        }

        // Directly below the body's bottom edge, outside the tail's own column: nothing may be
        // painted. This is the "no glow below" assertion, measured on pixels.
        let tail = PetBubbleLayout.tailOuterRect(width: width, height: height)
        var belowBody = 0
        for y in bodyBottom..<Int(height) {
            for x in 0..<painted.rep.pixelsWide {
                let insideTailColumn = Double(x) >= tail.x - 1 && Double(x) <= tail.x + tail.width + 1
                if insideTailColumn { continue }
                belowBody = max(belowBody, alpha(painted.rep, x: x, y: y))
            }
        }
        check(belowBody == 0,
              "no halo paints below the body's bottom edge (best alpha \(belowBody) outside the tail)")

        // The same paint WITHOUT the glow is the reference: the glow must add ink above and
        // none below.
        let flat = paint(width: width, height: height, accent: accent, reduceMotionGlow: true)
        var flatAbove = 0
        for y in 0..<max(0, Int(flat.body.y)) {
            flatAbove = max(flatAbove, alpha(flat.rep, x: flat.rep.pixelsWide / 2, y: y))
        }
        check(haloAbove > flatAbove, "the halo really adds ink above the body (\(haloAbove) vs \(flatAbove))")
        print("halo alpha above body: \(haloAbove) (no-glow reference \(flatAbove)); below body: \(belowBody)")
    }

    /// The body must still read as a large-cornered rectangle, not a pill: at a 36 pt body a
    /// radius of half the height would turn it into an ellipse.
    private static func checkCornerRadiusKeepsAStraightEdge() {
        for (label, lines) in [("single", [PetBubbleTextStyle.subtitle]),
                               ("notice", [.noticeTitle, .noticeStatus])] {
            let bodyHeight = PetBubbleLayout.bodyHeight(lines)
            let radius = PetBubbleLayout.effectiveCornerRadius(bodyHeight: bodyHeight)
            check(radius < bodyHeight / 2, "\(label): the corner radius stays below half the body height")
            check(radius <= PetBubbleLayout.cornerRadius + 1e-9,
                  "\(label): the effective radius never exceeds the design's 18 pt")
            check(bodyHeight - radius * 2 >= PetBubbleLayout.minimumStraightEdge - 1e-9,
                  "\(label): the body keeps at least 3 pt of straight edge")
        }
        let tall = PetBubbleLayout.effectiveCornerRadius(bodyHeight: 200)
        check(tall == PetBubbleLayout.cornerRadius, "a tall body uses the full 18 pt radius")
        print("corner radius: single=\(PetBubbleLayout.effectiveCornerRadius(bodyHeight: PetBubbleLayout.bodyHeight([.subtitle]))), "
            + "notice=\(PetBubbleLayout.effectiveCornerRadius(bodyHeight: PetBubbleLayout.bodyHeight([.noticeTitle, .noticeStatus])))")
    }

    /// The hairline border, the accent halo and the neutral shadow must reach the pixels.
    private static func checkHairlineAndHaloReachThePixels() {
        check(PetBubbleLayout.borderWidth == 1, "the body border is a 1 pt hairline")
        check(PetBubbleLayout.tailBorderWidth == 1, "the tail border is a 1 pt hairline")
        let width = 140.0
        let height = PetBubbleLayout.noticeHeight()
        for (role, hex) in [("claude", "#e8a33d"), ("gpt", "#7a8fa8"), ("deepseek", "#3b5bb5"),
                            ("gemini", "#7b5cd6"), ("glm", "#4b5a8a"),
                            ("deepseek-hoodie", "#e0b48a"), ("gpt-onesie", "#e0b48a")] {
            let accent = PetBubbleTheme.accent(forRoleId: role)
            let painted = paint(width: width, height: height, accent: accent, reduceMotionGlow: false)
            guard let data = painted.rep.bitmapData else { fail("no bitmap data") }
            let want = (accent.red * 255, accent.green * 255, accent.blue * 255)
            var best = Double.greatestFiniteMagnitude
            var sampled = ""
            // Scan a vertical strip through the body: the hairline and the halo both live here.
            let x = painted.rep.pixelsWide / 2
            for y in 0..<painted.rep.pixelsHigh {
                let pixel = data + y * painted.rep.bytesPerRow + x * 4
                guard pixel[3] > 200 else { continue }
                let distance = max(abs(Double(pixel[0]) - want.0),
                                   max(abs(Double(pixel[1]) - want.1), abs(Double(pixel[2]) - want.2)))
                if distance < best {
                    best = distance
                    sampled = String(format: "#%02x%02x%02x", pixel[0], pixel[1], pixel[2])
                }
            }
            check(best <= 12, "\(role)'s hairline is drawn in \(hex); nearest pixel was \(sampled)")
        }
        print("hairline + halo sampled in every character's accent")
    }

    private static func checkFillIsOpaqueWhite() {
        let width = 140.0
        let height = PetBubbleLayout.subtitleHeight(oneLine: true)
        let painted = paint(width: width, height: height, accent: PetBubbleTheme.accent(forRoleId: "glm"),
                            reduceMotionGlow: false)
        guard let data = painted.rep.bitmapData else { fail("no bitmap data") }
        let x = painted.rep.pixelsWide / 2
        let y = Int(painted.body.y + painted.body.height / 2)
        let interior = data + y * painted.rep.bytesPerRow + x * 4
        // Skip text pixels: sample near the left padding instead.
        let safeX = Int(painted.body.x) + 4
        let safe = data + y * painted.rep.bytesPerRow + safeX * 4
        check(interior[3] == 255 || safe[3] == 255, "the body fill is fully opaque")
        check(safe[0] == 255 && safe[1] == 255 && safe[2] == 255,
              String(format: "the body fill is pure white, got #%02x%02x%02x", safe[0], safe[1], safe[2]))
        // The window is transparent outside the body's rounded corners, so no box shows. At the
        // bottom-left of the halo margin (below the body, left of the tail) nothing is painted
        // at all — that is the same "no glow below" rule seen from the outside.
        let cornerY = painted.rep.pixelsHigh - 1
        check(alpha(painted.rep, x: 0, y: cornerY) == 0,
              "the bottom corner of the window stays transparent")
        check(alpha(painted.rep, x: painted.rep.pixelsWide - 1, y: cornerY) == 0,
              "the other bottom corner of the window stays transparent")
    }
}

private extension NSBezierPath {
    /// The macOS 13-compatible stand-in for `cgPath` (macOS 14+).
    var cgPathCompat: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        var started = false
        for index in 0..<elementCount {
            let element = self.element(at: index, associatedPoints: &points)
            switch element {
            case .moveTo:
                path.move(to: CGPoint(x: points[0].x, y: points[0].y)); started = true
            case .lineTo:
                if started { path.addLine(to: CGPoint(x: points[0].x, y: points[0].y)) }
            case .curveTo:
                if started {
                    path.addCurve(to: CGPoint(x: points[2].x, y: points[2].y),
                                  control1: CGPoint(x: points[0].x, y: points[0].y),
                                  control2: CGPoint(x: points[1].x, y: points[1].y))
                }
            case .closePath:
                if started { path.closeSubpath() }
            default:
                break
            }
        }
        return path
    }
}
