import {
  applyEvent,
  createSnapshot,
} from "../apps/hana-desktop-pet/state-core.mjs";

const session = {
  sessionId: "demo-session-2026-10",
  title: "状态镜像演示",
  agentId: "demo-agent",
  agentName: "本地模拟 Agent",
};
const now = Date.now();
let snapshot = createSnapshot();

snapshot = applyEvent(snapshot, session, { type: "agent_start" }, now);
snapshot = applyEvent(snapshot, session, {
  type: "tool_execution_start",
  toolName: "example.read",
  args: { prompt: "此字段不应该出现在快照里" },
}, now + 1);
snapshot = applyEvent(snapshot, session, {
  type: "tool_execution_end",
  toolName: "example.read",
  isError: false,
  result: { content: "此字段也不应该出现在快照里" },
}, now + 2);
snapshot = applyEvent(snapshot, session, { type: "agent_end" }, now + 3);

console.log(JSON.stringify({
  mode: "synthetic-event-demo; not connected to Hana or a desktop pet",
  snapshot,
}, null, 2));
