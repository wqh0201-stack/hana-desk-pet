using System;
using System.Collections.Generic;
using System.Linq;

namespace HanaDesktopPet.Core
{
    internal sealed class PetWorkPoseIdentity : IEquatable<PetWorkPoseIdentity>
    {
        internal PetWorkPoseIdentity(string sessionId, double workSegmentStart)
        {
            SessionId = sessionId;
            WorkSegmentStart = workSegmentStart;
        }

        internal string SessionId { get; private set; }
        internal double WorkSegmentStart { get; private set; }

        public bool Equals(PetWorkPoseIdentity other)
        {
            return other != null && SessionId == other.SessionId && WorkSegmentStart.Equals(other.WorkSegmentStart);
        }

        public override bool Equals(object obj) { return Equals(obj as PetWorkPoseIdentity); }
        public override int GetHashCode() { return (SessionId ?? String.Empty).GetHashCode() * 397 ^ WorkSegmentStart.GetHashCode(); }
    }

    internal sealed class PetWorkPoseScheduler
    {
        internal const double ThinkingHold = 6;
        internal const double BusyLeftHold = 4;
        internal const double ThinkingVariantHold = 7;
        internal const double BusyRightHold = 5;
        internal const double ToolMinimumVisible = 2.0;
        internal const double ToolReturnGrace = 1.2;

        private enum SchedulerMode { Dormant, Rhythm, Tool, Grace }

        private sealed class Phase
        {
            internal Phase(string pose, double duration) { Pose = pose; Duration = duration; }
            internal string Pose { get; private set; }
            internal double Duration { get; private set; }
        }

        private PetWorkPoseIdentity _identity;
        private int _generation;
        private SchedulerMode _mode;
        private double? _cycleStartedAt;
        private List<Phase> _phases = new List<Phase>();
        private string _thinkingPose = "thinking";
        private WorkPoseSet _latestWorkPoses;
        private double? _pauseStartedAt;
        private string _toolPose;
        private double? _toolEnteredAt;
        private string _gracePose;
        private double? _graceEndsAt;
        private double? _lastObservedAt;

        internal int CurrentGeneration { get { return _generation; } }
        internal PetWorkPoseIdentity CurrentIdentity { get { return _identity; } }

        internal bool Matches(PetWorkPoseIdentity identity, int generation)
        {
            return Object.Equals(_identity, identity) && _generation == generation;
        }

        internal void BeginInteraction(double at)
        {
            if (_pauseStartedAt.HasValue) return;
            _pauseStartedAt = NormalizeTime(at);
        }

        internal void EndInteraction(double at)
        {
            if (!_pauseStartedAt.HasValue) return;
            double pauseStart = _pauseStartedAt.Value;
            double now = NormalizeTime(Math.Max(at, pauseStart));
            if (_cycleStartedAt.HasValue)
                _cycleStartedAt = _cycleStartedAt.Value + (now - pauseStart);
            _pauseStartedAt = null;
        }

        internal SchedulerTick Update(
            string sessionId,
            double? workSegmentStart,
            string status,
            string hint,
            bool hasPriorityState,
            bool allowsAutonomousRotation,
            bool interactionIsActive,
            string realPose,
            WorkPoseSet workPoses,
            double at)
        {
            double now = NormalizeTime(at);
            bool contextChanged = false;
            if (workPoses != null) _latestWorkPoses = workPoses;

            PetWorkPoseIdentity resolvedIdentity = null;
            if ((status == "working" || status == "tool") && workSegmentStart.HasValue &&
                IsFinite(workSegmentStart.Value) && workSegmentStart.Value >= 0)
                resolvedIdentity = new PetWorkPoseIdentity(sessionId ?? String.Empty, workSegmentStart.Value);

            if (!Object.Equals(resolvedIdentity, _identity))
            {
                _identity = resolvedIdentity;
                contextChanged = true;
                EnterDormant();
            }

            if (interactionIsActive) BeginInteraction(now);
            else EndInteraction(now);

            bool suppressed = hint != null || hasPriorityState || !allowsAutonomousRotation;
            switch (status)
            {
                case "tool":
                    if (suppressed)
                    {
                        if (_mode != SchedulerMode.Dormant)
                        {
                            EnterDormant();
                            contextChanged = true;
                        }
                    }
                    else if (_mode != SchedulerMode.Tool || _toolPose != realPose)
                    {
                        _toolPose = realPose;
                        _toolEnteredAt = now;
                        _gracePose = null;
                        _graceEndsAt = null;
                        _cycleStartedAt = null;
                        _phases.Clear();
                        _mode = SchedulerMode.Tool;
                        contextChanged = true;
                    }
                    break;

                case "working":
                    if (suppressed)
                    {
                        if (_mode != SchedulerMode.Dormant)
                        {
                            EnterDormant();
                            contextChanged = true;
                        }
                    }
                    else if (_toolPose != null && _toolEnteredAt.HasValue)
                    {
                        double endsAt = Math.Max(_toolEnteredAt.Value + ToolMinimumVisible, now + ToolReturnGrace);
                        _gracePose = _toolPose;
                        _graceEndsAt = endsAt;
                        _toolPose = null;
                        _toolEnteredAt = null;
                        _cycleStartedAt = null;
                        _phases.Clear();
                        _mode = SchedulerMode.Grace;
                        contextChanged = true;
                    }
                    else if (_mode == SchedulerMode.Grace && _graceEndsAt.HasValue && now >= _graceEndsAt.Value)
                    {
                        EnterDormant();
                        contextChanged = true;
                    }

                    if (_mode == SchedulerMode.Dormant && !suppressed && workPoses != null && workPoses.SupportsRhythm)
                    {
                        _phases = BuildPhases(workPoses);
                        _thinkingPose = workPoses.Thinking;
                        _cycleStartedAt = now;
                        _mode = SchedulerMode.Rhythm;
                        contextChanged = true;
                    }
                    break;

                default:
                    if (_mode != SchedulerMode.Dormant || _toolPose != null || _graceEndsAt.HasValue)
                    {
                        EnterDormant();
                        contextChanged = true;
                    }
                    break;
            }

            if (contextChanged) _generation = _generation == Int32.MaxValue ? 0 : _generation + 1;
            _lastObservedAt = now;
            return Tick(now, false);
        }

        internal SchedulerTick Advance(PetWorkPoseIdentity expectedIdentity, int expectedGeneration, double at)
        {
            if (!Matches(expectedIdentity, expectedGeneration)) return SchedulerTick.Invalidated;
            double now = NormalizeTime(at);
            if (_mode == SchedulerMode.Grace && _graceEndsAt.HasValue && now >= _graceEndsAt.Value)
            {
                EnterDormant();
                if (_latestWorkPoses != null && _latestWorkPoses.SupportsRhythm)
                {
                    _phases = BuildPhases(_latestWorkPoses);
                    _thinkingPose = _latestWorkPoses.Thinking;
                    _cycleStartedAt = now;
                    _mode = SchedulerMode.Rhythm;
                }
                _generation = _generation == Int32.MaxValue ? 0 : _generation + 1;
            }
            _lastObservedAt = now;
            return Tick(now, false);
        }

        internal string CurrentPose(double at)
        {
            double now = Math.Max(NormalizeTime(at), _lastObservedAt.HasValue ? _lastObservedAt.Value : 0);
            switch (_mode)
            {
                case SchedulerMode.Grace:
                    return _gracePose != null && _graceEndsAt.HasValue && now < _graceEndsAt.Value ? _gracePose : null;
                case SchedulerMode.Rhythm:
                    Phase phase = CurrentPhase(now);
                    return phase != null ? phase.Pose : _thinkingPose;
                default: return null;
            }
        }

        internal double? NextDeadline(double at)
        {
            double now = Math.Max(NormalizeTime(at), _lastObservedAt.HasValue ? _lastObservedAt.Value : 0);
            if (_mode == SchedulerMode.Dormant || _mode == SchedulerMode.Tool) return null;
            if (_mode == SchedulerMode.Grace)
                return _graceEndsAt.HasValue && _graceEndsAt.Value > now ? _graceEndsAt : null;
            if (_pauseStartedAt.HasValue || !_cycleStartedAt.HasValue || _phases.Count == 0) return null;
            double cycle = CycleDuration(_phases);
            if (cycle <= 0) return null;
            double elapsed = Math.Max(0, now - _cycleStartedAt.Value);
            double completedCycles = Math.Floor(elapsed / cycle);
            double cursor = _cycleStartedAt.Value + completedCycles * cycle;
            foreach (Phase phase in _phases)
            {
                cursor += phase.Duration;
                if (cursor > now) return cursor;
            }
            return cursor + cycle;
        }

        internal SchedulerTick RebuildRhythm(WorkPoseSet workPoses, double at)
        {
            double now = NormalizeTime(at);
            if (_mode == SchedulerMode.Grace)
            {
                // The grace pose belongs to the former character's resolved tool artwork.
                // Drop it during an outfit/catalog change; the following Update starts the
                // current character's rhythm from its own thinking pose without resetting mood time.
                _latestWorkPoses = workPoses;
                EnterDormant();
                _generation = _generation == Int32.MaxValue ? 0 : _generation + 1;
                _lastObservedAt = now;
                return Tick(now, false);
            }
            if (_mode == SchedulerMode.Rhythm)
            {
                if (workPoses == null || !workPoses.SupportsRhythm)
                {
                    EnterDormant();
                    _generation = _generation == Int32.MaxValue ? 0 : _generation + 1;
                    _lastObservedAt = now;
                    return Tick(now, false);
                }
                _phases = BuildPhases(workPoses);
                _thinkingPose = workPoses.Thinking;
                _cycleStartedAt = now;
                _generation = _generation == Int32.MaxValue ? 0 : _generation + 1;
            }
            _lastObservedAt = now;
            return Tick(now, false);
        }

        private void EnterDormant()
        {
            _mode = SchedulerMode.Dormant;
            _cycleStartedAt = null;
            _phases.Clear();
            _pauseStartedAt = null;
            _toolPose = null;
            _toolEnteredAt = null;
            _gracePose = null;
            _graceEndsAt = null;
        }

        private SchedulerTick Tick(double now, bool discarded)
        {
            return new SchedulerTick(CurrentPose(now), _generation, _identity, NextDeadline(now), discarded);
        }

        private Phase CurrentPhase(double now)
        {
            if (_phases.Count == 0 || !_cycleStartedAt.HasValue) return null;
            double effectiveNow = _pauseStartedAt.HasValue ? _pauseStartedAt.Value : now;
            double elapsed = Math.Max(0, effectiveNow - _cycleStartedAt.Value);
            double cycle = CycleDuration(_phases);
            if (cycle <= 0) return null;
            double offset = elapsed % cycle;
            foreach (Phase phase in _phases)
            {
                if (offset < phase.Duration) return phase;
                offset -= phase.Duration;
            }
            return _phases[_phases.Count - 1];
        }

        private static List<Phase> BuildPhases(WorkPoseSet workPoses)
        {
            string[] poses = new[] { workPoses.Thinking, workPoses.BusyLeft, workPoses.ThinkingVariant, workPoses.BusyRight };
            double[] durations = new[] { ThinkingHold, BusyLeftHold, ThinkingVariantHold, BusyRightHold };
            List<Phase> built = new List<Phase>();
            for (int i = 0; i < poses.Length; i++)
            {
                if (built.Count == 0 || poses[i] != built[built.Count - 1].Pose)
                    built.Add(new Phase(poses[i], durations[i]));
            }
            while (built.Count > 1 && built[built.Count - 1].Pose == built[0].Pose)
                built.RemoveAt(built.Count - 1);
            return built;
        }

        private static double CycleDuration(IList<Phase> phases)
        {
            return phases.Sum(phase => phase.Duration);
        }

        private double NormalizeTime(double time)
        {
            double safe = IsFinite(time) ? Math.Max(0, time) : 0;
            return Math.Max(safe, _lastObservedAt.HasValue ? _lastObservedAt.Value : safe);
        }

        private static bool IsFinite(double value) { return !Double.IsNaN(value) && !Double.IsInfinity(value); }
    }

    internal sealed class SchedulerTick
    {
        internal SchedulerTick(string pose, int generation, PetWorkPoseIdentity identity, double? nextDeadline, bool discardedStaleTick)
        {
            Pose = pose;
            Generation = generation;
            Identity = identity;
            NextDeadline = nextDeadline;
            DiscardedStaleTick = discardedStaleTick;
        }

        internal string Pose { get; private set; }
        internal int Generation { get; private set; }
        internal PetWorkPoseIdentity Identity { get; private set; }
        internal double? NextDeadline { get; private set; }
        internal bool DiscardedStaleTick { get; private set; }

        internal static SchedulerTick Invalidated
        {
            get { return new SchedulerTick(null, 0, null, null, true); }
        }
    }
}
