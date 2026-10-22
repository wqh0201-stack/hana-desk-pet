using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Windows
{
    internal sealed class PetArtwork
    {
        public BitmapSource Bitmap { get; private set; }
        public int Width { get; private set; }
        public int Height { get; private set; }
        public byte[] Alpha { get; private set; }
        public long ByteCost { get; private set; }
        /// <summary>First row holding a visible pixel (top-left origin).</summary>
        public int ContentTop { get; private set; }
        /// <summary>Number of rows holding a visible pixel.</summary>
        public int ContentHeight { get; private set; }

        public PetArtwork(BitmapSource bitmap, int width, int height, byte[] alpha)
        {
            Bitmap = bitmap;
            Width = width;
            Height = height;
            Alpha = alpha;
            // Account for the decoded source, converted Pbgra32 surface and alpha hit map.
            ByteCost = (long)width * height * 9L;

            int first = -1;
            int last = -1;
            for (int row = 0; row < height; row++)
            {
                bool opaque = false;
                int start = row * width;
                for (int column = 0; column < width; column++)
                {
                    if (alpha[start + column] >= 32) { opaque = true; break; }
                }
                if (opaque)
                {
                    if (first < 0) first = row;
                    last = row;
                }
            }
            ContentTop = first < 0 ? 0 : first;
            ContentHeight = last < first ? height : last - first + 1;
        }

        public byte AlphaAt(int x, int y)
        {
            if (x < 0 || y < 0 || x >= Width || y >= Height) return 0;
            return Alpha[y * Width + x];
        }
    }

    /// <summary>
    /// Catalog-only PNG loader. Character folders and image names come exclusively from
    /// the bundled catalog and are checked before any path is opened.
    /// </summary>
    internal sealed class PetArtworkCatalog
    {
        private const long MaximumCatalogBytes = 1024 * 1024;
        private const long MaximumImageFileBytes = 12L * 1024L * 1024L;
        private const int MaximumImageDimension = 4096;
        private const long MaximumImagePixels = 2L * 1024L * 1024L;
        private const long MaximumCacheBytes = 32L * 1024L * 1024L;

        private readonly IPetAssetStore _store;
        private readonly Dictionary<string, CharacterEntry> _characters;
        private readonly Dictionary<string, CacheEntry> _cache = new Dictionary<string, CacheEntry>(StringComparer.Ordinal);
        private readonly List<string> _useOrder = new List<string>();
        private long _cacheBytes;

        public double MaximumAspectRatio { get; private set; }

        private sealed class CharacterEntry
        {
            public string Id;
            public string Directory;
            public List<string> FileNames;
            public HashSet<string> PoseNames;
            public HashSet<string> GeneratedFileNames;
        }

        private sealed class CacheEntry
        {
            public PetArtwork Artwork;
            public long ByteCost;
        }

        public PetArtworkCatalog(IPetAssetStore store)
        {
            if (store == null) throw new ArgumentNullException("store");
            _store = store;
            long catalogLength = store.GetLength("catalog.json");
            if (catalogLength <= 0 || catalogLength > MaximumCatalogBytes)
                throw new InvalidDataException("CrossPet/catalog.json is missing, empty or too large.");

            byte[] catalogBytes = store.ReadAllBytes("catalog.json");
            string json = Encoding.UTF8.GetString(catalogBytes);
            Dictionary<string, object> document = new JavaScriptSerializer().DeserializeObject(json) as Dictionary<string, object>;
            if (document == null || ReadInteger(document, "schemaVersion") != 1)
                throw new InvalidDataException("CrossPet/catalog.json has an unsupported schema.");

            IList characterList = ReadArray(document, "characters");
            if (characterList == null || characterList.Count != PetRole.BuiltIns.Count)
                throw new InvalidDataException("CrossPet/catalog.json must list the seven built-in characters.");

            _characters = new Dictionary<string, CharacterEntry>(StringComparer.Ordinal);
            double maxRatio = 0.0;
            for (int roleIndex = 0; roleIndex < PetRole.BuiltIns.Count; roleIndex++)
            {
                Dictionary<string, object> raw = characterList[roleIndex] as Dictionary<string, object>;
                PetRole role = PetRole.BuiltIns[roleIndex];
                if (raw == null) throw new InvalidDataException("CrossPet catalog character entry is invalid.");

                string id = ReadString(raw, "id");
                string assetDirectory = ReadString(raw, "assetDirectory");
                if (!String.Equals(id, role.Id, StringComparison.Ordinal) ||
                    !String.Equals(assetDirectory, id, StringComparison.Ordinal) ||
                    !IsSafeCharacterId(id))
                    throw new InvalidDataException("CrossPet catalog contains an unexpected character ID or directory.");

                IList files = ReadArray(raw, "poseFiles");
                if (files == null || files.Count == 0) throw new InvalidDataException("CrossPet character has no listed pose files: " + id);

                CharacterEntry entry = new CharacterEntry();
                entry.Id = id;
                entry.Directory = assetDirectory;
                entry.FileNames = new List<string>();
                entry.PoseNames = new HashSet<string>(StringComparer.Ordinal);
                entry.GeneratedFileNames = new HashSet<string>(StringComparer.Ordinal);
                for (int fileIndex = 0; fileIndex < files.Count; fileIndex++)
                {
                    string fileName = files[fileIndex] as string;
                    if (!IsSafePoseFileName(fileName) || !entry.PoseNames.Add(fileName.Substring(0, fileName.Length - 4)))
                        throw new InvalidDataException("CrossPet catalog contains an unsafe or duplicate pose file for " + id + ".");
                    entry.FileNames.Add(fileName);
                }
                if (!entry.PoseNames.Contains("idle")) throw new InvalidDataException("CrossPet character is missing its listed idle.png: " + id);

                IList generated = ReadArray(raw, "generatedPoses");
                if (generated != null)
                {
                    for (int generatedIndex = 0; generatedIndex < generated.Count; generatedIndex++)
                    {
                        string generatedName = generated[generatedIndex] as string;
                        if (!IsSafePoseFileName(generatedName) || !entry.FileNames.Contains(generatedName) || !entry.GeneratedFileNames.Add(generatedName))
                            throw new InvalidDataException("CrossPet catalog has an invalid generated pose list for " + id + ".");
                    }
                }

                _characters.Add(id, entry);
                for (int fileIndex = 0; fileIndex < entry.FileNames.Count; fileIndex++)
                {
                    PngHeader header = ReadAndValidatePngHeader(entry, entry.FileNames[fileIndex]);
                    maxRatio = Math.Max(maxRatio, (double)header.Width / (double)header.Height);
                }
            }
            MaximumAspectRatio = maxRatio > 0.0 ? maxRatio : 1.0;
        }

        public ISet<string> AvailablePoses(string characterId)
        {
            CharacterEntry character;
            if (!_characters.TryGetValue(characterId ?? String.Empty, out character))
                return new HashSet<string>(StringComparer.Ordinal);
            return new HashSet<string>(character.PoseNames, StringComparer.Ordinal);
        }

        /// <summary>
        /// Reads an optional, non-catalog image such as the shared basin artwork. Only
        /// plain relative bundle names are accepted, and a missing file is not an error:
        /// the caller falls back to its drawn basin.
        /// </summary>
        public byte[] ReadOptionalImage(string relativePath)
        {
            if (String.IsNullOrEmpty(relativePath) || relativePath.IndexOf('\\') >= 0 ||
                relativePath.IndexOf(':') >= 0 || relativePath.IndexOf("..") >= 0)
                return null;
            try
            {
                return _store.ReadAllBytes(relativePath);
            }
            catch (InvalidDataException) { return null; }
            catch (FileNotFoundException) { return null; }
            catch (IOException) { return null; }
        }

        /// <summary>
        /// Decodes an optional image, or returns null when it is absent or unreadable.
        /// Used for the double-click basin, which must never take the artwork path down.
        /// </summary>
        public BitmapSource DecodeOptionalImage(string relativePath)
        {
            byte[] bytes = ReadOptionalImage(relativePath);
            if (bytes == null || bytes.Length == 0) return null;
            try
            {
                BitmapImage decoded = new BitmapImage();
                using (MemoryStream stream = new MemoryStream(bytes, false))
                {
                    decoded.BeginInit();
                    decoded.CacheOption = BitmapCacheOption.OnLoad;
                    decoded.CreateOptions = BitmapCreateOptions.PreservePixelFormat;
                    decoded.StreamSource = stream;
                    decoded.EndInit();
                }
                if (decoded.PixelWidth <= 0 || decoded.PixelHeight <= 0 ||
                    decoded.PixelWidth > MaximumImageDimension || decoded.PixelHeight > MaximumImageDimension)
                    return null;
                decoded.Freeze();
                return decoded;
            }
            catch (InvalidDataException) { return null; }
            catch (NotSupportedException) { return null; }
            catch (IOException) { return null; }
        }

        public PetArtwork GetArtwork(string characterId, string poseName)
        {
            CharacterEntry character;
            if (!_characters.TryGetValue(characterId ?? String.Empty, out character)) return null;
            if (!character.PoseNames.Contains(poseName ?? String.Empty)) return null;

            string key = characterId + "/" + poseName;
            CacheEntry cached;
            if (_cache.TryGetValue(key, out cached))
            {
                Touch(key);
                return cached.Artwork;
            }

            string filename = poseName + ".png";
            byte[] bytes = ReadSafeImageBytes(character, filename);
            BitmapImage decoded = new BitmapImage();
            using (MemoryStream stream = new MemoryStream(bytes, false))
            {
                decoded.BeginInit();
                decoded.CacheOption = BitmapCacheOption.OnLoad;
                decoded.CreateOptions = BitmapCreateOptions.PreservePixelFormat;
                decoded.StreamSource = stream;
                decoded.EndInit();
            }
            if (decoded.PixelWidth <= 0 || decoded.PixelHeight <= 0 || decoded.PixelWidth > MaximumImageDimension ||
                decoded.PixelHeight > MaximumImageDimension || (long)decoded.PixelWidth * decoded.PixelHeight > MaximumImagePixels)
                throw new InvalidDataException("CrossPet image dimensions exceed the safe limit: " + characterId + "/" + filename);

            FormatConvertedBitmap converted = new FormatConvertedBitmap(decoded, PixelFormats.Pbgra32, null, 0.0);
            converted.Freeze();
            int width = converted.PixelWidth;
            int height = converted.PixelHeight;
            int stride = width * 4;
            byte[] pixels = new byte[stride * height];
            converted.CopyPixels(pixels, stride, 0);
            byte[] alpha = new byte[width * height];
            for (int pixel = 0, source = 3; pixel < alpha.Length; pixel++, source += 4)
                alpha[pixel] = pixels[source];

            PetArtwork artwork = new PetArtwork(converted, width, height, alpha);
            AddToCache(key, artwork);
            return artwork;
        }

        private void AddToCache(string key, PetArtwork artwork)
        {
            long cost = artwork.ByteCost;
            while (_cache.Count > 0 && _cacheBytes + cost > MaximumCacheBytes)
            {
                string evict = null;
                for (int i = 0; i < _useOrder.Count; i++)
                {
                    evict = _useOrder[i];
                    break;
                }
                if (evict == null) break;
                CacheEntry entry = _cache[evict];
                _cache.Remove(evict);
                _useOrder.Remove(evict);
                _cacheBytes -= entry.ByteCost;
            }
            if (cost > MaximumCacheBytes) return;
            CacheEntry cacheEntry = new CacheEntry();
            cacheEntry.Artwork = artwork;
            cacheEntry.ByteCost = cost;
            _cache[key] = cacheEntry;
            _cacheBytes += cost;
            _useOrder.Add(key);
        }

        private void Touch(string key)
        {
            _useOrder.Remove(key);
            _useOrder.Add(key);
        }

        private byte[] ReadSafeImageBytes(CharacterEntry character, string filename)
        {
            if (!character.FileNames.Contains(filename)) throw new InvalidDataException("Image is not listed in the CrossPet catalog.");
            string relative = ListedRelativePath(character, filename);
            long length = _store.GetLength(relative);
            if (length < 24 || length > MaximumImageFileBytes)
                throw new InvalidDataException("CrossPet image is missing or too large: " + character.Id + "/" + filename);
            byte[] bytes = _store.ReadAllBytes(relative);
            ValidatePngBytes(bytes, character.Id, filename);
            return bytes;
        }

        private PngHeader ReadAndValidatePngHeader(CharacterEntry character, string filename)
        {
            string relative = ListedRelativePath(character, filename);
            long length = _store.GetLength(relative);
            if (length < 24 || length > MaximumImageFileBytes)
                throw new InvalidDataException("CrossPet image is missing or too large: " + character.Id + "/" + filename);
            return ValidatePngBytes(_store.ReadPrefix(relative, 24), character.Id, filename);
        }

        private static PngHeader ValidatePngBytes(byte[] bytes, string characterId, string filename)
        {
            if (bytes == null || bytes.Length < 24 || bytes[0] != 137 || bytes[1] != 80 || bytes[2] != 78 || bytes[3] != 71 ||
                bytes[4] != 13 || bytes[5] != 10 || bytes[6] != 26 || bytes[7] != 10 ||
                bytes[12] != 73 || bytes[13] != 72 || bytes[14] != 68 || bytes[15] != 82)
                throw new InvalidDataException("CrossPet file is not a valid PNG: " + characterId + "/" + filename);
            int width = ReadBigEndianInt32(bytes, 16);
            int height = ReadBigEndianInt32(bytes, 20);
            if (width <= 0 || height <= 0 || width > MaximumImageDimension || height > MaximumImageDimension ||
                (long)width * height > MaximumImagePixels)
                throw new InvalidDataException("CrossPet image dimensions exceed the safe limit: " + characterId + "/" + filename);
            return new PngHeader(width, height);
        }

        private string ListedRelativePath(CharacterEntry character, string fileName)
        {
            if (character == null)
            {
                if (!String.Equals(fileName, "catalog.json", StringComparison.Ordinal))
                    throw new InvalidDataException("Only the bundled catalog can be loaded at the CrossPet root.");
                return "catalog.json";
            }

            if (!_characters.ContainsKey(character.Id) || !String.Equals(character.Directory, character.Id, StringComparison.Ordinal) ||
                !IsSafeCharacterId(character.Id) || !IsSafePoseFileName(fileName) || !character.FileNames.Contains(fileName))
                throw new InvalidDataException("CrossPet image path is not an exact catalog entry.");
            return character.Directory + "/" + fileName;
        }

        private static bool IsSafeCharacterId(string id)
        {
            if (String.IsNullOrEmpty(id) || id.Length > 40) return false;
            for (int i = 0; i < id.Length; i++)
            {
                char c = id[i];
                if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-') return false;
            }
            return true;
        }

        private static bool IsSafePoseFileName(string fileName)
        {
            if (String.IsNullOrEmpty(fileName) || !fileName.EndsWith(".png", StringComparison.Ordinal) || fileName.Length <= 4 || fileName.Length > 100)
                return false;
            for (int i = 0; i < fileName.Length - 4; i++)
            {
                char c = fileName[i];
                if (!(c >= 'a' && c <= 'z') && !(c >= '0' && c <= '9') && c != '-' && c != '_') return false;
            }
            return true;
        }

        private static string ReadString(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary.TryGetValue(key, out value) ? value as string : null;
        }

        private static int ReadInteger(Dictionary<string, object> dictionary, string key)
        {
            object value;
            if (!dictionary.TryGetValue(key, out value)) return -1;
            try { return Convert.ToInt32(value); }
            catch { return -1; }
        }

        private static IList ReadArray(Dictionary<string, object> dictionary, string key)
        {
            object value;
            return dictionary.TryGetValue(key, out value) ? value as IList : null;
        }

        private static int ReadBigEndianInt32(byte[] bytes, int offset)
        {
            return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
        }

        private sealed class PngHeader
        {
            public int Width;
            public int Height;
            public PngHeader(int width, int height) { Width = width; Height = height; }
        }
    }
}
