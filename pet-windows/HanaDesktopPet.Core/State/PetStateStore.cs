using System;
using System.Collections.Generic;
using System.Linq;

namespace HanaDesktopPet.Core
{
    public sealed class PetRole : IEquatable<PetRole>
    {
        private static readonly IReadOnlyList<PetRole> BuiltInRoles = Array.AsReadOnly(new[]
        {
            new PetRole("claude", "Claude"),
            new PetRole("gpt", "GPT 白龙"),
            new PetRole("deepseek", "DeepSeek 大肥鱼"),
            new PetRole("gemini", "Gemini"),
            new PetRole("glm", "GLM 黑狐狸"),
            new PetRole("deepseek-hoodie", "大肥鱼·Claude 卫衣"),
            new PetRole("gpt-onesie", "GPT 降智龙崽")
        });

        public string Id { get; private set; }
        public string Name { get; private set; }
        public static IReadOnlyList<PetRole> BuiltIns { get { return BuiltInRoles; } }

        public PetRole(string id, string name)
        {
            Id = id;
            Name = name;
        }

        public bool Equals(PetRole other)
        {
            return other != null && Id == other.Id && Name == other.Name;
        }

        public override bool Equals(object obj) { return Equals(obj as PetRole); }
        public override int GetHashCode() { return (Id ?? "").GetHashCode() * 397 ^ (Name ?? "").GetHashCode(); }
    }

    public sealed class PetActivity
    {
        public string SessionId { get; private set; }
        public string Title { get; private set; }
        public string AgentId { get; private set; }
        public string AgentName { get; private set; }
        public string Status { get; private set; }
        public string ToolName { get; private set; }
        public long LastActivityAt { get; private set; }
        public string Hint { get; private set; }

        public PetActivity(string sessionId = null, string title = null, string agentId = null,
            string agentName = null, string status = "idle", string toolName = null,
            long lastActivityAt = 0, string hint = null)
        {
            SessionId = sessionId;
            Title = title;
            AgentId = agentId;
            AgentName = agentName;
            Status = status;
            ToolName = toolName;
            LastActivityAt = lastActivityAt;
            Hint = hint;
        }
    }

    public sealed class PetSelection
    {
        public string CharacterId { get; private set; }
        public long Revision { get; private set; }
        public long UpdatedAt { get; private set; }

        public PetSelection(string characterId = "claude", long revision = 0, long updatedAt = 0)
        {
            CharacterId = characterId;
            Revision = Math.Max(0, revision);
            UpdatedAt = Math.Max(0, updatedAt);
        }
    }

    public sealed class PetViewState
    {
        public IReadOnlyList<PetRole> Roles { get; private set; }
        public PetActivity Activity { get; private set; }
        public PetSelection Selection { get; private set; }
        public bool AppConnected { get; private set; }
        public string DisplayStatus { get { return AppConnected ? Activity.Status : "idle"; } }
        public string DisplayHint { get { return AppConnected ? Activity.Hint : null; } }

        public PetViewState(IReadOnlyList<PetRole> roles, PetActivity activity, PetSelection selection, bool appConnected)
        {
            Roles = roles;
            Activity = activity;
            Selection = selection;
            AppConnected = appConnected;
        }
    }

    public sealed class PetSnapshotDTO
    {
        public long Revision { get; private set; }
        public IReadOnlyList<PetRole> Characters { get; private set; }
        public PetActivity Activity { get; private set; }

        public PetSnapshotDTO(long revision, IReadOnlyList<PetRole> characters, PetActivity activity)
        {
            Revision = revision;
            Characters = characters;
            Activity = activity;
        }
    }

    public enum SnapshotIngestResult { Accepted, Stale }
    public enum SelectionWriteResultKind { Updated, Conflict, UnknownRole }

    public sealed class SelectionWriteResult
    {
        public SelectionWriteResultKind Kind { get; private set; }
        public PetSelection Selection { get; private set; }
        public SelectionWriteResult(SelectionWriteResultKind kind, PetSelection selection)
        {
            Kind = kind;
            Selection = selection;
        }
    }

    /// <summary>In-memory state owner. It never reads or writes Hana or CrossPet configuration.</summary>
    public sealed class PetStateStore
    {
        private const long ConnectionTimeoutMs = 8000;
        private readonly object gate = new object();
        private IReadOnlyList<PetRole> roles = PetRole.BuiltIns;
        private PetActivity activity = new PetActivity();
        private PetSelection selection;
        private long snapshotRevision;
        private long lastSnapshotReceivedAt;

        public PetStateStore(PetSelection initialSelection = null)
        {
            selection = initialSelection ?? new PetSelection();
            selection = new PetSelection(selection.CharacterId, selection.Revision, selection.UpdatedAt);
        }

        public PetViewState ViewState(long? now = null)
        {
            lock (gate)
            {
                long instant = now.HasValue ? now.Value : NowMilliseconds();
                bool connected = lastSnapshotReceivedAt > 0 && instant >= lastSnapshotReceivedAt &&
                    instant - lastSnapshotReceivedAt <= ConnectionTimeoutMs;
                return new PetViewState(roles, activity, selection, connected);
            }
        }

        public PetSelection CurrentSelection()
        {
            lock (gate) return selection;
        }

        public PetSelection SelectLocally(string characterId, long? now = null)
        {
            lock (gate)
            {
                if (!roles.Any(role => role.Id == characterId)) return null;
                if (selection.CharacterId == characterId) return selection;
                long instant = now.HasValue ? now.Value : NowMilliseconds();
                selection = new PetSelection(characterId, Increment(selection.Revision),
                    Math.Max(Math.Max(0, instant), Increment(selection.UpdatedAt)));
                return selection;
            }
        }

        public SnapshotIngestResult Ingest(PetSnapshotDTO snapshot, long? receivedAt = null)
        {
            lock (gate)
            {
                if (snapshot.Revision < snapshotRevision) return SnapshotIngestResult.Stale;
                snapshotRevision = snapshot.Revision;
                roles = Array.AsReadOnly(snapshot.Characters.ToArray());
                activity = snapshot.Activity;
                long instant = Math.Max(0, receivedAt.HasValue ? receivedAt.Value : NowMilliseconds());
                lastSnapshotReceivedAt = Math.Max(instant, lastSnapshotReceivedAt);
                if (!roles.Any(role => role.Id == selection.CharacterId) && roles.Count > 0)
                    selection = new PetSelection(roles[0].Id, Increment(selection.Revision),
                        Math.Max(instant, Increment(selection.UpdatedAt)));
                return SnapshotIngestResult.Accepted;
            }
        }

        public SelectionWriteResult WriteRemoteSelection(string characterId, long expectedRevision,
            long updatedAt, long? now = null)
        {
            lock (gate)
            {
                if (expectedRevision != selection.Revision)
                    return new SelectionWriteResult(SelectionWriteResultKind.Conflict, selection);
                if (!roles.Any(role => role.Id == characterId))
                    return new SelectionWriteResult(SelectionWriteResultKind.UnknownRole, selection);
                if (selection.CharacterId == characterId)
                    return new SelectionWriteResult(SelectionWriteResultKind.Updated, selection);
                long instant = now.HasValue ? now.Value : NowMilliseconds();
                selection = new PetSelection(characterId, Increment(selection.Revision),
                    Math.Max(Math.Max(Math.Max(0, updatedAt), Math.Max(0, instant)), Increment(selection.UpdatedAt)));
                return new SelectionWriteResult(SelectionWriteResultKind.Updated, selection);
            }
        }

        public static long NowMilliseconds()
        {
            return (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;
        }

        private static long Increment(long value) { return value == long.MaxValue ? value : value + 1; }
    }

    public sealed class PetPoseReadback : IEquatable<PetPoseReadback>
    {
        public string CharacterId { get; private set; }
        public string Pose { get; private set; }
        public bool Fallback { get; private set; }
        public long Since { get; private set; }
        public long Revision { get; private set; }

        public PetPoseReadback(string characterId, string pose, bool fallback, long since, long revision)
        {
            CharacterId = characterId;
            Pose = pose;
            Fallback = fallback;
            Since = Math.Max(0, since);
            Revision = Math.Max(0, revision);
        }

        public bool Equals(PetPoseReadback other)
        {
            return other != null && CharacterId == other.CharacterId && Pose == other.Pose &&
                Fallback == other.Fallback && Since == other.Since && Revision == other.Revision;
        }

        public override bool Equals(object obj) { return Equals(obj as PetPoseReadback); }
        public override int GetHashCode() { return (CharacterId ?? "").GetHashCode() * 397 ^ (Pose ?? "").GetHashCode(); }
    }

    /// <summary>Thread-safe readback of the pose the native renderer has already resolved.</summary>
    public sealed class PetPoseReadbackStore
    {
        private readonly object gate = new object();
        private PetPoseReadback state = new PetPoseReadback("claude", "idle", false, PetStateStore.NowMilliseconds(), 0);

        public PetPoseReadback Current()
        {
            lock (gate) return state;
        }

        public PetPoseReadback Update(string characterId, string pose, bool fallback, long? now = null)
        {
            lock (gate)
            {
                bool poseChanged = state.CharacterId != characterId || state.Pose != pose;
                bool changed = poseChanged || state.Fallback != fallback;
                if (!changed) return state;
                long instant = now.HasValue ? now.Value : PetStateStore.NowMilliseconds();
                long since = poseChanged ? Math.Max(Math.Max(0, instant), Increment(state.Since)) : state.Since;
                state = new PetPoseReadback(characterId, pose, fallback, since, Increment(state.Revision));
                return state;
            }
        }

        private static long Increment(long value) { return value == long.MaxValue ? value : value + 1; }
    }
}
