using System;
using System.Collections.Generic;

namespace HanaDesktopPet.Core
{
    /// <summary>
    /// Deterministic SplitMix64. The selector never touches system randomness, so a check
    /// can assert exactly which line a given seed produces.
    /// </summary>
    internal sealed class PetSubtitleRandom
    {
        private ulong _state;

        internal PetSubtitleRandom(ulong seed)
        {
            _state = seed;
        }

        internal ulong Next()
        {
            unchecked
            {
                _state += 0x9E3779B97F4A7C15UL;
                ulong z = _state;
                z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
                z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
                return z ^ (z >> 31);
            }
        }

        /// <summary>Uniform value in 0..upperBound-1; upperBound &lt;= 1 yields 0.</summary>
        internal int Next(int upperBound)
        {
            if (upperBound <= 1) return 0;
            return (int)(Next() % (ulong)upperBound);
        }
    }

    public enum PetBubbleStyle
    {
        /// <summary>Two lines: session title + the notice status word.</summary>
        Notice,
        /// <summary>One line of dialogue keyed off the pose that is on screen.</summary>
        Subtitle
    }

    public sealed class PetBubbleContent
    {
        internal PetBubbleContent(string id, PetBubbleStyle style, string title, string status)
        {
            Id = id;
            Style = style;
            Title = title;
            Status = status;
        }

        public string Id { get; private set; }
        public PetBubbleStyle Style { get; private set; }
        /// <summary>Notice only: the session title. Empty for a subtitle.</summary>
        public string Title { get; private set; }
        /// <summary>Notice: its status word. Subtitle: the dialogue line itself.</summary>
        public string Status { get; private set; }

        internal bool SameWords(PetBubbleContent other)
        {
            return other != null && Id == other.Id && Style == other.Style &&
                Title == other.Title && Status == other.Status;
        }
    }

    internal sealed class PetSubtitleFrame
    {
        internal PetSubtitleFrame(PetBubbleContent content, bool changed, double? nextDeadline)
        {
            Content = content;
            Changed = changed;
            NextDeadline = nextDeadline;
        }

        internal PetBubbleContent Content { get; private set; }
        /// <summary>True when the visible words changed, so the window re-measures its size.</summary>
        internal bool Changed { get; private set; }
        /// <summary>The next moment this selector must be ticked; null means nothing is scheduled.</summary>
        internal double? NextDeadline { get; private set; }
    }

    /// <summary>
    /// Turns "which pose is on screen right now" into one line of dialogue.
    ///
    /// Priority, highest first: the pick-up loop, a confirmation notice, a completion
    /// notice (both keep their unchanged two-line format), then the pose's subtitle.
    /// Every subtitle stays at least MinDwellSeconds; states arriving inside that window
    /// queue and merge so only the last one shows. Self-retiring states clear themselves;
    /// persistent (null dwell) states stay until the pose changes or something preempts
    /// them. Notices and the pick-up line are never delayed by that dwell.
    ///
    /// Pure logic: no session, tool name, tool argument or file path is read here.
    /// </summary>
    internal sealed class PetSubtitleSelector
    {
        private sealed class Showing
        {
            internal PetBubbleContent Content;
            internal string RoleId;
            internal string State;
            internal double ShownAt;
            /// <summary>Null when the state persists until the pose changes.</summary>
            internal double? RetireAt;
            internal bool IsSubtitle { get { return Content.Style == PetBubbleStyle.Subtitle; } }
        }

        private sealed class Queued
        {
            internal PetBubbleContent Content;
            internal string RoleId;
            internal string State;
            internal double ReadyAt;
        }

        private readonly PetSubtitleCatalog _catalog;
        private readonly PetSubtitleRandom _random;
        private Showing _showing;
        private Queued _queued;
        private string _appliedKey;
        private string _retiredKey;
        /// <summary>One entry per (role, state): bounded, never grows at runtime.</summary>
        private readonly Dictionary<string, int> _lastLineIndex = new Dictionary<string, int>(StringComparer.Ordinal);

        internal PetSubtitleSelector(PetSubtitleCatalog catalog, ulong seed)
        {
            if (catalog == null) throw new ArgumentNullException("catalog");
            _catalog = catalog;
            _random = new PetSubtitleRandom(seed);
            MinDwellSeconds = Math.Max(0, catalog.MinDwellSeconds);
        }

        internal double MinDwellSeconds { get; private set; }

        internal PetBubbleContent CurrentContent
        {
            get { return _showing == null ? null : _showing.Content; }
        }

        internal PetSubtitleFrame Update(string pose, string roleId, PetNoticePresentation notice,
            bool isPickUp, bool enabled, double time)
        {
            double now = IsFinite(time) ? Math.Max(0, time) : 0;
            PetBubbleContent previous = CurrentContent;

            if (!enabled)
            {
                Clear();
                return new PetSubtitleFrame(null, previous != null, null);
            }

            // 1. The pick-up loop wins outright: the user is holding the character.
            if (isPickUp)
            {
                string pickUpState = _catalog.StateKeyForPose("picked-up");
                if (pickUpState != null && _catalog.HasLines(roleId, pickUpState))
                {
                    string pickUpKey = roleId + "|" + pickUpState;
                    if (_appliedKey != pickUpKey)
                    {
                        _appliedKey = pickUpKey;
                        _retiredKey = null;
                        Show(DrawLine(roleId, pickUpState), roleId, pickUpState, now);
                    }
                    _queued = null;
                    return Frame(previous);
                }
            }

            // 2./3. A notice keeps its exact existing two-line format.
            if (notice != null && notice.BubbleVisible)
            {
                PetBubbleContent content = new PetBubbleContent(
                    notice.Id, PetBubbleStyle.Notice, notice.Title, notice.Status);
                Showing showing = new Showing();
                showing.Content = content;
                showing.RoleId = roleId;
                showing.State = "notice";
                showing.ShownAt = now;
                showing.RetireAt = null;
                _showing = showing;
                _queued = null;
                // A notice is a different owner of the bubble: when it ends, the pose's state
                // is re-entered and speaks again instead of resuming a retired line.
                _appliedKey = null;
                _retiredKey = null;
                return new PetSubtitleFrame(content, !content.SameWords(previous), notice.EndsAt);
            }

            // 4. The subtitle for the pose's logical state.
            string state = _catalog.StateKeyForPose(pose);
            if (state == null || !_catalog.HasLines(roleId, state))
            {
                Clear();
                return new PetSubtitleFrame(null, previous != null, null);
            }
            return Advance(roleId, state, now, previous);
        }

        private PetSubtitleFrame Advance(string roleId, string state, double now, PetBubbleContent previous)
        {
            string key = roleId + "|" + state;

            if (_appliedKey == key)
            {
                if (_queued != null && _queued.State == state && now >= _queued.ReadyAt)
                {
                    Show(_queued.Content, roleId, state, now);
                    _queued = null;
                    return Frame(previous);
                }
                if (_showing != null && _showing.State == state && _showing.RoleId == roleId &&
                    _showing.RetireAt.HasValue && now >= _showing.RetireAt.Value)
                {
                    _showing = null;
                    _queued = null;
                    _retiredKey = key;
                    return new PetSubtitleFrame(null, true, null);
                }
                return Frame(previous);
            }

            _appliedKey = key;
            // This state already retired and its pose never went away: stay silent.
            if (_retiredKey == key)
            {
                _queued = null;
                return new PetSubtitleFrame(CurrentContent, false, _showing == null ? null : _showing.RetireAt);
            }
            _retiredKey = null;

            PetBubbleContent content = DrawLine(roleId, state);
            // A subtitle already on screen for the same character gets its full minimum
            // dwell. Notices, the pick-up line and a character switch are exempt.
            if (_showing != null && _showing.IsSubtitle && _showing.RoleId == roleId)
            {
                double notBefore = _showing.ShownAt + MinDwellSeconds;
                if (now < notBefore)
                {
                    Queued queued = new Queued();
                    queued.Content = content;
                    queued.RoleId = roleId;
                    queued.State = state;
                    queued.ReadyAt = notBefore;
                    _queued = queued;
                    return new PetSubtitleFrame(_showing.Content, false, notBefore);
                }
            }
            Show(content, roleId, state, now);
            _queued = null;
            return Frame(previous);
        }

        private void Show(PetBubbleContent content, string roleId, string state, double now)
        {
            Showing showing = new Showing();
            showing.Content = content;
            showing.RoleId = roleId;
            showing.State = state;
            showing.ShownAt = now;
            double? dwell = _catalog.DwellSeconds(state);
            showing.RetireAt = dwell.HasValue ? (double?)(now + dwell.Value) : null;
            _showing = showing;
        }

        private void Clear()
        {
            _showing = null;
            _queued = null;
            _appliedKey = null;
            _retiredKey = null;
        }

        /// <summary>Draws the line for one state entry; the same state never repeats twice in a row.</summary>
        private PetBubbleContent DrawLine(string roleId, string state)
        {
            string[] lines = _catalog.Lines(roleId, state);
            if (lines.Length == 0) return null;
            string key = roleId + "|" + state;
            int index = 0;
            if (lines.Length > 1)
            {
                int last;
                if (_lastLineIndex.TryGetValue(key, out last))
                {
                    int offset = _random.Next(lines.Length - 1);
                    index = offset >= last ? offset + 1 : offset;
                }
                else
                {
                    index = _random.Next(lines.Length);
                }
            }
            _lastLineIndex[key] = index;
            return new PetBubbleContent(
                "subtitle:" + roleId + ":" + state + ":" + index,
                PetBubbleStyle.Subtitle, "", lines[index]);
        }

        private PetSubtitleFrame Frame(PetBubbleContent previous)
        {
            List<double> deadlines = new List<double>();
            if (_showing != null && _showing.RetireAt.HasValue) deadlines.Add(_showing.RetireAt.Value);
            if (_queued != null) deadlines.Add(_queued.ReadyAt);
            PetBubbleContent content = CurrentContent;
            double? next = null;
            if (deadlines.Count > 0)
            {
                double min = deadlines[0];
                for (int i = 1; i < deadlines.Count; i++) if (deadlines[i] < min) min = deadlines[i];
                next = min;
            }
            // A retired bubble leaves no current content; the change is real only when
            // something was on screen before.
            bool changed = content == null ? previous != null : !content.SameWords(previous);
            return new PetSubtitleFrame(content, changed, next);
        }

        private static bool IsFinite(double value)
        {
            return !Double.IsNaN(value) && !Double.IsInfinity(value);
        }
    }
}
