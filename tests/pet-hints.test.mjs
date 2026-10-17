/**
 * Host-driven presentation hints: confirming / compacting / interrupted.
 *
 * These three event families carry the most sensitive payloads in the whole bus
 * (prompt bodies, tool arguments, user input, dropped interjection text), so every
 * test here also asserts that nothing but `event.type` and the session attribution
 * survives into storage or the pet protocol.
 */
import test from "node:test";
import assert from "node:assert/strict";
import { createHarness } from "./synthetic-host.mjs";
import app from "../apps/hana-desktop-pet/index.js";
import {
  HINT_TTL_MS,
  PET_HINTS,
} from "../apps/hana-desktop-pet/state-core.mjs";
import { toPetSnapshot } from "../apps/hana-desktop-pet/pet-bridge.mjs";
import {
  PET_SCHEMA_VERSION,
  PET_PROTOCOL_VERSION,
  SNAPSHOT_KEY,
  FOLLOW_KEY,
  SESSION_LIST_KEY,
} from "../apps/hana-desktop-pet/pet-bridge.mjs";

const LIST_REFRESH_MS = 5000;
const BRIDGE_POLL_MS = 1500;
const BRIDGE_ENABLED_KEY = "hana-pet.bridge.enabled";

const SEEN = "sess_seen_0001";
const OTHER = "sess_other_0002";
const SEEN_PATH = "/private/session/seen.jsonl";
const OTHER_PATH = "/private/session/other.jsonl";

/**
 * Every payload field that the contract says must never be read. The values are
 * unique sentinels so a leak is unambiguous.
 */
const SECRETS = {
  body: "SECRET-prospective-body",
  title: "SECRET-confirmation-title",
  detail: "SECRET-subject-detail",
  payload: "SECRET-tool-argument-payload",
  value: "SECRET-user-typed-value",
  result: "SECRET-compaction-result",
  errorMessage: "SECRET-compaction-error",
  displayText: "SECRET-dropped-interjection-text",
};

/** A payload shaped like the real events, carrying every sensitive field. */
function sensitivePayload() {
  return {
    body: SECRETS.body,
    title: SECRETS.title,
    subject: { detail: SECRETS.detail, kind: "tool" },
    payload: { args: SECRETS.payload, token: SECRETS.payload },
    value: SECRETS.value,
    result: { summary: SECRETS.result },
    errorMessage: SECRETS.errorMessage,
    interjections: [{ displayText: SECRETS.displayText, id: "i1" }],
    message: SECRETS.body,
    sessionPath: SEEN_PATH,
  };
}

function assertNoSecret(value, label) {
  const serialized = JSON.stringify(value);
  for (const [name, secret] of Object.entries(SECRETS)) {
    assert.equal(serialized.includes(secret), false, `${label} leaks ${name}`);
  }
}

function entries() {
  return [
    { sessionId: SEEN, title: "被跟随", agentId: "agent-a", agentName: "码农", path: SEEN_PATH, lifecycle: "active" },
    { sessionId: OTHER, title: "别的会话", agentId: "agent-b", agentName: "执笔", path: OTHER_PATH, lifecycle: "active" },
  ];
}

async function mount(options = {}) {
  const harness = createHarness({ sessions: entries(), ...options });
  harness.installTimers();
  try {
    await app.apply(harness.sdk);
  } catch (error) {
    harness.restoreTimers();
    throw error;
  }
  for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
  return harness;
}

async function emit(harness, event, sessionPath) {
  const subscription = harness.state.subscriptions[0];
  assert.ok(subscription, "the App subscribed to the bus");
  await harness.tick(1);
  await subscription.callback(event, sessionPath);
  for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function pin(harness, sessionId) {
  await harness.write("hana-pet.follow.request", { requestId: `r-${sessionId}`, pinnedSessionId: sessionId });
  for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
}

function hintOf(harness, sessionId) {
  const snapshot = harness.read(SNAPSHOT_KEY);
  const row = (snapshot?.sessions ?? []).find((item) => item.sessionId === sessionId);
  return row ? row.hint : undefined;
}

/**
 * The hint as the pet sees it. Expiry is evaluated lazily at projection time rather
 * than written back, so the stored value is not the effective one.
 */
function currentHint(harness) {
  return toPetSnapshot(harness.read(SNAPSHOT_KEY), harness.now()).activity.hint;
}

test("the wire contract is version 3 with exactly one new optional field", () => {
  assert.equal(PET_SCHEMA_VERSION, 3);
  assert.equal(PET_PROTOCOL_VERSION, 3);
  assert.deepEqual([...PET_HINTS], ["confirming", "compacting", "interrupted"],
    "the frozen hint enum must not drift from the native side");
});

test("a confirmation raises `confirming` on the followed session only", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);

  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), "confirming");
  assert.equal(currentHint(harness), "confirming", "the followed session shows the hint");

  // Another session asking for confirmation must not steal the presentation.
  await emit(harness, { type: "agent_start", sessionId: OTHER }, OTHER_PATH);
  await emit(harness, { type: "session_confirmation", sessionId: OTHER, ...sensitivePayload() }, OTHER_PATH);
  assert.equal(hintOf(harness, OTHER), "confirming", "the other row records its own hint");
  assert.equal(currentHint(harness), "confirming");
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, SEEN, "the pin still owns the pet");

  // Clear the current session's own confirmation before unpinning. While it is
  // confirming it must not be preempted, even by another confirming session.
  await emit(harness, { type: "confirmation_resolved", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), null);

  // With no pin the confirming challenger takes over immediately.
  await pin(harness, null);
  assert.equal(harness.read(SNAPSHOT_KEY).current.sessionId, OTHER);
  assert.equal(currentHint(harness), "confirming", "the followed session decides the hint");

  assertNoSecret(harness.store, "store after confirmations");
});

test("`confirmation_resolved` clears `confirming`", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);
  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), "confirming");

  await emit(harness, { type: "confirmation_resolved", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), null, "the resolution clears the hint");
  assert.equal(currentHint(harness), null);
  assertNoSecret(harness.store, "store after resolution");
});

test("an unattributed confirmation_resolved clears the hint without inventing a session", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);
  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), "confirming");

  const before = harness.read(SNAPSHOT_KEY).sessions.length;
  // A terminal proposal reports sessionId: null and no usable path.
  await emit(harness, { type: "confirmation_resolved", sessionId: null, ...sensitivePayload() }, null);

  assert.equal(hintOf(harness, SEEN), null, "the stale prompt is cleared");
  const after = harness.read(SNAPSHOT_KEY);
  assert.equal(after.sessions.length, before, "no session row was invented");
  assert.equal(after.sessions.some((item) => item.sessionId.startsWith("unresolved:")), false,
    "no placeholder row was created for it");
  assertNoSecret(harness.store, "store after unattributed resolution");
});

test("`compaction_start` raises `compacting` and `compaction_end` clears it", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);

  await emit(harness, { type: "compaction_start", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), "compacting");
  assert.equal(currentHint(harness), "compacting");

  await emit(harness, { type: "compaction_end", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), null);
  assert.equal(currentHint(harness), null);
  assertNoSecret(harness.store, "store after compaction");
});

test("`interjection_dropped` raises a short `interrupted` hint", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);

  await emit(harness, { type: "interjection_dropped", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), "interrupted");
  assert.equal(currentHint(harness), "interrupted");
  assert.ok(HINT_TTL_MS.interrupted <= 5000, "the interrupted hint is short-lived");

  // It expires on its own without any clear event.
  await harness.tick(HINT_TTL_MS.interrupted);
  assert.equal(currentHint(harness), null, "the hint expires");
  assertNoSecret(harness.store, "store after interjection");
});

test("`confirming` and `compacting` expire so a missed clear cannot stick", async () => {
  for (const [raiseType, hint] of [["session_confirmation", "confirming"], ["compaction_start", "compacting"]]) {
    const harness = await mount();
    await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
    await pin(harness, SEEN);
    await emit(harness, { type: raiseType, sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
    assert.equal(currentHint(harness), hint, `${hint} is showing`);

    // Just inside the TTL it still shows.
    await harness.tick(HINT_TTL_MS[hint] - 1);
    assert.equal(currentHint(harness), hint, `${hint} is still fresh`);

    // Past the TTL it is gone even though the clear event never arrived.
    await harness.tick(2);
    assert.equal(currentHint(harness), null, `${hint} expired`);
  }
});

test("hint events never disturb the existing activity state machine", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);
  const before = harness.read(SNAPSHOT_KEY).current;
  assert.equal(before.status, "working");

  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  const during = harness.read(SNAPSHOT_KEY).current;
  assert.equal(during.status, before.status, "status is untouched by a hint");
  assert.equal(during.running, before.running);
  assert.equal(during.toolName, before.toolName);
  assert.equal(during.hint, "confirming");

  // A tool event still updates the tool state normally while a hint is showing.
  await emit(harness, { type: "tool_execution_start", sessionId: SEEN, toolName: "read" }, SEEN_PATH);
  const afterTool = harness.read(SNAPSHOT_KEY).current;
  assert.equal(afterTool.toolName, "read");
  assert.equal(afterTool.hint, "confirming", "the hint survives unrelated activity");
});

test("a close or a restart clears the hint instead of reviving it", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);
  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), "confirming");

  // A closed session cannot still be waiting on the user.
  await emit(harness, { type: "session_closed", sessionId: SEEN }, SEEN_PATH);
  assert.equal(hintOf(harness, SEEN), null);

  // A restart drops any hint that was still persisted.
  const seeded = await mount({
    seed: {
      [SNAPSHOT_KEY]: {
        schemaVersion: 1, observedAt: 1, revision: 9,
        sessions: [
          { sessionId: SEEN, title: "被跟随", status: "working", running: true,
            toolName: "read", hint: "confirming", hintAt: 1, lastActivityAt: 5, statusAt: 5 },
          { sessionId: OTHER, title: "别的", status: "idle", hint: "compacting", hintAt: 2,
            lastActivityAt: 4, statusAt: 4 },
        ],
        current: null,
      },
    },
  });
  const restored = seeded.read(SNAPSHOT_KEY);
  for (const row of restored.sessions) {
    assert.equal(row.hint, null, `${row.sessionId} lost its stale hint`);
    assert.equal(row.hintAt, 0);
  }
  assert.equal(restored.current?.hint ?? null, null);
});

test("an unattributable hint event is dropped rather than parked on a placeholder", async () => {
  // No list, no get: nothing can say which session this path belongs to.
  const harness = await mount({ sessions: [], listMode: "denied", getMode: "denied" });
  await emit(harness, { type: "session_confirmation", ...sensitivePayload() }, "/private/session/unknown.jsonl");

  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.sessions.length, 0, "no placeholder row was created for a hint");
  assert.equal(snapshot.current, null);
  assertNoSecret(harness.store, "store after unattributable hint");
});

test("the hint reaches the pet DTO and nowhere else", async () => {
  const harness = await mount({ seed: { [BRIDGE_ENABLED_KEY]: true } });
  await emit(harness, { type: "agent_start", sessionId: SEEN }, SEEN_PATH);
  await pin(harness, SEEN);
  await harness.tick(BRIDGE_POLL_MS * 2);

  const beforeCount = harness.state.published.length;
  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  await harness.tick(BRIDGE_POLL_MS * 2);

  assert.ok(harness.state.published.length > beforeCount, "a snapshot was published after the hint");
  const latest = harness.state.published[harness.state.published.length - 1];
  assert.deepEqual(Object.keys(latest).sort(), ["activity", "characters", "revision", "schemaVersion"]);
  assert.deepEqual(Object.keys(latest.activity).sort(),
    ["agentId", "agentName", "hint", "lastActivityAt", "sessionId", "status", "title", "toolName"],
    "exactly one field was added, and only that one");
  assert.equal(latest.schemaVersion, 3);
  assert.equal(latest.activity.hint, "confirming");
  assert.equal(latest.activity.sessionId, SEEN);
  assertNoSecret(latest, "published dto");

  // Clearing reaches the wire as null, not as a missing key.
  await emit(harness, { type: "confirmation_resolved", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);
  await harness.tick(BRIDGE_POLL_MS * 2);
  const cleared = harness.state.published[harness.state.published.length - 1];
  assert.equal("hint" in cleared.activity, true, "the key is always present");
  assert.equal(cleared.activity.hint, null, "and null when there is no hint");
});

test("hint values are restricted to the frozen enum even if storage is tampered with", async () => {
  const harness = await mount({
    seed: {
      [SNAPSHOT_KEY]: {
        schemaVersion: 1, observedAt: 1, revision: 3,
        sessions: [
          { sessionId: SEEN, title: "被跟随", status: "idle", hint: "not-a-real-hint", hintAt: 5,
            lastActivityAt: 9, statusAt: 0 },
        ],
        current: null,
      },
    },
  });
  const row = harness.read(SNAPSHOT_KEY).sessions[0];
  assert.equal(row.hint, null, "an unknown hint value is discarded on load");
});

test("the existing follow and list behaviour is unchanged by the new subscriptions", async () => {
  const harness = await mount();
  await emit(harness, { type: "agent_start", sessionId: OTHER }, OTHER_PATH);
  await emit(harness, { type: "session_confirmation", sessionId: SEEN, ...sensitivePayload() }, SEEN_PATH);

  // No pin: the most recently active real session leads, not the hint's owner.
  const snapshot = harness.read(SNAPSHOT_KEY);
  assert.equal(snapshot.current.sessionId, OTHER, "a hint does not hijack the current session");
  assert.equal(harness.read(FOLLOW_KEY).mode, "latest");
  assert.equal(harness.read(SESSION_LIST_KEY).available, true);
  assertNoSecret(harness.store, "store after mixed activity");
});
