using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Windows
{
    internal sealed class PetWindowPosition
    {
        public string MonitorDevice { get; set; }
        public double XRatio { get; set; }
        public double YRatio { get; set; }
    }

    internal sealed class PetPreferencesData
    {
        internal PetPreferencesData()
        {
            ShowNotices = true;
            BasinOverrides = new Dictionary<string, PetBasinConfig>(StringComparer.Ordinal);
        }

        public PetSelection Selection { get; set; }
        public bool PositionLocked { get; set; }
        public bool ShowNotices { get; set; }
        /// <summary>Per-character basin geometry saved from the debug panel.</summary>
        public Dictionary<string, PetBasinConfig> BasinOverrides { get; set; }
        public PetWindowPosition WindowPosition { get; set; }
    }

    /// <summary>
    /// Persists only the local role choice, lock flag, notification-bubble preference and
    /// monitor-relative window position. No session or activity data is ever written here.
    /// </summary>
    internal sealed class PetPreferences
    {
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
        private readonly string _filePath;

        public PetPreferences()
        {
            string directory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "HanaDesktopPet");
            _filePath = Path.Combine(directory, "preferences.json");
        }

        public PetPreferencesData Load()
        {
            PetPreferencesData fallback = Defaults();
            try
            {
                string directory = Path.GetDirectoryName(_filePath);
                if (Directory.Exists(directory) && (File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0)
                    return fallback;
                if (!File.Exists(_filePath)) return fallback;
                FileInfo info = new FileInfo(_filePath);
                if ((info.Attributes & FileAttributes.ReparsePoint) != 0 || info.Length > 16384) return fallback;
                string json = File.ReadAllText(_filePath, Encoding.UTF8);
                Dictionary<string, object> root = Json.DeserializeObject(json) as Dictionary<string, object>;
                if (root == null) return fallback;
                Dictionary<string, object> rawSelection = GetObject(root, "Selection") ?? GetObject(root, "selection");
                string characterId = rawSelection == null ? null : ReadString(rawSelection, "CharacterId", "characterId");
                long revision = rawSelection == null ? 0 : ReadLong(rawSelection, "Revision", "revision");
                long updatedAt = rawSelection == null ? 0 : ReadLong(rawSelection, "UpdatedAt", "updatedAt");
                PetSelection selection = IsBuiltIn(characterId)
                    ? new PetSelection(characterId, Math.Max(0, revision), Math.Max(0, updatedAt))
                    : new PetSelection();
                bool locked = ReadBoolean(root, "PositionLocked", "positionLocked");
                // The bubble preference is on unless an explicit stored value says otherwise.
                bool showNotices = true;
                if (root.ContainsKey("ShowNotices") || root.ContainsKey("showNotices"))
                    showNotices = ReadBoolean(root, "ShowNotices", "showNotices");
                Dictionary<string, PetBasinConfig> basinOverrides = ReadBasinOverrides(root);
                Dictionary<string, object> rawPosition = GetObject(root, "WindowPosition") ?? GetObject(root, "windowPosition");
                PetWindowPosition position = null;
                if (rawPosition != null)
                {
                    position = new PetWindowPosition
                    {
                        MonitorDevice = ReadString(rawPosition, "MonitorDevice", "monitorDevice"),
                        XRatio = ReadDouble(rawPosition, "XRatio", "xRatio"),
                        YRatio = ReadDouble(rawPosition, "YRatio", "yRatio")
                    };
                }
                return new PetPreferencesData { Selection = selection, PositionLocked = locked, ShowNotices = showNotices,
                    BasinOverrides = basinOverrides, WindowPosition = CleanPosition(position) };
            }
            catch
            {
                return fallback;
            }
        }

        private static Dictionary<string, PetBasinConfig> ReadBasinOverrides(Dictionary<string, object> root)
        {
            Dictionary<string, PetBasinConfig> result = new Dictionary<string, PetBasinConfig>(StringComparer.Ordinal);
            Dictionary<string, object> raw = GetObject(root, "BasinOverrides") ?? GetObject(root, "basinOverrides");
            if (raw == null) return result;
            foreach (KeyValuePair<string, object> pair in raw)
            {
                System.Collections.IList values = pair.Value as System.Collections.IList;
                if (values == null || values.Count != 3) continue;
                double width;
                double xOffset;
                double yOffset;
                if (!TryNumber(values[0], out width) || !TryNumber(values[1], out xOffset) || !TryNumber(values[2], out yOffset))
                    continue;
                result[pair.Key] = new PetBasinConfig(width, xOffset, yOffset).Clamped();
            }
            return result;
        }

        private static bool TryNumber(object value, out double number)
        {
            number = 0.0;
            if (value == null) return false;
            try
            {
                number = Convert.ToDouble(value);
                return true;
            }
            catch
            {
                return false;
            }
        }

        public void Save(PetPreferencesData data)
        {
            if (data == null) return;
            try
            {
                PetPreferencesData safe = new PetPreferencesData();
                safe.Selection = data.Selection != null && IsBuiltIn(data.Selection.CharacterId)
                    ? data.Selection
                    : new PetSelection();
                safe.PositionLocked = data.PositionLocked;
                safe.ShowNotices = data.ShowNotices;
                safe.BasinOverrides = data.BasinOverrides != null
                    ? new Dictionary<string, PetBasinConfig>(data.BasinOverrides, StringComparer.Ordinal)
                    : new Dictionary<string, PetBasinConfig>(StringComparer.Ordinal);
                safe.WindowPosition = CleanPosition(data.WindowPosition);

                Dictionary<string, object> selection = new Dictionary<string, object>();
                selection.Add("CharacterId", safe.Selection.CharacterId);
                selection.Add("Revision", safe.Selection.Revision);
                selection.Add("UpdatedAt", safe.Selection.UpdatedAt);
                Dictionary<string, object> document = new Dictionary<string, object>();
                document.Add("Selection", selection);
                document.Add("PositionLocked", safe.PositionLocked);
                document.Add("ShowNotices", safe.ShowNotices);
                if (safe.BasinOverrides.Count > 0)
                {
                    Dictionary<string, object> basin = new Dictionary<string, object>();
                    foreach (KeyValuePair<string, PetBasinConfig> pair in safe.BasinOverrides)
                    {
                        if (pair.Value == null) continue;
                        basin[pair.Key] = new object[] { pair.Value.Width, pair.Value.XOffset, pair.Value.YOffset };
                    }
                    document.Add("BasinOverrides", basin);
                }
                if (safe.WindowPosition != null)
                {
                    Dictionary<string, object> position = new Dictionary<string, object>();
                    position.Add("MonitorDevice", safe.WindowPosition.MonitorDevice);
                    position.Add("XRatio", safe.WindowPosition.XRatio);
                    position.Add("YRatio", safe.WindowPosition.YRatio);
                    document.Add("WindowPosition", position);
                }

                string directory = Path.GetDirectoryName(_filePath);
                if (!Directory.Exists(directory)) Directory.CreateDirectory(directory);
                if ((File.GetAttributes(directory) & FileAttributes.ReparsePoint) != 0) return;
                string temporary = _filePath + "." + Guid.NewGuid().ToString("N") + ".tmp";
                byte[] bytes = new UTF8Encoding(false).GetBytes(Json.Serialize(document));
                try
                {
                    using (FileStream stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        stream.Write(bytes, 0, bytes.Length);
                        stream.Flush(true);
                    }
                    if (File.Exists(_filePath))
                    {
                        if ((File.GetAttributes(_filePath) & FileAttributes.ReparsePoint) != 0) return;
                        File.Replace(temporary, _filePath, null);
                    }
                    else
                        File.Move(temporary, _filePath);
                }
                finally
                {
                    try { if (File.Exists(temporary)) File.Delete(temporary); }
                    catch { }
                }
            }
            catch
            {
                // Preferences are best-effort. A read-only profile must not prevent the pet from starting.
            }
        }

        private static PetPreferencesData Defaults()
        {
            return new PetPreferencesData
            {
                Selection = new PetSelection(),
                PositionLocked = false,
                ShowNotices = true,
                WindowPosition = null
            };
        }

        private static PetWindowPosition CleanPosition(PetWindowPosition position)
        {
            if (position == null || String.IsNullOrWhiteSpace(position.MonitorDevice) ||
                position.MonitorDevice.Length > 128 || Double.IsNaN(position.XRatio) || Double.IsInfinity(position.XRatio) ||
                Double.IsNaN(position.YRatio) || Double.IsInfinity(position.YRatio)) return null;
            return new PetWindowPosition
            {
                MonitorDevice = position.MonitorDevice,
                XRatio = Clamp(position.XRatio, 0.0, 1.0),
                YRatio = Clamp(position.YRatio, 0.0, 1.0)
            };
        }

        private static bool IsBuiltIn(string id)
        {
            if (String.IsNullOrEmpty(id)) return false;
            foreach (PetRole role in PetRole.BuiltIns)
                if (String.Equals(role.Id, id, StringComparison.Ordinal)) return true;
            return false;
        }

        private static Dictionary<string, object> GetObject(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary.TryGetValue(key, out value) ? value as Dictionary<string, object> : null;
        }

        private static string ReadString(Dictionary<string, object> dictionary, string primary, string alternate)
        {
            object value;
            if (dictionary.TryGetValue(primary, out value)) return value as string;
            if (dictionary.TryGetValue(alternate, out value)) return value as string;
            return null;
        }

        private static long ReadLong(Dictionary<string, object> dictionary, string primary, string alternate)
        {
            object value;
            try
            {
                if (dictionary.TryGetValue(primary, out value)) return Convert.ToInt64(value);
                if (dictionary.TryGetValue(alternate, out value)) return Convert.ToInt64(value);
            }
            catch { }
            return 0;
        }

        private static double ReadDouble(Dictionary<string, object> dictionary, string primary, string alternate)
        {
            object value;
            try
            {
                if (dictionary.TryGetValue(primary, out value)) return Convert.ToDouble(value);
                if (dictionary.TryGetValue(alternate, out value)) return Convert.ToDouble(value);
            }
            catch { }
            return Double.NaN;
        }

        private static bool ReadBoolean(Dictionary<string, object> dictionary, string primary, string alternate)
        {
            object value;
            if (dictionary.TryGetValue(primary, out value))
            {
                try { return Convert.ToBoolean(value); }
                catch { return false; }
            }
            if (dictionary.TryGetValue(alternate, out value))
            {
                try { return Convert.ToBoolean(value); }
                catch { return false; }
            }
            return false;
        }

        private static double Clamp(double value, double minimum, double maximum)
        {
            if (value < minimum) return minimum;
            if (value > maximum) return maximum;
            return value;
        }
    }
}
