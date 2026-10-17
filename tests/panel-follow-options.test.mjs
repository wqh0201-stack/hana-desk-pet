/**
 * DOM-level checks for the control panel's follow dropdown.
 *
 * The panel re-renders once per second. These tests drive that re-render against a
 * minimal DOM stub to prove the dropdown is not rebuilt while its content is
 * unchanged, and never rebuilt while the user has it open or focused — the two
 * behaviours that made the list flicker and fight the user's selection.
 */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const PANEL_PATH = "apps/hana-desktop-pet/ui/assets/panel.js";

/**
 * Run the real panel module body against a stub DOM and return handles for
 * driving it: `renderTick()` re-runs the panel's own per-second tick.
 */
async function mountPanel(store) {
  const source = fs.readFileSync(PANEL_PATH, "utf8");
  const listeners = new Map();
  const made = [];
  let activeElement = null;

  function el(tag = "div") {
    const node = {
      tagName: tag, children: [], _text: "", value: "", checked: false, disabled: false,
      dataset: {}, style: { setProperty() {} }, className: "",
      _replaceCount: 0,
      get textContent() { return this._text; },
      set textContent(v) { this._text = String(v); },
      append(...kids) { this.children.push(...kids); },
      appendChild(k) { this.children.push(k); return k; },
      replaceChildren(...kids) {
        this._replaceCount += 1;
        this.children = kids.flatMap((k) => (k && k.tagName === "fragment" ? k.children : [k]));
      },
      addEventListener(type, fn) {
        if (!listeners.has(this)) listeners.set(this, new Map());
        const own = listeners.get(this);
        if (!own.has(type)) own.set(type, []);
        own.get(type).push(fn);
      },
      setAttribute() {}, removeAttribute() {},
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
    get activeElement() { return activeElement; },
  };

  const timers = [];
  const sandbox = {
    document,
    window: {
      setInterval: (fn) => { timers.push(fn); return timers.length; },
      clearInterval() {},
      addEventListener() {},
    },
    console,
    Date, Math, Number, JSON, Array, Object, String, Set, Map, Promise, isFinite,
  };
  sandbox.globalThis = sandbox;

  const changeListeners = [];
  const hanaStub = {
    ready() {},
    storage: {
      global: {
        async get(key) { return store[key]; },
        async set(key, value) { store[key] = value; },
        onChanged(fn) { changeListeners.push(fn); return () => {}; },
      },
    },
  };

  const patched = source.replace('import { hana } from "./sdk.js";', "");
  const wrapped = `(async () => { const hana = __hana; ${patched} })()`;
  const context = vm.createContext({ ...sandbox, __hana: hanaStub });
  await vm.runInContext(wrapped, context, { filename: "panel.js" });
  await new Promise((resolve) => setTimeout(resolve, 60));

  const select = byId.get("follow-select");
  const dispatch = (type) => {
    const own = listeners.get(select);
    if (!own || !own.has(type)) return;
    for (const fn of own.get(type)) fn({ key: "" });
  };

  return {
    select,
    byId,
    store,
    setActive(node) { activeElement = node; },
    /** Push new storage into the panel the way the host would, then settle. */
    async pushStorage() {
      for (const fn of changeListeners) fn(["hana-pet.session-list"]);
      for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
    },
    /** Simulate the panel's own 1 s ticker, then let its async refresh settle. */
    async renderTick() {
      const fn = timers[timers.length - 1];
      if (fn) fn();
      // render() is synchronous, but refresh() repopulates state on storage change.
      for (let i = 0; i < 3; i += 1) await new Promise((resolve) => setImmediate(resolve));
    },
    dispatch,
    replaceCount() { return select._replaceCount; },
  };
}

function baseStore(overrides = {}) {
  return {
    "hana-pet.bridge.enabled": false,
    "hana-pet.bridge.status": "disabled",
    "hana-pet.activity.snapshot": { revision: 1, observedAt: 1,
      sessions: [{
        sessionId: "sess_aaa11111", title: "给桌宠加绑定", agentId: "codingagent", agentName: "码农",
        status: "working", running: true, toolName: "read", lastActivityAt: 1000, statusAt: 1000,
        displayTitle: "给桌宠加绑定",
      }],
      current: {
        sessionId: "sess_aaa11111", title: "给桌宠加绑定", agentName: "码农",
        status: "working", running: true, toolName: "read", lastActivityAt: 1000, statusAt: 1000,
        displayTitle: "给桌宠加绑定",
      } },
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "给桌宠加绑定", agentName: "码农", lifecycle: "active", displayTitle: "给桌宠加绑定" },
      { sessionId: "sess_bbb22222", title: null, agentName: "Mona", lifecycle: "active", displayTitle: "会话 · bb22222" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, reason: "no_activity", released: null },
    "hana-pet.selection": { characterId: "claude", updatedAt: 1, petRevision: 0 },
    ...overrides,
  };
}

test("the dropdown is built once and not rebuilt while its content is unchanged", async () => {
  const panel = await mountPanel(baseStore());
  const initial = panel.replaceCount();
  assert.ok(initial > 0, "the options were built at least once");
  assert.equal(panel.select.children.length, 3, "跟随最近活动 + two sessions");

  for (let i = 0; i < 5; i += 1) await panel.renderTick();
  assert.equal(panel.replaceCount(), initial, "identical content must not rebuild the list");
  assert.equal(panel.select.children.length, 3, "the options are still there");
});

test("the dropdown is not rebuilt while it is open or focused", async () => {
  const panel = await mountPanel(baseStore());
  const initial = panel.replaceCount();

  // Open the list, then let several per-second renders go by.
  panel.dispatch("mousedown");
  await panel.renderTick();
  assert.equal(panel.replaceCount(), initial, "no rebuild while the dropdown is open");

  // Content genuinely changed underneath: the rebuild must be deferred, not applied.
  panel.store["hana-pet.session-list"] = { available: true, sessions: [
    { sessionId: "sess_aaa11111", title: "给桌宠加绑定", agentName: "码农", lifecycle: "active", displayTitle: "给桌宠加绑定" },
    { sessionId: "sess_bbb22222", title: null, agentName: "Mona", lifecycle: "active", displayTitle: "会话 · bb22222" },
    { sessionId: "sess_ccc33333", title: "新会话", agentName: "码农", lifecycle: "active", displayTitle: "新会话" },
  ]};
  await panel.pushStorage();
  assert.equal(panel.replaceCount(), initial, "a content change is deferred, not forced on an open list");
  assert.equal(panel.select.children.length, 3, "the open list still shows the old options");

  // Closing it applies the deferred rebuild.
  panel.dispatch("blur");
  assert.equal(panel.replaceCount(), initial + 1, "the deferred rebuild runs on blur");
  assert.equal(panel.select.children.length, 4, "the new option is now present");
});

test("the dropdown is not rebuilt while it merely has focus", async () => {
  const panel = await mountPanel(baseStore());
  const initial = panel.replaceCount();
  panel.setActive(panel.select);
  panel.dispatch("focus");
  for (let i = 0; i < 3; i += 1) await panel.renderTick();
  assert.equal(panel.replaceCount(), initial, "focus alone blocks a rebuild");
});

test("an unchanged selection does not have its value reassigned each second", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.follow": { mode: "pinned", pinnedSessionId: "sess_aaa11111",
      followedSessionId: "sess_aaa11111", reason: "pinned", released: null },
  }));
  assert.equal(panel.select.value, "sess_aaa11111", "the pinned session is selected");

  // Count writes to `value` across several renders.
  let writes = 0;
  let held = panel.select.value;
  Object.defineProperty(panel.select, "value", {
    get() { return held; },
    set(v) { writes += 1; held = v; },
    configurable: true,
  });
  for (let i = 0; i < 4; i += 1) await panel.renderTick();
  assert.equal(writes, 0, "the value is left alone while it is already correct");
  assert.equal(held, "sess_aaa11111");
});

test("a placeholder session is never offered as a pinnable option", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "真会话", agentName: "码农", lifecycle: "active", displayTitle: "真会话" },
      { sessionId: "unresolved:1d904175", title: null, agentName: null, lifecycle: "active", displayTitle: "未识别会话 · 1d904175" },
      { sessionId: "local-session-3", title: null, agentName: null, lifecycle: "active", displayTitle: "会话 · session-3" },
    ]},
  }));
  const values = panel.select.children.map((option) => option.value);
  assert.equal(values.includes("unresolved:1d904175"), false, "no unresolved placeholder option");
  assert.equal(values.includes("local-session-3"), false, "no legacy placeholder option");
  assert.deepEqual(values, ["", "sess_aaa11111"], "only the real session remains selectable");
});

test("a session failure is shown with its kind and code, and never a message", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.session-diagnostics": {
      schemaVersion: 1, observedAt: 1,
      list: { code: "APP_CAPABILITY_DENIED", kind: "permission", operation: "session:list" },
      get: null,
    },
  }));
  const status = panel.byId.get("session-status");
  assert.match(status.textContent, /会话清单不可用 · 原因：/);
  assert.match(status.textContent, /APP_CAPABILITY_DENIED/);
  assert.match(status.textContent, /缺少 app\/sessions\.read 授权/);
  assert.equal(status.dataset.state, "error");
  for (const leak of ["denied by", "/private", "Missing app"]) {
    assert.equal(status.textContent.includes(leak), false, `status leaks ${leak}`);
  }
});

test("a list success with a get failure never claims the session list is unavailable", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.session-diagnostics": {
      schemaVersion: 1, observedAt: 1,
      // Exactly the field shape read from the installed App's storage.
      list: null,
      get: { code: "APP_HOST_ERROR", kind: "host", operation: "session:get", selector: "path" },
    },
  }));
  const status = panel.byId.get("session-status");

  // The misleading sentence must be gone.
  assert.equal(status.textContent.includes("会话清单不可用"), false,
    "a get-only failure must not claim the session list is unavailable");
  assert.notEqual(status.dataset.state, "error", "a get-only failure is not an equal-severity warning");

  // It is still reported, but as a quiet caveat naming the failed operation.
  assert.match(status.textContent, /个别会话详情暂不可读/);
  assert.match(status.textContent, /按路径 查询/);
  assert.match(status.textContent, /APP_HOST_ERROR/);
  assert.match(status.textContent, /会话名称仍取自会话清单/);
  assert.equal(status.dataset.state, "info");
});

test("a get failure with an id selector is distinguished from a path one", async () => {
  const byId = await mountPanel(baseStore({
    "hana-pet.session-diagnostics": { schemaVersion: 1, observedAt: 1, list: null,
      get: { code: "RPC_TIMEOUT", kind: "timeout", operation: "session:get", selector: "id" } },
  }));
  assert.match(byId.byId.get("session-status").textContent, /按 ID 查询/);
  assert.equal(byId.byId.get("session-status").textContent.includes("会话清单不可用"), false);
});

test("archived sessions never appear in the picker, not even as disabled options", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "活跃会话", agentName: "码农", lifecycle: "active", displayTitle: "活跃会话" },
      { sessionId: "sess_old99999", title: "归档会话", agentName: "码农", lifecycle: "archived", displayTitle: "归档会话" },
    ]},
  }));
  const values = panel.select.children.map((option) => option.value);
  assert.equal(values.includes("sess_old99999"), false, "an archived session is not offered at all");
  assert.deepEqual(values, ["", "sess_aaa11111"], "only the active session plus the default");
  const text = panel.select.children.map((option) => option.textContent).join("|");
  assert.equal(text.includes("归档"), false, "no archived label leaks into the picker");
});

test("63 archived sessions next to one active still leave a usable, active-only picker", async () => {
  const archived = Array.from({ length: 63 }, (_, index) => ({
    sessionId: `sess_arch${String(index).padStart(4, "0")}`, title: `旧会话 ${index}`,
    agentName: "码农", lifecycle: "archived", displayTitle: `旧会话 ${index}`,
  }));
  const panel = await mountPanel(baseStore({
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "活跃会话", agentName: "码农", lifecycle: "active", displayTitle: "活跃会话" },
      ...archived,
    ]},
  }));
  const values = panel.select.children.map((option) => option.value);
  assert.deepEqual(values, ["", "sess_aaa11111"], "the active session survives; no archive is listed");
  assert.ok(panel.select.children.length <= 16, "the picker stays short");
});

test("the picker is capped and ordered by recent activity, never dropping the newest", async () => {
  const sessions = Array.from({ length: 20 }, (_, index) => ({
    sessionId: `sess_${String(index).padStart(3, "0")}`, title: `会话 ${index}`,
    lifecycle: "active", displayTitle: `会话 ${index}`,
  }));
  const activity = sessions.map((item, index) => ({
    sessionId: item.sessionId, title: item.title, status: "idle", running: false,
    lastActivityAt: 1000 + index * 10, statusAt: 0, displayTitle: item.title,
  }));
  const panel = await mountPanel(baseStore({
    "hana-pet.session-list": { available: true, sessions },
    "hana-pet.activity.snapshot": { revision: 1, observedAt: 1, sessions: activity, current: activity[activity.length - 1] },
  }));
  const values = panel.select.children.map((option) => option.value).filter(Boolean);
  assert.equal(values.length, 15, "capped at ~15 entries");
  assert.equal(values[0], "sess_019", "the most recently active session leads");
  assert.equal(values.includes("sess_000"), false, "the oldest activity falls out first");
});

test("a pinned archived session falls back to the default selection", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "活跃会话", lifecycle: "active", displayTitle: "活跃会话" },
      { sessionId: "sess_old99999", title: "归档会话", lifecycle: "archived", displayTitle: "归档会话" },
    ]},
    "hana-pet.follow": { mode: "pinned", pinnedSessionId: "sess_old99999",
      followedSessionId: "sess_old99999", reason: "pinned", released: null },
  }));
  assert.equal(panel.select.value, "", "an archived pin does not stay selected");
});

test("no failure means no diagnostic line", async () => {
  const panel = await mountPanel(baseStore());
  const status = panel.byId.get("session-status");
  assert.equal(status.textContent, "");
});

test("the panel mirrors the hint with its own label and validates the enum", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.activity.snapshot": { revision: 1, observedAt: 1,
      sessions: [], current: { sessionId: "sess_aaa11111", title: "T", agentName: "码农",
        status: "working", running: true, toolName: null, hint: "confirming",
        lastActivityAt: 1000, statusAt: 1000, displayTitle: "T" } },
  }));
  const hint = panel.byId.get("activity-hint");
  assert.equal(hint.textContent, "等待确认");
  assert.equal(hint.dataset.hint, "confirming");
});

test("an unknown hint value never reaches the panel", async () => {
  const panel = await mountPanel(baseStore({
    "hana-pet.activity.snapshot": { revision: 1, observedAt: 1,
      sessions: [], current: { sessionId: "sess_aaa11111", title: "T",
        status: "idle", running: false, hint: "<script>alert(1)</script>",
        lastActivityAt: 1000, statusAt: 1000, displayTitle: "T" } },
  }));
  const hint = panel.byId.get("activity-hint");
  assert.equal(hint.textContent, "");
  assert.equal(hint.dataset.hint, "none");
});

test("no hint means an empty, hidden pill", async () => {
  const panel = await mountPanel(baseStore());
  const hint = panel.byId.get("activity-hint");
  assert.equal(hint.textContent, "");
  assert.equal(hint.dataset.hint, "none");
});
