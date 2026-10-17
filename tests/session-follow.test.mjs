import test from "node:test";
import assert from "node:assert/strict";
import { createHarness } from "./synthetic-host.mjs";
import app from "../apps/hana-desktop-pet/index.js";
import {
  FOLLOW_KEY,
  SESSION_LIST_KEY,
  SNAPSHOT_KEY,
  SELECTION_KEY,
} from "../apps/hana-desktop-pet/pet-bridge.mjs";

const PRIVATE_SENTINELS = [
  "/private/session/path", "/private/cwd", "private first message",
  "private-model", "private-owner", "secret-tool-arg", "secret-result",
];
const FOLLOW_REQUEST_KEY = "hana-pet.follow.request";
const BRIDGE_ENABLED_KEY = "hana-pet.bridge.enabled";
const LIST_REFRESH_MS = 5000;
const BRIDGE_POLL_MS = 1500;

const ENTRY_KEYS = ["agentId", "agentName", "displayTitle", "lifecycle", "sessionId", "title"];

function fullEntries() {
  const bare = [
    { sessionId: "session-alpha-0001", title: "标题·甲", agentId: "agent-coder", agentName: "码农", path: "/private/session/alpha", cwd: "/private/cwd/alpha" },
    { sessionId: "session-beta-0002", title: null, agentId: "agent-writer", agentName: "执笔", path: "/private/session/beta", cwd: "/private/cwd/beta" },
    { sessionId: "session-gamma-0003", title: "   ", agentId: null, agentName: null, path: "/private/session/gamma", cwd: "/private/cwd/gamma" },
  ];
  const extras = {
    sessionId: null, path: "/private/session/path", title: null, firstMessage: "private first message",
    agentId: null, agentName: null, modelId: "private-model", messageCount: 3, cwd: "/private/cwd",
    modified: 1700000000000, ownerPluginId: "private-owner", kind: "chat", visibility: "private",
    lifecycle: "active", archivedAt: null,
  };
  return bare.map((entry) => ({ ...extras, ...entry }));
}

/** Mount the real entry against the synthetic host with timers captured. */
async function mount(options = {}) {
  const harness = createHarness({ sessions: options.sessions ?? fullEntries(), ...options });
  harness.installTimers();
  try {
    await app.apply(harness.sdk);
  } catch (error) {
    harness.restoreTimers();
    throw error;
  }
  await settle();
  return harness;
}

/** Step the clock between events so receive ordering stays unambiguous. */
async function emit(harness, event, sessionPath, delayMs = 1) {
  const subscription = harness.state.subscriptions[0];
  assert.ok(subscription, "the App subscribed to the public bus");
  await harness.tick(delayMs);
  await subscription.callback(event, sessionPath);
  await settle();
}

async function settle() {
  for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function request(harness, pinnedSessionId, requestId = `req-${Math.random()}`) {
  await harness.write(FOLLOW_REQUEST_KEY, { requestId, pinnedSessionId });
  await settle();
}



function assertClean(value, label) {
  const serialized = JSON.stringify(value);
  for (const sentinel of PRIVATE_SENTINELS) {
    assert.equal(serialized.includes(sentinel), false, `${label} leaks ${sentinel}`);
  }
}

test("every session row carries a distinguishable title, never a bare 会话", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta");
  await emit(harness, { type: "agent_start", sessionId: "session-gamma-0003" }, "/private/session/gamma");

  const snapshot = harness.read(SNAPSHOT_KEY);
  const titles = snapshot.sessions.map((item) => item.displayTitle);
  assert.equal(new Set(titles).size, titles.length, "rows must be distinguishable");
  for (const item of snapshot.sessions) {
    assert.equal(typeof item.displayTitle, "string");
    assert.ok(item.displayTitle.length > 0);
    assert.notEqual(item.displayTitle, "会话", "no row may degrade to a bare 会话");
  }

  const beta = snapshot.sessions.find((item) => item.sessionId === "session-beta-0002");
  const gamma = snapshot.sessions.find((item) => item.sessionId === "session-gamma-0003");
  assert.equal(beta.displayTitle, "会话 · eta-0002", "a missing title falls back to the short id");
  assert.equal(gamma.displayTitle, "会话 · mma-0003", "a whitespace title is treated as missing");

  // The list rows are resolved by the very same rule as the current session.
  const listed = harness.read(SESSION_LIST_KEY);
  for (const item of listed.sessions) {
    assert.equal(typeof item.displayTitle, "string", "list rows get a title too");
    assert.ok(item.displayTitle.length > 0);
    assert.notEqual(item.displayTitle, "会话");
  }
  const listedBeta = listed.sessions.find((item) => item.sessionId === "session-beta-0002");
  assert.equal(listedBeta.displayTitle, "会话 · eta-0002", "the list uses the same fallback as the current session");
});

test("the persisted session list keeps only the metadata allowlist", async () => {
  const harness = await mount();
  const list = harness.read(SESSION_LIST_KEY);
  assert.equal(list.available, true);
  assert.equal(list.sessions.length, 3);
  for (const item of list.sessions) {
    assert.deepEqual(Object.keys(item).sort(), ENTRY_KEYS,
      "only sessionId/title/agent/lifecycle plus the derived title survive");
  }
  assertClean(list, "session list");
  assertClean(harness.store, "whole store");

  // An outside write must be re-projected on load, never trusted.
  await harness.write(SESSION_LIST_KEY, {
    schemaVersion: 1, observedAt: 1, available: true, sessions: [{
      sessionId: "session-alpha-0001", title: "注入标题", agentId: "a", agentName: "b",
      lifecycle: "active", path: "/private/session/path", cwd: "/private/cwd",
      firstMessage: "private first message", messageCount: 9,
    }],
  });
  const reload = await mount({
    seed: {
      [SESSION_LIST_KEY]: {
        schemaVersion: 1, observedAt: 1, available: true, sessions: [{
          sessionId: "session-alpha-0001", title: "注入标题", agentId: "a", agentName: "b",
          lifecycle: "active", path: "/private/session/path", cwd: "/private/cwd",
          firstMessage: "private first message", messageCount: 9,
        }],
      },
    },
  });
  const cleaned = reload.read(SESSION_LIST_KEY);
  assert.deepEqual(Object.keys(cleaned.sessions[0]).sort(), ENTRY_KEYS);
  assert.equal(cleaned.sessions[0].path, undefined);
  assert.equal(cleaned.sessions[0].cwd, undefined);
  assert.equal(cleaned.sessions[0].firstMessage, undefined);
  assertClean(cleaned, "re-projected list");

  // A snapshot restored from storage is re-projected too.
  await harness.write(SESSION_LIST_KEY, {
    schemaVersion: 1, observedAt: 1, available: true,
    sessions: [{ sessionId: "s1", title: "t", agentId: "a", agentName: "n", lifecycle: "active",
      path: "/private/session/path", cwd: "/private/cwd" }],
  });
  const snapshotReload = await mount({
    seed: {
      [SNAPSHOT_KEY]: {
        schemaVersion: 1, observedAt: 1, revision: 4, sessions: [{
          sessionId: "session-alpha-0001", title: "甲", agentId: "a", agentName: "n", status: "working",
          running: true, toolName: "file.read", lastActivityAt: 5, statusAt: 5,
          path: "/private/session/path", message: "private first message",
        }], current: null,
      },
    },
  });
  const restored = snapshotReload.read(SNAPSHOT_KEY);
  assert.equal(restored.current.running, false, "a restart never revives stale work");
  assert.equal(restored.current.toolName, null);
  assert.equal(restored.current.path, undefined);
  assertClean(snapshotReload.store, "restored store");
});

test("a denied, broken or malformed session:list degrades to existing behaviour", async () => {
  for (const listMode of ["denied", "throw", "malformed"]) {
    const harness = await mount({ listMode });
    await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
    await emit(harness, { type: "tool_execution_start", sessionId: "session-alpha-0001", toolName: "file.read",
      args: { token: "secret-tool-arg" }, result: "secret-result" }, "/private/session/alpha");

    const snapshot = harness.read(SNAPSHOT_KEY);
    assert.equal(snapshot.current.sessionId, "session-alpha-0001", `${listMode} still follows activity`);
    assert.equal(snapshot.current.toolName, "file.read");
    assert.equal(snapshot.current.displayTitle, "标题·甲");

    const list = harness.read(SESSION_LIST_KEY);
    assert.equal(list.available, false, `${listMode} must not claim a real list`);
    assert.deepEqual(list.sessions, []);
    assert.equal(harness.read(FOLLOW_KEY).mode, "latest", `${listMode} keeps the default follow`);
    assert.ok(harness.state.logs.length > 0, `${listMode} still logs startup`);
    assertClean(harness.store, `${listMode} store`);

    // The periodic refresh must not throw out of the timer either.
    await harness.tick(LIST_REFRESH_MS);
    assert.equal(harness.read(SESSION_LIST_KEY).available, false);
  }
});

test("a denied session:get does not stop activity tracking", async () => {
  const harness = await mount({ getMode: "denied" });
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, "session-alpha-0001");
  // The list is the primary naming source, so the real title still comes through.
  assert.equal(snapshot.current.displayTitle, "标题·甲");
});

test("pinning a session keeps it current even when another session is newer", async () => {
  const harness = await mount();
  await emit(harness, { type: "tool_execution_end", sessionId: "session-alpha-0001", isError: false }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 3001);
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-beta-0002", "newer idle challenger clears the activity margin");

  await request(harness, "session-alpha-0001");

  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, "session-alpha-0001", "the pin wins immediately");
  assert.equal(snapshot.current.displayTitle, "标题·甲");
  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "pinned");
  assert.equal(follow.pinnedSessionId, "session-alpha-0001");
  assert.equal(follow.reason, "pinned");
  assert.equal(follow.followedSessionId, "session-alpha-0001");
  assert.equal(follow.released, null);
  assertClean(harness.store, "store after pinning");

  await emit(harness, { type: "agent_start", sessionId: "session-gamma-0003" }, "/private/session/gamma");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001", "another session cannot steal the pin");
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned");

  await emit(harness, { type: "tool_execution_start", sessionId: "session-alpha-0001", toolName: "search" }, "/private/session/alpha");
  const afterTool = harness.read(SNAPSHOT_KEY);
  assert.equal(afterTool.current.sessionId, "session-alpha-0001");
  assert.equal(afterTool.current.toolName, "search");
});

test("unpinning returns to following the most recent activity", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await request(harness, "session-alpha-0001");
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned");

  await emit(harness, { type: "agent_end", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 3001);
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001", "the pin holds");

  await request(harness, null, "req-unpin");
  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "latest");
  assert.equal(follow.pinnedSessionId, null);
  assert.equal(follow.reason, "latest");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-beta-0002", "back to the newest activity");
});

test("manual unpin bypasses hysteresis and immediately follows a challenger 1 second ahead", async () => {
  const harness = await mount();
  await emit(harness, { type: "tool_execution_end", sessionId: "session-alpha-0001", isError: false }, "/private/session/alpha");
  await request(harness, "session-alpha-0001");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 1001);

  const pinned = harness.read(SNAPSHOT_KEY);
  assert.equal(pinned.current.sessionId, "session-alpha-0001", "pin remains authoritative before unpin");
  const alphaAt = pinned.sessions.find((item) => item.sessionId === "session-alpha-0001").lastActivityAt;
  const betaAt = pinned.sessions.find((item) => item.sessionId === "session-beta-0002").lastActivityAt;
  assert.equal(betaAt - alphaAt, 1001, "the challenger is below the ordinary 2-second margin");

  await request(harness, null, "req-unpin-one-second");
  assert.equal(harness.read(FOLLOW_KEY).mode, "latest");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-beta-0002",
    "the explicit unpin follows latest immediately");
});

test("a closed pinned session releases the pin and the pet keeps moving", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 1001);
  await request(harness, "session-alpha-0001");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001");

  await emit(harness, { type: "session_closed", sessionId: "session-alpha-0001" }, "/private/session/alpha");

  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "latest", "a closed session must not hold the pin");
  assert.equal(follow.pinnedSessionId, null);
  assert.equal(follow.released.sessionId, "session-alpha-0001");
  assert.equal(follow.released.reason, "pinned_closed");
  assert.ok(Number.isSafeInteger(follow.released.at));

  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, "session-beta-0002", "the pet follows a live session, not a dead pin");
  assert.equal(follow.followedSessionId, "session-beta-0002");
  assert.equal(follow.reason, "latest");
});

test("a session closed and then used again can be pinned without being released in the same turn", async () => {
  // The reported bug: the host sent session_closed for a session the user kept
  // using, so the first click on that row pinned it and released it immediately
  // with a bogus "已取消固定 … 会话已关闭" notice.
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 1001);
  await emit(harness, { type: "session_closed", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  assert.ok(harness.read(SNAPSHOT_KEY).sessions
    .find((item) => item.sessionId === "session-alpha-0001").closedAt > 0, "the close was recorded");

  // The user keeps working in that very session.
  await emit(harness, { type: "turn_start", sessionId: "session-alpha-0001" }, "/private/session/alpha", 1002);
  const resumed = harness.read(SNAPSHOT_KEY).sessions
    .find((item) => item.sessionId === "session-alpha-0001");
  assert.equal(resumed.closedAt, 0, "activity after the close clears it");

  await request(harness, "session-alpha-0001");

  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "pinned", "the pin must survive the click that created it");
  assert.equal(follow.pinnedSessionId, "session-alpha-0001");
  assert.equal(follow.released, null, "no release notice is produced");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001");
  assertClean(harness.store, "store after pinning a resumed session");
});

test("an archived pinned session releases immediately to a challenger inside the margin", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_end", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 1001);
  await request(harness, "session-alpha-0001");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001");

  // The host now reports the pinned session as archived.
  harness.setSessions(fullEntries().map((entry) => (
    entry.sessionId === "session-alpha-0001"
      ? { ...entry, lifecycle: "archived", archivedAt: "2026-01-01T00:00:00Z" }
      : entry
  )));
  await harness.tick(LIST_REFRESH_MS);

  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "latest");
  assert.equal(follow.released.reason, "pinned_archived");
  assert.equal(follow.released.sessionId, "session-alpha-0001");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-beta-0002");
});

test("a pin absent from the list is held through a grace window, then released", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_end", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta", 3001);
  await request(harness, "session-ghost-9999");

  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "pinned", "an unseen pin is not dropped instantly");
  assert.ok(Number.isSafeInteger(follow.missingSince), "the absence is timestamped");
  assert.equal(follow.released, null);

  // With no row at all for the pin, the pet must not freeze: it already follows a live session.
  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, "session-beta-0002", "an unseen pin does not freeze the pet");
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned", "but the pin itself is still held");

  await harness.tick(LIST_REFRESH_MS);
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned", "the grace window is respected");

  // Reappearing in the list revives the pin instead of dropping it.
  harness.setSessions([...fullEntries(), { ...fullEntries()[0], sessionId: "session-ghost-9999", title: null }]);
  await harness.tick(LIST_REFRESH_MS);
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned", "a returning session keeps its pin");
  assert.equal(harness.read(FOLLOW_KEY).missingSince, null);
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-ghost-9999", "the revived pin leads again");
  assert.equal(harness.read(SNAPSHOT_KEY).current.lastActivityAt, 0, "no activity is fabricated");

  harness.setSessions(fullEntries());

  // One refresh stamps the absence; the next one past the grace window releases it.
  await harness.tick(LIST_REFRESH_MS);
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned", "the grace window starts at the next sighting");
  await harness.tick(LIST_REFRESH_MS * 4);
  const released = harness.read(FOLLOW_KEY);
  assert.equal(released.mode, "latest", "a dead pin must never freeze the pet");
  assert.equal(released.released.reason, "pinned_missing");
  assert.equal(released.released.sessionId, "session-ghost-9999");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-beta-0002");
});

test("a pin absent only because listing is denied is never released", async () => {
  const harness = await mount({ listMode: "denied" });
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await emit(harness, { type: "agent_start", sessionId: "session-beta-0002" }, "/private/session/beta");
  await request(harness, "session-alpha-0001");
  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned");

  await harness.tick(LIST_REFRESH_MS * 10);
  const follow = harness.read(FOLLOW_KEY);
  assert.equal(follow.mode, "pinned", "absence of evidence is not evidence of absence");
  assert.equal(follow.missingSince, null);
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001");
});

test("malformed pin requests are ignored without changing the follow state", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  assert.equal(harness.read(FOLLOW_KEY).mode, "latest");

  for (const payload of [
    { requestId: "r1", pinnedSessionId: "/private/session/alpha" },
    { requestId: "r2", pinnedSessionId: "../../etc/passwd" },
    { requestId: "r3", pinnedSessionId: 42 },
    { requestId: "r4", pinnedSessionId: { nested: "x" } },
    { requestId: "r5", pinnedSessionId: "注入\n换行" },
    { requestId: "r6", pinnedSessionId: "a".repeat(400) },
    { requestId: "r7", pinnedSessionId: "" },
    "not-an-object",
    null,
  ]) {
    await harness.write(FOLLOW_REQUEST_KEY, payload);
    await settle();
    const follow = harness.read(FOLLOW_KEY);
    assert.ok(follow, `follow record survived: ${JSON.stringify(payload)}`);
    assert.equal(follow.mode, "latest", `rejected: ${JSON.stringify(payload)}`);
    assert.equal(follow.pinnedSessionId, null);
  }
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-alpha-0001");
});

test("a repeated request id is applied once and events never change the character", async () => {
  const harness = await mount();
  assert.equal(harness.read(SELECTION_KEY).characterId, "claude");
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");

  await request(harness, "session-beta-0002", "same-id");
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, "session-beta-0002");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, "session-beta-0002");

  // The same request id arriving again is a no-op.
  await harness.write(FOLLOW_REQUEST_KEY, { requestId: "same-id", pinnedSessionId: null });
  await settle();
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, "session-beta-0002", "duplicate ids are ignored");

  assert.equal(harness.read(SELECTION_KEY).characterId, "claude", "pinning is not a role change");
  assertClean(harness.store, "full store");
});

test("the pet projection stays body-free while following a pinned session", async () => {
  const harness = await mount({ seed: { [BRIDGE_ENABLED_KEY]: true } });
  await emit(harness, { type: "agent_start", sessionId: "session-alpha-0001" }, "/private/session/alpha");
  await request(harness, "session-beta-0002");
  await emit(harness, { type: "tool_execution_start", sessionId: "session-beta-0002", toolName: "file.write",
    args: { token: "secret-tool-arg" } }, "/private/session/beta");

  await harness.tick(BRIDGE_POLL_MS * 2);

  assert.ok(harness.state.published.length > 0, "the bridge published a snapshot");
  for (const dto of harness.state.published) {
    assert.deepEqual(Object.keys(dto).sort(), ["activity", "characters", "revision", "schemaVersion"]);
    assert.deepEqual(Object.keys(dto.activity).sort(),
      ["agentId", "agentName", "hint", "lastActivityAt", "sessionId", "status", "title", "toolName"]);
    assertClean(dto, "published dto");
  }
  const latest = harness.state.published[harness.state.published.length - 1];
  assert.equal(latest.activity.sessionId, "session-beta-0002", "the pet sees the pinned session");
  assert.equal(latest.activity.title, "会话 · eta-0002", "the pinned title uses the same fallback");
  assert.equal(latest.activity.toolName, "file.write");
});

const SESSION_DIAGNOSTICS_KEY = "hana-pet.session-diagnostics";
const REAL_PATH = "/private/session/real-0001";
const REAL_ID = "sess_real0_7e54cc427982b968";

/** A host whose list carries the real session, so path -> id can be learned. */
function withRealSession(overrides = {}) {
  return mount({
    sessions: [{
      sessionId: REAL_ID, title: "歌词双行显示设置", agentId: "agent-hanako", agentName: "哦鲸鲸",
      path: REAL_PATH, cwd: "/private/cwd/real", firstMessage: "private first message",
      lifecycle: "active", messageCount: 12, modelId: "private-model", ownerPluginId: "private-owner",
      kind: "chat", visibility: "private", modified: 1700000000000, archivedAt: null,
    }],
    ...overrides,
  });
}

test("path-only events land on the real session id, never a local-session placeholder", async () => {
  const harness = await withRealSession();
  // The event carries no sessionId at all — only the bus callback path.
  await emit(harness, { type: "agent_start" }, REAL_PATH);
  await emit(harness, { type: "tool_execution_start", toolName: "exec_command",
    args: { token: "secret-tool-arg" } }, REAL_PATH);

  const snapshot = harness.read(SNAPSHOT_KEY);
  const ids = snapshot.sessions.map((item) => item.sessionId);
  assert.deepEqual(ids, [REAL_ID], "activity is attributed to the real session");
  assert.equal(ids.some((id) => /^local-session-\d+$/.test(id)), false, "no fake local-session id");
  assert.equal(snapshot.current.sessionId, REAL_ID);
  assert.equal(snapshot.current.title, "歌词双行显示设置");
  assert.equal(snapshot.current.toolName, "exec_command");
  assert.ok(snapshot.current.lastActivityAt > 0, "the real session shows real activity");
  assertClean(harness.store, "store with path-only events");
});

test("unresolved activity is parked under a stable placeholder and merged once resolved", async () => {
  // No session:get, no usable list: the id cannot be resolved yet.
  const harness = await mount({ sessions: [], listMode: "denied", getMode: "denied" });
  await emit(harness, { type: "agent_start" }, REAL_PATH);
  await emit(harness, { type: "tool_execution_start", toolName: "exec_command" }, REAL_PATH);

  let snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.sessions.length, 1);
  const parked = snapshot.sessions[0];
  assert.equal(parked.sessionId.startsWith("local-session-"), false, "no legacy fake id");
  assert.equal(parked.sessionId.startsWith("unresolved:"), true, "parked under a stable placeholder");
  assert.equal(parked.unresolved, true);
  // A placeholder must never be presented as the session the pet follows.
  assert.equal(snapshot.current, null, "an unresolved row never becomes the current session");
  assert.equal(harness.read(FOLLOW_KEY).mode, "latest");
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, null);

  // Repeating the same path must reuse the same key, not mint another one.
  await emit(harness, { type: "agent_end" }, REAL_PATH);
  snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.sessions.length, 1, "the same path keeps one row");
  assert.equal(snapshot.sessions[0].sessionId, parked.sessionId, "the placeholder key is stable");
  assert.ok(snapshot.sessions[0].lastActivityAt > 0, "the parked activity is recorded");
  assert.equal(snapshot.sessions[0].runEnded, true, "the parked run is tracked as ended");

  // Now the host starts answering again: the list teaches us path -> id.
  harness.setListMode("ok");
  harness.setSessions([{
    sessionId: REAL_ID, title: "歌词双行显示设置", agentName: "哦鲸鲸",
    path: REAL_PATH, cwd: "/private/cwd/real", firstMessage: "private first message", lifecycle: "active",
  }]);
  const listed = harness.state.listCalls.length;
  await harness.tick(LIST_REFRESH_MS);

  const merged = harness.read(SNAPSHOT_KEY);
  assert.ok(harness.state.listCalls.length > listed, "the list was consulted again");
  assert.equal(merged.sessions.length, 1, "the placeholder is gone, not duplicated");
  assert.equal(merged.sessions[0].sessionId, REAL_ID, "activity merged onto the real id");
  assert.equal(merged.sessions[0].sessionId.startsWith("unresolved:"), false);
  assert.equal(merged.current.sessionId, REAL_ID, "the real session now leads");
  assert.equal(merged.current.title, "歌词双行显示设置");
  assert.ok(merged.current.lastActivityAt > 0, "the merged activity is preserved");
  assert.equal(merged.current.runEnded, true, "the merged run keeps its terminal state");
  assertClean(harness.store, "store after merge");
});

test("a placeholder is never offered for pinning and never accepted as a pin", async () => {
  const harness = await mount({ sessions: [], listMode: "denied", getMode: "denied" });
  await emit(harness, { type: "agent_start" }, REAL_PATH);
  const snapshot = harness.read(SNAPSHOT_KEY);
  const placeholder = snapshot.sessions[0].sessionId;
  assert.equal(placeholder.startsWith("unresolved:"), true);

  // It never reaches the selectable list.
  const list = harness.read(SESSION_LIST_KEY);
  assert.deepEqual(list.sessions, [], "placeholders are filtered out of the list");

  // A direct pin request for it is rejected.
  await request(harness, placeholder);
  assert.equal(harness.read(FOLLOW_KEY).mode, "latest", "a placeholder cannot be pinned");
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, null);

  // A legacy local-session id is rejected too.
  await request(harness, "local-session-3", "req-legacy");
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, null, "legacy placeholders cannot be pinned");
  assert.equal(harness.read(SNAPSHOT_KEY).current, null);
});

test("stale local-session rows are dropped on load", async () => {
  const legacy = {
    schemaVersion: 1, observedAt: 1700000000000, revision: 9473,
    sessions: [
      { sessionId: "local-session-1", title: null, agentId: null, agentName: null, status: "success",
        running: false, toolName: null, lastActivityAt: 1000, statusAt: 1000 },
      { sessionId: "local-session-3", title: null, agentId: null, agentName: null, status: "working",
        running: true, toolName: "exec_command", lastActivityAt: 2000, statusAt: 2000 },
      { sessionId: REAL_ID, title: "歌词双行显示设置", agentId: "agent-hanako", agentName: "哦鲸鲸",
        status: "idle", running: false, toolName: null, lastActivityAt: 30, statusAt: 30 },
    ],
    current: { sessionId: "local-session-3", title: null, status: "working", running: true,
      toolName: "exec_command", lastActivityAt: 2000, statusAt: 2000 },
  };
  const harness = await mount({ seed: { [SNAPSHOT_KEY]: legacy } });

  const cleaned = harness.read(SNAPSHOT_KEY);
  const ids = cleaned.sessions.map((item) => item.sessionId);
  assert.equal(ids.includes("local-session-1"), false, "legacy row 1 dropped");
  assert.equal(ids.includes("local-session-3"), false, "legacy row 3 dropped");
  assert.deepEqual(ids, [REAL_ID], "the real session survives");
  assert.equal(cleaned.current.sessionId, REAL_ID, "the real session leads after cleanup");
  assert.equal(cleaned.current.running, false, "a restart never revives stale work");
  assert.equal(cleaned.current.toolName, null);
  assertClean(harness.store, "store after legacy cleanup");
});

test("session-call failures record a diagnostic code/kind and never a message", async () => {
  // Permission denied on the list.
  const denied = await mount({ listMode: "denied" });
  await denied.tick(LIST_REFRESH_MS);
  const diagDenied = denied.read(SESSION_DIAGNOSTICS_KEY);
  assert.equal(diagDenied.list.kind, "permission", "the permission kind is reported");
  assert.equal(diagDenied.list.code, "APP_CAPABILITY_DENIED");
  assert.equal(diagDenied.list.operation, "session:list");
  assert.equal("selector" in diagDenied.list, false, "a list call has no selector");
  assert.deepEqual(Object.keys(diagDenied.list).sort(), ["code", "kind", "operation"]);
  const deniedJson = JSON.stringify(diagDenied);
  for (const leak of ["Missing", "denied by", "/private", "secret", "message"]) {
    assert.equal(deniedJson.includes(leak), false, `diagnostics leak ${leak}`);
  }
  assert.equal(denied.read(SESSION_LIST_KEY).available, false);

  // Host throws with an unrecognised code: still classified, message dropped.
  const broken = await mount({ listMode: "throw" });
  await broken.tick(LIST_REFRESH_MS);
  const diagBroken = broken.read(SESSION_DIAGNOSTICS_KEY);
  assert.equal(typeof diagBroken.list.code, "string");
  assert.ok(["host", "timeout", "aborted", "unsupported", "permission"].includes(diagBroken.list.kind));
  assert.equal(JSON.stringify(diagBroken).includes("APP_UNEXPECTED"), true, "the stable code is kept");

  // A well-formed reply with no list is reported as malformed.
  const malformed = await mount({ listMode: "malformed" });
  await malformed.tick(LIST_REFRESH_MS);
  assert.equal(malformed.read(SESSION_DIAGNOSTICS_KEY).list.kind, "malformed");

  // A `session:get` failure is recorded in its own slot.
  const getBroken = await mount();
  getBroken.failNextGet(getBroken.sdkError("RPC_TIMEOUT", "timeout"));
  await emit(getBroken, { type: "session_created", sessionId: "sess_unknown01" }, "/private/session/x");
  const diagGet = getBroken.read(SESSION_DIAGNOSTICS_KEY);
  assert.equal(diagGet.get.code, "RPC_TIMEOUT");
  assert.equal(diagGet.get.kind, "timeout");
  assert.equal(diagGet.get.operation, "session:get");
  assert.equal(diagGet.get.selector, "id", "an id-selected get is recorded as such");

  // Recovery clears the diagnostic instead of leaving a stale error behind.
  const recovered = await mount({ listMode: "denied" });
  await recovered.tick(LIST_REFRESH_MS);
  assert.equal(recovered.read(SESSION_DIAGNOSTICS_KEY).list.kind, "permission");
  recovered.setListMode("ok");
  await recovered.tick(LIST_REFRESH_MS);
  assert.equal(recovered.read(SESSION_DIAGNOSTICS_KEY).list, null, "a later success clears the failure");
  assert.equal(recovered.read(SESSION_LIST_KEY).available, true);
});

test("a path-selected get failure is recorded with its selector, still without any path", async () => {
  const harness = await mount({ sessions: [], getMode: "denied" });
  // No sessionId on the event, so the lookup has to go by path.
  await emit(harness, { type: "agent_start" }, REAL_PATH);

  const diag = harness.read(SESSION_DIAGNOSTICS_KEY);
  assert.equal(diag.get.operation, "session:get");
  assert.ok(["path", "legacyPath"].includes(diag.get.selector), "a path-selected get is recorded as such");
  assert.equal(diag.get.eventHasSessionId, false, "the event carried no session id");
  assert.equal(diag.get.legacyPathTried, true, "the legacy selector was attempted as a fallback");
  // Only the enum/boolean allowlist; no id, path, message or body.
  for (const key of Object.keys(diag.get)) {
    assert.ok(["code", "kind", "operation", "selector", "pathMatch",
      "eventHasSessionId", "listHasPath", "pathResolvedFromList", "legacyPathTried"].includes(key),
    `unexpected diagnostic field ${key}`);
    assert.ok(["string", "boolean"].includes(typeof diag.get[key]), `${key} must be a scalar enum/boolean`);
  }

  // Still only enums: no message, no session id, no path, no body.
  const serialized = JSON.stringify(diag);
  for (const leak of [REAL_PATH, "/private", "session/", "denied by", "secret"]) {
    assert.equal(serialized.includes(leak), false, `diagnostics leak ${leak}`);
  }
  assert.equal(serialized.includes(REAL_ID), false, "no session id is stored in diagnostics");
});

test("the session list is asked for all lifecycles so old sessions keep their names", async () => {
  const harness = await mount();
  const call = harness.state.listCalls[harness.state.listCalls.length - 1];
  assert.equal(call.scope, "all");
  assert.equal(call.lifecycle, "all", "archived sessions are needed for naming, not just activity");
});

test("an archived session is named but cannot be pinned", async () => {
  const archivedId = "sess_old0_archived0001";
  const harness = await mount({
    sessions: [{
      sessionId: archivedId, title: "归档会话", agentId: "agent-a", agentName: "码农",
      path: "/private/session/old", lifecycle: "archived", archivedAt: "2026-01-01T00:00:00Z",
      cwd: "/private/cwd/old", firstMessage: "private first message",
    }],
  });

  const list = harness.read(SESSION_LIST_KEY);
  assert.equal(list.available, true);
  const entry = list.sessions.find((item) => item.sessionId === archivedId);
  assert.ok(entry, "the archived session is listed so its name is available");
  assert.equal(entry.lifecycle, "archived", "its lifecycle is preserved for the UI");
  assert.equal(entry.title, "归档会话");
  assert.ok(entry.displayTitle.length > 0, "it still resolves a display title");
  assert.deepEqual(Object.keys(entry).sort(),
    ["agentId", "agentName", "displayTitle", "lifecycle", "sessionId", "title"],
    "still only the metadata allowlist: no path, cwd or body");
  assertClean(list, "list containing an archived session");

  // Pinning it is refused; the follow stays on the default.
  await request(harness, archivedId);
  assert.equal(harness.read(FOLLOW_KEY).mode, "latest", "an archived session cannot be pinned");
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, null);
});

test("an active session can still be pinned while archived ones are listed", async () => {
  const activeId = "sess_new0_active00001";
  const harness = await mount({
    sessions: [
      { sessionId: activeId, title: "活跃会话", agentName: "码农", path: "/private/session/new", lifecycle: "active" },
      { sessionId: "sess_old0_archived0001", title: "归档会话", agentName: "码农",
        path: "/private/session/old", lifecycle: "archived" },
    ],
  });
  await emit(harness, { type: "agent_start", sessionId: activeId }, "/private/session/new");
  await request(harness, activeId);

  assert.equal(harness.read(FOLLOW_KEY).mode, "pinned");
  assert.equal(harness.read(FOLLOW_KEY).pinnedSessionId, activeId);
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, activeId);
});

test("the list's own `path` is enough: no session:get is needed to attribute activity", async () => {
  // get is completely refused; only the list can resolve identities.
  const harness = await mount({
    sessions: [{
      sessionId: REAL_ID, title: "接手会话工作", agentId: "agent-hanako", agentName: "哦鲸鲸",
      path: REAL_PATH, lifecycle: "active", cwd: "/private/cwd", firstMessage: "private first message",
    }],
    getMode: "denied",
  });
  const getsBefore = harness.state.getCalls.length;
  await emit(harness, { type: "agent_start" }, REAL_PATH);
  await emit(harness, { type: "tool_execution_start", toolName: "exec_command" }, REAL_PATH);

  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, REAL_ID, "the list's path -> id mapping resolved it");
  assert.equal(snapshot.sessions.length, 1, "no placeholder row was created");
  assert.equal(snapshot.sessions[0].unresolved, false);
  assert.equal(snapshot.current.title, "接手会话工作");
  assert.equal(harness.state.getCalls.length, getsBefore, "no path-based session:get was attempted");
  assertClean(harness.store, "store resolved from the list alone");
});

test("a large archive never evicts the active sessions' path mappings", async () => {
  const activeId = "sess_active_keep0001";
  const activePath = "/private/session/keep-active.jsonl";
  const archived = Array.from({ length: 400 }, (_, index) => ({
    sessionId: `sess_arch${String(index).padStart(4, "0")}`,
    title: `归档 ${index}`,
    path: `/private/session/archive-${index}.jsonl`,
    lifecycle: "archived",
  }));
  // The active session is FIRST, and the archive is inserted after it -- exactly the
  // shape that used to evict the live mapping under a 64-entry LRU.
  const harness = await mount({
    sessions: [{ sessionId: activeId, title: "活跃会话", path: activePath, lifecycle: "active" }, ...archived],
  });
  await harness.tick(LIST_REFRESH_MS);

  await emit(harness, { type: "agent_start" }, activePath);
  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, activeId, "the active session kept its mapping");
  assert.equal(snapshot.current.title, "活跃会话");
  assert.equal(snapshot.sessions.some((item) => item.sessionId.startsWith("unresolved:")), false,
    "no placeholder was needed");
});

test("a path that differs only by prefix still resolves by basename", async () => {
  const id = "sess_base_0001";
  const harness = await mount({
    sessions: [{ sessionId: id, title: "同名文件", path: "/private/session/agentA/2026-01-01_x.jsonl", lifecycle: "active" }],
    getMode: "denied",
  });
  // The bus callback reports a differently-rooted path for the same file.
  await emit(harness, { type: "agent_start" }, "/other/root/2026-01-01_x.jsonl");

  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, id, "the basename fallback resolved it");
  assert.equal(snapshot.sessions.some((item) => item.sessionId.startsWith("unresolved:")), false);
});

test("when every source fails the activity stays clearly unidentified and never steals current", async () => {
  const harness = await mount({ sessions: [], listMode: "denied", getMode: "denied" });
  // A real session is active; the unresolved path must not outrank it.
  await emit(harness, { type: "agent_start", sessionId: "sess_known0001", title: "已知会话" }, null);
  await emit(harness, { type: "agent_start" }, REAL_PATH);

  const snapshot = harness.read(SNAPSHOT_KEY);
  const placeholder = snapshot.sessions.find((item) => item.sessionId.startsWith("unresolved:"));
  assert.ok(placeholder, "the activity is kept, not dropped");
  assert.equal(placeholder.unresolved, true);
  assert.equal(placeholder.displayTitle.startsWith("未识别会话"), true,
    "it is labelled as unidentified rather than posing as a session");
  assert.equal(snapshot.current.sessionId, "sess_known0001",
    "an identifiable active session keeps `current`");

  // Diagnostics say what happened, as enums and booleans only.
  const diag = harness.read(SESSION_DIAGNOSTICS_KEY);
  assert.equal(diag.get.eventHasSessionId, false, "the event carried no session id");
  assert.equal(diag.get.listHasPath, false, "no list mapping was available");
  assert.equal(diag.get.pathResolvedFromList, false);
  assert.ok(["path", "legacyPath"].includes(diag.get.selector));
  assert.equal(diag.get.legacyPathTried, true, "the legacy selector fallback was attempted");
  for (const key of Object.keys(diag.get)) {
    assert.ok(["code", "kind", "operation", "selector", "pathMatch",
      "eventHasSessionId", "listHasPath", "pathResolvedFromList", "legacyPathTried"].includes(key),
    `unexpected field ${key}`);
  }
  const serialized = JSON.stringify(diag);
  for (const leak of [REAL_PATH, "/private", ".jsonl", "secret"]) {
    assert.equal(serialized.includes(leak), false, `diagnostics leak ${leak}`);
  }
  assertClean(harness.store, "store with an unresolved row");
});

test("the legacySessionPath selector resolves a session when sessionPath fails", async () => {
  const id = "sess_legacy0001";
  const harness = await mount({ sessions: [], listMode: "denied" });
  // sessionPath throws, legacySessionPath answers.
  harness.state.legacyOnlyPath = REAL_PATH;
  harness.setLegacyId(id);
  await emit(harness, { type: "agent_start" }, REAL_PATH);

  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, id, "the legacy selector resolved the session");
  assert.equal(snapshot.sessions.some((item) => item.sessionId.startsWith("unresolved:")), false);
  assert.equal(harness.read(SESSION_DIAGNOSTICS_KEY).get, null, "a success clears the diagnostic");
});
