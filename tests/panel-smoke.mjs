import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.js", "utf8");
const poseIndexSource = fs.readFileSync("apps/hana-desktop-pet/ui/assets/pose-index.js", "utf8");
const { POSE_INDEX } = await import(`data:text/javascript;base64,${Buffer.from(poseIndexSource).toString("base64")}`);
const store = {
  "hana-pet.bridge.enabled": true,
  "hana-pet.bridge.status": "connected",
  "hana-pet.activity.snapshot": {
    revision: 3, observedAt: 1,
    sessions: [
      { sessionId: "sess_aaa11111", title: "给桌宠加绑定", agentId: "codingagent", agentName: "码农",
        status: "working", running: true, toolName: "read", lastActivityAt: 1000, statusAt: 1000 },
      { sessionId: "sess_bbb22222", title: null, agentId: "alice", agentName: "Mona",
        status: "idle", running: false, toolName: null, lastActivityAt: 500, statusAt: 500 },
    ],
    current: { sessionId: "sess_aaa11111", title: "给桌宠加绑定", displayTitle: "给桌宠加绑定",
      agentName: "码农", status: "working", running: true, toolName: "read",
      lastActivityAt: 1000, statusAt: 1000 },
  },
  "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "给桌宠加绑定", agentName: "码农", lifecycle: "active" },
      { sessionId: "sess_bbb22222", title: null, agentName: "Mona", lifecycle: "active" },
  ]},
  "hana-pet.follow": { mode: "pinned", pinnedSessionId: "sess_aaa11111",
    followedSessionId: "sess_aaa11111", reason: "pinned", released: null },
  "hana-pet.selection": { characterId: "gpt", updatedAt: 1, petRevision: 0 },
  "hana-pet.session-diagnostics": { list: null, get: {
    code: "APP_HOST_ERROR", kind: "host", operation: "session:get", selector: "path", pathMatch: "basename",
  } },
};

const made = [];
function el(tag = "div") {
  const node = {
    tagName: tag, children: [], _text: "", value: "", checked: false, disabled: false,
    hidden: false, dataset: {}, style: { setProperty() {} }, className: "", attributes: {}, handlers: {},
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); },
    append(...kids) { this.children.push(...kids); },
    appendChild(k) { this.children.push(k); return k; },
    replaceChildren(...kids) {
      this.children = kids.flatMap((k) => (k && k.tagName === "fragment" ? k.children : [k]));
    },
    addEventListener(type, callback) { this.handlers[type] = callback; },
    setAttribute(name, value) { this.attributes[name] = String(value); },
    getAttribute(name) { return this.attributes[name] ?? null; },
    removeAttribute(name) { delete this.attributes[name]; },
  };
  made.push(node);
  return node;
}
const byId = new Map();
const document = {
  getElementById(id) { if (!byId.has(id)) byId.set(id, el()); return byId.get(id); },
  createElement: (t) => el(t),
  createDocumentFragment: () => el("fragment"),
};
let storageChange = null;
const failWrites = new Set();
const sandbox = {
  document,
  window: {
    setInterval: () => 1, clearInterval() {},
    setTimeout: () => 1, clearTimeout() {},
    addEventListener() {},
  },
  console,
  Date, Math, Number, JSON, Array, Object, String, Set, Map, Promise, isFinite,
};
sandbox.globalThis = sandbox;

const hanaStub = {
  ready() {},
  storage: {
    global: {
      async get(key) { return store[key]; },
      async set(key, value) {
        if (failWrites.has(key)) throw new Error("synthetic write failure");
        store[key] = value;
      },
      onChanged(callback) { storageChange = callback; return () => {}; },
    },
  },
};
const patched = source
  .replace('import { hana } from "./sdk.js";', "")
  .replace('import { POSE_INDEX } from "./pose-index.js";', "");
const wrapped = `(async () => { const hana = __hana; const POSE_INDEX = __poseIndex; ${patched} })()`;
const context = vm.createContext({ ...sandbox, __hana: hanaStub, __poseIndex: POSE_INDEX });
await vm.runInContext(wrapped, context, { filename: "panel.js" });
await new Promise((r) => setTimeout(r, 60));

const roleBox = byId.get("role-options");
const status = byId.get("activity-status");
const sessions = byId.get("sessions");
const bridgeState = byId.get("bridge-state");
const stageImage = byId.get("stage-image");
const followMode = byId.get("follow-mode");
const diagError = byId.get("diag-error");
const poseConnection = byId.get("pose-connection");
const poseName = byId.get("pose-name");
const poseFallback = byId.get("pose-fallback");
const followReleaseNotice = byId.get("follow-release-notice");
const out = {
  roleButtons: roleBox?.children.length ?? 0,
  activityStatus: status?.textContent ?? null,
  sessionTitle: byId.get("session-title")?.textContent ?? null,
  sessionRows: sessions?.children.length ?? 0,
  bridgeState: bridgeState?.textContent ?? null,
  stageImage: stageImage?.src ?? null,
  poseConnection: poseConnection?.textContent ?? null,
  poseName: poseName?.textContent ?? null,
  poseFallback: poseFallback?.hidden ?? null,
  followMode: followMode?.textContent ?? null,
  diagnosticError: diagError?.textContent ?? null,
  eventCount: byId.get("diag-event-count")?.textContent ?? null,
};
console.log(JSON.stringify(out, null, 1));

let ok = out.roleButtons === 7 && out.sessionRows === 2 && out.activityStatus === "工具执行" &&
  out.bridgeState === "已连接" && out.stageImage === "./assets/poses/gpt/idle.webp" &&
  out.poseConnection === "桌宠未连接" && out.poseName === "idle" && out.poseFallback === true &&
  out.followMode === "固定跟随" && out.diagnosticError.includes("APP_HOST_ERROR") &&
  !out.diagnosticError.includes("path") && out.eventCount === "当前快照不提供";

const secondSession = sessions.children[1]?.children[0];
secondSession?.handlers.click?.();
await new Promise((r) => setTimeout(r, 20));
if (store["hana-pet.follow.request"]?.pinnedSessionId !== "sess_bbb22222" ||
    byId.get("follow-mode").textContent !== "固定跟随") ok = false;

store["hana-pet.session-list"].sessions[1].lifecycle = "archived";
store["hana-pet.follow"] = {
  mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", reason: "latest",
  released: { sessionId: "sess_bbb22222", reason: "pinned_archived", at: Date.now() },
};
storageChange?.(["hana-pet.follow", "hana-pet.session-list"]);
await new Promise((r) => setTimeout(r, 30));
if (followReleaseNotice.hidden || !followReleaseNotice.textContent.includes("会话已归档") ||
    !followReleaseNotice.textContent.includes("现在跟随「给桌宠加绑定」")) ok = false;
await new Promise((r) => setTimeout(r, 30));
if (followReleaseNotice.hidden) ok = false;

const newRole = roleBox.children.find((button) => button.dataset.roleId === "deepseek");
newRole?.handlers.click?.();
await new Promise((r) => setTimeout(r, 20));
if (store["hana-pet.selection"]?.characterId !== "deepseek" ||
    byId.get("stage-image").src !== "./assets/poses/deepseek/idle.webp") ok = false;

failWrites.add("hana-pet.selection");
const rejectedRole = roleBox.children.find((button) => button.dataset.roleId === "glm");
rejectedRole?.handlers.click?.();
await new Promise((r) => setTimeout(r, 20));
if (store["hana-pet.selection"]?.characterId !== "deepseek" ||
    byId.get("stage-image").src !== "./assets/poses/deepseek/idle.webp" ||
    !byId.get("panel-notice").textContent.includes("已恢复原选择")) ok = false;
failWrites.clear();

store["hana-pet.bridge.status"] = {
  status: "connected", reason: null,
  poseState: { schemaVersion: 3, characterId: "gpt", pose: "thinking", fallback: true, since: 10, revision: 4 },
};
storageChange?.(["hana-pet.bridge.status"]);
await new Promise((r) => setTimeout(r, 30));
if (byId.get("stage-image").src !== "./assets/poses/gpt/thinking.webp" ||
    byId.get("pose-connection").textContent !== "桌宠姿态" ||
    byId.get("pose-name").textContent !== "thinking" || byId.get("pose-fallback").hidden) ok = false;

let variantRevision = 5;
for (const pose of ["reading-2", "happy-2", "sleeping-2", "thinking-2", "sorry"]) {
  store["hana-pet.bridge.status"] = {
    status: "connected", reason: null,
    poseState: { schemaVersion: 3, characterId: "claude", pose, fallback: false, since: 11, revision: variantRevision++ },
  };
  storageChange?.(["hana-pet.bridge.status"]);
  await new Promise((r) => setTimeout(r, 20));
  if (byId.get("stage-image").src !== `./assets/poses/claude/${pose}.webp` ||
      byId.get("pose-name").textContent !== pose || byId.get("pose-connection").textContent !== "桌宠姿态" ||
      byId.get("pose-fallback").hidden !== true) ok = false;
}

const reasonCases = [
  ["unreachable", "桌宠没在运行，请打开它。"],
  ["version_mismatch", "桌宠版本与控制台不配套，请换成配套版本。"],
  ["invalid_response", "桌宠回应异常。"],
];
for (const [reason, message] of reasonCases) {
  store["hana-pet.bridge.status"] = { status: "offline", reason, poseState: null };
  storageChange?.(["hana-pet.bridge.status"]);
  await new Promise((r) => setTimeout(r, 30));
  if (byId.get("bridge-state").textContent !== message ||
      byId.get("stage-image").src !== "./assets/poses/deepseek/idle.webp" ||
      byId.get("pose-connection").textContent !== "桌宠未连接" ||
      byId.get("pose-fallback").hidden !== true) ok = false;
}

store["hana-pet.bridge.enabled"] = false;
store["hana-pet.bridge.status"] = "disabled";
storageChange?.(["hana-pet.bridge.enabled", "hana-pet.bridge.status"]);
await new Promise((r) => setTimeout(r, 30));
if (byId.get("bridge-state").textContent !== "连接已关闭" ||
    byId.get("bridge-toggle").checked !== false) ok = false;

console.log(ok ? "PANEL_SMOKE_OK" : "PANEL_SMOKE_FAIL");
process.exit(ok ? 0 : 1);
