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
                .Update(State("error", null, "confirming", "error", "claude", 25), 0);
            Check(error.Pose == "oops" && !error.Fallback, "Error feedback outranks a concurrent hint.");
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
                frame = animator.Update(State("tool", "exec", null, "swamped", "claude", 400 + i), i);
            Check(frame != null && frame.Pose == "swamped_left",
                "Five distinct tool starts within ten seconds produce the first swamped side.");
            PetRenderFrame alternating = animator.Update(State("tool", "exec", null, "swamped", "claude", 405), 5);
            Check(alternating.Pose == "swamped_right", "A further dense tool start alternates the swamped side.");
            PetRenderFrame expired = animator.Update(State("tool", "exec", null, "swamped", "claude", 405), 15.001);
            Check(expired.Pose == "running", "Tool density leaves the ten-second window without a repeating swamped mood.");
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

        private static PetAnimator NewAnimator(ISet<string> poses)
        {
            return new PetAnimator(delegate(string characterId) { return new HashSet<string>(poses, StringComparer.Ordinal); });
        }

        private static PetViewState State(string status, string tool, string hint, string sessionId,
            string characterId, long lastActivityAt, bool connected = true, long selectionRevision = 0)
        {
            PetActivity activity = new PetActivity(sessionId, "Synthetic session", "synthetic-agent", "Synthetic Agent",
                status, tool, lastActivityAt, hint);
            PetSelection selection = new PetSelection(characterId, selectionRevision, 0);
            return new PetViewState(PetRole.BuiltIns, activity, selection, connected);
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
