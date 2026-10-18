using System;
using System.Collections.Generic;
using System.Linq;

namespace HanaDesktopPet.Core
{
    internal sealed class PetPoseTimeline
    {
        private const double CrossfadeDuration = 0.20;
        private const double ReducedMotionCrossfadeDuration = 0.08;
        private static readonly double[] IdleIntervals = new[] { 5.8, 6.6, 5.4, 7.2 };
        private const double BlinkDuration = 0.18;
        private const int MaximumSourceLayers = 3;

        private bool _isInitialized;
        private string _status = "idle";
        private string _hint;
        private string _basePose = "idle";
        private ISet<string> _availablePoseNames = new HashSet<string>(StringComparer.Ordinal) { "idle" };
        private bool _reduceMotion;
        private bool _allowsIdleAnimation = true;

        private string _idlePose;
        private int _idleCandidateIndex;
        private int _idleScheduleIndex;
        private double? _nextIdleAt;
        private double? _blinkUntil;

        private string _reactionPose;
        private bool _reactionFallback;
        private double? _reactionEndsAt;

        private string _settledPose = "idle";
        private List<PetPoseLayer> _transitionSource = new List<PetPoseLayer>();
        private string _transitionTarget;
        private double _transitionStartedAt;
        private double _transitionDuration = CrossfadeDuration;

        internal bool IsTransitioning { get { return _transitionTarget != null; } }
        internal bool HasActiveReaction { get { return _reactionEndsAt.HasValue; } }
        internal bool HasVisibleReaction { get { return _reactionEndsAt.HasValue && _reactionPose != null; } }
        internal bool ReactionFallback { get { return HasVisibleReaction && _reactionFallback; } }
        internal string TargetPose { get { return EffectivePose; } }

        internal IList<PetPoseLayer> Update(
            string status,
            string basePose,
            ISet<string> availablePoseNames,
            bool reduceMotion,
            bool allowsIdleAnimation,
            string hint,
            bool immediate,
            double at)
        {
            double now = SafeTime(at);
            bool firstUpdate = !_isInitialized;
            bool stateChanged = _status != status || _basePose != basePose || _hint != hint;
            bool motionChanged = _reduceMotion != reduceMotion;
            bool idleAnimationChanged = _allowsIdleAnimation != allowsIdleAnimation;

            _status = status;
            _hint = hint;
            _basePose = basePose;
            _availablePoseNames = availablePoseNames ?? new HashSet<string>(StringComparer.Ordinal);
            _reduceMotion = reduceMotion;
            _allowsIdleAnimation = allowsIdleAnimation;
            _isInitialized = true;

            if (firstUpdate)
            {
                _settledPose = basePose;
                ResetIdleCycle(now, status == "idle" && !reduceMotion && allowsIdleAnimation);
            }
            else if (stateChanged || idleAnimationChanged)
            {
                _reactionPose = null;
                _reactionFallback = false;
                _reactionEndsAt = null;
                ResetIdleCycle(now, status == "idle" && !reduceMotion && allowsIdleAnimation);
            }
            else if (motionChanged)
            {
                if (reduceMotion)
                {
                    _idlePose = null;
                    _nextIdleAt = null;
                    _blinkUntil = null;
                    _reactionPose = null;
                    _reactionFallback = false;
                    _reactionEndsAt = null;
                }
                else if (status == "idle")
                {
                    ScheduleNextIdle(now);
                }
            }

            if (status == "idle" && !reduceMotion && allowsIdleAnimation && !_nextIdleAt.HasValue && !_blinkUntil.HasValue)
                ScheduleNextIdle(now);
            if (_idlePose != null && !_availablePoseNames.Contains(_idlePose)) _idlePose = null;

            Retarget(EffectivePose, now, immediate);
            return Advance(now);
        }

        internal IList<PetPoseLayer> BeginReaction(string pose, bool fallback, double duration, double at)
        {
            double now = SafeTime(at);
            if (!_isInitialized) return VisibleLayers(now);
            double safeDuration = IsFinite(duration) ? Math.Max(0, duration) : 0;
            _reactionPose = pose;
            _reactionFallback = fallback;
            _reactionEndsAt = now + safeDuration;
            Retarget(EffectivePose, now, false);
            return Advance(now);
        }

        internal IList<PetPoseLayer> InterruptReaction(double at)
        {
            double now = SafeTime(at);
            if (!_reactionEndsAt.HasValue) return Advance(now);
            _reactionPose = null;
            _reactionFallback = false;
            _reactionEndsAt = null;
            Retarget(EffectivePose, now, false);
            return Advance(now);
        }

        internal IList<PetPoseLayer> InterruptTransition(double at)
        {
            double now = SafeTime(at);
            _reactionPose = null;
            _reactionFallback = false;
            _reactionEndsAt = null;
            _settledPose = EffectivePose;
            _transitionTarget = null;
            _transitionSource.Clear();
            return VisibleLayers(now);
        }

        internal IList<PetPoseLayer> Advance(double at)
        {
            double now = SafeTime(at);
            if (_reactionEndsAt.HasValue && now >= _reactionEndsAt.Value)
            {
                double endsAt = _reactionEndsAt.Value;
                _reactionPose = null;
                _reactionFallback = false;
                _reactionEndsAt = null;
                Retarget(EffectivePose, endsAt, false);
            }

            if (_blinkUntil.HasValue && now >= _blinkUntil.Value)
            {
                double blinkUntil = _blinkUntil.Value;
                _blinkUntil = null;
                if (_status == "idle" && !_reduceMotion && _allowsIdleAnimation) ScheduleNextIdle(blinkUntil);
                Retarget(EffectivePose, blinkUntil, false);
            }
            else if (_nextIdleAt.HasValue && now >= _nextIdleAt.Value && _status == "idle" &&
                     !_reduceMotion && _allowsIdleAnimation && !_reactionEndsAt.HasValue)
            {
                StartNextIdlePose(now);
            }

            Retarget(EffectivePose, now, false);
            if (_transitionTarget != null && now >= _transitionStartedAt + _transitionDuration)
            {
                _settledPose = _transitionTarget;
                _transitionTarget = null;
                _transitionSource.Clear();
            }
            return VisibleLayers(now);
        }

        internal IList<PetPoseLayer> VisibleLayers(double at)
        {
            double now = SafeTime(at);
            if (_transitionTarget == null) return new List<PetPoseLayer> { new PetPoseLayer(_settledPose, 1) };
            double rawProgress = _transitionDuration <= 0 ? 1 :
                Math.Min(1, Math.Max(0, (now - _transitionStartedAt) / _transitionDuration));
            double progress = rawProgress * rawProgress * (3 - 2 * rawProgress);
            Dictionary<string, double> weights = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (PetPoseLayer layer in _transitionSource)
                AddWeight(weights, layer.Pose, layer.Opacity * (1 - progress));
            AddWeight(weights, _transitionTarget, progress);
            IList<PetPoseLayer> layers = NormalizeLayers(weights);
            // Keep the requested destination represented even on the zero-opacity first
            // frame. The UI can then report the timeline target without mistaking the
            // still-visible source layer for a missing-art fallback.
            if (!layers.Any(layer => layer.Pose == _transitionTarget))
                layers.Add(new PetPoseLayer(_transitionTarget, 0));
            return layers;
        }

        internal double? NextWakeAt(double at)
        {
            double now = SafeTime(at);
            if (IsTransitioning)
            {
                double end = _transitionStartedAt + _transitionDuration;
                return Math.Min(end, now + 1.0 / 30.0);
            }
            if (_reactionEndsAt.HasValue) return _reactionEndsAt;
            if (_nextIdleAt.HasValue) return _nextIdleAt;
            return null;
        }

        private string EffectivePose
        {
            get
            {
                if (_reactionEndsAt.HasValue && _reactionPose != null) return _reactionPose;
                if (_status == "idle" && !_reduceMotion && _allowsIdleAnimation)
                {
                    if (_blinkUntil.HasValue) return "idle-blink";
                    if (_idlePose != null) return _idlePose;
                }
                return _basePose;
            }
        }

        private void ResetIdleCycle(double at, bool schedule)
        {
            _idlePose = null;
            _idleCandidateIndex = 0;
            _idleScheduleIndex = 0;
            _blinkUntil = null;
            _nextIdleAt = null;
            if (schedule) ScheduleNextIdle(at);
        }

        private void ScheduleNextIdle(double at)
        {
            if (_status != "idle" || _reduceMotion || !_allowsIdleAnimation)
            {
                _nextIdleAt = null;
                return;
            }
            if (AvailableIdleCandidates.Count == 0)
            {
                _nextIdleAt = null;
                return;
            }
            double interval = IdleIntervals[_idleScheduleIndex % IdleIntervals.Length];
            _nextIdleAt = at + interval;
            _idleScheduleIndex++;
        }

        private void StartNextIdlePose(double at)
        {
            IList<string> candidates = AvailableIdleCandidates;
            if (candidates.Count == 0)
            {
                _nextIdleAt = null;
                return;
            }
            string candidate = candidates[_idleCandidateIndex % candidates.Count];
            _idleCandidateIndex++;
            if (candidate == "idle-blink")
            {
                _blinkUntil = at + BlinkDuration;
                _nextIdleAt = _blinkUntil;
            }
            else
            {
                _idlePose = candidate;
                ScheduleNextIdle(at);
            }
        }

        private IList<string> AvailableIdleCandidates
        {
            get
            {
                List<string> candidates = new List<string>();
                string[] ordered = new[] { "idle-2", "idle-3", "idle-blink" };
                foreach (string candidate in ordered)
                    if (_availablePoseNames.Contains(candidate)) candidates.Add(candidate);
                return candidates;
            }
        }

        private void Retarget(string pose, double at, bool immediate)
        {
            if (_transitionTarget == pose) return;
            if (_transitionTarget == null && _settledPose == pose) return;
            if (immediate)
            {
                _settledPose = pose;
                _transitionSource.Clear();
                _transitionTarget = null;
                return;
            }

            _transitionSource = TrimmedLayers(VisibleLayers(at), MaximumSourceLayers);
            if (_transitionSource.Count == 1 && _transitionSource[0].Pose == pose && _transitionSource[0].Opacity >= 0.999)
            {
                _settledPose = pose;
                _transitionSource.Clear();
                _transitionTarget = null;
                return;
            }
            _transitionTarget = pose;
            _transitionStartedAt = at;
            _transitionDuration = _reduceMotion ? ReducedMotionCrossfadeDuration : CrossfadeDuration;
        }

        private static List<PetPoseLayer> TrimmedLayers(IList<PetPoseLayer> layers, int maximumCount)
        {
            Dictionary<string, double> combined = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (PetPoseLayer layer in layers) AddWeight(combined, layer.Pose, layer.Opacity);
            List<PetPoseLayer> normalized = NormalizeLayers(combined).ToList();
            List<PetPoseLayer> retained = normalized
                .OrderByDescending(layer => layer.Opacity)
                .ThenBy(layer => layer.Pose, StringComparer.Ordinal)
                .Take(Math.Max(1, maximumCount)).ToList();
            double sum = retained.Sum(layer => layer.Opacity);
            if (sum <= 0) return new List<PetPoseLayer>();
            return retained.Select(layer => new PetPoseLayer(layer.Pose, layer.Opacity / sum))
                .OrderBy(layer => layer.Pose, StringComparer.Ordinal).ToList();
        }

        private static IList<PetPoseLayer> NormalizeLayers(IDictionary<string, double> weights)
        {
            List<KeyValuePair<string, double>> positive = weights.Where(pair => pair.Value > 0.0001).ToList();
            double sum = positive.Sum(pair => pair.Value);
            if (sum <= 0) return new List<PetPoseLayer>();
            return positive.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .Select(pair => new PetPoseLayer(pair.Key, pair.Value / sum)).ToList();
        }

        private static void AddWeight(IDictionary<string, double> weights, string pose, double weight)
        {
            if (pose == null) return;
            double existing;
            weights.TryGetValue(pose, out existing);
            weights[pose] = existing + weight;
        }

        private static double SafeTime(double time) { return IsFinite(time) ? time : 0; }
        private static bool IsFinite(double value) { return !Double.IsNaN(value) && !Double.IsInfinity(value); }
    }
}
