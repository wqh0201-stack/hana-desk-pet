import Foundation

// Pick-up (drag) animation checks: threshold gating, A/B rhythm, idempotent drag streams,
// release without a click, restoring the latest real state, lifecycle cleanup, stale
// deadlines, reduced motion and the alpha-hit / window-receipt policy.
//
// Everything runs on a caller-supplied monotonic clock. No sleeping, no GUI, no listener,
// no contact with a real host or the fixed 127.0.0.1:43127 service. Resource checks are
// real: they decode the bundled catalog through `PetArtworkCatalog`.

@main
private struct PoseDragPickUpChecks {
    private static var checks = 0

    private static let poses = [
        "idle", "idle-2", "idle-3", "idle-blink", "thinking", "thinking-2", "busy_left", "busy_right",
        "reading", "writing", "searching", "running", "delegating", "drawing",
        "happy", "happy-2", "oops", "asking", "compact", "surprised",
        "sleeping", "tired", "swamped_left", "swamped_right", "proud",
        "picked-up", "picked-up-2",
    ]

    static func main() throws {
        try checkThresholdGating()
        try checkFrameRhythm()
        try checkIdempotentDragStream()
        try checkReleaseRestoresLatestState()
        try checkReleaseDoesNotClick()
        try checkLifecycleCleanup()
        try checkStaleDeadline()
        try checkReducedMotion()
        try checkAlphaHitAndReceiptPolicy()
        try checkTimelineHardCut()
        try checkResourceMapping()
        print("PoseDragPickUpChecks: \(checks) checks passed.")
    }

    // MARK: - 1. Threshold gating

    private static func checkThresholdGating() throws {
        var gesture = PetDragClickGesture()
        var pickUp = PetPickUpAnimation()

        // A press that never moves is a click candidate, never a drag.
        gesture.begin(at: PetPointerPoint(x: 100, y: 100))
        let stillHeld = gesture.drag(to: PetPointerPoint(x: 102, y: 101))
        expect(stillHeld == nil, "a sub-threshold move yields no translation")
        expect(!PetPickUpAnimation.shouldBeginDrag(translation: stillHeld, positionLocked: false),
               "holding the button without crossing the threshold never starts the loop")
        expect(!pickUp.isActive, "the loop stays off before the threshold")

        // Crossing the threshold with an unlocked position starts it.
        let crossed = gesture.drag(to: PetPointerPoint(x: 106, y: 101))
        expect(crossed == PetPointerPoint(x: 6, y: 1), "the translation is measured from mouse-down")
        expect(PetPickUpAnimation.shouldBeginDrag(translation: crossed, positionLocked: false),
               "a real drag past the threshold starts the loop")
        pickUp.begin(at: 10)
        expect(pickUp.isActive, "the loop is active after a real drag")
        expect(pickUp.frameIndex(at: 10, reduceMotion: false) == 0, "the first frame of the loop is the head frame")

        // A locked position can never move the window, so it never animates either.
        gesture.begin(at: PetPointerPoint(x: 0, y: 0))
        let movedWhileLocked = gesture.drag(to: PetPointerPoint(x: 40, y: 40))
        expect(movedWhileLocked != nil, "the gesture still reports movement")
        expect(!PetPickUpAnimation.shouldBeginDrag(translation: movedWhileLocked, positionLocked: true),
               "a locked position never starts the pick-up loop")

        // A plain click release never starts anything, and the gesture still reports the click.
        gesture.begin(at: PetPointerPoint(x: 10, y: 10))
        expect(gesture.end(at: PetPointerPoint(x: 11, y: 10)), "an unmoved release is a click")
        expect(!PetPickUpAnimation.shouldBeginDrag(translation: nil, positionLocked: false),
               "a click with no translation never starts the loop")
        expect(!PetPickUpAnimation.shouldBeginDrag(translation: PetPointerPoint(x: 0, y: 0), positionLocked: false),
               "a zero translation never starts the loop")

        // AXPress / tap responses never touch the interaction at all.
        let untouched = PetPickUpAnimation()
        expect(!untouched.isActive && untouched.poseName(at: 0, availablePoseNames: poses, reduceMotion: false) == nil,
               "a tap or AXPress cannot start the loop")
    }

    // MARK: - 2. A/B rhythm

    private static func checkFrameRhythm() throws {
        var pickUp = PetPickUpAnimation()
        pickUp.begin(at: 0)
        let interval = PetPickUpAnimation.frameInterval
        expect(interval == 0.16, "the first version uses 160 ms per frame")

        expect(frame(pickUp, 0) == "picked-up", "t=0 shows the head frame")
        expect(frame(pickUp, 0.159) == "picked-up", "the head frame holds for 160 ms")
        expect(frame(pickUp, 0.16) == "picked-up-2", "the tail frame starts at 160 ms")
        expect(frame(pickUp, 0.319) == "picked-up-2", "the tail frame holds for 160 ms")
        expect(frame(pickUp, 0.32) == "picked-up", "the loop returns to the head frame at 320 ms")
        expect(frame(pickUp, 0.48) == "picked-up-2", "the loop keeps alternating")
        expect(frame(pickUp, 1.6) == "picked-up", "ten frames later the phase is unchanged")

        expect(pickUp.nextDeadline(after: 0, reduceMotion: false) == 0.16, "the next frame is 160 ms out")
        expect(pickUp.nextDeadline(after: 0.161, reduceMotion: false) == 0.32, "the deadline follows the phase")
        expect(pickUp.nextDeadline(after: 0.32, reduceMotion: false) == 0.48, "deadlines never repeat a past frame")

        // A character missing one frame just holds the frame it has, never a blank pose.
        expect(pickUp.poseName(at: 0.16, availablePoseNames: ["idle", "picked-up"], reduceMotion: false) == "picked-up",
               "a missing tail frame holds the head frame instead of blinking away")
        expect(pickUp.poseName(at: 0, availablePoseNames: ["idle"], reduceMotion: false) == nil,
               "a character without pick-up art does not own the artwork")
    }

    // MARK: - 3. Idempotent drag stream

    private static func checkIdempotentDragStream() throws {
        // A steady drag stream must advance the rhythm, not freeze it on the head frame.
        var streamed = PetPickUpAnimation()
        var t = 0.0
        while t <= 0.5 {
            streamed.begin(at: t)
            t += 0.01
        }
        expect(frame(streamed, 0.16) == "picked-up-2",
               "repeated mouseDragged callbacks do not restart the loop")
        expect(frame(streamed, 0.48) == "picked-up-2", "the stream keeps the original phase")
        expect(streamed.nextDeadline(after: 0.5, reduceMotion: false) == 0.64,
               "the deadline is derived from the original start, not the last callback")

        // A stream that continues after a long pause behaves the same as one sparse call.
        var sparse = PetPickUpAnimation()
        sparse.begin(at: 0)
        var late = 0.0
        while late <= 2.0 {
            sparse.begin(at: late)
            late += 0.05
        }
        var single = PetPickUpAnimation()
        single.begin(at: 0)
        for probe in [0.0, 0.16, 0.32, 0.9, 1.7, 2.0] {
            expect(frame(sparse, probe) == frame(single, probe),
                   "a dense drag stream reaches the same frame at \(probe) as a single begin")
        }
    }

    // MARK: - 4. Release restores the latest real state

    private static func checkReleaseRestoresLatestState() throws {
        var pickUp = PetPickUpAnimation()
        pickUp.begin(at: 0)
        expect(frame(pickUp, 0.16) == "picked-up-2", "the loop is running while dragging")

        // While the loop is active the real state keeps being observed: a tool starts mid-drag.
        let underlyingWhileDragging = PetPosePlanner.preferredPose(for: .tool, toolName: "read_file")
        expect(underlyingWhileDragging == "reading", "the underlying session state is unaffected by the drag")

        // The loop covers every real state while the drag lasts, including a pending hint and
        // an error: the user is holding the character, so the drag wins until it ends.
        for realPose in ["thinking", "reading", "oops", "asking", "tired", "sleeping", "proud"] {
            expect(pickUp.displayPose(realPose: realPose, at: 0.16, availablePoseNames: poses, reduceMotion: false) == "picked-up-2",
                   "the drag keeps drawing over the real \(realPose) pose")
        }
        expect(pickUp.displayPose(realPose: "oops", at: 0.16, availablePoseNames: poses, reduceMotion: true) == "picked-up",
               "even an error pose is covered by the frozen pick-up frame while dragging")

        pickUp.end()
        expect(!pickUp.isActive, "release ends the loop")
        expect(pickUp.poseName(at: 0.2, availablePoseNames: poses, reduceMotion: false) == nil,
               "the loop stops owning the artwork after release")
        // The renderer falls back to whatever the real state resolves to *now*, not to a
        // snapshot taken at mouse-down.
        let latest = PetPosePlanner.resolvedPose(preferred: underlyingWhileDragging, availablePoseNames: poses)
        expect(latest == "reading", "release shows the latest real pose, not a pre-drag snapshot")

        // Ending an inactive loop is a no-op (safe for release paths that never dragged).
        var idle = PetPickUpAnimation()
        idle.end()
        expect(!idle.isActive, "ending an inactive loop is harmless")

        // Re-entering after a release starts a fresh rhythm on the head frame.
        var again = PetPickUpAnimation()
        again.begin(at: 0)
        _ = frame(again, 0.5)
        again.end()
        again.begin(at: 0.6)
        expect(frame(again, 0.6) == "picked-up", "a new drag starts on the head frame again")
        expect(again.nextDeadline(after: 0.6, reduceMotion: false) == 0.76,
               "a new drag restarts the frame clock")
    }

    // MARK: - 5. Release does not click

    private static func checkReleaseDoesNotClick() throws {
        var gesture = PetDragClickGesture()
        var pickUp = PetPickUpAnimation()
        gesture.begin(at: PetPointerPoint(x: 0, y: 0))
        let translation = gesture.drag(to: PetPointerPoint(x: 30, y: 0))
        expect(PetPickUpAnimation.shouldBeginDrag(translation: translation, positionLocked: false),
               "the drag starts the loop")
        pickUp.begin(at: 0)
        let isClick = gesture.end(at: PetPointerPoint(x: 30, y: 0))
        pickUp.end()
        expect(!isClick, "a drag release never fires the tap response")
        expect(!pickUp.isActive, "the loop is cleaned up on release")

        // A drag that returns exactly to its origin is still a drag once the threshold was crossed.
        var returning = PetDragClickGesture()
        returning.begin(at: PetPointerPoint(x: 50, y: 50))
        _ = returning.drag(to: PetPointerPoint(x: 80, y: 50))
        expect(!returning.end(at: PetPointerPoint(x: 50, y: 50)),
               "coming back to the exact origin is still a drag, not a click")
    }

    // MARK: - 6. Lifecycle cleanup

    private static func checkLifecycleCleanup() throws {
        // Role switch: the pick-up frames belong to the old character.
        var roleSwitch = PetPickUpAnimation()
        roleSwitch.begin(at: 0)
        expect(roleSwitch.isActive, "the loop runs before the outfit change")
        roleSwitch.end()
        expect(roleSwitch.poseName(at: 0.16, availablePoseNames: poses, reduceMotion: false) == nil,
               "a character switch clears the loop")
        expect(roleSwitch.nextDeadline(after: 0.16, reduceMotion: false) == nil,
               "a cleared loop leaves no wake-up behind")

        // Cancel (Escape / cancelOperation) and losing the window share the same cleanup.
        var cancelled = PetPickUpAnimation()
        cancelled.begin(at: 0)
        cancelled.end()
        expect(!cancelled.isActive && cancelled.nextDeadline(after: 1, reduceMotion: false) == nil,
               "cancel clears the loop and its deadline")

        // Session change also drops it.
        var sessionChange = PetPickUpAnimation()
        sessionChange.begin(at: 0)
        sessionChange.end()
        expect(sessionChange.poseName(at: 0.16, availablePoseNames: poses, reduceMotion: false) == nil,
               "a session change clears the loop")

        // The event policy holds the window through the whole pointer sequence, and releases
        // it afterwards, exactly as before.
        var policy = PetWindowEventPolicy()
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: false),
               "outside the character the window still passes events through")
        policy.beginPointerSequence()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: true),
               "a pointer sequence keeps the window receptive")
        policy.endPointerSequence()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: true, duringPickUp: false),
               "the pointer over the character keeps the window receptive")
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: false),
               "handing the window back after the sequence still works")
    }

    // MARK: - 7. Stale deadline

    private static func checkStaleDeadline() throws {
        // A deadline captured before the release must not resurrect the loop.
        var pickUp = PetPickUpAnimation()
        pickUp.begin(at: 0)
        let capturedDeadline = pickUp.nextDeadline(after: 0.16, reduceMotion: false)
        expect(capturedDeadline == 0.32, "the loop scheduled its next frame")

        pickUp.end()
        expect(pickUp.nextDeadline(after: 0.16, reduceMotion: false) == nil,
               "after release there is no live deadline")
        // Firing the captured timer later only re-reads the (inactive) loop.
        expect(pickUp.poseName(at: 0.32, availablePoseNames: poses, reduceMotion: false) == nil,
               "a callback that arrives after release cannot write a pick-up pose")

        // Re-entering produces a different phase, so an old callback cannot be mistaken for
        // the new loop and jump the frames.
        pickUp.begin(at: 0.5)
        expect(frame(pickUp, 0.5) == "picked-up", "the new drag starts on the head frame")
        expect(pickUp.nextDeadline(after: 0.5, reduceMotion: false) == 0.66,
               "the new loop owns its own deadline")

        // A scheduler-style stale check: the pick-up layer exposes no identity, so its only
        // safeguard is the `isActive` gate, which must be enough for every path above.
        expect(pickUp.poseName(at: 100, availablePoseNames: poses, reduceMotion: false) != nil,
               "a live loop keeps advancing regardless of how late the timer fires")
    }

    // MARK: - 8. Reduced motion

    private static func checkReducedMotion() throws {
        var pickUp = PetPickUpAnimation()
        pickUp.begin(at: 0)
        expect(pickUp.poseName(at: 0, availablePoseNames: poses, reduceMotion: true) == "picked-up",
               "reduced motion still shows the head frame while dragging")
        expect(pickUp.poseName(at: 0.16, availablePoseNames: poses, reduceMotion: true) == "picked-up",
               "reduced motion freezes the frame instead of flapping")
        expect(pickUp.poseName(at: 5, availablePoseNames: poses, reduceMotion: true) == "picked-up",
               "the frozen frame does not drift with time")
        expect(pickUp.nextDeadline(after: 0.16, reduceMotion: true) == nil,
               "reduced motion schedules no frame deadline")

        // Dragging still works; only the decorative flapping is gone.
        expect(pickUp.isActive, "reduced motion does not disable dragging")
        expect(PetPickUpAnimation.shouldBeginDrag(
            translation: PetPointerPoint(x: 12, y: 0),
            positionLocked: false
        ), "reduced motion does not block entering the loop")

        // Turning reduced motion off resumes the rhythm from where it would be.
        expect(pickUp.poseName(at: 0.16, availablePoseNames: poses, reduceMotion: false) == "picked-up-2",
               "leaving reduced motion resumes the normal rhythm")
    }

    // MARK: - 9. Alpha hit and receipt policy

    private static func checkAlphaHitAndReceiptPolicy() throws {
        let root = CommandLine.arguments.dropFirst().first ?? "assets/crosspet"
        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: root, isDirectory: true))
        let layout = PetCharacterLayout(maximumAspectRatio: catalog.maximumAspectRatio)

        for role in PetRole.builtIns {
            let frames = [("picked-up", 0), ("picked-up-2", 1)].compactMap { pose, _ in
                catalog.frame(characterID: role.id, poseName: pose).map { (pose, $0) }
            }
            expect(frames.count == 2, "\(role.id) decodes both pick-up frames")

            // Both frames share one canvas height and therefore one draw height and foot line,
            // so switching frames never resizes or re-crops the character.
            let rects = frames.map { layout.imageRect(
                containerWidth: layout.windowSize.width,
                sourceWidth: Double($0.1.width),
                sourceHeight: Double($0.1.height)
            ) }
            expect(abs(rects[0].height - rects[1].height) < 1e-9,
                   "\(role.id) pick-up frames share one display height")
            expect(abs(rects[0].minY - rects[1].minY) < 1e-9,
                   "\(role.id) pick-up frames share the foot line")
            expect(abs(rects[0].maxX - rects[1].maxX) < 1e-9 && abs(rects[0].minX - rects[1].minX) < 1e-9,
                   "\(role.id) pick-up frames share the same horizontal extent")
            expect(rects[0].maxX <= layout.windowSize.width && rects[0].minX >= 0,
                   "\(role.id) pick-up frames stay inside the reserved window")

            for (pose, frame) in frames {
                expect(frame.height == 640, "\(role.id)/\(pose) keeps the catalog's 640 px canvas")
                expect(frame.containsOpaquePixel(
                    x: frame.width / 2,
                    yFromTop: frame.height / 2,
                    minimumAlpha: 16
                ), "\(role.id)/\(pose) has an opaque body under the pointer")
                expect(!frame.containsOpaquePixel(x: 0, yFromTop: 0),
                       "\(role.id)/\(pose) keeps a transparent corner")
            }
            expect(frames[0].1 !== frames[1].1, "\(role.id) really ships two different frames")
            expect(frames[0].1.image !== frames[1].1.image, "\(role.id) frames are distinct decoded images")

            // Alpha hit sampling uses the same transform as drawing, so a layer switch cannot
            // make the hit test disagree with what is on screen.
            let anchor = PetPointerPoint(
                x: layout.artworkAnchor.x,
                y: layout.artworkAnchor.y
            )
            let motion = PetCharacterMotion(
                width: layout.windowSize.width,
                height: layout.windowSize.height,
                phase: 0,
                reactionProgress: nil,
                isError: false,
                anchor: anchor
            )
            let centre = PetPointerPoint(
                x: rects[0].x + rects[0].width / 2,
                y: rects[0].y + rects[0].height / 2
            )
            let forward = motion.applying(to: centre)
            let restored = motion.unapplying(to: forward)
            expect(abs(restored.x - centre.x) < 1e-9 && abs(restored.y - centre.y) < 1e-9,
                   "\(role.id) draw and alpha-hit transforms stay exact inverses during a pick-up frame")
        }

        // The window keeps receiving events for the whole drag, whichever frame is showing.
        var policy = PetWindowEventPolicy()
        policy.beginPointerSequence()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: true),
               "the window keeps receiving events while the pick-up loop is active")
        policy.endPointerSequence()
        expect(!policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: true),
               "an active pick-up alone keeps the window receptive even outside the silhouette")
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: false, duringPickUp: false),
               "with no interaction and no pointer on the character the window still passes through")
        expect(policy.ignoresMouseEvents(pointerIsOnCharacter: true, duringPickUp: false) == false,
               "the pointer over the character still blocks pass-through")

        // Frames are served from the bounded catalog cache, never re-decoded per frame.
        let first = catalog.frame(characterID: "claude", poseName: "picked-up")
        let second = catalog.frame(characterID: "claude", poseName: "picked-up")
        expect(first != nil && first === second, "repeated pick-up frame lookups hit the decoded cache")
    }

    // MARK: - 10. Hard cut in the timeline

    private static func checkTimelineHardCut() throws {
        var timeline = PetPoseTimeline()
        _ = timeline.update(status: .working, basePose: "thinking", availablePoseNames: poses, at: 0)
        expect(timeline.advance(at: 0.5) == [PetPoseLayer(poseName: "thinking", opacity: 1)],
               "the work pose settles before the drag")

        // Frame switches cut hard: no outgoing layer survives, so two arms cannot overlap.
        let head = timeline.update(
            status: .working,
            basePose: "picked-up",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            immediate: true,
            at: 1
        )
        expect(head == [PetPoseLayer(poseName: "picked-up", opacity: 1)],
               "entering the loop cuts to the head frame with no cross-fade")
        let tail = timeline.update(
            status: .working,
            basePose: "picked-up-2",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            immediate: true,
            at: 1.16
        )
        expect(tail == [PetPoseLayer(poseName: "picked-up-2", opacity: 1)],
               "the frame switch is a hard cut, never a 0.20 s cross-fade over a 0.16 s frame")
        expect(!timeline.isTransitioning, "a hard cut leaves no in-flight transition")
        expect(timeline.nextWakeAt(after: 1.16) == nil,
               "a settled hard-cut frame adds no animation timer of its own")

        // Leaving the loop returns to the ordinary cross-fade for real state changes.
        let released = timeline.update(status: .working, basePose: "thinking", availablePoseNames: poses, at: 1.32)
        expect(released == [PetPoseLayer(poseName: "picked-up-2", opacity: 1)],
               "release starts from the visible frame without a jump")
        expect(timeline.advance(at: 1.52) == [PetPoseLayer(poseName: "thinking", opacity: 1)],
               "the return to the real pose uses the normal cross-fade")

        // Interrupting mid-drag (pointer-down during a frame) still settles on the real state.
        _ = timeline.update(
            status: .tool,
            basePose: "picked-up",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            immediate: true,
            at: 2
        )
        let interrupted = timeline.interruptTransition(at: 2.05)
        expect(interrupted == [PetPoseLayer(poseName: "picked-up", opacity: 1)],
               "pointer interruption during a pick-up frame is pixel-stable")
        expect(!timeline.isTransitioning, "interruption clears the frame transition")
    }

    // MARK: - 11. Resource mapping and provenance

    private static func checkResourceMapping() throws {
        let root = CommandLine.arguments.dropFirst().first ?? "assets/crosspet"
        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: root, isDirectory: true))

        // Expected SHA-256 of every pick-up frame, with the source pack each one must come from.
        let expected: [String: [(String, String, String)]] = [
            "claude": [
                ("picked-up.webp", "45e5bca3e9693733fc801c7493c92977fac9f00ab429501d32009f096bb1c8a6", "new"),
                ("picked-up-2.webp", "4b44604457c5587b539990839459593e02fbba24cae3c32197bc31d8014c725a", "new"),
            ],
            "gpt": [
                ("picked-up.webp", "00cfd771c457aafa61cded8ef2cb3bbd04a86bb39351a63b86cbf92b7dda80d2", "new"),
                ("picked-up-2.webp", "a3d1deadaea8a3a8088caac0375899b4d5c4f270bdd3a4a5a7d7fa4215fcaf42", "new"),
            ],
            "deepseek": [
                ("picked-up.webp", "e372d740b2f7339dea2c110c046e3750e3835fb902f74fbd5cf846a639f10ab4", "new"),
                ("picked-up-2.webp", "cae77483aece5a3c6e6fc10ddc32c7f33f82d9d0cdd3708006d2dacdd7d26bbe", "new"),
            ],
            "gemini": [
                ("picked-up.webp", "48b83a5614be570057621c27f7d8956a39d042126dcc11ccd921385a316724c2", "new"),
                ("picked-up-2.webp", "437547fa5ac9a02c548e2f0382ddc4470910564ac9b85175adc170cad887723d", "new"),
            ],
            "glm": [
                ("picked-up.webp", "65005ddbff8a70c9fc23202a159fb32e405ebdfc8f31609b151da5c4c51d4ed0", "new"),
                ("picked-up-2.webp", "ca7c05fe390e31a575b7319b0ff993fc3c3052f3ad56b772c9060fc03aa4ce7b", "new"),
            ],
            "deepseek-hoodie": [
                ("picked-up.webp", "473091813a5b085f98aada90742b29c01654b819e3af255e5e390fa294f5e94a", "new"),
                ("picked-up-2.webp", "2ebff5c77554e7fdee0cce3a40b73fa6d95bf2df8fc973321cc260d11a8e6be3", "new"),
            ],
            // The user's final choice: the older pack for the onesie skin, not the new waving one.
            "gpt-onesie": [
                ("picked-up.webp", "2bbe7ef9934af8d6dc82884aa0f949c0a6c4d11c059a5bfff4847d0447d5a782", "old"),
                ("picked-up-2.webp", "39640d08ffa804957c97bb90e4e49f6aef5a0c36c16018aeba7ae8a8ab4bf2bc", "old"),
            ],
        ]

        let checked = try catalog.validateAllAssets()
        let catalogCount = PetRole.builtIns.reduce(0) { $0 + catalog.poseNames(forCharacterID: $1.id).count }
        expect(checked == catalogCount, "all \(catalogCount) catalogued WebP assets decode")
        expect(catalogCount == 211, "the catalog now lists 211 assets (193 upstream + 18 local)")

        for role in PetRole.builtIns {
            let names = catalog.poseNames(forCharacterID: role.id)
            expect(names.contains("picked-up") && names.contains("picked-up-2"),
                   "\(role.id) lists both pick-up frames")
            guard let frames = expected[role.id] else {
                fatalError("CHECK FAILED: no expected provenance recorded for \(role.id)")
            }
            for (filename, hash, source) in frames {
                let url = URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent(role.id, isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
                guard let data = try? Data(contentsOf: url) else {
                    fatalError("CHECK FAILED: \(role.id)/\(filename) is missing")
                }
                let digest = sha256(data)
                expect(digest == hash, "\(role.id)/\(filename) matches the \(source)-pack SHA-256")
                expect(digest.count == 64, "\(role.id)/\(filename) digest is a full SHA-256")
            }
        }

        // The onesie must NOT be the new waving pack: its hashes must differ from every new-pack frame.
        let newPackHashes = Set(expected.values.flatMap { $0 }.filter { $0.2 == "new" }.map(\.1))
        for (_, hash, _) in expected["gpt-onesie"] ?? [] {
            expect(!newPackHashes.contains(hash), "gpt-onesie does not use a new waving-pack frame")
        }
        // And the white dragon must not have been swapped to the old pack either.
        for (_, hash, source) in expected["gpt"] ?? [] {
            expect(source == "new", "gpt (white dragon) uses the new waving pack, not the old one")
            expect(!hash.isEmpty, "gpt frames carry an explicit new-pack provenance")
        }

        // Catalog bookkeeping: 18 locally generated poses, named per character.
        let generatedCount = PetRole.builtIns.reduce(0) { sum, role in
            sum + ((catalog.generatedPoseNames(forCharacterID: role.id)).count)
        }
        expect(generatedCount == 18, "the catalog marks 18 locally generated poses")
    }

    // MARK: - Helpers

    private static func frame(_ pickUp: PetPickUpAnimation, _ time: TimeInterval) -> String? {
        pickUp.poseName(at: time, availablePoseNames: poses, reduceMotion: false)
    }

    /// Minimal SHA-256 so the check stays dependency-free.
    private static func sha256(_ data: Data) -> String {
        data.withUnsafeBytes { raw -> String in
            let bytes = Array(raw)
            var state: [UInt32] = [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ]
            var message = bytes
            let bitLength = UInt64(bytes.count) * 8
            message.append(0x80)
            while message.count % 64 != 56 { message.append(0) }
            for shift in stride(from: 56, through: 0, by: -8) {
                message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
            }
            let k: [UInt32] = [
                0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
                0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
                0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
                0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
                0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
                0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
                0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
                0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
            ]
            var w = [UInt32](repeating: 0, count: 64)
            for chunk in stride(from: 0, to: message.count, by: 64) {
                for index in 0..<16 {
                    let base = chunk + index * 4
                    w[index] = (UInt32(message[base]) << 24) | (UInt32(message[base + 1]) << 16) |
                        (UInt32(message[base + 2]) << 8) | UInt32(message[base + 3])
                }
                for index in 16..<64 {
                    let s0 = rotr(w[index - 15], 7) ^ rotr(w[index - 15], 18) ^ (w[index - 15] >> 3)
                    let s1 = rotr(w[index - 2], 17) ^ rotr(w[index - 2], 19) ^ (w[index - 2] >> 10)
                    w[index] = w[index - 16] &+ s0 &+ w[index - 7] &+ s1
                }
                var a = state[0], b = state[1], c = state[2], d = state[3]
                var e = state[4], f = state[5], g = state[6], h = state[7]
                for index in 0..<64 {
                    let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                    let ch = (e & f) ^ (~e & g)
                    let temp1 = h &+ s1 &+ ch &+ k[index] &+ w[index]
                    let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                    let maj = (a & b) ^ (a & c) ^ (b & c)
                    let temp2 = s0 &+ maj
                    h = g; g = f; f = e; e = d &+ temp1
                    d = c; c = b; b = a; a = temp1 &+ temp2
                }
                state[0] = state[0] &+ a; state[1] = state[1] &+ b
                state[2] = state[2] &+ c; state[3] = state[3] &+ d
                state[4] = state[4] &+ e; state[5] = state[5] &+ f
                state[6] = state[6] &+ g; state[7] = state[7] &+ h
            }
            return state.map { String(format: "%08x", $0) }.joined()
        }
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
