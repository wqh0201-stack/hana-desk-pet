using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text;
using System.Web.Script.Serialization;

namespace HanaDesktopPet.Windows
{
    /// <summary>
    /// Reads bundled pet artwork. The shipped single-file build embeds every PNG, so the
    /// executable has no sibling asset folder; a folder store stays available for local
    /// debugging against a checked-out CrossPet tree.
    /// </summary>
    internal interface IPetAssetStore
    {
        long GetLength(string relativePath);
        byte[] ReadPrefix(string relativePath, int count);
        byte[] ReadAllBytes(string relativePath);
    }
    /// <summary>
    /// Artwork packed as one blob plus an offset index, both embedded in the executable.
    /// The blob is opened once and read by offset, so a 98 MB asset set never has to be
    /// copied into managed memory as a whole.
    /// </summary>
    internal sealed class EmbeddedPetAssetStore : IPetAssetStore, IDisposable
    {
        internal const string IndexResourceName = "HanaDesktopPet.Assets.idx.json";
        internal const string BlobResourceName = "HanaDesktopPet.Assets.bin";

        private readonly Dictionary<string, AssetEntry> _entries = new Dictionary<string, AssetEntry>(StringComparer.Ordinal);
        private readonly Stream _blob;
        private readonly object _gate = new object();
        private bool _disposed;

        private sealed class AssetEntry
        {
            public long Offset;
            public long Length;
        }

        public EmbeddedPetAssetStore(Assembly assembly)
        {
            if (assembly == null) throw new ArgumentNullException("assembly");
            byte[] indexBytes;
            using (Stream index = assembly.GetManifestResourceStream(IndexResourceName))
            {
                if (index == null) throw new InvalidDataException("The bundled artwork index is missing: " + IndexResourceName);
                if (index.Length <= 0 || index.Length > 4L * 1024L * 1024L)
                    throw new InvalidDataException("The bundled artwork index has an unexpected size.");
                indexBytes = ReadFully(index, (int)index.Length);
            }

            _blob = assembly.GetManifestResourceStream(BlobResourceName);
            if (_blob == null) throw new InvalidDataException("The bundled artwork blob is missing: " + BlobResourceName);
            long blobLength = _blob.Length;

            Dictionary<string, object> document =
                new JavaScriptSerializer().DeserializeObject(Encoding.UTF8.GetString(indexBytes)) as Dictionary<string, object>;
            if (document == null) throw new InvalidDataException("The bundled artwork index is not a JSON object.");

            object rawFiles;
            if (!document.TryGetValue("files", out rawFiles)) throw new InvalidDataException("The bundled artwork index has no file list.");
            System.Collections.IList files = rawFiles as System.Collections.IList;
            if (files == null || files.Count == 0) throw new InvalidDataException("The bundled artwork index lists no files.");

            for (int i = 0; i < files.Count; i++)
            {
                Dictionary<string, object> raw = files[i] as Dictionary<string, object>;
                if (raw == null) throw new InvalidDataException("The bundled artwork index entry is invalid.");
                string name = ReadString(raw, "name");
                long offset = ReadInteger(raw, "offset");
                long length = ReadInteger(raw, "length");
                if (!IsSafeRelativeName(name)) throw new InvalidDataException("The bundled artwork index contains an unsafe name.");
                if (offset < 0 || length <= 0 || offset + length > blobLength)
                    throw new InvalidDataException("The bundled artwork index points outside the blob: " + name);
                if (_entries.ContainsKey(name)) throw new InvalidDataException("The bundled artwork index repeats a name: " + name);
                AssetEntry entry = new AssetEntry();
                entry.Offset = offset;
                entry.Length = length;
                _entries.Add(name, entry);
            }
        }

        public long GetLength(string relativePath)
        {
            return EntryFor(relativePath).Length;
        }

        public byte[] ReadPrefix(string relativePath, int count)
        {
            AssetEntry entry = EntryFor(relativePath);
            if (count < 0) throw new ArgumentOutOfRangeException("count");
            return ReadRange(entry, Math.Min((long)count, entry.Length));
        }

        public byte[] ReadAllBytes(string relativePath)
        {
            AssetEntry entry = EntryFor(relativePath);
            return ReadRange(entry, entry.Length);
        }

        private AssetEntry EntryFor(string relativePath)
        {
            if (_disposed) throw new ObjectDisposedException("EmbeddedPetAssetStore");
            AssetEntry entry;
            if (relativePath == null || !_entries.TryGetValue(relativePath, out entry))
                throw new InvalidDataException("Artwork is not listed in the bundled index: " + relativePath);
            return entry;
        }

        private byte[] ReadRange(AssetEntry entry, long count)
        {
            if (count > int.MaxValue) throw new InvalidDataException("Artwork entry is too large to load.");
            byte[] buffer = new byte[(int)count];
            lock (_gate)
            {
                _blob.Seek(entry.Offset, SeekOrigin.Begin);
                int offset = 0;
                while (offset < buffer.Length)
                {
                    int read = _blob.Read(buffer, offset, buffer.Length - offset);
                    if (read <= 0) throw new InvalidDataException("The bundled artwork blob ended unexpectedly.");
                    offset += read;
                }
            }
            return buffer;
        }

        public void Dispose()
        {
            if (_disposed) return;
            _disposed = true;
            _blob.Dispose();
        }

        internal static bool IsSafeRelativeName(string name)
        {
            if (String.IsNullOrEmpty(name) || name.Length > 160) return false;
            if (name.IndexOf('\\') >= 0 || name.IndexOf(':') >= 0) return false;
            string[] parts = name.Split('/');
            if (parts.Length < 1 || parts.Length > 2) return false;
            for (int i = 0; i < parts.Length; i++)
            {
                if (parts[i].Length == 0 || parts[i] == "." || parts[i] == "..") return false;
                for (int c = 0; c < parts[i].Length; c++)
                {
                    char ch = parts[i][c];
                    if (!(ch >= 'a' && ch <= 'z') && !(ch >= '0' && ch <= '9') && ch != '-' && ch != '_' && ch != '.') return false;
                }
            }
            return true;
        }

        private static string ReadString(Dictionary<string, object> source, string key)
        {
            object value;
            return source.TryGetValue(key, out value) ? value as string : null;
        }

        private static long ReadInteger(Dictionary<string, object> source, string key)
        {
            object value;
            if (!source.TryGetValue(key, out value)) return -1;
            try { return Convert.ToInt64(value); }
            catch { return -1; }
        }

        private static byte[] ReadFully(Stream stream, int count)
        {
            byte[] buffer = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int read = stream.Read(buffer, offset, count - offset);
                if (read <= 0) throw new InvalidDataException("A bundled resource ended unexpectedly.");
                offset += read;
            }
            return buffer;
        }
    }

    /// <summary>
    /// Debug-only store that reads the checked-out CrossPet folder. Keeps the original
    /// path-escape and reparse-point checks so a modified tree cannot widen what loads.
    /// </summary>
    internal sealed class DirectoryPetAssetStore : IPetAssetStore
    {
        private readonly string _root;
        private readonly string _rootPrefix;

        public DirectoryPetAssetStore(string directory)
        {
            _root = Path.GetFullPath(directory);
            _rootPrefix = _root.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar) + Path.DirectorySeparatorChar;
        }

        public long GetLength(string relativePath)
        {
            return new FileInfo(Resolve(relativePath)).Length;
        }

        public byte[] ReadPrefix(string relativePath, int count)
        {
            string path = Resolve(relativePath);
            byte[] buffer = new byte[Math.Min(count, (int)Math.Min(new FileInfo(path).Length, Int32.MaxValue))];
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                int offset = 0;
                while (offset < buffer.Length)
                {
                    int read = stream.Read(buffer, offset, buffer.Length - offset);
                    if (read <= 0) break;
                    offset += read;
                }
                if (offset != buffer.Length) throw new InvalidDataException("CrossPet PNG header is incomplete: " + relativePath);
            }
            return buffer;
        }

        public byte[] ReadAllBytes(string relativePath)
        {
            string path = Resolve(relativePath);
            FileInfo info = new FileInfo(path);
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("CrossPet image is linked: " + relativePath);
            return File.ReadAllBytes(path);
        }

        private string Resolve(string relativePath)
        {
            if (relativePath == null || relativePath.IndexOf('\\') >= 0 || relativePath.IndexOf(':') >= 0)
                throw new InvalidDataException("Artwork path is not a relative bundle name.");
            string full = Path.GetFullPath(Path.Combine(_root, relativePath.Replace('/', Path.DirectorySeparatorChar)));
            if (!full.StartsWith(_rootPrefix, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("CrossPet path escaped its root.");
            if (!File.Exists(full)) throw new FileNotFoundException("CrossPet resource is missing: " + relativePath);
            return full;
        }
    }
}
