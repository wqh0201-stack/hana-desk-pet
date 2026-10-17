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

test("every projected step stays a strict v2 DTO with no private bus content", () => {
  for (const step of fixture.steps) {
    assert.equal(step.dto.schemaVersion, 3, `${step.label} schema`);
    assert.deepEqual(Object.keys(step.dto).sort(), ["activity", "characters", "revision", "schemaVersion"], `${step.label} root keys`);
    assert.deepEqual(Object.keys(step.dto.activity).sort(), [
      "agentId", "agentName", "hint", "lastActivityAt", "sessionId", "status", "title", "toolName",
    ], `${step.label} activity keys`);
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
