using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Core.Tests
{
    /// <summary>
    /// Synthetic checks for the status subtitle layer on the Windows side: the bundled
    /// table parses, every pose normalises to a state that has lines, the dwell merge,
    /// persistence, transient retirement, non-repeating choice and the notice / pick-up /
    /// switch priorities all hold, and the accent table matches the macOS one.
    /// NOTE: compiled only on Windows; the macOS run reports the missing csc.exe instead.
    /// </summary>
    internal static class SubtitleChecks
    {
        private static int _checks;

        internal static void Run()
        {
            PetSubtitleCatalog catalog = LoadCatalog();
            CheckCatalogCoversEveryPose(catalog);
            CheckStateTable(catalog);
            CheckDeterministicChoiceAndNoRepeat(catalog);
            CheckMinimumDwellQueuesAndMerges(catalog);
            CheckPersistentAndRetired(catalog);
            CheckTransientStatesRetire(catalog);
            CheckNoticePreempts(catalog);
            CheckPickUpPreempts(catalog);
            CheckDisabledSwitch(catalog);
            CheckRoleIsolation(catalog);
            CheckAccents();
            CheckTiersIncludeTail();
            CheckAnimatorPublishesSubtitle(catalog);
            Console.WriteLine("PASS: " + _checks + " subtitle checks.");
        }

        private static PetSubtitleCatalog LoadCatalog()
        {
            return PetSubtitleCatalog.Parse(File.ReadAllBytes(Path.Combine(AssetRoot(), "pet-lines.json")));
        }

        private static void CheckCatalogCoversEveryPose(PetSubtitleCatalog catalog)
        {
            Dictionary<string, object> root = Deserialize(Path.Combine(AssetRoot(), "catalog.json"));
            object rawCharacters;
            if (!root.TryGetValue("characters", out rawCharacters)) throw new InvalidDataException("catalog has no characters");
            object[] characters = rawCharacters as object[];
            if (characters == null || characters.Length == 0) throw new InvalidDataException("catalog characters invalid");

            HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
            for (int i = 0; i < characters.Length; i++)
            {
                Dictionary<string, object> character = characters[i] as Dictionary<string, object>;
                string roleId = character["id"] as string;
                object[] files = character["poseFiles"] as object[];
                for (int f = 0; f < files.Length; f++)
                {
                    string filename = files[f] as string;
                    string pose = filename.Substring(0, filename.Length - 5);
                    seen.Add(pose);
                    string state = catalog.StateKeyForPose(pose);
                    Check(state != null, pose + " normalises to a state");
                    Check(catalog.HasLines(roleId, state), roleId + "/" + pose + " -> " + state + " has lines");
                }
            }
            Check(seen.Count >= 30, "the catalog's distinct pose names were enumerated");

            string[,] variants = new string[,]
            {
                { "thinking-2", "thinking" }, { "idle-2", "idle" }, { "idle-3", "idle" },
                { "idle-blink", "idle" }, { "busy_left", "busy" }, { "busy_right", "busy" },
                { "swamped_left", "swamped" }, { "swamped_right", "swamped" }, { "sleeping-2", "sleeping" },
                { "happy-2", "happy" }, { "reading-2", "reading" }, { "deepthink", "thinking" },
                { "picked-up-2", "picked-up" }, { "sorry", "oops" }, { "listening", "asking" },
                { "surprised", "interrupted" }
            };
            for (int i = 0; i < variants.GetLength(0); i++)
                Check(catalog.StateKeyForPose(variants[i, 0]) == variants[i, 1],
                    variants[i, 0] + " normalises to " + variants[i, 1]);
            Check(catalog.StateKeyForPose("no-such-pose") == "idle", "an unknown pose falls back to idle");
            Check(catalog.StateKeyForPose("") == "idle", "an empty pose name falls back to idle");
        }

        private static void CheckStateTable(PetSubtitleCatalog catalog)
        {
            string[] order = catalog.StateOrder;
            Check(order.Length == 20, "the reviewed table has 20 states");
            Check(catalog.UnreachableStates.Length == 1 && catalog.UnreachableStates[0] == "pat",
                "only `pat` is unreachable and that is recorded");
            Check(catalog.DwellSeconds("pat") == 4.0, "an unreachable state keeps its reviewed dwell");
            Check(catalog.MinDwellSeconds == 2.5, "the reviewed minimum dwell is 2.5 s");
            Check(new List<string>(catalog.PoseStates.Values).Contains("notice") == false,
                "no artwork pose maps to the notice pseudo-state");
        }

        private static void CheckDeterministicChoiceAndNoRepeat(PetSubtitleCatalog catalog)
        {
            for (ulong seed = 1; seed <= 16; seed++)
            {
                PetSubtitleSelector selector = new PetSubtitleSelector(catalog, seed);
                string previous = null;
                double time = 0;
                for (int round = 0; round < 8; round++)
                {
                    PetSubtitleFrame first = selector.Update("oops", "gpt", null, false, true, time);
                    Check(first.Content != null, "re-entering a state produced a line");
                    string text = first.Content.Status;
                    if (previous != null) Check(previous != text, "seed " + seed + " never repeats the previous line");
                    previous = text;
                    time += 3;
                    selector.Update("idle", "gpt", null, false, true, time);
                    time += 3;
                }
            }
            PetSubtitleSelector left = new PetSubtitleSelector(catalog, 7);
            PetSubtitleSelector right = new PetSubtitleSelector(catalog, 7);
            for (int step = 0; step < 6; step++)
            {
                PetSubtitleFrame a = left.Update("thinking", "claude", null, false, true, step * 4);
                PetSubtitleFrame b = right.Update("thinking", "claude", null, false, true, step * 4);
                Check(a.Content != null && b.Content != null && a.Content.Status == b.Content.Status,
                    "identical seeds and inputs produce identical words");
            }
            HashSet<string> picks = new HashSet<string>(StringComparer.Ordinal);
            for (ulong seed = 1; seed <= 8; seed++)
            {
                PetSubtitleSelector selector = new PetSubtitleSelector(catalog, seed);
                PetSubtitleFrame frame = selector.Update("happy", "glm", null, false, true, 0);
                if (frame.Content != null) picks.Add(frame.Content.Status);
            }
            Check(picks.Count == 2, "both candidate lines of a two-candidate state are reachable");
        }

        private static void CheckMinimumDwellQueuesAndMerges(PetSubtitleCatalog catalog)
        {
            PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 3);
            PetSubtitleFrame first = selector.Update("idle", "claude", null, false, true, 0);
            Check(first.Content != null, "the first subtitle shows at once");
            Check(first.NextDeadline == 6, "a self-retiring state schedules its own deadline");
            PetSubtitleFrame queued = selector.Update("searching", "claude", null, false, true, 1.0);
            Check(queued.Content != null && queued.Content.Status == first.Content.Status,
                "a new state inside the 2.5 s window does not cut the current line");
            Check(!queued.Changed, "the queued line reports no visible change yet");
            Check(queued.NextDeadline == 2.5, "the queued line becomes visible at the dwell boundary");
            selector.Update("writing", "claude", null, false, true, 1.4);
            PetSubtitleFrame merged = selector.Update("running", "claude", null, false, true, 1.8);
            Check(merged.Content.Status == first.Content.Status, "queued arrivals keep merging without showing");
            PetSubtitleFrame flushed = selector.Update("running", "claude", null, false, true, 2.5);
            Check(flushed.Changed, "the flushed line is reported as a visible change");
            Check(Contains(catalog.Lines("claude", "running"), flushed.Content.Status),
                "only the last queued state is shown");
            Check(!Contains(catalog.Lines("claude", "writing"), flushed.Content.Status),
                "the dropped intermediate state never shows");
            Check(flushed.NextDeadline == null, "a persistent state schedules no retire deadline");
        }

        private static void CheckPersistentAndRetired(PetSubtitleCatalog catalog)
        {
            PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 11);
            PetSubtitleFrame shown = selector.Update("thinking", "deepseek", null, false, true, 0);
            Check(shown.Content != null && shown.NextDeadline == null, "a null-dwell state schedules nothing");
            PetSubtitleFrame later = selector.Update("thinking", "deepseek", null, false, true, 600);
            Check(later.Content.Status == shown.Content.Status, "a persistent state stays on screen");
            PetSubtitleFrame variant = selector.Update("thinking-2", "deepseek", null, false, true, 601);
            Check(variant.Content.Status == shown.Content.Status, "thinking-2 keeps the thinking line");

            PetSubtitleSelector retiring = new PetSubtitleSelector(catalog, 5);
            PetSubtitleFrame happy = retiring.Update("happy", "claude", null, false, true, 0);
            Check(happy.NextDeadline == 5, "`happy` retires after five seconds");
            PetSubtitleFrame expired = retiring.Update("happy", "claude", null, false, true, 5.1);
            Check(expired.Content == null && expired.Changed, "a transient state clears at its deadline");
            PetSubtitleFrame staysEmpty = retiring.Update("happy-2", "claude", null, false, true, 9);
            Check(staysEmpty.Content == null, "the same state does not reappear while its pose persists");
            retiring.Update("idle", "claude", null, false, true, 10);
            PetSubtitleFrame returned = retiring.Update("happy", "claude", null, false, true, 12);
            Check(returned.Content != null, "re-entering the state after another state speaks again");
        }

        private static void CheckTransientStatesRetire(PetSubtitleCatalog catalog)
        {
            string[,] transient = new string[,]
            {
                { "happy", "happy" }, { "proud", "proud" }, { "oops", "oops" },
                { "idle", "idle" }, { "drawing", "drawing" }, { "surprised", "interrupted" }
            };
            for (int i = 0; i < transient.GetLength(0); i++)
            {
                double? dwell = catalog.DwellSeconds(transient[i, 1]);
                Check(dwell.HasValue, transient[i, 1] + " should have a reviewed dwell");
                PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 9);
                PetSubtitleFrame start = selector.Update(transient[i, 0], "gemini", null, false, true, 1);
                Check(start.Content != null, transient[i, 1] + " shows at once");
                Check(start.NextDeadline == 1 + dwell.Value, transient[i, 1] + " retires on time");
                Check(selector.Update(transient[i, 0], "gemini", null, false, true, 1 + dwell.Value - 0.01).Content != null,
                    transient[i, 1] + " is still visible just before its deadline");
                Check(selector.Update(transient[i, 0], "gemini", null, false, true, 1 + dwell.Value).Content == null,
                    transient[i, 1] + " clears at its deadline");
            }
            string[] persistent = new string[]
            {
                "thinking", "reading", "writing", "searching", "running", "delegating",
                "busy", "asking", "compact", "tired", "sleeping", "swamped", "picked-up"
            };
            for (int i = 0; i < persistent.Length; i++)
                Check(catalog.DwellSeconds(persistent[i]) == null, persistent[i] + " is a persistent state");
        }

        private static void CheckNoticePreempts(PetSubtitleCatalog catalog)
        {
            PetNoticePresentation confirmation = MakeNotice("confirmation:abcd:1", "confirmation", "合成会话", "需要你确认", 0, 300, true);
            PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 2);
            PetSubtitleFrame subtitle = selector.Update("idle", "claude", null, false, true, 0);
            Check(subtitle.Content != null && subtitle.Content.Style == PetBubbleStyle.Subtitle, "a subtitle is showing first");
            PetSubtitleFrame notice = selector.Update("idle", "claude", confirmation, false, true, 0.2);
            Check(notice.Changed, "the confirmation is an immediate visible change");
            Check(notice.Content.Style == PetBubbleStyle.Notice, "a notice takes the bubble over as a notice");
            Check(notice.Content.Title == "合成会话" && notice.Content.Status == "需要你确认",
                "the two-line notice format is unchanged");
            Check(notice.NextDeadline == 300, "the notice keeps its own 300 s deadline");
            PetSubtitleFrame same = selector.Update("idle", "claude", confirmation, false, true, 1);
            Check(same.Content.Status == notice.Content.Status && !same.Changed, "the same confirmation is not re-announced");

            PetNoticePresentation completion = MakeNotice("completion:abcd:2", "completion", "合成会话", "本轮完成了！", 2, 8, true);
            PetSubtitleFrame completed = selector.Update("idle", "claude", completion, false, true, 2);
            Check(completed.Content.Style == PetBubbleStyle.Notice && completed.Content.Status == "本轮完成了！",
                "a completion also uses the unchanged two-line format");
            Check(completed.NextDeadline == 8, "the completion keeps its own six-second deadline");
            PetSubtitleFrame after = selector.Update("idle", "claude", null, false, true, 8.1);
            Check(after.Content.Style == PetBubbleStyle.Subtitle, "the subtitle returns once the notice ends");

            PetNoticePresentation hidden = MakeNotice("completion:ffff:3", "completion", "隐藏", "本轮完成了！", 0, 6, false);
            PetSubtitleSelector hiddenSelector = new PetSubtitleSelector(catalog, 4);
            hiddenSelector.Update("idle", "claude", null, false, true, 0);
            PetSubtitleFrame hiddenResult = hiddenSelector.Update("idle", "claude", hidden, false, true, 1);
            Check(hiddenResult.Content.Style == PetBubbleStyle.Subtitle,
                "an invisible notice does not replace the subtitle");
        }

        private static void CheckPickUpPreempts(PetSubtitleCatalog catalog)
        {
            PetNoticePresentation confirmation = MakeNotice("confirmation:1234:1", "confirmation", "拎起", "需要你确认", 0, 300, true);
            PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 6);
            selector.Update("idle", "deepseek", confirmation, false, true, 0);
            PetSubtitleFrame picked = selector.Update("picked-up", "deepseek", confirmation, true, true, 0.1);
            Check(picked.Content.Style == PetBubbleStyle.Subtitle, "the pick-up line replaces even a confirmation");
            Check(picked.Changed, "the pick-up line is an immediate change");
            Check(Contains(catalog.Lines("deepseek", "picked-up"), picked.Content.Status),
                "the pick-up line comes from the picked-up group");
            PetSubtitleFrame second = selector.Update("picked-up-2", "deepseek", confirmation, true, true, 0.2);
            Check(second.Content.Status == picked.Content.Status, "switching pick-up frames keeps one line");
            PetSubtitleFrame released = selector.Update("asking", "deepseek", confirmation, false, true, 0.3);
            Check(released.Content.Style == PetBubbleStyle.Notice, "releasing the character restores the confirmation");
            PetSubtitleFrame again = selector.Update("picked-up", "deepseek", confirmation, true, true, 5);
            Check(again.Content.Style == PetBubbleStyle.Subtitle, "picking up again shows the pick-up line");
        }

        private static void CheckDisabledSwitch(PetSubtitleCatalog catalog)
        {
            PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 8);
            Check(selector.Update("thinking", "glm", null, false, true, 0).Content != null, "the subtitle shows while on");
            PetSubtitleFrame off = selector.Update("thinking", "glm", null, false, false, 1);
            Check(off.Content == null && off.Changed, "turning the switch off hides the bubble");
            Check(off.NextDeadline == null, "a hidden bubble schedules no wake");
            Check(selector.Update("happy", "glm", null, false, false, 2).Content == null, "no line appears while off");
            PetSubtitleFrame backOn = selector.Update("happy", "glm", null, false, true, 3);
            Check(backOn.Content != null && backOn.Content.Style == PetBubbleStyle.Subtitle,
                "re-enabling resumes subtitles, not a stale notice replay");
        }

        private static void CheckRoleIsolation(PetSubtitleCatalog catalog)
        {
            string[] roles = catalog.Roles;
            string[] states = catalog.StateOrder;
            for (int r = 0; r < roles.Length; r++)
            {
                for (int s = 0; s < states.Length; s++)
                {
                    string[] lines = catalog.Lines(roles[r], states[s]);
                    Check(lines.Length >= 1 && lines.Length <= 2,
                        roles[r] + "/" + states[s] + " has one or two lines");
                    Check(new HashSet<string>(lines, StringComparer.Ordinal).Count == lines.Length,
                        roles[r] + "/" + states[s] + " has no duplicate candidate");
                    for (int i = 0; i < lines.Length; i++)
                        Check(lines[i].Length <= PetSubtitleCatalog.MaximumLineCharacters,
                            roles[r] + "/" + states[s] + " lines fit the bounded length");
                }
            }
            PetSubtitleSelector selector = new PetSubtitleSelector(catalog, 1);
            PetSubtitleFrame claude = selector.Update("idle", "claude", null, false, true, 0);
            PetSubtitleFrame gpt = selector.Update("idle", "gpt", null, false, true, 1);
            Check(Contains(catalog.Lines("claude", "idle"), claude.Content.Status),
                "the line belongs to the selected character");
            Check(Contains(catalog.Lines("gpt", "idle"), gpt.Content.Status),
                "switching characters re-draws from the new table");
        }

        private static void CheckAccents()
        {
            string[] roles = new string[] { "claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie" };
            string[] hexes = new string[] { "#e8a33d", "#7a8fa8", "#3b5bb5", "#7b5cd6", "#4b5a8a", "#e0b48a", "#e0b48a" };
            for (int i = 0; i < roles.Length; i++)
                Check(PetBubbleTheme.Accent(roles[i]).Hex == hexes[i], roles[i] + " uses the reviewed accent " + hexes[i]);
            Check(PetBubbleTheme.Accent("unknown-role").Hex == "#e0b48a",
                "an unknown role id falls back to the neutral accent");
            Check(String.Join(",", PetBubbleTheme.KnownRoleIds) == String.Join(",", roles),
                "the theme table covers exactly the seven built-in roles");
        }

        private static void CheckTiersIncludeTail()
        {
            // Measured against the real fonts and the real view after the halo/hairline change.
            Check(PetBubbleLayout.SubtitleHeight(true) == 64, "the one-line tier is 64 pt tall");
            Check(PetBubbleLayout.SubtitleHeight(false) == 82, "the two-line subtitle tier is 82 pt tall");
            Check(PetBubbleLayout.NoticeHeight() == 78, "the notice tier is 78 pt tall");
            Check(PetBubbleLayout.GapAbovePet == 2.0 && PetBubbleLayout.TailTipSlack == 0.0,
                "the tail leaves the reviewed 2 pt gap to the head and the tail tip is the window's bottom edge");
            Check(PetBubbleLayout.BorderWidth == 1.0 && PetBubbleLayout.TailBorderWidth == 1.0,
                "the border is a 1 pt hairline on the body and the tail");
            Check(PetBubbleLayout.AccentGlows.Length == 3 && PetBubbleLayout.GlowInset == 8.0,
                "three accent halo passes inside an 8 pt margin");
            double[] widths = new double[] { PetBubbleLayout.MinWidth, 140.0, PetBubbleLayout.MaxWidth };
            double[] heights = new double[]
            {
                PetBubbleLayout.SubtitleHeight(true), PetBubbleLayout.SubtitleHeight(false), PetBubbleLayout.NoticeHeight()
            };
            for (int w = 0; w < widths.Length; w++)
            {
                for (int h = 0; h < heights.Length; h++)
                {
                    PetBubbleRect body = PetBubbleLayout.BodyRect(widths[w], heights[h]);
                    PetBubbleRect outer = PetBubbleLayout.TailOuterRect(widths[w], heights[h]);
                    Check(body.X >= PetBubbleLayout.GlowInset &&
                        body.X + body.Width <= widths[w] - PetBubbleLayout.GlowInset + 1e-9,
                        "the body sits inside the halo margin");
                    Check(outer.X >= 0 && outer.Y >= 0, "the tail stays inside the left/top edge");
                    Check(outer.X + outer.Width <= widths[w] + 1e-9, "the tail stays inside the right edge");
                    Check(outer.Y + outer.Height <= heights[h] + 1e-9, "the tail stays inside the bottom edge");
                    Check(outer.Y >= body.Y + body.Height, "the tail hangs below the body, not over the text");
                    Check(Math.Abs(outer.X + outer.Width / 2.0 - (body.X + body.Width / 2.0)) < 1e-9,
                        "the tail is centred on the body");
                    Check(Math.Abs(outer.Y + outer.Height - heights[h]) <= 1,
                        "the window bottom is essentially the tail's outer tip");
                    // No halo may paint below the body: that area belongs to the character.
                    Check(Math.Abs(PetBubbleLayout.BodyGlowClip(widths[w], heights[h]).Height -
                        (body.Y + body.Height)) < 1e-9,
                        "the body halo is clipped exactly at the body's bottom edge");
                    for (int g = 0; g < PetBubbleLayout.AccentGlows.Length; g++)
                    {
                        PetBubbleRect halo = PetBubbleLayout.GlowRect(PetBubbleLayout.AccentGlows[g], widths[w], heights[h]);
                        Check(halo.Y >= 0 && halo.Y + halo.Height <= body.Y + body.Height + 1e-9,
                            "a halo pass never reaches below the body");
                        Check(halo.X >= 0 && halo.X + halo.Width <= widths[w] + 1e-9,
                            "a halo pass stays inside the side margins");
                    }
                }
            }
        }

        /// The renderer must publish the subtitle for the pose it actually settled on, and a
        /// subtitle must never replace an in-flight notice.
        private static void CheckAnimatorPublishesSubtitle(PetSubtitleCatalog catalog)
        {
            ISet<string> poses = new HashSet<string>(StringComparer.Ordinal)
            {
                "idle", "idle-2", "idle-3", "idle-blink", "thinking", "thinking-2",
                "busy_left", "busy_right", "reading", "writing", "searching", "running",
                "delegating", "drawing", "asking", "listening", "compact", "surprised",
                "happy", "happy-2", "oops", "sorry", "sleeping", "tired",
                "swamped_left", "swamped_right", "proud", "picked-up", "picked-up-2"
            };
            PetAnimator animator = new PetAnimator(delegate(string characterId) { return poses; });
            animator.AttachSubtitleCatalog(catalog, 0x68616E6170657421UL);
            PetRenderFrame idle = animator.Update(State("idle", null, null, "s-sub", "deepseek", 1), 0);
            Check(idle.Bubble != null && idle.Bubble.Style == PetBubbleStyle.Subtitle,
                "An idle pose publishes a one-line subtitle.");
            Check(Contains(catalog.Lines("deepseek", "idle"), idle.Bubble.Status),
                "The published line belongs to the selected character's idle wording.");
            Check(idle.NextWakeAt.HasValue && idle.NextWakeAt.Value <= 6,
                "A self-retiring subtitle schedules a wake no later than its own dwell deadline.");

            // The idle blink rhythm already wakes at 5.8s, so that wake may not come from the
            // subtitle. A dedicated animator proves the dwell deadline itself clears the bubble.
            PetAnimator retireAnimator = new PetAnimator(delegate(string characterId) { return poses; });
            retireAnimator.AttachSubtitleCatalog(catalog, 0x68616E6170657421UL);
            retireAnimator.Update(State("idle", null, null, "s-sub", "deepseek", 1), 0);
            PetRenderFrame retired = retireAnimator.Update(State("idle", null, null, "s-sub", "deepseek", 1), 6.01);
            Check(retired.Bubble == null, "The idle subtitle is cleared at its own dwell deadline.");

            // A confirmation still wins, in its unchanged two-line format.
            PetNotice[] notices = new[] {
                new PetNotice("confirmation:aaaaaaaa:2000", "confirmation", "s-sub", "确认", 2000)
            };
            PetViewState confirming = State("idle", null, null, "s-sub", "deepseek", 2000, notices);
            PetRenderFrame confirmed = animator.Update(confirming, 3, false, true, true, 2000);
            Check(confirmed.Bubble != null && confirmed.Bubble.Style == PetBubbleStyle.Notice,
                "A confirmation takes the bubble over as a two-line notice even mid-subtitle.");
            Check(confirmed.Bubble.Status == "需要你确认",
                "The notice wording is unchanged by the subtitle layer.");

            // Bubbles off: no subtitle reaches the window, and the pose is untouched.
            PetAnimator hiddenAnimator = new PetAnimator(delegate(string characterId) { return poses; });
            hiddenAnimator.AttachSubtitleCatalog(catalog, 1UL);
            PetRenderFrame hidden = hiddenAnimator.Update(
                State("working", null, null, "s-hidden", "claude", 1), 0, false, true, false);
            Check(hidden.Bubble == null, "With bubbles off no subtitle is published.");
            Check(hidden.Pose == "thinking", "With bubbles off the pose is still driven normally.");
        }

        private static PetNoticePresentation MakeNotice(string id, string kind, string title, string status,
            double startedAt, double endsAt, bool visible)
        {
            return new PetNoticePresentation(id, kind, title, status, startedAt, endsAt, visible);
        }

        private static PetViewState State(string status, string toolName, string hint, string sessionId,
            string characterId, long lastActivityAt, IReadOnlyList<PetNotice> notices = null)
        {
            PetActivity activity = new PetActivity(sessionId, "Synthetic session", "synthetic-agent",
                "Synthetic Agent", status, toolName, lastActivityAt, hint, null);
            PetSelection selection = new PetSelection(characterId, 0, 0);
            return new PetViewState(PetRole.BuiltIns, activity, selection, true, "latest", 0, notices);
        }

        private static bool Contains(string[] values, string value)
        {
            for (int i = 0; i < values.Length; i++) if (values[i] == value) return true;
            return false;
        }

        private static string AssetRoot()
        {
            string configured = Environment.GetEnvironmentVariable("CROSSPET_ASSET_DIR");
            if (!String.IsNullOrEmpty(configured)) return configured;
            // The checks executable can live at different depths under .build, so search
            // upwards for the canonical asset folder instead of counting directories.
            DirectoryInfo directory = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (directory != null)
            {
                string candidate = Path.Combine(directory.FullName, "assets", "crosspet");
                if (File.Exists(Path.Combine(candidate, "pet-lines.json"))) return candidate;
                directory = directory.Parent;
            }
            throw new InvalidDataException(
                "asset root not found; set CROSSPET_ASSET_DIR to worktree/assets/crosspet (searched above "
                + AppDomain.CurrentDomain.BaseDirectory + ")");
        }

        private static Dictionary<string, object> Deserialize(string path)
        {
            string text = File.ReadAllText(path, new UTF8Encoding(false, true));
            return new System.Web.Script.Serialization.JavaScriptSerializer().DeserializeObject(text)
                as Dictionary<string, object>;
        }

        private static void Check(bool condition, string message)
        {
            _checks++;
            if (!condition) throw new InvalidOperationException("CHECK FAILED: " + message);
        }
    }
}
