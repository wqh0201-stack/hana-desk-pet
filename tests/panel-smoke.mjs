import assert from "node:assert/strict";
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
let themeSnapshot = {
  theme: "warm-paper", appearance: "light",
  ...(process.env.PANEL_THEME_INITIAL_CSS ? { cssUrl: process.env.PANEL_THEME_INITIAL_CSS } : {}),
};
let themeSubscriber = null;
const themeFetches = [];
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
  documentElement: el("html"),
  head: el("head"),
  getElementById(id) { if (!byId.has(id)) byId.set(id, el()); return byId.get(id); },
  createElement: (t) => el(t),
  createDocumentFragment: () => el("fragment"),
  querySelector(selector) {
    if (selector === "style[data-hana-theme-style]") {
      return this.head.children.find((node) => Object.hasOwn(node.attributes, "data-hana-theme-style")) ?? null;
    }
    return null;
  },
};
let storageChange = null;
const failWrites = new Set();
const sandbox = {
  document,
  window: {
    setInterval: () => 1, clearInterval() {},
    setTimeout: () => 1, clearTimeout() {},
    addEventListener() {},
    matchMedia: () => ({ matches: false }),
    async fetch(url, options) {
      themeFetches.push({ url, options });
      const bg = String(url).endsWith("dark.css") ? "#14242d" : "#F8F4ED";
      return { ok: true, async text() { return `:root{--bg:${bg}}`; } };
    },
  },
  console,
  Date, Math, Number, JSON, Array, Object, String, Set, Map, Promise, isFinite,
};
sandbox.globalThis = sandbox;

const hanaStub = {
  ready() {},
  theme: {
    getSnapshot() { return { ...themeSnapshot }; },
    subscribe(callback) {
      themeSubscriber = callback;
      callback({ ...themeSnapshot });
      return () => { themeSubscriber = null; };
    },
  },
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
// An automatic release is never reported as the user cancelling the pin.
if (!followReleaseNotice.textContent.includes("已自动解除固定") ||
    followReleaseNotice.textContent.includes("已取消固定")) ok = false;
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

assert.equal(document.documentElement.dataset.appearance, "light",
  "initial host appearance is reflected on the document root");
assert.equal(themeFetches.length, themeSnapshot.cssUrl ? 1 : 0,
  "an initial host CSS URL is fetched once; a missing URL leaves the local fallback in place");
if (themeSnapshot.cssUrl) {
  assert.equal(themeFetches[0].url, themeSnapshot.cssUrl);
  assert.match(document.querySelector("style[data-hana-theme-style]")?.textContent ?? "", /--bg:#F8F4ED/);
}
const palettePair = {
  light: { theme: "paper", cssUrl: "https://theme.invalid/light.css" },
  dark: { theme: "slate", cssUrl: "https://theme.invalid/dark.css" },
};
themeSubscriber?.({ theme: "slate", appearance: "dark", palettes: palettePair });
await new Promise((r) => setTimeout(r, 10));
let themeStyle = document.querySelector("style[data-hana-theme-style]");
assert.equal(document.documentElement.dataset.appearance, "dark");
assert.equal(themeFetches.at(-1)?.url, palettePair.dark.cssUrl,
  "palette-only theme snapshots select the CSS matching appearance");
assert.equal(themeFetches.at(-1)?.options?.credentials, "same-origin");
assert.match(themeStyle?.textContent ?? "", /--bg:#14242d/);
themeSubscriber?.({ theme: "paper", appearance: "light", palettes: palettePair });
await new Promise((r) => setTimeout(r, 10));
themeStyle = document.querySelector("style[data-hana-theme-style]");
assert.equal(document.documentElement.dataset.appearance, "light");
assert.equal(themeFetches.at(-1)?.url, palettePair.light.cssUrl);
assert.match(themeStyle?.textContent ?? "", /--bg:#F8F4ED/);

const panelCss = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.css", "utf8");
const stageRule = panelCss.match(/\.stage\s*\{([^}]*)\}/)?.[1] ?? "";
const narrowStageRule = panelCss.match(/@media\s*\(max-width:\s*390px\)[\s\S]*?\.stage\s*\{([^}]*)\}/)?.[1] ?? "";
assert.match(stageRule, /display:\s*grid;/, "stage uses a bounded grid");
assert.match(stageRule, /grid-template-columns:\s*128px\s+minmax\(0,\s*1fr\);/);
assert.match(stageRule, /overflow:\s*hidden;/, "stage clips paint to its border");
assert.match(narrowStageRule, /grid-template-columns:\s*minmax\(0,\s*1fr\);/, "narrow stage stacks vertically");
assert.match(panelCss, /(?:^|\n)img\s*\{\s*max-width:\s*100%;\s*height:\s*auto;\s*\}/m, "all images have a responsive width cap");

for (const [bridge, host, fallback] of [
  ["bg", "bg", "bg"], ["surface", "bg-card", "surface"], ["text", "text", "text"],
  ["muted", "text-muted", "muted"], ["light", "text-light", "light"],
  ["accent", "accent", "accent"], ["border", "border", "border"],
]) {
  assert.ok(panelCss.includes(`--hk-${bridge}: var(--${host}, var(--fallback-${fallback}));`),
    `host ${host} must win over the ${fallback} fallback`);
}
assert.match(panelCss, /@media\s*\(prefers-color-scheme:\s*dark\)/, "system dark fallback exists");
assert.match(panelCss, /--hk-accent-readable:\s*color-mix\(in srgb, var\(--hk-accent\) 74%, var\(--hk-text\)\)/,
  "accent text is derived for readable contrast");
assert.match(panelCss, /--hk-accent-fill:\s*color-mix\(in srgb, var\(--hk-accent\) 90%, var\(--hk-text\)\)/,
  "accent fills preserve contrast for foreground text");
assert.match(panelCss, /:root\[data-appearance="dark"\]\s*\{\s*color-scheme:\s*dark;/,
  "host appearance controls native dark controls and accent foreground");
assert.match(panelCss, /:root\[data-appearance="light"\]\s*\{\s*color-scheme:\s*light;/,
  "host appearance controls native light controls");
const componentCss = panelCss
  .replace(/:root\s*\{[^{}]*\}/g, "")
  .replace(/:root\[data-appearance=\"(?:dark|light)\"\]\s*\{[^{}]*\}/g, "");
assert.doesNotMatch(componentCss,
  /\b(?:color|background(?:-color)?|border(?:-[a-z-]+)?|outline(?:-color)?|box-shadow|scrollbar-color|accent-color)\s*:[^;{}]*(?:#[0-9a-f]{3,8}\b|rgba?\()/i,
  "component colors must come through bridge variables");

function fallbackTokens(block) {
  return Object.fromEntries([...block.matchAll(/(--fallback-[\w-]+)\s*:\s*(#[0-9a-f]{6})\s*;/gi)]
    .map(([, name, value]) => [name.slice("--fallback-".length), value]));
}
function contrastRatio(left, right) {
  const luminance = (hex) => {
    const [r, g, b] = hex.slice(1).match(/../g).map((value) => parseInt(value, 16) / 255)
      .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const a = luminance(left), b = luminance(right);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}
function mixSrgbHex(left, right, leftShare) {
  const leftChannels = left.slice(1).match(/../g).map((value) => parseInt(value, 16));
  const rightChannels = right.slice(1).match(/../g).map((value) => parseInt(value, 16));
  return `#${leftChannels.map((value, index) =>
    Math.round(value * leftShare + rightChannels[index] * (1 - leftShare)).toString(16).padStart(2, "0"))
    .join("")}`;
}
const lightRoot = panelCss.match(/:root\s*\{([^{}]*)\}/)?.[1] ?? "";
const darkRoot = panelCss.match(/@media\s*\(prefers-color-scheme:\s*dark\)\s*\{\s*:root\s*\{([^{}]*)\}/)?.[1] ?? "";
const lightPalette = fallbackTokens(lightRoot);
for (const [key, value] of Object.entries({
  bg: "#F8F4ED", surface: "#FCFAF5", text: "#3B3D3F", muted: "#6B6158", accent: "#537D96",
  "success-text": "#48664A", "warning-text": "#6F531F", "error-text": "#854747",
})) assert.equal(lightPalette[key], value, `warm-paper fallback ${key}`);
assert.match(lightRoot, /--fallback-border:\s*rgba\(122,\s*96,\s*88,\s*0\.18\)/i);
const slatePalette = fallbackTokens(darkRoot);
assert.equal(slatePalette.bg, "#14242d", "deep-slate fallback is preserved");
for (const [name, block] of [["light", lightRoot], ["dark", darkRoot]]) {
  const p = fallbackTokens(block);
  for (const [fg, bg] of [
    ["text", "bg"], ["text", "surface"], ["muted", "bg"], ["muted", "surface"],
    ["light", "bg"], ["light", "surface"],
    ["neutral-text", "neutral-bg"], ["info-text", "info-bg"], ["success-text", "success-bg"],
    ["warning-text", "warning-bg"], ["error-text", "error-bg"],
    ["status-success", "bg"], ["status-warning", "bg"], ["status-error", "bg"],
  ]) {
    const ratio = contrastRatio(p[fg], p[bg]);
    assert.ok(ratio >= 4.5, `${name} ${fg} on ${bg} contrast is ${ratio.toFixed(2)}:1`);
  }
  const accentReadable = mixSrgbHex(p.accent, p.text, 0.74);
  const accentFill = mixSrgbHex(p.accent, p.text, 0.90);
  const readableRatio = contrastRatio(accentReadable, p.surface);
  const fillRatio = contrastRatio(p["on-accent"], accentFill);
  assert.ok(readableRatio >= 4.5,
    `${name} readable accent on surface contrast is ${readableRatio.toFixed(2)}:1`);
  assert.ok(fillRatio >= 4.5,
    `${name} on-accent on derived fill contrast is ${fillRatio.toFixed(2)}:1`);
}
console.log("PANEL_LAYOUT_THEME_CONTRACT_OK");
console.log(ok ? "PANEL_SMOKE_OK" : "PANEL_SMOKE_FAIL");
process.exit(ok ? 0 : 1);
