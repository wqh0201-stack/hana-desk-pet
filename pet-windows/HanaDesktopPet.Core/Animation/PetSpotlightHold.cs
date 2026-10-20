using System;

namespace HanaDesktopPet.Core
{
    /// <summary>
    /// A display-only hold for an asynchronous tool that has already returned. The
    /// console reports when a drawing tool was called, never that it is still running;
    /// this type only turns that timestamp into a local deadline for the artwork.
    /// </summary>
    internal sealed class PetSpotlightHold
    {
        internal const double DrawingHold = 4.0;

        private long? _lastSpotlightAt;
        private double? _endsAt;

        internal void Update(PetSpotlight spotlight, double now, long wallNowMs)
        {
            if (spotlight == null || spotlight.Kind != "drawing" || spotlight.At <= 0)
            {
                _lastSpotlightAt = null;
                _endsAt = null;
                return;
            }
            if (_lastSpotlightAt.HasValue && _lastSpotlightAt.Value == spotlight.At) return;
            _lastSpotlightAt = spotlight.At;
            double remaining = (spotlight.At + DrawingHold * 1000.0 - wallNowMs) / 1000.0;
            if (remaining > 0 && remaining <= DrawingHold)
                _endsAt = Math.Max(0, now) + remaining;
            else
                _endsAt = null;
        }

        internal bool IsActive(double now)
        {
            return _endsAt.HasValue && Math.Max(0, now) < _endsAt.Value;
        }

        internal double? NextDeadline(double now)
        {
            if (!IsActive(now)) return null;
            return _endsAt;
        }

        internal void Reset()
        {
            _lastSpotlightAt = null;
            _endsAt = null;
        }
    }
}
