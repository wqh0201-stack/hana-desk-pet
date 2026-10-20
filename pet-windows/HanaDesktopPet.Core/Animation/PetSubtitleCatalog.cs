using System;
using System.Collections.Generic;
using System.IO;
using System.Web.Script.Serialization;

namespace HanaDesktopPet.Core
{
    /// <summary>
    /// The bundled subtitle table: one or two original lines per character and logical
    /// state. It is a native-layer resource, not a protocol field. Which state applies is
    /// decided by the pose that is actually on screen, so no session content is read here.
    /// The wording is original to this project; no upstream CrossPet line is reused.
    /// </summary>
    internal sealed class PetSubtitleCatalog
    {
        internal const int MaximumLineCharacters = 120;
        private const int MaximumTableBytes = 512 * 1024;

        private readonly string[] _stateOrder;
        private readonly Dictionary<string, string> _poseStates;
        private readonly Dictionary<string, double> _dwell;
        private readonly Dictionary<string, Dictionary<string, string[]>> _lines;
        private readonly string[] _roles;
        private readonly string[] _unreachableStates;
        private readonly double _minDwellSeconds;

        internal string[] StateOrder { get { return (string[])_stateOrder.Clone(); } }
        internal Dictionary<string, string> PoseStates { get { return new Dictionary<string, string>(_poseStates); } }
        internal string[] Roles { get { return (string[])_roles.Clone(); } }
        internal string[] UnreachableStates { get { return (string[])_unreachableStates.Clone(); } }
        internal double MinDwellSeconds { get { return _minDwellSeconds; } }

        private PetSubtitleCatalog(string[] stateOrder, Dictionary<string, string> poseStates,
            Dictionary<string, double> dwell, Dictionary<string, Dictionary<string, string[]>> lines,
            string[] roles, string[] unreachableStates, double minDwellSeconds)
        {
            _stateOrder = stateOrder;
            _poseStates = poseStates;
            _dwell = dwell;
            _lines = lines;
            _roles = roles;
            _unreachableStates = unreachableStates;
            _minDwellSeconds = minDwellSeconds;
        }

        /// <summary>Loads and validates the table; a malformed table throws.</summary>
        internal static PetSubtitleCatalog Parse(byte[] utf8Json)
        {
            if (utf8Json == null || utf8Json.Length == 0 || utf8Json.Length > MaximumTableBytes)
                throw new InvalidDataException("The subtitle table is missing, empty or too large.");
            string text = new System.Text.UTF8Encoding(false, true).GetString(utf8Json);
            Dictionary<string, object> root = new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object>;
            if (root == null) throw new InvalidDataException("The subtitle table is not a JSON object.");
            if (ReadInt(root, "schemaVersion") != 1) throw new InvalidDataException("Unexpected subtitle schema version.");

            string[] stateOrder = ReadStringArray(root, "stateOrder");
            if (stateOrder == null || stateOrder.Length == 0) throw new InvalidDataException("The subtitle table has no state order.");
            HashSet<string> stateSet = new HashSet<string>(stateOrder, StringComparer.Ordinal);
            if (stateSet.Count != stateOrder.Length) throw new InvalidDataException("The subtitle state order repeats a state.");

            Dictionary<string, object> rawPoseStates = GetObject(root, "poseStates");
            Dictionary<string, object> rawDwell = GetObject(root, "dwellSeconds");
            Dictionary<string, object> rawCharacters = GetObject(root, "characters");
            if (rawPoseStates == null || rawDwell == null || rawCharacters == null)
                throw new InvalidDataException("The subtitle table is missing a required section.");
            if (rawDwell.Count != stateSet.Count) throw new InvalidDataException("Every state needs a dwell entry.");

            Dictionary<string, string> poseStates = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (KeyValuePair<string, object> pair in rawPoseStates)
            {
                string state = pair.Value as string;
                if (state == null || !stateSet.Contains(state))
                    throw new InvalidDataException("A pose maps to an unknown state.");
                poseStates[pair.Key] = state;
            }

            Dictionary<string, double> dwell = new Dictionary<string, double>(StringComparer.Ordinal);
            foreach (string state in stateOrder)
            {
                object raw = rawDwell[state];
                if (raw == null) continue; // null means "persist until the pose changes"
                double seconds = Convert.ToDouble(raw, System.Globalization.CultureInfo.InvariantCulture);
                if (Double.IsNaN(seconds) || Double.IsInfinity(seconds) || seconds <= 0 || seconds > 600)
                    throw new InvalidDataException("A state dwell is out of range.");
                dwell[state] = seconds;
            }

            double minDwell = root.ContainsKey("minDwellSeconds")
                ? Convert.ToDouble(root["minDwellSeconds"], System.Globalization.CultureInfo.InvariantCulture)
                : 2.5;
            if (Double.IsNaN(minDwell) || Double.IsInfinity(minDwell) || minDwell < 0 || minDwell > 60)
                throw new InvalidDataException("The minimum dwell is out of range.");

            string[] roles = new string[PetRole.BuiltIns.Count];
            for (int i = 0; i < roles.Length; i++) roles[i] = PetRole.BuiltIns[i].Id;
            if (rawCharacters.Count != roles.Length) throw new InvalidDataException("The subtitle table has an unexpected role set.");
            Dictionary<string, Dictionary<string, string[]>> lines =
                new Dictionary<string, Dictionary<string, string[]>>(StringComparer.Ordinal);
            foreach (string role in roles)
            {
                object rawRole;
                if (!rawCharacters.TryGetValue(role, out rawRole)) throw new InvalidDataException("A built-in role has no lines.");
                Dictionary<string, object> states = rawRole as Dictionary<string, object>;
                if (states == null || states.Count != stateSet.Count)
                    throw new InvalidDataException("A role's state set differs from the table.");
                Dictionary<string, string[]> byState = new Dictionary<string, string[]>(StringComparer.Ordinal);
                foreach (string state in stateOrder)
                {
                    object rawState;
                    if (!states.TryGetValue(state, out rawState)) throw new InvalidDataException("A role is missing a state.");
                    object[] rawLines = rawState as object[];
                    if (rawLines == null || rawLines.Length == 0 || rawLines.Length > 8)
                        throw new InvalidDataException("A state's line list is empty or too long.");
                    string[] cleaned = new string[rawLines.Length];
                    HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
                    for (int i = 0; i < rawLines.Length; i++)
                    {
                        string line = rawLines[i] as string;
                        if (line == null) throw new InvalidDataException("A line is not a string.");
                        line = line.Trim();
                        if (line.Length == 0 || line.Length > MaximumLineCharacters)
                            throw new InvalidDataException("A line is empty or too long.");
                        if (!seen.Add(line)) throw new InvalidDataException("A state repeats one line.");
                        cleaned[i] = line;
                    }
                    byState[state] = cleaned;
                }
                lines[role] = byState;
            }

            string[] unreachable = ReadStringArray(root, "unreachableStates") ?? new string[0];
            foreach (string state in unreachable)
                if (!stateSet.Contains(state)) throw new InvalidDataException("An unreachable state is not in the table.");

            return new PetSubtitleCatalog(stateOrder, poseStates, dwell, lines, roles, unreachable, minDwell);
        }

        /// <summary>
        /// Normalises an artwork pose name to a logical state key. The exact table entry wins;
        /// then a numbered variant (thinking-2, idle-3, sleeping-2) drops its suffix; an
        /// unknown pose falls back to idle, and a table without idle reports null so the
        /// caller shows no invented line.
        /// </summary>
        internal string StateKeyForPose(string pose)
        {
            if (String.IsNullOrEmpty(pose)) return IdleState;
            string direct;
            if (_poseStates.TryGetValue(pose, out direct)) return direct;
            int dash = pose.LastIndexOf('-');
            if (dash > 0)
            {
                string stripped;
                if (_poseStates.TryGetValue(pose.Substring(0, dash), out stripped)) return stripped;
            }
            return IdleState;
        }

        private string IdleState
        {
            get
            {
                string idle;
                return _poseStates.TryGetValue("idle", out idle) ? idle : null;
            }
        }

        internal string[] Lines(string roleId, string state)
        {
            Dictionary<string, string[]> states;
            string[] value;
            if (roleId != null && _lines.TryGetValue(roleId, out states) && states.TryGetValue(state, out value))
                return (string[])value.Clone();
            return new string[0];
        }

        internal bool HasLines(string roleId, string state)
        {
            Dictionary<string, string[]> states;
            string[] value;
            return roleId != null && _lines.TryGetValue(roleId, out states) &&
                state != null && states.TryGetValue(state, out value) && value.Length > 0;
        }

        /// <summary>Seconds this state stays on screen; null means it persists.</summary>
        internal double? DwellSeconds(string state)
        {
            double value;
            if (state != null && _dwell.TryGetValue(state, out value)) return value;
            return null;
        }

        private static int ReadInt(Dictionary<string, object> source, string key)
        {
            object value;
            if (!source.TryGetValue(key, out value)) return -1;
            try { return Convert.ToInt32(value, System.Globalization.CultureInfo.InvariantCulture); }
            catch { return -1; }
        }

        private static string[] ReadStringArray(Dictionary<string, object> source, string key)
        {
            object value;
            if (!source.TryGetValue(key, out value)) return null;
            object[] items = value as object[];
            if (items == null) return null;
            string[] result = new string[items.Length];
            for (int i = 0; i < items.Length; i++)
            {
                result[i] = items[i] as string;
                if (result[i] == null) return null;
            }
            return result;
        }

        private static Dictionary<string, object> GetObject(Dictionary<string, object> source, string key)
        {
            object value;
            return source.TryGetValue(key, out value) ? value as Dictionary<string, object> : null;
        }
    }
}
