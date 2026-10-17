// Synthetic cross-layer lifecycle fixture.
//
// It walks the same public event sequence a real Hana session would produce and
// projects each step through the strict v2 DTO. `tests/lifecycle-projection.test.mjs`
// asserts the JS half; `tests/pose-lifecycle-checks.swift` replays the emitted DTOs
// through the native PetAPI, the pose planner and the pose timeline.
//
// The private values below are injected into every synthetic event and must never
// appear in a projection. This is synthetic data only: it never contacts a real
// Hana host or the fixed 127.0.0.1:43127 pet service.

import { applyEvent, createSnapshot } from "../apps/hana-desktop-pet/state-core.mjs";
import { toPetSnapshot } from "../apps/hana-desktop-pet/pet-bridge.mjs";

export const LIFECYCLE_PRIVATE_SENTINELS = Object.freeze([
  "private-message-body",
  "private-args-token",
  "private-result-body",
  "private-prompt-body",
  "private-session-path",
]);

const IDENTITY = Object.freeze({
  sessionId: "session-lifecycle01",
  title: "跨层合成联调",
  agentId: "agent-coder",
  agentName: "码农",
});

/**
 * One synthetic step: the public event (or `null` when the step only advances the
 * clock) plus the projection the JS layer must produce and the pose the native
 * planner must prefer. Read tool, write tool, short feedback, continued work,
 * retry and whole-run end are all covered.
 */
const SEQUENCE = [
  { label: "agent_start", at: 1000, event: ["agent_start", {}], status: "working", toolName: null, pose: "thinking" },
  { label: "read_tool_start", at: 1100, event: ["tool_execution_start", { toolName: "read" }], status: "tool", toolName: "read", pose: "reading" },
  { label: "read_tool_end", at: 1200, event: ["tool_execution_end", { toolName: "read", isError: false }], status: "success", toolName: null, pose: "happy" },
  { label: "feedback_survives_next_turn", at: 1300, event: ["turn_start", {}], status: "success", toolName: null, pose: "happy" },
  { label: "feedback_expires_to_work", at: 4000, event: null, status: "working", toolName: null, pose: "thinking" },
  { label: "write_tool_start", at: 4100, event: ["tool_execution_start", { toolName: "functions.write" }], status: "tool", toolName: "functions.write", pose: "writing" },
  { label: "write_tool_error", at: 4200, event: ["tool_execution_end", { toolName: "functions.write", isError: true }], status: "error", toolName: null, pose: "oops" },
  { label: "error_feedback_survives_next_turn", at: 4300, event: ["turn_start", {}], status: "error", toolName: null, pose: "oops" },
  { label: "error_feedback_expires_to_work", at: 7000, event: null, status: "working", toolName: null, pose: "thinking" },
  { label: "agent_end_will_retry", at: 7100, event: ["agent_end", { willRetry: true }], status: "working", toolName: null, pose: "thinking" },
  { label: "auto_retry_start", at: 7200, event: ["auto_retry_start", {}], status: "working", toolName: null, pose: "thinking" },
  { label: "auto_retry_end_is_not_completion", at: 7300, event: ["auto_retry_end", {}], status: "working", toolName: null, pose: "thinking" },
  { label: "whole_run_end", at: 7400, event: ["agent_end", { willRetry: false }], status: "success", toolName: null, pose: "happy" },
  { label: "outcome_still_recent", at: 8000, event: null, status: "success", toolName: null, pose: "happy" },
  { label: "outcome_expires_to_idle", at: 11000, event: null, status: "idle", toolName: null, pose: "idle" },
];

export const LIFECYCLE_EXPECTATIONS = Object.freeze(SEQUENCE.map((step) => Object.freeze({
  label: step.label,
  at: step.at,
  status: step.status,
  toolName: step.toolName,
  pose: step.pose,
})));

export function buildLifecycleSteps() {
  let snapshot = createSnapshot();
  return SEQUENCE.map((step) => {
    if (step.event) {
      snapshot = applyEvent(snapshot, IDENTITY, {
        type: step.event[0],
        sessionPath: "private-session-path",
        prompt: "private-prompt-body",
        message: { content: "private-message-body" },
        args: { token: "private-args-token" },
        result: { content: "private-result-body" },
        ...step.event[1],
      }, step.at);
    }
    return {
      label: step.label,
      at: step.at,
      expectation: { status: step.status, toolName: step.toolName, pose: step.pose },
      dto: toPetSnapshot(snapshot, step.at),
    };
  });
}

export function buildLifecycleFixture() {
  return {
    schemaVersion: 1,
    generatedBy: "tests/lifecycle-fixture.mjs",
    sessionId: IDENTITY.sessionId,
    privateSentinels: LIFECYCLE_PRIVATE_SENTINELS,
    steps: buildLifecycleSteps(),
  };
}

const outFlag = process.argv.indexOf("--out");
if (outFlag !== -1 && process.argv[outFlag + 1]) {
  const { writeFileSync, mkdirSync } = await import("node:fs");
  const { dirname, resolve } = await import("node:path");
  const target = resolve(process.argv[outFlag + 1]);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, `${JSON.stringify(buildLifecycleFixture(), null, 2)}\n`, "utf8");
  console.log(`Wrote synthetic lifecycle fixture: ${target}`);
}
