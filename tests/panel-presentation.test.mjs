/**
 * Presentation contract for the control panel.
 *
 * These checks pin the parts of the redesign that are easy to regress without a
 * browser: which name the stage shows, when a pose may be called live, how a
 * tool result differs from a finished run, and that the visible vocabulary never
 * leaks raw pose ids. The DOM here is a stub; layout is covered by the browser
 * probe in tools/panel-layout-probe.mjs.
 */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const PANEL_SOURCE = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.js", "utf8");
const POSE_INDEX_SOURCE = fs.readFileSync("apps/hana-desktop-pet/ui/assets/pose-index.js", "utf8");
const { POSE_INDEX } = await import(`data:text/javascript;base64,${Buffer.from(POSE_INDEX_SOURCE).toString("base64")}`);

function makeStore(overrides = {}) {
  const now = Date.now();
  return {
    "hana-pet.bridge.enabled": true,
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: null },
    "hana-pet.activity.snapshot": {
      revision: 7,
      observedAt: now,
      sessions: [],
      current: null,
    },
    "hana-pet.session-list": { available: true, sessions: [] },
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: null, released: null },
    "hana-pet.selection": { characterId: "claude", updatedAt: 1, petRevision: 0 },
    ...overrides,
  };
}

async function mountPanel(store) {
  const byId = new Map();
  const made = [];
  const listeners = new Map();
  let activeElement = null;

  function el(tag = "div") {
    const node = {
      tagName: tag, children: [], _text: "", value: "", checked: false, disabled: false,
      hidden: false, dataset: {}, style: { setProperty() {} }, className: "", attributes: {},
      parentNode: null,
      _replaceCount: 0,
      classList: { add() {}, remove() {}, toggle() {} },
      get textContent() { return this._text; },
      set textContent(value) { this._text = String(value); },
      get firstElementChild() { return this.children[0] ?? null; },
      append(...kids) { for (const kid of kids) { this.children.push(kid); kid.parentNode = this; } },
      appendChild(kid) { this.children.push(kid); kid.parentNode = this; return kid; },
      insertBefore(child, reference) {
        const index = reference ? this.children.indexOf(reference) : -1;
        if (index >= 0) this.children.splice(index, 0, child);
        else this.children.push(child);
        child.parentNode = this;
        return child;
      },
      remove() {
        const parent = this.parentNode;
        if (!parent) return;
        const index = parent.children.indexOf(this);
        if (index >= 0) parent.children.splice(index, 1);
        this.parentNode = null;
      },
      replaceChildren(...kids) {
        this._replaceCount += 1;
        this.children = kids.flatMap((kid) => (kid && kid.tagName === "fragment" ? kid.children : [kid]));
        for (const kid of this.children) kid.parentNode = this;
      },
      addEventListener(type, callback) {
        if (!listeners.has(this)) listeners.set(this, new Map());
        const own = listeners.get(this);
        if (!own.has(type)) own.set(type, []);
        own.get(type).push(callback);
      },
      setAttribute(name, value) { this.attributes[name] = String(value); },
      getAttribute(name) { return this.attributes[name] ?? null; },
      removeAttribute(name) { delete this.attributes[name]; },
    };
    made.push(node);
    return node;
  }

  const document = {
    getElementById(id) { if (!byId.has(id)) byId.set(id, el()); return byId.get(id); },
    createElement: (tag) => el(tag),
    createDocumentFragment: () => el("fragment"),
    get activeElement() { return activeElement; },
  };

  const timers = [];
  const sandbox = {
    document,
    window: {
      setInterval: (callback) => { timers.push(callback); return timers.length; },
      clearInterval() {},
      setTimeout: () => 1,
      clearTimeout() {},
      addEventListener() {},
      matchMedia: () => ({ matches: false }),
    },
    console,
    Date, Math, Number, JSON, Array, Object, String, Set, Map, Promise, isFinite,
  };
  sandbox.globalThis = sandbox;

  const changeListeners = [];
  const writes = [];
  const failWrites = new Set();
  const hanaStub = {
    ready() {},
    storage: {
      global: {
        async get(key) { return store[key]; },
        async set(key, value) {
          if (failWrites.has(key)) throw new Error("synthetic write failure");
          writes.push({ key, value });
          store[key] = value;
        },
        onChanged(callback) { changeListeners.push(callback); return () => {}; },
      },
    },
  };

  const patched = PANEL_SOURCE
    .replace('import { hana } from "./sdk.js";', "")
    .replace('import { POSE_INDEX } from "./pose-index.js";', "");
  const wrapped = `(async () => { const hana = __hana; const POSE_INDEX = __poseIndex; ${patched} })()`;
  const context = vm.createContext({ ...sandbox, __hana: hanaStub, __poseIndex: POSE_INDEX });
  await vm.runInContext(wrapped, context, { filename: "panel.js" });
  await settle();

  async function settle() {
    for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
  }

  return {
    store,
    byId,
    writes,
    failWrites,
    text(id) { return byId.get(id)?.textContent ?? null; },
    attr(id, name) { return byId.get(id)?.getAttribute(name) ?? null; },
    hidden(id) { return byId.get(id)?.hidden ?? null; },
    setActive(node) { activeElement = node; },
    async pushStorage(keys = ["hana-pet.activity.snapshot"]) {
      for (const callback of changeListeners) callback(keys);
      await settle();
    },
    /** Run the panel's own one-second tick, which only re-renders. */
    async tick() {
      const callback = timers[timers.length - 1];
      if (callback) callback();
      await settle();
    },
    rows() { return byId.get("sessions").children; },
    rowButton(index) { return byId.get("sessions").children[index]?.children[0] ?? null; },
    sessionReplaceCount() { return byId.get("sessions")._replaceCount; },
    click(id) {
      const handler = byId.get(id)?.handlers?.click;
      if (handler) handler();
      return settle();
    },
    fire(node, type) {
      const own = listeners.get(node);
      for (const callback of own?.get(type) ?? []) callback({});
      return settle();
    },
  };
}

function session(overrides = {}) {
  return {
    sessionId: "sess_aaa11111",
    title: "整理插画素材",
    displayTitle: "整理插画素材",
    agentId: "codingagent",
    agentName: "码农",
    status: "working",
    running: true,
    toolName: "read",
    runEnded: false,
    lastActivityAt: Date.now() - 12000,
    statusAt: Date.now() - 12000,
    ...overrides,
  };
}

function snapshotOf(sessions, current = sessions[0] ?? null) {
  return { revision: 9, observedAt: Date.now(), sessions, current };
}

test("the stage headline is the role name, not the session title", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session()]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", agentName: "码农", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
    "hana-pet.selection": { characterId: "gpt", updatedAt: 1, petRevision: 0 },
  }));
  assert.equal(panel.text("role-title"), "GPT 白龙");
  assert.equal(panel.text("follow-target"), "跟随会话：整理插画素材");
  assert.match(panel.text("agent"), /^码农 · /);
  // The relative time appears once in the stage, not again in a second line.
  const stageText = ["role-title", "follow-target", "agent", "activity-status", "pose-name", "pose-connection"]
    .map((id) => panel.text(id)).join("|");
  assert.equal(stageText.split("前").length - 1, 1, "only one relative timestamp is shown");
  assert.equal(panel.text("pose-connection"), "等待姿态同步 · 静态预览");
  assert.equal(panel.byId.get("sessions").children.length, 1);
});

test("a validated readback supplies the name, the image and the pose label together", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: {
      schemaVersion: 3, characterId: "claude", pose: "reading-2", fallback: false, since: Date.now() - 5000, revision: 12,
    } },
    "hana-pet.selection": { characterId: "deepseek", updatedAt: 1, petRevision: 0 },
  }));
  assert.equal(panel.text("role-title"), "Claude");
  assert.equal(panel.byId.get("stage-image").src, "./assets/poses/claude/reading-2.webp");
  assert.equal(panel.text("pose-name"), "阅读");
  assert.equal(panel.text("pose-connection"), "实时姿态");
  // The strip keeps showing the user's target while the stage shows the readback.
  assert.equal(panel.byId.get("role-options").children
    .filter((button) => button.getAttribute("aria-pressed") === "true")
    .map((button) => button.dataset.roleId).join(","), "deepseek");
  assert.equal(panel.hidden("role-sync"), false);
  assert.match(panel.text("role-sync"), /已选 DeepSeek 大肥鱼，等待桌宠同步/);
});

test("a tool success never claims the run ended; an ended run may", async () => {
  const toolSuccess = session({ status: "success", running: true, runEnded: false, statusAt: Date.now(), lastActivityAt: 2000 });
  const ended = session({ status: "success", running: false, runEnded: true, statusAt: Date.now(), lastActivityAt: 1000 });
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([toolSuccess, { ...ended, sessionId: "sess_bbb22222" }]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
      { sessionId: "sess_bbb22222", title: "发布构建", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  assert.equal(panel.text("activity-status"), "操作成功");
  assert.equal(panel.byId.get("sessions").children[0].children[0].children[1].textContent, "操作成功");
  assert.equal(panel.byId.get("sessions").children[1].children[0].children[1].textContent, "本轮结束");

  // Once the short feedback window expires, the real state takes over again.
  const expired = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session({ status: "success", running: false, runEnded: true,
      statusAt: Date.now() - 5000 })]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  assert.equal(expired.text("activity-status"), "空闲");
});

test("a fallback readback is labelled as a substitute pose and keeps raw fields in diagnostics", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: {
      schemaVersion: 3, characterId: "glm", pose: "sleeping", fallback: true, since: 1700000000000, revision: 33,
    } },
  }));
  assert.equal(panel.hidden("pose-fallback"), false);
  assert.equal(panel.text("pose-name"), "打盹");
  assert.equal(panel.text("diag-pose-role"), "glm");
  assert.equal(panel.text("diag-pose-name"), "sleeping");
  assert.equal(panel.text("diag-pose-fallback"), "是");
  assert.equal(panel.text("diag-pose-revision"), "33");
  assert.notEqual(panel.text("diag-pose-since"), "—");
});

test("without a live readback the diagnostics never pretend to have one", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: null },
  }));
  for (const id of ["diag-pose-role", "diag-pose-name", "diag-pose-fallback", "diag-pose-revision", "diag-pose-since"]) {
    assert.equal(panel.text(id), "—", `${id} must stay empty without a readback`);
  }
  assert.equal(panel.text("pose-connection"), "等待姿态同步 · 静态预览");
});

test("a disconnected console uses the selected role and says it is a static preview", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.enabled": false,
    "hana-pet.bridge.status": "disabled",
    "hana-pet.selection": { characterId: "gpt-onesie", updatedAt: 1, petRevision: 0 },
  }));
  assert.equal(panel.text("role-title"), "GPT 降智龙崽");
  assert.equal(panel.byId.get("stage-image").src, "./assets/poses/gpt-onesie/idle.webp");
  assert.equal(panel.text("pose-connection"), "静态预览");
  assert.equal(panel.text("bridge-state"), "连接已关闭");
  assert.equal(panel.hidden("connection-note"), true);
});

test("connection failures use short labels with the explanation in the note line", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "offline", reason: "version_mismatch", poseState: null },
  }));
  assert.equal(panel.text("bridge-state"), "版本不匹配");
  assert.equal(panel.hidden("connection-note"), false);
  assert.match(panel.text("connection-note"), /配套版本/);
  assert.equal(panel.text("pose-connection"), "静态预览");
});

test("the followed row is marked in both follow modes and carries only one status pill", async () => {
  const sessions = [
    session({ sessionId: "sess_aaa11111", title: "整理插画素材", lastActivityAt: 2000 }),
    session({ sessionId: "sess_bbb22222", title: "发布构建", status: "idle", running: false, toolName: null, lastActivityAt: 1000 }),
  ];
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf(sessions),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
      { sessionId: "sess_bbb22222", title: "发布构建", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_bbb22222", released: null },
  }));
  const rows = panel.rows();
  assert.equal(rows.length, 2);
  assert.equal(rows[0].children[0].dataset.followed, "false");
  assert.equal(rows[1].children[0].dataset.followed, "true");
  assert.equal(rows[1].children[0].getAttribute("aria-pressed"), "false", "a followed row is not a pinned row");
  assert.equal(rows[1].children[0].children[2].hidden, false);
  assert.equal(rows[1].children[0].children[2].textContent, "跟随中");
  assert.equal(rows[1].children[0].children[1].textContent, "空闲");
  // No legacy “当前” capsule anywhere in the visible list.
  assert.equal(rows.some((row) => row.children[0].children.some((part) => part.textContent === "当前")), false);
});

test("a pinned target is marked as pinned, not merely followed", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session({ lastActivityAt: 2000 })]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "pinned", pinnedSessionId: "sess_aaa11111",
      followedSessionId: "sess_aaa11111", released: null },
  }));
  const button = panel.rowButton(0);
  assert.equal(button.getAttribute("aria-pressed"), "true");
  assert.equal(button.dataset.followed, "true");
  assert.equal(button.children[2].textContent, "已固定");
});

test("visible text never exposes raw pose ids; diagnostics still locate the exact image", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: {
      schemaVersion: 3, characterId: "claude", pose: "happy-2", fallback: false, since: Date.now(), revision: 3,
    } },
  }));
  const visible = ["role-title", "follow-target", "agent", "activity-status", "pose-name", "pose-connection"]
    .map((id) => panel.text(id)).join("|");
  assert.equal(/happy-2|\bidle\b|\bthinking\b/.test(visible), false);
  assert.equal(panel.text("pose-name"), "开心");
  assert.equal(panel.text("diag-pose-name"), "happy-2");
});

test("every catalogued pose the panel accepts has a Chinese label or a neutral one", async () => {
  const labels = new Set();
  const panel = await mountPanel(makeStore());
  for (const roleId of Object.keys(POSE_INDEX.roles)) {
    for (const pose of POSE_INDEX.roles[roleId]) {
      panel.store["hana-pet.bridge.status"] = { status: "connected", reason: null, poseState: {
        schemaVersion: 3, characterId: roleId, pose, fallback: false, since: Date.now(), revision: 1,
      } };
      await panel.pushStorage(["hana-pet.bridge.status"]);
      labels.add(panel.text("pose-name"));
      assert.equal(panel.byId.get("stage-image").src, `./assets/poses/${roleId}/${pose}.webp`);
      assert.equal(/^[a-z0-9-]+$/.test(panel.text("pose-name")), false,
        `${roleId}/${pose} leaked its raw id into the stage`);
    }
  }
  assert.ok(labels.has("待机") && labels.has("被拎起") && labels.has("实时姿态"),
    "named poses, pick-up frames and unlabelled poses all resolve");
});

test("the list updates in place: same node, same focus, no rebuild every second", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session(), session({ sessionId: "sess_bbb22222", title: "发布构建", lastActivityAt: 1000 })]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
      { sessionId: "sess_bbb22222", title: "发布构建", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  const button = panel.rowButton(1);
  panel.setActive(button);
  const before = panel.sessionReplaceCount();
  for (let i = 0; i < 10; i += 1) await panel.tick();
  assert.equal(panel.rowButton(1), button, "the row node survives a second of ticks");
  assert.equal(panel.sessionReplaceCount(), before, "the list is not rebuilt on time updates");
});

test("a removed session is gone after the next render and never resurrected", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session()]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  assert.equal(panel.rows().length, 1);
  panel.store["hana-pet.session-list"] = { available: true, sessions: [] };
  panel.store["hana-pet.activity.snapshot"] = snapshotOf([], null);
  await panel.pushStorage(["hana-pet.session-list", "hana-pet.activity.snapshot"]);
  assert.equal(panel.rows().length, 1);
  assert.equal(panel.rows()[0].className, "empty");
  await panel.tick();
  assert.equal(panel.rows().length, 1, "the empty placeholder does not multiply");
});

test("missing title and agent fall back safely without inventing names", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session({ title: null, displayTitle: null, agentName: null, agentId: null })]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: null, lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  assert.match(panel.text("follow-target"), /^跟随会话：会话 · aaa11111$/);
  assert.match(panel.text("agent"), /^Agent 未知 · /);
});

test("a title containing markup is rendered as text, never parsed", async () => {
  const title = '<img src=x onerror="alert(1)"> 会话';
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session({ title, displayTitle: title })]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title, lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  assert.equal(panel.text("follow-target"), `跟随会话：${title}`);
  assert.equal(panel.byId.get("sessions").children[0].children[0].children[0].children[0].textContent, title);
});

test("a role whose storage write fails restores the previous selection", async () => {
  const store = makeStore({ "hana-pet.selection": { characterId: "claude", updatedAt: 1, petRevision: 0 } });
  const panel = await mountPanel(store);
  panel.failWrites.add("hana-pet.selection");
  const glm = panel.byId.get("role-options").children.find((button) => button.dataset.roleId === "glm");
  await panel.fire(glm, "click");
  assert.equal(store["hana-pet.selection"].characterId, "claude", "the failed write is rolled back");
  assert.equal(panel.text("role-title"), "Claude");
  assert.match(panel.text("panel-notice"), /角色切换未能保存/);
});

test("a follow write failure restores the previous follow mode", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.activity.snapshot": snapshotOf([session(), session({ sessionId: "sess_bbb22222", title: "发布构建", lastActivityAt: 1000 })]),
    "hana-pet.session-list": { available: true, sessions: [
      { sessionId: "sess_aaa11111", title: "整理插画素材", lifecycle: "active" },
      { sessionId: "sess_bbb22222", title: "发布构建", lifecycle: "active" },
    ]},
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: "sess_aaa11111", released: null },
  }));
  panel.failWrites.add("hana-pet.follow.request");
  await panel.fire(panel.rowButton(1), "click");
  assert.equal(panel.text("follow-mode"), "自动跟随");
  assert.match(panel.text("panel-notice"), /固定会话请求未能保存/);
});

test("a connection toggle write failure restores the previous connection state", async () => {
  const store = makeStore({
    "hana-pet.bridge.enabled": true,
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: null },
  });
  const panel = await mountPanel(store);
  const toggle = panel.byId.get("bridge-toggle");
  panel.failWrites.add("hana-pet.bridge.enabled");
  toggle.checked = false;
  await panel.fire(toggle, "change");
  assert.equal(store["hana-pet.bridge.enabled"], true);
  assert.equal(panel.text("bridge-state"), "已连接");
  assert.equal(panel.byId.get("bridge-toggle").checked, true);
  assert.match(panel.text("panel-notice"), /连接开关未能保存/);
});
