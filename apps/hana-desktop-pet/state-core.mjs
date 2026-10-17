export const EVENT_TYPES = Object.freeze([
  "agent_start",
  "turn_start",
  "turn_end",
  "tool_execution_start",
  "tool_execution_end",
  "agent_end",
  "session_metadata_updated",
  "session_info_changed",
  "session_created",
  "session_closed",
  "session_forked",
  "auto_retry_start",
  "auto_retry_end",
  // Host-driven presentation signals. Their payloads carry user text, tool args
  // and results, so only `event.type` and the session attribution are ever read.
  "session_confirmation",
  "confirmation_resolved",
  "compaction_start",
  "compaction_end",
  "interjection_dropped",
]);

/**
 * The only hint values that cross the pet protocol. Frozen so neither end can
 * drift: the native side switches on these exact strings.
 */
export const PET_HINTS = Object.freeze(["confirming", "compacting", "interrupted"]);
/**
 * Upper bounds for each hint. A dropped or missing clear event must never leave
 * the pet stuck in a state the user cannot dismiss, so every hint expires.
 */
export const HINT_TTL_MS = Object.freeze({
  confirming: 600000,
  compacting: 600000,
  interrupted: 4000,
});
/** Events that raise a hint, keyed to the hint they raise. */
const HINT_RAISE = new Map([
  ["session_confirmation", "confirming"],
  ["compaction_start", "compacting"],
  ["interjection_dropped", "interrupted"],
]);
/** Events that clear a hint, keyed to the hint they clear. */
const HINT_CLEAR = new Map([
  ["confirmation_resolved", "confirming"],
  ["compaction_end", "compacting"],
]);
export const HINT_EVENT_TYPES = Object.freeze([...HINT_RAISE.keys(), ...HINT_CLEAR.keys()]);
export const OUTCOME_HOLD_MS = 2500;
export const MAX_SESSIONS = 32;
export const SESSION_LIST_MAX = 64;
/** Active sessions get their own budget so truncation can never drop one. */
export const SESSION_ACTIVE_MAX = 128;
/** Archived rows are only kept to backfill titles; they never reach the picker. */
export const SESSION_ARCHIVED_MAX = 96;
/** How long a pinned session may be absent from the session list before the pin is released. */
export const PIN_MISSING_GRACE_MS = 15000;
export const FOLLOW_NOTICE_TTL_MS = 600000;
export const SESSION_ENTRY_KEYS = Object.freeze([
  "sessionId", "title", "agentId", "agentName", "lifecycle", "displayTitle",
]);
/** Prefix for an activity record whose real session id could not be resolved yet. */
export const UNRESOLVED_PREFIX = "unresolved:";
/** Legacy per-process fake ids that must never be shown, pinned or followed again. */
export const LEGACY_PLACEHOLDER_PATTERN = /^local-session-\d+$/;
export const FOLLOW_REASONS = Object.freeze([
  "no_activity", "latest", "pinned", "pinned_closed", "pinned_archived", "pinned_missing",
]);
export const FOLLOW_RELEASE_REASONS = Object.freeze([
  "pinned_closed", "pinned_archived", "pinned_missing",
]);
const ALLOWED_EVENTS = new Set(EVENT_TYPES);
const IDLE_EVENTS = new Set(["session_created", "session_forked"]);
const ACTIVITY_EVENTS = new Set([
  "agent_start",
  "turn_start",
  "turn_end",
  "tool_execution_start",
  "tool_execution_end",
  "agent_end",
  "auto_retry_start",
  "auto_retry_end",
]);

export function cleanText(value, maxLength = 160) {
  if (typeof value !== "string") return null;
  const cleaned = value.replace(/[\u0000-\u001f\u007f-\u009f]/g, " ").trim();
  if (!cleaned) return null;
  return Array.from(cleaned).slice(0, maxLength).join("");
}

export function cleanId(value, maxLength = 256) {
  return cleanText(value, maxLength);
}

export function normalizeIdentity(identity) {
  if (!identity || typeof identity !== "object") return null;
  const sessionId = cleanId(identity.sessionId);
  if (!sessionId) return null;
  return {
    sessionId,
    title: identity.title === undefined ? undefined : cleanText(identity.title, 120),
    agentId: identity.agentId === undefined ? undefined : cleanId(identity.agentId, 128),
    agentName: identity.agentName === undefined ? undefined : cleanText(identity.agentName, 80),
  };
}

export function createSnapshot() {
  return {
    schemaVersion: 1,
    observedAt: 0,
    revision: 0,
    sessions: [],
    current: null,
  };
}

export function shortSessionId(sessionId) {
  const safe = cleanId(sessionId) ?? "unknown";
  const normalized = safe.replace(/[^A-Za-z0-9_-]/g, "");
  return normalized.slice(-8) || "unknown";
}

/** FNV-1a over the session path: a stable, opaque internal key (never persisted as a path). */
function hashKey(value) {
  let hash = 0x811c9dc5;
  const text = String(value ?? "");
  for (let index = 0; index < text.length; index += 1) {
    hash ^= text.charCodeAt(index);
    hash = Math.imul(hash, 0x01000193) >>> 0;
  }
  return hash.toString(16).padStart(8, "0");
}

/** Stable id for activity that arrived without a resolvable session id. */
export function unresolvedKeyFor(sessionPath) {
  return `${UNRESOLVED_PREFIX}${hashKey(sessionPath)}`;
}

export function isUnresolvedSessionId(sessionId) {
  return typeof sessionId === "string" && sessionId.startsWith(UNRESOLVED_PREFIX);
}

/** True for any id this App invented itself rather than learned from the host. */
export function isPlaceholderSessionId(sessionId) {
  return isUnresolvedSessionId(sessionId) ||
    (typeof sessionId === "string" && LEGACY_PLACEHOLDER_PATTERN.test(sessionId));
}

export function displayTitleFor(session, sessions = []) {
  const shortId = shortSessionId(session?.sessionId);
  if (isUnresolvedSessionId(session?.sessionId)) return `未识别会话 · ${shortId}`;
  const title = cleanText(session?.title, 120);
  if (!title) return `会话 · ${shortId}`;

  const sameTitle = sessions.filter((item) => cleanText(item?.title, 120) === title);
  if (sameTitle.length <= 1) return title;

  const agentName = cleanText(session?.agentName, 80);
  const sameAgent = sameTitle.filter((item) => cleanText(item?.agentName, 80) === agentName);
  const suffix = agentName ? ` · ${agentName}` : "";
  return `${title}${suffix}${sameAgent.length > 1 || !agentName ? ` · ${shortId}` : ""}`;
}

/** A hint is only valid while it is one of the frozen values and still fresh. */
export function effectiveHint(session, now = Date.now()) {
  if (!session || !PET_HINTS.includes(session.hint)) return null;
  const at = session.hintAt;
  // Without a real timestamp we cannot prove the hint is fresh, so we drop it.
  if (!Number.isFinite(at) || at <= 0) return null;
  const ttl = HINT_TTL_MS[session.hint];
  if (now - at >= ttl) return null;
  return session.hint;
}

export function effectiveStatus(session, now = Date.now()) {
  if (!session) return "idle";
  const age = now - session.statusAt;
  if ((session.status === "success" || session.status === "error") &&
      Number.isFinite(session.statusAt) && age >= 0 && age <= OUTCOME_HOLD_MS) {
    // Short tool feedback temporarily overlays the real underlying activity.
    return session.status;
  }
  if (session.running === true) return "working";
  return "idle";
}

function cleanSession(session) {
  if (!session || typeof session !== "object") return null;
  const sessionId = cleanId(session.sessionId);
  if (!sessionId) return null;
  const status = ["working", "success", "error", "idle"].includes(session.status)
    ? session.status
    : "idle";
  return {
    sessionId,
    title: cleanText(session.title, 120),
    agentId: cleanId(session.agentId, 128),
    agentName: cleanText(session.agentName, 80),
    status,
    running: session.running === true,
    toolName: cleanText(session.toolName, 80),
    feedbackResumed: session.feedbackResumed === true,
    runEnded: session.runEnded === true,
    // Derived from the id so a placeholder can never masquerade as a real session.
    unresolved: isUnresolvedSessionId(sessionId),
    hint: PET_HINTS.includes(session.hint) ? session.hint : null,
    hintAt: Number.isFinite(session.hintAt) && session.hintAt > 0 ? session.hintAt : 0,
    closedAt: Number.isFinite(session.closedAt) && session.closedAt > 0 ? session.closedAt : 0,
    lastActivityAt: Number.isFinite(session.lastActivityAt) ? session.lastActivityAt : 0,
    statusAt: Number.isFinite(session.statusAt) && session.statusAt >= 0 ? session.statusAt : 0,
  };
}

function activityOrder(a, b) {
  return b.lastActivityAt - a.lastActivityAt || a.sessionId.localeCompare(b.sessionId);
}

/**
 * The most recent session that is still live. Skipped: closed sessions, and any
 * placeholder id we invented — an unresolved record must never own `current`,
 * otherwise the pet follows a session that is not the user's real one.
 */
function latestActive(records) {
  let best = null;
  let fallback = null;
  for (const record of records) {
    if (record.lastActivityAt <= 0 || record.unresolved === true) continue;
    if (fallback === null || activityOrder(record, fallback) < 0) fallback = record;
    if (record.closedAt > 0) continue;
    if (best === null || activityOrder(record, best) < 0) best = record;
  }
  return best ?? fallback;
}

function attachTitles(records) {
  return records.map((record) => ({ ...record, displayTitle: displayTitleFor(record, records) }));
}

/** Metadata-only seed so a pinned session with no activity yet still gets a row. */
function seedSession(entry) {
  if (!entry || typeof entry !== "object") return null;
  const sessionId = cleanId(entry.sessionId);
  if (!sessionId) return null;
  return {
    sessionId,
    title: cleanText(entry.title, 120),
    agentId: cleanId(entry.agentId, 128),
    agentName: cleanText(entry.agentName, 80),
    status: "idle",
    running: false,
    toolName: null,
    feedbackResumed: false,
    runEnded: false,
    closedAt: 0,
    lastActivityAt: 0,
    statusAt: 0,
  };
}

function buildSnapshot(previous, sessions, observedAt, follow = {}) {
  const ordered = sessions.map(cleanSession).filter(Boolean).sort(activityOrder);
  const pinnedSessionId = follow.pinnedSessionId ? cleanId(follow.pinnedSessionId) : null;
  const known = pinnedSessionId
    ? ordered.find((item) => item.sessionId === pinnedSessionId) ?? null
    : null;
  const seeded = known === null && follow.pinnedSeed ? seedSession(follow.pinnedSeed) : null;
  const pinned = known ?? (seeded && seeded.sessionId === pinnedSessionId ? seeded : null);
  const rows = pinned
    ? [...ordered.filter((item) => item.sessionId !== pinned.sessionId).slice(0, MAX_SESSIONS - 1), pinned]
    : ordered.slice(0, MAX_SESSIONS);
  // A pinned session stays current even when another session was active more recently.
  // A placeholder never becomes the target: it is not the user's real session.
  const candidate = pinned ?? latestActive(ordered);
  const target = candidate && candidate.unresolved !== true ? candidate : null;
  return {
    schemaVersion: 1,
    observedAt,
    revision: (Number.isSafeInteger(previous?.revision) ? previous.revision : 0) + 1,
    sessions: attachTitles(rows),
    current: target ? { ...target, displayTitle: displayTitleFor(target, rows) } : null,
  };
}

/** Re-derive `current` after a follow change, without any bus event. */
export function rebuildSnapshot(snapshot, follow = {}, observedAt = Date.now()) {
  if (!snapshot || typeof snapshot !== "object" || !Array.isArray(snapshot.sessions)) return snapshot;
  return buildSnapshot(snapshot, snapshot.sessions, observedAt, follow);
}

/**
 * Apply a hint event without needing a full identity record.
 *
 * `owner.sessionId` names the affected session; `owner.clearAll` clears the hint on
 * every session, which is how an unattributed `confirmation_resolved` is handled.
 * Returns the same snapshot when nothing changed, so callers can skip a write.
 */
export function applyHintEvent(snapshot, owner, event, receivedAt = Date.now(), follow = {}) {
  if (!event || typeof event !== "object" || !HINT_EVENT_TYPES.includes(event.type)) return snapshot;
  if (!owner || typeof owner !== "object") return snapshot;
  const raised = HINT_RAISE.get(event.type) ?? null;
  const cleared = HINT_CLEAR.get(event.type) ?? null;
  const sessionId = cleanId(owner.sessionId);
  if (!raised && !cleared) return snapshot;
  if (!raised && !sessionId && owner.clearAll !== true) return snapshot;
  if (raised && !sessionId) return snapshot;

  const at = Number.isFinite(receivedAt) ? Math.floor(receivedAt) : Date.now();
  const prior = Array.isArray(snapshot?.sessions) ? snapshot.sessions.map(cleanSession).filter(Boolean) : [];
  let changed = false;
  const next = prior.map((record) => {
    const isOwner = sessionId ? record.sessionId === sessionId : owner.clearAll === true;
    if (!isOwner) return record;
    if (raised) {
      if (record.hint === raised && record.hintAt === at) return record;
      changed = true;
      return { ...record, hint: raised, hintAt: at };
    }
    // A resolution only clears its own hint; it must not wipe an unrelated one.
    if (record.hint !== cleared) return record;
    changed = true;
    return { ...record, hint: null, hintAt: 0 };
  });
  // Nothing to attach the hint to: never invent a row for a presentation event.
  if (!changed) return snapshot;
  const observedAt = Math.max(at, Number.isFinite(snapshot?.observedAt) ? snapshot.observedAt + 1 : 1);
  return buildSnapshot(snapshot, next, observedAt, follow);
}

export function recoverSnapshot(value) {
  if (!value || typeof value !== "object" || value.schemaVersion !== 1 || !Array.isArray(value.sessions)) {
    return createSnapshot();
  }
  const sessions = value.sessions.map((item) => {
    const safe = cleanSession(item);
    if (!safe) return null;
    // Placeholder rows are dropped on load: the session path is deliberately never
    // persisted, so a loaded placeholder could never be resolved or merged.
    if (isPlaceholderSessionId(safe.sessionId)) return null;
    // A process restart breaks event continuity. Never revive a stale "working" state,
    // and never revive a hint: it describes a moment that is already gone.
    return {
      ...safe,
      running: false,
      status: "idle",
      statusAt: 0,
      toolName: null,
      feedbackResumed: false,
      runEnded: false,
      hint: null,
      hintAt: 0,
    };
  }).filter(Boolean);
  return buildSnapshot(
    { revision: Number.isSafeInteger(value.revision) ? value.revision : 0 },
    sessions,
    Number.isFinite(value.observedAt) ? value.observedAt : 0,
  );
}

function isRecentFeedback(record, at) {
  const age = at - record.statusAt;
  return (record.status === "success" || record.status === "error") &&
    Number.isFinite(record.statusAt) && age >= 0 && age <= OUTCOME_HOLD_MS;
}

function beginWork(record, at, { preserveRecentFeedback = false } = {}) {
  const keepFeedback = preserveRecentFeedback && isRecentFeedback(record, at);
  record.running = true;
  record.runEnded = false;
  record.toolName = null;
  if (keepFeedback) {
    // Keep the short result visible through the next synchronous work event.
    record.feedbackResumed = true;
  } else {
    record.status = "working";
    record.statusAt = at;
    record.feedbackResumed = false;
  }
}

export function applyEvent(snapshot, identity, event, receivedAt = Date.now(), follow = {}) {
  if (!event || typeof event !== "object" || !ALLOWED_EVENTS.has(event.type)) return snapshot;
  const safeIdentity = normalizeIdentity(identity);
  if (!safeIdentity) return snapshot;
  // Hint events carry user text, tool args and results. Nothing beyond the type and
  // the session attribution is read from them — not here and not anywhere else.

  const prior = Array.isArray(snapshot?.sessions) ? snapshot.sessions.map(cleanSession).filter(Boolean) : [];
  const index = prior.findIndex((item) => item.sessionId === safeIdentity.sessionId);
  const record = index >= 0
    ? { ...prior[index] }
    : {
        sessionId: safeIdentity.sessionId,
        title: null,
        agentId: null,
        agentName: null,
        status: "idle",
        running: false,
        toolName: null,
        feedbackResumed: false,
        runEnded: false,
        closedAt: 0,
        hint: null,
        hintAt: 0,
        lastActivityAt: 0,
        statusAt: 0,
      };

  const rawReceivedAt = Number.isFinite(receivedAt) ? Math.floor(receivedAt) : Date.now();
  // Equal or backwards wall-clock readings still get an unambiguous local receive order.
  const observedAt = Math.max(rawReceivedAt, Number.isFinite(snapshot?.observedAt) ? snapshot.observedAt + 1 : 1);
  // A known terminal event prevents a late tool event from reviving the completed runtime.
  if ((event.type === "tool_execution_start" || event.type === "tool_execution_end") && record.runEnded) {
    return snapshot;
  }

  for (const key of ["title", "agentId", "agentName"]) {
    if (safeIdentity[key] !== undefined) record[key] = safeIdentity[key];
  }

  // Hint events are presentation-only: they raise or clear one frozen enum value and
  // never touch status, running or tool state. Their payloads are not read.
  const raised = HINT_RAISE.get(event.type) ?? null;
  const cleared = HINT_CLEAR.get(event.type) ?? null;
  if (raised !== null) {
    record.hint = raised;
    record.hintAt = rawReceivedAt;
  } else if (cleared !== null) {
    // A resolution only clears its own hint; it must not wipe an unrelated one.
    if (record.hint === cleared) {
      record.hint = null;
      record.hintAt = 0;
    }
  }

  if (event.type === "session_metadata_updated" && event.metadata &&
      Object.prototype.hasOwnProperty.call(event.metadata, "title")) {
    record.title = cleanText(event.metadata.title, 120);
  }

  if (ACTIVITY_EVENTS.has(event.type)) {
    record.lastActivityAt = observedAt;
  }

  if (event.type === "agent_start") {
    beginWork(record, rawReceivedAt);
  } else if (event.type === "turn_start") {
    beginWork(record, rawReceivedAt, { preserveRecentFeedback: true });
  } else if (event.type === "auto_retry_start") {
    beginWork(record, rawReceivedAt);
  } else if (event.type === "tool_execution_start") {
    const toolName = cleanText(event.toolName, 80);
    record.running = true;
    record.runEnded = false;
    record.status = "working";
    record.statusAt = rawReceivedAt;
    record.feedbackResumed = false;
    record.toolName = toolName;
  } else if (event.type === "tool_execution_end") {
    // The public end event promises isError, not a stable active-call correlation key.
    // Clear the single exposed tool name rather than retaining a potentially stale one.
    record.toolName = null;
    record.feedbackResumed = false;
    if (typeof event.isError === "boolean") {
      record.status = event.isError ? "error" : "success";
      record.statusAt = rawReceivedAt;
    } else {
      // An absent outcome flag is not evidence of success or failure.
      record.status = record.running ? "working" : "idle";
      record.statusAt = rawReceivedAt;
    }
  } else if (event.type === "agent_end") {
    const willRetry = event.willRetry === true;
    const preserveUnrecoveredError = !willRetry && !record.feedbackResumed &&
      record.status === "error" && isRecentFeedback(record, rawReceivedAt);
    record.running = willRetry;
    record.runEnded = !willRetry;
    record.toolName = null;
    record.feedbackResumed = false;
    if (willRetry) {
      record.status = "working";
      record.statusAt = rawReceivedAt;
    } else if (preserveUnrecoveredError) {
      // Keep a just-observed tool error briefly; a tool result is never itself a whole-run success.
      record.status = "error";
    } else {
      // agent_end proves the observed agent run ended; this means lifecycle completion, not user-goal satisfaction.
      record.status = "success";
      record.statusAt = rawReceivedAt;
    }
  } else if (event.type === "session_closed") {
    record.running = false;
    record.runEnded = true;
    record.status = "idle";
    record.statusAt = rawReceivedAt;
    record.toolName = null;
    record.feedbackResumed = false;
    record.closedAt = rawReceivedAt;
    // A closed session cannot be waiting on the user.
    record.hint = null;
    record.hintAt = 0;
  } else if (IDLE_EVENTS.has(event.type)) {
    record.running = false;
    record.runEnded = false;
    record.status = "idle";
    record.statusAt = rawReceivedAt;
    record.toolName = null;
    record.feedbackResumed = false;
  }
  // turn_end and auto_retry_end are not whole-agent completion evidence; retain the last known work phase.

  if (index >= 0) prior[index] = record;
  else prior.push(record);
  return buildSnapshot(snapshot, prior, observedAt, follow);
}

/** Build the metadata-only seed for a pinned session from a projected list entry. */
export function pinnedSeedFor(follow, entries = []) {
  const sessionId = follow?.pinnedSessionId ? cleanId(follow.pinnedSessionId) : null;
  if (!sessionId || !Array.isArray(entries)) return null;
  const entry = entries.find((item) => item?.sessionId === sessionId) ?? null;
  if (!entry) return null;
  return {
    sessionId: entry.sessionId,
    title: cleanText(entry.title, 120),
    agentId: cleanId(entry.agentId, 128),
    agentName: cleanText(entry.agentName, 80),
  };
}

/**
 * Move one unresolved placeholder's activity onto the real session id.
 * Returns a new snapshot, or the same one when there is nothing to merge.
 */
export function mergeSnapshot(snapshot, fromId, toId, observedAt = Date.now(), identity = null) {
  const from = cleanId(fromId);
  const to = cleanId(toId, 256);
  if (!from || !to || from === to || !Array.isArray(snapshot?.sessions)) return snapshot;
  const source = snapshot.sessions.find((item) => item.sessionId === from) ?? null;
  if (!source) return snapshot;
  const prior = snapshot.sessions.map(cleanSession).filter(Boolean);
  const targetIndex = prior.findIndex((item) => item.sessionId === to);
  const merged = targetIndex >= 0
    ? { ...prior[targetIndex] }
    : {
        sessionId: to, title: null, agentId: null, agentName: null, status: "idle",
        running: false, toolName: null, feedbackResumed: false, runEnded: false,
        closedAt: 0, lastActivityAt: 0, statusAt: 0,
      };
  // The real session's identity comes from the host, never from the placeholder.
  for (const key of ["title", "agentId", "agentName"]) {
    const known = cleanText(identity?.[key], key === "title" ? 120 : 128);
    if (known) merged[key] = known;
  }
  for (const key of ["status", "running", "toolName", "feedbackResumed", "runEnded", "closedAt"]) {
    if (source[key] === undefined) continue;
    if (source[key] === null || source[key] === false || source[key] === 0) continue;
    merged[key] = source[key];
  }
  // A real id always wins: the placeholder is never ambiguous once resolved.
  merged.unresolved = false;
  merged.lastActivityAt = Math.max(merged.lastActivityAt, source.lastActivityAt);
  merged.statusAt = Math.max(merged.statusAt, source.statusAt);
  for (const key of ["title", "agentId", "agentName"]) {
    if (merged[key] === null && source[key] !== null) merged[key] = source[key];
  }
  const rows = prior.filter((item) => item.sessionId !== from);
  if (targetIndex >= 0) rows[rows.findIndex((item) => item.sessionId === to)] = merged;
  else rows.push(merged);
  return buildSnapshot(snapshot, rows, observedAt, { pinnedSessionId: null });
}

export function projectSessionEntry(entry) {
  if (!entry || typeof entry !== "object") return null;
  const sessionId = cleanId(entry.sessionId);
  if (!sessionId) return null;
  return {
    sessionId,
    title: cleanText(entry.title, 120),
    agentId: cleanId(entry.agentId, 128),
    agentName: cleanText(entry.agentName, 80),
    lifecycle: entry.lifecycle === "archived" ? "archived" : "active",
  };
}

/**
 * Project a real session list down to the metadata allowlist; paths and bodies are dropped.
 *
 * Active sessions are kept first and under their own cap, so a long archive can never
 * push a live session out of the budget. Archived rows are retained only so a snapshot
 * row can borrow their title; the picker filters them out entirely.
 */
export function projectSessionList(entries, {
  maxActive = SESSION_ACTIVE_MAX,
  maxArchived = SESSION_ARCHIVED_MAX,
} = {}) {
  if (!Array.isArray(entries)) return [];
  const seen = new Set();
  const active = [];
  const archived = [];
  for (const entry of entries) {
    const safe = projectSessionEntry(entry);
    if (!safe || seen.has(safe.sessionId)) continue;
    // Only real host ids are pinnable; a placeholder is never offered here.
    if (isPlaceholderSessionId(safe.sessionId)) continue;
    seen.add(safe.sessionId);
    if (safe.lifecycle === "archived") archived.push(safe);
    else active.push(safe);
  }
  const byId = (a, b) => a.sessionId.localeCompare(b.sessionId);
  active.sort(byId);
  archived.sort(byId);
  return attachTitles([...active.slice(0, maxActive), ...archived.slice(0, maxArchived)]);
}

/**
 * The sessions the user may actually pick: active only, most recently active first.
 * Archived rows never appear here, no matter how many there are.
 */
export function pickableSessionList(entries, activityAt = {}, max = 15) {
  if (!Array.isArray(entries)) return [];
  const at = (sessionId) => {
    const value = activityAt instanceof Map ? activityAt.get(sessionId) : activityAt?.[sessionId];
    return Number.isFinite(value) ? value : 0;
  };
  return entries
    .filter((entry) => isPinnableEntry(entry))
    .sort((a, b) => at(b.sessionId) - at(a.sessionId) || a.sessionId.localeCompare(b.sessionId))
    .slice(0, max);
}

/** Attach the metadata-only seed so a pinned session keeps a row before any activity. */
export function withPinnedSeed(follow, entries = []) {
  if (follow?.mode !== "pinned") return follow;
  const seed = pinnedSeedFor(follow, entries);
  if (!seed) return follow;
  return { ...follow, pinnedSeed: seed };
}

/** A placeholder must never be pinned: it is not a session the user can name. */
export function isPinnableSessionId(sessionId) {
  const safe = cleanId(sessionId, 256);
  return Boolean(safe) && !isPlaceholderSessionId(safe);
}

/** Only an `active` lifecycle may be pinned; an archived session can still be shown by name. */
export function isPinnableEntry(entry) {
  return isPinnableSessionId(entry?.sessionId) && entry?.lifecycle !== "archived";
}

function keepSeed(previous, follow) {
  if (follow.mode !== "pinned") return follow;
  const seed = previous?.pinnedSeed ?? null;
  return seed ? { ...follow, pinnedSeed: seed } : follow;
}

export function createSessionList() {
  return { schemaVersion: 1, observedAt: 0, available: false, sessions: [] };
}

export function createFollow() {
  return {
    schemaVersion: 1,
    mode: "latest",
    pinnedSessionId: null,
    updatedAt: 0,
    followedSessionId: null,
    reason: "no_activity",
    missingSince: null,
    released: null,
  };
}

function normalizeRelease(value, now) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const sessionId = cleanId(value.sessionId);
  const reason = FOLLOW_RELEASE_REASONS.includes(value.reason) ? value.reason : null;
  if (!sessionId || !reason) return null;
  const at = Number.isSafeInteger(value.at) && value.at >= 0 ? value.at : 0;
  // A release notice is transient UI context, not durable state.
  if (now - at > FOLLOW_NOTICE_TTL_MS) return null;
  return { sessionId, reason, at };
}

export function normalizeFollow(value, now = Date.now()) {
  const base = createFollow();
  if (!value || typeof value !== "object" || Array.isArray(value)) return base;
  const pinnedSessionId = cleanId(value.pinnedSessionId, 256);
  // A placeholder id we invented is not a session the user can name, so a pin to
  // one is stale data (or an injection) and falls back to the default follow.
  const mode = isPinnableSessionId(pinnedSessionId) && value.mode === "pinned" ? "pinned" : "latest";
  return {
    schemaVersion: 1,
    mode,
    pinnedSessionId: mode === "pinned" ? pinnedSessionId : null,
    updatedAt: Number.isSafeInteger(value.updatedAt) && value.updatedAt >= 0 ? value.updatedAt : 0,
    followedSessionId: cleanId(value.followedSessionId, 256),
    reason: FOLLOW_REASONS.includes(value.reason) ? value.reason : "no_activity",
    missingSince: Number.isSafeInteger(value.missingSince) && value.missingSince > 0
      ? value.missingSince
      : null,
    released: normalizeRelease(value.released, now),
  };
}

/**
 * Decide which session the pet follows and why. A pin is released as soon as
 * the target is provably gone (closed or archived), or stays absent from the
 * session list beyond the grace window — so a dead pin can never freeze the pet.
 */
export function resolveFollow(value, options = {}) {
  const {
    sessions = [],
    listEntries = [],
    listAvailable = false,
    now = Date.now(),
    missingGraceMs = PIN_MISSING_GRACE_MS,
  } = options;
  const at = Number.isSafeInteger(now) ? now : 0;
  let follow = keepSeed(value, normalizeFollow(value, at));
  const activity = sessions.map(cleanSession).filter(Boolean);

  if (follow.mode === "pinned") {
    const sessionId = follow.pinnedSessionId;
    const record = activity.find((item) => item.sessionId === sessionId) ?? null;
    const entry = listEntries.find((item) => item?.sessionId === sessionId) ?? null;
    const closed = record !== null && record.closedAt > 0;
    const archived = entry !== null && entry.lifecycle !== "active";
    const missing = listAvailable && entry === null;
    const expired = missing && follow.missingSince !== null && at - follow.missingSince >= missingGraceMs;
    const releaseReason = closed
      ? "pinned_closed"
      : archived ? "pinned_archived" : expired ? "pinned_missing" : null;
    if (releaseReason) {
      const { pinnedSeed, ...released } = follow;
      follow = {
        ...released,
        mode: "latest",
        pinnedSessionId: null,
        missingSince: null,
        released: { sessionId, reason: releaseReason, at },
      };
    } else {
      // Advance the absence window each time the pin is confirmed missing, so a
      // long-lived dead pin expires even if the first sighting was never stored.
      follow = { ...follow, missingSince: missing ? at : null };
    }
  }

  let view;
  if (follow.mode === "pinned") {
    view = { mode: "pinned", sessionId: follow.pinnedSessionId, reason: "pinned" };
  } else {
    const latest = latestActive(activity);
    view = {
      mode: "latest",
      sessionId: latest?.sessionId ?? null,
      reason: latest ? "latest" : "no_activity",
    };
  }
  follow = { ...follow, followedSessionId: view.sessionId, reason: view.reason };
  return { follow: view.mode === "pinned" ? keepSeed(value, follow) : follow, view };
}
