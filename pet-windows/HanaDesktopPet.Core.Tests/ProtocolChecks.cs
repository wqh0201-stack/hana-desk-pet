using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Web.Script.Serialization;
using HanaDesktopPet.Core;

namespace HanaDesktopPet.Core.Tests
{
    /// <summary>Framework-free checks for protocol and state behavior using synthetic DTOs only.</summary>
    public static class ProtocolChecks
    {
        public static void Run()
        {
            CheckStateTimingAndSelection();
            CheckPoseReadback();
            CheckSnapshotWhitelist();
            CheckV4Fields();
            CheckSelectionProtocol();
            CheckHttpCodecBoundaries();
        }

        private static void CheckStateTimingAndSelection()
        {
            var store = new PetStateStore();
            PetViewState initial = store.ViewState(10000);
            Check(!initial.AppConnected && initial.DisplayStatus == "idle" && initial.DisplayHint == null,
                "A new store starts disconnected and idle.");

            Check(store.Ingest(ValidSnapshot(3, "working", "confirming"), 20000) == SnapshotIngestResult.Accepted,
                "Initial snapshot accepted.");
            PetViewState live = store.ViewState(28000);
            Check(live.AppConnected && live.DisplayStatus == "working" && live.DisplayHint == "confirming",
                "Snapshot remains connected through the 8 second boundary.");
            PetViewState expired = store.ViewState(28001);
            Check(!expired.AppConnected && expired.Activity.Status == "working" &&
                expired.DisplayStatus == "idle" && expired.DisplayHint == null,
                "Expired snapshot data remains stored while display status and hint reset.");
            Check(store.Ingest(ValidSnapshot(2, "idle"), 30000) == SnapshotIngestResult.Stale,
                "Older snapshot revisions are rejected.");

            PetSelection selection = store.SelectLocally("gpt", 10);
            Check(selection != null && selection.CharacterId == "gpt" && selection.Revision == 1 && selection.UpdatedAt == 10,
                "Local selection increments revision and advances timestamp monotonically.");
            Check(Object.ReferenceEquals(store.SelectLocally("gpt", 99), selection),
                "Selecting the current role is idempotent.");
            Check(store.SelectLocally("unknown", 99) == null, "Unknown local role cannot be selected.");

            List<PetRole> rolesWithoutGpt = PetRole.BuiltIns.Where(delegate(PetRole role) { return role.Id != "gpt"; }).ToList();
            SnapshotIngestResult corrected = store.Ingest(new PetSnapshotDTO(4, rolesWithoutGpt, new PetActivity()), 40000);
            PetSelection correctedSelection = store.CurrentSelection();
            Check(corrected == SnapshotIngestResult.Accepted && correctedSelection.CharacterId == "claude" && correctedSelection.Revision == 2,
                "If a snapshot removes the selected role, selection falls back to the first role and advances revision.");
        }

        private static void CheckPoseReadback()
        {
            var readback = new PetPoseReadbackStore();
            PetPoseReadback initial = readback.Current();
            PetPoseReadback unchanged = readback.Update("claude", "idle", false, 10);
            Check(unchanged.Equals(initial), "An unchanged rendered pose does not increment readback revision.");
            PetPoseReadback changed = readback.Update("gpt", "thinking", true, 5);
            Check(changed.CharacterId == "gpt" && changed.Pose == "thinking" && changed.Fallback &&
                changed.Since >= initial.Since + 1 && changed.Revision == initial.Revision + 1,
                "Pose readback reports the resolved pose, fallback state, and monotonic revision.");
            PetPoseReadback fallbackOnly = readback.Update("gpt", "thinking", false, 100);
            Check(fallbackOnly.Since == changed.Since && fallbackOnly.Revision == changed.Revision + 1,
                "Fallback-only changes increment revision without resetting pose age.");
        }

        private static void CheckSnapshotWhitelist()
        {
            var store = new PetStateStore();
            var api = new PetAPI(store, new PetPoseReadbackStore());
            PetHTTPResponse good = api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson()));
            Check(good.StatusCode == 200 && store.ViewState().Activity.Title == "Synthetic session",
                "A valid allowlisted synthetic snapshot is accepted.");

            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(extraRootField: true))).StatusCode == 400,
                "Unknown root properties are rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(duplicateRevision: true))).StatusCode == 400,
                "Duplicate JSON properties are rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(fractionalRevision: true))).StatusCode == 400,
                "Fractional revision values are rejected.");
            string highPrecisionFraction = SnapshotJson().Replace("\"revision\":1,", "\"revision\":1.000000000000000000000000000001,");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", highPrecisionFraction)).StatusCode == 400,
                "A high-precision fractional revision cannot round into an integer.");
            string integralExponent = SnapshotJson().Replace("\"revision\":1,", "\"revision\":1.0e0,");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", integralExponent)).StatusCode == 200,
                "Mathematically integral exponent-form revisions are accepted.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(booleanActivityTime: true))).StatusCode == 400,
                "Boolean timestamps are rejected as non-integers.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(extraActivityField: true))).StatusCode == 400,
                "Unapproved activity fields are rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(controlInTitle: true))).StatusCode == 400,
                "Control characters in text are rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(longTitle: true))).StatusCode == 400,
                "Text over the field limit is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", SnapshotJson(reorderedRoles: true))).StatusCode == 400,
                "Character roster and order must exactly match the built-in whitelist.");

            var noContentType = new PetHTTPRequest("POST", "/v4/snapshot", new Dictionary<string, string>(), Encoding.UTF8.GetBytes(SnapshotJson()));
            Check(api.Handle(noContentType).StatusCode == 415, "Snapshot endpoint requires JSON content type.");
            Check(api.Handle(new PetHTTPRequest("GET", "/v4/snapshot", new Dictionary<string, string>(), new byte[0])).StatusCode == 405,
                "Known endpoints reject the wrong HTTP method.");
            Check(api.Handle(new PetHTTPRequest("GET", "/other", new Dictionary<string, string>(), new byte[0])).StatusCode == 404,
                "Unknown paths return not found.");
            Check(api.Handle(new PetHTTPRequest("GET", "/v3/hello", new Dictionary<string, string>(), new byte[0])).StatusCode == 404,
                "The retired v3 route is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v3/snapshot", SnapshotJson())).StatusCode == 404,
                "The retired v3 snapshot route is rejected.");
        }

        private static void CheckV4Fields()
        {
            var store = new PetStateStore();
            var api = new PetAPI(store, new PetPoseReadbackStore());
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson())).StatusCode == 200,
                "A bounded v4 snapshot with follow, concurrency, notices and a spotlight is accepted.");
            PetViewState state = store.ViewState();
            Check(state.FollowMode == "pinned" && state.ConcurrentSessions == 3 &&
                state.Notifications.Count == 1 && state.Activity.Spotlight != null &&
                state.Activity.Spotlight.Kind == "drawing" && state.Activity.Spotlight.At == 123,
                "The v4 metadata is projected without touching activity status.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(badMode: true))).StatusCode == 400,
                "An unknown follow mode is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(badConcurrency: true))).StatusCode == 400,
                "Out-of-range concurrency is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(tooManyNotices: true))).StatusCode == 400,
                "More than eight notices are rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(badNoticeId: true))).StatusCode == 400,
                "An unsafe notice id is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(badNoticeKind: true))).StatusCode == 400,
                "An unknown notice kind is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(badSpotlight: true))).StatusCode == 400,
                "An unknown spotlight kind is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(duplicateNotice: true))).StatusCode == 400,
                "Duplicate notice ids are rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(wrongModeType: true))).StatusCode == 400,
                "A non-string follow mode is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(wrongConcurrencyType: true))).StatusCode == 400,
                "A non-integer concurrency count is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(wrongNoticesType: true))).StatusCode == 400,
                "A non-array notifications value is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(missingSpotlightAt: true))).StatusCode == 400,
                "A spotlight without its timestamp is rejected.");
            Check(api.Handle(JsonRequest("POST", "/v4/snapshot", V4SnapshotJson(unknownRoot: true))).StatusCode == 400,
                "An unknown v4 root field is rejected.");
            Check(store.ViewState().FollowMode == "pinned",
                "A rejected v4 field never mutates the accepted snapshot.");
        }

        private static string V4SnapshotJson(bool badMode = false, bool badConcurrency = false,
            bool tooManyNotices = false, bool badNoticeId = false, bool badNoticeKind = false,
            bool badSpotlight = false, bool duplicateNotice = false, bool wrongModeType = false,
            bool wrongConcurrencyType = false, bool wrongNoticesType = false,
            bool missingSpotlightAt = false, bool unknownRoot = false)
        {
            string characters = String.Join(",", PetRole.BuiltIns.Select(role =>
                "{\"id\":\"" + role.Id + "\",\"name\":\"" + role.Name + "\"}"));
            string mode = badMode ? "\"other\"" : (wrongModeType ? "4" : "\"pinned\"");
            string concurrency = badConcurrency ? "33" : (wrongConcurrencyType ? "\"3\"" : "3");
            string notices;
            if (tooManyNotices)
            {
                notices = "[" + String.Join(",", Enumerable.Range(0, 9).Select(index =>
                    "{\"id\":\"completion:0badf00d:" + index + "\",\"kind\":\"completion\",\"at\":" + index + "}").ToArray()) + "]";
            }
            else if (badNoticeId)
            {
                notices = "[{\"id\":\"bad id!/../x\",\"kind\":\"completion\",\"at\":1}]";
            }
            else if (badNoticeKind)
            {
                notices = "[{\"id\":\"completion:0badf00d:1\",\"kind\":\"success\",\"at\":1}]";
            }
            else if (duplicateNotice)
            {
                notices = "[{\"id\":\"completion:0badf00d:1\",\"kind\":\"completion\",\"at\":1}," +
                    "{\"id\":\"completion:0badf00d:1\",\"kind\":\"completion\",\"at\":2}]";
            }
            else if (wrongNoticesType)
            {
                notices = "\"none\"";
            }
            else
            {
                notices = "[{\"id\":\"confirmation:0badf00d:122\",\"kind\":\"confirmation\",\"sessionId\":\"synthetic-session\",\"title\":\"Synthetic session\",\"at\":122}]";
            }
            string spotlight;
            if (badSpotlight)
                spotlight = ",\"spotlight\":{\"kind\":\"video\",\"at\":123}";
            else if (missingSpotlightAt)
                spotlight = ",\"spotlight\":{\"kind\":\"drawing\"}";
            else
                spotlight = ",\"spotlight\":{\"kind\":\"drawing\",\"at\":123}";
            return "{\"schemaVersion\":4,\"revision\":2,\"characters\":[" + characters + "]," +
                "\"followMode\":" + mode + ",\"concurrentSessions\":" + concurrency +
                ",\"notifications\":" + notices +
                (unknownRoot ? ",\"unexpected\":1" : "") +
                ",\"activity\":{\"sessionId\":\"synthetic-session\",\"title\":\"Synthetic session\"," +
                "\"agentId\":\"agent\",\"agentName\":\"Agent\",\"status\":\"working\",\"toolName\":\"tool\"," +
                "\"lastActivityAt\":123" + spotlight + "}}";
        }

        private static void CheckSelectionProtocol()
        {
            var store = new PetStateStore();
            var api = new PetAPI(store, new PetPoseReadbackStore());
            PetHTTPResponse selected = api.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"gpt\",\"expectedRevision\":0,\"updatedAt\":100}"));
            Check(selected.StatusCode == 200 && store.CurrentSelection().CharacterId == "gpt" && store.CurrentSelection().Revision == 1,
                "A valid revision-checked remote selection updates state.");
            PetHTTPResponse conflict = api.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"claude\",\"expectedRevision\":0,\"updatedAt\":200}"));
            Check(conflict.StatusCode == 409 && store.CurrentSelection().CharacterId == "gpt",
                "Stale selection writes return the current state as a conflict.");
            PetHTTPResponse unknown = api.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"not-a-role\",\"expectedRevision\":1,\"updatedAt\":200}"));
            Check(unknown.StatusCode == 400 && JsonString(unknown.Body, "error") == "unknown_character",
                "Syntactically valid but unavailable roles are rejected.");
            PetHTTPResponse duplicate = api.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"claude\",\"expectedRevision\":1,\"updatedAt\":200,\"updatedAt\":201}"));
            Check(duplicate.StatusCode == 400, "Duplicate selection fields are rejected.");
            PetHTTPResponse overflow = api.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"claude\",\"expectedRevision\":9223372036854775808,\"updatedAt\":200}"));
            Check(overflow.StatusCode == 400, "Out-of-range integers are rejected.");

            var numericApi = new PetAPI(new PetStateStore(), new PetPoseReadbackStore());
            PetHTTPResponse maximumTimestamp = numericApi.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"gpt\",\"expectedRevision\":0,\"updatedAt\":9223372036854775807.0}"));
            Check(maximumTimestamp.StatusCode == 200 && JsonSelectionLong(maximumTimestamp.Body, "updatedAt") == Int64.MaxValue,
                "The exact Int64 upper bound remains valid when written as an integral decimal.");
            PetHTTPResponse roundedFraction = numericApi.Handle(JsonRequest("POST", "/v4/selection",
                "{\"schemaVersion\":4,\"characterId\":\"claude\",\"expectedRevision\":1,\"updatedAt\":1.000000000000000000000000000001}"));
            Check(roundedFraction.StatusCode == 400,
                "A high-precision fractional timestamp cannot round into an integer.");

            PetHTTPResponse hello = api.Handle(new PetHTTPRequest("GET", "/v4/hello", new Dictionary<string, string>(), new byte[0]));
            Check(hello.StatusCode == 200 && JsonLong(hello.Body, "protocolVersion") == 4,
                "Hello identifies protocol version 4.");

            var readback = new PetPoseReadbackStore();
            readback.Update("deepseek", "tool", true, 123456);
            PetHTTPResponse stateResponse = new PetAPI(store, readback).Handle(
                new PetHTTPRequest("GET", "/v4/state", new Dictionary<string, string>(), new byte[0]));
            Check(stateResponse.StatusCode == 200 && JsonString(stateResponse.Body, "characterId") == "deepseek" &&
                JsonString(stateResponse.Body, "pose") == "tool" && JsonBoolean(stateResponse.Body, "fallback"),
                "State endpoint reports the renderer's actual pose readback.");
        }

        private static void CheckHttpCodecBoundaries()
        {
            byte[] head = Encoding.ASCII.GetBytes("POST /v4/snapshot HTTP/1.1\r\nHost: 127.0.0.1:43127\r\ncontent-type: application/json\r\nContent-Length: 2\r\n\r\n");
            Check(PetHTTPCodec.Parse(head) == null, "Partial Content-Length bodies remain incomplete.");
            byte[] body = Encoding.ASCII.GetBytes("{}");
            var complete = head.Concat(body).ToArray();
            PetHTTPRequest parsed = PetHTTPCodec.Parse(complete);
            Check(parsed != null && parsed.Method == "POST" && parsed.Path == "/v4/snapshot" && parsed.Body.Length == 2 &&
                parsed.Headers["content-type"] == "application/json",
                "A complete request parses with normalized header names.");

            ExpectParseError("duplicate headers", Encoding.ASCII.GetBytes("GET / HTTP/1.1\r\nContent-Length: 0\r\ncontent-length: 0\r\n\r\n"), HTTPParseError.Malformed);
            ExpectParseError("chunked encoding", Encoding.ASCII.GetBytes("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), HTTPParseError.UnsupportedTransferEncoding);
            ExpectParseError("unexpected body tail", Encoding.ASCII.GetBytes("POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\na!"), HTTPParseError.UnexpectedTrailingBytes);
            ExpectParseError("body over limit", Encoding.ASCII.GetBytes("POST / HTTP/1.1\r\nContent-Length: " + (PetHTTPCodec.MaxBodyBytes + 1) + "\r\n\r\n"), HTTPParseError.BodyTooLarge);
            ExpectParseError("non-decimal content length", Encoding.ASCII.GetBytes("POST / HTTP/1.1\r\nContent-Length: +1\r\n\r\n"), HTTPParseError.Malformed);
            ExpectParseError("header over limit", new byte[PetHTTPCodec.MaxHeaderBytes + 1], HTTPParseError.HeaderTooLarge);
            ExpectParseError("invalid utf8 headers", new byte[] { 0xFF, 0x0D, 0x0A, 0x0D, 0x0A }, HTTPParseError.Malformed);

            byte[] encoded = PetHTTPCodec.Encode(new PetHTTPResponse(200, Encoding.UTF8.GetBytes("{}")));
            string encodedText = Encoding.ASCII.GetString(encoded);
            Check(encodedText.Contains("Content-Length: 2\r\n") && encodedText.Contains("Connection: close\r\n"),
                "Responses declare exact length and close the connection.");
        }

        private static PetSnapshotDTO ValidSnapshot(long revision, string status, string hint = null)
        {
            return new PetSnapshotDTO(revision, PetRole.BuiltIns,
                new PetActivity("synthetic-session", "Synthetic session", "agent", "Agent", status, "tool", 123, hint));
        }

        private static string SnapshotJson(bool extraRootField = false, bool duplicateRevision = false,
            bool fractionalRevision = false, bool booleanActivityTime = false, bool extraActivityField = false,
            bool controlInTitle = false, bool longTitle = false, bool reorderedRoles = false)
        {
            IEnumerable<PetRole> roles = reorderedRoles ? PetRole.BuiltIns.Reverse() : PetRole.BuiltIns;
            string characters = String.Join(",", roles.Select(role => "{\"id\":\"" + role.Id + "\",\"name\":\"" + role.Name + "\"}"));
            string title = controlInTitle ? "Synthetic\\n session" : (longTitle ? new String('x', 121) : "Synthetic session");
            string activityExtra = extraActivityField ? ",\"prompt\":\"forbidden\"" : "";
            string revision = fractionalRevision ? "1.5" : (duplicateRevision ? "1,\"revision\":1" : "1");
            string activityTime = booleanActivityTime ? "true" : "123";
            return "{\"schemaVersion\":4,\"revision\":" + revision + ",\"characters\":[" + characters + "]," +
                "\"activity\":{\"sessionId\":\"synthetic-session\",\"title\":\"" + title + "\",\"agentId\":\"agent\",\"agentName\":\"Agent\",\"status\":\"working\",\"toolName\":\"tool\",\"lastActivityAt\":" + activityTime + activityExtra + "}" +
                (extraRootField ? ",\"prompt\":\"forbidden\"}" : "}");
        }

        private static PetHTTPRequest JsonRequest(string method, string path, string body)
        {
            return new PetHTTPRequest(method, path, new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "content-type", "application/json" }
            }, Encoding.UTF8.GetBytes(body));
        }

        private static string JsonString(byte[] body, string property)
        {
            var serializer = new JavaScriptSerializer();
            IDictionary<string, object> value = (IDictionary<string, object>)serializer.DeserializeObject(Encoding.UTF8.GetString(body));
            return (string)value[property];
        }

        private static long JsonLong(byte[] body, string property)
        {
            var serializer = new JavaScriptSerializer();
            IDictionary<string, object> value = (IDictionary<string, object>)serializer.DeserializeObject(Encoding.UTF8.GetString(body));
            return Convert.ToInt64(value[property]);
        }

        // POST /v4/selection answers with the updated selection wrapped in a "selection" envelope.
        private static long JsonSelectionLong(byte[] body, string property)
        {
            var serializer = new JavaScriptSerializer();
            IDictionary<string, object> value = (IDictionary<string, object>)serializer.DeserializeObject(Encoding.UTF8.GetString(body));
            IDictionary<string, object> selection = (IDictionary<string, object>)value["selection"];
            return Convert.ToInt64(selection[property]);
        }

        private static bool JsonBoolean(byte[] body, string property)
        {
            var serializer = new JavaScriptSerializer();
            IDictionary<string, object> value = (IDictionary<string, object>)serializer.DeserializeObject(Encoding.UTF8.GetString(body));
            return (bool)value[property];
        }

        private static void ExpectParseError(string name, byte[] bytes, HTTPParseError expected)
        {
            try { PetHTTPCodec.Parse(bytes); }
            catch (PetHTTPParseException exception)
            {
                if (exception.Error == expected) return;
                throw new InvalidOperationException("Protocol check failed: " + name + " threw " + exception.Error + ".");
            }
            throw new InvalidOperationException("Protocol check failed: " + name + " should throw " + expected + ".");
        }

        private static void Check(bool condition, string message)
        {
            if (!condition) throw new InvalidOperationException("Protocol check failed: " + message);
        }
    }
}
