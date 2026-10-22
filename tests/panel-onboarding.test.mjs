/**
 * A 路专项：控制台未连接时的桌宠下载/启动引导。
 *
 * 这里只跑合成状态：连接关闭 / 连接中 / 已连接 / unreachable /
 * version_mismatch / invalid_response / 状态不可读，以及宿主拒权后的可复制
 * 降级。DOM 用 stub，真实布局由 tools/panel-onboarding-probe.mjs 在浏览器里测。
 *
 * 不连接真实会话，不调用真实宿主，不写任何真实存储。
 */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const PANEL_SOURCE = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.js", "utf8");
const PANEL_HTML = fs.readFileSync("apps/hana-desktop-pet/ui/panel.html", "utf8");
const PANEL_CSS = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.css", "utf8");

// 仓库里最新的桌宠版本，来自各端的单一来源：
// Windows 在 pet-windows/version.json，macOS 在 Resources/Info.plist（CFBundleShortVersionString）。
const WINDOWS_VERSION = JSON.parse(
  fs.readFileSync("pet-windows/version.json", "utf8")).version;
const MAC_VERSION = fs.readFileSync("pet-macos/Resources/Info.plist", "utf8")
  .match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];
assert.ok(WINDOWS_VERSION, "pet-windows/version.json exposes a version");
assert.ok(MAC_VERSION, "Info.plist exposes CFBundleShortVersionString");

// 控制台实际下载的那一对（0.6.8 的配对）。
// 这里钉的是「控制台指向的版本」，而不是仓库里最新的桌宠版本；下面的断言会保证
// 仓库里的桌宠只会比它新、不会比它旧。
const PINNED_WINDOWS_VERSION = "0.3.1";
const PINNED_MAC_VERSION = "0.5.10";

const WINDOWS_URL =
  `https://github.com/wqh0201-stack/hana-desk-pet/releases/download/windows-${PINNED_WINDOWS_VERSION}/HanaDesktopPet-windows-${PINNED_WINDOWS_VERSION}-portable.zip`;
const MAC_URL =
  `https://github.com/wqh0201-stack/hana-desk-pet/releases/download/pet-${PINNED_MAC_VERSION}/HanaDesktopPet-crosspet-v${PINNED_MAC_VERSION}-local.zip`;

/** Numeric per-part comparison so a patch bump never counts as "older". */
function compareVersions(left, right) {
  const a = String(left).split(".").map((part) => Number.parseInt(part, 10) || 0);
  const b = String(right).split(".").map((part) => Number.parseInt(part, 10) || 0);
  for (let index = 0; index < Math.max(a.length, b.length); index += 1) {
    const x = a[index] ?? 0;
    const y = b[index] ?? 0;
    if (x !== y) return x > y ? 1 : -1;
  }
  return 0;
}
// 这两条是协议 v3 时代的旧入口；v4 候选不得再出现。
const RETIRED_URLS = [
  "https://github.com/wqh0201-stack/hana-desk-pet/releases/download/windows-0.2.0/HanaDesktopPet-windows-0.2.0-portable.zip",
  "https://github.com/wqh0201-stack/hana-desk-pet/releases/download/console-0.6.5/HanaDesktopPet-crosspet-v0.5.8-local.zip",
];

function makeStore(overrides = {}) {
  return {
    "hana-pet.bridge.enabled": true,
    "hana-pet.bridge.status": { status: "connecting", reason: null, poseState: null },
    "hana-pet.activity.snapshot": { revision: 1, observedAt: 1, sessions: [], current: null },
    "hana-pet.session-list": { available: true, sessions: [] },
    "hana-pet.follow": { mode: "latest", pinnedSessionId: null, followedSessionId: null, released: null },
    "hana-pet.selection": { characterId: "claude", updatedAt: 1, petRevision: 0 },
    ...overrides,
  };
}

async function mountPanel(store, { external, failReads = false } = {}) {
  const byId = new Map();
  const listeners = new Map();
  let focusedId = null;

  function el(tag = "div") {
    const node = {
      tagName: tag, children: [], _text: "", value: "", checked: false, disabled: false,
      hidden: false, dataset: {}, style: { setProperty() {} }, className: "", attributes: {},
      parentNode: null,
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
      focus() { focusedId = this.id ?? null; },
    };
    return node;
  }

  const document = {
    getElementById(id) {
      if (!byId.has(id)) {
        const node = el();
        node.id = id;
        byId.set(id, node);
      }
      return byId.get(id);
    },
    createElement: (tag) => el(tag),
    createDocumentFragment: () => el("fragment"),
    querySelector: () => null,
    addEventListener() {},
    createRange() {
      return { selectNodeContents() {} };
    },
    get activeElement() { return null; },
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
      getSelection: () => ({ removeAllRanges() {}, addRange() {} }),
    },
    console: { ...console, warn() {} },
    Date, Math, Number, JSON, Array, Object, String, Set, Map, Promise, isFinite,
  };
  sandbox.globalThis = sandbox;

  const changeListeners = [];
  const hanaStub = {
    ready() {},
    storage: {
      global: {
        async get(key) {
          if (failReads) throw new Error("synthetic host read failure");
          return store[key];
        },
        async set(key, value) { store[key] = value; },
        onChanged(callback) { changeListeners.push(callback); return () => {}; },
      },
    },
    ...(external ? { external } : {}),
  };

  const patched = PANEL_SOURCE
    .replace('import { hana } from "./sdk.js";', "")
    .replace('import { POSE_INDEX } from "./pose-index.js";', "");
  const wrapped = `(async () => { const hana = __hana; const POSE_INDEX = __poseIndex; ${patched} })()`;
  const context = vm.createContext({ ...sandbox, __hana: hanaStub, __poseIndex: { roles: {} } });
  await vm.runInContext(wrapped, context, { filename: "panel.js" });
  await settle();

  async function settle() {
    for (let i = 0; i < 6; i += 1) await new Promise((resolve) => setImmediate(resolve));
  }

  return {
    store,
    byId,
    text(id) { return byId.get(id)?.textContent ?? null; },
    hidden(id) { return byId.get(id)?.hidden ?? null; },
    state(id) { return byId.get(id)?.dataset?.state ?? null; },
    focusedId() { return focusedId; },
    async push(keys) {
      for (const callback of changeListeners) callback(keys);
      await settle();
    },
    async click(id) {
      const node = byId.get(id);
      const handlers = listeners.get(node)?.get("click") ?? [];
      let prevented = false;
      for (const handler of handlers) {
        handler({ preventDefault() { prevented = true; }, stopPropagation() {} });
      }
      await settle();
      return prevented;
    },
  };
}

const offline = (reason) => ({ "hana-pet.bridge.status": { status: "offline", reason, poseState: null } });

test("with the connection switched off the guide asks for the toggle first", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.enabled": false,
    "hana-pet.bridge.status": "disabled",
  }));
  assert.equal(panel.hidden("pet-onboarding"), false);
  assert.match(panel.text("onboarding-lead"), /「本机连接」/);
  assert.equal(panel.state("pet-onboarding"), "disabled");
  // Both platforms stay visible; the panel never guesses the host OS.
  assert.equal(panel.hidden("download-windows"), false);
  assert.equal(panel.hidden("download-mac"), false);
});

test("connecting shows progress and never a failure sentence", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "connecting", reason: null, poseState: null },
  }));
  assert.equal(panel.hidden("pet-onboarding"), false);
  assert.equal(panel.text("onboarding-lead"), "正在连接本机桌宠…");
  assert.equal(panel.state("pet-onboarding"), "connecting");
  assert.doesNotMatch(panel.text("onboarding-lead"), /失败|没连上|未安装/);
  assert.equal(panel.hidden("onboarding-fallback"), true);
});

test("an unreachable pet asks to start the downloaded pet before offering downloads", async () => {
  const panel = await mountPanel(makeStore(offline("unreachable")));
  assert.equal(panel.hidden("pet-onboarding"), false);
  const lead = panel.text("onboarding-lead");
  assert.ok(lead.indexOf("先打开它") < lead.indexOf("按系统选一个版本"),
    "start-before-download order");
  assert.match(panel.text("bridge-state"), /连接失败/);
  assert.equal(panel.state("pet-onboarding"), "offline");
  // "not connected" is never asserted as "not installed".
  assert.doesNotMatch(lead, /未安装|没有安装|尚未安装/);
});

test("version and response errors keep their real reason plus the matching next step", async () => {
  for (const [reason, barLabel, barNote, step] of [
    ["version_mismatch", /版本不匹配/, /配套版本/, /配套版本/],
    ["invalid_response", /回应异常/, /回应异常/, /重启桌宠/],
  ]) {
    const panel = await mountPanel(makeStore(offline(reason)));
    // The connection bar keeps the truthful label and explanation; the guide adds
    // only the action, so the two lines never duplicate the same sentence.
    assert.match(panel.text("bridge-state"), barLabel);
    assert.match(panel.text("connection-note"), barNote);
    assert.match(panel.text("onboarding-lead"), step);
    assert.doesNotMatch(panel.text("onboarding-lead"), /未安装|没有安装/);
    // The download entries remain reachable for every failure reason.
    assert.equal(panel.hidden("pet-onboarding"), false);
  }
});

test("an unknown failure reason falls back to the generic start-then-download copy", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "offline", reason: "something_else", poseState: null },
  }));
  assert.match(panel.text("onboarding-lead"), /先打开它|按系统选一个版本/);
});

test("a healthy connection folds the main guide away", async () => {
  const panel = await mountPanel(makeStore({
    "hana-pet.bridge.status": { status: "connected", reason: null, poseState: null },
  }));
  assert.equal(panel.hidden("pet-onboarding"), true);
  assert.equal(panel.text("onboarding-lead"), "");
});

test("switching between states never leaves the previous guide behind", async () => {
  const panel = await mountPanel(makeStore(offline("unreachable")));
  assert.equal(panel.state("pet-onboarding"), "offline");

  panel.store["hana-pet.bridge.status"] = { status: "connecting", reason: null, poseState: null };
  await panel.push(["hana-pet.bridge.status"]);
  assert.equal(panel.state("pet-onboarding"), "connecting");
  assert.equal(panel.text("onboarding-lead"), "正在连接本机桌宠…");

  panel.store["hana-pet.bridge.status"] = { status: "connected", reason: null, poseState: null };
  await panel.push(["hana-pet.bridge.status"]);
  assert.equal(panel.hidden("pet-onboarding"), true);

  panel.store["hana-pet.bridge.enabled"] = false;
  panel.store["hana-pet.bridge.status"] = "disabled";
  await panel.push(["hana-pet.bridge.enabled", "hana-pet.bridge.status"]);
  assert.equal(panel.hidden("pet-onboarding"), false);
  assert.equal(panel.state("pet-onboarding"), "disabled");

  panel.store["hana-pet.bridge.enabled"] = true;
  panel.store["hana-pet.bridge.status"] = { status: "offline", reason: "version_mismatch", poseState: null };
  await panel.push(["hana-pet.bridge.enabled", "hana-pet.bridge.status"]);
  assert.equal(panel.state("pet-onboarding"), "offline");
  assert.match(panel.text("bridge-state"), /版本不匹配/);
  assert.match(panel.text("onboarding-lead"), /配套版本/);
});

test("unreadable host state is not dressed up as a connection verdict", async () => {
  const panel = await mountPanel(makeStore(), { failReads: true });
  assert.equal(panel.text("bridge-state"), "状态暂不可读");
  assert.equal(panel.hidden("pet-onboarding"), false);
  assert.equal(panel.state("pet-onboarding"), "unknown");
  assert.match(panel.text("onboarding-lead"), /状态暂时读不到/);
  assert.doesNotMatch(panel.text("onboarding-lead"), /连接失败|已连接|未安装/);
  // Downloads stay available; the panel simply stops guessing.
  assert.equal(panel.hidden("download-windows"), false);
  assert.equal(panel.hidden("download-mac"), false);
});

test("both download entries open only their own fixed HTTPS release URL", async () => {
  const opened = [];
  const panel = await mountPanel(makeStore(offline("unreachable")), {
    external: { open(payload) { opened.push(payload); return Promise.resolve({ opened: true }); } },
  });

  const windowsPrevented = await panel.click("download-windows");
  const macPrevented = await panel.click("download-mac");

  assert.equal(windowsPrevented, true, "the anchor click is handled by the panel, not the iframe");
  assert.equal(macPrevented, true);
  assert.equal(JSON.stringify(opened), JSON.stringify([{ url: WINDOWS_URL }, { url: MAC_URL }]));
  for (const payload of opened) {
    const url = new URL(payload.url);
    assert.equal(url.protocol, "https:");
    assert.equal(url.hostname, "github.com");
  }
  assert.equal(panel.hidden("onboarding-fallback"), true);
});

test("a denied external open falls back to a selectable copy of the same URL", async () => {
  const panel = await mountPanel(makeStore(offline("unreachable")), {
    external: {
      open() {
        return Promise.reject(Object.assign(new Error("App requires the UI capability external.open."),
          { code: "CAPABILITY_DENIED" }));
      },
    },
  });

  await panel.click("download-windows");

  assert.equal(panel.hidden("onboarding-fallback"), false);
  assert.equal(panel.text("onboarding-fallback-url"), WINDOWS_URL);
  assert.match(panel.text("onboarding-fallback-text"), /Windows 版/);
  assert.equal(panel.focusedId(), "onboarding-fallback-url");
  // The guide itself still explains the connection; the fallback is additive.
  assert.equal(panel.hidden("pet-onboarding"), false);
});

test("a host without external.open degrades instead of silently doing nothing", async () => {
  const panel = await mountPanel(makeStore(offline("unreachable")));
  await panel.click("download-mac");
  assert.equal(panel.hidden("onboarding-fallback"), false);
  assert.equal(panel.text("onboarding-fallback-url"), MAC_URL);
});

test("connecting again clears a stale fallback instead of keeping a dead link", async () => {
  const panel = await mountPanel(makeStore(offline("unreachable")), {
    external: { open() { return Promise.reject(new Error("denied")); } },
  });
  await panel.click("download-windows");
  assert.equal(panel.hidden("onboarding-fallback"), false);

  panel.store["hana-pet.bridge.status"] = { status: "connected", reason: null, poseState: null };
  await panel.push(["hana-pet.bridge.status"]);
  assert.equal(panel.hidden("pet-onboarding"), true);
  assert.equal(panel.hidden("onboarding-fallback"), true);
  assert.equal(panel.text("onboarding-fallback-url"), "");
});

test("both download entries agree in panel.js and panel.html and track the shipped versions", () => {
  // 上一版回归：控制台已是 v4，两个入口却还指向 v3 的 0.2.0 / 0.5.8。
  // 这里把「允许列表」「静态备用链接」「各端版本来源」三处钉在一起。
  const block = PANEL_SOURCE.slice(PANEL_SOURCE.indexOf("const PET_DOWNLOADS"),
    PANEL_SOURCE.indexOf("const nodes = {"));
  const entries = Object.fromEntries([...block.matchAll(
    /(windows|mac): Object\.freeze\(\{\s*url: "([^"]+)"/g)].map(([, platform, url]) => [platform, url]));
  assert.deepEqual(entries, { windows: WINDOWS_URL, mac: MAC_URL },
    "PET_DOWNLOADS carries exactly the current v4 assets");

  const hrefs = Object.fromEntries([...PANEL_HTML.matchAll(
    /<a\b[^>]*id="download-(windows|mac)"[^>]*href="([^"]+)"/g)]
    .map(([, platform, href]) => [platform, href]));
  assert.deepEqual(hrefs, entries, "the static fallback links match the allow-list exactly");

  for (const url of RETIRED_URLS) {
    assert.ok(!PANEL_SOURCE.includes(url), `panel.js still offers a v3 download: ${url}`);
    assert.ok(!PANEL_HTML.includes(url), `panel.html still offers a v3 download: ${url}`);
  }
  assert.ok(!PANEL_HTML.includes("windows-0.2.0"), "the install copy must not name the retired release");
});

test("the repo's desktop builds are never older than the versions the console downloads", () => {
  // 桌宠可以先打补丁版（0.3.1 / 0.5.10），控制台等下次发版再指过去；但不能反过来：
  // 控制台已经指向的版本，仓库里必须真的存在。
  assert.ok(compareVersions(WINDOWS_VERSION, PINNED_WINDOWS_VERSION) >= 0,
    `Windows sources ${WINDOWS_VERSION} are older than the pinned ${PINNED_WINDOWS_VERSION}`);
  assert.ok(compareVersions(MAC_VERSION, PINNED_MAC_VERSION) >= 0,
    `macOS sources ${MAC_VERSION} are older than the pinned ${PINNED_MAC_VERSION}`);
});

test("the static markup keeps link semantics, both platforms, and the short install steps", () => {
  const anchors = [...PANEL_HTML.matchAll(/<a\b[^>]*id="(download-[a-z]+)"[^>]*>/g)];
  assert.equal(anchors.length, 2, "exactly two platform entries");
  assert.match(PANEL_HTML, /id="download-windows"[\s\S]*?下载 Windows 版/);
  assert.match(PANEL_HTML, /id="download-mac"[\s\S]*?下载 macOS 版/);
  assert.ok(PANEL_HTML.includes(WINDOWS_URL), "Windows href is the v4 companion asset");
  assert.ok(PANEL_HTML.includes(MAC_URL), "macOS href is the v4 companion asset");
  assert.doesNotMatch(PANEL_HTML, /releases\/latest/, "no /releases/latest shortcut");
  assert.doesNotMatch(PANEL_HTML, /HanaDesktopPet\.exe"/, "never link a bare exe");
  for (const href of [WINDOWS_URL, MAC_URL]) {
    assert.match(href, /releases\/download\/[^/]+\/[^/]+\.zip$/);
  }
  // Short install path, both platforms, and the same-machine requirement.
  assert.match(PANEL_HTML, /下载对应系统的 zip 并解压/);
  assert.match(PANEL_HTML, /Windows 双击 exe/);
  assert.match(PANEL_HTML, /macOS 右键 → 打开 \.app/);
  assert.match(PANEL_HTML, /同一台电脑上，在 Hana 控制台打开「本机连接」/);
  assert.match(PANEL_HTML, /不必关闭安全防护/);
  assert.match(PANEL_HTML, /安装说明/, "the detailed help entry exists");
  // The Windows release is described as a release link, never as a live download.
  assert.ok(PANEL_HTML.includes(`windows-${PINNED_WINDOWS_VERSION}`), "the install note names the release the console downloads");
  // 不得把「打不开」归因成「还没上线」：网络/权限/浏览器失败都不等于未发布。
  assert.doesNotMatch(PANEL_HTML, /还没上线/);
  assert.doesNotMatch(PANEL_HTML, /打不开就是/);
  assert.doesNotMatch(PANEL_HTML, /未发布|尚未发布|等待发布/);
  // 只保留可校验的来源提示与系统安全提示。
  assert.ok(PANEL_HTML.includes(`核对下载来源是 Release「windows-${PINNED_WINDOWS_VERSION}」`),
    "the security note names the release the console downloads");
  assert.doesNotMatch(PANEL_HTML, /插件市场|已上架|market/);
});

test("the panel exposes no network, download or install capability of its own", async () => {
  // The guide is display + link only: no fetch, no GitHub API, no local-machine.
  const constants = PANEL_SOURCE.slice(PANEL_SOURCE.indexOf("const PET_DOWNLOADS"),
    PANEL_SOURCE.indexOf("const nodes = {"));
  const behaviour = PANEL_SOURCE.slice(PANEL_SOURCE.indexOf("function onboardingModel"),
    PANEL_SOURCE.indexOf("function render() {"));
  assert.ok(constants.length > 0 && behaviour.length > 0, "the onboarding section is locatable");
  const guideSource = constants + behaviour;
  assert.doesNotMatch(guideSource, /fetch\(/);
  assert.doesNotMatch(guideSource, /api\.github\.com/);
  assert.doesNotMatch(guideSource, /local-machine/);
  assert.doesNotMatch(guideSource, /clipboard/);
  assert.doesNotMatch(PANEL_SOURCE, /hana\.[\w.]*openExternal/);
  assert.doesNotMatch(PANEL_SOURCE, /window\.open\(/);
  // Only the static allow-list may be opened.
  assert.equal((PANEL_SOURCE.match(/const PET_DOWNLOADS/g) ?? []).length, 1);
  const openCalls = [...PANEL_SOURCE.matchAll(/\.open\(([^)]*)\)/g)].filter(([, args]) => /url:/.test(args));
  assert.equal(openCalls.length, 1);
  assert.match(openCalls[0][1], /url: entry\.url/);
  // Both allow-list entries are https GitHub release assets and nothing else.
  for (const match of PANEL_SOURCE.matchAll(/url: "(https:[^"]+)"/g)) {
    assert.match(match[1], /^https:\/\/github\.com\/wqh0201-stack\/hana-desk-pet\/releases\/download\//);
  }
});

test("the onboarding styles stay inside the existing bridge variables", () => {
  const block = PANEL_CSS.match(/\.pet-onboarding\s*\{([^}]*)\}/)?.[1] ?? "";
  assert.match(block, /var\(--hk-/);
  assert.doesNotMatch(block, /#[0-9a-f]{3,8}\b|rgba?\(/i);
  assert.match(PANEL_CSS, /\.download-link:focus-visible/);
  assert.match(PANEL_CSS, /\.onboarding-fallback-url/);
  assert.match(PANEL_CSS, /@media \(max-width: 390px\) \{[\s\S]*?\.pet-onboarding/,
    "narrow windows get their own onboarding padding");
});
