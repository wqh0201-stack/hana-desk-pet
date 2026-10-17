import Foundation

@main
struct PetPoseTimelineChecks {
    private static var checkCount = 0

    static func main() {
        testStableWorkAndInterruptibleCrossfade()
        testReactionRestoresLatestActivity()
        testIdleDwellAndBlink()
        testReducedMotionScheduling()
        testMoodThresholdsAndBoundaries()
        testHintsSuppressSleepAndYieldToWorkMood()
        testFatiguePriorityAndWakeups()
        testHintPriorityInterruptAndStandby()
        testSleepingDoesNotRestartIdleAnimation()
        testFixedHeightLayoutAndTransform()
        testWorkRhythmThroughTimeline()
        testTapResponseDefersRotation()
        testReducedMotionStopsRotationNotFeedback()
        testMoodRegressionWithRhythm()
        print("PoseTimelineChecks: \(checkCount) checks passed.")
    }

    private static func testStableWorkAndInterruptibleCrossfade() {
        var timeline = PetPoseTimeline()
        let poses = allPoses
        let initial = timeline.update(status: .working, basePose: "thinking", availablePoseNames: poses, at: 0)
        expect(initial == [PetPoseLayer(poseName: "thinking", opacity: 1)], "initial working pose is immediate")
        expect(timeline.advance(at: 0.55) == initial, "working state does not switch poses on the old 0.55-second cadence")
        expect(timeline.nextWakeAt(after: 0.55) == nil, "static work has no recurring animation timer")

        _ = timeline.update(status: .tool, basePose: "busy_left", availablePoseNames: poses, at: 1)
        let start = timeline.visibleLayers(at: 1)
        expect(start == [PetPoseLayer(poseName: "thinking", opacity: 1)], "state change begins from the currently visible pose")
        let middle = timeline.advance(at: 1.1)
        expect(abs(opacity("thinking", in: middle) - 0.5) < 1e-9, "cross-fade retains half of the outgoing pose at midpoint")
        expect(abs(opacity("busy_left", in: middle) - 0.5) < 1e-9, "cross-fade reveals half of the incoming pose at midpoint")
        expect(abs(middle.reduce(0) { $0 + $1.opacity } - 1) < 1e-9, "cross-fade opacity remains normalized")

        let interrupted = timeline.update(status: .error, basePose: "oops", availablePoseNames: poses, at: 1.1)
        expect(interrupted == middle, "a new state interrupts without a visible jump")
        expect(timeline.advance(at: 1.31) == [PetPoseLayer(poseName: "oops", opacity: 1)], "interrupted transition settles on the newest state")
    }

    private static func testReactionRestoresLatestActivity() {
        var timeline = PetPoseTimeline()
        _ = timeline.update(status: .working, basePose: "thinking", availablePoseNames: allPoses, at: 0)
        _ = timeline.beginReaction(pose: "happy", at: 1)
        let inReaction = timeline.advance(at: 1.1)
        expect(opacity("happy", in: inReaction) > 0 && opacity("thinking", in: inReaction) > 0, "tap reaction cross-fades from current art")

        let interrupted = timeline.update(status: .working, basePose: "writing", availablePoseNames: allPoses, at: 1.1)
        expect(interrupted == inReaction, "a latest activity update interrupts the tap response continuously")
        expect(!timeline.hasActiveReaction, "new activity cancels the temporary reaction")
        expect(timeline.advance(at: 1.31) == [PetPoseLayer(poseName: "writing", opacity: 1)], "interrupted reaction cannot restore its stale pre-tap pose")

        _ = timeline.beginReaction(pose: "happy", at: 2)
        expect(timeline.advance(at: 2.8) == [PetPoseLayer(poseName: "writing", opacity: 1)], "finished tap response returns to the latest working pose")

        _ = timeline.beginReaction(pose: "happy", at: 3)
        let beforePointerDown = timeline.advance(at: 3.1)
        let afterPointerDown = timeline.interruptReaction(at: 3.1)
        expect(afterPointerDown == beforePointerDown, "pointer-down interrupts a tap animation without a visible jump")
        expect(!timeline.hasActiveReaction, "drag/click pointer-down cancels stale tap feedback")
        expect(timeline.advance(at: 3.31) == [PetPoseLayer(poseName: "writing", opacity: 1)], "pointer interruption returns to the latest state")
    }

    private static func testIdleDwellAndBlink() {
        var timeline = PetPoseTimeline()
        let poses = ["idle", "idle-2", "idle-3", "idle-blink"]
        _ = timeline.update(status: .idle, basePose: "idle", availablePoseNames: poses, at: 0)
        expect(timeline.advance(at: 0.55) == [PetPoseLayer(poseName: "idle", opacity: 1)], "idle holds its pose instead of ticking rapidly")
        expect(abs((timeline.nextWakeAt(after: 0) ?? -1) - 5.8) < 1e-9, "first idle change has a long, deliberate dwell")

        _ = timeline.advance(at: 5.8)
        expect(opacity("idle-2", in: timeline.advance(at: 5.9)) > 0, "first available idle variation appears after the dwell")
        expect(timeline.advance(at: 6.1) == [PetPoseLayer(poseName: "idle-2", opacity: 1)], "idle variation remains settled after its short cross-fade")

        _ = timeline.advance(at: 12.4)
        expect(timeline.advance(at: 12.7) == [PetPoseLayer(poseName: "idle-3", opacity: 1)], "second idle variation also receives a stable hold")
        _ = timeline.advance(at: 17.8)
        let blink = timeline.advance(at: 17.9)
        expect(opacity("idle-blink", in: blink) > 0, "available blink is introduced as a short cross-fade")
        let restored = timeline.advance(at: 18.2)
        expect(restored == [PetPoseLayer(poseName: "idle-3", opacity: 1)], "blink restores the prior idle variation")
    }

    private static func testReducedMotionScheduling() {
        var timeline = PetPoseTimeline()
        _ = timeline.update(
            status: .idle,
            basePose: "idle",
            availablePoseNames: allPoses,
            reduceMotion: true,
            at: 0
        )
        expect(timeline.nextWakeAt(after: 0) == nil, "reduced motion disables idle pose loops")
        _ = timeline.update(
            status: .working,
            basePose: "thinking",
            availablePoseNames: allPoses,
            reduceMotion: true,
            at: 1
        )
        expect(timeline.advance(at: 1.04).count == 2, "reduced-motion state feedback remains a brief opacity cross-fade")
        expect(timeline.advance(at: 1.09) == [PetPoseLayer(poseName: "thinking", opacity: 1)], "reduced-motion cross-fade settles quickly")
    }

    private static func testMoodThresholdsAndBoundaries() {
        var sleep = PetPoseMoodTracker()
        expect(sleep.update(status: .idle, toolName: nil, lastActivityAt: 10, at: 0) == nil, "idle dwell starts without immediately sleeping")
        expect(sleep.nextDeadline(after: 0) == PetPoseMoodTracker.sleepAfterIdle + 0.001, "sleep schedules one threshold wakeup just after five minutes")
        expect(sleep.advance(at: PetPoseMoodTracker.sleepAfterIdle - 0.001) == nil, "sleep threshold does not fire early")
        expect(sleep.advance(at: PetPoseMoodTracker.sleepAfterIdle) == nil, "sleep waits until idle is strictly longer than five minutes")
        expect(sleep.advance(at: PetPoseMoodTracker.sleepAfterIdle + 0.001) == .sleeping, "sleep starts just beyond the five-minute threshold")
        expect(sleep.nextDeadline(after: PetPoseMoodTracker.sleepAfterIdle + 0.001) == nil, "settled sleep has no repeating wakeup")
        expect(sleep.update(status: .idle, toolName: nil, lastActivityAt: 11, at: 301) == nil, "a new idle activity timestamp immediately wakes and restarts the dwell")
        expect(sleep.update(status: .working, toolName: nil, lastActivityAt: 12, at: 302) == nil, "a working status immediately wakes sleep")

        var longIdle = PetPoseMoodTracker()
        _ = longIdle.update(status: .idle, toolName: nil, lastActivityAt: 13, at: 0)
        expect(longIdle.advance(at: 10 * 60) == .sleeping, "ten minutes of pure idle stays sleeping rather than becoming tired")

        var tired = PetPoseMoodTracker()
        _ = tired.update(status: .working, toolName: nil, lastActivityAt: 20, at: 0)
        let justBeforeTenMinutes = PetPoseMoodTracker.tiredAfterWork - 1
        _ = tired.update(status: .tool, toolName: "read_file", lastActivityAt: 21, at: justBeforeTenMinutes)
        expect(tired.nextDeadline(after: justBeforeTenMinutes) == PetPoseMoodTracker.tiredAfterWork + 0.001, "tired schedules exactly one wake just beyond ten minutes from continuous work start")
        expect(tired.advance(at: 9 * 60 + 59) == nil, "tired remains off at the exact nine-minute-fifty-nine-second boundary")
        expect(tired.advance(at: PetPoseMoodTracker.tiredAfterWork - 0.001) == nil, "tired threshold does not fire at ten minutes minus one millisecond")
        expect(tired.advance(at: PetPoseMoodTracker.tiredAfterWork) == nil, "tired waits until work is strictly longer than ten minutes")
        expect(tired.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.001) == .tired, "tired starts just beyond the ten-minute threshold")
        expect(tired.nextDeadline(after: PetPoseMoodTracker.tiredAfterWork + 0.001) == nil, "settled tired state has no repeating wakeup")
        expect(tired.update(status: .idle, toolName: nil, lastActivityAt: 22, at: 601) == nil, "idle clears continuous-work fatigue")
        _ = tired.update(status: .working, toolName: nil, lastActivityAt: 23, at: 602)
        expect(tired.advance(at: 602 + 9 * 60 + 59) == nil, "work after idle starts a fresh fatigue interval")
        expect(tired.advance(at: 602 + PetPoseMoodTracker.tiredAfterWork) == nil, "the restarted ten-minute boundary remains strict")
        expect(tired.advance(at: 602 + PetPoseMoodTracker.tiredAfterWork + 0.001) == .tired, "only the restarted continuous work interval triggers tired")

        var shortSuccess = PetPoseMoodTracker()
        _ = shortSuccess.update(status: .working, toolName: nil, lastActivityAt: 30, at: 0)
        expect(shortSuccess.update(status: .success, toolName: nil, lastActivityAt: 31, at: PetPoseMoodTracker.proudAfterWork - 0.001) == nil, "short work success does not request proud art")
        expect(shortSuccess.nextDeadline(after: 60) == 62.499, "short feedback continuity ends after its bounded window")

        var proud = PetPoseMoodTracker()
        _ = proud.update(status: .working, toolName: nil, lastActivityAt: 40, at: 0)
        expect(proud.update(status: .success, toolName: nil, lastActivityAt: 41, at: PetPoseMoodTracker.proudAfterWork) == .proud, "success after sixty seconds prefers proud")
        expect(proud.advance(at: 61) == .proud, "proud remains visible during the short success feedback")
        expect(proud.update(status: .working, toolName: nil, lastActivityAt: 42, at: 61.5) == nil, "continued work within short feedback preserves the round without stale proud art")
        expect(proud.nextDeadline(after: 61.5) == PetPoseMoodTracker.tiredAfterWork + 0.001, "the 2.5-second success continuation retains the original fatigue deadline")
        expect(proud.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.001) == .tired, "short tool-result feedback does not erase continuous work")

        var busy = PetPoseMoodTracker()
        for index in 0..<PetPoseMoodTracker.busyToolStartThreshold {
            let result = busy.update(
                status: .tool,
                toolName: "search",
                lastActivityAt: Int64(100 + index),
                at: Double(index)
            )
            if index < PetPoseMoodTracker.busyToolStartThreshold - 1 {
                expect(result == nil, "busy mood waits for the fifth tool start")
            } else {
                expect(result == .swampedLeft, "fifth tool start within ten seconds begins swamped-left")
            }
        }
        expect(busy.update(status: .tool, toolName: "search", lastActivityAt: 104, at: 4.5) == .swampedLeft, "re-reading the same tool snapshot does not count a duplicate start")
        expect(busy.update(status: .tool, toolName: "search", lastActivityAt: 105, at: 5) == .swampedRight, "subsequent qualifying tool starts alternate swamped sides")
        expect(busy.nextDeadline(after: 5) == 11.001, "busy mood schedules its inclusive rolling-window expiry")
        expect(busy.advance(at: 10.999) == .swampedRight, "busy mood remains active before the oldest qualifying start expires")
        expect(busy.advance(at: 11) == .swampedRight, "a start exactly ten seconds old remains inside the rolling window")
        expect(busy.advance(at: 11.001) == nil, "busy mood ends when fewer than five starts remain in ten seconds")

        var newBurst = PetPoseMoodTracker()
        for index in 0..<PetPoseMoodTracker.busyToolStartThreshold {
            _ = newBurst.update(status: .tool, toolName: "search", lastActivityAt: Int64(200 + index), at: Double(index))
        }
        expect(newBurst.update(status: .working, toolName: nil, lastActivityAt: 300, at: 20) == nil, "a later quiet work phase is not considered swamped")
        expect(newBurst.update(status: .tool, toolName: "search", lastActivityAt: 301, at: 21) == nil, "expired tool starts do not leak into a later burst")
    }

    private static func testHintsSuppressSleepAndYieldToWorkMood() {
        var idle = PetPoseMoodTracker()
        _ = idle.update(status: .idle, toolName: nil, hint: .confirming, lastActivityAt: 1, at: 0)
        expect(idle.advance(at: 301) == nil, "confirming while idle cannot trigger sleeping")
        _ = idle.update(status: .idle, toolName: nil, hint: .compacting, lastActivityAt: 2, at: 302)
        expect(idle.advance(at: 603) == nil, "compacting while idle cannot trigger sleeping")
        _ = idle.update(status: .idle, toolName: nil, hint: .interrupted, lastActivityAt: 3, at: 604)
        expect(idle.advance(at: 905) == nil, "interrupted hint remains visible instead of sleeping")
        _ = idle.update(status: .idle, toolName: nil, hint: nil, lastActivityAt: 4, at: 906)
        expect(idle.advance(at: 1_206) == nil, "clearing a hint restarts the idle dwell")
        expect(idle.advance(at: 1_206.001) == .sleeping, "ordinary idle sleep resumes after the post-hint dwell")

        for (index, hint) in PetActivityHint.allCases.enumerated() {
            var work = PetPoseMoodTracker()
            _ = work.update(status: .working, toolName: nil, hint: hint, lastActivityAt: Int64(5 + index), at: 0)
            expect(work.advance(at: PetPoseMoodTracker.tiredAfterWork + 1) == nil, "\(hint.rawValue) suppresses fatigue after the threshold")
            expect(work.update(status: .working, toolName: nil, hint: nil, lastActivityAt: Int64(10 + index), at: PetPoseMoodTracker.tiredAfterWork + 1) == .tired, "clearing \(hint.rawValue) restores the accumulated work fatigue")

            var busy = PetPoseMoodTracker()
            for event in 0..<PetPoseMoodTracker.busyToolStartThreshold {
                let result = busy.update(
                    status: .tool,
                    toolName: "search",
                    hint: hint,
                    lastActivityAt: Int64(100 + event),
                    at: Double(event)
                )
                expect(result == nil, "\(hint.rawValue) suppresses swamped mood while active")
            }
            expect(busy.nextDeadline(after: Double(PetPoseMoodTracker.busyToolStartThreshold - 1)) == nil, "\(hint.rawValue) suppresses mood wakeups while active")
            expect(busy.update(status: .tool, toolName: "search", hint: nil, lastActivityAt: 104, at: 4.1) == .swampedLeft, "clearing \(hint.rawValue) restores the current swamped state")

            var proud = PetPoseMoodTracker()
            _ = proud.update(status: .working, toolName: nil, lastActivityAt: Int64(200 + index), at: 0)
            expect(proud.update(status: .success, toolName: nil, hint: hint, lastActivityAt: Int64(210 + index), at: PetPoseMoodTracker.proudAfterWork) == nil, "\(hint.rawValue) suppresses proud mood while active")
            expect(proud.update(status: .success, toolName: nil, hint: nil, lastActivityAt: Int64(210 + index), at: PetPoseMoodTracker.proudAfterWork + 1) == .proud, "clearing \(hint.rawValue) restores proud success feedback")
        }
    }

    private static func testFatiguePriorityAndWakeups() {
        var busyWins = PetPoseMoodTracker()
        _ = busyWins.update(status: .working, toolName: nil, lastActivityAt: 300, at: 0)
        var finalBurstResult: PetPoseMood?
        for event in 0..<PetPoseMoodTracker.busyToolStartThreshold {
            finalBurstResult = busyWins.update(
                status: .tool,
                toolName: "search",
                lastActivityAt: Int64(301 + event),
                at: PetPoseMoodTracker.tiredAfterWork + Double(event) * 0.1
            )
        }
        expect(finalBurstResult == .swampedLeft, "a qualifying busy burst outranks fatigue when both conditions are true")
        expect(busyWins.nextDeadline(after: PetPoseMoodTracker.tiredAfterWork + 0.4) == PetPoseMoodTracker.tiredAfterWork + 10.001, "the active busy window schedules one expiry wake instead of repeating tired wakeups")
        expect(busyWins.advance(at: PetPoseMoodTracker.tiredAfterWork + 10) == .swampedLeft, "the oldest tool start remains in the inclusive ten-second window")
        expect(busyWins.advance(at: PetPoseMoodTracker.tiredAfterWork + 10.001) == .tired, "fatigue appears after the busy priority expires")
        expect(busyWins.nextDeadline(after: PetPoseMoodTracker.tiredAfterWork + 10.001) == nil, "fatigue settles without repeated wakeups")

        var proudWins = PetPoseMoodTracker()
        _ = proudWins.update(status: .working, toolName: nil, lastActivityAt: 400, at: 0)
        expect(proudWins.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.001) == .tired, "working status alone reaches the fatigue mood")
        expect(proudWins.update(status: .success, toolName: nil, lastActivityAt: 401, at: PetPoseMoodTracker.tiredAfterWork + 1) == .proud, "proud success feedback retains priority over accumulated fatigue")
    }

    private static func testHintPriorityInterruptAndStandby() {
        let poses = allPoses
        var timeline = PetPoseTimeline()
        let confirmingPose = PetPosePlanner.resolvedPose(
            preferred: PetPosePlanner.preferredPose(for: .working, toolName: nil, hint: .confirming),
            availablePoseNames: poses
        )
        let initial = timeline.update(
            status: .working,
            basePose: confirmingPose,
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            hint: .confirming,
            at: 0
        )
        expect(initial == [PetPoseLayer(poseName: "asking", opacity: 1)], "confirming hint covers an ordinary working pose")

        let clear = timeline.update(
            status: .working,
            basePose: "thinking",
            availablePoseNames: poses,
            hint: nil,
            at: 1
        )
        expect(clear == initial && timeline.isTransitioning, "clearing a hint interrupts toward the latest work pose without a jump")
        let changed = timeline.update(
            status: .working,
            basePose: "compact",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            hint: .compacting,
            at: 1.05
        )
        expect(changed == timeline.visibleLayers(at: 1.05) && timeline.isTransitioning, "a new hint retargets the active transition")
        let interrupted = timeline.interruptTransition(at: 1.06)
        expect(interrupted == [PetPoseLayer(poseName: "compact", opacity: 1)], "pointer interaction interrupts the transition at the current hint")
        expect(!timeline.isTransitioning && !timeline.hasActiveReaction, "pointer interaction leaves the timeline responsive")

        expect(PetPosePlanner.preferredPose(for: .error, toolName: nil, hint: .confirming) == "oops", "error short feedback outranks a pending hint")
        _ = timeline.update(status: .error, basePose: "oops", availablePoseNames: poses, hint: nil, at: 2)
        expect(timeline.advance(at: 4.499) == [PetPoseLayer(poseName: "oops", opacity: 1)], "error art remains visible during the host short-feedback interval")
        let restored = timeline.update(
            status: .working,
            basePose: "asking",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            hint: .confirming,
            at: 4.5
        )
        expect(restored == [PetPoseLayer(poseName: "oops", opacity: 1)], "the latest hint returns as soon as error feedback ends")
        expect(timeline.advance(at: 4.7) == [PetPoseLayer(poseName: "asking", opacity: 1)], "the hint settles through the normal cross-fade")

        var idleTimeline = PetPoseTimeline()
        _ = idleTimeline.update(
            status: .idle,
            basePose: "surprised",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            hint: .interrupted,
            at: 0
        )
        expect(idleTimeline.nextWakeAt(after: 0) == nil, "interrupted hint does not start idle variations while active")
        _ = idleTimeline.update(status: .idle, basePose: "idle", availablePoseNames: poses, hint: nil, at: 1)
        expect((idleTimeline.nextWakeAt(after: 1) ?? 0) > 1, "clearing interrupted returns to the regular idle schedule")
    }

    private static func testSleepingDoesNotRestartIdleAnimation() {
        var timeline = PetPoseTimeline()
        let poses = allPoses + ["sleeping", "tired", "swamped_left", "swamped_right", "proud"]
        _ = timeline.update(
            status: .idle,
            basePose: "sleeping",
            availablePoseNames: poses,
            allowsIdleAnimation: false,
            at: 0
        )
        expect(timeline.nextWakeAt(after: 0) == nil, "sleeping suppresses the ordinary idle animation schedule")
        expect(timeline.advance(at: 0.21) == [PetPoseLayer(poseName: "sleeping", opacity: 1)], "sleeping settles without periodic pose changes")
        let wake = timeline.update(status: .working, basePose: "thinking", availablePoseNames: poses, at: 1)
        expect(wake == [PetPoseLayer(poseName: "sleeping", opacity: 1)], "new work starts its wake transition from the visible sleeping pose")
        expect(timeline.advance(at: 1.21) == [PetPoseLayer(poseName: "thinking", opacity: 1)], "wake transition returns to the current work pose")
    }

    private static func testFixedHeightLayoutAndTransform() {
        let layout = PetCharacterLayout(maximumAspectRatio: 0.9)
        let narrow = layout.imageRect(containerWidth: layout.windowSize.width, sourceWidth: 512, sourceHeight: 640)
        let wide = layout.imageRect(containerWidth: layout.windowSize.width, sourceWidth: 576, sourceHeight: 640)
        expect(abs(narrow.height - layout.displayHeight) < 1e-9, "narrow pose uses the fixed display height")
        expect(abs(wide.height - layout.displayHeight) < 1e-9, "wide pose uses the same fixed display height")
        expect(narrow.y == wide.y && narrow.y == layout.bottomInset, "all poses share one bottom anchor")
        expect(narrow.minX >= layout.horizontalInset && wide.maxX <= layout.windowSize.width - layout.horizontalInset, "maximum catalog ratio leaves horizontal motion margin")

        let anchor = PetPointerPoint(x: layout.windowSize.width / 2, y: layout.bottomInset)
        let motion = PetCharacterMotion(
            width: layout.windowSize.width,
            height: layout.windowSize.height,
            phase: 0,
            reactionProgress: 0.25,
            isError: false,
            anchor: anchor
        )
        let rect = layout.imageRect(containerWidth: layout.windowSize.width, sourceWidth: 576, sourceHeight: 640)
        for point in [
            PetPointerPoint(x: rect.minX, y: rect.minY),
            PetPointerPoint(x: rect.maxX, y: rect.minY),
            PetPointerPoint(x: rect.minX, y: rect.maxY),
            PetPointerPoint(x: rect.maxX, y: rect.maxY),
        ] {
            let moved = motion.applying(to: point)
            expect(moved.x >= 0 && moved.x <= layout.windowSize.width, "transformed artwork remains inside the width reserved from max aspect ratio")
            expect(moved.y >= 0 && moved.y <= layout.windowSize.height, "bottom-anchored response remains inside the window")
            let restored = motion.unapplying(to: moved)
            expect(abs(restored.x - point.x) < 1e-9 && abs(restored.y - point.y) < 1e-9, "draw and alpha-hit inverse transforms agree")
        }
    }

    private static func testWorkRhythmThroughTimeline() {
        let poses = allPoses
        let workSet = PetWorkPoseSet(
            thinking: "thinking",
            busyLeft: "busy_left",
            thinkingVariant: "thinking-2",
            busyRight: "busy_right"
        )
        var scheduler = PetWorkPoseScheduler()
        var timeline = PetPoseTimeline()

        func render(at time: Double, status: PetActivityStatus = .working, hint: PetActivityHint? = nil) -> [PetPoseLayer] {
            let realPose = PetPosePlanner.resolvedPose(
                preferred: PetPosePlanner.preferredPose(for: status, toolName: nil, hint: hint),
                availablePoseNames: poses
            )
            let tick = scheduler.update(
                PetWorkPoseSchedulerInput(
                    sessionId: "session-timeline",
                    workSegmentStart: 0,
                    status: status,
                    hint: hint,
                    hasPriorityState: false,
                    allowsAutonomousRotation: true,
                    interactionIsActive: timeline.hasActiveReaction,
                    realPose: realPose
                ),
                workPoses: workSet,
                at: time
            )
            return timeline.update(
                status: status,
                basePose: tick.pose ?? realPose,
                availablePoseNames: poses,
                hint: hint,
                at: time
            )
        }

        expect(render(at: 0) == [PetPoseLayer(poseName: "thinking", opacity: 1)],
               "the rhythm's first frame settles immediately")
        expect(timeline.nextWakeAt(after: 0) == nil, "a stable rhythm stage adds no animation timer of its own")
        let boundary = render(at: 6.001)
        expect(boundary == [PetPoseLayer(poseName: "thinking", opacity: 1)],
               "a rhythm stage change starts from the currently visible pose")
        let midFade = timeline.advance(at: 6.101)
        expect(midFade.count == 2 && opacity("busy_left", in: midFade) > 0.4 && opacity("thinking", in: midFade) > 0.4,
               "a rhythm stage change goes through the shared cross-fade")
        expect(timeline.advance(at: 6.201) == [PetPoseLayer(poseName: "busy_left", opacity: 1)],
               "the rhythm cross-fade settles in 0.20 seconds")
        expect(render(at: 10.001) == [PetPoseLayer(poseName: "busy_left", opacity: 1)],
               "the next stage also starts from what is on screen")
        expect(timeline.advance(at: 10.201) == [PetPoseLayer(poseName: "thinking-2", opacity: 1)],
               "the thinking variant settles without a jump")

        // A tool preempts an in-flight rhythm cross-fade without a visible jump.
        let mid = timeline.update(status: .working, basePose: "busy_right", availablePoseNames: poses, at: 17.1)
        let tool = timeline.update(status: .tool, basePose: "reading", availablePoseNames: poses, at: 17.1)
        expect(tool == mid, "a real tool interrupts the rhythm cross-fade continuously")
        expect(timeline.advance(at: 17.31) == [PetPoseLayer(poseName: "reading", opacity: 1)],
               "the real tool pose settles normally")

        // A hint covers the rhythm and falls back through the existing chain.
        let hintLayers = render(at: 18, hint: .confirming)
        expect(hintLayers.count >= 1, "a hint produces a visible target")
        expect(timeline.advance(at: 18.21) == [PetPoseLayer(poseName: "asking", opacity: 1)],
               "a hint reaches the asking pose while the rhythm is suspended")
        expect(scheduler.nextDeadline(after: 18) == nil, "a suspended rhythm schedules no wake-up")
    }

    private static func testTapResponseDefersRotation() {
        let poses = allPoses
        let workSet = PetWorkPoseSet(
            thinking: "thinking",
            busyLeft: "busy_left",
            thinkingVariant: "thinking-2",
            busyRight: "busy_right"
        )
        var scheduler = PetWorkPoseScheduler()
        var timeline = PetPoseTimeline()

        func tick(at time: Double) -> PetWorkPoseSchedulerTick {
            scheduler.update(
                PetWorkPoseSchedulerInput(
                    sessionId: "session-tap",
                    workSegmentStart: 0,
                    status: .working,
                    hint: nil,
                    hasPriorityState: false,
                    allowsAutonomousRotation: true,
                    interactionIsActive: timeline.hasActiveReaction,
                    realPose: "thinking"
                ),
                workPoses: workSet,
                at: time
            )
        }

        _ = tick(at: 0)
        _ = timeline.update(status: .working, basePose: "thinking", availablePoseNames: poses, at: 0)
        _ = timeline.beginReaction(pose: "happy", at: 5)
        let duringTap = tick(at: 5)
        expect(duringTap.pose == "thinking", "the rhythm holds its stage during a tap response")
        expect(duringTap.nextDeadline == nil, "no rhythm deadline can cancel the tap response")
        let responseFade = timeline.advance(at: 5.1)
        expect(opacity("happy", in: responseFade) > 0, "the tap response itself is not interrupted by the rhythm")
        _ = timeline.advance(at: 5.6)
        expect(!timeline.hasActiveReaction, "the tap response ends on its own short duration")
        let resumed = tick(at: 5.6)
        expect(resumed.pose == "thinking", "the rhythm resumes on the same stage after the response")
        expect(resumed.nextDeadline == 6.6, "the 0.6-second pause is removed from the cycle instead of being skipped")

        // Pointer-down during a response settles on the latest state, as before.
        _ = timeline.beginReaction(pose: "happy", at: 7)
        let afterPointerDown = timeline.interruptReaction(at: 7.1)
        expect(!timeline.hasActiveReaction, "pointer-down still cancels the tap response")
        expect(afterPointerDown.contains { $0.poseName == "thinking" }, "pointer-down returns to the rhythm pose")
    }

    private static func testReducedMotionStopsRotationNotFeedback() {
        let poses = allPoses
        let workSet = PetWorkPoseSet(
            thinking: "thinking",
            busyLeft: "busy_left",
            thinkingVariant: "thinking-2",
            busyRight: "busy_right"
        )
        var scheduler = PetWorkPoseScheduler()
        var timeline = PetPoseTimeline()
        let reduced = scheduler.update(
            PetWorkPoseSchedulerInput(
                sessionId: "session-motion",
                workSegmentStart: 0,
                status: .working,
                hint: nil,
                hasPriorityState: false,
                allowsAutonomousRotation: false,
                interactionIsActive: false,
                realPose: "thinking"
            ),
            workPoses: workSet,
            at: 0
        )
        expect(reduced.pose == nil && reduced.nextDeadline == nil,
               "reduced motion removes the autonomous work rotation")
        expect(timeline.update(
            status: .working,
            basePose: "thinking",
            availablePoseNames: poses,
            reduceMotion: true,
            at: 0
        ) == [PetPoseLayer(poseName: "thinking", opacity: 1)], "the stable work pose still renders")
        _ = timeline.update(status: .tool, basePose: "reading", availablePoseNames: poses, reduceMotion: true, at: 1)
        expect(timeline.advance(at: 1.04).count == 2, "real tool feedback still cross-fades under reduced motion")
        expect(timeline.advance(at: 1.09) == [PetPoseLayer(poseName: "reading", opacity: 1)],
               "reduced-motion feedback settles quickly")
    }

    private static func testMoodRegressionWithRhythm() {
        let poses = allPoses + ["sleeping", "tired", "swamped_left", "swamped_right", "proud"]
        let workSet = PetWorkPoseSet(
            thinking: "thinking",
            busyLeft: "busy_left",
            thinkingVariant: "thinking-2",
            busyRight: "busy_right"
        )
        var mood = PetPoseMoodTracker()
        var scheduler = PetWorkPoseScheduler()
        var timeline = PetPoseTimeline()

        // Thirty seconds of rhythm must not shorten the fatigue threshold.
        var time = 0.0
        while time <= 30 {
            _ = mood.update(status: .working, toolName: nil, lastActivityAt: 10, at: time)
            _ = scheduler.update(
                PetWorkPoseSchedulerInput(
                    sessionId: "session-mood",
                    workSegmentStart: mood.continuousWorkStart,
                    status: .working,
                    hint: nil,
                    hasPriorityState: false,
                    allowsAutonomousRotation: true,
                    interactionIsActive: false,
                    realPose: "thinking"
                ),
                workPoses: workSet,
                at: time
            )
            time += 1
        }
        expect(mood.mood(at: 30) == nil, "rhythm changes alone never reach a mood")
        _ = timeline.update(status: .working, basePose: "thinking", availablePoseNames: poses, at: 30)

        // Fatigue: the mood owns the artwork and the rhythm goes quiet.
        let tiredMood = mood.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.01)
        expect(tiredMood == .tired, "continuous work still reaches fatigue")
        let tiredPose = PetPoseMood.resolvedPose(for: .tired, workPose: "thinking", availablePoseNames: poses)
        let tiredTick = scheduler.update(
            PetWorkPoseSchedulerInput(
                sessionId: "session-mood",
                workSegmentStart: mood.continuousWorkStart,
                status: .working,
                hint: nil,
                hasPriorityState: true,
                allowsAutonomousRotation: true,
                interactionIsActive: false,
                realPose: tiredPose
            ),
            workPoses: workSet,
            at: PetPoseMoodTracker.tiredAfterWork + 0.01
        )
        expect(tiredTick.pose == nil && tiredTick.nextDeadline == nil, "fatigue silences the rhythm entirely")
        _ = timeline.update(
            status: .working,
            basePose: tiredPose,
            availablePoseNames: poses,
            allowsIdleAnimation: true,
            at: PetPoseMoodTracker.tiredAfterWork + 0.01
        )
        expect(timeline.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.21) == [PetPoseLayer(poseName: "tired", opacity: 1)],
               "the tired pose still renders through the same timeline")

        // Idle → sleeping still needs strictly more than five minutes.
        var sleepy = PetPoseMoodTracker()
        _ = sleepy.update(status: .idle, toolName: nil, lastActivityAt: 99, at: 0)
        expect(sleepy.advance(at: PetPoseMoodTracker.sleepAfterIdle) == nil, "sleep remains strict")
        expect(sleepy.advance(at: PetPoseMoodTracker.sleepAfterIdle + 0.001) == .sleeping,
               "sleep still begins just past five idle minutes")
    }

    private static var allPoses: [String] {
        ["idle", "idle-2", "idle-3", "idle-blink", "thinking", "writing", "busy_left", "busy_right", "happy", "oops", "asking", "listening", "compact", "surprised"]
    }

    private static func opacity(_ pose: String, in layers: [PetPoseLayer]) -> Double {
        layers.first(where: { $0.poseName == pose })?.opacity ?? 0
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checkCount += 1
        guard condition() else { fatalError("CHECK FAILED: \(message)") }
    }
}
