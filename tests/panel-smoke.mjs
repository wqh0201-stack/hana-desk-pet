import fs from "node:fs";
import vm from "node:vm";

const source = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.js", "utf8");
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
};

const made = [];
function el(tag = "div") {
  const node = {
    tagName: tag, children: [], _text: "", value: "", checked: false, disabled: false,
    dataset: {}, style: { setProperty() {} }, className: "",
    get textContent() { return this._text; },
    set textContent(v) { this._text = String(v); },
    append(...kids) { this.children.push(...kids); },
    appendChild(k) { this.children.push(k); return k; },
    replaceChildren(...kids) {
      // Real DOM flattens a DocumentFragment into its children; emulate that.
      this.children = kids.flatMap((k) => (k && k.tagName === "fragment" ? k.children : [k]));
    },
    addEventListener() {}, setAttribute() {}, removeAttribute() {},
    classList: { add() {}, remove() {}, toggle() {} },
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
const sandbox = {
  document,
  window: { setInterval: () => 1, clearInterval() {}, addEventListener() {} },
  console,
  Date, Math, Number, JSON, Array, Object, String, Set, Map, Promise, isFinite,
};
sandbox.globalThis = sandbox;

// Stub the host SDK so the module body executes for real.
const hanaStub = {
  ready() {},
  storage: {
    global: {
      async get(key) { return store[key]; },
      async set(key, value) { store[key] = value; },
      onChanged() { return () => {}; },
    },
  },
};
const patched = source.replace('import { hana } from "./sdk.js";', "");
const wrapped = `(async () => { const hana = __hana; ${patched} })()`;
const context = vm.createContext({ ...sandbox, __hana: hanaStub });
await vm.runInContext(wrapped, context, { filename: "panel.js" });
await new Promise((r) => setTimeout(r, 60));

const roleBox = byId.get("role-options");
const followSelect = byId.get("follow-select");
const status = byId.get("activity-status");
const title = byId.get("session-title");
const sessions = byId.get("sessions");
const bridgeState = byId.get("bridge-state");

const out = {
  roleButtons: roleBox?.children.length ?? 0,
  followOptions: followSelect?.children.length ?? 0,
  followSelected: followSelect?.value ?? null,
  activityStatus: status?.textContent ?? null,
  sessionTitle: title?.textContent ?? null,
  sessionRows: sessions?.children.length ?? 0,
  bridgeState: bridgeState?.textContent ?? null,
};
console.log(JSON.stringify(out, null, 1));
const ok = out.roleButtons === 7 && out.followOptions === 3 && out.sessionRows === 2
  && out.activityStatus === "工具运行" && out.bridgeState === "已连接";
console.log(ok ? "PANEL_SMOKE_OK" : "PANEL_SMOKE_FAIL");
process.exit(ok ? 0 : 1);
