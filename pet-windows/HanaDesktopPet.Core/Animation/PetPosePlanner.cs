using System;
using System.Collections.Generic;
using System.Linq;

namespace HanaDesktopPet.Core
{
    internal static class PetPosePlanner
    {
        private static readonly HashSet<string> ReadingTools = new HashSet<string>(StringComparer.Ordinal)
        {
            "read_file", "readfile", "file_read", "read_text_file", "read_document", "open_file",
            "get_file_contents", "web_fetch", "current_status"
        };
        private static readonly HashSet<string> WritingTools = new HashSet<string>(StringComparer.Ordinal)
        {
            "write_file", "writefile", "file_write", "edit_file", "editfile", "append_file",
            "replace_file", "patch_file", "todo_write"
        };
        private static readonly HashSet<string> GenericReadingTools = new HashSet<string>(StringComparer.Ordinal) { "read", "ls" };
        private static readonly HashSet<string> GenericWritingTools = new HashSet<string>(StringComparer.Ordinal) { "write", "edit" };
        private static readonly HashSet<string> SearchingTools = new HashSet<string>(StringComparer.Ordinal)
        {
            "search", "web_search", "search_web", "search_files", "search_code", "code_search", "grep", "find",
            "find_files", "ripgrep", "rg", "tool_search", "tool_help", "browser", "search_memory"
        };
        private static readonly HashSet<string> RunningTools = new HashSet<string>(StringComparer.Ordinal)
        {
            "exec", "execute", "shell", "terminal", "bash", "zsh", "run_command", "execute_command",
            "exec_command", "run_shell_command", "write_stdin"
        };
        private static readonly HashSet<string> DelegatingTools = new HashSet<string>(StringComparer.Ordinal)
        {
            "delegate", "delegate_task", "subagent", "spawn_agent", "spawn_subagent", "create_agent",
            "subagent_reply", "subagent_message", "subagent_close", "session"
        };
        private static readonly HashSet<string> DrawingTools = new HashSet<string>(StringComparer.Ordinal)
        {
            "image_gen", "image_generation", "generate_image", "create_image", "draw_image",
            "text_to_image", "media_generate-image"
        };

        private static readonly string[] BasePoses = new string[]
        {
            "idle", "thinking", "busy_left", "busy_right", "reading", "writing", "searching", "running",
            "delegating", "drawing", "happy", "oops"
        };

        internal static string PreferredPose(string status, string toolName, string hint)
        {
            // The existing short error feedback always wins over a concurrent host hint.
            if (status == "error") return "oops";
            if (hint == "confirming") return "asking";
            if (hint == "compacting") return "compact";
            if (hint == "interrupted") return "surprised";
            switch (status)
            {
                case "idle": return "idle";
                case "working": return "thinking";
                case "tool": return PreferredToolPose(toolName) ?? "busy_left";
                case "success": return "happy";
                default: return "idle";
            }
        }

        internal static string Resolve(string preferred, ISet<string> available)
        {
            if (available == null || available.Count == 0) return "idle";
            foreach (string candidate in CandidatePoses(preferred))
                if (available.Contains(candidate)) return candidate;
            if (available.Contains("idle")) return "idle";
            // Normal catalogs always contain idle. Keep malformed catalogs inside their own
            // listed artwork while making this last-resort choice stable across set types.
            return available.OrderBy(name => name, StringComparer.Ordinal).First();
        }

        internal static string WorkThinkingVariant(string characterId)
        {
            if (characterId == "claude") return "thinking-2";
            if (characterId == "deepseek" || characterId == "deepseek-hoodie") return "deepthink";
            return "thinking";
        }

        internal static WorkPoseSet WorkPoses(string characterId, ISet<string> available)
        {
            if (available == null || available.Count == 0) return null;
            string thinking = Resolve("thinking", available);
            string variantName = WorkThinkingVariant(characterId);
            WorkPoseSet poses = new WorkPoseSet(
                thinking,
                available.Contains("busy_left") ? "busy_left" : thinking,
                available.Contains(variantName) ? variantName : thinking,
                available.Contains("busy_right") ? "busy_right" : thinking);
            return poses.SupportsRhythm ? poses : null;
        }

        private static string PreferredToolPose(string toolName)
        {
            if (toolName == null || toolName.Length > 80) return null;
            string nameSpace;
            string leaf;
            if (!TryNormalizeToolName(toolName, out nameSpace, out leaf)) return null;
            if (ReadingTools.Contains(leaf)) return "reading";
            if (WritingTools.Contains(leaf)) return "writing";
            if (GenericReadingTools.Contains(leaf) && (nameSpace.Length == 0 || nameSpace == "functions")) return "reading";
            if (GenericWritingTools.Contains(leaf) && (nameSpace.Length == 0 || nameSpace == "functions")) return "writing";
            if (SearchingTools.Contains(leaf)) return "searching";
            if (RunningTools.Contains(leaf)) return "running";
            if (DelegatingTools.Contains(leaf)) return "delegating";
            if (DrawingTools.Contains(leaf)) return "drawing";
            return null;
        }

        private static bool TryNormalizeToolName(string name, out string nameSpace, out string leaf)
        {
            nameSpace = String.Empty;
            leaf = String.Empty;
            string lowered = name.Trim().ToLowerInvariant();
            if (lowered.Length == 0) return false;
            foreach (char ch in lowered)
            {
                if ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' ||
                    ch == '.' || ch == ':' || ch == '/') continue;
                return false;
            }

            string normalized = lowered.Replace("::", ".");
            string[] namespaceParts = normalized.Split(new char[] { '.', ':', '/' }, StringSplitOptions.None);
            if (namespaceParts.Any(part => part.Length == 0)) return false;
            List<string> nameParts = new List<string>();
            foreach (string part in namespaceParts)
            {
                string[] components = part.Split(new string[] { "__" }, StringSplitOptions.None);
                if (components.Any(component => component.Length == 0)) return false;
                nameParts.AddRange(components);
            }
            if (nameParts.Count == 0) return false;
            leaf = nameParts[nameParts.Count - 1];
            nameParts.RemoveAt(nameParts.Count - 1);
            nameSpace = String.Join(".", nameParts.ToArray());

            int delimiter = Math.Max(leaf.LastIndexOf('_'), leaf.LastIndexOf('-'));
            if (delimiter > 0)
            {
                string suffix = leaf.Substring(delimiter + 1);
                if (suffix.StartsWith("v", StringComparison.Ordinal)) suffix = suffix.Substring(1);
                if (suffix.Length > 0 && suffix.All(ch => ch >= '0' && ch <= '9'))
                    leaf = leaf.Substring(0, delimiter);
            }
            return true;
        }

        private static IEnumerable<string> CandidatePoses(string preferred)
        {
            List<string> candidates = new List<string> { preferred };
            string canonicalBase = BasePoses.FirstOrDefault(baseName => preferred == baseName ||
                preferred == baseName + "-2" || preferred == baseName + "-3");
            if (BasePoses.Contains(preferred, StringComparer.Ordinal))
            {
                candidates.Add(preferred + "-2");
                candidates.Add(preferred + "-3");
            }
            else if (canonicalBase != null && preferred != canonicalBase)
            {
                candidates.Add(canonicalBase);
            }

            string canonical = canonicalBase ?? preferred;
            switch (canonical)
            {
                case "asking": candidates.AddRange(new[] { "listening", "thinking", "idle" }); break;
                case "compact": candidates.AddRange(new[] { "thinking", "busy_left", "idle" }); break;
                case "surprised": candidates.AddRange(new[] { "oops", "idle" }); break;
                case "idle": candidates.AddRange(new[] { "idle-blink", "idle-2", "idle-3" }); break;
                case "idle-blink": candidates.AddRange(new[] { "idle", "idle-2", "idle-3" }); break;
                case "thinking": candidates.AddRange(new[] { "busy_left", "busy_right", "idle", "idle-2", "idle-3" }); break;
                case "busy_left": candidates.AddRange(new[] { "busy_right", "thinking", "thinking-2", "idle", "idle-2", "idle-3" }); break;
                case "busy_right": candidates.AddRange(new[] { "busy_left", "thinking", "thinking-2", "idle", "idle-2", "idle-3" }); break;
                case "reading":
                case "writing":
                case "searching":
                    candidates.AddRange(new[] { "thinking", "thinking-2", "busy_left", "busy_right", "idle", "idle-2", "idle-3" });
                    break;
                case "running": candidates.AddRange(new[] { "busy_left", "busy_right", "thinking", "thinking-2", "idle", "idle-2", "idle-3" }); break;
                case "delegating": candidates.AddRange(new[] { "busy_right", "busy_left", "running", "thinking", "thinking-2", "idle", "idle-2", "idle-3" }); break;
                case "drawing": candidates.AddRange(new[] { "thinking", "thinking-2", "busy_left", "busy_right", "idle", "idle-2", "idle-3" }); break;
                case "happy": candidates.AddRange(new[] { "happy-2", "proud", "idle", "idle-2", "idle-3" }); break;
                case "oops": candidates.AddRange(new[] { "sorry", "surprised", "idle", "idle-2", "idle-3" }); break;
            }
            return candidates.Distinct(StringComparer.Ordinal);
        }
    }

    internal enum PetMood
    {
        Sleeping,
        Tired,
        SwampedLeft,
        SwampedRight,
        Proud
    }

    internal static class PetMoodPoseResolver
    {
        internal static string PrimaryPose(PetMood mood)
        {
            switch (mood)
            {
                case PetMood.Sleeping: return "sleeping";
                case PetMood.Tired: return "tired";
                case PetMood.SwampedLeft: return "swamped_left";
                case PetMood.SwampedRight: return "swamped_right";
                case PetMood.Proud: return "proud";
                default: return "idle";
            }
        }

        internal static string Resolve(PetMood mood, string workPose, ISet<string> available)
        {
            string[] candidates;
            switch (mood)
            {
                case PetMood.Sleeping: candidates = new[] { "sleeping", "sleeping-2", "idle" }; break;
                case PetMood.Tired: candidates = new[] { "tired", "tired-2", workPose, "idle" }; break;
                case PetMood.SwampedLeft: candidates = new[] { "swamped_left", "busy_left", "busy_right", "idle" }; break;
                case PetMood.SwampedRight: candidates = new[] { "swamped_right", "busy_right", "busy_left", "idle" }; break;
                case PetMood.Proud: candidates = new[] { "proud", "proud-2", "happy", "happy-2", "idle" }; break;
                default: candidates = new[] { "idle" }; break;
            }
            foreach (string candidate in candidates)
                if (available != null && available.Contains(candidate)) return candidate;
            return PetPosePlanner.Resolve("idle", available);
        }
    }

    internal sealed class PetMoodTracker
    {
        internal const double SleepAfterIdle = 5 * 60;
        internal const double TiredAfterWork = 10 * 60;
        internal const double BusyToolWindow = 10;
        internal const int BusyToolStartThreshold = 5;
        internal const double ProudAfterWork = 60;
        internal const double ShortFeedbackContinuation = 2.5;
        private const double ThresholdWakeEpsilon = 0.001;

        private string _status;
        private string _hint;
        private long? _lastActivityAt;
        private double? _idleSince;
        private double? _workSince;
        private double? _feedbackContinuationEndsAt;
        private bool _proudSuccess;
        private readonly List<double> _toolStartTimes = new List<double>();
        private string _lastToolName;
        private long? _lastToolActivityAt;
        private bool _hasToolSignature;
        private PetMood? _lastSwampedMood;
        private double? _lastObservedAt;

        internal double? ContinuousWorkStart { get { return _workSince; } }

        internal void Reset()
        {
            _status = null;
            _hint = null;
            _lastActivityAt = null;
            _idleSince = null;
            _workSince = null;
            _feedbackContinuationEndsAt = null;
            _proudSuccess = false;
            _toolStartTimes.Clear();
            _lastToolName = null;
            _lastToolActivityAt = null;
            _hasToolSignature = false;
            _lastSwampedMood = null;
            _lastObservedAt = null;
        }

        internal PetMood? Update(string status, string toolName, string hint, long lastActivityAt, double at)
        {
            double now = NormalizeTime(at);
            ExpireFeedbackContinuation(now);
            string previousStatus = _status;
            bool timestampChanged = !_lastActivityAt.HasValue || _lastActivityAt.Value != lastActivityAt;

            switch (status)
            {
                case "idle":
                    if (hint != null)
                    {
                        _idleSince = null;
                    }
                    else if (previousStatus != "idle" || timestampChanged || _hint != null || !_idleSince.HasValue)
                    {
                        _idleSince = now;
                    }
                    _workSince = null;
                    _feedbackContinuationEndsAt = null;
                    _proudSuccess = false;
                    _hasToolSignature = false;
                    break;

                case "working":
                case "tool":
                    bool returningFromShortFeedback = (previousStatus == "success" || previousStatus == "error") &&
                        _feedbackContinuationEndsAt.HasValue && now < _feedbackContinuationEndsAt.Value && _workSince.HasValue;
                    if (!IsWorkStatus(previousStatus) && !returningFromShortFeedback) _workSince = now;
                    _idleSince = null;
                    _feedbackContinuationEndsAt = null;
                    _proudSuccess = false;
                    if (status == "tool")
                    {
                        bool newToolStart = previousStatus != "tool" || _lastToolName != toolName ||
                            !_lastToolActivityAt.HasValue || _lastToolActivityAt.Value != lastActivityAt || !_hasToolSignature;
                        if (newToolStart) RecordToolStart(now);
                        _lastToolName = toolName;
                        _lastToolActivityAt = lastActivityAt;
                        _hasToolSignature = true;
                    }
                    else
                    {
                        _hasToolSignature = false;
                    }
                    break;

                case "success":
                case "error":
                    _idleSince = null;
                    if (IsWorkStatus(previousStatus))
                    {
                        _feedbackContinuationEndsAt = now + ShortFeedbackContinuation;
                    }
                    else if ((previousStatus == "success" || previousStatus == "error") && timestampChanged && _workSince.HasValue)
                    {
                        _feedbackContinuationEndsAt = now + ShortFeedbackContinuation;
                    }
                    _hasToolSignature = false;
                    if (status == "success")
                    {
                        bool newFeedback = previousStatus != "success" || timestampChanged;
                        if (newFeedback) _proudSuccess = _workSince.HasValue && now - _workSince.Value >= ProudAfterWork;
                    }
                    else
                    {
                        _proudSuccess = false;
                    }
                    break;
            }

            _status = status;
            _hint = hint;
            _lastActivityAt = lastActivityAt;
            _lastObservedAt = now;
            return MoodAt(now);
        }

        internal PetMood? Advance(double at)
        {
            double now = NormalizeTime(at);
            ExpireFeedbackContinuation(now);
            _lastObservedAt = now;
            return MoodAt(now);
        }

        internal PetMood? MoodAt(double at)
        {
            double now = NormalizeTime(at);
            if (_hint != null) return null;
            if (_status == "success" && _proudSuccess) return PetMood.Proud;
            if (_status == "idle" && _idleSince.HasValue && now - _idleSince.Value > SleepAfterIdle)
                return PetMood.Sleeping;
            if (!IsWorkStatus(_status) || !_workSince.HasValue) return null;
            if (_status == "tool" && RecentToolStarts(now).Count >= BusyToolStartThreshold)
                return _lastSwampedMood ?? PetMood.SwampedLeft;
            if (now - _workSince.Value > TiredAfterWork) return PetMood.Tired;
            return null;
        }

        internal double? NextDeadline(double at)
        {
            double now = NormalizeTime(at);
            List<double> deadlines = new List<double>();
            if (_hint == null)
            {
                if (_status == "idle" && _idleSince.HasValue)
                {
                    double deadline = _idleSince.Value + SleepAfterIdle + ThresholdWakeEpsilon;
                    if (deadline > now) deadlines.Add(deadline);
                }
                if (IsWorkStatus(_status) && _workSince.HasValue)
                {
                    double deadline = _workSince.Value + TiredAfterWork + ThresholdWakeEpsilon;
                    if (deadline > now) deadlines.Add(deadline);
                }
                if (_status == "tool")
                {
                    List<double> recent = RecentToolStarts(now);
                    if (recent.Count >= BusyToolStartThreshold)
                    {
                        double deadline = recent[0] + BusyToolWindow + ThresholdWakeEpsilon;
                        if (deadline > now) deadlines.Add(deadline);
                    }
                }
            }
            if (_feedbackContinuationEndsAt.HasValue && _feedbackContinuationEndsAt.Value > now)
                deadlines.Add(_feedbackContinuationEndsAt.Value);
            return deadlines.Count == 0 ? (double?)null : deadlines.Min();
        }

        private void RecordToolStart(double time)
        {
            _toolStartTimes.Add(time);
            if (_toolStartTimes.Count > BusyToolStartThreshold)
                _toolStartTimes.RemoveRange(0, _toolStartTimes.Count - BusyToolStartThreshold);
            if (RecentToolStarts(time).Count >= BusyToolStartThreshold)
                _lastSwampedMood = _lastSwampedMood == PetMood.SwampedLeft ? PetMood.SwampedRight : PetMood.SwampedLeft;
        }

        private List<double> RecentToolStarts(double time)
        {
            return _toolStartTimes.Where(start => start >= time - BusyToolWindow).ToList();
        }

        private void ExpireFeedbackContinuation(double time)
        {
            if (!_feedbackContinuationEndsAt.HasValue || time < _feedbackContinuationEndsAt.Value) return;
            _workSince = null;
            _feedbackContinuationEndsAt = null;
        }

        private double NormalizeTime(double time)
        {
            double safe = IsFinite(time) ? Math.Max(0, time) : 0;
            return Math.Max(safe, _lastObservedAt.HasValue ? _lastObservedAt.Value : safe);
        }

        private static bool IsFinite(double value) { return !Double.IsNaN(value) && !Double.IsInfinity(value); }
        private static bool IsWorkStatus(string status) { return status == "working" || status == "tool"; }
    }

    internal sealed class WorkPoseSet
    {
        internal WorkPoseSet(string thinking, string busyLeft, string thinkingVariant, string busyRight)
        {
            Thinking = thinking;
            BusyLeft = busyLeft;
            ThinkingVariant = thinkingVariant;
            BusyRight = busyRight;
        }

        internal string Thinking { get; private set; }
        internal string BusyLeft { get; private set; }
        internal string ThinkingVariant { get; private set; }
        internal string BusyRight { get; private set; }

        internal IList<string> DistinctPoses
        {
            get
            {
                return new[] { Thinking, BusyLeft, ThinkingVariant, BusyRight }
                    .Distinct(StringComparer.Ordinal).ToList();
            }
        }

        internal bool SupportsRhythm { get { return DistinctPoses.Count >= 2; } }
    }
}
