import test from "node:test";
import assert from "node:assert/strict";
import {
  applyEvent,
  applyHintEvent,
  createFollow,
  createSnapshot,
  HINT_TTL_MS,
  displayTitleFor,
  effectiveHint,
  effectiveStatus,
  FOLLOW_NOTICE_TTL_MS,
  FOLLOW_SWITCH_MARGIN_MS,
  FOLLOW_ACTIVE_WINDOW_MS,
  isPinnableSessionId,
  isPinnableEntry,
  pickableSessionList,
  isPlaceholderSessionId,
  isUnresolvedSessionId,
  mergeSnapshot,
  normalizeFollow,
  PET_HINTS,
  PIN_MISSING_GRACE_MS,
  projectSessionList,
  rebuildSnapshot,
  recoverSnapshot,
  resolveFollow,
  unresolvedKeyFor,
} from "../apps/hana-desktop-pet/state-core.mjs";

const identity = (sessionId, extra = {}) => ({
  sessionId,
  title: "代码联调",
  agentId: "agent-coder",
  agentName: "码农",
  ...extra,
});

test("tool lifecycle yields working, success/error, then idle without storing result bodies", () => {
  let state = createSnapshot();
  state = applyEvent(state, identity("session-abcdef12"), { type: "agent_start" }, 1000);
  assert.equal(state.current.status, "working");
  assert.equal(effectiveStatus(state.current, 1000), "working");

  state = applyEvent(state, identity("session-abcdef12"), {
    type: "tool_execution_start", toolName: "file.read", args: { secret: "do-not-copy" },
    message: { content: "private-message" }, sessionPath: "/private/session/path",
  }, 1010);
  assert.equal(state.current.toolName, "file.read");

  state = applyEvent(state, identity("session-abcdef12"), {
    type: "tool_execution_end", isError: false,
    result: { content: "private-result" },
  }, 1020);
  assert.equal(state.current.running, true, "a tool result is feedback, not agent completion");
  assert.equal(state.current.toolName, null, "a completed tool must not remain the active tool");
  assert.equal(effectiveStatus(state.current, 1020), "success", "feedback overlays the active work state");
  state = applyEvent(state, identity("session-abcdef12"), { type: "turn_start" }, 1100);
  assert.equal(effectiveStatus(state.current, 1100), "success", "a synchronous next turn must not erase feedback");
  assert.equal(effectiveStatus(state.current, 3521), "working", "feedback expires back to the actual active state");
  state = applyEvent(state, identity("session-abcdef12"), { type: "agent_end" }, 3600);
  assert.equal(effectiveStatus(state.current, 3600), "success");
  assert.equal(effectiveStatus(state.current, 6101), "idle");
  const serialized = JSON.stringify(state);
  assert.equal(serialized.includes("do-not-copy"), false);
  assert.equal(serialized.includes("private-result"), false);
  assert.equal(serialized.includes("secret"), false);
  assert.equal(serialized.includes("private-message"), false);
  assert.equal(serialized.includes("/private/session/path"), false);
});

test("a sufficiently newer idle challenger selects current; titles with collisions are disambiguated", () => {
  let state = createSnapshot();
  state = applyEvent(state, identity("session-older001"), { type: "turn_start" }, 2000);
  state = applyEvent(state, identity("session-older001"), { type: "agent_end" }, 2001);
  state = applyEvent(state, identity("session-newer002"), { type: "tool_execution_start", toolName: "search" }, 5001);
  assert.equal(state.current.sessionId, "session-newer002");
  assert.equal(state.current.displayTitle, "代码联调 · 码农 · newer002");
});

test("alternating activity between two idle sessions does not cause ping-pong", () => {
  assert.equal(FOLLOW_SWITCH_MARGIN_MS, 2000);
  assert.equal(FOLLOW_ACTIVE_WINDOW_MS, 30000);

  let state = createSnapshot();
  state = applyEvent(state, identity("session-ping-a"), { type: "agent_start" }, 100000);
  state = applyEvent(state, identity("session-ping-a"), { type: "agent_end" }, 100001);
  let at = 101000;
  let priorId = state.current.sessionId;
  let switches = 0;

  for (let index = 0; index < 10; index += 1) {
    const sessionId = index % 2 === 0 ? "session-ping-b" : "session-ping-a";
    state = applyEvent(state, identity(sessionId), { type: "agent_start" }, at);
    if (state.current.sessionId !== priorId) switches += 1;
    priorId = state.current.sessionId;
    at += 1;
    state = applyEvent(state, identity(sessionId), { type: "agent_end" }, at);
    if (state.current.sessionId !== priorId) switches += 1;
    priorId = state.current.sessionId;
    at += 100;
  }

  assert.ok(switches <= 5, `ten alternating turns switched current ${switches} times`);
  assert.equal(state.current.sessionId, "session-ping-a");
});

test("recent work on current resists a more active session", () => {
  let state = applyEvent(createSnapshot(), identity("session-working-a"), { type: "agent_start" }, 200000);
  state = applyEvent(state, identity("session-working-b"), { type: "agent_start" }, 204000);
  assert.equal(state.current.sessionId, "session-working-a",
    "the incumbent is still working and its last activity is inside the 30-second window");

  let toolState = applyEvent(createSnapshot(), identity("session-tool-a"), {
    type: "tool_execution_start", toolName: "file.read",
  }, 205000);
  toolState = applyEvent(toolState, identity("session-tool-b"), { type: "agent_start" }, 209000);
  assert.equal(toolState.current.sessionId, "session-tool-a", "an active tool is protected too");
  assert.equal(toolState.current.toolName, "file.read");
});

test("without a follow-intent change, an idle current requires the full activity margin", () => {
  const idleCurrent = () => {
    let state = applyEvent(createSnapshot(), identity("session-idle-a"), { type: "agent_start" }, 300000);
    return applyEvent(state, identity("session-idle-a"), { type: "agent_end" }, 300001);
  };

  let oneSecond = idleCurrent();
  oneSecond = applyEvent(oneSecond, identity("session-idle-b"), { type: "agent_start" }, 301002);
  assert.equal(oneSecond.current.sessionId, "session-idle-a", "a 1-second lead is below the 2-second margin");

  let threeSeconds = idleCurrent();
  threeSeconds = applyEvent(threeSeconds, identity("session-idle-b"), { type: "agent_start" }, 303002);
  assert.equal(threeSeconds.current.sessionId, "session-idle-b", "a 3-second lead clears the margin");
});

test("a one-shot hysteresis bypass does not affect subsequent ordinary events", () => {
  let state = applyEvent(createSnapshot(), identity("session-bypass-a"), { type: "agent_start" }, 1000000);
  state = applyEvent(state, identity("session-bypass-a"), { type: "agent_end" }, 1000001);
  const pin = { mode: "pinned", pinnedSessionId: "session-bypass-a" };
  state = rebuildSnapshot(state, pin, 1000002);
  state = applyEvent(state, identity("session-bypass-b"), { type: "agent_start" }, 1001002, pin);
  state = applyEvent(state, identity("session-bypass-b"), { type: "agent_end" }, 1001003, pin);
  assert.equal(state.current.sessionId, "session-bypass-a", "pin keeps current before the follow change");

  state = rebuildSnapshot(state, createFollow(), 1001003, { bypassHysteresis: true });
  assert.equal(state.current.sessionId, "session-bypass-b", "unpin bypasses the 2-second margin once");

  state = applyEvent(state, identity("session-bypass-a"), { type: "agent_start" }, 1002004);
  assert.equal(state.current.sessionId, "session-bypass-b",
    "the next normal event still applies hysteresis to the 1-second challenger");
});

test("a confirming challenger takes over immediately despite active-work protection", () => {
  let state = applyEvent(createSnapshot(), identity("session-confirm-current"), { type: "agent_start" }, 400000);
  state = applyEvent(state, identity("session-confirm-challenger"), { type: "agent_start" }, 400100);
  assert.equal(state.current.sessionId, "session-confirm-current", "active work initially keeps current");
  state = applyEvent(state, identity("session-confirm-challenger"), { type: "session_confirmation" }, 400101);
  assert.equal(state.current.sessionId, "session-confirm-challenger");
  assert.equal(state.current.hint, "confirming");
});

test("a current session awaiting confirmation cannot be preempted", () => {
  let state = applyEvent(createSnapshot(), identity("session-confirm-current"), { type: "agent_start" }, 500000);
  state = applyEvent(state, identity("session-confirm-current"), { type: "session_confirmation" }, 500001);
  state = applyEvent(state, identity("session-confirm-challenger"), { type: "agent_start" }, 510002);
  assert.equal(state.current.sessionId, "session-confirm-current");
  assert.equal(state.current.hint, "confirming");

  state = rebuildSnapshot(state, createFollow(), 510003, { bypassHysteresis: true });
  assert.equal(state.current.sessionId, "session-confirm-current",
    "a follow-intent bypass does not hide an outstanding current confirmation");
});

test("a pin prevents every event from switching current", () => {
  let state = applyEvent(createSnapshot(), identity("session-pinned-a"), { type: "agent_start" }, 600000);
  state = applyEvent(state, identity("session-pinned-a"), { type: "agent_end" }, 600001);
  state = applyEvent(state, identity("session-pinned-b"), { type: "agent_start" }, 603002);
  state = applyEvent(state, identity("session-pinned-b"), { type: "agent_end" }, 603003);

  const follow = { mode: "pinned", pinnedSessionId: "session-pinned-a" };
  state = rebuildSnapshot(state, follow, 603004);
  assert.equal(state.current.sessionId, follow.pinnedSessionId);
  let previousId = state.current.sessionId;
  let switches = 0;
  let at = 604000;
  for (let index = 0; index < 10; index += 1) {
    const sessionId = index % 2 === 0 ? "session-pinned-b" : "session-pinned-a";
    state = applyEvent(state, identity(sessionId), { type: "agent_start" }, at, follow);
    if (state.current.sessionId !== previousId) switches += 1;
    previousId = state.current.sessionId;
    at += 1;
    state = applyEvent(state, identity(sessionId), { type: "agent_end" }, at, follow);
    if (state.current.sessionId !== previousId) switches += 1;
    previousId = state.current.sessionId;
    at += 100;
  }
  assert.equal(switches, 0);
});

test("a pin missing past its grace period releases to the latest session", () => {
  let state = applyEvent(createSnapshot(), identity("session-fallback-a"), { type: "agent_start" }, 700000);
  state = applyEvent(state, identity("session-fallback-a"), { type: "agent_end" }, 700001);
  state = applyEvent(state, identity("session-fallback-b"), { type: "agent_start" }, 703002);
  state = applyEvent(state, identity("session-fallback-b"), { type: "agent_end" }, 703003);
  assert.equal(state.current.sessionId, "session-fallback-b");

  const missing = resolveFollow({ mode: "pinned", pinnedSessionId: "session-missing-pin" }, {
    sessions: state.sessions, listEntries: [], listAvailable: true, now: 704000,
  });
  assert.equal(missing.follow.mode, "pinned");
  let held = rebuildSnapshot(state, missing.follow, 704000);
  assert.equal(held.current.sessionId, "session-fallback-b", "an absent pin does not blank current during grace");

  const expired = resolveFollow(missing.follow, {
    sessions: held.sessions, listEntries: [], listAvailable: true,
    now: 704000 + PIN_MISSING_GRACE_MS,
  });
  assert.equal(expired.follow.mode, "latest");
  assert.equal(expired.follow.released.reason, "pinned_missing");
  held = rebuildSnapshot(held, expired.follow, 704000 + PIN_MISSING_GRACE_MS);
  assert.equal(held.current.sessionId, "session-fallback-b", "the released pin falls back to latest activity");
});

test("empty titles fall back to a stable session-id suffix", () => {
  const session = { sessionId: "session-01ABCDEF", title: "  ", agentName: null };
  assert.equal(displayTitleFor(session), "会话 · 01ABCDEF");
});

test("tool errors map only the isError flag and do not persist error details", () => {
  let state = createSnapshot();
  state = applyEvent(state, identity("session-error001"), { type: "tool_execution_start", toolName: "file.write" }, 2500);
  state = applyEvent(state, identity("session-error001"), {
    type: "tool_execution_end", isError: true,
    result: { message: "private stack trace" },
  }, 2501);
  state = applyEvent(state, identity("session-error001"), { type: "agent_end" }, 2502);
  assert.equal(effectiveStatus(state.current, 2502), "error");
  assert.equal(JSON.stringify(state).includes("private stack trace"), false);
});

test("metadata-only title updates and session close never add role selection to activity state", () => {
  let state = createSnapshot();
  state = applyEvent(state, identity("session-abcdef12"), { type: "turn_start" }, 3000);
  state = applyEvent(state, identity("session-abcdef12"), {
    type: "session_metadata_updated", metadata: { title: "新标题", prompt: "private text" },
  }, 3001);
  assert.equal(state.current.title, "新标题");
  assert.equal(state.selectedCharacterId, undefined);

  state = applyEvent(state, identity("session-abcdef12"), { type: "session_closed" }, 3002);
  assert.equal(state.current.status, "idle");
  assert.equal(state.selectedCharacterId, undefined);
  assert.equal(JSON.stringify(state).includes("private text"), false);
});

test("unlisted event types are ignored and never become snapshot fields", () => {
  const initial = createSnapshot();
  const next = applyEvent(initial, identity("session-abcdef12"), {
    type: "message_update", message: { text: "sensitive" },
  }, 4000);
  assert.equal(next, initial);
});

test("same-millisecond or backwards wall-clock readings still use callback receive order", () => {
  let state = createSnapshot();
  state = applyEvent(state, identity("session-abcdef12"), { type: "tool_execution_end", toolName: "a", isError: false }, 5000);
  state = applyEvent(state, identity("session-abcdef12"), { type: "tool_execution_start", toolName: "b" }, 4990);
  assert.equal(state.current.toolName, "b");
  assert.equal(state.current.status, "working");
  assert.ok(state.observedAt > 5000);
});

test("retries remain active and an auto-retry end is not mistaken for whole-agent completion", () => {
  let state = applyEvent(createSnapshot(), identity("session-retry001"), { type: "agent_start" }, 7000);
  state = applyEvent(state, identity("session-retry001"), {
    type: "agent_end", willRetry: true, messages: [{ content: "must-not-be-read" }],
  }, 7010);
  assert.equal(state.current.running, true);
  assert.equal(effectiveStatus(state.current, 7010), "working");
  assert.equal(state.current.runEnded, false);

  state = applyEvent(state, identity("session-retry001"), { type: "auto_retry_start" }, 7020);
  state = applyEvent(state, identity("session-retry001"), { type: "auto_retry_end" }, 7030);
  assert.equal(state.current.running, true);
  assert.equal(effectiveStatus(state.current, 7030), "working");
  assert.equal(state.current.status, "working", "retry-end alone carries no success/failure result");

  state = applyEvent(state, identity("session-retry001"), { type: "agent_end", willRetry: false }, 7040);
  assert.equal(state.current.running, false);
  assert.equal(effectiveStatus(state.current, 7040), "success", "agent_end marks lifecycle end, not user-goal satisfaction");
  assert.equal(effectiveStatus(state.current, 9541), "idle");
});

test("continuous tools replace the active tool and tool starts interrupt older feedback", () => {
  let state = applyEvent(createSnapshot(), identity("session-tools001"), { type: "agent_start" }, 8000);
  state = applyEvent(state, identity("session-tools001"), {
    type: "tool_execution_start", toolName: "file.read",
  }, 8010);
  state = applyEvent(state, identity("session-tools001"), {
    type: "tool_execution_end", isError: false,
  }, 8020);
  assert.equal(state.current.toolName, null);
  assert.equal(effectiveStatus(state.current, 8020), "success");

  state = applyEvent(state, identity("session-tools001"), {
    type: "tool_execution_start", toolName: "file.write",
  }, 8030);
  assert.equal(state.current.toolName, "file.write");
  assert.equal(effectiveStatus(state.current, 8030), "working");
  state = applyEvent(state, identity("session-tools001"), {
    type: "tool_execution_end", isError: true,
  }, 8040);
  assert.equal(state.current.toolName, null);
  assert.equal(effectiveStatus(state.current, 8040), "error");
  assert.equal(effectiveStatus(state.current, 10541), "working");
});

test("tool error feedback is brief, survives immediate work resumption, then yields to the final lifecycle state", () => {
  let state = applyEvent(createSnapshot(), identity("session-recover001"), { type: "agent_start" }, 9000);
  state = applyEvent(state, identity("session-recover001"), {
    type: "tool_execution_start", toolName: "file.read",
  }, 9010);
  state = applyEvent(state, identity("session-recover001"), {
    type: "tool_execution_end", isError: true,
    result: { error: "private error body" },
  }, 9020);
  assert.equal(effectiveStatus(state.current, 9020), "error");
  assert.equal(state.current.running, true);
  state = applyEvent(state, identity("session-recover001"), { type: "turn_start" }, 9030);
  assert.equal(effectiveStatus(state.current, 9030), "error");
  assert.equal(effectiveStatus(state.current, 11521), "working");
  state = applyEvent(state, identity("session-recover001"), { type: "agent_end" }, 12000);
  assert.equal(effectiveStatus(state.current, 12000), "success");
  assert.equal(state.current.running, false);
  assert.equal(JSON.stringify(state).includes("private error body"), false);
});

test("out-of-order and missing tool events stay conservative; terminal runs cannot be revived", () => {
  let state = createSnapshot();
  state = applyEvent(state, identity("session-order001"), {
    type: "tool_execution_end", isError: false,
  }, 13000);
  assert.equal(state.current.running, false, "a result without a known start does not imply active work");
  assert.equal(effectiveStatus(state.current, 13000), "success");

  state = applyEvent(state, identity("session-order001"), { type: "agent_start" }, 13020);
  state = applyEvent(state, identity("session-order001"), {
    type: "tool_execution_start", toolName: "older.tool",
  }, 13030);
  state = applyEvent(state, identity("session-order001"), {
    type: "tool_execution_start", toolName: "current.tool",
  }, 13040);
  assert.equal(state.current.toolName, "current.tool");
  state = applyEvent(state, identity("session-order001"), {
    type: "tool_execution_end", isError: false,
  }, 13050);
  assert.equal(state.current.toolName, null, "without a public correlation key, do not retain a possibly stale tool name");
  assert.equal(state.current.running, true);
  assert.equal(effectiveStatus(state.current, 13050), "success");
  assert.equal(effectiveStatus(state.current, 15551), "working");

  state = applyEvent(state, identity("session-order001"), { type: "agent_end" }, 13060);
  const afterAgentEnd = state;
  state = applyEvent(state, identity("session-order001"), {
    type: "tool_execution_end", isError: true,
  }, 13070);
  assert.equal(state, afterAgentEnd, "late tool results after terminal agent_end are ignored");
  state = applyEvent(state, identity("session-order001"), {
    type: "tool_execution_start", toolName: "late.tool",
  }, 13080);
  assert.equal(state, afterAgentEnd, "a tool event alone cannot revive a known-ended run");
  assert.equal(effectiveStatus(state.current, 15561), "idle");
});

test("missing outcome flags never fabricate success, and turn_end/auto_retry_end are not terminal evidence", () => {
  let state = applyEvent(createSnapshot(), identity("session-missing001"), { type: "turn_start" }, 14000);
  state = applyEvent(state, identity("session-missing001"), { type: "turn_end", aborted: true }, 14010);
  assert.equal(state.current.running, true);
  assert.equal(effectiveStatus(state.current, 14010), "working");
  state = applyEvent(state, identity("session-missing001"), {
    type: "tool_execution_start", toolName: "known.tool",
  }, 14020);
  state = applyEvent(state, identity("session-missing001"), {
    type: "tool_execution_end",
  }, 14030);
  assert.equal(state.current.toolName, null);
  assert.equal(state.current.status, "working");
  assert.equal(effectiveStatus(state.current, 14030), "working");
  state = applyEvent(state, identity("session-missing001"), { type: "auto_retry_end" }, 14040);
  assert.equal(state.current.running, true);
  assert.equal(effectiveStatus(state.current, 14040), "working");
});

test("every snapshot row resolves a title; none degrades to a bare 会话", () => {
  let state = createSnapshot();
  state = applyEvent(state, { sessionId: "session-alpha-0001", title: "排查", agentName: "码农" }, { type: "turn_start" }, 10000);
  state = applyEvent(state, { sessionId: "session-beta-0002", title: null, agentName: null }, { type: "turn_start" }, 10001);
  state = applyEvent(state, { sessionId: "session-gamma-0003", title: "   " }, { type: "turn_start" }, 10002);

  assert.equal(state.sessions.length, 3);
  for (const row of state.sessions) {
    assert.equal(typeof row.displayTitle, "string", "every row carries a resolved title");
    assert.ok(row.displayTitle.length > 0);
    assert.notEqual(row.displayTitle, "会话", "a bare 会话 cannot distinguish sessions");
  }
  const beta = state.sessions.find((item) => item.sessionId === "session-beta-0002");
  const gamma = state.sessions.find((item) => item.sessionId === "session-gamma-0003");
  assert.equal(beta.displayTitle, "会话 · eta-0002");
  assert.equal(gamma.displayTitle, "会话 · mma-0003");
  assert.notEqual(beta.displayTitle, gamma.displayTitle, "rows stay distinguishable by short id");

  // The same resolution is applied to the projected session list.
  const listed = projectSessionList([
    { sessionId: "session-alpha-0001", title: "排查", agentName: "码农", path: "/private/p", cwd: "/private/cwd" },
    { sessionId: "session-beta-0002", title: null, firstMessage: "private body" },
  ]);
  assert.equal(listed[0].displayTitle, "排查");
  assert.equal(listed[1].displayTitle, "会话 · eta-0002");
});

test("the session-list projection drops paths, bodies, models and counters", () => {
  const projected = projectSessionList([{
    sessionId: "session-alpha-0001", path: "/private/session/path", title: "甲",
    firstMessage: "private first message", agentId: "a", agentName: "n", modelId: "private-model",
    messageCount: 9, cwd: "/private/cwd", modified: 1, ownerPluginId: "private-owner",
    kind: "chat", visibility: "private", lifecycle: "active", archivedAt: null,
  }]);
  assert.equal(projected.length, 1);
  assert.deepEqual(Object.keys(projected[0]).sort(),
    ["agentId", "agentName", "displayTitle", "lifecycle", "sessionId", "title"]);
  const serialized = JSON.stringify(projected);
  for (const sentinel of [
    "/private/session/path", "/private/cwd", "private first message",
    "private-model", "private-owner", "visibility",
  ]) {
    assert.equal(serialized.includes(sentinel), false, `leaks ${sentinel}`);
  }

  assert.deepEqual(projectSessionList(null), []);
  assert.deepEqual(projectSessionList([{ sessionId: null }]), []);
  // Duplicate ids collapse and archived lifecycle is preserved.
  const deduped = projectSessionList([
    { sessionId: "s1", title: "a", lifecycle: "active" },
    { sessionId: "s1", title: "b", lifecycle: "archived" },
  ]);
  assert.equal(deduped.length, 1);
  assert.equal(deduped[0].lifecycle, "active", "the first sighting wins");
});

test("a pin wins over newer activity and unpinning restores the latest", () => {
  let state = createSnapshot();
  state = applyEvent(state, { sessionId: "session-older0001", title: "旧" }, { type: "turn_start" }, 20000);
  state = applyEvent(state, { sessionId: "session-older0001" }, { type: "agent_end" }, 20001);
  state = applyEvent(state, { sessionId: "session-newer0002", title: "新" }, { type: "turn_start" }, 23002);
  assert.equal(state.current.sessionId, "session-newer0002");

  const pin = { mode: "pinned", pinnedSessionId: "session-older0001" };
  let decision = resolveFollow(pin, { sessions: state.sessions, listEntries: [], listAvailable: true, now: 23003 });
  assert.equal(decision.view.mode, "pinned");
  assert.equal(decision.view.sessionId, "session-older0001");
  assert.equal(decision.follow.reason, "pinned");

  const pinned = rebuildSnapshot(state, decision.follow, 23003);
  assert.equal(pinned.current.sessionId, "session-older0001", "the pin leads even though it is older");
  assert.equal(pinned.current.displayTitle, "旧");

  // A new event on a different session still cannot steal the pin.
  const withEvent = applyEvent(pinned, { sessionId: "session-third0003", title: "第三" }, { type: "turn_start" }, 23004, decision.follow);
  assert.equal(withEvent.current.sessionId, "session-older0001", "the pin is sticky across events");

  const unpin = normalizeFollow({ ...createFollow(), updatedAt: 23005 }, 23005);
  const back = rebuildSnapshot(withEvent, unpin, 23005);
  assert.equal(back.current.sessionId, "session-third0003", "unpinned follows the newest activity");
});

test("a closed, archived or long-missing pin is released with a reason", () => {
  let state = createSnapshot();
  state = applyEvent(state, { sessionId: "session-live001", title: "在线" }, { type: "turn_start" }, 30000);
  state = applyEvent(state, { sessionId: "session-doom001", title: "终结" }, { type: "turn_start" }, 30001);

  // Closed: the session_closed event marks it, and the next resolve releases the pin.
  const closedState = applyEvent(state, { sessionId: "session-doom001" }, { type: "session_closed" }, 30002, {
    mode: "pinned", pinnedSessionId: "session-doom001",
  });
  const afterClose = resolveFollow({ mode: "pinned", pinnedSessionId: "session-doom001" }, {
    sessions: closedState.sessions, listEntries: [], listAvailable: true, now: 30003,
  });
  assert.equal(afterClose.follow.mode, "latest");
  assert.equal(afterClose.follow.released.reason, "pinned_closed");
  assert.equal(afterClose.follow.released.sessionId, "session-doom001");
  const movedOn = rebuildSnapshot(closedState, afterClose.follow, 30003);
  assert.equal(movedOn.current.sessionId, "session-live001", "the pet follows a live session, not a dead pin");

  // With another live session available, a closed one is never the latest target.
  const unpinClosed = rebuildSnapshot(closedState, createFollow(), 30003);
  assert.equal(unpinClosed.current.sessionId, "session-live001");

  // Closing the only session must not blank `current`: the pet simply goes idle.
  let onlyState = createSnapshot();
  onlyState = applyEvent(onlyState, { sessionId: "session-solo0001", title: "唯一" }, { type: "turn_start" }, 31000);
  onlyState = applyEvent(onlyState, { sessionId: "session-solo0001" }, { type: "session_closed" }, 31001);
  assert.equal(onlyState.current.sessionId, "session-solo0001", "the last closed session is still displayed");
  assert.equal(onlyState.current.status, "idle");

  // Archived on the real list.
  const archived = resolveFollow({ mode: "pinned", pinnedSessionId: "session-doom001" }, {
    sessions: state.sessions,
    listEntries: [{ sessionId: "session-doom001", lifecycle: "archived" }],
    listAvailable: true, now: 30004,
  });
  assert.equal(archived.follow.mode, "latest");
  assert.equal(archived.follow.released.reason, "pinned_archived");

  // Missing from the list: held inside the grace window, released past it.
  const missingStart = resolveFollow({ mode: "pinned", pinnedSessionId: "session-ghost9999" }, {
    sessions: state.sessions, listEntries: [], listAvailable: true, now: 40000,
  });
  assert.equal(missingStart.follow.mode, "pinned", "an unseen pin is not dropped instantly");
  assert.equal(missingStart.follow.missingSince, 40000);
  assert.equal(missingStart.follow.released, null);

  const stillGrace = resolveFollow(missingStart.follow, {
    sessions: state.sessions, listEntries: [], listAvailable: true, now: 40000 + PIN_MISSING_GRACE_MS - 1,
  });
  assert.equal(stillGrace.follow.mode, "pinned", "the grace window is respected");

  const expired = resolveFollow(missingStart.follow, {
    sessions: state.sessions, listEntries: [], listAvailable: true, now: 40000 + PIN_MISSING_GRACE_MS,
  });
  assert.equal(expired.follow.mode, "latest", "a dead pin must never freeze the pet");
  assert.equal(expired.follow.released.reason, "pinned_missing");
  assert.equal(expired.follow.released.sessionId, "session-ghost9999");

  // A list we cannot read is not evidence of absence.
  const unreadable = resolveFollow({ mode: "pinned", pinnedSessionId: "session-live001" }, {
    sessions: state.sessions, listEntries: [], listAvailable: false, now: 90000,
  });
  assert.equal(unreadable.follow.mode, "pinned");
  assert.equal(unreadable.follow.missingSince, null);
  assert.equal(unreadable.follow.released, null);
});

test("a follow record is normalized and never carries unexpected fields", () => {
  const base = createFollow();
  assert.equal(base.mode, "latest");
  assert.equal(base.pinnedSessionId, null);
  assert.equal(base.released, null);

  // A pinnedSessionId without mode=pinned is not a pin.
  assert.equal(normalizeFollow({ pinnedSessionId: "s1" }, 1).mode, "latest");
  assert.equal(normalizeFollow({ mode: "pinned", pinnedSessionId: "" }, 1).mode, "latest");
  // Junk and hostile shapes fall back to the default.
  for (const value of [null, undefined, "x", 42, [], { mode: "pinned" }]) {
    assert.equal(normalizeFollow(value, 1).mode, "latest", `rejected: ${JSON.stringify(value)}`);
    assert.equal(normalizeFollow(value, 1).pinnedSessionId, null);
  }
  // Unknown reasons and unknown release causes are dropped; a stale notice expires.
  assert.equal(normalizeFollow({ reason: "made-up" }, 1).reason, "no_activity");
  assert.equal(normalizeFollow({ released: { sessionId: "s1", reason: "nope", at: 0 } }, 1).released, null);
  assert.equal(normalizeFollow({ released: { sessionId: "", reason: "pinned_closed", at: 0 } }, 1).released, null);
  assert.equal(normalizeFollow({ released: { sessionId: "s1", reason: "pinned_closed", at: 5000 } }, 6000).released.reason,
    "pinned_closed", "a recent release notice survives a reload");
  assert.equal(normalizeFollow({ released: { sessionId: "s1", reason: "pinned_closed", at: 5000 } },
    5000 + FOLLOW_NOTICE_TTL_MS + 1).released, null,
    "a release notice is transient UI context, not durable state");

  const follow = normalizeFollow({ mode: "pinned", pinnedSessionId: "s1", updatedAt: 7 }, 9000);
  assert.deepEqual(Object.keys(follow).sort(), [
    "followedSessionId", "missingSince", "mode", "pinnedSessionId", "reason", "released", "schemaVersion", "updatedAt",
  ]);
});

test("placeholder ids are recognised, never pinnable, and never presented as real", () => {
  const key = unresolvedKeyFor("/private/session/alpha");
  assert.equal(key.startsWith("unresolved:"), true);
  assert.equal(isUnresolvedSessionId(key), true);
  assert.equal(isPlaceholderSessionId(key), true);
  assert.equal(isPinnableSessionId(key), false, "a placeholder is not pinnable");

  // The key is stable for a path and opaque: the path itself never appears.
  assert.equal(unresolvedKeyFor("/private/session/alpha"), key, "the same path yields the same key");
  assert.notEqual(unresolvedKeyFor("/private/session/beta"), key, "different paths differ");
  assert.equal(key.includes("/private"), false, "the path is not embedded in the id");

  // Legacy per-process fake ids are placeholders too.
  assert.equal(isPlaceholderSessionId("local-session-3"), true);
  assert.equal(isPinnableSessionId("local-session-3"), false);
  // Real host ids are untouched.
  assert.equal(isPlaceholderSessionId("sess_0mvbpagcf_7e54cc427982b968d4e0"), false);
  assert.equal(isPinnableSessionId("sess_0mvbpagcf_7e54cc427982b968d4e0"), true);
  assert.equal(isPinnableSessionId(""), false);
  assert.equal(isPinnableSessionId(null), false);

  // Display: a placeholder says so instead of masquerading as a normal session.
  assert.equal(displayTitleFor({ sessionId: key, title: null }), `未识别会话 · ${key.slice(-8)}`);
  assert.equal(displayTitleFor({ sessionId: key, title: "即使是假标题" }).startsWith("未识别会话"), true,
    "a placeholder never borrows a title to look legitimate");

  // A pin to a placeholder is never accepted.
  assert.equal(normalizeFollow({ mode: "pinned", pinnedSessionId: key }, 1).mode, "latest");
  assert.equal(normalizeFollow({ mode: "pinned", pinnedSessionId: "local-session-1" }, 1).mode, "latest");

  // Placeholders never reach the selectable list.
  assert.deepEqual(projectSessionList([
    { sessionId: "sess_real0001", title: "真", lifecycle: "active" },
    { sessionId: key, title: null, lifecycle: "active" },
    { sessionId: "local-session-2", title: null, lifecycle: "active" },
  ]).map((item) => item.sessionId), ["sess_real0001"]);
});

test("an unresolved row records activity but never becomes the current session", () => {
  let state = createSnapshot();
  const placeholder = unresolvedKeyFor("/private/session/alpha");
  state = applyEvent(state, { sessionId: placeholder, title: null }, { type: "agent_start" }, 60000);
  state = applyEvent(state, { sessionId: placeholder }, { type: "tool_execution_start", toolName: "exec_command" }, 60001);

  assert.equal(state.sessions.length, 1);
  assert.equal(state.sessions[0].unresolved, true);
  assert.equal(state.sessions[0].sessionId, placeholder);
  assert.equal(state.sessions[0].toolName, "exec_command", "the activity is still recorded");
  assert.equal(state.current, null, "a placeholder never owns the current session");

  // A real session active at the same time keeps the lead.
  let mixed = applyEvent(state, { sessionId: "sess_real0001", title: "真会话" }, { type: "agent_start" }, 60002);
  assert.equal(mixed.current.sessionId, "sess_real0001", "the real session leads");
  assert.equal(mixed.sessions.some((item) => item.sessionId === placeholder), true,
    "the placeholder is retained for a later merge");

  // Only a placeholder present: still nothing is presented as current.
  const onlyPlaceholder = applyEvent(createSnapshot(), { sessionId: placeholder }, { type: "agent_start" }, 60003);
  assert.equal(onlyPlaceholder.current, null, "activity alone does not promote a placeholder");
});

test("merging a placeholder onto a real id moves the activity and drops the placeholder", () => {
  const placeholder = unresolvedKeyFor("/private/session/alpha");
  let state = createSnapshot();
  state = applyEvent(state, { sessionId: placeholder }, { type: "agent_start" }, 70000);
  state = applyEvent(state, { sessionId: placeholder }, { type: "tool_execution_start", toolName: "exec_command" }, 70001);
  const parked = state;

  const merged = mergeSnapshot(parked, placeholder, "sess_real0001", 70002, {
    title: "歌词双行显示设置", agentId: "agent-hanako", agentName: "哦鲸鲸",
  });
  const ids = merged.sessions.map((item) => item.sessionId);
  assert.equal(ids.includes(placeholder), false, "the placeholder is removed");
  assert.deepEqual(ids, ["sess_real0001"], "only the real session remains");
  assert.equal(merged.current.sessionId, "sess_real0001");
  assert.equal(merged.current.title, "歌词双行显示设置", "identity comes from the host");
  assert.equal(merged.current.agentName, "哦鲸鲸");
  assert.equal(merged.current.toolName, "exec_command", "the activity moved across");
  assert.equal(merged.current.running, true);
  assert.equal(merged.current.unresolved, false);
  assert.ok(merged.current.lastActivityAt >= 70001, "the activity timestamp moved too");

  // Merging into an existing row combines rather than replaces.
  let withReal = createSnapshot();
  withReal = applyEvent(withReal, { sessionId: "sess_real0001", title: "已有标题" }, { type: "agent_start" }, 70010);
  const combined = mergeSnapshot(withReal, placeholder, "sess_real0001", 70020);
  assert.equal(combined.sessions.length, 1);
  assert.equal(combined.current.title, "已有标题", "an existing title is not clobbered");

  // Degenerate inputs are no-ops.
  assert.equal(mergeSnapshot(parked, placeholder, placeholder, 70030), parked, "same id is a no-op");
  assert.equal(mergeSnapshot(parked, "absent", "sess_real0001", 70031), parked, "missing source is a no-op");
  assert.equal(mergeSnapshot(parked, placeholder, null, 70032), parked, "no target is a no-op");
  assert.equal(mergeSnapshot(createSnapshot(), placeholder, "sess_real0001", 70033).sessions.length, 0);
});

test("restoring an App snapshot drops placeholder rows", () => {
  const placeholder = unresolvedKeyFor("/private/session/alpha");
  const restored = recoverSnapshot({
    schemaVersion: 1, observedAt: 1, revision: 9473,
    sessions: [
      { sessionId: "local-session-1", title: null, status: "success", running: false,
        lastActivityAt: 1000, statusAt: 1000 },
      { sessionId: "local-session-3", title: null, status: "working", running: true,
        toolName: "exec_command", lastActivityAt: 2000, statusAt: 2000 },
      { sessionId: placeholder, title: null, status: "working", running: true,
        toolName: "exec_command", lastActivityAt: 2500, statusAt: 2500 },
      { sessionId: "sess_real0001", title: "歌词双行显示设置", agentName: "哦鲸鲸", status: "idle",
        running: false, lastActivityAt: 30, statusAt: 30 },
    ],
    current: { sessionId: "local-session-3", status: "working", running: true,
      toolName: "exec_command", lastActivityAt: 2000, statusAt: 2000 },
  });

  const ids = restored.sessions.map((item) => item.sessionId);
  assert.deepEqual(ids, ["sess_real0001"], "every placeholder is gone; the real session stays");
  assert.equal(restored.current.sessionId, "sess_real0001", "the real session leads");
  assert.equal(restored.current.running, false, "a restart never revives stale work");
  assert.equal(restored.current.toolName, null);
});

test("an archived session is nameable but never pinnable", () => {
  const active = { sessionId: "sess_active0001", title: "活跃", lifecycle: "active" };
  const archived = { sessionId: "sess_archived01", title: "归档", lifecycle: "archived" };
  const placeholder = { sessionId: unresolvedKeyFor("/p"), title: null, lifecycle: "active" };

  assert.equal(isPinnableEntry(active), true);
  assert.equal(isPinnableEntry(archived), false, "an archived session cannot be pinned");
  assert.equal(isPinnableEntry(placeholder), false, "a placeholder cannot be pinned");
  assert.equal(isPinnableEntry(null), false);
  assert.equal(isPinnableEntry({}), false);

  // Both lifecycle states survive the projection so the UI can show the difference.
  const projected = projectSessionList([active, archived]);
  assert.deepEqual(projected.map((item) => item.lifecycle), ["active", "archived"]);
  assert.equal(projected.every((item) => item.displayTitle.length > 0), true,
    "an archived session still gets a display title");
  // Paths never survive the projection even though they drove the mapping.
  const withPaths = projectSessionList([{ ...active, path: "/private/session/a", cwd: "/private/cwd" }]);
  assert.deepEqual(Object.keys(withPaths[0]).sort(),
    ["agentId", "agentName", "displayTitle", "lifecycle", "sessionId", "title"]);
  assert.equal(JSON.stringify(withPaths).includes("/private"), false, "no path is stored");
});

test("the session list keeps every active session even when the archive is huge", () => {
  // 300 archived rows and one active: the active one must survive truncation.
  const archived = Array.from({ length: 300 }, (_, index) => ({
    sessionId: `sess_arch${String(index).padStart(4, "0")}`, title: `旧 ${index}`, lifecycle: "archived",
  }));
  const active = { sessionId: "sess_active_zzz", title: "活跃", lifecycle: "active" };
  const projected = projectSessionList([...archived, active]);
  assert.equal(projected.some((item) => item.sessionId === active.sessionId), true,
    "the active session is never traded away for archive rows");
  assert.equal(projected.filter((item) => item.lifecycle === "active").length, 1);

  // All-active lists are not truncated by the archived budget.
  const manyActive = Array.from({ length: 100 }, (_, index) => ({
    sessionId: `sess_act${String(index).padStart(4, "0")}`, title: `新 ${index}`, lifecycle: "active",
  }));
  assert.equal(projectSessionList(manyActive).length, 100, "active sessions keep their own budget");

  // Projection never carries a path even though the raw entry had one.
  const withPath = projectSessionList([{ ...active, path: "/private/session/x.jsonl", cwd: "/private/cwd" }]);
  assert.equal(JSON.stringify(withPath).includes("/private"), false);
});

test("the pickable list is active-only and ordered by recent activity", () => {
  const entries = [
    { sessionId: "sess_aaa", title: "A", lifecycle: "active" },
    { sessionId: "sess_bbb", title: "B", lifecycle: "active" },
    { sessionId: "sess_arc", title: "归档", lifecycle: "archived" },
    { sessionId: "unresolved:deadbeef", title: null, lifecycle: "active" },
  ];
  const picked = pickableSessionList(entries, { sess_aaa: 10, sess_bbb: 99 }, 15);
  assert.deepEqual(picked.map((item) => item.sessionId), ["sess_bbb", "sess_aaa"],
    "archived and unresolved rows never appear, and recency decides the order");

  // The cap applies to active entries only, keeping the most recent.
  const many = Array.from({ length: 40 }, (_, index) => ({
    sessionId: `sess_${String(index).padStart(3, "0")}`, title: `s${index}`, lifecycle: "active",
  }));
  const activity = Object.fromEntries(many.map((item, index) => [item.sessionId, index]));
  const capped = pickableSessionList(many, activity, 15);
  assert.equal(capped.length, 15);
  assert.equal(capped[0].sessionId, "sess_039", "the newest survives the cap");
  assert.equal(capped.some((item) => item.sessionId === "sess_039"), true);
});

test("hints are a frozen enum with an expiry each", () => {
  assert.deepEqual([...PET_HINTS], ["confirming", "compacting", "interrupted"]);
  for (const hint of PET_HINTS) {
    assert.equal(typeof HINT_TTL_MS[hint], "number", `${hint} has a TTL`);
    assert.ok(HINT_TTL_MS[hint] > 0, `${hint} TTL is positive`);
  }
  assert.ok(HINT_TTL_MS.interrupted < HINT_TTL_MS.confirming, "interrupted is the short one");

  // effectiveHint refuses anything outside the enum and anything expired.
  assert.equal(effectiveHint({ hint: "confirming", hintAt: 1000 }, 1001), "confirming");
  assert.equal(effectiveHint({ hint: "confirming", hintAt: 1000 }, 1000 + HINT_TTL_MS.confirming), null,
    "the TTL boundary itself is expired");
  assert.equal(effectiveHint({ hint: "bogus", hintAt: 1000 }, 1001), null);
  assert.equal(effectiveHint({ hint: null, hintAt: 1000 }, 1001), null);
  assert.equal(effectiveHint(null, 1001), null);
  // A missing timestamp cannot prove freshness, so the hint is dropped.
  assert.equal(effectiveHint({ hint: "confirming" }, 1001), null);
});

test("hint events raise and clear only their own hint, never inventing a row", () => {
  let state = applyEvent(createSnapshot(), { sessionId: "sess_a", title: "A" }, { type: "agent_start" }, 1000);
  assert.equal(state.sessions[0].hint, null, "a normal event carries no hint");

  state = applyHintEvent(state, { sessionId: "sess_a" }, { type: "session_confirmation" }, 2000);
  assert.equal(state.current.hint, "confirming");
  assert.equal(state.current.hintAt, 2000);
  assert.equal(state.current.status, "working", "a hint never changes status");

  // A compaction start replaces the confirmation rather than stacking.
  state = applyHintEvent(state, { sessionId: "sess_a" }, { type: "compaction_start" }, 3000);
  assert.equal(state.current.hint, "compacting");
  assert.equal(state.current.hintAt, 3000);

  // `confirmation_resolved` must not clear an unrelated hint.
  state = applyHintEvent(state, { sessionId: "sess_a" }, { type: "confirmation_resolved" }, 4000);
  assert.equal(state.current.hint, "compacting", "an unrelated clear is a no-op");

  state = applyHintEvent(state, { sessionId: "sess_a" }, { type: "compaction_end" }, 5000);
  assert.equal(state.current.hint, null);
  assert.equal(state.current.hintAt, 0);

  // Unknown sessions are never created by a hint.
  const before = state;
  const orphan = applyHintEvent(state, { sessionId: "sess_absent" }, { type: "session_confirmation" }, 6000);
  assert.equal(orphan, before, "no row is invented for an unknown session");

  // An unattributed clear wipes every showing hint.
  let two = applyEvent(createSnapshot(), { sessionId: "sess_a" }, { type: "agent_start" }, 7000);
  two = applyEvent(two, { sessionId: "sess_b" }, { type: "agent_start" }, 7001);
  two = applyHintEvent(two, { sessionId: "sess_a" }, { type: "session_confirmation" }, 7002);
  two = applyHintEvent(two, { sessionId: "sess_b" }, { type: "session_confirmation" }, 7003);
  two = applyHintEvent(two, { sessionId: null, clearAll: true }, { type: "confirmation_resolved" }, 7004);
  assert.deepEqual(two.sessions.map((item) => item.hint), [null, null],
    "an unattributed resolution clears them all");
  assert.equal(two.sessions.length, 2, "and adds no row");

  // An unattributed raise is dropped outright.
  assert.equal(applyHintEvent(two, { sessionId: null }, { type: "session_confirmation" }, 7005), two);
});

test("restoring an App snapshot never revives stale work, feedback, or tool identity", () => {
  let source = applyEvent(createSnapshot(), identity("session-abcdef12"), { type: "turn_start" }, 6000);
  source = applyEvent(source, identity("session-abcdef12"), {
    type: "tool_execution_start", toolName: "file.read",
  }, 6010);
  const restored = recoverSnapshot(source);
  assert.equal(restored.current.status, "idle");
  assert.equal(restored.current.running, false);
  assert.equal(restored.current.toolName, null);
  assert.equal(restored.current.feedbackResumed, false);
  assert.equal(restored.current.runEnded, false);
  assert.equal(restored.selectedCharacterId, undefined);
});
