using System;
using System.Collections.Generic;
using System.Linq;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Core.Tests
{
    /// <summary>Deterministic animation checks driven by synthetic monotonic timestamps.</summary>
    public static class AnimationChecks
    {
        private static readonly ISet<string> FullCatalog = MakeSet(
            "idle", "idle-2", "idle-3", "idle-blink", "thinking", "thinking-2", "deepthink",
            "busy_left", "busy_right", "reading", "writing", "searching", "running", "delegating", "drawing",
            "asking", "listening", "compact", "surprised", "happy", "happy-2", "oops", "sorry",
            "sleeping", "sleeping-2", "tired", "tired-2", "swamped_left", "swamped_right", "proud", "proud-2",
            "picked-up", "picked-up-2");

        public static void Run()
        {
            CheckInitialPoseAndCatalogFallback();
            CheckToolMappingAndPriority();
            CheckMoodThresholdsAndContinuity();
            CheckDenseToolMoodAndWindowExpiry();
            CheckWorkRhythmAndToolReturnGrace();
            CheckIdleVariantsAndReducedMotion();
            CheckCrossFadeAndOneShotWakeups();
            CheckTapDragAndLatestStateRestoration();
            CheckRoleSessionCancellationAndMonotonicWake();
            CheckSemanticToolOutranksAmbientMood();
            CheckSwampedWorkRhythm();
            CheckSpotlightAndCompletionNotice();
            CheckNoticeCenterAndBubbleLayout();
            SubtitleChecks.Run();
        }

        private static void CheckInitialPoseAndCatalogFallback()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetRenderFrame initial = animator.Update(State("idle", null, null, "s1", "claude", 1), 0);
            Check(initial.CharacterId == "claude" && initial.Pose == "idle" && !initial.Fallback,
                "The first update resolves a catalogued idle pose immediately.");
            Check(initial.Layers.Count == 1 && initial.Layers[0].Pose == "idle" && initial.Layers[0].Opacity == 1,
                "The initial frame is drawable without waiting for an animation deadline.");
            AssertLayersBelongTo(initial, FullCatalog);

            ISet<string> smallCatalog = MakeSet("idle", "thinking", "busy_left", "busy_right");
            PetRenderFrame drawingFallback = NewAnimator(smallCatalog)
                .Update(State("tool", "image_gen", null, "s2", "claude", 2), 0);
            Check(drawingFallback.Pose == "thinking" && drawingFallback.Fallback,
                "A missing drawing pose resolves through the character's own catalog and reports fallback.");
            AssertLayersBelongTo(drawingFallback, smallCatalog);
        }

        private static void CheckToolMappingAndPriority()
        {
            string[] mapped = new[]
            {
                "functions::read_file_v2", "functions.write_file", "web.search", "exec_command",
                "delegate_task", "image_gen", "current_status"
            };
            string[] expected = new[] { "reading", "writing", "searching", "running", "delegating", "drawing", "reading" };
            for (int i = 0; i < mapped.Length; i++)
            {
                PetRenderFrame frame = NewAnimator(FullCatalog)
                    .Update(State("tool", mapped[i], null, "tool-" + i, "claude", i + 1), i);
                Check(frame.Pose == expected[i], "Whitelisted tool name maps to its intended pose: " + mapped[i]);
            }

            PetRenderFrame genericRead = NewAnimator(FullCatalog)
                .Update(State("tool", "functions.read", null, "generic", "claude", 20), 0);
            Check(genericRead.Pose == "reading", "Generic read is accepted in the functions namespace.");
            PetRenderFrame foreignGeneric = NewAnimator(FullCatalog)
                .Update(State("tool", "other.read", null, "foreign", "claude", 21), 0);
            Check(foreignGeneric.Pose == "busy_left", "Generic read is not guessed from an unrelated namespace.");
            PetRenderFrame substring = NewAnimator(FullCatalog)
                .Update(State("tool", "not_read_file_backup", null, "substring", "claude", 22), 0);
            Check(substring.Pose == "busy_left", "A matching substring is not treated as an allowlisted tool.");

            PetRenderFrame hinted = NewAnimator(FullCatalog)
                .Update(State("tool", "read_file", "compacting", "hint", "claude", 23), 0);
            Check(hinted.Pose == "compact", "A visible hint outranks ordinary tool artwork.");
            PetRenderFrame interrupted = NewAnimator(FullCatalog)
                .Update(State("working", null, "interrupted", "hint2", "claude", 24), 0);
            Check(interrupted.Pose == "surprised", "Interrupted hint selects its dedicated response.");
            PetRenderFrame error = NewAnimator(FullCatalog)
                .Update(State("error", null, "compacting", "error", "claude", 25), 0);
            Check(error.Pose == "oops" && !error.Fallback, "Error feedback outranks the lower-priority hints.");
            PetRenderFrame confirmingError = NewAnimator(FullCatalog)
                .Update(State("error", null, "confirming", "error-confirm", "claude", 25), 0);
            Check(confirmingError.Pose == "asking", "A pending confirmation outranks even an error.");
            PetRenderFrame disconnected = NewAnimator(FullCatalog)
                .Update(State("tool", "read_file", "confirming", "offline", "claude", 26, false), 0);
            Check(disconnected.Pose == "idle", "A disconnected app cannot keep its tool name or hint on screen.");
        }

        private static void CheckMoodThresholdsAndContinuity()
        {
            PetAnimator idle = NewAnimator(FullCatalog);
            Check(idle.Update(State("idle", null, null, "idle-session", "claude", 100), 0).Pose == "idle",
                "Idle begins in the ordinary pose.");
            Check(idle.Update(State("idle", null, null, "idle-session", "claude", 100), 300).Pose != "sleeping",
                "Sleeping does not start at the exact five-minute boundary.");
            PetRenderFrame sleeping = idle.Update(State("idle", null, null, "idle-session", "claude", 100), 300.001);
            Check(sleeping.Pose == "sleeping", "Idle enters the sleeping mood just after five minutes.");
            PetRenderFrame settledSleep = idle.Update(State("idle", null, null, "idle-session", "claude", 100), 300.3);
            Check(settledSleep.NextWakeAt == null,
                "Once sleeping cross-fade settles, the long-duration mood schedules no repeating wake.");
            PetRenderFrame awake = idle.Update(State("idle", null, null, "idle-session", "claude", 101), 301);
            Check(awake.Pose == "idle", "A newer idle activity timestamp wakes the sleeping pose.");

            PetAnimator working = NewAnimator(FullCatalog);
            working.Update(State("working", null, null, "work-session", "claude", 200), 0);
            Check(working.Update(State("working", null, null, "work-session", "claude", 200), 600).Pose != "tired",
                "Fatigue does not start at the exact ten-minute boundary.");
            PetRenderFrame tired = working.Update(State("working", null, null, "work-session", "claude", 200), 600.001);
            Check(tired.Pose == "tired" && !tired.Fallback, "Continuous work reaches the tired mood after ten minutes.");

            PetAnimator moodFallbackAnimator = NewAnimator(MakeSet("idle", "thinking"));
            moodFallbackAnimator.Update(State("working", null, null, "mood-fallback", "claude", 250), 0);
            PetRenderFrame moodFallback = moodFallbackAnimator.Update(
                State("working", null, null, "mood-fallback", "claude", 250), 600.001);
            Check(moodFallback.Pose == "thinking" && moodFallback.Fallback,
                "Mood fallback reports the final catalog pose when tired artwork is unavailable.");

            PetAnimator proud = NewAnimator(FullCatalog);
            proud.Update(State("working", null, null, "proud-session", "claude", 300), 0);
            PetRenderFrame success = proud.Update(State("success", null, null, "proud-session", "claude", 301), 60);
            Check(success.Pose == "proud" && !success.Fallback,
                "A success after a minute of continuous work gets the proud response.");
            Check(proud.Update(State("success", null, null, "proud-session", "claude", 302), 62.4).Pose == "proud",
                "A new success in the short feedback tail keeps work continuity.");
        }

        private static void CheckDenseToolMoodAndWindowExpiry()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetRenderFrame frame = null;
            for (int i = 0; i < 5; i++)
                frame = animator.Update(State("tool", "mcp_probe", null, "swamped", "claude", 400 + i), i);
            Check(frame != null && frame.Pose == "swamped_left",
                "Five distinct tool starts within ten seconds produce the first swamped side.");
            PetRenderFrame alternating = animator.Update(State("tool", "mcp_probe", null, "swamped", "claude", 405), 5);
            Check(alternating.Pose == "swamped_right", "A further dense tool start alternates the swamped side.");
            PetRenderFrame expired = animator.Update(State("tool", "mcp_probe", null, "swamped", "claude", 405), 15.001);
            Check(expired.Pose != "swamped_left" && expired.Pose != "swamped_right",
                "Tool density leaves the ten-second window without a repeating swamped mood.");
        }

        private static void CheckWorkRhythmAndToolReturnGrace()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetViewState work = State("working", null, null, "rhythm", "claude", 500);
            Check(animator.Update(work, 0).Pose == "thinking", "The work cycle starts at thinking.");
            Check(animator.Update(work, 5.999).Pose == "thinking", "Thinking holds for six seconds.");
            Check(animator.Update(work, 6).Pose == "busy_left", "The second work phase begins at six seconds.");
            Check(animator.Update(work, 10).Pose == "thinking-2", "The third work phase begins after the four-second left hold.");
            Check(animator.Update(work, 17).Pose == "busy_right", "The fourth work phase begins after the seven-second thinking variant.");
            Check(animator.Update(work, 22).Pose == "thinking", "The ordinary work cycle repeats on its 22-second boundary.");

            PetRenderFrame tool = animator.Update(State("tool", "read_file", null, "rhythm", "claude", 501), 23);
            Check(tool.Pose == "reading", "Tool activity owns the real mapped pose.");
            PetViewState returnedWork = State("working", null, null, "rhythm", "claude", 502);
            Check(animator.Update(returnedWork, 23.5).Pose == "reading", "A tool pose remains visible during the return grace period.");
            Check(animator.Update(returnedWork, 24.9).Pose == "reading", "Repeated work updates do not extend the tool grace deadline.");
            Check(animator.Update(returnedWork, 25).Pose == "thinking", "The current work rhythm resumes when tool grace ends.");
        }

        private static void CheckIdleVariantsAndReducedMotion()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetViewState idle = State("idle", null, null, "idle-variants", "claude", 600);
            PetRenderFrame first = animator.Update(idle, 0);
            Check(first.NextWakeAt.HasValue && Math.Abs(first.NextWakeAt.Value - 5.8) < 0.0001,
                "The first idle variation uses the first deterministic schedule interval.");
            animator.Update(idle, 5.8);
            PetRenderFrame variant = animator.Update(idle, 6.01);
            Check(variant.Pose == "idle-2" && !variant.Fallback && variant.Layers.Any(layer => layer.Pose == variant.Pose),
                "The first idle variation is the reported target, is represented in its layers, and is not a fallback.");

            animator.Update(idle, 12.4);
            animator.Update(idle, 17.8);
            PetRenderFrame blink = animator.Update(idle, 17.81);
            Check(blink.Pose == "idle-blink" && !blink.Fallback && blink.Layers.Any(layer => layer.Pose == blink.Pose),
                "A scheduled blink is reported as an intentional timeline target, including during its fade.");

            PetRenderFrame still = NewAnimator(FullCatalog).Update(idle, 30, true, true);
            Check(still.Pose == "idle" && (!still.NextWakeAt.HasValue || still.NextWakeAt.Value > 30.1),
                "Reduced motion suppresses autonomous idle changes while keeping only non-animation mood deadlines.");
            PetRenderFrame hidden = NewAnimator(FullCatalog).Update(idle, 30, false, false);
            Check(hidden.NextWakeAt == null, "A hidden or otherwise disabled renderer schedules no autonomous wake.");
        }

        private static void CheckCrossFadeAndOneShotWakeups()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            animator.Update(State("idle", null, null, "fade", "claude", 650), 0);
            PetRenderFrame changing = animator.Update(State("working", null, null, "fade", "claude", 651), 1);
            Check(changing.Pose == "thinking" && changing.Layers.Any(layer => layer.Pose == changing.Pose),
                "The timeline target is represented even at the zero-opacity start of a cross-fade.");
            Check(changing.NextWakeAt.HasValue && changing.NextWakeAt.Value > 1 &&
                changing.NextWakeAt.Value <= 1 + (1.0 / 30.0) + 0.0001,
                "A continuous cross-fade requests the next visible frame within 30 Hz.");
            double opacity = changing.Layers.Sum(layer => layer.Opacity);
            Check(changing.Layers.Count <= 4 && Math.Abs(opacity - 1) < 0.0001,
                "Cross-fade layers stay bounded and their normalized opacities sum to one.");

            PetRenderFrame retargeted = animator.Update(State("tool", "read_file", null, "fade", "claude", 652), 1.05);
            Check(retargeted.Layers.Count <= 4 && Math.Abs(retargeted.Layers.Sum(layer => layer.Opacity) - 1) < 0.0001,
                "An interrupted fade retargets from the visible blend without accumulating layers.");
        }

        private static void CheckTapDragAndLatestStateRestoration()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetViewState work = State("working", null, null, "interaction", "claude", 700);
            animator.Update(work, 0);
            animator.Tap(0.1);
            PetRenderFrame tap = animator.Update(work, 0.2);
            Check(tap.Pose == "happy" && !tap.Fallback && tap.Layers.Any(layer => layer.Pose == tap.Pose) && tap.NextWakeAt.HasValue,
                "A tap reports its catalogued happy target without mislabeling the active response as a fallback.");

            PetAnimator substitutedTap = NewAnimator(MakeSet("idle", "thinking", "happy-2"));
            PetViewState reducedCatalogWork = State("working", null, null, "tap-fallback", "claude", 699);
            substitutedTap.Update(reducedCatalogWork, 0);
            substitutedTap.Tap(0.1);
            PetRenderFrame substitutedReaction = substitutedTap.Update(reducedCatalogWork, 0.2);
            Check(substitutedReaction.Pose == "happy-2" && substitutedReaction.Fallback,
                "A tap reports fallback only when its intended happy artwork is genuinely absent.");

            animator.BeginPointer(0.21);
            PetRenderFrame interruptedTap = animator.Update(work, 0.22);
            Check(interruptedTap.Layers.All(layer => layer.Pose != "happy"),
                "Pointer-down interrupts a tap response and returns control to current activity.");

            animator.BeginDrag(0.3);
            Check(animator.IsDragging, "Beginning an actual drag starts the pick-up overlay.");
            PetRenderFrame pickedUp = animator.Update(work, 0.31);
            Check(pickedUp.Pose == "picked-up" && !pickedUp.Fallback && pickedUp.NextWakeAt.HasValue,
                "The first pick-up frame covers ordinary work and has an absolute next-frame deadline.");
            PetRenderFrame secondFrame = animator.Update(work, 0.47);
            Check(secondFrame.Pose == "picked-up-2", "The pick-up pose advances after 160 milliseconds.");

            PetViewState error = State("error", null, null, "interaction", "claude", 701);
            PetRenderFrame heldError = animator.Update(error, 0.5);
            Check(heldError.Pose == "picked-up" || heldError.Pose == "picked-up-2",
                "A drag overlays a new real error state without mutating or losing it.");
            animator.EndDrag(0.6);
            PetRenderFrame released = animator.Update(error, 0.61);
            Check(!animator.IsDragging && released.Pose == "oops",
                "Release reveals the latest error state instead of a pre-drag snapshot.");

            PetAnimator reduced = NewAnimator(FullCatalog);
            reduced.Update(work, 0);
            reduced.BeginDrag(0.1);
            PetRenderFrame pinnedFrame = reduced.Update(work, 10, true, true);
            Check(pinnedFrame.Pose == "picked-up" && (!pinnedFrame.NextWakeAt.HasValue || pinnedFrame.NextWakeAt.Value > 10.1),
                "Reduced motion pins the first pick-up frame without a 160 millisecond flap wake.");
        }

        private static void CheckRoleSessionCancellationAndMonotonicWake()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetViewState work = State("working", null, null, "session-a", "claude", 800);
            animator.Update(work, 0);
            animator.BeginDrag(0.1);
            PetViewState nextRole = State("working", null, null, "session-a", "deepseek", 801, true, 1);
            PetRenderFrame roleChange = animator.Update(nextRole, 0.2);
            Check(!animator.IsDragging && roleChange.CharacterId == "deepseek" && roleChange.Pose == "thinking",
                "Changing characters cancels character-specific pick-up frames and resolves the new role.");

            animator.BeginDrag(0.3);
            PetViewState nextSession = State("working", null, null, "session-b", "deepseek", 802, true, 1);
            PetRenderFrame sessionChange = animator.Update(nextSession, 0.4);
            Check(!animator.IsDragging && sessionChange.Pose == "thinking",
                "Changing sessions cancels interaction history and starts a fresh work display segment.");

            PetRenderFrame monotonic = animator.Update(nextSession, 0.1);
            Check(monotonic.Pose == "thinking" && monotonic.NextWakeAt.HasValue && monotonic.NextWakeAt.Value >= 0.4,
                "A stale wake time cannot rewind the monotonic animation clock or revive an old interaction.");
        }

        private static void CheckSemanticToolOutranksAmbientMood()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            animator.Update(State("working", null, null, "semantic", "claude", 1000), 0);
            PetRenderFrame tired = animator.Update(State("working", null, null, "semantic", "claude", 1000), 600.001);
            Check(tired.Pose == "tired", "Continuous work still reaches the fatigue mood while only thinking.");
            PetRenderFrame reading = animator.Update(State("tool", "read_file", null, "semantic", "claude", 1001), 601);
            Check(reading.Pose == "reading", "A semantic read action is not covered by the fatigue mood.");

            PetAnimator dense = NewAnimator(FullCatalog);
            PetRenderFrame denseFrame = null;
            for (int i = 0; i < 5; i++)
                denseFrame = dense.Update(State("tool", "mcp_probe", null, "dense", "claude", 2000 + i), i);
            Check(denseFrame != null && denseFrame.Pose == "swamped_left", "Dense generic tools still produce the swamped mood.");
            PetRenderFrame readAfterDense = dense.Update(State("tool", "read_file", null, "dense", "claude", 2010), 6);
            Check(readAfterDense.Pose == "reading", "A semantic read is not covered by the dense-tool swamped mood.");
        }

        private static void CheckSwampedWorkRhythm()
        {
            PetAnimator animator = NewAnimator(FullCatalog);
            PetViewState unbound = State("working", null, null, "swamped-concurrency", "claude", 3000,
                true, 0, "latest", 2);
            Check(animator.Update(unbound, 0).Pose == "swamped_left",
                "Two unbound working sessions replace ordinary thinking with the swamped rhythm.");
            Check(animator.Update(unbound, 6).Pose == "swamped_right",
                "The swamped rhythm alternates calmly between its two existing poses.");

            PetAnimator pinned = NewAnimator(FullCatalog);
            PetViewState bound = State("working", null, null, "swamped-concurrency", "claude", 3000,
                true, 0, "pinned", 2);
            Check(pinned.Update(bound, 0).Pose == "thinking",
                "A bound pet ignores other sessions' concurrency.");

            PetAnimator single = NewAnimator(FullCatalog);
            PetViewState oneWorker = State("working", null, null, "one-worker", "claude", 3000,
                true, 0, "latest", 1);
            Check(single.Update(oneWorker, 0).Pose == "thinking", "One working session keeps ordinary thinking.");
        }

        private static void CheckSpotlightAndCompletionNotice()
        {
            PetAnimator drawingAnimator = NewAnimator(FullCatalog);
            PetViewState drawing = State("working", null, null, "drawing", "claude", 4000,
                true, 0, "latest", 0, null, new PetSpotlight("drawing", 4000));
            Check(drawingAnimator.Update(drawing, 0, false, true, true, 4000).Pose == "drawing",
                "A fresh drawing marker holds the drawing pose.");
            PetRenderFrame settledDrawing = drawingAnimator.Update(drawing, 0.3, false, true, true, 4000);
            Check(settledDrawing.NextWakeAt.HasValue && Math.Abs(settledDrawing.NextWakeAt.Value - 4) < 0.0001,
                "The drawing hold exposes its four-second deadline.");
            PetRenderFrame afterDrawing = drawingAnimator.Update(
                State("working", null, null, "drawing", "claude", 4000), 4.001, false, true, true, 8001);
            Check(afterDrawing.Pose == "thinking", "After four seconds the real work rhythm returns.");

            PetAnimator noticeAnimator = NewAnimator(FullCatalog);
            noticeAnimator.Update(State("idle", null, null, "notice", "claude", 5000), 0, false, true, true, 5000);
            PetNotice[] notices = new[] {
                new PetNotice("completion:11111111:5000", "completion", "s1", "完成", 5000)
            };
            PetViewState completed = State("idle", null, null, "notice", "claude", 5000,
                true, 0, "latest", 0, notices);
            PetRenderFrame celebration = noticeAnimator.Update(completed, 0, false, true, true, 5000);
            Check(celebration.Pose == "happy" && celebration.Notice != null &&
                celebration.Notice.Kind == "completion",
                "A completion notice celebrates with the happy pose and its two-line bubble.");
            Check(celebration.Bubble != null && celebration.Bubble.Style == PetBubbleStyle.Notice &&
                celebration.Bubble.Title == "完成" && celebration.Bubble.Status == "本轮完成了！",
                "Without a subtitle table the renderer still exposes the notice bubble itself.");
            PetRenderFrame settledCelebration = noticeAnimator.Update(completed, 0.3, false, true, true, 5000);
            Check(settledCelebration.NextWakeAt.HasValue &&
                Math.Abs(settledCelebration.NextWakeAt.Value - 6) < 0.0001,
                "The completion celebration lasts six seconds.");
            PetRenderFrame afterCelebration = noticeAnimator.Update(completed, 6.001, false, true, true, 5001);
            Check(afterCelebration.Pose == "idle" && afterCelebration.Notice == null,
                "After six seconds the latest real state returns.");

            // Hiding bubbles keeps the pose but must never surface an old bubble later.
            PetAnimator hiddenAnimator = NewAnimator(FullCatalog);
            hiddenAnimator.Update(State("idle", null, null, "notice-hidden", "claude", 6000), 0, false, true, false, 6000);
            PetNotice[] hiddenNotices = new[] {
                new PetNotice("completion:99999999:6000", "completion", "s1", "隐藏", 6000)
            };
            PetViewState hiddenState = State("idle", null, null, "notice-hidden", "claude", 6000,
                true, 0, "latest", 0, hiddenNotices);
            PetRenderFrame hiddenFrame = hiddenAnimator.Update(hiddenState, 1, false, true, false, 6000);
            Check(hiddenFrame.Pose == "happy" && hiddenFrame.Notice != null &&
                !hiddenFrame.Notice.BubbleVisible,
                "With bubbles off the completion still animates but exposes no bubble.");
            Check(hiddenFrame.Bubble == null,
                "With bubbles off no bubble content reaches the window at all.");
            PetRenderFrame reopenedFrame = hiddenAnimator.Update(hiddenState, 2, false, true, true, 6001);
            Check(reopenedFrame.Notice != null && !reopenedFrame.Notice.BubbleVisible,
                "Re-enabling inside the pose window does not pop the old completion bubble back.");
        }

        private static void CheckNoticeCenterAndBubbleLayout()
        {
            PetNoticeCenter center = new PetNoticeCenter();
            PetNotice replayNotice = new PetNotice("completion:11111111:1000", "completion", null, "完成", 1000);
            PetNoticeTick replay = center.Update(new[] { replayNotice }, true, false, 0, 1000);
            Check(replay.Presentation == null, "A completion present at startup is not replayed.");

            PetNotice fresh = new PetNotice("completion:11111111:2000", "completion", null, "完成", 2000);
            PetNoticeTick shown = center.Update(new[] { fresh }, true, false, 10, 2000);
            Check(shown.Presentation != null && shown.Presentation.Kind == "completion" &&
                shown.Presentation.Status == "本轮完成了！" && shown.Presentation.EndsAt == 16,
                "A fresh completion becomes a six-second two-line celebration.");

            PetNotice confirmation = new PetNotice("confirmation:22222222:2100", "confirmation", null, "确认", 2100);
            PetNoticeTick preempt = center.Update(new[] { fresh, confirmation }, true, false, 12, 2100);
            Check(preempt.Presentation != null && preempt.Presentation.Kind == "confirmation" &&
                preempt.Presentation.Status == "需要你确认",
                "A confirmation preempts a completion.");
            PetNoticeTick stable = center.Update(new[] { fresh, confirmation }, true, false, 13, 2100);
            Check(stable.Presentation != null && stable.Presentation.Id == preempt.Presentation.Id && !stable.Changed,
                "The same confirmation is not re-announced.");
            Check(center.Update(new PetNotice[0], true, false, 14, 2200).Presentation == null,
                "Resolving the confirmation clears the bubble.");

            PetNoticeCenter timeoutCenter = new PetNoticeCenter();
            PetNotice longConfirmation = new PetNotice("confirmation:33333333:3000", "confirmation", null, "长确认", 3000);
            timeoutCenter.Update(new[] { longConfirmation }, true, false, 0, 3000);
            Check(timeoutCenter.Update(new[] { longConfirmation }, true, false, 300.001, 3300).Presentation == null,
                "A confirmation bubble has a safety timeout.");

            PetNoticeCenter blockedCenter = new PetNoticeCenter();
            blockedCenter.Update(new PetNotice[0], true, false, 0, 0);
            PetNotice blockedNotice = new PetNotice("completion:44444444:4000", "completion", null, "等待", 4000);
            Check(blockedCenter.Update(new[] { blockedNotice }, true, true, 1, 4000).Presentation == null,
                "A completion waits behind an error, confirmation, drawing hold or drag.");
            Check(blockedCenter.Update(new[] { blockedNotice }, true, false, 2, 4001).Presentation != null,
                "The queued completion shows once the higher state clears.");
            Check(blockedCenter.Update(new[] { blockedNotice }, true, false, 8.001, 4002).Presentation == null,
                "It ends at its own six-second deadline.");

            // The reviewer's recovery timeline: error display holds for four seconds, then
            // the completion runs a full six seconds of its own.
            PetNoticeCenter recoveryCenter = new PetNoticeCenter();
            recoveryCenter.Update(new PetNotice[0], true, false, 0, 0);
            PetNotice recoveryNotice = new PetNotice("completion:99999999:16000", "completion", "R", "R", 16000);
            Check(recoveryCenter.Update(new[] { recoveryNotice }, true, true, 1, 16000).Presentation == null,
                "The completion waits behind the four-second error display.");
            PetNoticeTick afterErrorHold = recoveryCenter.Update(new[] { recoveryNotice }, true, false, 4.001, 16001);
            Check(afterErrorHold.Presentation != null &&
                Math.Abs(afterErrorHold.Presentation.EndsAt - 10.001) < 0.0001,
                "After the error hold it runs its own full six seconds.");

            PetNoticeCenter toggleCenter = new PetNoticeCenter();
            PetNotice pendingConfirmation = new PetNotice("confirmation:66666666:6000", "confirmation", null, "开关", 6000);
            Check(toggleCenter.Update(new[] { pendingConfirmation }, false, false, 1, 6000).Presentation == null,
                "Bubbles off shows no confirmation bubble.");
            Check(toggleCenter.Update(new[] { pendingConfirmation }, true, false, 2, 6001).Presentation != null,
                "Re-enabling shows a still-pending confirmation.");

            // A completion queued but never shown before bubbles are turned off must not
            // start after re-enabling.
            PetNoticeCenter queuedCenter = new PetNoticeCenter();
            queuedCenter.Update(new PetNotice[0], true, false, 0, 0, "latest");
            PetNotice queuedCompletion = new PetNotice("completion:eeeeeeee:13000", "completion", "E", "E", 13000);
            Check(queuedCenter.Update(new[] { queuedCompletion }, true, true, 1, 13000, "latest").Presentation == null,
                "The completion waits while blocked.");
            Check(queuedCenter.Update(new[] { queuedCompletion }, false, true, 2, 13001, "latest").Presentation == null,
                "Turning bubbles off while it is still queued shows nothing.");
            Check(queuedCenter.Update(new[] { queuedCompletion }, true, false, 3, 13002, "latest").Presentation == null,
                "Re-enabling does not start the old queued completion (pose or bubble).");

            // The reviewer's exact timeline: off + blocked, completion arrives, re-enable
            // while still blocked, then the block clears. Pose yes, bubble no.
            PetNoticeCenter offBlockedCenter = new PetNoticeCenter();
            offBlockedCenter.Update(new PetNotice[0], false, true, 0, 0, "latest");
            PetNotice offBlocked = new PetNotice("completion:dddddddd:15000", "completion", "D", "D", 15000);
            offBlockedCenter.Update(new[] { offBlocked }, false, true, 1, 15000, "latest");
            offBlockedCenter.Update(new[] { offBlocked }, true, true, 2, 15001, "latest");
            PetNoticeTick offBlockedCleared = offBlockedCenter.Update(new[] { offBlocked }, true, false, 3, 15002, "latest");
            Check(offBlockedCleared.Presentation != null &&
                offBlockedCleared.Presentation.Kind == "completion" &&
                !offBlockedCleared.Presentation.BubbleVisible,
                "A completion arriving off+blocked never pops a bubble when the block clears.");

            // Binding changes the allowed scope: the old B is dropped, the new A remains.
            PetNoticeCenter scopeCenter = new PetNoticeCenter();
            scopeCenter.Update(new PetNotice[0], true, false, 0, 0, "latest");
            PetNotice scopeB = new PetNotice("completion:bbbbbbbb:9000", "completion", "B", "B", 9000);
            Check(scopeCenter.Update(new[] { scopeB }, true, true, 1, 9000, "latest").Presentation == null,
                "B is queued while a higher-priority state owns the artwork.");
            PetNotice scopeA = new PetNotice("completion:aaaaaaaa:9100", "completion", "A", "A", 9100);
            PetNoticeTick boundA = scopeCenter.Update(new[] { scopeA }, true, false, 2, 9100, "pinned");
            Check(boundA.Presentation != null && boundA.Presentation.Title == "A",
                "After binding A only A may be shown.");
            Check(scopeCenter.Update(new PetNotice[0], true, false, 9, 9200, "pinned").Presentation == null,
                "The stale queued B is dropped instead of leaking into the new scope.");

            PetNoticeCenter playingCenter = new PetNoticeCenter();
            playingCenter.Update(new PetNotice[0], true, false, 0, 0, "latest");
            PetNotice playingB = new PetNotice("completion:bbbbbbbb:10000", "completion", "B", "B", 10000);
            Check(playingCenter.Update(new[] { playingB }, true, false, 1, 10000, "latest").Presentation != null,
                "B is playing before the binding change.");
            Check(playingCenter.Update(new PetNotice[0], true, false, 2, 10001, "pinned").Presentation == null,
                "Binding A removes B from the allowed scope at once.");
            Check(playingCenter.Update(new[] { playingB }, true, false, 3, 10002, "pinned").Presentation == null,
                "B never returns after the scope changed.");

            // An active completion is not cut short when the console's TTL drops it from the wire.
            PetNoticeCenter lateCenter = new PetNoticeCenter();
            lateCenter.Update(new PetNotice[0], true, false, 0, 0, "latest");
            PetNotice lateNotice = new PetNotice("completion:dddddddd:12000", "completion", "D", "D", 12000);
            Check(lateCenter.Update(new[] { lateNotice }, true, true, 1, 12000, "latest").Presentation == null,
                "The late completion waits behind a higher-priority state.");
            PetNoticeTick lateStart = lateCenter.Update(new[] { lateNotice }, true, false, 2, 20000, "latest");
            Check(lateStart.Presentation != null && lateStart.Presentation.EndsAt == 8,
                "It receives its own full six-second deadline.");
            Check(lateCenter.Update(new PetNotice[0], true, false, 7.999, 20001, "latest").Presentation != null,
                "An active completion is not cut short by the console TTL.");
            Check(lateCenter.Update(new PetNotice[0], true, false, 8.001, 20002, "latest").Presentation == null,
                "It ends at its own six-second deadline.");

            Check(PetBubbleLayout.Width(0) == PetBubbleLayout.MinWidth &&
                PetBubbleLayout.Width(100) == 152 && PetBubbleLayout.Width(500) == PetBubbleLayout.MaxWidth,
                "The bubble width adapts, clamps at both ends and never shrinks the font.");
            Check(PetBubbleLayout.SubtitleHeight(true) == 64 && PetBubbleLayout.SubtitleHeight(false) == 82 &&
                PetBubbleLayout.NoticeHeight() == 78,
                "All tiers include the halo margin and the ellipse tail.");
            Check(PetBubbleLayout.SubtitleHeight(true) == PetBubbleLayout.GlowInset +
                PetBubbleLayout.BodyHeight(new[] { PetBubbleLayout.TextStyle.Subtitle }) + PetBubbleLayout.TailSpan,
                "The window height is halo + body + tail, with no hidden slack.");
            Check(PetBubbleLayout.BorderWidth == 1.0 && PetBubbleLayout.TailBorderWidth == 1.0 &&
                PetBubbleLayout.TailStrokeInset == 0.5,
                "The border is a 1 pt hairline on the body and on the tail.");
            Check(PetBubbleLayout.AccentGlows.Length == 3 && PetBubbleLayout.GlowInset == 8.0,
                "Three accent halo passes are declared inside an 8 pt margin.");
            Check(PetBubbleLayout.GapAbovePet == 2.0 && PetBubbleLayout.TailTipSlack == 0.0,
                "The tail leaves the reviewed 2 pt gap to the head and no rounding slack under it.");
            // Windows screen coordinates grow downwards, so y = 100 is the pet's TOP edge and
            // y = 300 is its bottom. The bubble must hang from the top, never from the feet.
            PetBubblePoint centered = PetBubbleLayout.Origin(
                new PetBubbleRect(100, 100, 176, 200), 140, PetBubbleLayout.NoticeHeight(),
                new PetBubbleRect(0, 0, 1440, 900), 0);
            Check(centered.X == 118, "The bubble sits above and centered on the pet.");
            Check(Math.Abs(centered.Y + PetBubbleLayout.NoticeHeight() + PetBubbleLayout.GapAbovePet
                - PetBubbleLayout.TailTipSlack - 100.0) < 1e-9,
                "The tail tip lands GapAbovePet above the character's top edge.");
            Check(centered.Y + PetBubbleLayout.NoticeHeight() <= 100.0,
                "The whole bubble window stays above the pet's top edge, not below its feet.");
            PetBubblePoint inset = PetBubbleLayout.Origin(
                new PetBubbleRect(100, 100, 176, 200), 140, PetBubbleLayout.NoticeHeight(),
                new PetBubbleRect(0, 0, 1440, 900), 24);
            Check(Math.Abs((centered.Y - inset.Y) + 24.0) < 1e-9,
                "Transparent room above the artwork pushes the bubble up by the same amount.");
            PetBubblePoint clamped = PetBubbleLayout.Origin(
                new PetBubbleRect(1300, 100, 176, 200), 140, PetBubbleLayout.NoticeHeight(),
                new PetBubbleRect(0, 0, 1440, 900), 0);
            Check(clamped.X == 1294, "The bubble is clamped inside the screen edge.");
            // No halo may paint below the body: that area belongs to the character.
            double glowHeight = PetBubbleLayout.SubtitleHeight(true);
            PetBubbleRect glowBody = PetBubbleLayout.BodyRect(140, glowHeight);
            PetBubbleRect glowClip = PetBubbleLayout.BodyGlowClip(140, glowHeight);
            Check(Math.Abs(glowClip.Height - (glowBody.Y + glowBody.Height)) < 1e-9,
                "The body halo is clipped exactly at the body's bottom edge.");
            foreach (PetBubbleGlow pass in PetBubbleLayout.AccentGlows)
            {
                PetBubbleRect halo = PetBubbleLayout.GlowRect(pass, 140, glowHeight);
                Check(halo.Y >= 0 && halo.Y + halo.Height <= glowBody.Y + glowBody.Height + 1e-9,
                    "A halo pass never reaches below the body.");
                Check(halo.X >= 0 && halo.X + halo.Width <= 140 + 1e-9,
                    "A halo pass stays inside the side margins.");
            }

            // Turning bubbles off must never let an old completion bubble pop back.
            PetNoticeCenter hiddenCenter = new PetNoticeCenter();
            hiddenCenter.Update(new PetNotice[0], false, false, 0, 0);
            PetNotice hiddenCompletion = new PetNotice("completion:77777777:7000", "completion", null, "关", 7000);
            PetNoticeTick poseOnly = hiddenCenter.Update(new[] { hiddenCompletion }, false, false, 1, 7000);
            Check(poseOnly.Presentation != null && poseOnly.Presentation.Kind == "completion" &&
                !poseOnly.Presentation.BubbleVisible,
                "A completion arriving with bubbles off still drives the pose but no bubble.");
            PetNoticeTick reopened = hiddenCenter.Update(new[] { hiddenCompletion }, true, false, 2, 7001);
            Check(reopened.Presentation != null && reopened.Presentation.Id == poseOnly.Presentation.Id &&
                !reopened.Presentation.BubbleVisible,
                "Re-enabling inside the six-second pose window does not pop the old bubble back.");
            PetNoticeTick afterWindow = hiddenCenter.Update(new[] { hiddenCompletion }, true, false, 8, 7002);
            Check(afterWindow.Presentation == null, "The same completion never replays after its window ends.");

            // A visible completion hidden one second in, re-enabled one second later.
            PetNoticeCenter midPlayCenter = new PetNoticeCenter();
            midPlayCenter.Update(new PetNotice[0], true, false, 0, 0);
            PetNotice midPlay = new PetNotice("completion:88888888:8000", "completion", null, "中途关闭", 8000);
            PetNoticeTick playing = midPlayCenter.Update(new[] { midPlay }, true, false, 1, 8000);
            Check(playing.Presentation != null && playing.Presentation.BubbleVisible,
                "A visible completion starts with its bubble.");
            PetNoticeTick hiddenMidPlay = midPlayCenter.Update(new[] { midPlay }, false, false, 2, 8001);
            Check(hiddenMidPlay.Presentation != null && !hiddenMidPlay.Presentation.BubbleVisible,
                "Turning bubbles off one second in keeps the pose but hides the bubble.");
            PetNoticeTick reopenedMidPlay = midPlayCenter.Update(new[] { midPlay }, true, false, 3, 8002);
            Check(reopenedMidPlay.Presentation != null &&
                reopenedMidPlay.Presentation.Id == playing.Presentation.Id &&
                !reopenedMidPlay.Presentation.BubbleVisible,
                "Re-enabling one second later must not replay the already-shown completion.");
            Check(reopenedMidPlay.Presentation.EndsAt == playing.Presentation.EndsAt,
                "The original six-second pose deadline is preserved, not restarted.");

        }

        private static PetAnimator NewAnimator(ISet<string> poses)
        {
            return new PetAnimator(delegate(string characterId) { return new HashSet<string>(poses, StringComparer.Ordinal); });
        }

        private static PetViewState State(string status, string tool, string hint, string sessionId,
            string characterId, long lastActivityAt, bool connected = true, long selectionRevision = 0,
            string followMode = "latest", int concurrentSessions = 0,
            IReadOnlyList<PetNotice> notifications = null, PetSpotlight spotlight = null)
        {
            PetActivity activity = new PetActivity(sessionId, "Synthetic session", "synthetic-agent", "Synthetic Agent",
                status, tool, lastActivityAt, hint, spotlight);
            PetSelection selection = new PetSelection(characterId, selectionRevision, 0);
            return new PetViewState(PetRole.BuiltIns, activity, selection, connected,
                followMode, concurrentSessions, notifications);
        }

        private static ISet<string> MakeSet(params string[] names)
        {
            return new HashSet<string>(names, StringComparer.Ordinal);
        }

        private static void AssertLayersBelongTo(PetRenderFrame frame, ISet<string> poses)
        {
            Check(poses.Contains(frame.Pose), "The reported pose belongs to the selected character's catalog.");
            Check(frame.Layers.Any(layer => layer.Pose == frame.Pose), "The reported target is represented in the visible layer set.");
            foreach (PetPoseLayer layer in frame.Layers)
                Check(poses.Contains(layer.Pose), "Every visible animation layer belongs to the selected character's catalog.");
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("Animation check failed: " + message);
        }
    }
}
