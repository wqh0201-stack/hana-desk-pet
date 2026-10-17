import { cleanId, cleanText, effectiveHint, effectiveStatus } from "./state-core.mjs";

export const PET_BASE_URL = "http://127.0.0.1:43127";
export const PET_PROTOCOL_VERSION = 3;
export const PET_SCHEMA_VERSION = 3;
export const BRIDGE_ENABLED_KEY = "hana-pet.bridge.enabled";
export const BRIDGE_STATUS_KEY = "hana-pet.bridge.status";
export const SELECTION_KEY = "hana-pet.selection";
export const SNAPSHOT_KEY = "hana-pet.activity.snapshot";
export const SESSION_LIST_KEY = "hana-pet.session-list";
export const FOLLOW_KEY = "hana-pet.follow";
export const FOLLOW_REQUEST_KEY = "hana-pet.follow.request";
export const SESSION_DIAGNOSTICS_KEY = "hana-pet.session-diagnostics";
/** Only these stable SDK error kinds/codes are ever stored; never a message or path. */
export const DIAGNOSTIC_KINDS = Object.freeze([
  "permission", "timeout", "aborted", "unsupported", "host", "empty", "malformed", "ok",
]);
/** Which kind of session selector was used. An enum, never the id or path itself. */
export const DIAGNOSTIC_SELECTORS = Object.freeze(["id", "path", "legacyPath"]);
/** Closed set of boolean diagnostic flags; deliberately all-or-nothing. */
export const DIAGNOSTIC_FLAGS = Object.freeze([
  "eventHasSessionId", "listHasPath", "pathResolvedFromList", "legacyPathTried",
]);
/** How a path lookup matched: exact map hit, basename fallback, or nothing. */
export const DIAGNOSTIC_PATH_MATCHES = Object.freeze(["exact", "basename", "miss"]);
export const PET_CATALOG = Object.freeze([
  Object.freeze({ id: "claude", name: "Claude" }),
  Object.freeze({ id: "gpt", name: "GPT 白龙" }),
  Object.freeze({ id: "deepseek", name: "DeepSeek 大肥鱼" }),
  Object.freeze({ id: "gemini", name: "Gemini" }),
  Object.freeze({ id: "glm", name: "GLM 黑狐狸" }),
  Object.freeze({ id: "deepseek-hoodie", name: "大肥鱼·Claude 卫衣" }),
  Object.freeze({ id: "gpt-onesie", name: "GPT 降智龙崽" }),
]);
export const DEFAULT_CHARACTER_ID = PET_CATALOG[0].id;

const MAX_BODY_BYTES = 16 * 1024;
const RESPONSE_LIMIT_BYTES = 16 * 1024;
const ROUTES = new Map([
  ["/v3/hello", new Set(["GET"])],
  ["/v3/snapshot", new Set(["POST"])],
  ["/v3/selection", new Set(["GET", "POST"])],
  ["/v3/state", new Set(["GET"])],
]);
const POSE_STATE_KEYS = "characterId,fallback,pose,revision,schemaVersion,since";
const POSE_NAME_PATTERN = /^[a-z0-9][a-z0-9_-]{0,47}$/;
const BRIDGE_FAILURE_REASONS = new Set(["unreachable", "version_mismatch", "invalid_response"]);

class PetBridgeError extends Error {
  constructor(code, reason) {
    super(code);
    this.name = "PetBridgeError";
    this.code = code;
    this.reason = reason;
  }
}

export function bridgeFailureReason(error) {
  return BRIDGE_FAILURE_REASONS.has(error?.reason) ? error.reason : "invalid_response";
}
const CHARACTER_IDS = new Set(PET_CATALOG.map((item) => item.id));
const STATUSES = new Set(["idle", "working", "tool", "success", "error"]);

function finiteInt(value, fallback = 0) {
  return Number.isSafeInteger(value) && value >= 0 ? value : fallback;
}

function normalizeCharacterId(value) {
  const id = cleanId(value, 48);
  return id && CHARACTER_IDS.has(id) ? id : DEFAULT_CHARACTER_ID;
}

export function normalizeSelection(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { characterId: DEFAULT_CHARACTER_ID, updatedAt: 0, petRevision: 0 };
  }
  return {
    characterId: normalizeCharacterId(value.characterId),
    updatedAt: finiteInt(value.updatedAt),
    petRevision: finiteInt(value.petRevision),
  };
}

export function reconcileSelection(localValue, remoteValue) {
  const local = normalizeSelection(localValue);
  const remote = {
    characterId: normalizeCharacterId(remoteValue?.characterId),
    updatedAt: finiteInt(remoteValue?.updatedAt),
    petRevision: finiteInt(remoteValue?.revision),
  };
  if (local.characterId === remote.characterId) {
    return { action: "keep", selection: { ...local, petRevision: remote.petRevision } };
  }
  if (local.updatedAt > remote.updatedAt) {
    return { action: "push", selection: { ...local, petRevision: remote.petRevision } };
  }
  return { action: "adopt", selection: remote };
}

function statusFor(session, now) {
  if (!session) return "idle";
  const status = effectiveStatus(session, now);
  if (status === "working" && cleanText(session.toolName, 80)) return "tool";
  return STATUSES.has(status) ? status : "idle";
}

/**
 * Reduce a host failure to a stable, storable summary. Only `code`/`kind` (plus
 * the SDK operation, the selector kind, and a few booleans) survive: raw messages
 * can carry paths, ids and body text.
 */
export function sessionDiagnostic(error, options = {}) {
  const { operation = "unknown", fallback = "host", selector = null, flags = null } = options;
  const kind = typeof error?.kind === "string" && DIAGNOSTIC_KINDS.includes(error.kind)
    ? error.kind
    : fallback;
  const code = typeof error?.code === "string" && /^[A-Z0-9_.]{2,64}$/.test(error.code)
    ? error.code
    : "APP_HOST_ERROR";
  const op = typeof operation === "string" && /^[a-z:.]{2,48}$/.test(operation)
    ? operation
    : "unknown";
  const out = { code, kind, operation: op };
  // Only selector-based calls carry one, and only as a closed enum.
  if (DIAGNOSTIC_SELECTORS.includes(selector)) out.selector = selector;
  if (DIAGNOSTIC_PATH_MATCHES.includes(options.pathMatch)) out.pathMatch = options.pathMatch;
  // Diagnostic flags are booleans only, so no path, id or body can ride along.
  if (flags && typeof flags === "object") {
    for (const [key, value] of Object.entries(flags)) {
      if (!DIAGNOSTIC_FLAGS.includes(key) || typeof value !== "boolean") continue;
      out[key] = value;
    }
  }
  return out;
}

export function createSessionDiagnostics() {
  return { schemaVersion: 1, observedAt: 0, list: null, get: null };
}

/** Build a strict, body-free projection; never pass a raw Hana bus event here. */
export function toPetSnapshot(snapshot, now = Date.now()) {
  const current = snapshot && typeof snapshot === "object" ? snapshot.current : null;
  return {
    schemaVersion: PET_SCHEMA_VERSION,
    revision: finiteInt(now, Date.now()),
    characters: PET_CATALOG.map(({ id, name }) => ({ id, name })),
    activity: {
      sessionId: cleanId(current?.sessionId, 256),
      title: cleanText(current?.displayTitle ?? current?.title, 120),
      agentId: cleanId(current?.agentId, 128),
      agentName: cleanText(current?.agentName, 80),
      status: statusFor(current, now),
      toolName: cleanText(current?.toolName, 80),
      // The only new field in schema 3: one frozen enum value, or null.
      hint: effectiveHint(current, now),
      lastActivityAt: finiteInt(current?.lastActivityAt),
    },
  };
}

function validateSelectionResponse(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) || value.schemaVersion !== PET_SCHEMA_VERSION ||
      Object.keys(value).sort().join(",") !== "characterId,revision,schemaVersion,updatedAt") {
    throw new Error("PET_PROTOCOL_INVALID");
  }
  const characterId = value.characterId;
  if (typeof characterId !== "string" || !CHARACTER_IDS.has(characterId)) {
    throw new Error("PET_SELECTION_INVALID");
  }
  if (!Number.isSafeInteger(value.revision) || value.revision < 0 ||
      !Number.isSafeInteger(value.updatedAt) || value.updatedAt < 0) {
    throw new Error("PET_SELECTION_INVALID");
  }
  return {
    characterId,
    revision: value.revision,
    updatedAt: value.updatedAt,
  };
}

function validatePoseStateResponse(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      Object.keys(value).sort().join(",") !== POSE_STATE_KEYS ||
      value.schemaVersion !== PET_SCHEMA_VERSION ||
      typeof value.characterId !== "string" || !CHARACTER_IDS.has(value.characterId) ||
      typeof value.pose !== "string" || !POSE_NAME_PATTERN.test(value.pose) ||
      typeof value.fallback !== "boolean" ||
      !Number.isSafeInteger(value.since) || value.since < 0 ||
      !Number.isSafeInteger(value.revision) || value.revision < 0) {
    throw new PetBridgeError("PET_POSE_STATE_INVALID", "invalid_response");
  }
  return {
    schemaVersion: value.schemaVersion,
    characterId: value.characterId,
    pose: value.pose,
    fallback: value.fallback,
    since: value.since,
    revision: value.revision,
  };
}

export class PetBridgeClient {
  constructor(fetchImpl, { baseUrl = PET_BASE_URL, timeoutMs = 900 } = {}) {
    if (typeof fetchImpl !== "function") throw new TypeError("A host network fetch function is required");
    const base = new URL(baseUrl);
    if (base.protocol !== "http:" || base.hostname !== "127.0.0.1" ||
        base.origin !== PET_BASE_URL || base.pathname !== "/") {
      throw new Error("PET_ENDPOINT_MUST_BE_LOOPBACK");
    }
    this.fetchImpl = fetchImpl;
    this.baseUrl = base.origin;
    this.timeoutMs = timeoutMs;
    this.lastPoseState = null;
  }

  resetPoseRevision() {
    this.lastPoseState = null;
  }

  async request(path, method, body) {
    const allowedMethods = ROUTES.get(path);
    if (!allowedMethods || !allowedMethods.has(method)) throw new Error("PET_ROUTE_NOT_ALLOWED");
    let bodyText;
    if (body !== undefined) {
      bodyText = JSON.stringify(body);
      if (new TextEncoder().encode(bodyText).byteLength > MAX_BODY_BYTES) throw new Error("PET_REQUEST_TOO_LARGE");
    }
    let response;
    try {
      response = await this.fetchImpl(`${this.baseUrl}${path}`, {
        method,
        headers: bodyText === undefined ? { accept: "application/json" } : {
          accept: "application/json",
          "content-type": "application/json",
        },
        ...(bodyText === undefined ? {} : { body: bodyText }),
        redirect: "error",
        timeoutMs: this.timeoutMs,
        maxResponseBytes: RESPONSE_LIMIT_BYTES,
      });
    } catch {
      throw new PetBridgeError("PET_UNREACHABLE", "unreachable");
    }
    if (response?.redirected === true) throw new PetBridgeError("PET_REDIRECT_REFUSED", "invalid_response");
    if (typeof response?.url === "string" && response.url) {
      try {
        const finalUrl = new URL(response.url);
        if (finalUrl.origin !== this.baseUrl || finalUrl.pathname !== path) {
          throw new PetBridgeError("PET_ORIGIN_CHANGED", "invalid_response");
        }
      } catch (error) {
        if (error instanceof PetBridgeError) throw error;
        throw new PetBridgeError("PET_RESPONSE_INVALID", "invalid_response");
      }
    }
    if (!Number.isSafeInteger(response?.status) || typeof response?.json !== "function") {
      throw new PetBridgeError("PET_RESPONSE_INVALID", "invalid_response");
    }
    let data;
    try {
      data = await response.json();
    } catch {
      throw new PetBridgeError("PET_RESPONSE_INVALID", "invalid_response");
    }
    return { status: response.status, ok: response.ok === true, data };
  }

  async probe() {
    const result = await this.request("/v3/hello", "GET");
    if (result.status === 404) throw new PetBridgeError("PET_SERVICE_MISMATCH", "version_mismatch");
    if (!result.ok || !result.data || typeof result.data !== "object" || Array.isArray(result.data)) {
      throw new PetBridgeError("PET_SERVICE_MISMATCH", "invalid_response");
    }
    if (result.data.service === "hana-desktop-pet" &&
        Number.isSafeInteger(result.data.protocolVersion) &&
        result.data.protocolVersion !== PET_PROTOCOL_VERSION) {
      throw new PetBridgeError("PET_SERVICE_MISMATCH", "version_mismatch");
    }
    if (result.data.service !== "hana-desktop-pet" || result.data.protocolVersion !== PET_PROTOCOL_VERSION) {
      throw new PetBridgeError("PET_SERVICE_MISMATCH", "invalid_response");
    }
    return true;
  }

  async publish(snapshot) {
    const result = await this.request("/v3/snapshot", "POST", snapshot);
    if (!result.ok || result.data?.schemaVersion !== PET_SCHEMA_VERSION || result.data?.accepted !== true) {
      throw new Error("PET_SNAPSHOT_REJECTED");
    }
    return result.data;
  }

  async getSelection() {
    const result = await this.request("/v3/selection", "GET");
    if (!result.ok) throw new Error("PET_SELECTION_UNAVAILABLE");
    return validateSelectionResponse(result.data);
  }

  async getPoseState() {
    const result = await this.request("/v3/state", "GET");
    if (result.status === 404) throw new PetBridgeError("PET_POSE_STATE_UNAVAILABLE", "version_mismatch");
    if (!result.ok) throw new PetBridgeError("PET_POSE_STATE_UNAVAILABLE", "invalid_response");
    const state = validatePoseStateResponse(result.data);
    if (this.lastPoseState) {
      if (state.revision < this.lastPoseState.revision ||
          (state.revision === this.lastPoseState.revision &&
           JSON.stringify(state) !== JSON.stringify(this.lastPoseState))) {
        throw new PetBridgeError("PET_POSE_REVISION_INVALID", "invalid_response");
      }
    }
    this.lastPoseState = state;
    return state;
  }

  async setSelection(selection, expectedRevision) {
    const local = normalizeSelection(selection);
    const result = await this.request("/v3/selection", "POST", {
      schemaVersion: PET_SCHEMA_VERSION,
      characterId: local.characterId,
      expectedRevision: finiteInt(expectedRevision),
      updatedAt: local.updatedAt,
    });
    if (result.status === 409) {
      return { ok: false, selection: validateSelectionResponse(result.data?.selection) };
    }
    if (!result.ok) throw new Error("PET_SELECTION_REJECTED");
    return { ok: true, selection: validateSelectionResponse(result.data?.selection) };
  }
}
