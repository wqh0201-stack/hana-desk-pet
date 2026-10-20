using System;

namespace HanaDesktopPet.Core
{
    internal struct PetBubbleRect
    {
        internal double X;
        internal double Y;
        internal double Width;
        internal double Height;

        internal PetBubbleRect(double x, double y, double width, double height)
        {
            X = x;
            Y = y;
            Width = width;
            Height = height;
        }
    }

    internal struct PetBubblePoint
    {
        internal double X;
        internal double Y;

        internal PetBubblePoint(double x, double y)
        {
            X = x;
            Y = y;
        }
    }

    /// <summary>
    /// One halo pass: the accent glow drawn *outside* the 1 pt border. Modelled on a CSS
    /// box-shadow layer so both native ends can reproduce it with their own primitives
    /// (AppKit CGContext.setShadow, WPF DropShadowEffect).
    /// </summary>
    internal struct PetBubbleGlow
    {
        internal double OffsetX;
        internal double OffsetY;
        internal double BlurRadius;
        internal double Spread;
        internal double Alpha;
        /// <summary>True for the neutral drop shadow, which is not tinted by the character.</summary>
        internal bool IsNeutral;

        internal PetBubbleGlow(double offsetX, double offsetY, double blurRadius, double spread,
            double alpha, bool isNeutral)
        {
            OffsetX = offsetX;
            OffsetY = offsetY;
            BlurRadius = blurRadius;
            Spread = spread;
            Alpha = alpha;
            IsNeutral = isNeutral;
        }

        /// <summary>How far this pass can paint beyond the shape's own edge.</summary>
        internal double OutwardExtent
        {
            get { return Math.Abs(OffsetX) + BlurRadius + Spread; }
        }
    }

    /// <summary>
    /// Pure bubble geometry shared by the WPF window and the synthetic checks.
    ///
    /// The bubble is a large rounded rectangle with an independent small ellipse tail: white
    /// fill, a 1 pt accent hairline, 18 pt corners, and a 22 x 15 pt ellipse 1 pt thick under
    /// the middle of the body. Outside the border a two-layer accent halo grows left, up and
    /// right only. Each tier's height includes the tail *and* the halo margin.
    /// </summary>
    internal static class PetBubbleLayout
    {
        internal const double MaxWidth = 220.0;
        internal const double MinWidth = 96.0;
        /// <summary>Horizontal padding inside the border.</summary>
        internal const double PaddingX = 17.0;
        /// <summary>Vertical padding inside the border.</summary>
        internal const double PaddingY = 9.0;
        internal const double LineSpacing = 2.0;
        internal const double CornerRadius = 18.0;
        /// <summary>Accent-coloured hairline border, drawn inside the body rect.</summary>
        internal const double BorderWidth = 1.0;
        /// <summary>Dialogue font size. It never shrinks; a long line wraps instead.</summary>
        internal const double SubtitleFontSize = 13.0;
        /// <summary>Measured single-line height of the 13 pt system font, rounded up.</summary>
        internal const double SubtitleLineHeight = 16.0;
        internal const double TitleLineHeight = 15.0;
        /// <summary>Measured: the 11 pt regular font needs 13 pt.</summary>
        internal const double StatusLineHeight = 13.0;
        internal const double TailWidth = 22.0;
        internal const double TailHeight = 15.0;
        internal const double TailBorderWidth = 1.0;
        /// <summary>Gap between the body's bottom edge and the ellipse's outer top edge.</summary>
        internal const double TailGap = 4.0;
        /// <summary>Half of <see cref="TailBorderWidth"/>: the stroke's own half-width.</summary>
        internal const double TailStrokeInset = 0.5;
        /// <summary>Body bottom to the tail's outer tip: 4 + 15 + 1 = 20 pt.</summary>
        internal const double TailSpan = TailGap + TailHeight + TailStrokeInset * 2.0;
        /// <summary>The tail's space in the window height (equals TailSpan; no rounding slack).</summary>
        internal const double TailSpanInWindow = TailSpan;
        /// <summary>Transparent slack under the tail tip: zero at the current tail span.</summary>
        internal const double TailTipSlack = TailSpanInWindow - TailSpan;

        // Halo passes, innermost first.
        internal const double GlowHugAlpha = 0.22;
        internal const double GlowHugSpread = 0.5;
        internal const double GlowMainBlur = 7.0;
        internal const double GlowMainSpread = 2.0;
        internal const double GlowMainAlpha = 0.26;
        internal const double GlowOuterBlur = 16.0;
        internal const double GlowOuterSpread = 5.0;
        internal const double GlowOuterAlpha = 0.14;
        internal const double GlowNeutralAlpha = 0.06;

        /// <summary>
        /// Halo margin reserved on the left, top and right of the window. The widest pass
        /// reaches 21 pt, but it is only 14 % opaque out there, so 8 pt is kept: the halo fades
        /// into the wallpaper instead of growing a mostly invisible transparent border.
        /// </summary>
        internal const double GlowInset = 8.0;
        /// <summary>The halo never paints below the body: the character is right underneath.</summary>
        internal const double GlowBottomExtent = 0.0;
        /// <summary>The tail's own halo reach, sideways and up. Never past the tail tip.</summary>
        internal const double TailGlowInset = 4.0;

        internal const double EdgeMargin = 6.0;
        /// <summary>
        /// Distance from the tail tip to the top of the drawn artwork. Two points keep the
        /// halo off the head without a visible gap; it is never negative.
        /// </summary>
        internal const double GapAbovePet = 2.0;
        /// <summary>A rounded rectangle keeps a visible straight edge; the radius is capped below height/2.</summary>
        internal const double MinimumStraightEdge = 3.0;

        /// <summary>
        /// Effective corner radius for a body of this height. The 18 pt design turns into an
        /// ellipse on a ~36 pt body, so the radius stops `MinimumStraightEdge` short of half
        /// the height.
        /// </summary>
        internal static double CornerRadiusFor(double bodyHeight)
        {
            if (!IsFinite(bodyHeight) || bodyHeight <= 0) return 0.0;
            return Math.Max(0.0, Math.Min(CornerRadius, bodyHeight / 2.0 - MinimumStraightEdge));
        }

        /// <summary>The text column inside a window of this width.</summary>
        internal static double ContentWidthForWindow(double windowWidth)
        {
            if (!IsFinite(windowWidth)) return MaxContentWidth;
            return Math.Max(1.0, windowWidth - GlowInset * 2.0 - PaddingX * 2.0 - BorderWidth * 2.0);
        }

        /// <summary>Widest text column: max window width minus halo margins, paddings, borders.</summary>
        internal const double MaxContentWidth =
            MaxWidth - GlowInset * 2.0 - PaddingX * 2.0 - BorderWidth * 2.0;

        internal enum TextStyle
        {
            Subtitle,
            NoticeTitle,
            NoticeStatus
        }

        internal static readonly PetBubbleGlow GlowHug =
            new PetBubbleGlow(0, 0, 0, GlowHugSpread, GlowHugAlpha, false);
        internal static readonly PetBubbleGlow GlowMain =
            new PetBubbleGlow(0, 0, GlowMainBlur, GlowMainSpread, GlowMainAlpha, false);
        internal static readonly PetBubbleGlow GlowOuter =
            new PetBubbleGlow(0, 0, GlowOuterBlur, GlowOuterSpread, GlowOuterAlpha, false);
        internal static readonly PetBubbleGlow GlowNeutral =
            new PetBubbleGlow(0, 1, 3, 0, GlowNeutralAlpha, true);

        /// <summary>Every accent pass, innermost first.</summary>
        internal static readonly PetBubbleGlow[] AccentGlows = new[] { GlowHug, GlowMain, GlowOuter };

        /// <summary>
        /// A short line stays compact; a long one is wrapped, never shrunk. MinWidth/MaxWidth
        /// describe the whole window, halo margin included.
        /// </summary>
        internal static double Width(double measuredTextWidth)
        {
            double safe = IsFinite(measuredTextWidth) ? Math.Max(0, measuredTextWidth) : 0;
            double body = Math.Ceiling(safe + PaddingX * 2.0 + BorderWidth * 2.0);
            double clamped = Math.Min(MaxWidth - GlowInset * 2.0,
                Math.Max(MinWidth - GlowInset * 2.0, body));
            return clamped + GlowInset * 2.0;
        }

        internal static double LineHeight(TextStyle style)
        {
            switch (style)
            {
                case TextStyle.NoticeTitle: return TitleLineHeight;
                case TextStyle.NoticeStatus: return StatusLineHeight;
                default: return SubtitleLineHeight;
            }
        }

        /// <summary>Body height for the given text lines, borders and paddings included.</summary>
        internal static double BodyHeight(TextStyle[] lines)
        {
            int count = Math.Min(2, Math.Max(1, lines == null ? 1 : lines.Length));
            double text = 0.0;
            for (int i = 0; i < count; i++) text += LineHeight(lines[i]);
            return Math.Ceiling(BorderWidth * 2.0 + PaddingY * 2.0 + text + LineSpacing * (count - 1));
        }

        /// <summary>Total window height: halo margin, body, tail and rounding slack.</summary>
        internal static double Height(TextStyle[] lines)
        {
            return GlowInset + BodyHeight(lines) + TailSpanInWindow + TailTipSlack;
        }

        internal static double SubtitleHeight(bool oneLine)
        {
            return oneLine
                ? Height(new[] { TextStyle.Subtitle })
                : Height(new[] { TextStyle.Subtitle, TextStyle.Subtitle });
        }

        internal static double NoticeHeight()
        {
            return Height(new[] { TextStyle.NoticeTitle, TextStyle.NoticeStatus });
        }

        /// <summary>Body height implied by a window of this height.</summary>
        internal static double BodyHeightForWindow(double windowHeight)
        {
            return Math.Max(0.0, windowHeight - GlowInset - TailSpanInWindow - TailTipSlack);
        }

        /// <summary>The body rect inside the window, inset by the halo margin.</summary>
        internal static PetBubbleRect BodyRect(double width, double height)
        {
            if (!IsFinite(width) || !IsFinite(height) || width <= 0 ||
                height <= GlowInset + TailSpanInWindow + TailTipSlack)
                return new PetBubbleRect(0, 0, 0, 0);
            double bodyWidth = width - GlowInset * 2.0;
            if (bodyWidth <= 0) return new PetBubbleRect(0, 0, 0, 0);
            return new PetBubbleRect(GlowInset, GlowInset, bodyWidth, BodyHeightForWindow(height));
        }

        /// <summary>The ellipse itself (stroke centred on it), centred on the body.</summary>
        internal static PetBubbleRect TailPathRect(double width, double height)
        {
            PetBubbleRect body = BodyRect(width, height);
            if (body.Width <= 0 || body.Height <= 0) return new PetBubbleRect(0, 0, 0, 0);
            double outerBottom = height - TailTipSlack;
            return new PetBubbleRect(
                body.X + (body.Width - TailWidth) / 2.0,
                outerBottom - TailStrokeInset - TailHeight,
                TailWidth,
                TailHeight);
        }

        /// <summary>The ellipse's outer bounding box, stroke included. Stays inside the window.</summary>
        internal static PetBubbleRect TailOuterRect(double width, double height)
        {
            PetBubbleRect path = TailPathRect(width, height);
            if (path.Width <= 0 || path.Height <= 0) return new PetBubbleRect(0, 0, 0, 0);
            return new PetBubbleRect(
                path.X - TailStrokeInset,
                path.Y - TailStrokeInset,
                path.Width + TailStrokeInset * 2.0,
                path.Height + TailStrokeInset * 2.0);
        }

        /// <summary>
        /// Where a halo pass may paint around the body: grown left/top/right by the pass's
        /// reach, never downward.
        /// </summary>
        internal static PetBubbleRect GlowRect(PetBubbleGlow pass, double width, double height)
        {
            PetBubbleRect body = BodyRect(width, height);
            if (body.Width <= 0 || body.Height <= 0 || pass.IsNeutral) return new PetBubbleRect(0, 0, 0, 0);
            double reach = Math.Min(pass.OutwardExtent, GlowInset);
            return new PetBubbleRect(
                body.X - reach,
                body.Y - reach,
                body.Width + reach * 2.0,
                body.Height + reach);
        }

        /// <summary>The lowest point any accent halo may paint to: the body's bottom edge.</summary>
        internal static double GlowBottomLimit(double width, double height)
        {
            PetBubbleRect body = BodyRect(width, height);
            return body.Height <= 0 ? 0.0 : body.Y + body.Height + GlowBottomExtent;
        }

        /// <summary>
        /// The clip rect for the body halo: full window width, from the top down to the body's
        /// bottom edge. Everything below is cut — that is how "no glow below" is enforced
        /// instead of trusting a shadow to spread evenly.
        /// </summary>
        internal static PetBubbleRect BodyGlowClip(double width, double height)
        {
            double limit = GlowBottomLimit(width, height);
            if (!IsFinite(width) || width <= 0 || limit <= 0) return new PetBubbleRect(0, 0, 0, 0);
            return new PetBubbleRect(0, 0, width, limit);
        }

        /// <summary>
        /// The clip rect for the tail's own small halo: the tail grown by TailGlowInset on the
        /// left/right/top only. Its bottom is the window's bottom edge, which is the tail tip.
        /// </summary>
        internal static PetBubbleRect TailGlowClip(double width, double height)
        {
            PetBubbleRect outer = TailOuterRect(width, height);
            if (outer.Width <= 0 || outer.Height <= 0) return new PetBubbleRect(0, 0, 0, 0);
            double left = Math.Max(0, outer.X - TailGlowInset);
            double right = Math.Min(width, outer.X + outer.Width + TailGlowInset);
            double top = Math.Max(0, outer.Y - TailGlowInset);
            if (right <= left || height <= top) return new PetBubbleRect(0, 0, 0, 0);
            return new PetBubbleRect(left, top, right - left, height - top);
        }

        /// <summary>
        /// Preferred above the character, clamped into the monitor work area. The pet window
        /// itself never moves to make room, so its feet stay put. GapAbovePet is measured from
        /// the visible tail tip; a zero gap puts it exactly on the character's top edge.
        /// </summary>
        internal static PetBubblePoint Origin(PetBubbleRect petFrame, double bubbleWidth,
            double bubbleHeight, PetBubbleRect visibleFrame, double petArtworkTopInset)
        {
            double preferredX = petFrame.X + (petFrame.Width - bubbleWidth) / 2.0;
            // Windows screen coordinates grow downwards: petFrame.Y is the window's top edge and
            // the drawn artwork starts petArtworkTopInset below it, because the pet window keeps
            // transparent room above the character for its sway. The tail tip hangs GapAbovePet
            // above that artwork line, so the window's own top sits one bubble height higher.
            double safeInset = IsFinite(petArtworkTopInset)
                ? Math.Max(0.0, Math.Min(petArtworkTopInset, petFrame.Height))
                : 0.0;
            double artworkTop = petFrame.Y + safeInset;
            double preferredY = artworkTop - GapAbovePet - bubbleHeight + TailTipSlack;
            double minX = visibleFrame.X + EdgeMargin;
            double maxX = Math.Max(minX, visibleFrame.X + visibleFrame.Width - bubbleWidth - EdgeMargin);
            double minY = visibleFrame.Y + EdgeMargin;
            double maxY = Math.Max(minY, visibleFrame.Y + visibleFrame.Height - bubbleHeight - EdgeMargin);
            return new PetBubblePoint(
                Math.Min(Math.Max(preferredX, minX), maxX),
                Math.Min(Math.Max(preferredY, minY), maxY));
        }

        private static bool IsFinite(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value);
        }
    }
}
