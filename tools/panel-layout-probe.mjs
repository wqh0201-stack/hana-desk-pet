#!/usr/bin/env node
/**
 * Real-browser layout probe for the control panel.
 *
 * The Node tests run the panel against a DOM stub, which cannot prove that five
 * rows fit in 560x664 or that nothing overflows. This probe serves the production
 * panel.html/panel.css/panel.js from a synthetic fixture (only ./sdk.js is
 * replaced with a local stub), drives headless Chrome over CDP, and measures the
 * real layout at the acceptance sizes.
 *
 * Nothing here touches a real Hana host, a real session, or the network beyond
 * 127.0.0.1. Chrome is already installed; nothing is downloaded.
 *
 *   node tools/panel-layout-probe.mjs
 *   CHROME_PATH=/path/to/chrome node tools/panel-layout-probe.mjs
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const UI_DIR = path.join(PROJECT_ROOT, "apps/hana-desktop-pet/ui");
const BUILD_DIR = path.join(PROJECT_ROOT, ".build/panel-probe");
const SITE_DIR = path.join(BUILD_DIR, "site");
const SHOT_DIR = path.join(BUILD_DIR, "shots");

const CHROME_CANDIDATES = [
  process.env.CHROME_PATH,
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  "/Applications/Chromium.app/Contents/MacOS/Chromium",
  "/usr/bin/google-chrome",
  "/usr/bin/chromium",
  "/usr/bin/chromium-browser",
].filter(Boolean);

function findChrome() {
  return CHROME_CANDIDATES.find((candidate) => {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return true;
    } catch {
      return false;
    }
  }) ?? null;
}

function copyFile(from, to) {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  fs.copyFileSync(from, to);
}

function linkDir(from, to) {
  fs.mkdirSync(path.dirname(to), { recursive: true });
  try { fs.rmSync(to, { recursive: true, force: true }); } catch { /* ignore */ }
  fs.symlinkSync(from, to, "dir");
}

const SDK_STUB = `// Synthetic host for the layout probe. Never talks to Hana.
const params = new URLSearchParams(location.search);
const scenario = params.get("scenario") ?? "normal";
const appearance = params.get("appearance");
const now = Date.now();

function makeSession(index, overrides = {}) {
  const id = "sess_" + String(index).padStart(3, "0") + "abcdef";
  return {
    sessionId: id,
    title: "会话 " + index,
    displayTitle: "会话 " + index,
    agentId: "codingagent",
    agentName: "码农",
    status: "idle",
    running: false,
    toolName: null,
    runEnded: false,
    lastActivityAt: now - index * 60000,
    statusAt: now - index * 60000,
    ...overrides,
  };
}

const LONG_TITLE = "整理插画素材与播放器前端审美审查的第二轮迭代";
const sessions = [];
for (let i = 1; i <= 7; i += 1) {
  sessions.push(makeSession(i, {
    title: i === 1 ? LONG_TITLE : i === 2 ? null : "会话 " + i,
    displayTitle: i === 1 ? LONG_TITLE : i === 2 ? null : "会话 " + i,
    status: i === 1 ? "tool" : i === 3 ? "working" : "idle",
    running: i === 1 || i === 3,
    toolName: i === 1 ? "read" : null,
    agentName: i === 2 ? null : i === 4 ? "Mona" : "码农",
  }));
}

const many = Array.from({ length: 15 }, (_, index) => makeSession(index + 1, {
  status: index === 0 ? "tool" : index === 2 ? "working" : "idle",
  running: index === 0 || index === 2,
  toolName: index === 0 ? "read" : null,
}));

function bridge(status, poseState) {
  return { status, reason: status === "offline" ? "unreachable" : null, poseState: poseState ?? null };
}

const pose = (characterId, pose, fallback = false) => ({
  schemaVersion: 4, characterId, pose, fallback, since: now - 12000, revision: 42,
});

const fixtures = {
  normal: {
    bridge: bridge("connected", pose("gpt", "thinking")),
    selection: "gpt",
    sessions,
    current: sessions[0],
    follow: { mode: "latest", pinnedSessionId: null, followedSessionId: sessions[0].sessionId, released: null },
  },
  many: {
    bridge: bridge("connected", pose("deepseek", "reading")),
    selection: "deepseek",
    sessions: many,
    current: many[0],
    follow: { mode: "latest", pinnedSessionId: null, followedSessionId: many[0].sessionId, released: null },
  },
  empty: {
    bridge: bridge("connected", null),
    selection: "claude",
    sessions: [],
    current: null,
    follow: { mode: "latest", pinnedSessionId: null, followedSessionId: null, released: null },
  },
  error: {
    bridge: bridge("offline", null),
    selection: "glm",
    sessions: sessions.slice(0, 6),
    current: sessions[0],
    follow: { mode: "latest", pinnedSessionId: null, followedSessionId: sessions[0].sessionId,
      released: { sessionId: "sess_old99999", reason: "pinned_archived", at: now } },
  },
  pinned: {
    bridge: bridge("connected", pose("glm", "sleeping")),
    selection: "glm",
    sessions,
    current: sessions[0],
    follow: { mode: "pinned", pinnedSessionId: sessions[0].sessionId,
      followedSessionId: sessions[0].sessionId, released: null },
  },
  // A pose drawn on the widest catalog canvas (730x640) must not shrink the pet.
  widepose: {
    bridge: bridge("connected", pose("gpt", "delegating")),
    selection: "gpt",
    sessions,
    current: sessions[0],
    follow: { mode: "latest", pinnedSessionId: null, followedSessionId: sessions[0].sessionId, released: null },
  },
};

const fixture = fixtures[scenario] ?? fixtures.normal;
const list = fixture.sessions.map((item) => ({
  sessionId: item.sessionId,
  title: item.title,
  agentName: item.agentName,
  lifecycle: "active",
}));

const store = {
  "hana-pet.bridge.enabled": true,
  "hana-pet.bridge.status": fixture.bridge,
  "hana-pet.activity.snapshot": {
    revision: 12,
    observedAt: now,
    sessions: fixture.sessions,
    current: fixture.current,
  },
  "hana-pet.session-list": { available: true, sessions: list },
  "hana-pet.follow": fixture.follow,
  "hana-pet.selection": { characterId: fixture.selection, updatedAt: 1, petRevision: 0 },
  "hana-pet.session-diagnostics": { list: null, get: null },
};

export const hana = {
  ready() {},
  theme: appearance
    ? { getSnapshot() { return { appearance }; }, subscribe() { return () => {}; } }
    : undefined,
  storage: {
    global: {
      async get(key) { return store[key]; },
      async set(key, value) { store[key] = value; },
      onChanged() { return () => {}; },
    },
  },
};
`;

function buildSite() {
  fs.rmSync(SITE_DIR, { recursive: true, force: true });
  fs.mkdirSync(path.join(SITE_DIR, "assets"), { recursive: true });
  copyFile(path.join(UI_DIR, "panel.html"), path.join(SITE_DIR, "panel.html"));
  for (const file of ["panel.css", "panel.js", "pose-index.js"]) {
    copyFile(path.join(UI_DIR, "assets", file), path.join(SITE_DIR, "assets", file));
  }
  fs.writeFileSync(path.join(SITE_DIR, "assets/sdk.js"), SDK_STUB);
  linkDir(path.join(UI_DIR, "assets/poses"), path.join(SITE_DIR, "assets/poses"));
  linkDir(path.join(UI_DIR, "assets/roles"), path.join(SITE_DIR, "assets/roles"));
}

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".webp": "image/webp",
  ".png": "image/png",
  ".svg": "image/svg+xml",
};

function startServer() {
  const server = http.createServer((request, response) => {
    const url = new URL(request.url, "http://127.0.0.1");
    const relative = decodeURIComponent(url.pathname === "/" ? "/panel.html" : url.pathname);
    const file = path.join(SITE_DIR, relative);
    fs.readFile(file, (error, data) => {
      if (error) {
        response.statusCode = 404;
        response.end("not found");
        return;
      }
      response.setHeader("content-type", MIME[path.extname(file)] ?? "application/octet-stream");
      response.end(data);
    });
  });
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve({ server, port: server.address().port }));
  });
}

function waitForHttp(url, timeoutMs = 10000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const tick = async () => {
      try {
        const response = await fetch(url);
        if (response.ok) return resolve();
      } catch { /* not ready yet */ }
      if (Date.now() - started > timeoutMs) return reject(new Error(`timeout waiting for ${url}`));
      setTimeout(tick, 120);
    };
    void tick();
  });
}

class Cdp {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    this.ready = new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", reject, { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (message.id && this.pending.has(message.id)) {
        const { resolve, reject } = this.pending.get(message.id);
        this.pending.delete(message.id);
        if (message.error) reject(new Error(message.error.message));
        else resolve(message.result);
        return;
      }
      for (const callback of this.listeners.get(message.method) ?? []) callback(message.params);
    });
  }

  async send(method, params = {}) {
    await this.ready;
    const id = this.nextId++;
    const promise = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.ws.send(JSON.stringify({ id, method, params }));
    return promise;
  }

  on(method, callback) {
    if (!this.listeners.has(method)) this.listeners.set(method, []);
    this.listeners.get(method).push(callback);
  }

  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

async function launchChrome(chromePath) {
  const profile = path.join(BUILD_DIR, "chrome-profile");
  fs.rmSync(profile, { recursive: true, force: true });
  const port = 45000 + Math.floor(Math.random() * 1000);
  const child = spawn(chromePath, [
    "--headless=new",
    "--disable-gpu",
    "--hide-scrollbars",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-extensions",
    `--user-data-dir=${profile}`,
    `--remote-debugging-port=${port}`,
    "about:blank",
  ], { stdio: ["ignore", "ignore", "pipe"] });
  const versionUrl = `http://127.0.0.1:${port}/json/version`;
  await waitForHttp(versionUrl);
  const version = await (await fetch(versionUrl)).json();
  return { child, port, browserWs: version.webSocketDebuggerUrl };
}

async function newPage(port) {
  const response = await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: "PUT" });
  const target = await response.json();
  return target.webSocketDebuggerUrl;
}

const MEASURE = `(() => {
  const rect = (element) => {
    if (!element) return null;
    const box = element.getBoundingClientRect();
    return { top: box.top, bottom: box.bottom, left: box.left, right: box.right, width: box.width, height: box.height };
  };
  const list = document.querySelector("#sessions");
  const listBox = list.getBoundingClientRect();
  const rows = [...document.querySelectorAll("#sessions .session")].map((row) => {
    const button = row.querySelector("button");
    const box = row.getBoundingClientRect();
    return {
      title: button?.querySelector(".session-title")?.textContent ?? null,
      followed: button?.dataset.followed === "true",
      pinned: button?.getAttribute("aria-pressed") === "true",
      top: box.top,
      bottom: box.bottom,
      fullyVisible: box.top >= listBox.top - 0.5 && box.bottom <= listBox.bottom + 0.5,
      pill: button?.querySelector(".status-pill")?.textContent ?? null,
      markers: [...(button?.querySelectorAll(".session-marker") ?? [])].filter((m) => !m.hidden).map((m) => m.textContent),
    };
  });
  const roles = [...document.querySelectorAll("#role-options .role-option")].map((button) => {
    const box = button.getBoundingClientRect();
    const image = button.querySelector("img");
    const imageBox = image.getBoundingClientRect();
    return {
      id: button.dataset.roleId,
      top: box.top, bottom: box.bottom, left: box.left, right: box.right,
      visible: box.top >= 0 && box.bottom <= innerHeight && box.left >= 0 && box.right <= innerWidth,
      pressed: button.getAttribute("aria-pressed") === "true",
      name: button.querySelector(".role-name")?.textContent ?? null,
      thumb: {
        width: Math.round(imageBox.width * 10) / 10,
        height: Math.round(imageBox.height * 10) / 10,
        natural: image.naturalWidth + "x" + image.naturalHeight,
        fit: getComputedStyle(image).objectFit,
        position: getComputedStyle(image).objectPosition,
      },
    };
  });
  const followedButton = document.querySelector('#sessions .session-button[data-followed="true"]');
  const plainButton = document.querySelector('#sessions .session-button:not([data-followed="true"])');
  const grid = document.querySelector(".diagnostic-grid");
  const gridBox = grid.getBoundingClientRect();
  const style = (element) => element ? getComputedStyle(element) : null;
  const colors = {
    bodyBg: style(document.body).backgroundColor,
    bodyText: style(document.body).color,
    muted: style(document.querySelector("#agent")).color,
    surface: style(document.querySelector(".stage")).backgroundColor,
    followedBg: followedButton ? style(followedButton).backgroundColor : null,
    plainBg: plainButton ? style(plainButton).backgroundColor : null,
    followedTitle: followedButton ? style(followedButton.querySelector(".session-title")).color : null,
    stageTitle: style(document.querySelector("#role-title")).color,
  };
  return {
    viewport: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
    document: {
      scrollWidth: document.documentElement.scrollWidth,
      scrollHeight: document.documentElement.scrollHeight,
      clientWidth: document.documentElement.clientWidth,
      clientHeight: document.documentElement.clientHeight,
    },
    list: {
      ...rect(list),
      scrollHeight: list.scrollHeight,
      clientHeight: list.clientHeight,
      scrollTop: list.scrollTop,
      rowCount: rows.length,
      visibleRows: rows.filter((row) => row.fullyVisible).length,
      maxHeight: list.style.maxHeight || null,
    },
    sessionPanel: {
      ...rect(document.querySelector(".session-panel")),
      compact: document.querySelector(".session-panel").classList.contains("is-compact"),
    },
    controller: rect(document.querySelector(".controller")),
    sections: [...document.querySelector(".controller").children].map((child) => ({
      className: child.className,
      height: Math.round(child.getBoundingClientRect().height * 100) / 100,
      display: getComputedStyle(child).display,
    })),
    stageArt: rect(document.querySelector(".stage-art")),
    stageCopy: rect(document.querySelector(".stage-copy")),
    stageFrame: rect(document.querySelector(".stage-image-frame")),
    stageImageBox: rect(document.querySelector("#stage-image")),
    stageColumns: getComputedStyle(document.querySelector(".stage")).gridTemplateColumns,
    frameWidthStyle: getComputedStyle(document.querySelector(".stage-image-frame")).width,
    followTargetHeight: rect(document.querySelector("#follow-target"))?.height ?? null,
    rows,
    emptyNodes: document.querySelectorAll("#sessions .empty").length,
    roles,
    stage: rect(document.querySelector(".stage")),
    stageImage: rect(document.querySelector("#stage-image")),
    followTarget: document.querySelector("#follow-target")?.textContent ?? null,
    roleTitle: document.querySelector("#role-title")?.textContent ?? null,
    bridgeState: document.querySelector("#bridge-state")?.textContent ?? null,
    poseConnection: document.querySelector("#pose-connection")?.textContent ?? null,
    diagnosticsSummary: rect(document.querySelector(".diagnostics summary")),
    toggle: rect(document.querySelector(".toggle")),
    diagnosticsOpen: document.querySelector(".diagnostics")?.open === true,
    diagnosticsGrid: grid ? { height: gridBox.height, scrollHeight: grid.scrollHeight, overflowY: style(grid).overflowY } : null,
    colors,
  };
})()`;

const STABILITY = `(async () => {
  const list = document.querySelector("#sessions");
  const buttons = [...document.querySelectorAll("#sessions .session-button")];
  if (buttons.length < 3) return { skipped: true };
  const target = buttons[2];
  window.__probeTarget = target;
  window.__probeFirst = list.firstElementChild;
  target.focus({ preventScroll: true });
  list.scrollTop = 24;
  const before = list.scrollTop;
  await new Promise((resolve) => setTimeout(resolve, 10500));
  return {
    skipped: false,
    activePreserved: document.activeElement === window.__probeTarget,
    rowNodePreserved: list.firstElementChild === window.__probeFirst,
    before,
    after: list.scrollTop,
    ticks: 10,
  };
})()`;

function contrastRatio(rgbA, rgbB) {
  const parse = (value) => {
    const match = /rgba?\(([^)]+)\)/.exec(value ?? "");
    if (match) {
      const [r, g, b] = match[1].split(",").map((part) => parseFloat(part));
      return [r, g, b];
    }
    // Chrome serialises color-mix() results as color(srgb 0.1 0.2 0.3).
    const srgb = /color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)/.exec(value ?? "");
    if (srgb) return [srgb[1], srgb[2], srgb[3]].map((part) => parseFloat(part) * 255);
    return null;
  };
  const luminance = (rgb) => {
    const [r, g, b] = rgb.map((channel) => {
      const value = channel / 255;
      return value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const a = parse(rgbA);
  const b = parse(rgbB);
  if (!a || !b) return null;
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

const CASES = [
  { name: "560x664-light", width: 560, height: 664, scenario: "normal", theme: "light" },
  { name: "560x664-dark", width: 560, height: 664, scenario: "normal", theme: "dark" },
  { name: "560x664-pinned", width: 560, height: 664, scenario: "pinned", theme: "light" },
  { name: "560x664-widepose", width: 560, height: 664, scenario: "widepose", theme: "light" },
  { name: "560x664-error", width: 560, height: 664, scenario: "error", theme: "light" },
  { name: "560x664-empty", width: 560, height: 664, scenario: "empty", theme: "light" },
  { name: "420x640-light", width: 420, height: 640, scenario: "normal", theme: "light" },
  { name: "420x640-error", width: 420, height: 640, scenario: "error", theme: "light" },
  { name: "560x560-light", width: 560, height: 560, scenario: "normal", theme: "light" },
  { name: "560x720-light", width: 560, height: 720, scenario: "normal", theme: "light" },
  { name: "760x900-light", width: 760, height: 900, scenario: "many", theme: "light" },
  { name: "390x640-light", width: 390, height: 640, scenario: "normal", theme: "light" },
];

const failures = [];
function check(condition, message) {
  if (!condition) failures.push(message);
}

async function run() {
  const chromePath = findChrome();
  if (!chromePath) {
    console.log("PANEL_LAYOUT_SKIP no Chrome binary found (set CHROME_PATH to enable)");
    return 0;
  }
  fs.rmSync(BUILD_DIR, { recursive: true, force: true });
  fs.mkdirSync(SHOT_DIR, { recursive: true });
  buildSite();
  const { server, port } = await startServer();
  const chrome = await launchChrome(chromePath);
  let cdp = null;
  const results = [];
  try {
    cdp = new Cdp(await newPage(chrome.port));
    await cdp.send("Page.enable");
    await cdp.send("Runtime.enable");

    for (const item of CASES) {
      await cdp.send("Emulation.setDeviceMetricsOverride", {
        width: item.width, height: item.height, deviceScaleFactor: 2, mobile: false,
      });
      await cdp.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-color-scheme", value: item.theme }],
      });
      const url = `http://127.0.0.1:${port}/panel.html?scenario=${item.scenario}&theme=${item.theme}`;
      await cdp.send("Page.navigate", { url });
      const ready = await (async () => {
        const started = Date.now();
        while (Date.now() - started < 8000) {
          const result = await cdp.send("Runtime.evaluate", {
            expression: "document.readyState === 'complete' && document.querySelectorAll('#role-options .role-option').length === 7",
            returnByValue: true,
          });
          if (result.result.value === true) return true;
          await new Promise((resolve) => setTimeout(resolve, 80));
        }
        return false;
      })();
      check(ready, `${item.name}: panel did not become ready`);
      if (!ready) continue;

      if (item.name === "560x664-light") {
        await cdp.send("Runtime.evaluate", { expression: "document.querySelector('.diagnostics').open = true" });
        await new Promise((resolve) => setTimeout(resolve, 150));
        const withDiagnostics = await cdp.send("Runtime.evaluate", {
          expression: MEASURE, returnByValue: true,
        });
        const value = withDiagnostics.result.value;
        results.push({ name: `${item.name}-diagnostics-open`, ...value });
        check(value.document.scrollHeight <= value.viewport.height + 1,
          `${item.name} diagnostics open: page overflows vertically (${value.document.scrollHeight} > ${value.viewport.height})`);
        check(value.diagnosticsGrid && value.diagnosticsGrid.overflowY === "auto",
          `${item.name} diagnostics open: details area is not the documented internal scroller`);
        check(value.list.visibleRows >= 2,
          `${item.name} diagnostics open: only ${value.list.visibleRows} session rows remain`);
        const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
        fs.writeFileSync(path.join(SHOT_DIR, `${item.name}-diagnostics-open.png`), Buffer.from(shot.data, "base64"));
        await cdp.send("Runtime.evaluate", { expression: "document.querySelector('.diagnostics').open = false" });
        await new Promise((resolve) => setTimeout(resolve, 120));
      }

      const measured = await cdp.send("Runtime.evaluate", { expression: MEASURE, returnByValue: true });
      const value = measured.result.value;
      results.push({ name: item.name, ...value });
      const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
      fs.writeFileSync(path.join(SHOT_DIR, `${item.name}.png`), Buffer.from(shot.data, "base64"));

      check(value.document.scrollWidth <= value.viewport.width + 1,
        `${item.name}: horizontal page overflow (${value.document.scrollWidth} > ${value.viewport.width})`);
      check(value.document.scrollHeight <= value.viewport.height + 1,
        `${item.name}: vertical page overflow (${value.document.scrollHeight} > ${value.viewport.height})`);
      check(value.roles.length === 7, `${item.name}: expected 7 role buttons, saw ${value.roles.length}`);
      if (value.list.rowCount > 0) {
        check(value.emptyNodes === 0, `${item.name}: a stale empty placeholder is still in the list`);
      }
      check(value.roles.every((role) => role.visible), `${item.name}: a role button is outside the viewport`);
      check(value.roles.filter((role) => role.pressed).length === 1,
        `${item.name}: selected role is not unique`);
      check(Boolean(value.diagnosticsSummary), `${item.name}: diagnostics entry missing`);
      check(value.stageImageBox && value.stageImageBox.width >= 40 && value.stageImageBox.height >= 40,
        `${item.name}: stage image collapsed (${value.stageImageBox?.width}x${value.stageImageBox?.height})`);
      check(value.stageImageBox && value.stageImageBox.bottom <= value.viewport.height + 1,
        `${item.name}: stage image pushed out of view`);
      check(value.toggle && value.toggle.right <= value.viewport.width + 1 && value.toggle.bottom <= value.viewport.height + 1,
        `${item.name}: connection toggle is pushed out of view`);
      check(value.diagnosticsSummary.bottom <= value.viewport.height + 1,
        `${item.name}: diagnostics entry pushed out of view`);

      if (item.name === "560x664-light" || item.name === "560x664-dark" || item.name === "420x640-light") {
        const expected = item.name === "420x640-light" ? 4 : 5;
        check(value.list.visibleRows >= expected,
          `${item.name}: only ${value.list.visibleRows} complete session rows (expected >= ${expected})`);
      }
      if (item.scenario === "normal" || item.scenario === "pinned" || item.scenario === "widepose") {
        check(value.followTarget?.startsWith("跟随会话："), `${item.name}: follow target is missing`);
        check(value.roleTitle?.length > 0, `${item.name}: role title is missing`);
        check(value.rows.filter((row) => row.followed).length === 1,
          `${item.name}: exactly one row must be marked as followed`);
        check(value.rows.filter((row) => row.markers.length > 0).length === 1,
          `${item.name}: only the followed row may carry a follow marker`);
      }
      if (item.scenario === "pinned") {
        check(value.rows.some((row) => row.pinned && row.markers.includes("已固定")),
          `${item.name}: pinned row is not marked as pinned`);
      }
      if (item.scenario === "error") {
        check(value.bridgeState === "连接失败", `${item.name}: offline label is ${value.bridgeState}`);
        check(value.poseConnection === "静态预览", `${item.name}: offline pose caption is ${value.poseConnection}`);
      }
      if (item.theme === "dark") {
        const body = contrastRatio(value.colors.bodyText, value.colors.bodyBg);
        const muted = contrastRatio(value.colors.muted, value.colors.surface);
        const followed = contrastRatio(value.colors.followedTitle, value.colors.followedBg);
        check(body !== null && body >= 4.5, `${item.name}: body contrast ${body?.toFixed(2)}`);
        check(muted !== null && muted >= 4.5, `${item.name}: muted contrast ${muted?.toFixed(2)}`);
        check(followed !== null && followed >= 4.5, `${item.name}: followed title contrast ${followed?.toFixed(2)}`);
      }
      if (item.name === "560x664-light") {
        check(value.colors.followedBg !== value.colors.plainBg,
          `${item.name}: followed row has no distinct background`);
      }
    }

    // A pose on the widest catalog canvas must not resize the stage or the pet.
    const normalStage = results.find((item) => item.name === "560x664-light");
    const wideStage = results.find((item) => item.name === "560x664-widepose");
    if (normalStage && wideStage) {
      check(Math.abs(wideStage.stage.height - normalStage.stage.height) <= 0.5,
        `wide pose changes the stage height (${wideStage.stage.height} vs ${normalStage.stage.height})`);
      check(Math.abs(wideStage.stageImageBox.height - normalStage.stageImageBox.height) <= 0.5,
        `wide pose changes the canvas height (${wideStage.stageImageBox.height} vs ${normalStage.stageImageBox.height})`);
      check(Math.abs(normalStage.stageImageBox.width - 164) <= 0.5,
        `stage canvas width is ${normalStage.stageImageBox.width}, expected 164`);
    }

    // Host appearance must win over the system preference.
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 560, height: 664, deviceScaleFactor: 2, mobile: false,
    });
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-color-scheme", value: "light" }],
    });
    await cdp.send("Page.navigate", {
      url: `http://127.0.0.1:${port}/panel.html?scenario=normal&appearance=dark`,
    });
    await new Promise((resolve) => setTimeout(resolve, 500));
    const hostTheme = await cdp.send("Runtime.evaluate", {
      expression: "({ appearance: document.documentElement.dataset.appearance, bg: getComputedStyle(document.body).backgroundColor })",
      returnByValue: true,
    });
    check(hostTheme.result.value.appearance === "dark",
      "host appearance=dark did not override the light system preference");
    check(contrastRatio(hostTheme.result.value.bg, hostTheme.result.value.bg) === 1,
      "host appearance probe returned an unreadable background");

    // Focus and scroll must survive the one-second tick.
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 560, height: 664, deviceScaleFactor: 2, mobile: false,
    });
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-color-scheme", value: "light" }],
    });
    await cdp.send("Page.navigate", { url: `http://127.0.0.1:${port}/panel.html?scenario=many&theme=light` });
    await new Promise((resolve) => setTimeout(resolve, 700));
    const stability = await cdp.send("Runtime.evaluate", {
      expression: STABILITY, awaitPromise: true, returnByValue: true,
    });
    const stable = stability.result.value;
    results.push({ name: "stability-560x664-many", ...stable });
    if (!stable.skipped) {
      check(stable.activePreserved, "keyboard focus was lost across the one-second tick");
      check(stable.rowNodePreserved, "session rows were rebuilt across the one-second tick");
      check(stable.after === stable.before, `list scroll jumped from ${stable.before} to ${stable.after}`);
    }
  } finally {
    cdp?.close();
    chrome.child.kill("SIGTERM");
    server.close();
  }

  const summary = results.map((item) => ({
    name: item.name,
    viewport: item.viewport ? `${item.viewport.width}x${item.viewport.height}` : null,
    visibleRows: item.list?.visibleRows ?? null,
    rowCount: item.list?.rowCount ?? null,
    listHeight: item.list?.height ?? null,
    listMaxHeight: item.list?.maxHeight ?? null,
    sessionPanelHeight: item.sessionPanel?.height ?? null,
    compact: item.sessionPanel?.compact ?? null,
    stageHeight: item.stage?.height ?? null,
    stageCopyHeight: item.stageCopy?.height ?? null,
    stageFrameHeight: item.stageFrame?.height ?? null,
    stageFrameWidth: item.stageFrame?.width ?? null,
    stageImageBox: item.stageImageBox ? `${Math.round(item.stageImageBox.width)}x${Math.round(item.stageImageBox.height)}` : null,
    stageColumns: item.stageColumns ?? null,
    frameWidthStyle: item.frameWidthStyle ?? null,
    sections: item.sections?.map((section) => `${section.className}:${section.height}`).join(",") ?? null,
    controllerHeight: item.controller?.height ?? null,
    rowHeight: item.rows?.[0] ? Math.round((item.rows[0].bottom - item.rows[0].top) * 100) / 100 : null,
    pageScroll: item.document ? `${item.document.scrollWidth}x${item.document.scrollHeight}` : null,
    roleTitle: item.roleTitle ?? null,
    bridgeState: item.bridgeState ?? null,
    poseConnection: item.poseConnection ?? null,
    followed: item.rows?.filter((row) => row.followed).length ?? null,
    focusPreserved: item.activePreserved ?? null,
    rowNodePreserved: item.rowNodePreserved ?? null,
    scrollBefore: item.before ?? null,
    scrollAfter: item.after ?? null,
  }));
  console.log(JSON.stringify({ shots: SHOT_DIR, cases: summary }, null, 2));

  if (failures.length) {
    for (const failure of failures) console.error("FAIL " + failure);
    console.error(`PANEL_LAYOUT_FAIL ${failures.length} check(s)`);
    return 1;
  }
  console.log("PANEL_LAYOUT_OK");
  return 0;
}

run().then((code) => process.exit(code)).catch((error) => {
  console.error("PANEL_LAYOUT_ERROR", error);
  process.exit(1);
});
