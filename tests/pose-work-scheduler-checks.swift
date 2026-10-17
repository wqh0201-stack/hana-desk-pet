import Foundation

// Ordinary-work rhythm and tool-return grace checks (plan §6 A / A2 / B).
//
// Every check drives a caller-supplied monotonic clock; nothing here sleeps, opens a
// listener, contacts a real Hana host or posts to 127.0.0.1:43127. The real catalog is
// used only to prove the seven characters' candidate sets and the missing-artwork branch.

@main
private struct PoseWorkSchedulerChecks {
    private static var checks = 0

    private static let basePoses = PetWorkPoseSet(
        thinking: "thinking",
        busyLeft: "busy_left",
        thinkingVariant: "thinking-2",
        busyRight: "busy_right"
    )

    static func main() throws {
        try checkCandidateSetsFromRealCatalog()
        try checkRhythmAdvancement()
        try checkIdempotentHeartbeats()
        try checkDormantJumpDoesNotReplay()
        try checkIdentityAndGenerationInvalidateCallbacks()
        try checkToolReturnGraceFormula()
        try checkPreemptionAndResume()
        try checkSuppressionSwitches()
        try checkInteractionPause()
        try checkWorkClockIsolation()
        print("PoseWorkSchedulerChecks: \(checks) checks passed.")
    }

    // MARK: - A. Real catalog candidate sets

    private static func checkCandidateSetsFromRealCatalog() throws {
        let root = CommandLine.arguments.dropFirst().first ?? "assets/crosspet"
        let catalog = try PetArtworkCatalog(directoryURL: URL(fileURLWithPath: root, isDirectory: true))
        let expectedVariant = [
            "claude": "thinking-2",
            "gpt": "thinking",
            "deepseek": "deepthink",
            "gemini": "thinking",
            "glm": "thinking",
            "deepseek-hoodie": "deepthink",
            "gpt-onesie": "thinking",
        ]
        let forbidden = [
            "reading", "writing", "searching", "running", "delegating", "drawing",
            "happy", "oops", "asking", "compact", "surprised",
            "sleeping", "tired", "swamped_left", "swamped_right", "proud",
        ]

        for role in PetRole.builtIns {
            let poses = catalog.poseNames(forCharacterID: role.id)
            guard let set = PetPosePlanner.workPoseSet(characterID: role.id, availablePoseNames: poses) else {
                fatalError("CHECK FAILED: \(role.id) has no ordinary-work rhythm")
            }
            expect(set.thinking == "thinking", "\(role.id) rhythm starts from its base thinking pose")
            expect(set.busyLeft == "busy_left" && set.busyRight == "busy_right",
                   "\(role.id) rhythm uses the generic busy poses")
            expect(set.thinkingVariant == expectedVariant[role.id], "\(role.id) third stage uses its own character variant")
            expect(set.distinctPoses.count >= 3, "\(role.id) exposes at least three distinct work poses")
            for pose in set.distinctPoses {
                expect(poses.contains(pose), "\(role.id) work candidate \(pose) is catalogued artwork")
            }
            for pose in forbidden {
                expect(!set.distinctPoses.contains(pose), "\(role.id) never decorates ordinary work with \(pose)")
            }

            let phases = PetWorkPoseScheduler.phases(for: set)
            expect(phases.map(\.pose) == [set.thinking, set.busyLeft, set.thinkingVariant, set.busyRight],
                   "\(role.id) plays thinking → busy_left → variant → busy_right")
            expect(phases.map(\.duration) == [6, 4, 7, 5], "\(role.id) uses the first-version stage durations")
            expect(abs(phases.reduce(0) { $0 + $1.duration } - 22) < 1e-9, "\(role.id) cycle is 22 seconds")

            // The runtime rhythm agrees with the declared phases.
            var scheduler = PetWorkPoseScheduler()
            _ = scheduler.update(
                input(workSegmentStart: 0),
                workPoses: set,
                at: 0
            )
            let observed = stride(from: 0.0, through: 60.0, by: 0.25).map { scheduler.currentPose(at: $0) }
            expect(Set(observed.compactMap { $0 }) == Set(set.distinctPoses),
                   "\(role.id) a minute of ordinary work only ever shows its own four rhythm poses")
            expect(!observed.contains("writing"), "\(role.id) never revisits the removed working→writing mapper")
        }

        let claude = catalog.poseNames(forCharacterID: "claude")
        expect(PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: claude)?.thinkingVariant == "thinking-2" &&
               claude.contains("thinking-2"),
               "Claude reaches the thinking-2 variant")
        for id in ["deepseek", "deepseek-hoodie"] {
            let poses = catalog.poseNames(forCharacterID: id)
            expect(PetPosePlanner.workPoseSet(characterID: id, availablePoseNames: poses)?.thinkingVariant == "deepthink" &&
                   poses.contains("deepthink"),
                   "\(id) reaches the deepthink variant")
        }
        for id in ["gpt", "gemini", "glm", "gpt-onesie"] {
            let poses = catalog.poseNames(forCharacterID: id)
            expect(PetPosePlanner.workPoseSet(characterID: id, availablePoseNames: poses)?.thinkingVariant == "thinking",
                   "\(id) stays on base thinking for its third stage")
        }

        // Missing-artwork branches: no cycle rather than a wake-up that cannot change art.
        expect(PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: []) == nil,
               "an empty catalog has no work rhythm")
        expect(PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: ["idle"]) == nil,
               "a single available pose collapses to the stable baseline")
        expect(PetPosePlanner.workPoseSet(characterID: "claude", availablePoseNames: ["idle", "thinking"]) == nil,
               "one distinct work pose means no cycle")
        let missingVariant = PetPosePlanner.workPoseSet(
            characterID: "claude",
            availablePoseNames: ["idle", "thinking", "busy_left", "busy_right"]
        )
        expect(missingVariant?.thinkingVariant == "thinking", "a missing thinking variant falls back to base thinking")
        expect(missingVariant.map { PetWorkPoseScheduler.phases(for: $0).map(\.pose) } ==
               ["thinking", "busy_left", "thinking", "busy_right"],
               "a missing variant still shows base thinking in the third stage")
        let noRight = PetPosePlanner.workPoseSet(
            characterID: "claude",
            availablePoseNames: ["idle", "thinking", "busy_left"]
        )
        expect(noRight?.supportsRhythm == true, "a missing busy_right keeps a two-pose rhythm")
        expect(PetWorkPoseScheduler.phases(for: noRight!).map(\.pose) == ["thinking", "busy_left"],
               "the trailing repeated stage is trimmed so the cycle restarts on a visible change")

        // A scheduler with no usable set stays dormant and never schedules a wake-up.
        var scheduler = PetWorkPoseScheduler()
        let tick = scheduler.update(input(), workPoses: nil, at: 0)
        expect(tick.pose == nil && tick.nextDeadline == nil, "no candidate set means no autonomous wake-up")
    }

    // MARK: - A. Rhythm advancement

    private static func checkRhythmAdvancement() throws {
        var scheduler = PetWorkPoseScheduler()
        let first = scheduler.update(input(), workPoses: basePoses, at: 0)
        expect(first.pose == "thinking", "the first work frame is the base thinking pose")
        expect(first.nextDeadline == PetWorkPoseScheduler.thinkingHold, "the next autonomous change is 6 seconds out")
        expect(scheduler.currentPose(at: 0.999) == "thinking", "nothing changes during the first second")
        expect(scheduler.currentPose(at: 5.999) == "thinking", "the base thinking pose holds 6 seconds")
        expect(scheduler.currentPose(at: 6.001) == "busy_left", "the second stage starts just past 6 seconds")
        expect(scheduler.currentPose(at: 9.999) == "busy_left", "busy_left holds 4 seconds")
        expect(scheduler.currentPose(at: 10.001) == "thinking-2", "the third stage is the thinking variant")
        expect(scheduler.currentPose(at: 16.999) == "thinking-2", "the variant holds 7 seconds")
        expect(scheduler.currentPose(at: 17.001) == "busy_right", "the fourth stage is busy_right")
        expect(scheduler.currentPose(at: 21.999) == "busy_right", "busy_right holds 5 seconds")
        expect(scheduler.currentPose(at: 22.001) == "thinking", "the cycle restarts after 22 seconds")

        // No single pose overstays: the longest stage is the 7-second variant, so 7.3 s is
        // the ceiling the plan allows (7 s + transition tolerance).
        var previous = scheduler.currentPose(at: 0)
        var previousAt = 0.0
        var longest = 0.0
        for step in stride(from: 0.05, through: 60.0, by: 0.05) {
            let pose = scheduler.currentPose(at: step)
            if pose != previous {
                longest = max(longest, step - previousAt)
                previous = pose
                previousAt = step
            }
        }
        longest = max(longest, 60 - previousAt)
        expect(longest <= 7.3, "no ordinary work pose stays longer than 7.3 seconds (observed \(longest))")

        // Stage changes still use the existing, interruptible cross-fade; the timeline is
        // exercised in pose-timeline-checks.swift, which links it directly.
        expect(scheduler.currentPose(at: 10.001) != scheduler.currentPose(at: 9.999),
               "the stage change is visible to the renderer at the boundary")
    }

    // MARK: - A. Idempotent heartbeats

    private static func checkIdempotentHeartbeats() throws {
        // Feeding the same status every quarter second must land on exactly the same phase
        // as a single update followed by clock advancement. Both run forward in lockstep,
        // because the monotonic clock never moves backwards.
        var heartbeats = PetWorkPoseScheduler()
        var single = PetWorkPoseScheduler()
        var generations = Set<UInt64>()
        var probePoses: [TimeInterval: String?] = [:]
        let probes: Set<TimeInterval> = [0, 5.75, 6.25, 10.25, 17.25, 21.25]
        _ = single.update(input(), workPoses: basePoses, at: 0)
        var t = 0.0
        while t <= 25.0001 {
            generations.insert(heartbeats.update(input(), workPoses: basePoses, at: t).generation)
            expect(heartbeats.currentPose(at: t) == single.currentPose(at: t),
                   "an identical heartbeat at \(t) reaches the same phase as one update plus time")
            if probes.contains(t) { probePoses[t] = single.currentPose(at: t) }
            t += 0.25
        }
        expect(generations.count == 1, "repeated identical heartbeats never bump the generation")
        expect(probePoses[6.25] == "busy_left",
               "a fast refresh cannot pin the rhythm on the first stage forever")
        expect(probePoses[10.25] == "thinking-2", "the fast refresh also reaches the thinking variant")
        expect(probePoses[0] == "thinking", "the first frame is still the base thinking pose")

        // A heartbeat with a repeated payload after a real stage change keeps the cycle clock.
        var resetCheck = PetWorkPoseScheduler()
        _ = resetCheck.update(input(), workPoses: basePoses, at: 0)
        let heartbeat = resetCheck.update(input(), workPoses: basePoses, at: 8)
        expect(heartbeat.generation == resetCheck.currentGeneration, "an unchanged heartbeat keeps its generation")
        expect(heartbeat.pose == "busy_left", "a heartbeat at 8 seconds stays in the second stage")
        expect(resetCheck.update(input(), workPoses: basePoses, at: 10.5).pose == "thinking-2",
               "the heartbeat does not restart the cycle clock")
    }

    // MARK: - A. Dormant jump

    private static func checkDormantJumpDoesNotReplay() throws {
        var scheduler = PetWorkPoseScheduler()
        _ = scheduler.update(input(), workPoses: basePoses, at: 0)
        // A single jump to 31 s (sleep/wake or a main-thread stall) lands on the current
        // phase instead of replaying the skipped stages.
        expect(scheduler.currentPose(at: 31) == "busy_left",
               "a 31-second jump lands on the phase nine seconds into the 22-second cycle")
        let jumped = scheduler.advance(
            identity: scheduler.currentIdentity,
            generation: scheduler.currentGeneration,
            at: 31
        )
        expect(jumped.pose == "busy_left", "one jumped tick reports only the current target")
        expect(jumped.nextDeadline == 32, "the jumped tick schedules the next boundary, not a replay queue")

        var hidden = PetWorkPoseScheduler()
        _ = hidden.update(input(), workPoses: basePoses, at: 0)
        let hiddenTick = hidden.update(input(allowsAutonomousRotation: false), workPoses: basePoses, at: 40)
        expect(hiddenTick.pose == nil && hiddenTick.nextDeadline == nil,
               "a hidden window schedules no rotation deadline")
        let restored = hidden.update(input(), workPoses: basePoses, at: 400)
        expect(restored.pose == "thinking", "restoring visibility rebuilds the rhythm from the current state")
        expect(restored.nextDeadline == 406, "the rebuilt rhythm starts a fresh stage instead of catching up")
    }

    // MARK: - A2. Identity, generation, stale callbacks

    private static func checkIdentityAndGenerationInvalidateCallbacks() throws {
        var scheduler = PetWorkPoseScheduler()
        _ = scheduler.update(input(sessionId: "session-A", workSegmentStart: 100), workPoses: basePoses, at: 0)
        let identityA = scheduler.currentIdentity
        let generationA = scheduler.currentGeneration
        expect(identityA?.sessionId == "session-A", "the scheduler records the session it is following")

        // A callback queued in session A fires after the switch to session B.
        _ = scheduler.update(input(sessionId: "session-B", workSegmentStart: 200), workPoses: basePoses, at: 30)
        expect(scheduler.currentIdentity?.sessionId == "session-B", "the scheduler follows the new session")
        expect(scheduler.currentGeneration > generationA, "a session change bumps the generation")
        let poseBefore = scheduler.currentPose(at: 30)
        let deadlineBefore = scheduler.nextDeadline(after: 30)
        let stale = scheduler.advance(identity: identityA, generation: generationA, at: 31)
        expect(stale.discardedStaleTick && stale.pose == nil, "an old (identity, generation) callback spins empty")
        expect(scheduler.currentPose(at: 31) == poseBefore, "a stale callback cannot write a pose")
        expect(scheduler.nextDeadline(after: 31) == deadlineBefore, "a stale callback cannot reschedule a deadline")

        // A work-segment rebuild inside the same session also invalidates queued callbacks.
        var rebuilt = PetWorkPoseScheduler()
        _ = rebuilt.update(input(sessionId: "session-A", workSegmentStart: 300), workPoses: basePoses, at: 0)
        let oldIdentity = rebuilt.currentIdentity
        let oldGeneration = rebuilt.currentGeneration
        _ = rebuilt.update(input(sessionId: "session-A", workSegmentStart: 310), workPoses: basePoses, at: 5)
        expect(rebuilt.currentIdentity != oldIdentity, "a new work segment start is a new identity")
        expect(rebuilt.currentGeneration > oldGeneration, "a work-segment rebuild bumps the generation")
        expect(rebuilt.advance(identity: oldIdentity, generation: oldGeneration, at: 6).discardedStaleTick,
               "a callback from the previous work segment is discarded")

        // An identical heartbeat is not a new identity.
        var steady = PetWorkPoseScheduler()
        _ = steady.update(input(sessionId: "session-A", workSegmentStart: 400), workPoses: basePoses, at: 0)
        let steadyGeneration = steady.currentGeneration
        _ = steady.update(input(sessionId: "session-A", workSegmentStart: 400), workPoses: basePoses, at: 1)
        expect(steady.currentGeneration == steadyGeneration, "an unchanged identity keeps its generation")
        expect(!steady.advance(identity: steady.currentIdentity, generation: steadyGeneration, at: 2).discardedStaleTick,
               "a current callback is not discarded")

        // Changing outfit inside one session keeps the segment start but rebuilds the phases.
        var redress = PetWorkPoseScheduler()
        _ = redress.update(input(sessionId: "session-A", workSegmentStart: 500), workPoses: basePoses, at: 0)
        expect(redress.currentPose(at: 7) == "busy_left", "the rhythm reached its second stage before redressing")
        let redressed = redress.rebuildRhythm(workPoses: PetWorkPoseSet(
            thinking: "thinking",
            busyLeft: "busy_left",
            thinkingVariant: "deepthink",
            busyRight: "busy_right"
        ), at: 7)
        expect(redress.currentIdentity?.workSegmentStart == 500,
               "changing character inside one session keeps the continuous work start")
        expect(redressed.pose == "thinking", "the rebuilt rhythm restarts from base thinking")
        expect(redressed.generation > 1, "rebuilding the phases bumps the generation")
        expect(redress.currentPose(at: 13.5) == "busy_left", "the rebuilt rhythm runs on the new candidate set")

        expect(PetWorkPoseScheduler().currentGeneration == 0, "a fresh scheduler starts at generation 0")
    }

    // MARK: - B. Tool return grace

    private static func checkToolReturnGraceFormula() throws {
        // Tool pose observed at 10, return to working at 10.5:
        // grace end = max(10 + 2.0, 10.5 + 1.2) = 12.0, i.e. the full 2-second minimum.
        var early = PetWorkPoseScheduler()
        _ = early.update(input(), workPoses: basePoses, at: 0)
        _ = early.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 10)
        expect(early.currentPose(at: 10.2) == nil, "an observed tool pose is owned by the planner, not the scheduler")
        _ = early.update(input(status: .working), workPoses: basePoses, at: 10.5)
        expect(early.currentPose(at: 10.5) == "reading", "a direct tool → working return keeps the tool pose visible")
        expect(early.nextDeadline(after: 10.5) == 12.0, "the grace ends at max(cut + 2.0, return + 1.2)")

        var late = PetWorkPoseScheduler()
        _ = late.update(input(), workPoses: basePoses, at: 0)
        _ = late.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 10)
        _ = late.update(input(status: .working), workPoses: basePoses, at: 14)
        expect(late.currentPose(at: 14) == "reading", "a long tool still shows its pose at the return frame")
        expect(late.nextDeadline(after: 14) == 15.2, "a long tool already used its 2 seconds, so only 1.2 remain")

        // Repeated working heartbeats never extend the grace.
        var repeated = PetWorkPoseScheduler()
        _ = repeated.update(input(), workPoses: basePoses, at: 0)
        _ = repeated.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 10)
        _ = repeated.update(input(status: .working), workPoses: basePoses, at: 10.5)
        let graceDeadline = repeated.nextDeadline(after: 10.5)
        _ = repeated.update(input(status: .working), workPoses: basePoses, at: 11)
        expect(repeated.nextDeadline(after: 11) == graceDeadline, "repeated working heartbeats do not extend the grace")
        expect(repeated.currentPose(at: 11) == "reading", "the grace keeps the tool pose while it lasts")
        let settled = repeated.advance(
            identity: repeated.currentIdentity,
            generation: repeated.currentGeneration,
            at: 12.0
        )
        expect(settled.pose == "thinking", "after the grace the rhythm resumes on base thinking")
        expect(repeated.nextDeadline(after: 12.0) == 18.0, "the resumed rhythm gets a full thinking stage")

        // No grace after success or error: the old tool tail must not be replayed.
        var afterSuccess = PetWorkPoseScheduler()
        _ = afterSuccess.update(input(), workPoses: basePoses, at: 0)
        _ = afterSuccess.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 10)
        _ = afterSuccess.update(input(status: .success, hasPriorityState: true, realPose: "happy"), workPoses: basePoses, at: 10.5)
        let resumed = afterSuccess.update(input(status: .working), workPoses: basePoses, at: 13)
        expect(resumed.pose == "thinking", "tool → success → working never replays the old tool pose")
        expect(resumed.nextDeadline == 19, "the resumed rhythm starts a full thinking stage")

        // A tool that ended before the native side ever saw `.tool` cannot be invented.
        var unseen = PetWorkPoseScheduler()
        _ = unseen.update(input(), workPoses: basePoses, at: 0)
        let unseenTick = unseen.update(input(status: .working), workPoses: basePoses, at: 3)
        expect(unseenTick.pose == "thinking", "a tool that never reached the native side is not fabricated")
        expect(unseenTick.nextDeadline == 6, "the running rhythm keeps its original deadline")

        // Tool A → tool B → working: only the latest tool's grace applies.
        var twoTools = PetWorkPoseScheduler()
        _ = twoTools.update(input(), workPoses: basePoses, at: 0)
        _ = twoTools.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 10)
        _ = twoTools.update(input(status: .tool, realPose: "writing"), workPoses: basePoses, at: 11)
        expect(twoTools.currentPose(at: 11.1) == nil, "a new tool kinds takes over immediately without a queue")
        _ = twoTools.update(input(status: .working), workPoses: basePoses, at: 11.5)
        expect(twoTools.currentPose(at: 11.6) == "writing", "only the newest tool pose is retained")
        expect(twoTools.nextDeadline(after: 11.6) == 13.0, "the newest tool restarts its own grace window")

        // A hint arriving during the grace cancels it immediately.
        var hinted = PetWorkPoseScheduler()
        _ = hinted.update(input(), workPoses: basePoses, at: 0)
        _ = hinted.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 10)
        _ = hinted.update(input(status: .working), workPoses: basePoses, at: 10.5)
        let hintTick = hinted.update(input(hint: .confirming), workPoses: basePoses, at: 10.8)
        expect(hintTick.pose == nil && hintTick.nextDeadline == nil, "a hint cancels the tool grace at once")
        expect(hinted.currentPose(at: 11.0) == nil, "the cancelled grace never resurfaces")
    }

    // MARK: - B. Preemption and resume

    private static func checkPreemptionAndResume() throws {
        var scheduler = PetWorkPoseScheduler()
        _ = scheduler.update(input(), workPoses: basePoses, at: 0)
        expect(scheduler.currentPose(at: 6.5) == "busy_left", "the rhythm reaches busy_left")

        let generationBefore = scheduler.currentGeneration
        let toolTick = scheduler.update(input(status: .tool, realPose: "reading"), workPoses: basePoses, at: 6.5)
        expect(toolTick.pose == nil, "a real tool takes the artwork away from the rhythm at once")
        expect(toolTick.nextDeadline == nil, "no rhythm deadline survives a real tool")
        expect(toolTick.generation > generationBefore, "preemption bumps the generation")

        // Short working phase → grace → base thinking, with no replayed stages.
        _ = scheduler.update(input(status: .working), workPoses: basePoses, at: 7.0)
        expect(scheduler.currentPose(at: 7.5) == "reading", "the tool pose stays through its grace")
        expect(scheduler.nextDeadline(after: 7.5) == 8.5, "the grace is bounded by the tool minimum and the return delay")
        expect(scheduler.currentPose(at: 8.2) == "reading", "the grace runs to its computed end")
        // The merged wake timer fires at the grace end and resumes the rhythm there.
        let resumed = scheduler.advance(
            identity: scheduler.currentIdentity,
            generation: scheduler.currentGeneration,
            at: 8.5
        )
        expect(resumed.pose == "thinking", "ordinary work resumes on base thinking, not the skipped variant")
        expect(resumed.nextDeadline == 14.5, "the resumed rhythm gets a fresh full stage instead of catching up")

        // Errors and hints always win, and the scheduler adds no competing deadline.
        _ = scheduler.update(input(status: .tool, realPose: "writing"), workPoses: basePoses, at: 9)
        let error = scheduler.update(
            input(status: .error, hint: .confirming, hasPriorityState: true, realPose: "oops"),
            workPoses: basePoses,
            at: 9.1
        )
        expect(error.pose == nil && error.nextDeadline == nil, "error and hint are never covered by a rhythm or grace")
        expect(PetPosePlanner.preferredPose(for: .error, toolName: "read_file", hint: .confirming) == "oops",
               "the planner still ranks error above a concurrent hint")

        let success = scheduler.update(
            input(status: .success, hasPriorityState: true, realPose: "happy"),
            workPoses: basePoses,
            at: 9.2
        )
        expect(success.pose == nil && success.nextDeadline == nil,
               "success owns the artwork for the host's own window without scheduler interference")
    }

    // MARK: - Suppression switches

    private static func checkSuppressionSwitches() throws {
        var scheduler = PetWorkPoseScheduler()
        _ = scheduler.update(input(), workPoses: basePoses, at: 0)
        let reduced = scheduler.update(input(allowsAutonomousRotation: false), workPoses: basePoses, at: 2)
        expect(reduced.pose == nil && reduced.nextDeadline == nil,
               "reduced motion or an invisible window stops the decorative rotation")
        let resumed = scheduler.update(input(), workPoses: basePoses, at: 3)
        expect(resumed.pose == "thinking", "restoring animation rebuilds the rhythm from the real state")
        expect(resumed.nextDeadline == 9, "the rebuilt rhythm starts a fresh stage")

        var tired = PetWorkPoseScheduler()
        _ = tired.update(input(), workPoses: basePoses, at: 0)
        let priority = tired.update(input(hasPriorityState: true, realPose: "tired"), workPoses: basePoses, at: 4)
        expect(priority.pose == nil && priority.nextDeadline == nil, "a priority mood silences the rhythm completely")

        var burst = PetWorkPoseScheduler()
        _ = burst.update(input(), workPoses: basePoses, at: 0)
        _ = burst.update(input(status: .tool, realPose: "delegating"), workPoses: basePoses, at: 5)
        _ = burst.update(
            input(status: .tool, hasPriorityState: true, realPose: "delegating"),
            workPoses: basePoses,
            at: 5.2
        )
        expect(burst.currentPose(at: 5.3) == nil, "a burst mood silences an observed tool pose too")
        let suppressedGrace = burst.update(input(status: .working), workPoses: basePoses, at: 5.6)
        expect(suppressedGrace.pose == "thinking",
               "a suppressed tool observation cannot open a grace window later")
        let clear = burst.update(input(status: .tool, realPose: "delegating"), workPoses: basePoses, at: 6)
        expect(clear.pose == nil, "the scheduler defers to the real tool pose reported by the planner")
    }

    // MARK: - Interaction pause

    private static func checkInteractionPause() throws {
        var scheduler = PetWorkPoseScheduler()
        _ = scheduler.update(input(), workPoses: basePoses, at: 0)
        expect(scheduler.currentPose(at: 4) == "thinking", "the tap arrives during the first stage")
        _ = scheduler.update(input(interactionIsActive: true), workPoses: basePoses, at: 4)
        expect(scheduler.isPausedForInteraction, "an active tap response pauses the rhythm")
        expect(scheduler.nextDeadline(after: 4) == nil,
               "a paused rhythm schedules no rotation that could cancel the response")
        expect(scheduler.currentPose(at: 5.5) == "thinking", "the paused stage does not advance during the response")
        _ = scheduler.update(input(interactionIsActive: false), workPoses: basePoses, at: 4.52)
        expect(!scheduler.isPausedForInteraction, "the rhythm resumes when the response ends")
        expect(scheduler.currentPose(at: 5.99) == "thinking", "the paused span is removed rather than skipped")
        expect(scheduler.currentPose(at: 6.53) == "busy_left", "the stage boundary shifts by exactly the pause length")
    }

    // MARK: - D. Two clocks stay isolated

    private static func checkWorkClockIsolation() throws {
        var mood = PetPoseMoodTracker()
        var scheduler = PetWorkPoseScheduler()

        _ = mood.update(status: .working, toolName: nil, lastActivityAt: 10, at: 0)
        let workStart = mood.continuousWorkStart
        expect(workStart == 0, "the mood tracker owns the continuous work start")

        var observed = Set<String>()
        var t = 0.0
        while t <= 30 {
            let built = input(workSegmentStart: mood.continuousWorkStart ?? -1)
            let tick = scheduler.update(built, workPoses: basePoses, at: t)
            if let pose = tick.pose { observed.insert(pose) }
            _ = mood.update(status: .working, toolName: nil, lastActivityAt: 10, at: t)
            t += 0.5
        }
        expect(mood.continuousWorkStart == workStart, "30 seconds of rhythm changes never move the work clock")
        expect(mood.mood(at: 30) == nil, "rhythm changes are not mistaken for fatigue")
        expect(observed.count == 4, "the rhythm really did change poses during the isolation check")

        // The rhythm never counts as a tool start, so it cannot fake the busy mood.
        var busy = PetPoseMoodTracker()
        var burst = PetWorkPoseScheduler()
        var step = 0.0
        while step <= 10 {
            _ = busy.update(status: .working, toolName: nil, lastActivityAt: 500, at: step)
            _ = burst.update(input(workSegmentStart: busy.continuousWorkStart ?? -1), workPoses: basePoses, at: step)
            step += 0.25
        }
        expect(busy.mood(at: 10) == nil, "pose changes within ten seconds never trigger the busy mood")

        // Fatigue still wins and is not reset by the rhythm yielding.
        expect(mood.advance(at: PetPoseMoodTracker.tiredAfterWork) == nil, "the fatigue boundary stays strict")
        let fatigueMood = mood.advance(at: PetPoseMoodTracker.tiredAfterWork + 0.001)
        expect(fatigueMood == .tired, "fatigue still triggers just past the threshold")
        let tiredTick = scheduler.update(
            input(workSegmentStart: mood.continuousWorkStart ?? -1, hasPriorityState: true),
            workPoses: basePoses,
            at: PetPoseMoodTracker.tiredAfterWork + 0.001
        )
        expect(tiredTick.pose == nil, "the rhythm yields to fatigue")
        expect(mood.continuousWorkStart == workStart, "yielding to fatigue does not restart the work clock")

        // A session switch clears the action phases without touching the mood clock.
        let switched = scheduler.update(
            input(sessionId: "session-B", workSegmentStart: 700),
            workPoses: basePoses,
            at: 700
        )
        expect(switched.pose == "thinking", "a new session rebuilds the rhythm from base thinking")
        expect(mood.continuousWorkStart == workStart, "a session change never rewrites the work clock")

        // Changing character in one session does not restart the segment either.
        let sameSegment = scheduler.rebuildRhythm(workPoses: basePoses, at: 720)
        expect(sameSegment.identity?.workSegmentStart == 700, "rebuilding phases keeps the same work segment start")

        // Mood fatigue and the scheduler never share a threshold: the rhythm's stage
        // boundaries are far below ten minutes and cannot trigger the mood by themselves.
        expect(PetWorkPoseScheduler.thinkingHold + PetWorkPoseScheduler.busyLeftHold +
               PetWorkPoseScheduler.thinkingVariantHold + PetWorkPoseScheduler.busyRightHold
               < PetPoseMoodTracker.tiredAfterWork,
               "the action cycle is far shorter than the fatigue threshold")
    }

    // MARK: - Helpers


    private static func input(
        sessionId: String = "session-A",
        workSegmentStart: TimeInterval = 0,
        status: PetActivityStatus = .working,
        hint: PetActivityHint? = nil,
        hasPriorityState: Bool = false,
        allowsAutonomousRotation: Bool = true,
        interactionIsActive: Bool = false,
        realPose: String = "thinking"
    ) -> PetWorkPoseSchedulerInput {
        PetWorkPoseSchedulerInput(
            sessionId: sessionId,
            workSegmentStart: workSegmentStart,
            status: status,
            hint: hint,
            hasPriorityState: hasPriorityState,
            allowsAutonomousRotation: allowsAutonomousRotation,
            interactionIsActive: interactionIsActive,
            realPose: realPose
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
