import Foundation

/// Text metrics the bubble window may use. The font size never changes to fit.
public enum PetBubbleTextStyle: Equatable, Sendable {
    /// One 13 pt dialogue line (a long one wraps to at most two lines).
    case subtitle
    /// The notice title: 12 pt semibold.
    case noticeTitle
    /// The notice status word: 11 pt regular.
    case noticeStatus
}

/// One glow pass: the accent halo drawn *outside* the 1 pt border.
///
/// Modelled on a CSS `box-shadow` list so both native ends can reproduce it with their own
/// primitives (AppKit `NSShadow`/`CGContext.setShadow`, WPF `DropShadowEffect` layers).
public struct PetBubbleGlow: Equatable, Sendable {
    /// Horizontal/vertical offset of the halo (0 keeps it centred on the shape).
    public let offsetX: Double
    public let offsetY: Double
    /// Gaussian blur radius.
    public let blurRadius: Double
    /// How far the shadow's solid core spreads beyond the shape before the blur starts.
    public let spread: Double
    /// Fraction of the accent used as this pass's alpha (0…1).
    public let alpha: Double
    /// `true` for the neutral drop shadow, which uses its own colour instead of the accent.
    public let isNeutral: Bool

    public init(
        offsetX: Double,
        offsetY: Double,
        blurRadius: Double,
        spread: Double,
        alpha: Double,
        isNeutral: Bool = false
    ) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.blurRadius = blurRadius
        self.spread = spread
        self.alpha = alpha
        self.isNeutral = isNeutral
    }

    /// How far this pass can paint beyond the shape's own edge.
    public var outwardExtent: Double { abs(offsetX) + blurRadius + spread }
}

/// Pure, testable bubble geometry.
///
/// The bubble is a large rounded rectangle with an independent small ellipse tail:
/// `#ffffff` fill, a 1 pt border in the character's accent colour, 18 pt corners, and a
/// 22 × 15 pt ellipse 1 pt thick hanging under the middle of the body. Outside the border
/// there is a two-layer accent halo. Each tier's height includes the tail *and* the halo
/// margin, so nothing is ever drawn outside the window.
///
///   body            = 2·border + 2·paddingY + text lines (+ line spacing)
///   window height   = glowInset + body + tailSpan + tailTipSlack
///   gapAbovePet     = distance from the tail tip to the top of the character's artwork (2)
public struct PetBubbleLayout: Equatable, Sendable {
    public static let maxWidth: Double = 220
    public static let minWidth: Double = 96
    /// Horizontal padding inside the border.
    public static let paddingX: Double = 17
    /// Vertical padding inside the border.
    public static let paddingY: Double = 9
    public static let lineSpacing: Double = 2
    /// The body's corner radius.
    public static let cornerRadius: Double = 18
    /// A rounded rectangle must keep a visible straight edge. The body is only ~36 pt tall,
    /// and a radius of half that height turns the shape into a perfect pill (which is exactly
    /// what the 3 pt-border round looked like). The effective radius is therefore capped at
    /// `height / 2 - minimumStraightEdge`, so the 18 pt design still reads as a large-cornered
    /// rectangle instead of an ellipse.
    public static let minimumStraightEdge: Double = 3
    /// Accent-coloured hairline border, drawn inside the body rect.
    public static let borderWidth: Double = 1
    /// Dialogue font size. It never shrinks; a long line wraps instead.
    public static let subtitleFontSize: Double = 13
    /// Measured single-line height of the 13 pt system font (ascender 12.57 − descender
    /// −2.74 = 15.31, rounded up so a wrapped second line never clips).
    public static let subtitleLineHeight: Double = 16
    public static let titleLineHeight: Double = 15
    /// Measured: the 11 pt regular font needs ceil(10.635 + 2.320) = 13 pt.
    public static let statusLineHeight: Double = 13
    public static let tailWidth: Double = 22
    public static let tailHeight: Double = 15
    public static let tailBorderWidth: Double = 1
    /// Gap between the body's bottom edge and the ellipse's outer top edge.
    public static let tailGap: Double = 4
    /// Half of `tailBorderWidth`: the tail is inset by this much so its stroke stays inside.
    public static let tailStrokeInset: Double = 0.5
    /// Body bottom to the tail's outer tip: `tailGap + tailHeight + 2 · tailStrokeInset`
    /// = 4 + 15 + 1 = 20.0 — a whole number, so the window needs no rounding slack.
    public static let tailSpan: Double = tailGap + tailHeight + tailStrokeInset * 2
    /// The tail's space in the window height. Equal to `tailSpan` at a 1 pt tail border.
    public static let tailSpanInWindow: Double = tailSpan
    /// Whole-point rounding leaves this much transparent slack under the tail tip. At the
    /// current tail span this is exactly 0, so the tail tip *is* the window's bottom edge.
    public static let tailTipSlack: Double = tailSpanInWindow - tailSpan

    // MARK: - Halo
    //
    // The four passes of the reviewed design, innermost first. They paint only outward from
    // the border, and the window reserves `glowInset` on the left, top and right.

    /// A hairline of nearly solid accent hugging the border.
    public static let glowHug = PetBubbleGlow(offsetX: 0, offsetY: 0, blurRadius: 0, spread: 0.5, alpha: 0.22)
    /// The main halo.
    public static let glowMain = PetBubbleGlow(offsetX: 0, offsetY: 0, blurRadius: 7, spread: 2, alpha: 0.26)
    /// The wide outer diffusion.
    public static let glowOuter = PetBubbleGlow(offsetX: 0, offsetY: 0, blurRadius: 16, spread: 5, alpha: 0.14)
    /// A little neutral drop shadow so the bubble still reads on a pale wallpaper.
    public static let glowNeutral = PetBubbleGlow(offsetX: 0, offsetY: 1, blurRadius: 3, spread: 0, alpha: 0.06, isNeutral: true)

    /// Every accent pass, innermost first. The neutral drop shadow is handled separately
    /// because it is not tinted by the character.
    public static let accentGlows: [PetBubbleGlow] = [glowHug, glowMain, glowOuter]

    /// How far the accent halo is *allowed* to paint beyond the body. The widest pass reaches
    /// 21 pt, but the outermost one is only 14 % opaque there, so the reviewed design keeps
    /// 8 pt: the halo fades into the wallpaper instead of growing the window to 21 pt of
    /// (mostly invisible) transparent padding.
    public static let glowInset: Double = 8

    /// How far the halo is clipped below the body. The character sits directly under the
    /// bubble, so the body halo never bleeds downward onto its head: the lowest pixel it may
    /// paint is the body's own bottom edge.
    public static let glowBottomExtent: Double = 0

    /// The tail's own halo is small and bounded: it may only reach this far sideways and
    /// never past the tail tip, so the area under the bubble stays visually clean.
    public static let tailGlowInset: Double = 4

    public static let edgeMargin: Double = 6
    /// Distance from the tail tip to the top of the character's window. Zero means the tail
    /// touches the head exactly: no overlap, no visible gap. It is never negative.
    /// Distance from the visible tail tip to the top of the drawn artwork.
    public static let gapAbovePet: Double = 2
    /// The widest text column: max window width minus both halo margins, both paddings and
    /// both borders.
    public static let maxContentWidth: Double = maxWidth - glowInset * 2 - paddingX * 2 - borderWidth * 2
    /// Slack added to a measured text width before the clamp. Glyph ink overhangs its
    /// reported advance by a point or two, so sizing the content box to exactly the advance
    /// clips the first/last antialiased edge of a line that fits perfectly.
    public static let textInkSlack: Double = 3

    /// A short line stays compact; a long one is wrapped by the label, never shrunk.
    ///
    /// `minWidth`/`maxWidth` describe the whole window, halo margin included: the text is
    /// clamped inside that, and the halo margin is added back on both sides. So the bubble
    /// still never grows past 220 pt and never shrinks below 96 pt, glow or no glow.
    public static func width(measuredTextWidth: Double) -> Double {
        let safe = measuredTextWidth.isFinite ? max(0, measuredTextWidth) : 0
        let body = ceil(safe + paddingX * 2 + borderWidth * 2)
        let clampedBody = min(maxWidth - glowInset * 2, max(minWidth - glowInset * 2, body))
        return clampedBody + glowInset * 2
    }

    /// The radius actually used to draw the body at a given height: the design's 18 pt,
    /// reduced only when it would consume the whole edge.
    public static func effectiveCornerRadius(bodyHeight: Double) -> Double {
        guard bodyHeight.isFinite, bodyHeight > 0 else { return 0 }
        return min(cornerRadius, max(0, bodyHeight / 2 - minimumStraightEdge))
    }

    public static func lineHeight(for style: PetBubbleTextStyle) -> Double {
        switch style {
        case .subtitle: return subtitleLineHeight
        case .noticeTitle: return titleLineHeight
        case .noticeStatus: return statusLineHeight
        }
    }

    /// Body height for 1…2 measured lines, borders and paddings included.
    public static func bodyHeight(_ lines: [PetBubbleTextStyle]) -> Double {
        let count = min(2, max(1, lines.count))
        let text = (0..<count).reduce(0.0) { sum, index in sum + lineHeight(for: lines[index]) }
        return ceil(borderWidth * 2 + paddingY * 2 + text + lineSpacing * Double(count - 1))
    }

    /// Total window height: halo margin, body, tail and the rounding slack under its tip.
    public static func height(_ lines: [PetBubbleTextStyle]) -> Double {
        glowInset + bodyHeight(lines) + tailSpanInWindow + tailTipSlack
    }

    /// One dialogue line: the compact tier.
    public static func subtitleHeight(oneLine: Bool) -> Double {
        height(oneLine ? [.subtitle] : [.subtitle, .subtitle])
    }

    /// The unchanged two-line notice tier.
    public static func noticeHeight() -> Double {
        height([.noticeTitle, .noticeStatus])
    }

    /// How many lines a wrapped dialogue needs, from its measured height. A long line wraps
    /// to at most two; the font never shrinks and the last line truncates.
    public static func textLineCount(measuredHeight: Double) -> Int {
        guard measuredHeight.isFinite, measuredHeight > subtitleLineHeight * 1.5 else { return 1 }
        return 2
    }

    /// Body height implied by a window of this height.
    public static func bodyHeight(forWindowHeight windowHeight: Double) -> Double {
        max(0, windowHeight - glowInset - tailSpanInWindow - tailTipSlack)
    }

    /// The body rect inside the window: inset by the halo margin on the left/top/right, and
    /// its bottom edge exactly `tailSpan + slack` above the window's bottom.
    public static func bodyRect(width: Double, height: Double) -> PetPoseRect {
        let safeWidth = width.isFinite ? max(0, width) : 0
        guard safeWidth > 0, height.isFinite, height > glowInset + tailSpanInWindow + tailTipSlack else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        let bodyWidth = safeWidth - glowInset * 2
        guard bodyWidth > 0 else { return PetPoseRect(x: 0, y: 0, width: 0, height: 0) }
        return PetPoseRect(
            x: glowInset,
            y: glowInset,
            width: bodyWidth,
            height: bodyHeight(forWindowHeight: height)
        )
    }

    /// The ellipse's path rect (the shape itself, stroke centred on it): 22 × 15, centred on
    /// the body and `tailGap` under the body's bottom edge.
    public static func tailPathRect(width: Double, height: Double) -> PetPoseRect {
        let body = bodyRect(width: width, height: height)
        guard body.width > 0, body.height > 0, height.isFinite else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        let outerBottom = height - tailTipSlack
        return PetPoseRect(
            x: body.x + (body.width - tailWidth) / 2,
            y: outerBottom - tailStrokeInset - tailHeight,
            width: tailWidth,
            height: tailHeight
        )
    }

    /// The ellipse's outer bounding box, stroke included. Must stay inside the window.
    public static func tailOuterRect(width: Double, height: Double) -> PetPoseRect {
        let path = tailPathRect(width: width, height: height)
        guard path.width > 0, path.height > 0 else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        return PetPoseRect(
            x: path.x - tailStrokeInset,
            y: path.y - tailStrokeInset,
            width: path.width + tailStrokeInset * 2,
            height: path.height + tailStrokeInset * 2
        )
    }

    /// Where a halo pass may paint around the body, for the accent passes only.
    ///
    /// The rect keeps the body's own geometry and is grown outward by the pass's reach on the
    /// left/top/right — **never downward**. The character stands under the bubble, so the
    /// halo is cut at the body's bottom edge: the tail's own small halo is drawn around the
    /// tail ellipse alone and is likewise never allowed to reach past the tail tip.
    public static func glowRect(pass: PetBubbleGlow, width: Double, height: Double) -> PetPoseRect {
        let body = bodyRect(width: width, height: height)
        guard body.width > 0, body.height > 0, !pass.isNeutral else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        let reach = min(pass.outwardExtent, glowInset)
        return PetPoseRect(
            x: body.x - reach,
            y: body.y - reach,
            width: body.width + reach * 2,
            height: body.height + reach
        )
    }

    /// The lowest point any accent halo may paint to: the body's bottom edge, so the halo can
    /// never bleed onto the character below it.
    public static func glowBottomLimit(width: Double, height: Double) -> Double {
        let body = bodyRect(width: width, height: height)
        return body.height == 0 ? 0 : body.y + body.height + glowBottomExtent
    }

    /// The clip rect for the body halo: the window's full width, from the top down to the
    /// body's bottom edge. Everything below it is cut, which is how the "no glow below" rule
    /// is enforced instead of trusting a shadow to spread evenly.
    public static func bodyGlowClip(width: Double, height: Double) -> PetPoseRect {
        let limit = glowBottomLimit(width: width, height: height)
        guard width.isFinite, width > 0, limit > 0 else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        return PetPoseRect(x: 0, y: 0, width: width, height: limit)
    }

    /// The clip rect for the tail's own small halo: the tail expanded by `tailGlowInset` on the
    /// left/right/top only. Its bottom is the window's bottom edge, which *is* the tail tip, so
    /// nothing can bleed past it onto the character.
    public static func tailGlowClip(width: Double, height: Double) -> PetPoseRect {
        let outer = tailOuterRect(width: width, height: height)
        guard outer.width > 0, outer.height > 0, width.isFinite, height.isFinite else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        let left = max(0, outer.x - tailGlowInset)
        let right = min(width, outer.x + outer.width + tailGlowInset)
        let top = max(0, outer.y - tailGlowInset)
        guard right > left, height > top else {
            return PetPoseRect(x: 0, y: 0, width: 0, height: 0)
        }
        return PetPoseRect(x: left, y: top, width: right - left, height: height - top)
    }

    /// Preferred above the character; clamped into the screen's visible frame so it is
    /// never clipped. The pet window itself never moves to make room.
    ///
    /// `gapAbovePet` is measured from the *visible tail tip*, which sits `tailTipSlack` above
    /// the window's bottom edge — so the window origin is that much lower. A zero gap puts the
    /// tail tip exactly on the character window's top edge: no overlap, no seam.
    public static func origin(
        petFrame: PetPoseRect,
        bubbleSize: PetPoseSize,
        visibleFrame: PetPoseRect,
        petArtworkTopInset: Double = 0
    ) -> PetPosePoint {
        let preferredX = petFrame.x + (petFrame.width - bubbleSize.width) / 2
        // The pet window reserves transparent padding above the artwork so the character can
        // bob and rotate without clipping. Anchoring to `petFrame.maxY` would leave that
        // padding as a visible gap between the tail and the head, so the caller passes how
        // much padding sits above the drawn artwork and the bubble hangs from that line.
        let safeInset = petArtworkTopInset.isFinite ? max(0, min(petArtworkTopInset, petFrame.height)) : 0
        let artworkTop = petFrame.y + petFrame.height - safeInset
        let preferredY = artworkTop + gapAbovePet - tailTipSlack
        let minX = visibleFrame.minX + edgeMargin
        let maxX = max(minX, visibleFrame.maxX - bubbleSize.width - edgeMargin)
        // The bubble hangs above the character; the clamp only has to keep it on screen. A
        // zero gap still leaves the whole bubble above the pet's top edge, so the bubble can
        // be pulled down onto the pet only when the screen is too small to fit the window.
        let minY = visibleFrame.minY + edgeMargin
        let maxY = max(minY, visibleFrame.maxY - bubbleSize.height - edgeMargin)
        return PetPosePoint(
            x: min(max(preferredX, minX), maxX),
            y: min(max(preferredY, minY), maxY)
        )
    }
}
