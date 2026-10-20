import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_CHARACTER_ID,
  PET_BASE_URL,
  PET_CATALOG,
  PET_PROTOCOL_VERSION,
  PET_SCHEMA_VERSION,
  PetBridgeClient,
  createSessionDiagnostics,
  normalizeSelection,
  reconcileSelection,
  sessionDiagnostic,
  toPetSnapshot,
} from "../apps/hana-desktop-pet/pet-bridge.mjs";

function response(status, data, overrides = {}) {
  return {
    status,
    ok: status >= 200 && status < 300,
    redirected: false,
    url: `${PET_BASE_URL}/v4/test`,
    async json() { return data; },
    ...overrides,
  };
}

test("pet projection is a strict metadata allowlist and publishes seven manual choices", () => {
  const dto = toPetSnapshot({
    current: {
      sessionId: "session-12345678",
      displayTitle: "代码联调",
      title: "隐藏的原始标题不应覆盖",
      agentId: "agent-coder",
      agentName: "码农",
      status: "working",
      running: true,
      toolName: "file.read",
      activeTools: [{ callId: "private-call-id", toolName: "file.read" }],
      recentToolCallIds: ["private-finished-call-id"],
      feedbackResumed: true,
      runEnded: false,
      lastActivityAt: 4000,
      statusAt: 4000,
      message: "secret message",
      args: { token: "secret args" },
      result: "secret result",
      sessionPath: "/private/session/path",
      credentials: "secret credential",
    },
    prompt: "secret prompt",
  }, 5000);

  assert.equal(PET_PROTOCOL_VERSION, 4);
  assert.equal(PET_SCHEMA_VERSION, 4);
  assert.deepEqual(Object.keys(dto).sort(), [
    "activity", "characters", "concurrentSessions", "followMode", "notifications", "revision", "schemaVersion",
  ].sort());
  assert.equal(dto.schemaVersion, PET_SCHEMA_VERSION);
  assert.deepEqual(Object.keys(dto.activity).sort(), [
    "agentId", "agentName", "hint", "lastActivityAt", "sessionId", "spotlight", "status", "title", "toolName",
  ].sort());
  assert.equal(dto.activity.status, "tool");
  assert.equal(dto.activity.title, "代码联调");
  assert.equal(dto.activity.spotlight, null);
  assert.equal(dto.followMode, "latest");
  assert.equal(dto.concurrentSessions, 0);
  assert.deepEqual(dto.notifications, []);
  assert.deepEqual(dto.characters, PET_CATALOG.map(({ id, name }) => ({ id, name })));
  assert.deepEqual(PET_CATALOG.map(({ id }) => id), [
    "claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie",
  ]);
  const serialized = JSON.stringify(dto);
  for (const privateValue of [
    "secret message", "secret args", "secret result", "secret prompt", "/private/session/path",
    "secret credential", "private-call-id", "private-finished-call-id", "feedbackResumed", "runEnded",
  ]) {
    assert.equal(serialized.includes(privateValue), false);
  }
});

test("short outcomes overlay active work, then restore working/tool/idle without claiming goal success", () => {
  const toolFeedback = toPetSnapshot({ current: {
    sessionId: "s1", status: "success", statusAt: 1000, running: true,
    toolName: null, lastActivityAt: 1000,
  } }, 2000);
  const resumedWork = toPetSnapshot({ current: {
    sessionId: "s1", status: "success", statusAt: 1000, running: true,
    toolName: null, lastActivityAt: 1000,
  } }, 3501);
  const heldError = toPetSnapshot({ current: {
    sessionId: "s1", status: "error", statusAt: 1000, running: true,
    toolName: "file.read", lastActivityAt: 1000,
  } }, 3501);
  const resumedTool = toPetSnapshot({ current: {
    sessionId: "s1", status: "error", statusAt: 1000, running: true,
    toolName: "file.read", lastActivityAt: 1000,
  } }, 5001);
  const terminalRecent = toPetSnapshot({ current: {
    sessionId: "s1", status: "success", statusAt: 1000, running: false,
    lastActivityAt: 1000,
  } }, 2000);
  const terminalExpired = toPetSnapshot({ current: {
    sessionId: "s1", status: "success", statusAt: 1000, running: false,
    lastActivityAt: 1000,
  } }, 5000);

  assert.equal(toolFeedback.activity.status, "success");
  assert.equal(resumedWork.activity.status, "working");
  assert.equal(heldError.activity.status, "error", "the 4 s error hold is still visible");
  assert.equal(resumedTool.activity.status, "tool");
  assert.equal(resumedTool.activity.toolName, "file.read");
  assert.equal(terminalRecent.activity.status, "success");
  assert.equal(terminalExpired.activity.status, "idle");
  assert.equal(toPetSnapshot({}, 8000).activity.status, "idle");
});

test("selection stays manual and old role IDs migrate only to the v2 default", () => {
  assert.equal(DEFAULT_CHARACTER_ID, "claude");
  assert.equal(normalizeSelection({ characterId: "blue-whale" }).characterId, DEFAULT_CHARACTER_ID);
  assert.deepEqual(reconcileSelection(
    { characterId: "gpt-onesie", updatedAt: 20, petRevision: 3 },
    { characterId: "claude", updatedAt: 10, revision: 4 },
  ), {
    action: "push",
    selection: { characterId: "gpt-onesie", updatedAt: 20, petRevision: 4 },
  });
  assert.deepEqual(reconcileSelection(
    { characterId: "claude", updatedAt: 10, petRevision: 2 },
    { characterId: "deepseek-hoodie", updatedAt: 20, revision: 5 },
  ), {
    action: "adopt",
    selection: { characterId: "deepseek-hoodie", updatedAt: 20, petRevision: 5 },
  });
  assert.equal(reconcileSelection(
    { characterId: "claude", updatedAt: 4, petRevision: 2 },
    { characterId: "claude", updatedAt: 9, revision: 8 },
  ).action, "keep");
});

test("client uses fixed loopback routes and requires the v2 peer protocol", async () => {
  const calls = [];
  const client = new PetBridgeClient(async (url, init) => {
    calls.push({ url, init });
    if (url.endsWith("/v4/hello")) {
      return response(200, { service: "hana-desktop-pet", protocolVersion: 4 }, { url });
    }
    if (url.endsWith("/v4/snapshot")) {
      return response(200, { schemaVersion: 4, accepted: true }, { url });
    }
    return response(200, { schemaVersion: 4, characterId: "claude", revision: 0, updatedAt: 0 }, { url });
  });

  assert.equal(await client.probe(), true);
  await client.publish(toPetSnapshot({}, 100));
  await client.getSelection();
  assert.ok(calls.every(({ url }) => url.startsWith(`${PET_BASE_URL}/v4/`)));
  assert.ok(calls.every(({ init }) => init.redirect === "error"));
  assert.equal(calls[1].init.method, "POST");
  assert.equal(JSON.parse(calls[1].init.body).schemaVersion, 4);

  const legacyPeer = new PetBridgeClient(async (url) => response(200, {
    service: "hana-desktop-pet", protocolVersion: 1,
  }, { url }));
  await assert.rejects(legacyPeer.probe(), /PET_SERVICE_MISMATCH/);

  const mismatch = new PetBridgeClient(async (url) => response(200, {
    service: "other-local-process", protocolVersion: 4,
  }, { url }));
  await assert.rejects(mismatch.probe(), /PET_SERVICE_MISMATCH/);

  const redirect = new PetBridgeClient(async (url) => response(200, {}, {
    url,
    redirected: true,
  }));
  await assert.rejects(redirect.probe(), /PET_REDIRECT_REFUSED/);
  assert.throws(() => new PetBridgeClient(async () => {}, { baseUrl: "http://localhost:43127" }), /PET_ENDPOINT_MUST_BE_LOOPBACK/);
  assert.throws(() => new PetBridgeClient(async () => {}, { baseUrl: "http://127.0.0.1:9999" }), /PET_ENDPOINT_MUST_BE_LOOPBACK/);
});

test("selection writes use v4 expected revisions and conflicts return validated v4 selection", async () => {
  let captured;
  const client = new PetBridgeClient(async (url, init) => {
    captured = { url, init };
    return response(409, {
      selection: { schemaVersion: 4, characterId: "deepseek-hoodie", revision: 8, updatedAt: 900 },
    }, { url });
  });
  const result = await client.setSelection({ characterId: "gpt-onesie", updatedAt: 950 }, 7);
  assert.equal(captured.url, `${PET_BASE_URL}/v4/selection`);
  assert.equal(captured.init.method, "POST");
  assert.deepEqual(JSON.parse(captured.init.body), {
    schemaVersion: 4,
    characterId: "gpt-onesie",
    expectedRevision: 7,
    updatedAt: 950,
  });
  assert.deepEqual(result, {
    ok: false,
    selection: { characterId: "deepseek-hoodie", revision: 8, updatedAt: 900 },
  });

  await assert.rejects(
    new PetBridgeClient(async (url) => response(200, {
      schemaVersion: 1, characterId: "blue-whale", revision: 2, updatedAt: 100,
    }, { url })).getSelection(),
    /PET_PROTOCOL_INVALID/,
  );
});

test("a diagnostic keeps only enums: code, kind, operation and an optional selector", () => {
  const error = Object.assign(new Error("host said: /Users/x/private/session.jsonl exploded"), {
    code: "APP_HOST_ERROR", kind: "host",
  });
  const plain = sessionDiagnostic(error, { operation: "session:list" });
  assert.deepEqual(plain, { code: "APP_HOST_ERROR", kind: "host", operation: "session:list" });
  assert.equal("selector" in plain, false, "a list call has no selector");

  const byId = sessionDiagnostic(error, { operation: "session:get", selector: "id" });
  assert.deepEqual(byId, { code: "APP_HOST_ERROR", kind: "host", operation: "session:get", selector: "id" });
  const byPath = sessionDiagnostic(error, { operation: "session:get", selector: "path" });
  assert.equal(byPath.selector, "path", "the selector kind is preserved");
  assert.deepEqual(Object.keys(byPath).sort(),
    ["code", "kind", "operation", "selector"], "nothing else is kept");

  // Anything the host made up is downgraded or dropped.
  assert.equal(sessionDiagnostic(error, { operation: "session:get", selector: "/private/session" }).selector,
    undefined, "an arbitrary selector value is rejected");
  assert.equal(sessionDiagnostic(error, { operation: "session:get", selector: "sessionId" }).selector,
    undefined, "the actual id is never stored");
  const junk = sessionDiagnostic({ code: "bad code!", kind: "nonsense", message: "secret" },
    { operation: "session:get", selector: "id" });
  assert.deepEqual(junk, { code: "APP_HOST_ERROR", kind: "host", operation: "session:get", selector: "id" });

  // The message never survives, in any shape.
  const serialized = JSON.stringify([
    plain, byId, byPath, junk,
    sessionDiagnostic(error, { operation: "session:get", fallback: "empty", selector: "path" }),
  ]);
  for (const leak of ["exploded", "/Users", "private/session", "host said", "secret"]) {
    assert.equal(serialized.includes(leak), false, `diagnostics leak ${leak}`);
  }

  assert.deepEqual(createSessionDiagnostics(), { schemaVersion: 1, observedAt: 0, list: null, get: null });
});

function syntheticSession(overrides = {}) {
  return {
    sessionId: "session-a",
    displayTitle: "甲",
    title: "甲",
    running: false,
    runEnded: true,
    status: "success",
    statusAt: 1000,
    lastRunEndedAt: 1000,
    lastActivityAt: 1000,
    closedAt: 0,
    hint: null,
    hintAt: 0,
    unresolved: false,
    ...overrides,
  };
}

test("the v4 projection carries bounded follow, concurrency and notice metadata", () => {
  const ended = syntheticSession({ sessionId: "session-a", displayTitle: "甲" });
  const confirming = syntheticSession({
    sessionId: "session-b", displayTitle: "乙", running: true, runEnded: false,
    status: "working", statusAt: 2000, lastRunEndedAt: 0, lastActivityAt: 2000,
    hint: "confirming", hintAt: 2100,
  });
  const placeholder = syntheticSession({
    sessionId: "unresolved:abc12345", running: true, status: "working",
    lastActivityAt: 2000, lastRunEndedAt: 0, unresolved: true,
  });
  const snapshot = { sessions: [ended, confirming, placeholder], current: confirming };

  const latest = toPetSnapshot(snapshot, 3000, { followMode: "latest" });
  assert.equal(latest.followMode, "latest");
  assert.equal(latest.concurrentSessions, 1, "only the real running session is counted");
  assert.deepEqual(latest.notifications.map((item) => item.kind), ["confirmation", "completion"]);
  assert.equal(latest.notifications[0].title, "乙");
  assert.equal(latest.notifications[1].title, "甲");
  assert.ok(latest.notifications.every((item) => /^(confirmation|completion):[0-9a-f]{8}:\d+$/.test(item.id)));

  const pinnedB = toPetSnapshot(snapshot, 3000, { followMode: "pinned", pinnedSessionId: "session-b" });
  assert.equal(pinnedB.followMode, "pinned");
  assert.deepEqual(pinnedB.notifications.map((item) => item.kind), ["confirmation"],
    "a bound pet only notifies the bound conversation");

  const pinnedA = toPetSnapshot(snapshot, 3000, { followMode: "pinned", pinnedSessionId: "session-a" });
  assert.deepEqual(pinnedA.notifications.map((item) => item.kind), ["completion"]);

  const pinnedMissing = toPetSnapshot(snapshot, 3000, { followMode: "pinned", pinnedSessionId: "session-gone" });
  assert.deepEqual(pinnedMissing.notifications, []);

  const serialized = JSON.stringify(latest);
  for (const leak of ["secret", "/private", "args", "result", "prompt"]) {
    assert.equal(serialized.includes(leak), false, `the v4 projection leaks ${leak}`);
  }
});

test("completion notices expire, dedupe and never replace a pending confirmation", () => {
  const ended = syntheticSession({ sessionId: "session-a", displayTitle: "甲" });
  const confirming = syntheticSession({
    sessionId: "session-b", displayTitle: "乙", running: true, runEnded: false,
    status: "working", statusAt: 2000, lastRunEndedAt: 0, lastActivityAt: 2000,
    hint: "confirming", hintAt: 2100,
  });
  const duplicate = { ...ended };
  const snapshot = { sessions: [ended, duplicate, confirming], current: confirming };

  const fresh = toPetSnapshot(snapshot, 3000, { followMode: "latest" });
  assert.equal(fresh.notifications.filter((item) => item.kind === "completion").length, 1,
    "a duplicated row cannot duplicate the notice");

  const expired = toPetSnapshot(snapshot, 1000 + 20001, { followMode: "latest" });
  assert.equal(expired.notifications.filter((item) => item.kind === "completion").length, 0,
    "an old completion is history");
  assert.equal(expired.notifications.filter((item) => item.kind === "confirmation").length, 1,
    "the still-pending confirmation remains");

  const closed = syntheticSession({
    sessionId: "session-c", closedAt: 2000, lastActivityAt: 1000,
  });
  const closedDto = toPetSnapshot({ sessions: [closed], current: closed }, 3000, { followMode: "latest" });
  assert.deepEqual(closedDto.notifications, [], "a closed session raises nothing");

  const staleHint = syntheticSession({
    sessionId: "session-d", running: true, status: "working", lastActivityAt: 2000,
    lastRunEndedAt: 0, hint: "confirming", hintAt: 1000,
  });
  const staleDto = toPetSnapshot({ sessions: [staleHint], current: staleHint }, 1000 + 600001, { followMode: "latest" });
  assert.deepEqual(staleDto.notifications, [], "an expired hint is not a live confirmation");
});

test("the drawing spotlight is a display marker bounded by its own TTL", () => {
  const drawing = syntheticSession({
    sessionId: "session-draw", running: true, runEnded: false, status: "working",
    statusAt: 1000, lastRunEndedAt: 0, lastActivityAt: 1000, drawingAt: 1000,
  });
  const fresh = toPetSnapshot({ sessions: [drawing], current: drawing }, 2000);
  assert.deepEqual(fresh.activity.spotlight, { kind: "drawing", at: 1000 });
  assert.equal(fresh.activity.status, "working", "the marker never changes the real status");

  const expired = toPetSnapshot({ sessions: [drawing], current: drawing }, 1000 + 30001);
  assert.equal(expired.activity.spotlight, null);

  const future = syntheticSession({ ...drawing, drawingAt: 9000 });
  assert.equal(toPetSnapshot({ sessions: [future], current: future }, 2000).activity.spotlight, null,
    "a future timestamp is not trusted");

  const closed = syntheticSession({ ...drawing, closedAt: 2000, lastActivityAt: 1000 });
  assert.equal(toPetSnapshot({ sessions: [closed], current: closed }, 2000).activity.spotlight, null);
});
