import AppKit
import PetCore

final class PetWindowView: NSView, NSMenuDelegate {
    private let model: PetViewModel
    private let artwork: PetCharacterView
    private var refreshTimer: Timer?
    private var avoidanceTimer: Timer?
    private var pointerGesture = PetDragClickGesture()
    private var eventPolicy = PetWindowEventPolicy()
    private var dragStartWindowOrigin: NSPoint?
    private weak var attachedWindow: NSWindow?

    init(
        model: PetViewModel,
        artworkCatalog: PetArtworkCatalog?,
        layout: PetCharacterLayout,
        poseReadback: PetPoseReadbackStore = .shared
    ) {
        self.model = model
        self.artwork = PetCharacterView(
            catalog: artworkCatalog,
            layout: layout,
            poseReadback: poseReadback,
            frame: .zero
        )
        super.init(frame: NSRect(
            x: 0,
            y: 0,
            width: layout.windowSize.width,
            height: layout.windowSize.height
        ))
        buildInterface()
        model.onChange = { [weak self] in self?.render() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak model] _ in
            model?.refresh()
        }
        // Poll the cursor position at 30 Hz; this is not a global event monitor and adds no permission.
        let avoidanceTimer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.synchronizeMouseAvoidance()
        }
        RunLoop.main.add(avoidanceTimer, forMode: .common)
        self.avoidanceTimer = avoidanceTimer
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        refreshTimer?.invalidate()
        avoidanceTimer?.invalidate()
        attachedWindow?.ignoresMouseEvents = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let attachedWindow, attachedWindow !== window {
            attachedWindow.ignoresMouseEvents = false
            pointerGesture.cancel()
            dragStartWindowOrigin = nil
            eventPolicy.reset()
            artwork.endDragPickUp()
        }
        guard let window else {
            attachedWindow?.ignoresMouseEvents = false
            attachedWindow = nil
            pointerGesture.cancel()
            dragStartWindowOrigin = nil
            eventPolicy.reset()
            artwork.endDragPickUp()
            return
        }
        attachedWindow = window
        window.ignoresMouseEvents = false
        synchronizeMouseAvoidance()
    }

    private func buildInterface() {
        artwork.translatesAutoresizingMaskIntoConstraints = false
        addSubview(artwork)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: leadingAnchor),
            artwork.trailingAnchor.constraint(equalTo: trailingAnchor),
            artwork.topAnchor.constraint(equalTo: topAnchor),
            artwork.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        artwork.onActivate = { [weak self] in self?.activatePet() }
    }

    private func render() {
        let state = model.state
        let roleName = state.roles.first(where: { $0.id == state.selection.characterId })?.name ?? "桌宠"
        let toolName = state.appConnected ? state.activity.toolName : nil
        artwork.update(
            roleId: state.selection.characterId,
            roleName: roleName,
            sessionId: state.activity.sessionId,
            status: state.displayStatus,
            toolName: toolName,
            lastActivityAt: state.activity.lastActivityAt,
            hint: state.displayHint
        )
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // This filters AppKit's in-process view hit only; it does not shape the WindowServer window input region.
        let localPoint = superview.map { convert(point, from: $0) } ?? point
        let artworkPoint = artwork.convert(localPoint, from: self)
        return artwork.hitShapeContains(artworkPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let screenPoint = screenPoint(for: event) else { return }
        eventPolicy.beginPointerSequence()
        artwork.beginPointerInteraction()
        window?.ignoresMouseEvents = false
        pointerGesture.begin(at: PetPointerPoint(x: screenPoint.x, y: screenPoint.y))
        dragStartWindowOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard let screenPoint = screenPoint(for: event) else { return }
        let point = PetPointerPoint(x: screenPoint.x, y: screenPoint.y)
        guard let translation = pointerGesture.drag(to: point),
              let dragStartWindowOrigin,
              let window else { return }
        // Only a drag that really crosses the threshold with an unlocked position enters the
        // pick-up loop, and only along with the window move it is describing.
        guard PetPickUpAnimation.shouldBeginDrag(
            translation: translation,
            positionLocked: model.positionLocked
        ) else { return }
        window.setFrameOrigin(NSPoint(
            x: dragStartWindowOrigin.x + translation.x,
            y: dragStartWindowOrigin.y + translation.y
        ))
        // Idempotent, so a stream of mouseDragged events cannot restart the rhythm.
        artwork.beginDragPickUp()
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragStartWindowOrigin = nil
            eventPolicy.endPointerSequence()
            synchronizeMouseAvoidance()
        }
        artwork.endDragPickUp()
        guard let screenPoint = screenPoint(for: event) else {
            pointerGesture.cancel()
            return
        }
        let shouldActivate = pointerGesture.end(at: PetPointerPoint(x: screenPoint.x, y: screenPoint.y))
        guard shouldActivate,
              let artworkPoint = artworkPoint(for: event),
              artwork.hitShapeContains(artworkPoint) else { return }
        activatePet()
    }

    override func cancelOperation(_ sender: Any?) {
        pointerGesture.cancel()
        dragStartWindowOrigin = nil
        eventPolicy.cancelPointerSequence()
        artwork.endDragPickUp()
        synchronizeMouseAvoidance()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let artworkPoint = artworkPoint(for: event), artwork.hitShapeContains(artworkPoint) else { return nil }
        let menu = NSMenu(title: "桌宠")
        menu.delegate = self
        for role in model.state.roles {
            let item = NSMenuItem(title: role.name, action: #selector(selectRoleFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = role.id
            if role.id == model.state.selection.characterId { item.state = .on }
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let lock = NSMenuItem(title: "锁定位置", action: #selector(togglePositionLock), keyEquivalent: "")
        lock.target = self
        lock.state = model.positionLocked ? .on : .off
        menu.addItem(lock)

        let dock = NSMenuItem(title: "停靠并锁定到角落", action: nil, keyEquivalent: "")
        let corners = NSMenu()
        corners.delegate = self
        for (title, identifier) in [
            ("左上角", "top-left"),
            ("右上角", "top-right"),
            ("左下角", "bottom-left"),
            ("右下角", "bottom-right"),
        ] {
            let item = NSMenuItem(title: title, action: #selector(dockToCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            corners.addItem(item)
        }
        dock.submenu = corners
        menu.addItem(dock)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 Hana 桌宠", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func artworkPoint(for event: NSEvent) -> NSPoint? {
        let localPoint = convert(event.locationInWindow, from: nil)
        return artwork.convert(localPoint, from: self)
    }

    private func screenPoint(for event: NSEvent) -> NSPoint? {
        window?.convertPoint(toScreen: event.locationInWindow)
    }

    private func synchronizeMouseAvoidance() {
        guard let window else {
            attachedWindow?.ignoresMouseEvents = false
            attachedWindow = nil
            return
        }
        attachedWindow = window
        guard !eventPolicy.isInteractionHeld else {
            window.ignoresMouseEvents = false
            return
        }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInView = convert(pointInWindow, from: nil)
        let pointInArtwork = artwork.convert(pointInView, from: self)
        // During the pick-up loop the character is being dragged, so a transient pose frame
        // with transparent pixels under the cursor must not hand the window back.
        window.ignoresMouseEvents = eventPolicy.ignoresMouseEvents(
            pointerIsOnCharacter: artwork.hitShapeContains(pointInArtwork),
            duringPickUp: artwork.isDragPickUpActive
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        eventPolicy.menuDidOpen()
        artwork.endDragPickUp()
        synchronizeMouseAvoidance()
    }

    func menuDidClose(_ menu: NSMenu) {
        eventPolicy.menuDidClose()
        synchronizeMouseAvoidance()
    }

    private func activatePet() {
        artwork.reactToTap()
    }

    @objc private func selectRoleFromMenu(_ sender: NSMenuItem) {
        guard let roleId = sender.representedObject as? String else { return }
        model.selectRole(roleId)
    }

    @objc private func togglePositionLock() {
        model.setPositionLocked(!model.positionLocked)
    }

    @objc private func dockToCorner(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String,
              let window,
              let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let frame = window.frame
        let margin: CGFloat = 12
        let x = identifier.hasSuffix("left") ? visible.minX + margin : visible.maxX - frame.width - margin
        let y = identifier.hasPrefix("top") ? visible.maxY - frame.height - margin : visible.minY + margin
        window.setFrameOrigin(NSPoint(x: x, y: y))
        model.setPositionLocked(true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}

private final class PetCharacterView: NSView {
    private struct CachedArtwork {
        let frame: PetArtworkFrame
        let image: NSImage
    }

    private let catalog: PetArtworkCatalog?
    private let layout: PetCharacterLayout
    private let poseReadback: PetPoseReadbackStore
    private(set) var roleId = "claude"
    private(set) var status: PetActivityStatus = .idle
    private var basePose = "idle"
    private var availablePoseNames: [String] = []
    private var workPoses: PetWorkPoseSet?
    private var reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var motionIsActive = false
    private var timeline = PetPoseTimeline()
    private var moodTracker = PetPoseMoodTracker()
    private var workScheduler = PetWorkPoseScheduler()
    private var pickUp = PetPickUpAnimation()
    private var currentSessionId: String?
    private var currentHint: PetActivityHint?
    private var currentToolName: String?
    private var lastActivityAt: Int64 = 0
    private var displayedLayers: [PetPoseLayer] = []
    private var cachedArtwork: [String: CachedArtwork] = [:]
    private var artworkUseOrder: [String] = []
    private var wakeTimer: Timer?
    private var scheduledWakeAt: TimeInterval?
    private var scheduledWakeToken: WakeToken?
    private var windowVisibilityObserver: NSObjectProtocol?
    private var appHideObserver: NSObjectProtocol?
    private var appUnhideObserver: NSObjectProtocol?
    private var reducedMotionObserver: NSObjectProtocol?
    var onActivate: (() -> Void)?

    init(
        catalog: PetArtworkCatalog?,
        layout: PetCharacterLayout,
        poseReadback: PetPoseReadbackStore,
        frame frameRect: NSRect
    ) {
        self.catalog = catalog
        self.layout = layout
        self.poseReadback = poseReadback
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Claude 桌宠")
        setAccessibilityHelp("单击回应；拖动移动；右键打开角色菜单")
        observeSystemPreferences()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        wakeTimer?.invalidate()
        for observer in [windowVisibilityObserver, appHideObserver, appUnhideObserver, reducedMotionObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowVisibilityObserver {
            NotificationCenter.default.removeObserver(windowVisibilityObserver)
            self.windowVisibilityObserver = nil
        }
        guard let window else {
            updateAnimationActivity()
            return
        }
        windowVisibilityObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.updateAnimationActivity()
        }
        updateAnimationActivity()
    }

    private func observeSystemPreferences() {
        let center = NotificationCenter.default
        reducedMotionObserver = center.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: NSWorkspace.shared,
            queue: .main
        ) { [weak self] _ in
            self?.refreshReducedMotionPreference()
        }
        appHideObserver = center.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.updateAnimationActivity()
        }
        appUnhideObserver = center.addObserver(
            forName: NSApplication.didUnhideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            self?.updateAnimationActivity()
        }
    }

    private func refreshReducedMotionPreference() {
        let newValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard reduceMotion != newValue else { return }
        reduceMotion = newValue
        applyLatestState(at: ProcessInfo.processInfo.systemUptime)
    }

    private func updateAnimationActivity() {
        let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
        let shouldAnimate = visible && !NSApp.isHidden
        guard motionIsActive != shouldAnimate else { return }
        motionIsActive = shouldAnimate
        // Becoming invisible stops every autonomous deadline; becoming visible rebuilds the
        // rhythm from the current real state instead of replaying the hidden span. A hidden
        // window also cannot still be dragging, so the pick-up loop is dropped.
        if !shouldAnimate { pickUp.end() }
        applyLatestState(at: ProcessInfo.processInfo.systemUptime)
        if !motionIsActive { cancelWakeTimer() }
    }

    func update(
        roleId: String,
        roleName: String,
        sessionId: String?,
        status: PetActivityStatus,
        toolName: String?,
        lastActivityAt: Int64,
        hint: PetActivityHint?
    ) {
        let roleChanged = self.roleId != roleId
        let sessionChanged = currentSessionId != sessionId
        self.roleId = roleId
        self.currentSessionId = sessionId
        self.status = status
        self.currentToolName = toolName
        self.lastActivityAt = lastActivityAt
        self.currentHint = hint
        let poses = catalog?.poseNames(forCharacterID: roleId) ?? []
        let preferredPose = PetPosePlanner.preferredPose(for: status, toolName: toolName, hint: status == .error ? nil : hint)
        let resolvedPose = PetPosePlanner.resolvedPose(preferred: preferredPose, availablePoseNames: poses)
        availablePoseNames = poses
        workPoses = PetPosePlanner.workPoseSet(characterID: roleId, availablePoseNames: poses)
        basePose = resolvedPose
        if roleChanged {
            clearArtworkCache()
            timeline = PetPoseTimeline(initialPose: resolvedPose)
        }
        if sessionChanged {
            // A new session inherits neither the previous session's display history nor its
            // mood accumulation: the action clock, the tool tail, a pending tap response and
            // the fatigue start all restart. The continuous work clock itself stays owned by
            // the mood tracker.
            workScheduler = PetWorkPoseScheduler()
            moodTracker = PetPoseMoodTracker()
            _ = timeline.interruptReaction(at: ProcessInfo.processInfo.systemUptime)
            pickUp.end()
        } else if roleChanged {
            // Changing outfit inside one session keeps the continuous work history; only the
            // display phases are rebuilt for the new artwork. The pick-up frames belong to the
            // old character, so the interaction state is dropped rather than carried over.
            pickUp.end()
            workScheduler.rebuildRhythm(workPoses: workPoses, at: ProcessInfo.processInfo.systemUptime)
        }
        setAccessibilityLabel("\(roleName)桌宠")
        setAccessibilityValue(accessibilityStatus(status))
        applyLatestState(at: ProcessInfo.processInfo.systemUptime)
    }

    override func accessibilityPerformPress() -> Bool {
        guard let onActivate else { return false }
        onActivate()
        return true
    }

    func beginPointerInteraction() {
        let now = ProcessInfo.processInfo.systemUptime
        displayedLayers = timeline.interruptTransition(at: now)
        needsDisplay = true
        scheduleWake(at: now)
    }

    var isDragPickUpActive: Bool { pickUp.isActive }

    /// Enters the two-frame pick-up loop. Idempotent: the caller can invoke this on every
    /// `mouseDragged` event without restarting the rhythm. It never touches the activity
    /// state, `lastActivityAt` or the mood tracker's continuous-work clock.
    func beginDragPickUp() {
        guard !pickUp.isActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        pickUp.begin(at: now)
        applyLatestState(at: now)
    }

    /// Leaves the pick-up loop and immediately renders the latest real state. No pre-drag
    /// snapshot is restored, so the artwork cannot come back stale.
    func endDragPickUp() {
        guard pickUp.isActive else { return }
        pickUp.end()
        let now = ProcessInfo.processInfo.systemUptime
        applyLatestState(at: now)
    }

    func reactToTap() {
        let preferred = PetPosePlanner.preferredPose(for: .success, toolName: nil)
        let responseIsAvailable = availablePoseNames.contains("happy") || availablePoseNames.contains("happy-2")
        let responsePose = responseIsAvailable
            ? PetPosePlanner.resolvedPose(preferred: preferred, availablePoseNames: availablePoseNames)
            : nil
        let now = ProcessInfo.processInfo.systemUptime
        displayedLayers = timeline.beginReaction(pose: responsePose, at: now)
        // Register the response with the work scheduler immediately, so an autonomous
        // rotation cannot fire between the tap and the next rendering pass.
        applyLatestState(at: now)
    }

    private func applyLatestState(at time: TimeInterval) {
        let activeHint = status == .error ? nil : currentHint
        let mood = moodTracker.update(
            status: status,
            toolName: currentToolName,
            hint: activeHint,
            lastActivityAt: lastActivityAt,
            at: time
        )
        let preferredPose = PetPosePlanner.preferredPose(for: status, toolName: currentToolName, hint: activeHint)
        let workPose = PetPosePlanner.resolvedPose(preferred: preferredPose, availablePoseNames: availablePoseNames)
        let fallback: Bool
        let realPose: String
        let hasPriorityState: Bool
        if activeHint == nil, let mood {
            realPose = PetPoseMood.resolvedPose(for: mood, workPose: workPose, availablePoseNames: availablePoseNames)
            fallback = realPose != primaryPose(for: mood)
            hasPriorityState = true
        } else {
            realPose = workPose
            fallback = realPose != preferredPose
            hasPriorityState = false
        }

        // The action clock only decides which ordinary-work artwork to show. It reads the
        // mood tracker's continuous work start and never writes it.
        let workTick = workScheduler.update(
            PetWorkPoseSchedulerInput(
                sessionId: currentSessionId,
                workSegmentStart: moodTracker.continuousWorkStart,
                status: status,
                hint: activeHint,
                hasPriorityState: hasPriorityState,
                allowsAutonomousRotation: motionIsActive && !reduceMotion,
                interactionIsActive: timeline.hasActiveReaction,
                realPose: realPose
            ),
            workPoses: workPoses,
            at: time
        )
        basePose = workTick.pose ?? realPose
        // Autonomous rotation is never a missing-artwork substitution, so only the pose that
        // actually came out of the planner/mood chain may carry the fallback flag.
        let reportedFallback = fallback && basePose == realPose

        // The pick-up loop covers idle, work, mood and the real-feedback poses (a pending hint,
        // an error) while the drag lasts: the user is directly holding the character, so the
        // drag wins. It is a pure display overlay — it does not write `lastActivityAt`, the work
        // clock, the mood tracker or any follow timing, so the underlying session keeps being
        // observed and everything real renders again on release.
        let pickUpPose = pickUp.poseName(
            at: time,
            availablePoseNames: availablePoseNames,
            reduceMotion: reduceMotion
        )
        // `displayPose` is the same decision the checks assert: while the loop runs it owns
        // the artwork, otherwise the real pose shows.
        let displayedPose = pickUp.displayPose(
            realPose: basePose,
            at: time,
            availablePoseNames: availablePoseNames,
            reduceMotion: reduceMotion
        )
        let pickUpOwnsArtwork = pickUp.isActive && pickUpPose != nil

        displayedLayers = timeline.update(
            status: status,
            basePose: displayedPose,
            availablePoseNames: availablePoseNames,
            reduceMotion: reduceMotion,
            allowsIdleAnimation: mood != .sleeping && activeHint == nil && !pickUpOwnsArtwork,
            hint: activeHint,
            // Frame-by-frame poses cut hard: a 0.20 s cross-fade on a 0.16 s frame would
            // overlap two poses' arms.
            immediate: pickUpOwnsArtwork,
            at: time
        )
        // Readback stays honest: `picked-up`/`picked-up-2` are catalogued poses that really
        // are on screen, and they are not a missing-artwork substitution.
        poseReadback.update(characterId: roleId, pose: displayedPose, fallback: !pickUpOwnsArtwork && reportedFallback)
        needsDisplay = true
        scheduleWake(at: time)
    }

    /// The first candidate of PetPoseMood.resolvedPose, used only to report whether
    /// that existing fallback chain had to choose a substitute artwork.
    private func primaryPose(for mood: PetPoseMood) -> String {
        switch mood {
        case .sleeping: return "sleeping"
        case .tired: return "tired"
        case .swampedLeft: return "swamped_left"
        case .swampedRight: return "swamped_right"
        case .proud: return "proud"
        }
    }

    private func advanceTimeline(at time: TimeInterval) {
        applyLatestState(at: time)
    }

    /// Identity/generation captured when a one-shot wake was scheduled. A callback that no
    /// longer matches the live scheduler is discarded outright: it may not write a pose,
    /// rebuild phases or reschedule a deadline.
    private struct WakeToken: Equatable {
        let identity: PetWorkPoseIdentity?
        let generation: UInt64
    }

    private func scheduleWake(at time: TimeInterval) {
        let deadline = [
            timeline.nextWakeAt(after: time),
            moodTracker.nextDeadline(after: time),
            workScheduler.nextDeadline(after: time),
            pickUp.nextDeadline(after: time, reduceMotion: reduceMotion),
        ]
            .compactMap { $0 }
            .min()
        guard motionIsActive, let deadline else {
            cancelWakeTimer()
            return
        }
        let token = WakeToken(
            identity: workScheduler.currentIdentity,
            generation: workScheduler.currentGeneration
        )
        if let scheduledWakeAt, abs(scheduledWakeAt - deadline) < 0.01, scheduledWakeToken == token { return }
        wakeTimer?.invalidate()
        let timer = Timer(timeInterval: max(0.001, deadline - time), repeats: false) { [weak self] firedTimer in
            guard let self else {
                firedTimer.invalidate()
                return
            }
            if self.wakeTimer === firedTimer {
                self.wakeTimer = nil
                self.scheduledWakeAt = nil
                self.scheduledWakeToken = nil
            }
            self.wake(from: token)
        }
        wakeTimer = timer
        scheduledWakeAt = deadline
        scheduledWakeToken = token
        RunLoop.main.add(timer, forMode: .common)
    }

    private func wake(from token: WakeToken) {
        let now = ProcessInfo.processInfo.systemUptime
        // The merged wake timer also serves mood deadlines, so a callback whose scheduler
        // token is stale still re-renders the current state — it just never advances the old
        // phase, which is what keeps a queued callback from writing a pose into a new context.
        if workScheduler.matches(identity: token.identity, generation: token.generation) {
            _ = workScheduler.advance(identity: token.identity, generation: token.generation, at: now)
        }
        applyLatestState(at: now)
    }

    private func cancelWakeTimer() {
        wakeTimer?.invalidate()
        wakeTimer = nil
        scheduledWakeAt = nil
        scheduledWakeToken = nil
    }

    private func currentMotion() -> PetCharacterMotion {
        PetCharacterMotion(
            width: Double(bounds.width),
            height: Double(bounds.height),
            phase: 0,
            reactionProgress: nil,
            isError: false,
            anchor: PetPointerPoint(x: Double(bounds.midX), y: layout.bottomInset)
        )
    }

    private func artwork(for poseName: String) -> CachedArtwork? {
        let key = "\(roleId)/\(poseName)"
        if let cached = cachedArtwork[key] {
            artworkUseOrder.removeAll { $0 == key }
            artworkUseOrder.append(key)
            return cached
        }
        guard let frame = catalog?.frame(characterID: roleId, poseName: poseName) else { return nil }
        let image = NSImage(cgImage: frame.image, size: NSSize(width: frame.width, height: frame.height))
        let value = CachedArtwork(frame: frame, image: image)
        cachedArtwork[key] = value
        artworkUseOrder.append(key)
        trimArtworkCache()
        return value
    }

    private func trimArtworkCache() {
        let visibleKeys = Set(displayedLayers.map { "\(roleId)/\($0.poseName)" })
        while cachedArtwork.count > 5 {
            guard let index = artworkUseOrder.firstIndex(where: { !visibleKeys.contains($0) }) else { break }
            let key = artworkUseOrder.remove(at: index)
            cachedArtwork.removeValue(forKey: key)
        }
    }

    private func clearArtworkCache() {
        cachedArtwork.removeAll(keepingCapacity: true)
        artworkUseOrder.removeAll(keepingCapacity: true)
    }

    private func imageRect(for frame: PetArtworkFrame) -> NSRect {
        let rect = layout.imageRect(
            containerWidth: Double(bounds.width),
            sourceWidth: Double(frame.width),
            sourceHeight: Double(frame.height)
        )
        return NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }

    func hitShapeContains(_ point: NSPoint) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        let motion = currentMotion()
        let localPoint = motion.unapplying(to: PetPointerPoint(x: Double(point.x), y: Double(point.y)))
        let canonicalPoint = NSPoint(x: localPoint.x, y: localPoint.y)
        // Alpha samples come from the already-decoded, bounded frame cache: a hit test never
        // decodes an image. Out-of-rect layers contribute transparent alpha instead of skipping,
        // so the composited coverage matches what is actually drawn.
        var samples: [PetPoseAlphaSample] = []
        for layer in timeline.visibleLayers(at: now) where layer.opacity > 0.001 {
            guard let artwork = artwork(for: layer.poseName) else { continue }
            let frame = artwork.frame
            let rect = imageRect(for: frame)
            guard rect.width > 0, rect.height > 0, rect.contains(canonicalPoint) else { continue }
            let xFraction = (canonicalPoint.x - rect.minX) / rect.width
            let yFractionFromBottom = (canonicalPoint.y - rect.minY) / rect.height
            let x = Int(xFraction * CGFloat(frame.width))
            let yFromTop = Int((1 - yFractionFromBottom) * CGFloat(frame.height))
            samples.append(PetPoseAlphaSample(
                opacity: layer.opacity,
                alpha: frame.alphaValue(x: x, yFromTop: yFromTop)
            ))
        }
        return PetPoseHitCoverage.isHit(samples)
    }

    private func accessibilityStatus(_ status: PetActivityStatus) -> String {
        switch status {
        case .idle: return "空闲"
        case .working: return "工作中"
        case .tool: return "工具运行"
        case .success: return "已完成"
        case .error: return "遇到错误"
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let now = ProcessInfo.processInfo.systemUptime
        advanceTimeline(at: now)
        let layers = timeline.visibleLayers(at: now)
        guard !layers.isEmpty else { return }
        let motion = currentMotion()
        let pivot = NSPoint(x: motion.center.x, y: motion.center.y)

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: pivot.x, yBy: pivot.y + CGFloat(motion.bobY))
        transform.rotate(byDegrees: CGFloat(motion.rotationDegrees))
        transform.scale(by: CGFloat(motion.scale))
        transform.translateX(by: -pivot.x, yBy: -pivot.y)
        transform.concat()
        for layer in layers where layer.opacity > 0.001 {
            guard let artwork = artwork(for: layer.poseName) else { continue }
            artwork.image.draw(
                in: imageRect(for: artwork.frame),
                from: .zero,
                operation: .sourceOver,
                fraction: CGFloat(layer.opacity),
                respectFlipped: false,
                hints: nil
            )
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}
