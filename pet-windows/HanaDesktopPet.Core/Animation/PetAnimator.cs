using System;
using System.Collections.Generic;
using System.Linq;

namespace HanaDesktopPet.Core
{
    public sealed class PetPoseLayer
    {
        public string Pose { get; private set; }
        public double Opacity { get; private set; }

        public PetPoseLayer(string pose, double opacity)
        {
            Pose = pose;
            Opacity = opacity;
        }
    }

    public sealed class PetRenderFrame
    {
        public string CharacterId { get; private set; }
        public string Pose { get; private set; }
        public bool Fallback { get; private set; }
        public IReadOnlyList<PetPoseLayer> Layers { get; private set; }
        public double? NextWakeAt { get; private set; }

        public PetRenderFrame(string characterId, string pose, bool fallback,
            IReadOnlyList<PetPoseLayer> layers, double? nextWakeAt)
        {
            CharacterId = characterId;
            Pose = pose;
            Fallback = fallback;
            Layers = layers;
            NextWakeAt = nextWakeAt;
        }
    }

    /// <summary>
    /// Deterministic native artwork animation. All deadlines use caller supplied monotonic
    /// seconds, and only the character's own catalog-listed pose names are returned.
    /// </summary>
    public sealed class PetAnimator
    {
        private const double TapReactionDuration = 0.52;
        internal static readonly string[] PickUpPoseNameValues = new[] { "picked-up", "picked-up-2" };
        internal const double PickUpFrameIntervalValue = 0.16;

        private readonly Func<string, ISet<string>> _availablePoses;
        private PetPoseTimeline _timeline = new PetPoseTimeline();
        private PetMoodTracker _moodTracker = new PetMoodTracker();
        private PetWorkPoseScheduler _workScheduler = new PetWorkPoseScheduler();
        private readonly PetPickUpAnimation _pickUp = new PetPickUpAnimation();
        private PetViewState _lastState;
        private string _currentCharacterId;
        private string _currentSessionId;
        private ISet<string> _currentPoses = new HashSet<string>(StringComparer.Ordinal);
        private double? _lastObservedAt;
        private bool _hasState;
        private bool _isDragging;
        private bool _lastReduceMotion;
        private bool _lastAnimationsEnabled = true;

        public PetAnimator(Func<string, ISet<string>> availablePoses)
        {
            if (availablePoses == null) throw new ArgumentNullException("availablePoses");
            _availablePoses = availablePoses;
        }

        public bool IsDragging { get { return _isDragging; } }

        public PetRenderFrame Update(PetViewState state, double nowSeconds, bool reduceMotion = false, bool animationsEnabled = true)
        {
            if (state == null) throw new ArgumentNullException("state");
            double now = NormalizeTime(nowSeconds);
            PetActivity activity = state.Activity ?? new PetActivity();
            PetSelection selection = state.Selection ?? new PetSelection();
            string characterId = String.IsNullOrEmpty(selection.CharacterId) ? "claude" : selection.CharacterId;
            string status = NormalizeStatus(state.DisplayStatus);
            string hint = status == "error" ? null : NormalizeHint(state.DisplayHint);
            string sessionId = activity.SessionId;

            bool roleChanged = _hasState && _currentCharacterId != characterId;
            bool sessionChanged = _hasState && _currentSessionId != sessionId;
            ISet<string> poses = GetAvailablePoses(characterId);
            bool poseCatalogChanged = _hasState && _currentCharacterId == characterId && !_currentPoses.SetEquals(poses);

            if (roleChanged)
            {
                _timeline = new PetPoseTimeline();
                _isDragging = false;
                _pickUp.End();
            }
            if (sessionChanged)
            {
                _workScheduler = new PetWorkPoseScheduler();
                _moodTracker.Reset();
                _timeline.InterruptReaction(now);
                _isDragging = false;
                _pickUp.End();
            }
            else if (roleChanged)
            {
                WorkPoseSet changedWorkPoses = PetPosePlanner.WorkPoses(characterId, poses);
                _workScheduler.RebuildRhythm(changedWorkPoses, now);
            }
            else if (poseCatalogChanged)
            {
                _timeline = new PetPoseTimeline();
                _isDragging = false;
                _pickUp.End();
                WorkPoseSet changedWorkPoses = PetPosePlanner.WorkPoses(characterId, poses);
                _workScheduler.RebuildRhythm(changedWorkPoses, now);
            }

            if (!animationsEnabled && _isDragging)
            {
                _isDragging = false;
                _pickUp.End();
            }

            _currentCharacterId = characterId;
            _currentSessionId = sessionId;
            _currentPoses = poses;
            _hasState = true;
            _lastState = state;
            _lastReduceMotion = reduceMotion;
            _lastAnimationsEnabled = animationsEnabled;

            string toolName = state.AppConnected ? activity.ToolName : null;
            PetMood? mood = _moodTracker.Update(status, toolName, hint, activity.LastActivityAt, now);
            string preferredPose = PetPosePlanner.PreferredPose(status, toolName, hint);
            string workPose = PetPosePlanner.Resolve(preferredPose, poses);
            string realPose;
            bool fallback;
            bool hasPriorityState;
            if (hint == null && mood.HasValue)
            {
                realPose = PetMoodPoseResolver.Resolve(mood.Value, workPose, poses);
                fallback = realPose != PetMoodPoseResolver.PrimaryPose(mood.Value);
                hasPriorityState = true;
            }
            else
            {
                realPose = workPose;
                fallback = realPose != preferredPose;
                hasPriorityState = false;
            }

            WorkPoseSet workPoses = PetPosePlanner.WorkPoses(characterId, poses);
            SchedulerTick workTick = _workScheduler.Update(
                sessionId,
                _moodTracker.ContinuousWorkStart,
                status,
                hint,
                hasPriorityState,
                animationsEnabled && !reduceMotion,
                _timeline.HasActiveReaction,
                realPose,
                workPoses,
                now);
            string basePose = workTick.Pose ?? realPose;
            bool reportedFallback = fallback && basePose == realPose;

            string pickUpPose = _pickUp.PoseAt(now, poses, reduceMotion);
            bool pickUpOwnsArtwork = _isDragging && pickUpPose != null;
            string displayedPose = pickUpOwnsArtwork ? pickUpPose : basePose;

            IList<PetPoseLayer> layers = _timeline.Update(
                status,
                displayedPose,
                poses,
                reduceMotion,
                animationsEnabled && (!mood.HasValue || mood.Value != PetMood.Sleeping) && hint == null && !pickUpOwnsArtwork,
                hint,
                pickUpOwnsArtwork,
                now);

            double? nextWakeAt = null;
            if (animationsEnabled)
            {
                List<double> deadlines = new List<double>();
                AddDeadline(deadlines, _timeline.NextWakeAt(now));
                AddDeadline(deadlines, _moodTracker.NextDeadline(now));
                AddDeadline(deadlines, _workScheduler.NextDeadline(now));
                AddDeadline(deadlines, _pickUp.NextDeadline(now, reduceMotion));
                if (deadlines.Count > 0) nextWakeAt = deadlines.Min();
            }

            string targetPose = _timeline.TargetPose;
            bool targetFallback = reportedFallback;
            if (_timeline.HasVisibleReaction)
                targetFallback = _timeline.ReactionFallback;
            else if (targetPose != displayedPose)
                targetFallback = false;

            return new PetRenderFrame(characterId, targetPose, !pickUpOwnsArtwork && targetFallback,
                new List<PetPoseLayer>(layers).AsReadOnly(), nextWakeAt);
        }

        public void Tap(double nowSeconds)
        {
            double now = NormalizeTime(nowSeconds);
            if (!_hasState) return;
            string reactionPose = null;
            bool reactionFallback = false;
            if (_currentPoses.Contains("happy") || _currentPoses.Contains("happy-2"))
            {
                reactionPose = PetPosePlanner.Resolve(PetPosePlanner.PreferredPose("success", null, null), _currentPoses);
                reactionFallback = reactionPose != "happy";
            }
            _timeline.BeginReaction(reactionPose, reactionFallback, TapReactionDuration, now);
            RefreshLastState(now);
        }

        public void BeginPointer(double nowSeconds)
        {
            double now = NormalizeTime(nowSeconds);
            _timeline.InterruptTransition(now);
            RefreshLastState(now);
        }

        public void BeginDrag(double nowSeconds)
        {
            double now = NormalizeTime(nowSeconds);
            if (!_hasState || _isDragging) return;
            _isDragging = true;
            _pickUp.Begin(now);
            RefreshLastState(now);
        }

        public void EndDrag(double nowSeconds)
        {
            double now = NormalizeTime(nowSeconds);
            if (!_isDragging) return;
            _isDragging = false;
            _pickUp.End();
            RefreshLastState(now);
        }

        public void CancelInteraction(double nowSeconds)
        {
            double now = NormalizeTime(nowSeconds);
            _isDragging = false;
            _pickUp.End();
            _timeline.InterruptTransition(now);
            RefreshLastState(now);
        }

        private void RefreshLastState(double at)
        {
            if (_lastState != null) Update(_lastState, at, _lastReduceMotion, _lastAnimationsEnabled);
        }

        private ISet<string> GetAvailablePoses(string characterId)
        {
            ISet<string> source = _availablePoses(characterId);
            return source == null
                ? new HashSet<string>(StringComparer.Ordinal)
                : new HashSet<string>(source, StringComparer.Ordinal);
        }

        private double NormalizeTime(double value)
        {
            double safe = IsFinite(value) ? Math.Max(0, value) : 0;
            double normalized = Math.Max(safe, _lastObservedAt.HasValue ? _lastObservedAt.Value : safe);
            _lastObservedAt = normalized;
            return normalized;
        }

        private static string NormalizeStatus(string status)
        {
            switch (status)
            {
                case "idle":
                case "working":
                case "tool":
                case "success":
                case "error": return status;
                default: return "idle";
            }
        }

        private static string NormalizeHint(string hint)
        {
            switch (hint)
            {
                case "confirming":
                case "compacting":
                case "interrupted": return hint;
                default: return null;
            }
        }

        private static void AddDeadline(ICollection<double> deadlines, double? deadline)
        {
            if (deadline.HasValue && IsFinite(deadline.Value)) deadlines.Add(deadline.Value);
        }

        private static bool IsFinite(double value) { return !Double.IsNaN(value) && !Double.IsInfinity(value); }
    }

    internal sealed class PetPickUpAnimation
    {
        private double? _startedAt;
        internal bool IsActive { get { return _startedAt.HasValue; } }

        internal void Begin(double at)
        {
            if (!_startedAt.HasValue) _startedAt = SafeTime(at);
        }

        internal void End() { _startedAt = null; }

        internal int FrameIndex(double at, bool reduceMotion)
        {
            if (!_startedAt.HasValue || reduceMotion) return 0;
            double elapsed = Math.Max(0, SafeTime(at) - _startedAt.Value);
            long step = (long)Math.Floor(elapsed / PetAnimator.PickUpFrameIntervalValue);
            return (int)(step % PickUpPoseCount);
        }

        internal string PoseAt(double at, ISet<string> available, bool reduceMotion)
        {
            if (!_startedAt.HasValue || available == null) return null;
            List<string> ordered = PetAnimator.PickUpPoseNameValues.Where(available.Contains).ToList();
            if (ordered.Count == 0) return null;
            if (reduceMotion) return ordered[0];
            return ordered[FrameIndex(at, false) % ordered.Count];
        }

        internal double? NextDeadline(double at, bool reduceMotion)
        {
            if (!_startedAt.HasValue || reduceMotion) return null;
            double now = SafeTime(at);
            if (now < _startedAt.Value) return _startedAt.Value + PetAnimator.PickUpFrameIntervalValue;
            double elapsed = now - _startedAt.Value;
            double completed = Math.Floor(elapsed / PetAnimator.PickUpFrameIntervalValue);
            double next = _startedAt.Value + (completed + 1) * PetAnimator.PickUpFrameIntervalValue;
            return next > now ? next : now + PetAnimator.PickUpFrameIntervalValue;
        }

        private const int PickUpPoseCount = 2;
        private static double SafeTime(double time) { return Double.IsNaN(time) || Double.IsInfinity(time) ? 0 : Math.Max(0, time); }
    }
}
