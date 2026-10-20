using System;
using System.Collections.Generic;

namespace HanaDesktopPet.Core
{
    public sealed class PetNoticePresentation
    {
        internal PetNoticePresentation(string id, string kind, string title, string status,
            double startedAt, double endsAt, bool bubbleVisible)
        {
            Id = id;
            Kind = kind;
            Title = title;
            Status = status;
            StartedAt = startedAt;
            EndsAt = endsAt;
            BubbleVisible = bubbleVisible;
        }

        internal string Id { get; private set; }
        internal string Kind { get; private set; }
        internal string Title { get; private set; }
        internal string Status { get; private set; }
        internal double StartedAt { get; private set; }
        internal double EndsAt { get; private set; }
        /// <summary>False when this notice may drive the pose but must never show a bubble.</summary>
        internal bool BubbleVisible { get; private set; }

        internal PetNoticePresentation WithBubbleVisible(bool visible)
        {
            return new PetNoticePresentation(Id, Kind, Title, Status, StartedAt, EndsAt, visible);
        }
    }

    internal sealed class PetNoticeTick
    {
        internal PetNoticeTick(PetNoticePresentation presentation, bool changed, double? nextDeadline)
        {
            Presentation = presentation;
            Changed = changed;
            NextDeadline = nextDeadline;
        }

        internal PetNoticePresentation Presentation { get; private set; }
        internal bool Changed { get; private set; }
        internal double? NextDeadline { get; private set; }
    }

    /// <summary>
    /// Bounded, deterministic presentation queue for confirmation and completion
    /// notices. It only sees the already-sanitised DTO and never writes activity.
    /// </summary>
    internal sealed class PetNoticeCenter
    {
        internal const double ConfirmationDisplay = 300.0;
        internal const double CompletionDisplay = 6.0;
        internal const double CompletionTTL = 20.0;
        internal const int MaxCompletionQueue = 3;
        private const int MaxSeen = 64;

        private readonly Dictionary<string, int> _seen = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly List<string> _seenOrder = new List<string>();
        private int _nextSeenOrder;
        private readonly HashSet<string> _suppressed = new HashSet<string>(StringComparer.Ordinal);
        private readonly List<string> _suppressedOrder = new List<string>();
        private readonly HashSet<string> _retired = new HashSet<string>(StringComparer.Ordinal);
        private readonly List<string> _retiredOrder = new List<string>();
        private PetNoticePresentation _active;
        private readonly List<PetNotice> _pending = new List<PetNotice>();
        private bool _initialized;
        private bool _lastBubblesEnabled = true;
        private string _lastScope = "latest";

        internal PetNoticePresentation Presentation { get { return _active; } }

        internal PetNoticeTick Update(IReadOnlyList<PetNotice> notices, bool bubblesEnabled,
            bool completionBlocked, double now, long wallNowMs, string scope = "latest")
        {
            double time = Math.Max(0, now);
            PetNoticePresentation previous = _active;
            List<PetNotice> valid = Dedupe(notices);
            Dictionary<string, PetNotice> byId = new Dictionary<string, PetNotice>(StringComparer.Ordinal);
            for (int i = 0; i < valid.Count; i++) byId[valid[i].Id] = valid[i];

            // A binding change replaces the allowed notice scope. Anything already queued
            // or showing from the old scope must stop at once and never be replayed.
            string safeScope = scope == "pinned" ? "pinned" : "latest";
            if (safeScope != _lastScope)
            {
                _lastScope = safeScope;
                // Drop anything no longer listed, but keep the new scope's own queue.
                _pending.RemoveAll(delegate(PetNotice notice) { return !byId.ContainsKey(notice.Id); });
                if (_active != null && _active.Kind == "confirmation") _active = null;
                if (_active != null && _active.Kind == "completion" && !byId.ContainsKey(_active.Id))
                    _active = null;
                for (int i = 0; i < valid.Count; i++)
                    if (valid[i].Kind == "confirmation") UnmarkSeen(valid[i].Id);
            }

            if (!_initialized)
            {
                _initialized = true;
                // Completions are one-shot history at startup; a pending confirmation
                // is still actionable and may be shown.
                for (int i = 0; i < valid.Count; i++)
                    if (valid[i].Kind == "completion") MarkSeen(valid[i].Id);
            }

            if (_lastBubblesEnabled && !bubblesEnabled)
            {
                // Turning bubbles off hides the current bubble only. A completion keeps
                // its pose but is suppressed so re-enabling cannot replay it. A confirmation
                // stays actionable, so its seen state is forgotten instead.
                if (_active != null && _active.Kind == "completion" && _active.BubbleVisible)
                {
                    Suppress(_active.Id);
                    _active = _active.WithBubbleVisible(false);
                }
                if (_active != null && _active.Kind == "confirmation") _active = null;
                // Anything already queued before the setting changed is old: neither its
                // pose nor its bubble may replay. A completion arriving while bubbles are
                // off is different: pose yes, bubble no.
                for (int i = 0; i < _pending.Count; i++) Retire(_pending[i].Id);
                for (int i = 0; i < valid.Count; i++)
                    if (valid[i].Kind == "confirmation") UnmarkSeen(valid[i].Id);
            }
            _lastBubblesEnabled = bubblesEnabled;

            if (_active != null)
            {
                // A completion already on screen gets its full six seconds even when the
                // console's notice TTL drops it from the wire list; otherwise a notice
                // queued near the TTL would be cut short mid-display.
                if (_active.EndsAt <= time)
                    _active = null;
                else if (_active.Kind == "confirmation" &&
                    (!byId.ContainsKey(_active.Id) || !bubblesEnabled))
                    _active = null;
                else if (_active.Kind == "completion" && completionBlocked)
                    _active = null;
            }

            for (int i = 0; i < valid.Count; i++)
            {
                PetNotice notice = valid[i];
                if (notice.Kind != "completion" || _seen.ContainsKey(notice.Id)) continue;
                double age = (wallNowMs - notice.At) / 1000.0;
                if (age < -1 || age > CompletionTTL)
                {
                    MarkSeen(notice.Id);
                    continue;
                }
                if (ContainsPending(notice.Id)) continue;
                if (!bubblesEnabled)
                {
                    // A completion arriving while bubbles are off still drives the pose.
                    // Its bubble is permanently suppressed for this event, even if the user
                    // re-enables bubbles before a higher-priority block clears.
                    Suppress(notice.Id);
                    _pending.Clear();
                    _pending.Add(notice);
                }
                else
                {
                    if (_pending.Count >= MaxCompletionQueue) _pending.RemoveAt(0);
                    _pending.Add(notice);
                }
                MarkSeen(notice.Id);
            }
            // A queued completion must also be pruned when the follow scope changed: the
            // console stops listing another session's notice once the pet is bound.
            _pending.RemoveAll(delegate(PetNotice notice)
            {
                if (!byId.ContainsKey(notice.Id)) return true;
                double age = (wallNowMs - notice.At) / 1000.0;
                return age < -1 || age > CompletionTTL;
            });

            // A confirmation preempts a completion. A new confirmation never preempts an
            // already-showing confirmation: oldest-first is deterministic and cannot flap.
            if (bubblesEnabled && _active != null && _active.Kind == "completion")
            {
                PetNotice confirmation = NextConfirmation(valid);
                if (confirmation != null)
                {
                    _active = null;
                    Activate(confirmation, ConfirmationDisplay, time, bubblesEnabled);
                }
            }

            if (_active == null)
            {
                PetNotice confirmation = bubblesEnabled ? NextConfirmation(valid) : null;
                if (confirmation != null)
                    Activate(confirmation, ConfirmationDisplay, time, bubblesEnabled);
                else if (!completionBlocked && _pending.Count > 0)
                {
                    PetNotice completion = _pending[0];
                    _pending.RemoveAt(0);
                    if (!_retired.Contains(completion.Id))
                    {
                        // The action always runs for a notice received while bubbles were off.
                        // Bubble visibility was decided when it arrived.
                        Activate(completion, CompletionDisplay, time, bubblesEnabled);
                    }
                }
            }

            bool changed = previous == null ? _active != null :
                (_active == null || previous.Id != _active.Id || previous.EndsAt != _active.EndsAt ||
                 previous.Status != _active.Status || previous.Title != _active.Title ||
                 previous.BubbleVisible != _active.BubbleVisible);
            return new PetNoticeTick(_active, changed, _active == null ? (double?)null : _active.EndsAt);
        }

        internal double? NextDeadline(double now)
        {
            return _active == null ? (double?)null : _active.EndsAt;
        }

        private void Activate(PetNotice notice, double display, double now, bool bubblesEnabled)
        {
            bool visible = notice.Kind == "confirmation" ||
                (bubblesEnabled && !_suppressed.Contains(notice.Id));
            _active = new PetNoticePresentation(
                notice.Id,
                notice.Kind,
                NormalizedTitle(notice.Title),
                notice.Kind == "confirmation" ? "需要你确认" : "本轮完成了！",
                now,
                now + display,
                visible);
            if (notice.Kind == "confirmation") MarkSeen(notice.Id);
        }

        private PetNotice NextConfirmation(IList<PetNotice> notices)
        {
            PetNotice best = null;
            for (int i = 0; i < notices.Count; i++)
            {
                PetNotice notice = notices[i];
                if (notice.Kind != "confirmation" || _seen.ContainsKey(notice.Id)) continue;
                if (best == null || notice.At < best.At ||
                    (notice.At == best.At && String.CompareOrdinal(notice.Id, best.Id) < 0))
                    best = notice;
            }
            return best;
        }

        private static string NormalizedTitle(string title)
        {
            string cleaned = (title ?? String.Empty).Trim();
            if (cleaned.Length == 0) return "对话";
            return cleaned.Length <= 120 ? cleaned : cleaned.Substring(0, 120);
        }

        private void MarkSeen(string id)
        {
            if (_seen.ContainsKey(id)) return;
            _seen[id] = _nextSeenOrder;
            _seenOrder.Add(id);
            _nextSeenOrder++;
            while (_seenOrder.Count > MaxSeen)
            {
                string oldest = _seenOrder[0];
                _seenOrder.RemoveAt(0);
                _seen.Remove(oldest);
            }
        }

        private void UnmarkSeen(string id)
        {
            if (!_seen.Remove(id)) return;
            _seenOrder.RemoveAll(delegate(string value) { return value == id; });
        }

        private void Suppress(string id)
        {
            if (!_suppressed.Add(id)) return;
            _suppressedOrder.Add(id);
            while (_suppressedOrder.Count > MaxSeen)
            {
                string oldest = _suppressedOrder[0];
                _suppressedOrder.RemoveAt(0);
                _suppressed.Remove(oldest);
            }
        }

        private void Retire(string id)
        {
            if (!_retired.Add(id)) return;
            _retiredOrder.Add(id);
            while (_retiredOrder.Count > MaxSeen)
            {
                string oldest = _retiredOrder[0];
                _retiredOrder.RemoveAt(0);
                _retired.Remove(oldest);
            }
        }

        private bool ContainsPending(string id)
        {
            for (int i = 0; i < _pending.Count; i++)
                if (_pending[i].Id == id) return true;
            return false;
        }

        private static List<PetNotice> Dedupe(IReadOnlyList<PetNotice> notices)
        {
            List<PetNotice> result = new List<PetNotice>();
            HashSet<string> ids = new HashSet<string>(StringComparer.Ordinal);
            if (notices == null) return result;
            for (int i = 0; i < notices.Count; i++)
            {
                PetNotice notice = notices[i];
                if (notice == null || !ids.Add(notice.Id)) continue;
                result.Add(notice);
            }
            return result;
        }
    }
}
