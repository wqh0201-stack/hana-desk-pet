using System;
using System.Collections.Generic;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Core.Tests
{
    /// <summary>
    /// Deterministic checks for the double-click basin pile: the drop/settle/fade model, the
    /// shared window reserve, the double-click tracker and the animator wiring. Every call
    /// uses a caller-supplied monotonic clock; nothing here touches a window.
    /// </summary>
    public static class BasinChecks
    {
        public static void Run()
        {
            CheckDropAndSettle();
            CheckStackGeometry();
            CheckOverflow();
            CheckReducedMotion();
            CheckDeadlines();
            CheckReserve();
            CheckBasinConfig();
            CheckDoubleClicks();
            CheckAnimatorIntegration();
        }

        private static void CheckDropAndSettle()
        {
            PetBasinStack stack = new PetBasinStack();
            stack.Add(100.0);

            IList<PetBasinPlacement> first = stack.Placements(100.0, false);
            Check(first.Count == 1, "one click draws exactly one basin");
            Check(Math.Abs(first[0].Rise - PetBasinStack.BaseDropHeight) < 1e-9, "the basin starts one drop height above its slot");
            Check(first[0].Opacity < 0.05, "the basin fades in instead of popping");

            IList<PetBasinPlacement> halfway = stack.Placements(100.0 + PetBasinStack.DropDuration * 0.5, false);
            Check(halfway[0].Rise > 0.0 && halfway[0].Rise < PetBasinStack.BaseDropHeight, "the basin is still above its slot halfway down");
            Check(halfway[0].Opacity > 0.9, "the basin is fully visible while falling");

            IList<PetBasinPlacement> landed = stack.Placements(100.0 + PetBasinStack.DropDuration, false);
            Check(Math.Abs(landed[0].Rise) < 1e-9, "the basin lands exactly on its slot");
            Check(Math.Abs(landed[0].Opacity - 1.0) < 1e-9, "the landed basin is fully opaque");

            for (int step = 0; step <= 40; step++)
            {
                double time = 100.0 + PetBasinStack.DropDuration * step / 40.0;
                IList<PetBasinPlacement> list = stack.Placements(time, false);
                Check(list[0].Rise >= -1e-9, "the drop never goes below the slot");
            }
        }

        private static void CheckStackGeometry()
        {
            PetBasinStack stack = new PetBasinStack();
            for (int index = 0; index < 3; index++) stack.Add(index);
            IList<PetBasinPlacement> settled = stack.Placements(10.0, false);
            Check(stack.Count == 3, "three clicks stack three basins");
            for (int index = 0; index < settled.Count; index++)
            {
                Check(settled[index].Slot == index, "placements are listed bottom-up for draw order");
                Check(Math.Abs(settled[index].Rise - index * PetBasinStack.BaseSpacing) < 1e-9,
                    "slot " + index + " sits " + index + " spacings above the head");
                Check(Math.Abs(settled[index].Opacity - 1.0) < 1e-9, "a settled basin is opaque");
            }
        }

        private static void CheckOverflow()
        {
            PetBasinStack stack = new PetBasinStack();
            for (int index = 0; index < PetBasinStack.MaxCount; index++) stack.Add(index);
            Check(stack.Count == PetBasinStack.MaxCount, "the pile caps at the maximum count");

            stack.Add(20.0);
            Check(stack.Count == PetBasinStack.MaxCount, "an extra click keeps the pile at the cap");
            IList<PetBasinPlacement> overflowing = stack.Placements(20.0, false);
            Check(overflowing.Count == PetBasinStack.MaxCount + 1, "the removed bottom basin is still drawn while it fades");
            Check(Math.Abs(overflowing[0].Opacity - 1.0) < 1e-9, "the fading basin starts fully opaque");
            Check(Math.Abs(overflowing[1].Rise - PetBasinStack.BaseSpacing) < 1e-9,
                "the remaining pile starts one spacing high and settles down");

            IList<PetBasinPlacement> halfway = stack.Placements(20.0 + PetBasinStack.FadeOutDuration * 0.5, false);
            Check(halfway[0].Opacity > 0.0 && halfway[0].Opacity < 1.0, "the bottom basin fades out over time");

            IList<PetBasinPlacement> after = stack.Placements(
                20.0 + PetBasinStack.FadeOutDuration + PetBasinStack.SettleDuration, false);
            Check(after.Count == PetBasinStack.MaxCount, "the faded basin is dropped from the draw list");
            for (int index = 0; index < after.Count; index++)
                Check(Math.Abs(after[index].Rise - index * PetBasinStack.BaseSpacing) < 1e-9,
                    "slot " + index + " rests on the head again after the pile settles");

            stack.Clear();
            Check(stack.Count == 0, "clearing empties the pile");
            Check(stack.Placements(100.0, false).Count == 0, "a cleared pile draws nothing");
            Check(!stack.NextDeadline(100.0, false).HasValue, "a cleared pile schedules no wake");
        }

        private static void CheckReducedMotion()
        {
            PetBasinStack stack = new PetBasinStack();
            stack.Add(5.0);
            IList<PetBasinPlacement> immediate = stack.Placements(5.0, true);
            Check(immediate.Count == 1, "reduced motion still draws the basin");
            Check(Math.Abs(immediate[0].Rise) < 1e-9, "reduced motion skips the drop");
            Check(Math.Abs(immediate[0].Opacity - 1.0) < 1e-9, "reduced motion skips the fade-in");
            Check(!stack.NextDeadline(5.0, true).HasValue, "reduced motion schedules no animation frame");
        }

        private static void CheckDeadlines()
        {
            PetBasinStack stack = new PetBasinStack();
            stack.Add(1.0);
            double? first = stack.NextDeadline(1.0, false);
            Check(first.HasValue && first.Value > 1.0 && first.Value <= 1.0 + PetBasinStack.FrameInterval + 1e-9,
                "the drop wakes on the next animation frame");
            Check(!stack.NextDeadline(1.0 + PetBasinStack.DropDuration + PetBasinStack.SettleDuration + 1.0, false).HasValue,
                "a settled pile stops asking for frames");
        }

        private static void CheckReserve()
        {
            PetBasinConfig config = PetBasinConfig.Fallback;
            double required = PetBasinStack.RequiredTopPadding(config);
            double tallest = PetBasinStack.PileTopRise(PetBasinStack.MaxCount, config);
            Check(required > 0.0, "the window reserves room for a full pile");
            Check(tallest > 0.0, "a full pile reaches above the artwork");
            Check(required > tallest, "the reserve also leaves the bubble gap above a full pile");
            Check(Math.Abs(PetBasinStack.PileTopRise(0, config)) < 1e-9, "an empty pile does not move the bubble");
            Check(PetBasinStack.PileTopRise(1, config) > 0.0, "even one basin sticks up above the hair");
            Check(PetBasinStack.PileTopRise(1, config) < PetBasinStack.PileTopRise(2, config), "each extra basin raises the pile");
            Check(Math.Abs(PetBasinStack.TopReserve(required, config)) < 1e-9, "a layout that already reserves enough adds nothing");
            Check(Math.Abs(PetBasinStack.TopReserve(0.0, config) - required) < 1e-9, "a layout without top padding reserves the whole pile");
            Check(Math.Abs(PetBasinStack.TopReserve(25.0, config) - (required - 25.0)) < 1e-9, "the reserve is only the shortfall");
        }

        private static void CheckBasinConfig()
        {
            PetBasinConfig narrow = new PetBasinConfig(60.0, 0.0, 30.0);
            PetBasinConfig wide = new PetBasinConfig(120.0, 0.0, 30.0);
            Check(Math.Abs(PetBasinStack.Width(narrow) - 60.0) < 1e-9, "the configured width is used as is");
            Check(Math.Abs(PetBasinStack.Height(narrow) - 60.0 / PetBasinStack.AssetRatio) < 1e-9,
                "the height follows the fixed 117:47 asset ratio");
            Check(Math.Abs(PetBasinStack.Height(wide) - 120.0 / PetBasinStack.AssetRatio) < 1e-9,
                "the height is derived from the width, never stretched");
            Check(Math.Abs(PetBasinStack.Width(new PetBasinConfig(500.0, 0.0, 30.0)) - PetBasinStack.WidthMaximum) < 1e-9,
                "an oversized width clamps to the slider maximum");
            Check(Math.Abs(PetBasinStack.Width(new PetBasinConfig(10.0, 0.0, 30.0)) - PetBasinStack.WidthMinimum) < 1e-9,
                "an undersized width clamps to the slider minimum");

            PetBasinConfig shifted = new PetBasinConfig(92.0, 18.0, 30.0);
            Check(Math.Abs(shifted.Clamped().XOffset - 18.0) < 1e-9, "the horizontal offset survives clamping inside the range");
            Check(Math.Abs(new PetBasinConfig(92.0, 99.0, 30.0).Clamped().XOffset - PetBasinStack.XOffsetMaximum) < 1e-9,
                "the horizontal offset clamps to its range");
            Check(Math.Abs(new PetBasinConfig(92.0, 0.0, 200.0).Clamped().YOffset - PetBasinStack.YOffsetMaximum) < 1e-9,
                "the vertical offset clamps to its range");

            double shallow = PetBasinStack.PileTopRise(PetBasinStack.MaxCount, new PetBasinConfig(92.0, 0.0, 10.0));
            double deep = PetBasinStack.PileTopRise(PetBasinStack.MaxCount, new PetBasinConfig(92.0, 0.0, 60.0));
            Check(shallow > deep, "a deeper rim leaves less pile above the artwork");
            Check(PetBasinStack.RequiredTopPadding(PetBasinStack.ReserveConfig) > PetBasinStack.RequiredTopPadding(PetBasinConfig.Fallback),
                "the reserve config is the worst case of the slider ranges");

            string[] roles = new string[]
            {
                "claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"
            };
            for (int index = 0; index < roles.Length; index++)
                Check(PetBasinStack.ConfigFor(roles[index]) != null, roles[index] + " has a built-in basin config");
            Check(PetBasinStack.ConfigFor("unknown-role").Equals(PetBasinConfig.Fallback),
                "an unknown role uses the fallback config");
        }

        private static void CheckDoubleClicks()
        {
            PetDoubleClickTracker tracker = new PetDoubleClickTracker();
            Check(!tracker.Register(10.0, 0.5), "the first click is a single click");
            Check(tracker.Register(10.3, 0.5), "a second click inside the interval is a double click");
            Check(!tracker.Register(10.4, 0.5), "a third click starts a new sequence");

            PetDoubleClickTracker slow = new PetDoubleClickTracker();
            Check(!slow.Register(20.0, 0.5), "the first click is a single click");
            Check(!slow.Register(20.9, 0.5), "a click outside the interval is a new single click");
            Check(slow.Register(21.2, 0.5), "the pair after a missed interval still pairs up");

            PetDoubleClickTracker dragged = new PetDoubleClickTracker();
            Check(!dragged.Register(30.0, 0.5), "the first click is a single click");
            dragged.Reset();
            Check(!dragged.Register(30.2, 0.5), "a drag between clicks breaks the pair");
            Check(dragged.Register(30.4, 0.5), "the clicks after the drag pair with each other");
        }

        private static void CheckAnimatorIntegration()
        {
            HashSet<string> poses = new HashSet<string>(StringComparer.Ordinal)
            { "idle", "happy", "thinking", "busy_left", "busy_right", "picked-up", "picked-up-2" };
            PetAnimator animator = new PetAnimator(delegate(string characterId) { return poses; });
            PetViewState state = MakeState("working", "read_file", "claude");

            PetRenderFrame initial = animator.Update(state, 0.0);
            Check(initial.Basins.Count == 0, "no basins before a double click");

            animator.AddBasin(1.0);
            PetRenderFrame dropped = animator.Update(state, 1.2);
            Check(dropped.Basins.Count == 1, "a double click adds one basin");
            Check(dropped.Basins[0].Rise > 0.0, "the basin is still falling in the frame that follows the click");
            Check(dropped.NextWakeAt.HasValue, "the falling basin keeps the animation awake");

            PetRenderFrame settled = animator.Update(state, 5.0);
            Check(Math.Abs(settled.Basins[0].Rise) < 1e-9, "the basin has landed");

            // Changing the role drops the pile; the activity state is untouched by any of this.
            PetRenderFrame switched = animator.Update(MakeState("working", "read_file", "gpt"), 6.0);
            Check(switched.Basins.Count == 0, "changing the character clears the pile");

            animator.AddBasin(7.0);
            animator.ClearBasins();
            Check(animator.Update(MakeState("working", "read_file", "gpt"), 7.5).Basins.Count == 0,
                "the pile can be cleared explicitly");
        }

        private static PetViewState MakeState(string status, string tool, string characterId)
        {
            PetActivity activity = new PetActivity("s1", "Synthetic session", "synthetic-agent", "Synthetic Agent",
                status, tool, 1, null, null);
            PetSelection selection = new PetSelection(characterId, 0, 0);
            return new PetViewState(PetRole.BuiltIns, activity, selection, true, "latest", 0, null);
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("Basin check failed: " + message);
        }
    }
}
