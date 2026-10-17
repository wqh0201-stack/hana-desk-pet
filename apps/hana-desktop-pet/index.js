import { defineApp } from "./sdk/app-contract/server-client.js";
import {
  applyEvent,
  applyHintEvent,
  cleanId,
  createFollow,
  createSessionList,
  createSnapshot,
  EVENT_TYPES,
  HINT_EVENT_TYPES,
  isPinnableEntry,
  isPinnableSessionId,
  isPlaceholderSessionId,
  mergeSnapshot,
  normalizeFollow,
  projectSessionList,
  rebuildSnapshot,
  recoverSnapshot,
  resolveFollow,
  unresolvedKeyFor,
  withPinnedSeed,
} from "./state-core.mjs";
import {
  BRIDGE_ENABLED_KEY,
  BRIDGE_STATUS_KEY,
  bridgeFailureReason,
  createSessionDiagnostics,
  FOLLOW_KEY,
  FOLLOW_REQUEST_KEY,
  normalizeSelection,
  PET_CATALOG,
  PetBridgeClient,
  reconcileSelection,
  SESSION_DIAGNOSTICS_KEY,
  SESSION_LIST_KEY,
  SELECTION_KEY,
  SNAPSHOT_KEY,
  sessionDiagnostic,
  toPetSnapshot,
} from "./pet-bridge.mjs";

export const name = "hana-desktop-pet";

const MAX_SESSION_PATH_LENGTH = 2048;
const MAX_PATH_IDENTITIES = 64;
const BRIDGE_POLL_MS = 1500;
const BRIDGE_EVENT_DEBOUNCE_MS = 100;
const BRIDGE_PROBE_REFRESH_MS = 5000;
const SESSION_LIST_REFRESH_MS = 5000;
/** Room for a large archive without evicting active sessions; archive goes first. */
const RESOLVED_PATH_LIMIT = 512;
/** Archived rows are only indexed when no active entry needs the room. */
const ARCHIVED_INDEX_LIMIT = 256;
const PIN_ID_PATTERN = /^[A-Za-z0-9_.:@-]{1,256}$/;
const DIAGNOSTIC_OPS = { list: "session:list", get: "session:get" };
const META_REFRESH_EVENTS = new Set(["session_created", "session_forked", "session_info_changed"]);

function followStorageValue(value) {
  return {
    schemaVersion: 1,
    mode: value.mode,
    pinnedSessionId: value.pinnedSessionId,
    updatedAt: value.updatedAt,
    followedSessionId: value.followedSessionId,
    reason: value.reason,
    missingSince: value.missingSince,
    released: value.released,
  };
}
/** The session file name alone: unique even when two paths differ in prefix. */
function basenameOf(value) {
  if (typeof value !== "string" || !value) return null;
  const trimmed = value.replace(/[\\/]+$/, "");
  const index = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  const base = index >= 0 ? trimmed.slice(index + 1) : trimmed;
  return base || null;
}

function stableSnapshotString(value) {
  if (!value || typeof value !== "object") return String(value);
  const { revision, ...rest } = value;
  return JSON.stringify(rest);
}

function sameSnapshot(a, b) {
  if (a === b) return true;
  if (!a || !b) return a === b;
  return stableSnapshotString(a) === stableSnapshotString(b);
}

export default defineApp(async (sdk) => {
  const saved = await sdk.storage.global.get(SNAPSHOT_KEY, createSnapshot());
  let snapshot = recoverSnapshot(saved);
  const savedSelection = await sdk.storage.global.get(SELECTION_KEY, {});
  let selection = normalizeSelection(savedSelection);
  let bridgeEnabled = await sdk.storage.global.get(BRIDGE_ENABLED_KEY, false) === true;
  let bridgeStatus = bridgeEnabled ? "offline" : "disabled";
  let bridgeReason = null;
  let bridgePoseState = null;
  // Only metadata survives here: a pinned id last seen on the list and why we follow it.
  let follow = normalizeFollow(await sdk.storage.global.get(FOLLOW_KEY, createFollow()));
  let sessionList = normalizeSessionList(await sdk.storage.global.get(SESSION_LIST_KEY, createSessionList()));
  let diagnostics = normalizeDiagnostics(await sdk.storage.global.get(SESSION_DIAGNOSTICS_KEY, createSessionDiagnostics()));
  let lastAppliedRequestId = null;
  // path -> the last real identity the host gave us, used to merge placeholders.
  const resolvedPaths = new Map();
  /** "exact" | "basename" | "miss" for the most recent path lookup (diagnostics only). */
  let lastPathMatch = "miss";
  /** Whether the `legacySessionPath` selector has been attempted (diagnostics only). */
  let legacyPathTried = false;
  // path -> the identity last used for an event, including unresolved placeholders.
  const pathIdentities = new Map();
  let callbackQueue = Promise.resolve();
  let bridgeTickRunning = false;
  let bridgeTickPending = false;
  let bridgeRefreshTimer = null;
  let listRefreshRunning = false;
  let lastProbeAt = 0;
  const bridgeClient = new PetBridgeClient(sdk.network.fetch.bind(sdk.network));

  /** Persisted lists are re-projected through the metadata allowlist on load. */
  function normalizeSessionList(value) {
    return {
      schemaVersion: 1,
      observedAt: Number.isFinite(value?.observedAt) ? value.observedAt : 0,
      available: false,
      sessions: projectSessionList(value?.sessions ?? []),
    };
  }

  /** Diagnostics carry only `code`/`kind`/`operation`; anything else is discarded. */
  function normalizeDiagnostics(value) {
    const base = createSessionDiagnostics();
    if (!value || typeof value !== "object" || Array.isArray(value)) return base;
    const out = { ...base };
    for (const slot of ["list", "get"]) {
      const raw = value[slot];
      if (!raw || typeof raw !== "object" || Array.isArray(raw)) continue;
      out[slot] = sessionDiagnostic(raw, {
        operation: raw.operation ?? "unknown",
        selector: raw.selector,
        pathMatch: raw.pathMatch,
        flags: raw,
      });
    }
    return out;
  }

  /** Classify a host failure into a storable `code`/`kind`; never keep the message. */
  async function recordDiagnostics(slot, operation, error, fallback, selector = null, flags = null) {
    const pathMatch = slot === "get" ? lastPathMatch : null;
    const next = { ...diagnostics, [slot]: sessionDiagnostic(error, { operation, fallback, selector, flags, pathMatch }) };
    if (JSON.stringify(next) === JSON.stringify(diagnostics)) return;
    diagnostics = next;
    await sdk.storage.global.set(SESSION_DIAGNOSTICS_KEY, diagnostics);
  }

  async function clearDiagnostics(slot) {
    if (diagnostics[slot] === null) return;
    diagnostics = { ...diagnostics, [slot]: null };
    await sdk.storage.global.set(SESSION_DIAGNOSTICS_KEY, diagnostics);
  }

  /**
   * `session:get` is only an optional enrichment on top of the session list.
   * Its failures must never block, and are recorded with the selector kind so a
   * persistent failure can be told apart from an id-only or path-only problem.
   */
  async function readSession(selector) {
    const selectorKind = selector?.sessionId ? "id" : selector?.sessionPath ? "path" : null;
    try {
      const result = await sdk.sessions.get({ ...selector, scope: "all" });
      if (!result || typeof result !== "object") {
        await recordDiagnostics("get", DIAGNOSTIC_OPS.get, null, "empty", selectorKind);
        return null;
      }
      await clearDiagnostics("get");
      return result.session ?? null;
    } catch (error) {
      // Missing app/sessions.read is an expected, user-controlled state: record why
      // (code/kind/selector only) and continue with the unresolved placeholder path.
      await recordDiagnostics("get", DIAGNOSTIC_OPS.get, error, "host", selectorKind);
      return null;
    }
  }

  function savedIdentity(sessionId) {
    return snapshot.sessions.find((item) => item.sessionId === sessionId) ?? null;
  }

  /**
   * Remember a path -> real identity mapping so a parked placeholder can be merged.
   *
   * Ordering matters: this map is a cache, and the previous LRU eviction evicted the
   * OLDEST insert. Because the list refresh inserts every listed session, a large
   * archive would evict the few active sessions first — after which their events could
   * only land on `unresolved:` placeholders and the real session looked permanently
   * idle. So: active entries are protected, and eviction takes an archived entry.
   */
  function noteResolvedPath(path, sessionId, identity = {}, { lifecycle = "active" } = {}) {
    if (!path || !sessionId || isPlaceholderSessionId(sessionId)) return;
    const archived = lifecycle === "archived";
    resolvedPaths.delete(path);
    resolvedPaths.set(path, {
      sessionId,
      archived,
      title: cleanId(identity?.title, 120),
      agentId: cleanId(identity?.agentId, 128),
      agentName: cleanId(identity?.agentName, 80),
    });
    trimResolvedPaths();
  }

  /** Drop archived entries before any active one, oldest first. */
  function trimResolvedPaths() {
    if (resolvedPaths.size <= RESOLVED_PATH_LIMIT) return;
    for (const [path, known] of [...resolvedPaths]) {
      if (resolvedPaths.size <= RESOLVED_PATH_LIMIT) return;
      if (known.archived) resolvedPaths.delete(path);
    }
    // Only if archive-only eviction could not free enough do we drop active ones.
    for (const path of [...resolvedPaths.keys()]) {
      if (resolvedPaths.size <= RESOLVED_PATH_LIMIT) return;
      resolvedPaths.delete(path);
    }
  }

  /**
   * Look a path up exactly, then by basename. The event callback path and the list
   * `path` can differ in prefix, symlink target or relativity, while the session file
   * name itself is unique.
   */
  function lookupPath(path) {
    if (!path) return null;
    const exact = resolvedPaths.get(path);
    if (exact && !isPlaceholderSessionId(exact.sessionId)) {
      lastPathMatch = "exact";
      return exact;
    }
    const base = basenameOf(path);
    if (!base) {
      lastPathMatch = "miss";
      return null;
    }
    for (const [known, entry] of resolvedPaths) {
      if (isPlaceholderSessionId(entry.sessionId)) continue;
      if (basenameOf(known) === base) {
        lastPathMatch = "basename";
        return entry;
      }
    }
    lastPathMatch = "miss";
    return null;
  }

  /** Sweep every placeholder onto the real id now known for its path. */
  async function mergeResolvedPlaceholders() {
    for (const [path, known] of resolvedPaths) {
      if (!known || isPlaceholderSessionId(known.sessionId)) continue;
      const placeholder = unresolvedKeyFor(path);
      if (!snapshot.sessions.some((item) => item.sessionId === placeholder)) continue;
      await mergePlaceholder(placeholder, known.sessionId, known);
    }
  }

  /**
   * Resolve which session an event belongs to.
   *
   * Resolution order, cheapest and most reliable first:
   *   1. the id the event itself carries;
   *   2. the `path -> id` index built from `session:list` (the host returns `path`);
   *   3. `session:get` by id (when an id is already known);
   *   4. `session:get` by path, then `legacySessionPath`, then `session:context`.
   *
   * Step 4 is a last resort: the host validates a path against its agents directory
   * and throws a generic `APP_HOST_ERROR` when that fails, so it is fragile.
   *
   * A session id is only ever accepted from the host. When nothing resolves we do NOT
   * invent a per-process `local-session-N` — that swallowed the user's real activity.
   * Instead the activity parks under a stable placeholder derived from the path and is
   * merged onto the real id as soon as one is learned.
   */
  async function resolveIdentity(event, callbackPath) {
    const path = typeof callbackPath === "string" && callbackPath.length <= MAX_SESSION_PATH_LENGTH
      ? callbackPath
      : typeof event.sessionPath === "string" && event.sessionPath.length <= MAX_SESSION_PATH_LENGTH
        ? event.sessionPath
        : null;
    const cached = path ? pathIdentities.get(path) ?? null : null;
    const declaredId = cleanId(event.sessionId);
    let session = null;

    if (declaredId && (META_REFRESH_EVENTS.has(event.type) || !cached)) {
      session = await readSession({ sessionId: declaredId });
    } else if (!declaredId && cached && !isPlaceholderSessionId(cached.sessionId) &&
        event.type === "session_info_changed") {
      session = await readSession({ sessionId: cached.sessionId });
    }

    let knownPath = lookupPath(path);
    let pathResolvedFromList = Boolean(knownPath);

    // Only fall back to the fragile path-based session calls when the list gave nothing.
    if (!knownPath && !declaredId && path) {
      const viaPath = await readSessionByPath(path, { cached });
      if (viaPath) {
        knownPath = viaPath.identity;
        pathResolvedFromList = false;
        noteResolvedPath(path, viaPath.identity.sessionId, viaPath.identity);
      }
    }
    const resolvedId = declaredId ?? cleanId(session?.sessionId) ??
      (isPlaceholderSessionId(cached?.sessionId) ? null : cached?.sessionId) ??
      knownPath?.sessionId ?? null;

    // A freshly resolved id retires any placeholder this path was parked under.
    if (resolvedId && path) {
      const placeholder = unresolvedKeyFor(path);
      if (placeholder !== resolvedId) {
        await mergePlaceholder(placeholder, resolvedId, {
          title: cleanId(session?.title, 120),
          agentId: cleanId(session?.agentId, 128),
          agentName: cleanId(session?.agentName, 80),
        });
      }
      noteResolvedPath(path, resolvedId, {
        title: cleanId(session?.title, 120),
        agentId: cleanId(session?.agentId, 128),
        agentName: cleanId(session?.agentName, 80),
      });
    }

    const sessionId = resolvedId ?? (path ? unresolvedKeyFor(path) : null);
    if (!sessionId) return null;

    const previous = savedIdentity(sessionId);
    const identity = {
      sessionId,
      title: cleanId(session?.title, 120) ?? cleanId(knownPath?.title, 120) ?? cached?.title ?? previous?.title ?? null,
      agentId: cleanId(event.agentId, 128) ?? cleanId(session?.agentId, 128) ?? cleanId(knownPath?.agentId, 128) ?? cached?.agentId ?? previous?.agentId ?? null,
      agentName: cleanId(session?.agentName, 80) ?? cleanId(knownPath?.agentName, 80) ?? cached?.agentName ?? previous?.agentName ?? null,
    };
    if (event.type === "session_metadata_updated" && event.metadata &&
        Object.prototype.hasOwnProperty.call(event.metadata, "title")) {
      identity.title = event.metadata.title;
    }
    if (path) {
      pathIdentities.delete(path);
      pathIdentities.set(path, identity);
      while (pathIdentities.size > MAX_PATH_IDENTITIES) {
        pathIdentities.delete(pathIdentities.keys().next().value);
      }
    }
    if (!resolvedId) {
      // Record what we learned about why this event could not be attributed.
      await noteUnresolvedDiagnostics({
        eventHasSessionId: Boolean(declaredId),
        listHasPath: resolvedPaths.size > 0,
        pathResolvedFromList,
      });
    }
    return identity;
  }

  /**
   * Last-resort path lookup. Tried in order of decreasing reliability:
   * `session:get(sessionPath)` -> `session:get(legacySessionPath)` -> `session:context`.
   * Every attempt is recorded as an enum, never as a path or message.
   */
  async function readSessionByPath(path, { cached = null } = {}) {
    const attempts = [
      { selector: "path", call: () => sdk.sessions.get({ sessionPath: path, scope: "all" }), pick: (r) => r?.session },
      { selector: "legacyPath", call: () => sdk.sessions.get({ legacySessionPath: path, scope: "all" }), pick: (r) => r?.session },
      { selector: "path", call: () => sdk.sessions.context({ sessionPath: path, scope: "all" }), pick: (r) => r },
    ];
    let lastError = null;
    let lastSelector = null;
    for (const attempt of attempts) {
      lastSelector = attempt.selector;
      try {
        const result = await attempt.call();
        const picked = attempt.pick(result);
        const resolvedId = cleanId(picked?.sessionId);
        if (resolvedId && !isPlaceholderSessionId(resolvedId)) {
          await clearDiagnostics("get");
          legacyPathTried = attempt.selector === "legacyPath" ? true : legacyPathTried;
          return {
            identity: {
              sessionId: resolvedId,
              title: cleanId(picked?.title, 120) ?? cached?.title ?? null,
              agentId: cleanId(picked?.agentId, 128) ?? cached?.agentId ?? null,
              agentName: cleanId(picked?.agentName, 80) ?? cached?.agentName ?? null,
            },
          };
        }
        lastError = null;
      } catch (error) {
        lastError = error;
        if (attempt.selector === "legacyPath") legacyPathTried = true;
      }
    }
    await recordDiagnostics("get", DIAGNOSTIC_OPS.get, lastError, lastError ? "host" : "empty", lastSelector, {
      legacyPathTried,
    });
    return null;
  }

  /** Merge a path-resolution outcome into the diagnostics without clobbering the rest. */
  async function noteUnresolvedDiagnostics(flags) {
    const merged = { ...(diagnostics.get ?? { code: "APP_HOST_ERROR", kind: "host", operation: DIAGNOSTIC_OPS.get }), ...flags };
    const next = { ...diagnostics, get: sessionDiagnostic(merged, {
      operation: merged.operation ?? DIAGNOSTIC_OPS.get,
      fallback: merged.kind ?? "host",
      selector: merged.selector,
      pathMatch: lastPathMatch,
      flags: merged,
    }) };
    if (JSON.stringify(next) === JSON.stringify(diagnostics)) return;
    diagnostics = next;
    await sdk.storage.global.set(SESSION_DIAGNOSTICS_KEY, diagnostics);
  }

  /** Merge a placeholder's activity onto the real id, then persist. */
  async function mergePlaceholder(fromId, toId, identity = null) {
    const merged = mergeSnapshot(snapshot, fromId, toId, Date.now(), identity);
    if (merged === snapshot) return;
    snapshot = merged;
    await sdk.storage.global.set(SNAPSHOT_KEY, snapshot);
  }

  async function refreshFollow() {
    const wasPinned = follow.mode === "pinned";
    const previous = JSON.stringify(followStorageValue(follow));
    // A pin carries a metadata-only seed so the target keeps a row before any activity.
    follow = resolveFollow(withPinnedSeed(follow, sessionList.sessions), {
      sessions: snapshot.sessions,
      listEntries: sessionList.sessions,
      listAvailable: sessionList.available,
      now: Date.now(),
    }).follow;
    const next = JSON.stringify(followStorageValue(follow));
    if (next !== previous) await sdk.storage.global.set(FOLLOW_KEY, followStorageValue(follow));
    return wasPinned && follow.mode !== "pinned";
  }

  /** Re-resolve `current` after follow changes; a one-shot bypass honors changed intent. */
  async function rebuildCurrentSnapshot({ bypassHysteresis = false } = {}) {
    const next = rebuildSnapshot(snapshot, follow, Date.now(), { bypassHysteresis });
    if (sameSnapshot(next, snapshot)) return;
    snapshot = next;
    await sdk.storage.global.set(SNAPSHOT_KEY, snapshot);
    requestBridgeRefresh();
  }

  async function handleEvent(event, callbackPath) {
    if (!event || !EVENT_TYPES.includes(event.type)) return;
    // Hint events are handled on their own path: they must never invent a session.
    if (HINT_EVENT_TYPES.includes(event.type)) {
      await handleHintEvent(event, callbackPath);
      return;
    }
    const identity = await resolveIdentity(event, callbackPath);
    if (!identity) return;
    const nextSnapshot = applyEvent(snapshot, identity, event, Date.now(), follow);
    if (nextSnapshot === snapshot) return;
    snapshot = nextSnapshot;
    await sdk.storage.global.set(SNAPSHOT_KEY, snapshot);
    const releasedPin = await refreshFollow();
    if (releasedPin) await rebuildCurrentSnapshot({ bypassHysteresis: true });
    requestBridgeRefresh();
  }

  /**
   * Apply a presentation-only hint event.
   *
   * Only `event.type` and the session attribution are read. The payloads of these
   * events carry prompt bodies, tool arguments, user input, error messages and the
   * dropped interjection text, so none of it is touched here.
   *
   * `confirmation_resolved` legitimately arrives without a session (a terminal
   * proposal reports `sessionId: null`). Rather than guessing an owner, such an event
   * clears every `confirming` hint and never creates a row.
   */
  async function handleHintEvent(event, callbackPath) {
    const resolved = await resolveHintOwner(event, callbackPath);
    const applied = applyHintEvent(snapshot, resolved, event, Date.now(), follow);
    if (applied === snapshot) return;
    snapshot = applied;
    await sdk.storage.global.set(SNAPSHOT_KEY, snapshot);
    requestBridgeRefresh();
  }

  /**
   * Whether an unattributed hint event should clear every showing hint.
   *
   * `confirmation_resolved` is documented to arrive with `sessionId: null` for a
   * terminal proposal. Clearing all `confirming` hints is the honest reading: we know
   * a confirmation ended but not whose, so we must not leave a stale prompt showing.
   */
  function hintClearAll(event) {
    return event.type === "confirmation_resolved";
  }

  /**
   * Which session owns this hint event. Unlike `resolveIdentity` this never falls back
   * to a placeholder: an unattributed hint is dropped instead of being parked.
   */
  async function resolveHintOwner(event, callbackPath) {
    const declaredId = cleanId(event.sessionId);
    if (declaredId) return { sessionId: declaredId, clearAll: false };
    if (hintClearAll(event)) return { sessionId: null, clearAll: true };
    const path = typeof callbackPath === "string" && callbackPath.length <= MAX_SESSION_PATH_LENGTH
      ? callbackPath
      : typeof event.sessionPath === "string" && event.sessionPath.length <= MAX_SESSION_PATH_LENGTH
        ? event.sessionPath
        : null;
    const known = lookupPath(path);
    if (known) return { sessionId: known.sessionId, clearAll: false };
    const cached = path ? pathIdentities.get(path) ?? null : null;
    if (cached && !isPlaceholderSessionId(cached.sessionId)) {
      return { sessionId: cached.sessionId, clearAll: false };
    }
    return { sessionId: null, clearAll: false };
  }

  async function saveSelection(next) {
    selection = normalizeSelection(next);
    await sdk.storage.global.set(SELECTION_KEY, selection);
  }

  async function setBridgeStatus(next, { reason = null, poseState = null } = {}) {
    if (bridgeStatus === next && bridgeReason === reason &&
        JSON.stringify(bridgePoseState) === JSON.stringify(poseState)) return;
    bridgeStatus = next;
    bridgeReason = reason;
    bridgePoseState = poseState;
    await sdk.storage.global.set(BRIDGE_STATUS_KEY, {
      status: bridgeStatus,
      reason: bridgeReason,
      poseState: bridgePoseState,
      updatedAt: Date.now(),
    });
  }

  /**
   * Refresh the real session list. This is the primary source of titles and of
   * path -> sessionId, so it asks for `lifecycle: "all"`: an archived session still
   * has a name worth showing, even though only `active` entries are pinnable.
   *
   * `path` is read from the raw entries here (the host returns it) and kept in
   * memory only; the projection we persist never contains it.
   */
  async function refreshSessionList() {
    let entries = null;
    try {
      const result = await sdk.sessions.list({ scope: "all", lifecycle: "all" });
      if (Array.isArray(result?.sessions)) {
        entries = result.sessions;
      } else {
        // A well-formed reply with no list is still a failure worth diagnosing.
        await recordDiagnostics("list", DIAGNOSTIC_OPS.list, null, "malformed");
      }
    } catch (error) {
      // Without app/sessions.read — or with a host that refuses the verb — keep the
      // previous list but record why, so the panel can say so instead of guessing.
      await recordDiagnostics("list", DIAGNOSTIC_OPS.list, error);
      entries = null;
    }
    if (entries === null) {
      sessionList = { ...sessionList, available: false };
    } else {
      await indexListedPaths(entries);
      await clearDiagnostics("list");
      const projected = projectSessionList(entries);
      const changed = JSON.stringify(projected) !== JSON.stringify(sessionList.sessions);
      sessionList = { schemaVersion: 1, observedAt: Date.now(), available: true, sessions: projected };
      if (changed) await sdk.storage.global.set(SESSION_LIST_KEY, sessionList);
    }
    await mergeResolvedPlaceholders();
    const releasedPin = await refreshFollow();
    // A pin released by closure/archive is a follow-intent change; skip hysteresis once.
    await rebuildCurrentSnapshot({ bypassHysteresis: releasedPin });
  }

  /**
   * Index `path -> sessionId` from a raw list reply.
   *
   * Active sessions are indexed first and are never evicted in favour of an archived
   * one: the previous code inserted every listed session into a 64-entry LRU, so a
   * large archive pushed the live sessions out and their events could only land on
   * `unresolved:` placeholders.
   */
  async function indexListedPaths(entries) {
    let withPath = 0;
    const active = [];
    const archived = [];
    for (const entry of entries) {
      const entryPath = typeof entry?.path === "string" && entry.path.length <= MAX_SESSION_PATH_LENGTH
        ? entry.path
        : null;
      const entryId = cleanId(entry?.sessionId);
      if (!entryPath || !entryId) continue;
      withPath += 1;
      if (entry.lifecycle === "archived") archived.push(entry);
      else active.push(entry);
    }

    for (const entry of active) {
      noteResolvedPath(entry.path, cleanId(entry.sessionId), {
        title: entry.title,
        agentId: entry.agentId,
        agentName: entry.agentName,
      }, { lifecycle: "active" });
    }
    // Archived rows only exist to backfill a title, so they get a smaller budget.
    for (const entry of archived.slice(0, ARCHIVED_INDEX_LIMIT)) {
      noteResolvedPath(entry.path, cleanId(entry.sessionId), {
        title: entry.title,
        agentId: entry.agentId,
        agentName: entry.agentName,
      }, { lifecycle: "archived" });
    }
    return { withPath, activeCount: active.length, archivedCount: archived.length };
  }

  async function scheduleListRefresh() {
    if (listRefreshRunning) return;
    listRefreshRunning = true;
    try {
      await refreshSessionList();
      await rebuildCurrentSnapshot();
    } catch {
      // A refused list must never break the controller or the existing pet feed.
    } finally {
      listRefreshRunning = false;
    }
  }

  async function syncSelection(remote) {
    let decision = reconcileSelection(selection, remote);
    if (decision.action === "adopt") {
      await saveSelection(decision.selection);
      return;
    }
    if (decision.action === "keep") {
      if (decision.selection.petRevision !== selection.petRevision) await saveSelection(decision.selection);
      return;
    }

    const pushed = await bridgeClient.setSelection(decision.selection, remote.revision);
    if (pushed.ok) {
      await saveSelection({
        ...decision.selection,
        petRevision: pushed.selection.revision,
      });
      return;
    }

    // Revision conflict: compare local edit time with the current pet selection, then retry once.
    decision = reconcileSelection(selection, pushed.selection);
    if (decision.action === "adopt") {
      await saveSelection(decision.selection);
      return;
    }
    if (decision.action === "push") {
      const retry = await bridgeClient.setSelection(decision.selection, pushed.selection.revision);
      if (retry.ok) {
        await saveSelection({ ...decision.selection, petRevision: retry.selection.revision });
      } else {
        await saveSelection(reconcileSelection(selection, retry.selection).selection);
      }
    }
  }

  async function syncBridge() {
    bridgeEnabled = await sdk.storage.global.get(BRIDGE_ENABLED_KEY, false) === true;
    selection = normalizeSelection(await sdk.storage.global.get(SELECTION_KEY, selection));
    if (!bridgeEnabled) {
      lastProbeAt = 0;
      bridgeClient.resetPoseRevision();
      await setBridgeStatus("disabled");
      return;
    }

    if (bridgeStatus !== "connected") await setBridgeStatus("connecting");
    try {
      const now = Date.now();
      if (bridgeStatus !== "connected" || now - lastProbeAt >= BRIDGE_PROBE_REFRESH_MS) {
        await bridgeClient.probe();
        lastProbeAt = now;
      }
      const remoteSelection = await bridgeClient.getSelection();
      await syncSelection(remoteSelection);
      await bridgeClient.publish(toPetSnapshot(snapshot, Date.now()));
      const poseState = await bridgeClient.getPoseState();
      await setBridgeStatus("connected", { poseState });
    } catch (error) {
      // Never log raw SDK/network errors; they may contain private host or request details.
      lastProbeAt = 0;
      bridgeClient.resetPoseRevision();
      await setBridgeStatus("offline", { reason: bridgeFailureReason(error) });
    }
  }

  function requestBridgeRefresh() {
    if (!bridgeEnabled) return;
    if (bridgeRefreshTimer !== null) clearTimeout(bridgeRefreshTimer);
    bridgeRefreshTimer = setTimeout(() => {
      bridgeRefreshTimer = null;
      void scheduleBridgeTick(true);
    }, BRIDGE_EVENT_DEBOUNCE_MS);
  }

  /** Apply a panel pin request: a session id to follow, or null to follow the latest activity. */
  async function applyFollowRequest(request) {
    if (!request || typeof request !== "object" || Array.isArray(request)) return;
    const requestId = typeof request.requestId === "string" && request.requestId.length <= 256
      ? request.requestId
      : null;
    if (requestId !== null && requestId === lastAppliedRequestId) return;
    const raw = Object.prototype.hasOwnProperty.call(request, "pinnedSessionId") ? request.pinnedSessionId : null;
    const pinnedSessionId = raw === null || raw === undefined
      ? null
      : (typeof raw === "string" && PIN_ID_PATTERN.test(raw) ? raw : null);
    if (raw !== null && raw !== undefined && pinnedSessionId === null) return;
    lastAppliedRequestId = requestId;

    const now = Date.now();
    const wasPinned = follow.mode === "pinned";
    // Only a real, active host id can be pinned; a placeholder is not a session
    // the user can name, and an archived session is shown but not pinnable.
    if (pinnedSessionId !== null) {
      const entry = sessionList.sessions.find((item) => item.sessionId === pinnedSessionId) ?? null;
      const pinnable = entry !== null ? isPinnableEntry(entry) : isPinnableSessionId(pinnedSessionId);
      if (!pinnable) return;
    }
    const base = pinnedSessionId === null
      ? { ...createFollow(), updatedAt: now }
      : { ...createFollow(), mode: "pinned", pinnedSessionId, updatedAt: now };
    follow = withPinnedSeed(normalizeFollow(base, now), sessionList.sessions);
    await sdk.storage.global.set(FOLLOW_KEY, followStorageValue(follow));
    const releasedPin = await refreshFollow();
    const manualUnpin = wasPinned && pinnedSessionId === null;
    await rebuildCurrentSnapshot({ bypassHysteresis: manualUnpin || releasedPin });
  }

  async function readFollowRequest() {
    const stored = await sdk.storage.global.get(FOLLOW_REQUEST_KEY, null);
    await applyFollowRequest(stored);
  }

  async function scheduleBridgeTick(queueIfBusy = false) {
    if (bridgeTickRunning) {
      if (queueIfBusy) bridgeTickPending = true;
      return;
    }
    bridgeTickRunning = true;
    try {
      do {
        bridgeTickPending = false;
        try {
          await syncBridge();
        } catch (error) {
          await setBridgeStatus("offline", { reason: bridgeFailureReason(error) }).catch(() => {});
        }
      } while (bridgeTickPending);
    } finally {
      bridgeTickRunning = false;
    }
  }

  await sdk.storage.global.set(SNAPSHOT_KEY, snapshot);
  const savedCharacterIsKnown = PET_CATALOG.some(({ id }) => id === savedSelection?.characterId);
  if (!savedSelection || typeof savedSelection !== "object" || !savedCharacterIsKnown) {
    await sdk.storage.global.set(SELECTION_KEY, selection);
  }
  await sdk.storage.global.set(BRIDGE_STATUS_KEY, {
    status: bridgeStatus,
    reason: bridgeReason,
    poseState: bridgePoseState,
    updatedAt: Date.now(),
  });
  await sdk.storage.global.set(SESSION_LIST_KEY, sessionList);
  await sdk.storage.global.set(FOLLOW_KEY, followStorageValue(follow));
  await sdk.storage.global.set(SESSION_DIAGNOSTICS_KEY, diagnostics);

  await sdk.bus.subscribe((event, sessionPath) => {
    // Bus objects can contain message bodies, tool args and results. Only state-core's allowlist survives.
    callbackQueue = callbackQueue.then(() => handleEvent(event, sessionPath)).catch(() => {
      // Never log a raw event, session path or error that could contain private data.
    });
  }, { types: EVENT_TYPES });

  // The panel asks through its own request key, so an automatic release can never be re-applied by it.
  sdk.storage.global.onChanged((keys) => {
    if (!Array.isArray(keys) || !keys.includes(FOLLOW_REQUEST_KEY)) return;
    void readFollowRequest().catch(() => {});
  });

  setInterval(() => {
    void scheduleBridgeTick();
  }, BRIDGE_POLL_MS);
  setInterval(() => {
    void scheduleListRefresh();
  }, SESSION_LIST_REFRESH_MS);
  void scheduleBridgeTick();
  void scheduleListRefresh();

  await sdk.logger.info("Hana desktop pet controller is ready; local bridge is opt-in and event content is not forwarded.");
});
