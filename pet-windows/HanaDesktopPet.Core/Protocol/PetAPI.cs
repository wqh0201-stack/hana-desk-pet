using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;

namespace HanaDesktopPet.Core
{
    public sealed class PetAPI
    {
        private readonly PetStateStore store;
        private readonly PetPoseReadbackStore readback;

        public PetAPI(PetStateStore store, PetPoseReadbackStore readback)
        {
            this.store = store;
            this.readback = readback;
        }

        public PetHTTPResponse Handle(PetHTTPRequest request)
        {
            if (request.Method == "GET" && request.Path == "/v4/hello")
                return request.Body.Length == 0 ? Json(200, new { service = "hana-desktop-pet", protocolVersion = 4 }) : Json(400, new { error = "invalid_request" });
            if (request.Method == "GET" && request.Path == "/v4/selection")
                return request.Body.Length == 0 ? Json(200, SelectionObject(store.CurrentSelection())) : Json(400, new { error = "invalid_request" });
            if (request.Method == "GET" && request.Path == "/v4/state")
                return request.Body.Length == 0 ? Json(200, PoseObject(readback.Current())) : Json(400, new { error = "invalid_request" });
            if (request.Method == "POST" && request.Path == "/v4/snapshot")
            {
                if (!HasJsonContentType(request)) return Json(415, new { error = "json_required" });
                try
                {
                    PetSnapshotDTO snapshot = DecodeSnapshot(request.Body);
                    if (store.Ingest(snapshot) == SnapshotIngestResult.Accepted)
                        return Json(200, new { schemaVersion = 4, accepted = true });
                    return Json(409, new { schemaVersion = 4, accepted = false });
                }
                catch (Exception exception)
                {
                    if (!(exception is FormatException) && !(exception is InvalidDataException) && !(exception is OverflowException)) throw;
                    return Json(400, new { error = "invalid_snapshot" });
                }
            }
            if (request.Method == "POST" && request.Path == "/v4/selection")
            {
                if (!HasJsonContentType(request)) return Json(415, new { error = "json_required" });
                try
                {
                    IDictionary<string, object> value = RequireObject(StrictJson.Parse(request.Body),
                        new[] { "schemaVersion", "characterId", "expectedRevision", "updatedAt" },
                        new[] { "schemaVersion", "characterId", "expectedRevision", "updatedAt" });
                    long schemaVersion = ReadInteger(value["schemaVersion"]);
                    string characterId = RequiredText(value["characterId"], 48);
                    long expectedRevision = ReadInteger(value["expectedRevision"]);
                    long updatedAt = ReadInteger(value["updatedAt"]);
                    if (schemaVersion != 4 || !ValidRoleId(characterId)) throw new InvalidDataException();

                    SelectionWriteResult result = store.WriteRemoteSelection(characterId, expectedRevision, updatedAt);
                    if (result.Kind == SelectionWriteResultKind.Updated)
                        return Json(200, new { selection = SelectionObject(result.Selection) });
                    if (result.Kind == SelectionWriteResultKind.Conflict)
                        return Json(409, new { selection = SelectionObject(result.Selection) });
                    return Json(400, new { error = "unknown_character" });
                }
                catch (Exception exception)
                {
                    if (!(exception is FormatException) && !(exception is InvalidDataException) && !(exception is OverflowException)) throw;
                    return Json(400, new { error = "invalid_selection" });
                }
            }
            if (request.Path == "/v4/hello" || request.Path == "/v4/selection" ||
                request.Path == "/v4/state" || request.Path == "/v4/snapshot")
                return Json(405, new { error = "method_not_allowed" });
            return Json(404, new { error = "not_found" });
        }

        private static PetSnapshotDTO DecodeSnapshot(byte[] body)
        {
            IDictionary<string, object> root = RequireObject(StrictJson.Parse(body),
                new[] { "schemaVersion", "revision", "characters", "activity", "followMode", "concurrentSessions", "notifications" },
                new[] { "schemaVersion", "revision", "characters", "activity" });
            if (ReadInteger(root["schemaVersion"]) != 4) throw new InvalidDataException();
            long revision = ReadInteger(root["revision"]);

            // New root fields are validated when present and default safely when absent.
            // The console always sends them; hand-written synthetic snapshots need not.
            string followMode = "latest";
            object rawFollowMode;
            if (root.TryGetValue("followMode", out rawFollowMode) && rawFollowMode != null)
            {
                followMode = RequiredText(rawFollowMode, 16);
                if (followMode != "latest" && followMode != "pinned") throw new InvalidDataException();
            }
            long concurrentSessions = 0;
            object rawConcurrent;
            if (root.TryGetValue("concurrentSessions", out rawConcurrent) && rawConcurrent != null)
                concurrentSessions = ReadInteger(rawConcurrent);
            if (concurrentSessions > 32) throw new InvalidDataException();

            var rawCharacters = root["characters"] as ArrayList;
            if (rawCharacters == null || rawCharacters.Count != PetRole.BuiltIns.Count) throw new InvalidDataException();
            var roles = new List<PetRole>();
            foreach (object rawRole in rawCharacters)
            {
                IDictionary<string, object> item = RequireObject(rawRole, new[] { "id", "name" }, new[] { "id", "name" });
                string id = RequiredText(item["id"], 48);
                string name = RequiredText(item["name"], 40);
                if (!ValidRoleId(id) || name.Length == 0) throw new InvalidDataException();
                roles.Add(new PetRole(id, name));
            }
            if (!roles.SequenceEqual(PetRole.BuiltIns)) throw new InvalidDataException();

            IDictionary<string, object> activityObject = RequireObject(root["activity"],
                new[] { "sessionId", "title", "agentId", "agentName", "status", "toolName", "lastActivityAt", "hint", "spotlight" },
                new[] { "status", "lastActivityAt" });
            string status = RequiredText(activityObject["status"], 16);
            if (status != "idle" && status != "working" && status != "tool" && status != "success" && status != "error")
                throw new InvalidDataException();
            long lastActivityAt = ReadInteger(activityObject["lastActivityAt"]);
            string hint = OptionalField(activityObject, "hint", 16);
            if (hint != null && hint != "confirming" && hint != "compacting" && hint != "interrupted")
                throw new InvalidDataException();

            PetSpotlight spotlight = null;
            object rawSpotlight;
            if (activityObject.TryGetValue("spotlight", out rawSpotlight) && rawSpotlight != null)
            {
                IDictionary<string, object> item = RequireObject(rawSpotlight, new[] { "kind", "at" }, new[] { "kind", "at" });
                string kind = RequiredText(item["kind"], 16);
                if (kind != "drawing") throw new InvalidDataException();
                spotlight = new PetSpotlight(kind, ReadInteger(item["at"]));
            }

            var rawNotifications = new ArrayList();
            object rawNotificationValue;
            if (root.TryGetValue("notifications", out rawNotificationValue) && rawNotificationValue != null)
            {
                rawNotifications = rawNotificationValue as ArrayList;
                if (rawNotifications == null) throw new InvalidDataException();
            }
            if (rawNotifications.Count > 8) throw new InvalidDataException();
            var notifications = new List<PetNotice>();
            var noticeIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (object rawNotice in rawNotifications)
            {
                IDictionary<string, object> item = RequireObject(rawNotice,
                    new[] { "id", "kind", "sessionId", "title", "at" }, new[] { "id", "kind", "at" });
                string id = RequiredText(item["id"], 96);
                if (!ValidNoticeId(id) || !noticeIds.Add(id)) throw new InvalidDataException();
                string kind = RequiredText(item["kind"], 16);
                if (kind != "confirmation" && kind != "completion") throw new InvalidDataException();
                long at = ReadInteger(item["at"]);
                notifications.Add(new PetNotice(id, kind,
                    OptionalField(item, "sessionId", 256),
                    OptionalField(item, "title", 120),
                    at));
            }

            return new PetSnapshotDTO(revision, roles, new PetActivity(
                OptionalField(activityObject, "sessionId", 256),
                OptionalField(activityObject, "title", 120),
                OptionalField(activityObject, "agentId", 128),
                OptionalField(activityObject, "agentName", 80),
                status,
                OptionalField(activityObject, "toolName", 80),
                lastActivityAt,
                hint,
                spotlight), followMode, (int)concurrentSessions, notifications.AsReadOnly());
        }

        private static IDictionary<string, object> RequireObject(object value, IEnumerable<string> allowed, IEnumerable<string> required)
        {
            var dictionary = value as IDictionary<string, object>;
            if (dictionary == null) throw new InvalidDataException();
            var allowSet = new HashSet<string>(allowed, StringComparer.Ordinal);
            foreach (string key in dictionary.Keys)
                if (!allowSet.Contains(key)) throw new InvalidDataException();
            foreach (string key in required)
                if (!dictionary.ContainsKey(key)) throw new InvalidDataException();
            return dictionary;
        }

        private static long ReadInteger(object value)
        {
            var number = value as StrictJsonNumber;
            long integer;
            if (number == null || !number.TryGetNonNegativeInt64(out integer)) throw new InvalidDataException();
            return integer;
        }

        private static string RequiredText(object value, int limit)
        {
            string raw = value as string;
            if (raw == null || raw.Any(Char.IsControl) || StringInfo.ParseCombiningCharacters(raw).Length > limit)
                throw new InvalidDataException();
            return raw.Trim();
        }

        private static string OptionalText(object value, int limit)
        {
            if (value == null) return null;
            string result = RequiredText(value, limit);
            return result.Length == 0 ? null : result;
        }

        // Optional fields may be absent entirely; a Dictionary indexer would throw instead.
        private static string OptionalField(IDictionary<string, object> source, string name, int limit)
        {
            object value;
            return source.TryGetValue(name, out value) ? OptionalText(value, limit) : null;
        }

        private static bool ValidRoleId(string value)
        {
            return value.Length > 0 && value.Length <= 48 && value.All(c =>
                (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-');
        }

        private static bool ValidNoticeId(string value)
        {
            return value.Length > 0 && value.Length <= 96 && value.All(c =>
                (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
                c == '_' || c == '.' || c == ':' || c == '-');
        }

        private static bool HasJsonContentType(PetHTTPRequest request)
        {
            foreach (KeyValuePair<string, string> header in request.Headers)
            {
                if (!String.Equals(header.Key, "content-type", StringComparison.OrdinalIgnoreCase)) continue;
                return String.Equals(header.Value, "application/json", StringComparison.OrdinalIgnoreCase) ||
                    header.Value.StartsWith("application/json;", StringComparison.OrdinalIgnoreCase);
            }
            return false;
        }

        private static object SelectionObject(PetSelection selection)
        {
            return new { schemaVersion = 4, characterId = selection.CharacterId, revision = selection.Revision, updatedAt = selection.UpdatedAt };
        }

        private static object PoseObject(PetPoseReadback state)
        {
            return new { schemaVersion = 4, characterId = state.CharacterId, pose = state.Pose,
                fallback = state.Fallback, since = state.Since, revision = state.Revision };
        }

        private PetHTTPResponse Json(int statusCode, object value)
        {
            var serializer = new JavaScriptSerializer();
            return new PetHTTPResponse(statusCode, Encoding.UTF8.GetBytes(serializer.Serialize(value)));
        }
    }

    /// <summary>Retains the JSON number token so integer checks cannot be fooled by floating-point rounding.</summary>
    internal sealed class StrictJsonNumber
    {
        private readonly string token;

        public StrictJsonNumber(string token) { this.token = token; }

        public bool TryGetNonNegativeInt64(out long value)
        {
            value = 0;
            if (String.IsNullOrEmpty(token)) return false;

            int position = token[0] == '-' ? 1 : 0;
            bool negative = position != 0;
            int exponentMarker = token.IndexOfAny(new[] { 'e', 'E' }, position);
            int mantissaEnd = exponentMarker < 0 ? token.Length : exponentMarker;
            bool afterDecimal = false;
            int fractionalDigits = 0;
            var digits = new StringBuilder(mantissaEnd - position);
            bool nonZero = false;
            for (int i = position; i < mantissaEnd; i++)
            {
                char current = token[i];
                if (current == '.')
                {
                    afterDecimal = true;
                    continue;
                }
                digits.Append(current);
                if (afterDecimal) fractionalDigits++;
                if (current != '0') nonZero = true;
            }
            if (!nonZero) return true;
            if (negative) return false;

            int exponent = 0;
            if (exponentMarker >= 0)
            {
                int exponentPosition = exponentMarker + 1;
                bool exponentNegative = false;
                if (exponentPosition < token.Length && (token[exponentPosition] == '+' || token[exponentPosition] == '-'))
                {
                    exponentNegative = token[exponentPosition] == '-';
                    exponentPosition++;
                }
                for (int i = exponentPosition; i < token.Length; i++)
                {
                    int digit = token[i] - '0';
                    if (exponent < 1000000) exponent = Math.Min(1000000, exponent * 10 + digit);
                }
                if (exponentNegative) exponent = -exponent;
            }

            long scale = (long)exponent - fractionalDigits;
            string coefficient = digits.ToString();
            int firstNonZero = 0;
            while (firstNonZero < coefficient.Length && coefficient[firstNonZero] == '0') firstNonZero++;
            coefficient = coefficient.Substring(firstNonZero);

            if (scale < 0)
            {
                long trimCount = -scale;
                if (trimCount > coefficient.Length) return false;
                int retainedLength = coefficient.Length - (int)trimCount;
                if (retainedLength == 0) return false;
                for (int i = retainedLength; i < coefficient.Length; i++)
                    if (coefficient[i] != '0') return false;
                coefficient = coefficient.Substring(0, retainedLength);
            }
            else if (scale > 0)
            {
                if ((long)coefficient.Length + scale > 19) return false;
                coefficient += new String('0', (int)scale);
            }

            if (coefficient.Length > 19) return false;
            return Int64.TryParse(coefficient, NumberStyles.None, CultureInfo.InvariantCulture, out value);
        }
    }

    /// <summary>Small strict JSON parser that rejects duplicate object keys before values reach DTO validation.</summary>
    internal sealed class StrictJson
    {
        private readonly string text;
        private int position;
        private int depth;

        private StrictJson(string text) { this.text = text; }

        public static object Parse(byte[] bytes)
        {
            string json;
            try { json = new UTF8Encoding(false, true).GetString(bytes); }
            catch (DecoderFallbackException) { throw new FormatException("Invalid UTF-8 JSON."); }
            var parser = new StrictJson(json);
            object value = parser.ReadValue();
            parser.SkipWhiteSpace();
            if (parser.position != parser.text.Length) throw new FormatException("Trailing JSON data.");
            return value;
        }

        private object ReadValue()
        {
            SkipWhiteSpace();
            if (position >= text.Length) throw new FormatException("Missing JSON value.");
            char current = text[position];
            if (current == '{') return ReadObject();
            if (current == '[') return ReadArray();
            if (current == '"') return ReadString();
            if (current == 't') { ReadLiteral("true"); return true; }
            if (current == 'f') { ReadLiteral("false"); return false; }
            if (current == 'n') { ReadLiteral("null"); return null; }
            if (current == '-' || (current >= '0' && current <= '9')) return ReadNumber();
            throw new FormatException("Invalid JSON value.");
        }

        private IDictionary<string, object> ReadObject()
        {
            Enter();
            position++;
            SkipWhiteSpace();
            var result = new Dictionary<string, object>(StringComparer.Ordinal);
            if (Take('}')) { Leave(); return result; }
            while (true)
            {
                SkipWhiteSpace();
                if (position >= text.Length || text[position] != '"') throw new FormatException("Invalid object key.");
                string key = ReadString();
                if (result.ContainsKey(key)) throw new FormatException("Duplicate JSON property.");
                SkipWhiteSpace();
                Require(':');
                object value = ReadValue();
                result.Add(key, value);
                SkipWhiteSpace();
                if (Take('}')) break;
                Require(',');
            }
            Leave();
            return result;
        }

        private ArrayList ReadArray()
        {
            Enter();
            position++;
            SkipWhiteSpace();
            var result = new ArrayList();
            if (Take(']')) { Leave(); return result; }
            while (true)
            {
                result.Add(ReadValue());
                SkipWhiteSpace();
                if (Take(']')) break;
                Require(',');
            }
            Leave();
            return result;
        }

        private string ReadString()
        {
            Require('"');
            var builder = new StringBuilder();
            while (position < text.Length)
            {
                char current = text[position++];
                if (current == '"')
                {
                    string result = builder.ToString();
                    if (!HasValidSurrogatePairs(result)) throw new FormatException("Invalid unicode surrogate sequence.");
                    return result;
                }
                if (current < 0x20) throw new FormatException("Control character in JSON string.");
                if (current != '\\') { builder.Append(current); continue; }
                if (position >= text.Length) throw new FormatException("Incomplete string escape.");
                char escape = text[position++];
                switch (escape)
                {
                    case '"': builder.Append('"'); break;
                    case '\\': builder.Append('\\'); break;
                    case '/': builder.Append('/'); break;
                    case 'b': builder.Append('\b'); break;
                    case 'f': builder.Append('\f'); break;
                    case 'n': builder.Append('\n'); break;
                    case 'r': builder.Append('\r'); break;
                    case 't': builder.Append('\t'); break;
                    case 'u': builder.Append(ReadUnicodeEscape()); break;
                    default: throw new FormatException("Invalid string escape.");
                }
            }
            throw new FormatException("Unterminated JSON string.");
        }

        private char ReadUnicodeEscape()
        {
            if (position + 4 > text.Length) throw new FormatException("Incomplete unicode escape.");
            int value = 0;
            for (int i = 0; i < 4; i++)
            {
                char c = text[position++];
                int digit;
                if (c >= '0' && c <= '9') digit = c - '0';
                else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
                else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
                else throw new FormatException("Invalid unicode escape.");
                value = (value << 4) | digit;
            }
            return (char)value;
        }

        private object ReadNumber()
        {
            int start = position;
            if (Take('-') && position >= text.Length) throw new FormatException("Invalid number.");
            if (Take('0'))
            {
                if (position < text.Length && Char.IsDigit(text[position])) throw new FormatException("Leading zero.");
            }
            else
            {
                if (position >= text.Length || text[position] < '1' || text[position] > '9') throw new FormatException("Invalid number.");
                while (position < text.Length && IsDigit(text[position])) position++;
            }
            if (Take('.'))
            {
                if (position >= text.Length || !IsDigit(text[position])) throw new FormatException("Invalid fraction.");
                while (position < text.Length && IsDigit(text[position])) position++;
            }
            if (Take('e') || Take('E'))
            {
                if (!Take('+')) Take('-');
                if (position >= text.Length || !IsDigit(text[position])) throw new FormatException("Invalid exponent.");
                while (position < text.Length && IsDigit(text[position])) position++;
            }
            string token = text.Substring(start, position - start);
            return new StrictJsonNumber(token);
        }

        private void ReadLiteral(string literal)
        {
            if (position + literal.Length > text.Length || String.CompareOrdinal(text, position, literal, 0, literal.Length) != 0)
                throw new FormatException("Invalid literal.");
            position += literal.Length;
        }

        private void SkipWhiteSpace()
        {
            while (position < text.Length && (text[position] == ' ' || text[position] == '\t' || text[position] == '\r' || text[position] == '\n')) position++;
        }

        private bool Take(char expected)
        {
            if (position < text.Length && text[position] == expected) { position++; return true; }
            return false;
        }

        private void Require(char expected)
        {
            if (!Take(expected)) throw new FormatException("Unexpected JSON character.");
        }

        private void Enter()
        {
            depth++;
            if (depth > 32) throw new FormatException("JSON nesting is too deep.");
        }

        private void Leave() { depth--; }
        private static bool IsDigit(char c) { return c >= '0' && c <= '9'; }

        private static bool HasValidSurrogatePairs(string value)
        {
            for (int i = 0; i < value.Length; i++)
            {
                if (Char.IsHighSurrogate(value[i]))
                {
                    if (i + 1 >= value.Length || !Char.IsLowSurrogate(value[i + 1])) return false;
                    i++;
                }
                else if (Char.IsLowSurrogate(value[i])) return false;
            }
            return true;
        }
    }
}
