import test from "node:test";
import assert from "node:assert/strict";
import {
  buildLifecycleFixture,
  LIFECYCLE_PRIVATE_SENTINELS,
} from "./lifecycle-fixture.mjs";

const fixture = buildLifecycleFixture();

test("the synthetic lifecycle walks read/write tools, short feedback, continued work, retry and whole-run end", () => {
  assert.deepEqual(fixture.steps.map((step) => step.dto.activity.status), [
    "working", "tool", "success", "success", "working",
    "tool", "error", "error", "working",
    "working", "working", "working", "success", "success", "idle",
  ]);
  assert.deepEqual(fixture.steps.map((step) => step.dto.activity.toolName), [
    null, "read", null, null, null,
    "functions.write", null, null, null,
    null, null, null, null, null, null,
  ]);
  for (const step of fixture.steps) {
    assert.equal(step.dto.activity.status, step.expectation.status, `${step.label} status`);
    assert.equal(step.dto.activity.toolName, step.expectation.toolName, `${step.label} tool name`);
    assert.ok(typeof step.expectation.pose === "string" && step.expectation.pose.length > 0, `${step.label} declares a pose`);
  }
});

test("every projected step stays a strict v4 DTO with no private bus content", () => {
  for (const step of fixture.steps) {
    assert.equal(step.dto.schemaVersion, 4, `${step.label} schema`);
    assert.deepEqual(Object.keys(step.dto).sort(), [
      "activity", "characters", "concurrentSessions", "followMode", "notifications", "revision", "schemaVersion",
    ], `${step.label} root keys`);
    assert.deepEqual(Object.keys(step.dto.activity).sort(), [
      "agentId", "agentName", "hint", "lastActivityAt", "sessionId", "spotlight", "status", "title", "toolName",
    ], `${step.label} activity keys`);
    assert.equal(step.dto.followMode, "latest", `${step.label} follow mode`);
    assert.ok(Number.isSafeInteger(step.dto.concurrentSessions) && step.dto.concurrentSessions >= 0,
      `${step.label} bounded concurrency`);
    assert.ok(Array.isArray(step.dto.notifications), `${step.label} notifications array`);
    assert.equal(step.dto.characters.length, 7, `${step.label} keeps the seven manual choices`);
    const serialized = JSON.stringify(step.dto);
    for (const sentinel of LIFECYCLE_PRIVATE_SENTINELS) {
      assert.equal(serialized.includes(sentinel), false, `${step.label} leaks ${sentinel}`);
    }
  }
});

test("a tool result is short feedback, never whole-run completion or a stale active tool", () => {
  const byLabel = new Map(fixture.steps.map((step) => [step.label, step]));
  assert.equal(byLabel.get("read_tool_end").dto.activity.status, "success");
  assert.equal(byLabel.get("read_tool_end").dto.activity.toolName, null, "the finished tool is cleared");
  assert.equal(byLabel.get("feedback_survives_next_turn").dto.activity.status, "success", "a synchronous next turn keeps short feedback visible");
  assert.equal(byLabel.get("feedback_expires_to_work").dto.activity.status, "working", "feedback expires back to the real active state");
  assert.equal(byLabel.get("write_tool_error").dto.activity.status, "error");
  assert.equal(byLabel.get("error_feedback_expires_to_work").dto.activity.status, "working");
});

test("retry keeps work alive and only agent_end without retry ends the run", () => {
  const byLabel = new Map(fixture.steps.map((step) => [step.label, step]));
  assert.equal(byLabel.get("agent_end_will_retry").dto.activity.status, "working");
  assert.equal(byLabel.get("auto_retry_start").dto.activity.status, "working");
  assert.equal(byLabel.get("auto_retry_end_is_not_completion").dto.activity.status, "working");
  assert.equal(byLabel.get("whole_run_end").dto.activity.status, "success");
  assert.equal(byLabel.get("outcome_still_recent").dto.activity.status, "success");
  assert.equal(byLabel.get("outcome_expires_to_idle").dto.activity.status, "idle");
});

test("the fixture stays deterministic and serializable for the native replay", () => {
  const first = JSON.stringify(buildLifecycleFixture());
  const second = JSON.stringify(buildLifecycleFixture());
  assert.equal(first, second, "the fixture rebuilds byte-identically");
  const parsed = JSON.parse(first);
  assert.equal(parsed.steps.length, fixture.steps.length);
  assert.equal(parsed.steps[1].dto.activity.toolName, "read");
  assert.ok(parsed.steps.every((step) => Number.isSafeInteger(step.dto.revision)));
  const revisions = parsed.steps.map((step) => step.dto.revision);
  assert.deepEqual(revisions, [...revisions].sort((a, b) => a - b), "revisions are strictly increasing for the native store");
});

test("the full v4 metadata step really carries every new field", () => {
  const step = fixture.v4Step;
  assert.equal(step.dto.schemaVersion, 4);
  assert.equal(step.dto.followMode, "pinned");
  assert.equal(step.dto.concurrentSessions, 1, "the running synthetic session is counted");
  assert.deepEqual(step.dto.notifications.map((notice) => notice.kind), ["confirmation"]);
  assert.deepEqual(step.dto.activity.spotlight, { kind: "drawing", at: 20010 });
  assert.equal(step.dto.activity.hint, "confirming");
  assert.equal(step.dto.activity.status, "tool");
  const serialized = JSON.stringify(step.dto);
  for (const sentinel of LIFECYCLE_PRIVATE_SENTINELS) {
    assert.equal(serialized.includes(sentinel), false, `the v4 step leaks ${sentinel}`);
  }
});

// --- Synthetic concurrent follow input -----------------------------------------
//
// These steps feed the existing follow rules only. The 30-second active-work protection
// and the 2-second activity lead are asserted as they are implemented today; the pet's
// new display rhythm must not be able to change them.
test("two concurrent synthetic sessions keep the existing anti-ping-pong protection", () => {
  const byLabel = new Map(fixture.concurrentSteps.map((step) => [step.label, step]));
  const alpha = "concurrent-session-alpha";
  const beta = "concurrent-session-beta";

  assert.equal(byLabel.get("alpha_starts").dto.activity.sessionId, alpha, "the first worker owns the pet");
  assert.equal(byLabel.get("beta_starts_inside_active_protection").dto.activity.sessionId, alpha,
    "a second session starting inside the active-work window cannot steal the pet");
  assert.equal(byLabel.get("beta_progress_still_protected").dto.activity.sessionId, alpha,
    "repeated progress inside the window still cannot steal the pet");
  assert.equal(byLabel.get("alpha_tool_start").dto.activity.status, "tool", "the incumbent tool run is projected");
  assert.equal(byLabel.get("beta_progress_before_protection_expires").dto.activity.sessionId, alpha,
    "the protection lasts until the incumbent has been quiet for 30 seconds");
  assert.equal(byLabel.get("beta_overtakes_after_protection").dto.activity.sessionId, beta,
    "past the window the newer session takes over");
  assert.equal(byLabel.get("alpha_cannot_steal_back_inside_protection").dto.activity.sessionId, beta,
    "the new incumbent then gets the same protection");
  assert.equal(byLabel.get("alpha_returns_after_protection_and_margin").dto.activity.sessionId, alpha,
    "after both windows the newest activity wins again");
  for (const step of fixture.concurrentSteps) {
    assert.equal(step.dto.activity.sessionId, step.expectation.current, `${step.label} current owner`);
    assert.equal(step.dto.schemaVersion, 4, `${step.label} stays schema v4`);
    const serialized = JSON.stringify(step.dto);
    for (const sentinel of LIFECYCLE_PRIVATE_SENTINELS) {
      assert.equal(serialized.includes(sentinel), false, `${step.label} leaks ${sentinel}`);
    }
  }
});
