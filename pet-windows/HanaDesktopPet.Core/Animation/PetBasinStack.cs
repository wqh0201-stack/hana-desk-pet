using System;
using System.Collections.Generic;

namespace HanaDesktopPet.Core
{
    /// <summary>One basin as it should be drawn right now.</summary>
    /// <remarks>
    /// <c>Rise</c> is measured upwards from the base slot's centre, so a renderer in a
    /// top-down coordinate system subtracts it. <c>Slot</c> is the pile position (0 = the
    /// basin resting on the head) and is also the draw order: a higher slot paints over the
    /// one below it.
    /// </remarks>
    public sealed class PetBasinPlacement
    {
        public int Slot { get; private set; }
        public double Rise { get; private set; }
        public double Opacity { get; private set; }

        public PetBasinPlacement(int slot, double rise, double opacity)
        {
            Slot = slot;
            Rise = rise;
            Opacity = opacity;
        }
    }

    /// <summary>
    /// Per-character basin geometry: drawn width, horizontal offset from the character's
    /// centre line, and how far below the artwork's top edge the rim rests. The height is
    /// always derived from the width with the original 117:47 asset ratio, never stretched.
    /// </summary>
    public sealed class PetBasinConfig
    {
        public double Width { get; private set; }
        public double XOffset { get; private set; }
        public double YOffset { get; private set; }

        public PetBasinConfig(double width, double xOffset, double yOffset)
        {
            Width = width;
            XOffset = xOffset;
            YOffset = yOffset;
        }

        /// <summary>
        /// Characters without an explicit row. <c>YOffset</c> has to stay below the natural
        /// height (width / 2.49) or the crown would poke out above the basin.
        /// </summary>
        public static readonly PetBasinConfig Fallback = new PetBasinConfig(92.0, 0.0, 30.0);

        /// <summary>Clamped copy inside the debug-slider ranges.</summary>
        public PetBasinConfig Clamped()
        {
            return new PetBasinConfig(
                PetBasinStack.ClampedWidth(Width),
                PetBasinStack.ClampedXOffset(XOffset),
                PetBasinStack.ClampedYOffset(YOffset));
        }

        public override bool Equals(object obj)
        {
            PetBasinConfig other = obj as PetBasinConfig;
            if (other == null) return false;
            return Math.Abs(other.Width - Width) < 1e-9 &&
                Math.Abs(other.XOffset - XOffset) < 1e-9 &&
                Math.Abs(other.YOffset - YOffset) < 1e-9;
        }

        public override int GetHashCode()
        {
            return Width.GetHashCode() ^ (XOffset.GetHashCode() << 1) ^ (YOffset.GetHashCode() << 2);
        }
    }

    /// <summary>
    /// A pile of metal basins dropped on the character by double clicking.
    /// </summary>
    /// <remarks>
    /// Presentation only: it reads no activity state, writes no pose and owns no timer. The
    /// animator merges <c>NextDeadline</c> into its single wake timer and asks for the
    /// placements of the current monotonic time, so a repeated click cannot restart an
    /// animation and a stale callback cannot resurrect a finished one. Geometry is
    /// per-character and shared with the macOS implementation.
    /// </remarks>
    public sealed class PetBasinStack
    {
        /// <summary>Original asset ratio (117:47, about 2.49:1).</summary>
        public const double AssetRatio = 117.0 / 47.0;

        /// <summary>Vertical distance between two nested basins in the pile.</summary>
        public const double BaseSpacing = 7.0;
        public const int MaxCount = 10;

        public const double WidthMinimum = 60.0;
        public const double WidthMaximum = 120.0;
        public const double XOffsetMinimum = -30.0;
        public const double XOffsetMaximum = 30.0;
        public const double YOffsetMinimum = 10.0;
        public const double YOffsetMaximum = 80.0;

        internal const double BaseDropHeight = 20.0;
        internal const double DropDuration = 0.42;
        internal const double FadeInDuration = 0.08;
        internal const double SettleDuration = 0.18;
        internal const double FadeOutDuration = 0.25;
        internal const double FrameInterval = 1.0 / 60.0;
        public const double BubbleGap = 6.0;

        /// <summary>Built-in per-character rows; the debug panel stores an override on top.</summary>
        /// <remarks>Calibrated 2026-10-22 by user adjustment via the debug panel.</remarks>
        private static readonly Dictionary<string, PetBasinConfig> Configs =
            new Dictionary<string, PetBasinConfig>(StringComparer.Ordinal)
            {
                { "claude", new PetBasinConfig(112.66, -3.44, 43.39) },
                { "gpt", new PetBasinConfig(98.12, -3.06, 42.95) },
                { "deepseek", new PetBasinConfig(112.28, -9.57, 46.07) },
                { "gemini", new PetBasinConfig(107.69, -4.59, 41.61) },
                { "glm", new PetBasinConfig(97.36, -3.44, 37.59) },
                { "deepseek-hoodie", new PetBasinConfig(109.98, -12.63, 52.77) },
                { "gpt-onesie", new PetBasinConfig(112.66, -5.36, 42.50) },
            };

        /// <summary>
        /// Worst case across the slider ranges: the window reserves for this so moving the
        /// debug sliders can never clip the pile or resize the window.
        /// </summary>
        public static readonly PetBasinConfig ReserveConfig =
            new PetBasinConfig(WidthMaximum, 0.0, YOffsetMinimum);

        public static PetBasinConfig ConfigFor(string characterId)
        {
            PetBasinConfig config;
            if (characterId != null && Configs.TryGetValue(characterId, out config)) return config;
            return PetBasinConfig.Fallback;
        }

        public static double ClampedWidth(double width)
        {
            if (Double.IsNaN(width) || Double.IsInfinity(width)) return PetBasinConfig.Fallback.Width;
            if (width < WidthMinimum) return WidthMinimum;
            if (width > WidthMaximum) return WidthMaximum;
            return width;
        }

        public static double ClampedXOffset(double xOffset)
        {
            if (Double.IsNaN(xOffset) || Double.IsInfinity(xOffset)) return 0.0;
            if (xOffset < XOffsetMinimum) return XOffsetMinimum;
            if (xOffset > XOffsetMaximum) return XOffsetMaximum;
            return xOffset;
        }

        public static double ClampedYOffset(double yOffset)
        {
            if (Double.IsNaN(yOffset) || Double.IsInfinity(yOffset)) return PetBasinConfig.Fallback.YOffset;
            if (yOffset < YOffsetMinimum) return YOffsetMinimum;
            if (yOffset > YOffsetMaximum) return YOffsetMaximum;
            return yOffset;
        }

        public static double Width(PetBasinConfig config)
        {
            return ClampedWidth(config == null ? PetBasinConfig.Fallback.Width : config.Width);
        }

        /// <summary>The height always follows the fixed asset ratio; the artwork is not stretched.</summary>
        public static double Height(PetBasinConfig config)
        {
            return Width(config) / AssetRatio;
        }

        /// <summary>Distance from the artwork's top edge down to the centre of the first basin.</summary>
        public static double BaseCenterOffsetBelowArtworkTop(PetBasinConfig config)
        {
            double yOffset = ClampedYOffset(config == null ? PetBasinConfig.Fallback.YOffset : config.YOffset);
            return yOffset - Height(config) / 2.0;
        }

        /// <summary>How far the top of a pile reaches above the artwork's top edge.</summary>
        public static double PileTopRise(int count, PetBasinConfig config)
        {
            if (count <= 0) return 0.0;
            double height = Height(config);
            double yOffset = ClampedYOffset(config == null ? PetBasinConfig.Fallback.YOffset : config.YOffset);
            return Math.Max(0.0, (count - 1) * BaseSpacing + height - yOffset);
        }

        /// <summary>Room above the artwork that a full pile plus the bubble gap must have.</summary>
        public static double RequiredTopPadding(PetBasinConfig config)
        {
            return PileTopRise(MaxCount, config) + BubbleGap;
        }

        /// <summary>Extra room the window must add above the artwork for a full pile.</summary>
        public static double TopReserve(double artworkTopPadding, PetBasinConfig config)
        {
            if (Double.IsNaN(artworkTopPadding) || Double.IsInfinity(artworkTopPadding)) artworkTopPadding = 0.0;
            return Math.Max(0.0, RequiredTopPadding(config) - Math.Max(0.0, artworkTopPadding));
        }

        private sealed class Entry
        {
            public int Id;
            public double SpawnedAt;
        }

        private readonly List<Entry> _entries = new List<Entry>();
        private readonly List<double> _fadingStartedAt = new List<double>();
        private int _nextId;
        private double? _shiftStartedAt;
        private int _shiftCount;

        public int Count { get { return _entries.Count; } }

        /// <summary>
        /// Drops one more basin. At the cap the bottom basin fades out and the rest settle
        /// down one slot, so the pile keeps resting on the head instead of floating.
        /// </summary>
        public void Add(double at)
        {
            double now = SafeTime(at);
            if (_entries.Count >= MaxCount && _entries.Count > 0)
            {
                _entries.RemoveAt(0);
                _fadingStartedAt.Add(now);
                _shiftStartedAt = now;
                _shiftCount = _entries.Count;
            }
            Entry entry = new Entry();
            entry.Id = _nextId;
            entry.SpawnedAt = now;
            _entries.Add(entry);
            _nextId++;
        }

        public void Clear()
        {
            _entries.Clear();
            _fadingStartedAt.Clear();
            _shiftStartedAt = null;
            _shiftCount = 0;
        }

        /// <summary>Draw list for the given time: the fading bottom basin first, then the pile bottom-up.</summary>
        public IList<PetBasinPlacement> Placements(double at, bool reduceMotion)
        {
            double now = SafeTime(at);
            Prune(now);
            List<PetBasinPlacement> result = new List<PetBasinPlacement>(_fadingStartedAt.Count + _entries.Count);
            for (int fade = 0; fade < _fadingStartedAt.Count; fade++)
            {
                double progress = Progress(now - _fadingStartedAt[fade], FadeOutDuration);
                if (progress >= 1.0) continue;
                result.Add(new PetBasinPlacement(0, 0.0, 1.0 - progress));
            }
            for (int index = 0; index < _entries.Count; index++)
            {
                Entry entry = _entries[index];
                double rise = index * BaseSpacing;
                double opacity = 1.0;
                if (!reduceMotion)
                {
                    double elapsed = Math.Max(0.0, now - entry.SpawnedAt);
                    if (elapsed < DropDuration)
                    {
                        // The basin starts above its slot and bounces into place.
                        rise += BaseDropHeight * (1.0 - EaseOutBounce(Progress(elapsed, DropDuration)));
                    }
                    if (index < _shiftCount && _shiftStartedAt.HasValue)
                    {
                        double settle = Progress(now - _shiftStartedAt.Value, SettleDuration);
                        if (settle < 1.0) rise += BaseSpacing * (1.0 - EaseOutCubic(settle));
                    }
                    opacity = Progress(elapsed, FadeInDuration);
                }
                result.Add(new PetBasinPlacement(index, rise, Math.Min(1.0, Math.Max(0.0, opacity))));
            }
            return result;
        }

        /// <summary>Next frame boundary while a drop, settle or fade runs, otherwise null.</summary>
        public double? NextDeadline(double at, bool reduceMotion)
        {
            double now = SafeTime(at);
            Prune(now);
            if (reduceMotion) return null;
            bool animating = _fadingStartedAt.Count > 0;
            if (!animating)
            {
                for (int index = 0; index < _entries.Count; index++)
                {
                    if (now - _entries[index].SpawnedAt < DropDuration)
                    {
                        animating = true;
                        break;
                    }
                }
            }
            if (!animating && _shiftCount > 0 && _shiftStartedAt.HasValue && now - _shiftStartedAt.Value < SettleDuration)
                animating = true;
            if (!animating) return null;
            return now + FrameInterval;
        }

        private void Prune(double now)
        {
            for (int index = _fadingStartedAt.Count - 1; index >= 0; index--)
            {
                if (now - _fadingStartedAt[index] >= FadeOutDuration) _fadingStartedAt.RemoveAt(index);
            }
            if (_shiftStartedAt.HasValue && now - _shiftStartedAt.Value >= SettleDuration)
            {
                _shiftStartedAt = null;
                _shiftCount = 0;
            }
        }

        private static double SafeTime(double value)
        {
            if (Double.IsNaN(value) || Double.IsInfinity(value)) return 0.0;
            return Math.Max(0.0, value);
        }

        private static double Progress(double elapsed, double duration)
        {
            if (duration <= 0.0) return 1.0;
            return Math.Min(1.0, Math.Max(0.0, elapsed / duration));
        }

        private static double EaseOutCubic(double value)
        {
            double inverse = 1.0 - Math.Min(1.0, Math.Max(0.0, value));
            return 1.0 - inverse * inverse * inverse;
        }

        /// <summary>Robert Penner's easeOutBounce: the basin decelerates in three shrinking bounces.</summary>
        private static double EaseOutBounce(double value)
        {
            double x = Math.Min(1.0, Math.Max(0.0, value));
            const double n1 = 7.5625;
            const double d1 = 2.75;
            if (x < 1.0 / d1)
            {
                return n1 * x * x;
            }
            if (x < 2.0 / d1)
            {
                double shifted = x - 1.5 / d1;
                return n1 * shifted * shifted + 0.75;
            }
            if (x < 2.5 / d1)
            {
                double shifted = x - 2.25 / d1;
                return n1 * shifted * shifted + 0.9375;
            }
            {
                double shifted = x - 2.625 / d1;
                return n1 * shifted * shifted + 0.984375;
            }
        }
    }

    /// <summary>
    /// Separates a double click from two single clicks on the character.
    /// </summary>
    /// <remarks>
    /// The caller feeds only clicks that were already classified as clicks (never a drag)
    /// and passes the system double-click interval, so the gesture follows the desktop
    /// setting. A completed double click is consumed, which means a triple click starts a
    /// fresh sequence rather than dropping two basins.
    /// </remarks>
    public struct PetDoubleClickTracker
    {
        private double? _lastClickAt;

        /// <summary>Returns true when this click completes a double click.</summary>
        public bool Register(double time, double interval)
        {
            double now = SafeTime(time);
            double window = SafeInterval(interval);
            if (_lastClickAt.HasValue && now >= _lastClickAt.Value && now - _lastClickAt.Value <= window)
            {
                _lastClickAt = null;
                return true;
            }
            _lastClickAt = now;
            return false;
        }

        public void Reset()
        {
            _lastClickAt = null;
        }

        private static double SafeTime(double value)
        {
            if (Double.IsNaN(value) || Double.IsInfinity(value)) return 0.0;
            return Math.Max(0.0, value);
        }

        private static double SafeInterval(double value)
        {
            if (Double.IsNaN(value) || Double.IsInfinity(value)) return 0.0;
            return Math.Max(0.0, value);
        }
    }
}
