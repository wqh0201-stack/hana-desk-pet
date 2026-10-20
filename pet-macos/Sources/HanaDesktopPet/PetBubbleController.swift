import AppKit
import PetCore
import QuartzCore

/// A borderless, non-activating panel that can never take focus or a click.
final class PetBubblePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }
}

/// Owns the single bubble window. The pet panel itself never grows, moves or changes its
/// hit region, so the character's feet and drag/dock position stay put.
final class PetBubbleController {
    private let panel: PetBubblePanel
    private let bubbleView: PetBubbleView
    private var shownContent: PetBubbleContent?
    private var shownAccent: PetBubbleAccent?
    private weak var petWindow: NSWindow?
    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var hideGeneration = 0
    private var isVisible = false
    /// Transparent padding the pet window reserves above the drawn artwork, so the bubble
    /// hangs from the character's head instead of the window's top edge.
    private var petArtworkTopInset: Double = 0

    init() {
        bubbleView = PetBubbleView(frame: NSRect(x: 0, y: 0, width: 120, height: PetBubbleLayout.noticeHeight()))
        panel = PetBubblePanel(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: PetBubbleLayout.noticeHeight()),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = bubbleView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The accent halo is drawn by the view itself, clipped above the character; the
        // window's own shadow would paint evenly in every direction, including downward onto
        // the pet, so it is off.
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false

        appHideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.hide(reduceMotion: true)
        }
    }

    deinit {
        removeObservers()
        if let appHideObserver {
            NotificationCenter.default.removeObserver(appHideObserver)
        }
    }

    /// Applies the latest resolved bubble. `enabled` is the user's single bubble preference;
    /// turning it off never changes the pose, the activity state or the binding.
    func apply(
        content: PetBubbleContent?,
        roleId: String,
        enabled: Bool,
        reduceMotion: Bool,
        petWindow: NSWindow?,
        petArtworkTopInset: Double = 0
    ) {
        self.petWindow = petWindow
        self.petArtworkTopInset = petArtworkTopInset
        let accent = PetBubbleTheme.accent(forRoleId: roleId)
        guard enabled, let content, let petWindow, petWindow.isVisible, !NSApp.isHidden else {
            hide(reduceMotion: reduceMotion)
            return
        }
        if shownContent == content, shownAccent == accent, isVisible {
            reposition()
            return
        }
        shownContent = content
        shownAccent = accent
        bubbleView.configure(content: content, accent: accent)
        let size = bubbleView.fittingBubbleSize()
        panel.setContentSize(size)
        reposition()
        if !isVisible {
            show(reduceMotion: reduceMotion)
        } else {
            panel.alphaValue = 1
        }
        observe(petWindow)
    }

    private func show(reduceMotion: Bool) {
        hideGeneration += 1
        isVisible = true
        panel.alphaValue = reduceMotion ? 1 : 0
        if let petWindow, petWindow.windowNumber > 0 {
            panel.order(.above, relativeTo: petWindow.windowNumber)
        } else {
            panel.orderFrontRegardless()
        }
        guard !reduceMotion else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hide(reduceMotion: Bool) {
        guard isVisible else { return }
        hideGeneration += 1
        let generation = hideGeneration
        isVisible = false
        shownContent = nil
        shownAccent = nil
        if reduceMotion {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideGeneration == generation else { return }
            self.panel.orderOut(nil)
        })
    }

    private func reposition() {
        guard let petWindow, let screen = petWindow.screen ?? NSScreen.main else { return }
        let petFrame = petWindow.frame
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = PetBubbleLayout.origin(
            petFrame: PetPoseRect(
                x: petFrame.minX,
                y: petFrame.minY,
                width: petFrame.width,
                height: petFrame.height
            ),
            bubbleSize: PetPoseSize(width: size.width, height: size.height),
            visibleFrame: PetPoseRect(
                x: visible.minX,
                y: visible.minY,
                width: visible.width,
                height: visible.height
            ),
            petArtworkTopInset: petArtworkTopInset
        )
        panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y))
    }

    private func observe(_ window: NSWindow) {
        guard moveObserver == nil else { return }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }

    private func removeObservers() {
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
            self.moveObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

/// The quiet surface: an opaque white rounded body with an accent border, and an
/// independent small ellipse under its middle as the tail. Both are drawn inside the
/// window's bounds, so the tail is never clipped.
private final class PetBubbleView: NSView {
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var accent = PetBubbleTheme.fallback
    private var style: PetBubbleStyle = .subtitle
    private var measuredLines = 1

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // A dialogue line: 13 pt, centred, wrapped to at most two lines and never shrunk.
        // The paragraph style keeps the last visible line inside the padded width.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.lineSpacing = CGFloat(PetBubbleLayout.lineSpacing)
        subtitleLabel.font = NSFont.systemFont(ofSize: CGFloat(PetBubbleLayout.subtitleFontSize))
        subtitleLabel.textColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.cell?.wraps = true
        subtitleLabel.cell?.truncatesLastVisibleLine = true
        subtitleLabel.allowsDefaultTighteningForTruncation = true
        subtitleLabel.isEditable = false
        subtitleLabel.isSelectable = false
        subtitleLabel.isBezeled = false
        subtitleLabel.drawsBackground = false

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.isEditable = false
        titleLabel.isSelectable = false
        titleLabel.isBezeled = false
        titleLabel.drawsBackground = false

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = NSColor(calibratedWhite: 0.38, alpha: 1)
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.isEditable = false
        statusLabel.isSelectable = false
        statusLabel.isBezeled = false
        statusLabel.drawsBackground = false

        addSubview(subtitleLabel)
        addSubview(titleLabel)
        addSubview(statusLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        applyParagraph()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func configure(content: PetBubbleContent, accent: PetBubbleAccent) {
        self.style = content.style
        self.accent = accent
        let isSubtitle = content.style == .subtitle
        subtitleLabel.isHidden = !isSubtitle
        titleLabel.isHidden = isSubtitle
        statusLabel.isHidden = isSubtitle
        if isSubtitle {
            subtitleLabel.stringValue = content.status
            // The accent is border-only; the text colour never changes.
            setAccessibilityLabel(content.status)
            // Decide the line count from the *natural* width before applying the cell mode,
            // because the wrapping mode itself shortens what AppKit will measure.
            let naturalWidth = ceil(naturalSubtitleWidth(of: content.status))
            measuredLines = naturalWidth + PetBubbleLayout.paddingX * 2 + PetBubbleLayout.borderWidth * 2
                > PetBubbleLayout.maxWidth ? 2 : 1
        } else {
            titleLabel.stringValue = content.title
            statusLabel.stringValue = content.status
            setAccessibilityLabel("\(content.title)，\(content.status)")
            measuredLines = 1
        }
        applyParagraph()
        needsLayout = true
        needsDisplay = true
    }

    /// The width clamp is unchanged; a long line wraps instead of shrinking.
    ///
    /// Text is measured with `cellSize(forBounds:)`, which is the only measurement that agrees
    /// with what the cell will demand at draw time. `intrinsicContentSize` under-reports it
    /// (measured: 76 pt vs. 79.51 pt for "桌宠气泡实测"), and the 0.51 pt shortfall was enough
    /// for AppKit to ellipsize a title that should have fit. `boundingRect` over-reports for
    /// centred attributed text, so neither of those is used for sizing any more.
    func fittingBubbleSize() -> NSSize {
        if style != .subtitle {
            let needed = max(
                requiredTextWidth(of: titleLabel),
                requiredTextWidth(of: statusLabel)
            )
            let width = PetBubbleLayout.width(measuredTextWidth: ceil(needed))
            let contentWidth = width - PetBubbleLayout.paddingX * 2 - PetBubbleLayout.borderWidth * 2
            applyNoticeTruncation(contentWidth: contentWidth)
            return NSSize(width: width, height: PetBubbleLayout.noticeHeight())
        }
        let needed = requiredTextWidth(of: subtitleLabel)
        let width = PetBubbleLayout.width(measuredTextWidth: ceil(needed))
        let contentWidth = width - PetBubbleLayout.paddingX * 2 - PetBubbleLayout.borderWidth * 2
        // Re-check the line count at the width actually granted, then re-apply the cell mode
        // so the label draws with the truncation rule its height was sized for.
        let lines = lineCount(atContentWidth: contentWidth)
        if lines != measuredLines {
            measuredLines = lines
            applyParagraph()
        }
        return NSSize(
            width: width,
            height: PetBubbleLayout.height(lines > 1 ? [.subtitle, .subtitle] : [.subtitle])
        )
    }

    /// The width the cell really needs for this text on one line, unbounded.
    private func requiredTextWidth(of field: NSTextField) -> Double {
        guard !field.stringValue.isEmpty else { return 0 }
        let height = max(field.frame.height, CGFloat(PetBubbleLayout.subtitleLineHeight))
        let size = field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: height))
        return Double(size?.width ?? 0)
    }

    /// A notice line truncates only when it genuinely cannot fit; otherwise it clips, because
    /// `byTruncatingTail` makes AppKit reserve room for an ellipsis the line does not need.
    private func applyNoticeTruncation(contentWidth: Double) {
        let fits = requiredTextWidth(of: titleLabel) <= contentWidth + 0.01
        titleLabel.lineBreakMode = fits ? .byClipping : .byTruncatingTail
    }

    private func naturalSubtitleWidth(of text: String) -> Double {
        requiredTextWidth(of: subtitleLabel)
    }

    private func lineCount(atContentWidth contentWidth: Double) -> Int {
        guard !subtitleLabel.stringValue.isEmpty, let font = subtitleLabel.font, contentWidth > 0 else {
            return 1
        }
        let rect = subtitleLabel.stringValue.boundingRect(
            with: NSSize(width: contentWidth, height: 10_000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return PetBubbleLayout.textLineCount(measuredHeight: Double(rect.height))
    }

    private func applyParagraph() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = CGFloat(PetBubbleLayout.lineSpacing)
        guard let font = subtitleLabel.font else { return }
        // The cell must not reserve ellipsis room on a line that fits exactly: with
        // `wraps + truncatesLastVisibleLine` AppKit measures against the width *minus* an
        // ellipsis, which truncated short ordinary lines ("跑一下～" became "跑一…").
        // One line, no truncation; two lines, wrap and truncate the last one.
        paragraph.lineBreakMode = measuredLines > 1 ? .byTruncatingTail : .byClipping
        subtitleLabel.cell?.wraps = measuredLines > 1
        subtitleLabel.cell?.truncatesLastVisibleLine = measuredLines > 1
        subtitleLabel.maximumNumberOfLines = measuredLines > 1 ? 2 : 1
        subtitleLabel.attributedStringValue = NSAttributedString(
            string: subtitleLabel.stringValue,
            attributes: [
                .font: font,
                .foregroundColor: subtitleLabel.textColor ?? NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }


    override func layout() {
        super.layout()
        let body = PetBubbleLayout.bodyRect(width: Double(bounds.width), height: Double(bounds.height))
        guard body.width > 0, body.height > 0 else { return }
        let border = CGFloat(PetBubbleLayout.borderWidth)
        let paddingX = CGFloat(PetBubbleLayout.paddingX)
        let paddingY = CGFloat(PetBubbleLayout.paddingY)
        let contentWidth = max(0, CGFloat(body.width) - (paddingX + border) * 2)
        let top = CGFloat(body.y) + paddingY + border
        if style == .subtitle {
            let lineHeight = CGFloat(PetBubbleLayout.subtitleLineHeight)
            let height = measuredLines > 1
                ? lineHeight * 2 + CGFloat(PetBubbleLayout.lineSpacing)
                : lineHeight
            subtitleLabel.frame = NSRect(
                x: CGFloat(body.x) + paddingX + border,
                y: top,
                width: contentWidth,
                height: height
            )
            return
        }
        titleLabel.frame = NSRect(
            x: CGFloat(body.x) + paddingX + border,
            y: top,
            width: contentWidth,
            height: CGFloat(PetBubbleLayout.titleLineHeight)
        )
        statusLabel.frame = NSRect(
            x: CGFloat(body.x) + paddingX + border,
            y: top + CGFloat(PetBubbleLayout.titleLineHeight) + CGFloat(PetBubbleLayout.lineSpacing),
            width: contentWidth,
            height: CGFloat(PetBubbleLayout.statusLineHeight)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        let body = PetBubbleLayout.bodyRect(width: width, height: height)
        let bodyRect = NSRect(x: body.x, y: body.y, width: body.width, height: body.height)
        guard bodyRect.width > 0, bodyRect.height > 0 else { return }

        let accentColor = NSColor(
            srgbRed: CGFloat(accent.red),
            green: CGFloat(accent.green),
            blue: CGFloat(accent.blue),
            alpha: 1
        )
        let stroke = CGFloat(PetBubbleLayout.borderWidth)
        let cornerRadius = CGFloat(PetBubbleLayout.effectiveCornerRadius(bodyHeight: body.height))
        let bodyPath = NSBezierPath(
            roundedRect: bodyRect.insetBy(dx: stroke / 2, dy: stroke / 2),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        let neutral = NSColor(srgbRed: 40 / 255, green: 60 / 255, blue: 90 / 255, alpha: 1)

        // Everything is composed into one opaque, screen-space bitmap first. Drawing the halo
        // straight into the window would blend it against the view's own translucent layers
        // (the panel is non-opaque), which desaturated it into grey and left visible banding.
        // Compositing once, against the wallpaper the user actually has, is the only way the
        // accent halo reads as the character's colour.
        let scale = window?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int((width * scale).rounded()))
        let pixelHeight = max(1, Int((height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        bitmap.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // The bitmap is bottom-up like Core Graphics, so flip into the view's top-left space.
        let flip = NSAffineTransform()
        flip.translateX(by: 0, yBy: CGFloat(height))
        flip.scaleX(by: 1, yBy: -1)
        flip.concat()

        // 1. The accent halo, clipped so it only ever grows left, up and right.
        drawGlow(bodyPath: bodyPath, accent: accentColor, neutral: neutral)

        // 2. The body: opaque white fill, 1 pt accent hairline.
        NSColor.white.setFill()
        bodyPath.fill()
        accentColor.setStroke()
        bodyPath.lineWidth = stroke
        bodyPath.stroke()

        // 3. The tail: an independent small ellipse with its own small halo, drawn last so its
        //    white fill closes the outline where it meets the body.
        let tail = PetBubbleLayout.tailPathRect(width: width, height: height)
        let tailRect = NSRect(x: tail.x, y: tail.y, width: tail.width, height: tail.height)
        if tailRect.width > 0, tailRect.height > 0 {
            let tailPath = NSBezierPath(ovalIn: tailRect)
            drawTailGlow(tailPath: tailPath, accent: accentColor)
            NSColor.white.setFill()
            tailPath.fill()
            accentColor.setStroke()
            tailPath.lineWidth = CGFloat(PetBubbleLayout.tailBorderWidth)
            tailPath.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Put the composed bitmap on screen. Outside the drawn shapes the bitmap is fully
        // transparent, so the panel stays click-through and shows no box.
        guard let image = bitmap.cgImage else { return }
        NSGraphicsContext.saveGraphicsState()
        if let current = NSGraphicsContext.current {
            current.imageInterpolation = .high
        }
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Paints the accent halo passes and the neutral drop shadow into the current context.
    ///
    /// Each pass replicates one CSS `box-shadow` layer: the body path is filled with a shadow
    /// active and the body's own area is clipped away, so only the blur outside the border
    /// survives. A CSS `spread` grows the shadow's shape before blurring; doing that literally
    /// would start each pass's blur from a new hard edge and stack visible concentric rings, so
    /// the spread is folded into the blur radius instead: every pass decays continuously from
    /// the same border and still reaches out by `offset + blur + spread`.
    private func drawGlow(bodyPath: NSBezierPath, accent: NSColor, neutral: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let width = Double(bounds.width)
        let height = Double(bounds.height)
        let clip = PetBubbleLayout.bodyGlowClip(width: width, height: height)
        guard clip.width > 0, clip.height > 0 else { return }
        let bodyShape = NSBezierPath(
            roundedRect: bodyRectForDrawing(),
            xRadius: CGFloat(effectiveCornerRadius()),
            yRadius: CGFloat(effectiveCornerRadius())
        )
        let clipRect = NSRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)
        let tail = PetBubbleLayout.tailPathRect(width: width, height: height)
        let tailExclusion = NSBezierPath(ovalIn: NSRect(x: tail.x, y: tail.y, width: tail.width, height: tail.height))
        for pass in PetBubbleLayout.accentGlows {
            drawShadowPass(
                pass,
                shape: bodyShape,
                exclusions: [bodyShape, tailExclusion],
                color: accent,
                clipRect: clipRect,
                context: context
            )
        }
        drawShadowPass(
            PetBubbleLayout.glowNeutral,
            shape: bodyShape,
            exclusions: [bodyShape, tailExclusion],
            color: neutral,
            clipRect: clipRect,
            context: context
        )
    }

    private func bodyRectForDrawing() -> NSRect {
        let body = PetBubbleLayout.bodyRect(width: Double(bounds.width), height: Double(bounds.height))
        return NSRect(x: body.x, y: body.y, width: body.width, height: body.height)
    }

    /// The radius the body is actually drawn with (see PetBubbleLayout.effectiveCornerRadius).
    private func effectiveCornerRadius() -> Double {
        let body = PetBubbleLayout.bodyRect(width: Double(bounds.width), height: Double(bounds.height))
        return PetBubbleLayout.effectiveCornerRadius(bodyHeight: body.height)
    }

    private func drawTailGlow(tailPath: NSBezierPath, accent: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let clip = PetBubbleLayout.tailGlowClip(width: Double(bounds.width), height: Double(bounds.height))
        guard clip.width > 0, clip.height > 0 else { return }
        let clipRect = NSRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)
        let pass = PetBubbleGlow(offsetX: 0, offsetY: 1, blurRadius: 4, spread: 0, alpha: 0.22)
        drawShadowPass(
            pass,
            shape: tailPath,
            exclusions: [tailPath],
            color: accent,
            clipRect: clipRect,
            context: context
        )
    }

    /// One `box-shadow`-style pass: the halo only, never the shape's own fill.
    private func drawShadowPass(
        _ pass: PetBubbleGlow,
        shape: NSBezierPath,
        exclusions: [NSBezierPath],
        color: NSColor,
        clipRect: NSRect,
        context: CGContext
    ) {
        guard let shadowColor = color.cgColor.copy(alpha: CGFloat(pass.alpha)) else { return }
        context.saveGState()
        defer { context.restoreGState() }

        // Clip = the allowed band (full width, down to the body's bottom edge) minus the shape
        // itself and the tail. Each exclusion is its own even-odd clip: one combined even-odd
        // path would re-include the overlap and paint an opaque band under the body.
        context.clip(to: clipRect)
        for exclusion in exclusions {
            var cut = CGMutablePath()
            cut.addRect(clipRect)
            CGPathApplier.append(exclusion, to: &cut)
            context.addPath(cut)
            context.clip(using: .evenOdd)
        }

        context.setShadow(
            offset: CGSize(width: pass.offsetX, height: -pass.offsetY),
            blur: CGFloat(pass.blurRadius + pass.spread),
            color: shadowColor
        )
        // The shadow's source fill must be *white*, not black. Core Graphics premultiplies the
        // source over the shadow colour: a black fill over a transparent backdrop produced a
        // nearly black, desaturated halo (measured #050911 at 9 % alpha instead of the accent),
        // which is what made the glow read grey. White keeps the shadow's own colour intact.
        NSColor.white.setFill()
        shape.fill()
    }
}

/// Appends an `NSBezierPath` to a `CGMutablePath` without the macOS 14-only `cgPath`.
/// All we ever append are rounded rects and ellipses, so cubic curves and lines suffice.
private enum CGPathApplier {
    static func append(_ path: NSBezierPath, to target: inout CGMutablePath) {
        var points = [NSPoint](repeating: .zero, count: 3)
        var started = false
        for index in 0..<path.elementCount {
            let element = path.element(at: index, associatedPoints: &points)
            switch element {
            case .moveTo:
                target.move(to: CGPoint(x: points[0].x, y: points[0].y))
                started = true
            case .lineTo:
                if started { target.addLine(to: CGPoint(x: points[0].x, y: points[0].y)) }
            case .curveTo:
                if started {
                    target.addCurve(
                        to: CGPoint(x: points[2].x, y: points[2].y),
                        control1: CGPoint(x: points[0].x, y: points[0].y),
                        control2: CGPoint(x: points[1].x, y: points[1].y)
                    )
                }
            case .closePath:
                if started { target.closeSubpath() }
            default:
                // `NSBezierPath.ElementType` may grow; unknown elements are simply skipped.
                break
            }
        }
    }
}
