#!/usr/bin/env node
/**
 * Real-browser probe for the connection onboarding (A 路专项).
 *
 * The Node test proves the state machine against a DOM stub; this probe proves the
 * guide actually fits. It serves the production panel.html/panel.css/panel.js from
 * a synthetic site (only ./sdk.js is replaced), drives headless Chrome over CDP and
 * measures the real layout for every connection state at the acceptance sizes.
 *
 * Nothing here touches a real Hana host, a real session or the network: the stub
 * answers `hana.storage` locally and rejects/accepts `hana.external.open` on demand.
 *
 *   node tools/panel-onboarding-probe.mjs
 *   CHROME_PATH=/path/to/chrome node tools/panel-onboarding-probe.mjs
 */
import { spawn } from "node:child_process";
import fs from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";

const PROJECT_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const UI_DIR = path.join(PROJECT_ROOT, "apps/hana-desktop-pet/ui");
const BUILD_DIR = path.join(PROJECT_ROOT, ".build/panel-onboarding-probe");
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

const SDK_STUB = `// Synthetic host for the onboarding probe. Never talks to Hana.
const params = new URLSearchParams(location.search);
const scenario = params.get("scenario") ?? "connecting";
const deny = params.get("deny") === "1";
const now = Date.now();
window.__openCalls = [];

const STATES = {
  disabled: { status: "disabled", reason: null, poseState: null },
  connecting: { status: "connecting", reason: null, poseState: null },
  connected: { status: "connected", reason: null, poseState: null },
  unreachable: { status: "offline", reason: "unreachable", poseState: null },
  version_mismatch: { status: "offline", reason: "version_mismatch", poseState: null },
  invalid_response: { status: "offline", reason: "invalid_response", poseState: null },
};

const sessions = Array.from({ length: 6 }, (_, index) => ({
  sessionId: "sess_" + String(index + 1).padStart(3, "0") + "abcdef",
  title: index === 1 ? "整理插画素材与播放器前端审美审查的第二轮迭代" : "会话 " + (index + 1),
  displayTitle: index === 1 ? "整理插画素材与播放器前端审美审查的第二轮迭代" : "会话 " + (index + 1),
  agentId: "codingagent",
  agentName: "码农",
  status: index === 0 ? "tool" : "idle",
  running: index === 0,
  toolName: index === 0 ? "read" : null,
  runEnded: false,
  lastActivityAt: now - index * 60000,
  statusAt: now - index * 60000,
}));

const store = {
  "hana-pet.bridge.enabled": scenario !== "disabled",
  "hana-pet.bridge.status": STATES[scenario] ?? STATES.connecting,
  "hana-pet.activity.snapshot": { revision: 4, observedAt: now, sessions, current: sessions[0] },
  "hana-pet.session-list": {
    available: true,
    sessions: sessions.map((item) => ({
      sessionId: item.sessionId, title: item.title, agentName: item.agentName, lifecycle: "active",
    })),
  },
  "hana-pet.follow": {
    mode: "latest", pinnedSessionId: null, followedSessionId: sessions[0].sessionId, released: null,
  },
  "hana-pet.selection": { characterId: "claude", updatedAt: 1, petRevision: 0 },
  "hana-pet.session-diagnostics": { list: null, get: null },
};

export const hana = {
  ready() {},
  external: {
    open(payload) {
      window.__openCalls.push(payload?.url ?? null);
      if (deny) {
        return Promise.reject(Object.assign(new Error("App requires the UI capability external.open."),
          { code: "CAPABILITY_DENIED" }));
      }
      return Promise.resolve({ opened: true });
    },
  },
  storage: {
    global: {
      async get(key) {
        if (scenario === "unreadable") throw new Error("synthetic host read failure");
        if (window.__failReads) throw new Error("synthetic host read failure after the panel was healthy");
        return store[key];
      },
      async set(key, value) { store[key] = value; },
      onChanged(callback) {
        window.__changeCallbacks = window.__changeCallbacks || [];
        window.__changeCallbacks.push(callback);
        return () => {};
      },
    },
  },
};

// Synthetic triggers for the state-transition scenario. No host, no network.
window.__setFailReads = (value) => { window.__failReads = value === true; };
window.__notifyChange = () => {
  for (const callback of window.__changeCallbacks || []) {
    callback(["hana-pet.bridge.status", "hana-pet.activity.snapshot", "hana-pet.session-list"]);
  }
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
    this.ready = new Promise((resolve, reject) => {
      this.ws.addEventListener("open", resolve, { once: true });
      this.ws.addEventListener("error", reject, { once: true });
    });
    this.ws.addEventListener("message", (event) => {
      const message = JSON.parse(event.data);
      if (!message.id || !this.pending.has(message.id)) return;
      const { resolve, reject } = this.pending.get(message.id);
      this.pending.delete(message.id);
      if (message.error) reject(new Error(message.error.message));
      else resolve(message.result);
    });
  }

  async send(method, params = {}) {
    await this.ready;
    const id = this.nextId++;
    const promise = new Promise((resolve, reject) => this.pending.set(id, { resolve, reject }));
    this.ws.send(JSON.stringify({ id, method, params }));
    return promise;
  }

  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

async function launchChrome(chromePath) {
  const profile = path.join(BUILD_DIR, "chrome-profile");
  fs.rmSync(profile, { recursive: true, force: true });
  const port = 46000 + Math.floor(Math.random() * 1000);
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
    return {
      top: Math.round(box.top * 100) / 100, bottom: Math.round(box.bottom * 100) / 100,
      left: Math.round(box.left * 100) / 100, right: Math.round(box.right * 100) / 100,
      width: Math.round(box.width * 100) / 100, height: Math.round(box.height * 100) / 100,
    };
  };
  const inside = (box, viewport) => Boolean(box) &&
    box.top >= -0.5 && box.bottom <= viewport.height + 0.5 &&
    box.left >= -0.5 && box.right <= viewport.width + 0.5;
  const viewport = { width: innerWidth, height: innerHeight };
  const guide = document.querySelector("#pet-onboarding");
  const lead = document.querySelector("#onboarding-lead");
  const windows = document.querySelector("#download-windows");
  const mac = document.querySelector("#download-mac");
  const help = document.querySelector("#onboarding-help");
  const fallback = document.querySelector("#onboarding-fallback");
  const fallbackUrl = document.querySelector("#onboarding-fallback-url");
  const list = document.querySelector("#sessions");
  const listBox = list.getBoundingClientRect();
  const rows = [...document.querySelectorAll("#sessions .session")].map((row) => {
    const box = row.getBoundingClientRect();
    return {
      title: row.querySelector(".session-title")?.textContent ?? null,
      fullyVisible: box.top >= listBox.top - 0.5 && box.bottom <= listBox.bottom + 0.5,
    };
  });
  const guideVisible = guide && !guide.hidden;
  return {
    viewport,
    document: {
      scrollWidth: document.documentElement.scrollWidth,
      scrollHeight: document.documentElement.scrollHeight,
    },
    bridgeState: document.querySelector("#bridge-state")?.textContent ?? null,
    bridgeStatus: document.querySelector("#bridge-state")?.dataset.status ?? null,
    guide: {
      hidden: guide?.hidden ?? null,
      state: guide?.dataset.state ?? null,
      lead: lead?.textContent ?? null,
      box: guideVisible ? rect(guide) : null,
      insideViewport: guideVisible ? inside(rect(guide), viewport) : null,
      focused: guideVisible ? getComputedStyle(guide).borderLeftColor : null,
    },
    windows: { box: rect(windows), visible: Boolean(windows && windows.offsetParent !== null), label: windows?.textContent ?? null },
    mac: { box: rect(mac), visible: Boolean(mac && mac.offsetParent !== null), label: mac?.textContent ?? null },
    help: {
      box: rect(help), open: help?.open === true,
      summary: rect(help?.querySelector("summary")),
      summaryText: help?.querySelector("summary")?.textContent ?? null,
      body: (() => {
        const body = help?.querySelector(".onboarding-help-body");
        return help?.open && body ? rect(body) : null;
      })(),
      bodyScrollable: (() => {
        const body = help?.querySelector(".onboarding-help-body");
        return body ? { overflowY: getComputedStyle(body).overflowY, scrollHeight: body.scrollHeight, clientHeight: body.clientHeight } : null;
      })(),
    },
    fallback: {
      hidden: fallback?.hidden ?? null,
      box: fallback && !fallback.hidden ? rect(fallback) : null,
      text: document.querySelector("#onboarding-fallback-text")?.textContent ?? null,
      url: fallbackUrl?.textContent ?? null,
      fullyVisible: (() => {
        if (!fallback || fallback.hidden || !fallbackUrl) return false;
        const box = fallbackUrl.getBoundingClientRect();
        return box.top >= 0 && box.bottom <= innerHeight && box.left >= 0 && box.right <= innerWidth;
      })(),
      wrap: fallbackUrl ? getComputedStyle(fallbackUrl).wordBreak : null,
    },
    list: {
      rowCount: rows.length,
      visibleRows: rows.filter((row) => row.fullyVisible).length,
      box: rect(list),
    },
    helpNoteVisible: (() => {
      const note = document.querySelector("#onboarding-help .onboarding-hint");
      return Boolean(note && note.offsetParent !== null);
    })(),
  };
})()`;

const TAB_ORDER = `(async () => {
  document.body.focus();
  const seen = [];
  for (let i = 0; i < 14; i += 1) {
    const target = document.activeElement;
    if (target && target.id && !seen.includes(target.id)) seen.push(target.id);
  }
  return seen;
})()`;

function contrastRatio(colorA, colorB) {
  const parse = (value) => {
    const rgb = /rgba?\(([^)]+)\)/.exec(value ?? "");
    if (rgb) return rgb[1].split(",").slice(0, 3).map((part) => parseFloat(part));
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
  const a = parse(colorA);
  const b = parse(colorB);
  if (!a || !b) return null;
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

const CASES = [
  { name: "560x664-disabled", width: 560, height: 664, scenario: "disabled", theme: "light", guideState: "disabled" },
  { name: "560x664-connecting", width: 560, height: 664, scenario: "connecting", theme: "light", guideState: "connecting" },
  { name: "560x664-connected", width: 560, height: 664, scenario: "connected", theme: "light" },
  { name: "560x664-unreachable", width: 560, height: 664, scenario: "unreachable", theme: "light", guideState: "offline" },
  { name: "560x664-unreachable-dark", width: 560, height: 664, scenario: "unreachable", theme: "dark", guideState: "offline" },
  { name: "560x664-version-mismatch", width: 560, height: 664, scenario: "version_mismatch", theme: "light", guideState: "offline" },
  { name: "560x664-invalid-response", width: 560, height: 664, scenario: "invalid_response", theme: "light", guideState: "offline" },
  // 宿主状态完全读不到时列表本来就是空的（旧行为）：只验证引导不伪造结论、不溢出。
  { name: "560x664-unreadable", width: 560, height: 664, scenario: "unreadable", theme: "light",
    guideState: "unknown", readiness: "guide", minRows: 0, minRowsHelp: 0 },
  { name: "420x640-unreachable", width: 420, height: 640, scenario: "unreachable", theme: "light", guideState: "offline" },
  { name: "390x640-unreachable", width: 390, height: 640, scenario: "unreachable", theme: "light",
    guideState: "offline", minRows: 2, minRowsHelp: 1 },
  { name: "560x560-unreachable", width: 560, height: 560, scenario: "unreachable", theme: "light",
    guideState: "offline", minRowsHelp: 1 },
];

const failures = [];
function check(condition, message) {
  if (!condition) failures.push(message);
}

async function waitReady(cdp, mode = "panel") {
  const started = Date.now();
  const expression = mode === "guide"
    ? "document.readyState === 'complete' && document.querySelector('#onboarding-lead')?.textContent.length > 0"
    : "document.readyState === 'complete' && document.querySelectorAll('#role-options .role-option').length === 7";
  while (Date.now() - started < 8000) {
    const result = await cdp.send("Runtime.evaluate", { expression, returnByValue: true });
    if (result.result.value === true) return true;
    await new Promise((resolve) => setTimeout(resolve, 80));
  }
  return false;
}

async function measure(cdp) {
  const value = await cdp.send("Runtime.evaluate", { expression: MEASURE, returnByValue: true });
  return value.result.value;
}

async function shoot(cdp, name) {
  const shot = await cdp.send("Page.captureScreenshot", { format: "png" });
  fs.writeFileSync(path.join(SHOT_DIR, `${name}.png`), Buffer.from(shot.data, "base64"));
}

async function run() {
  const chromePath = findChrome();
  if (!chromePath) {
    console.log("PANEL_ONBOARDING_SKIP no Chrome binary found (set CHROME_PATH to enable)");
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
      await cdp.send("Page.navigate", {
        url: `http://127.0.0.1:${port}/panel.html?scenario=${item.scenario}`,
      });
      const ready = await waitReady(cdp, item.readiness ?? "panel");
      check(ready, `${item.name}: panel did not become ready`);
      if (!ready) continue;

      const value = await measure(cdp);
      results.push({ name: item.name, ...value });
      await shoot(cdp, item.name);

      check(value.document.scrollWidth <= item.width + 1,
        `${item.name}: horizontal page overflow (${value.document.scrollWidth} > ${item.width})`);
      check(value.document.scrollHeight <= item.height + 1,
        `${item.name}: vertical page overflow (${value.document.scrollHeight} > ${item.height})`);
      const expectGuide = item.scenario !== "connected";
      if (expectGuide) {
        check(value.guide.insideViewport === true, `${item.name}: the guide is outside the viewport`);
        check(value.windows.visible && value.mac.visible,
          `${item.name}: both platform entries must stay visible`);
        check(value.windows.box.right <= item.width + 1 && value.mac.box.right <= item.width + 1,
          `${item.name}: a download entry overflows horizontally`);
      }
      check(value.list.visibleRows >= (item.minRows ?? 3),
        `${item.name}: only ${value.list.visibleRows} whole session rows remain`);

      check(value.guide.hidden === !expectGuide,
        `${item.name}: guide hidden=${value.guide.hidden} for scenario ${item.scenario}`);
      if (expectGuide) {
        check(value.guide.state === item.guideState,
          `${item.name}: guide state is ${value.guide.state}, expected ${item.guideState}`);
        check(typeof value.guide.lead === "string" && value.guide.lead.length > 0,
          `${item.name}: the guide has no explanation`);
        check(!/未安装|没有安装/.test(value.guide.lead ?? ""),
          `${item.name}: the guide claims the pet is not installed`);
        check(value.guide.box.height <= 120,
          `${item.name}: the collapsed guide is ${value.guide.box.height}px tall, expected <= 120`);
      }
      if (item.scenario === "connecting") {
        check(!/失败|没连上/.test(value.guide.lead ?? ""),
          `${item.name}: connecting shows a failure sentence`);
      }
      if (item.scenario === "unreadable") {
        check(value.bridgeState === "状态暂不可读", `${item.name}: bridge label is ${value.bridgeState}`);
      }
      if (item.theme === "dark") {
        const guideColors = await cdp.send("Runtime.evaluate", {
          expression: `(() => {
            const lead = document.querySelector("#onboarding-lead");
            const link = document.querySelector("#download-windows");
            const guide = document.querySelector("#pet-onboarding");
            return {
              lead: getComputedStyle(lead).color,
              guideBg: getComputedStyle(guide).backgroundColor,
              linkText: getComputedStyle(link).color,
              linkBg: getComputedStyle(link).backgroundColor,
            };
          })()`,
          returnByValue: true,
        });
        const colors = guideColors.result.value;
        const lead = contrastRatio(colors.lead, colors.guideBg);
        const link = contrastRatio(colors.linkText, colors.linkBg);
        check(lead !== null && lead >= 4.5, `${item.name}: guide text contrast ${lead?.toFixed(2)}`);
        check(link !== null && link >= 4.5, `${item.name}: download link contrast ${link?.toFixed(2)}`);
      }

      // The detailed install steps must not push the page out of its box.
      await cdp.send("Runtime.evaluate", { expression: "document.querySelector('#onboarding-help').open = true" });
      await new Promise((resolve) => setTimeout(resolve, 120));
      const opened = await measure(cdp);
      results.push({ name: `${item.name}-help-open`, ...opened });
      await shoot(cdp, `${item.name}-help-open`);
      check(opened.document.scrollHeight <= item.height + 1,
        `${item.name} help open: vertical page overflow (${opened.document.scrollHeight} > ${item.height})`);
      check(opened.document.scrollWidth <= item.width + 1,
        `${item.name} help open: horizontal page overflow (${opened.document.scrollWidth} > ${item.width})`);
      check(opened.help.open === true, `${item.name} help open: details did not open`);
      check(opened.help.summaryText?.trim().length > 0, `${item.name} help open: summary text missing`);
      if (opened.help.body) {
        check(opened.help.body.left >= -0.5 && opened.help.body.right <= item.width + 0.5,
          `${item.name} help open: the help panel overflows horizontally`);
        check(opened.help.body.top >= -0.5 && opened.help.body.bottom <= item.height + 0.5,
          `${item.name} help open: the help panel is cut off by the window`);
        check(opened.help.bodyScrollable?.overflowY === "auto",
          `${item.name} help open: the help body is not the documented internal scroller`);
      }
      // Reading the whole install note still leaves whole session rows on screen,
      // and the guide only grows by the documented details budget.
      if (expectGuide) {
        check(opened.guide.box.height - value.guide.box.height <= 90,
          `${item.name} help open: the guide grew by ${opened.guide.box.height - value.guide.box.height}px`);
      }
      if (expectGuide) {
        // 展开安装说明会让会话列表少留一行；即使最矮的窗口也至少留 1 整行。
        check(opened.list.visibleRows >= (item.minRowsHelp ?? 1),
          `${item.name} help open: only ${opened.list.visibleRows} whole session rows remain`);
        check(opened.guide.box.height <= 150,
          `${item.name} help open: the guide grew to ${opened.guide.box.height}px`);
      }    }

    // Keyboard: Tab must reach both download entries and the install-summary.
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width: 560, height: 664, deviceScaleFactor: 2, mobile: false,
    });
    await cdp.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-color-scheme", value: "light" }],
    });
    await cdp.send("Page.navigate", { url: `http://127.0.0.1:${port}/panel.html?scenario=unreachable` });
    await waitReady(cdp);
    await cdp.send("Runtime.evaluate", { expression: "document.body.setAttribute('tabindex','-1'); document.body.focus();" });
    const tabbed = [];
    for (let i = 0; i < 16; i += 1) {
      await cdp.send("Input.dispatchKeyEvent", { type: "rawKeyDown", key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 });
      await cdp.send("Input.dispatchKeyEvent", { type: "keyUp", key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 });
      const focused = await cdp.send("Runtime.evaluate", {
        expression: "document.activeElement && (document.activeElement.id || document.activeElement.tagName)",
        returnByValue: true,
      });
      const id = focused.result.value;
      if (id && !tabbed.includes(id)) tabbed.push(id);
    }
    results.push({ name: "keyboard-tab-order", tabbed });
    for (const expected of ["download-windows", "download-mac", "bridge-toggle"]) {
      check(tabbed.includes(expected), `keyboard: Tab never reached ${expected} (saw ${tabbed.join(" > ")})`);
    }
    results.at(-1).helpReached = tabbed.some((id) => id.startsWith("onboarding-help")) ||
      tabbed.includes("pet-onboarding");

    // Visible focus ring on a download entry.
    await cdp.send("Runtime.evaluate", {
      expression: "document.querySelector('#download-windows').focus()",
    });
    const ring = await cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const link = document.querySelector("#download-windows");
        const style = getComputedStyle(link);
        return {
          focused: document.activeElement === link,
          outlineWidth: parseFloat(style.outlineWidth) || 0,
          outlineStyle: style.outlineStyle,
        };
      })()`,
      returnByValue: true,
    });
    results.at(-1).focusRing = ring.result.value;
    check(ring.result.value.focused, "keyboard: the download entry could not take focus");
    check(ring.result.value.outlineWidth >= 2 && ring.result.value.outlineStyle !== "none",
      "keyboard: the download entry has no visible focus ring");

    // A denied external.open must leave a usable, selectable copy of the link.
    await cdp.send("Page.navigate", { url: `http://127.0.0.1:${port}/panel.html?scenario=unreachable&deny=1` });
    await waitReady(cdp);
    await cdp.send("Runtime.evaluate", { expression: "document.querySelector('#download-windows').click()" });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const denied = await measure(cdp);
    results.push({ name: "download-denied-fallback", ...denied });
    await shoot(cdp, "download-denied-fallback");
    const deniedFocus = await cdp.send("Runtime.evaluate", {
      expression: "document.activeElement?.id ?? null",
      returnByValue: true,
    });
    results.at(-1).focused = deniedFocus.result.value;
    check(denied.fallback.hidden === false, "denied: the fallback block did not appear");
    check(deniedFocus.result.value === "onboarding-fallback-url",
      `denied: focus went to ${deniedFocus.result.value}, not the copyable link field`);
    check(denied.fallback.url?.startsWith("https://github.com/wqh0201-stack/hana-desk-pet/releases/download/"),
      `denied: fallback URL is ${denied.fallback.url}`);
    check(denied.fallback.url?.endsWith(".zip"), "denied: the fallback is not the packaged zip");
    check(denied.fallback.fullyVisible === true, "denied: the copyable link is clipped");
    check(denied.fallback.wrap === "break-all",
      `denied: the copyable link does not wrap (${denied.fallback.wrap})`);
    check(denied.fallback.box?.top >= 0 && denied.fallback.box?.bottom <= 664,
      "denied: the fallback block is outside the window");
    check(denied.document.scrollHeight <= 665 && denied.document.scrollWidth <= 561,
      `denied: page overflow (${denied.document.scrollWidth}x${denied.document.scrollHeight})`);
    check(denied.list.visibleRows >= 1, `denied: only ${denied.list.visibleRows} whole session rows remain`);

    // 状态转换：已 connected 且列表已有多行 → 宿主读取失败 → 引导重新出现。
    // refresh() 的 catch 只 renderOnboarding(null)，不重算整行高度；这里在真实布局下验证
    // 列表是否仍按整行收敛，而不是只看引导有没有出现。
    for (const viewport of [{ width: 560, height: 664 }, { width: 390, height: 640 }]) {
      await cdp.send("Emulation.setDeviceMetricsOverride", {
        width: viewport.width, height: viewport.height, deviceScaleFactor: 2, mobile: false,
      });
      await cdp.send("Emulation.setEmulatedMedia", {
        features: [{ name: "prefers-color-scheme", value: "light" }],
      });
      await cdp.send("Page.navigate", { url: `http://127.0.0.1:${port}/panel.html?scenario=connected` });
      await waitReady(cdp);
      const healthy = await measure(cdp);
      check(healthy.guide.hidden === true, `transition ${viewport.width}: the guide should start hidden`);

      await cdp.send("Runtime.evaluate", { expression: "window.__setFailReads(true); window.__notifyChange();" });
      await new Promise((resolve) => setTimeout(resolve, 350));
      const failed = await measure(cdp);
      results.push({ name: `transition-read-failure-${viewport.width}x${viewport.height}`, ...failed });
      await shoot(cdp, `transition-read-failure-${viewport.width}x${viewport.height}`);

      check(failed.guide.hidden === false, `transition ${viewport.width}: the guide did not come back`);
      check(failed.bridgeState === "状态暂不可读",
        `transition ${viewport.width}: bridge label is ${failed.bridgeState}`);
      check(failed.document.scrollWidth <= viewport.width + 1,
        `transition ${viewport.width}: horizontal overflow (${failed.document.scrollWidth})`);
      check(failed.document.scrollHeight <= viewport.height + 1,
        `transition ${viewport.width}: vertical overflow (${failed.document.scrollHeight})`);
      check(failed.windows.visible && failed.mac.visible,
        `transition ${viewport.width}: both platform entries must stay visible`);
      // 整行收敛：引导占位后，列表要么完整行填满可用高度，要么不留死空白。
      check(failed.list.visibleRows >= 1,
        `transition ${viewport.width}: only ${failed.list.visibleRows} whole session rows remain`);
      const listFit = await cdp.send("Runtime.evaluate", {
        expression: `(() => {
          const list = document.querySelector("#sessions");
          const rows = [...list.querySelectorAll(".session")];
          if (!rows.length) return { partialRows: 0, trailingGap: 0, rowCount: 0 };
          const box = list.getBoundingClientRect();
          const rowHeight = rows[0].getBoundingClientRect().height + 3;
          const partialRows = rows.filter((row) => {
            const r = row.getBoundingClientRect();
            return r.top < box.bottom - 0.5 && r.bottom > box.bottom + 0.5;
          }).length;
          const lastVisible = rows.filter((row) => {
            const r = row.getBoundingClientRect();
            return r.bottom <= box.bottom + 0.5;
          }).at(-1);
          const trailingGap = lastVisible ? Math.round((box.bottom - lastVisible.getBoundingClientRect().bottom) * 100) / 100 : 0;
          return { partialRows, trailingGap, rowCount: rows.length, rowHeight: Math.round(rowHeight * 100) / 100 };
        })()`,
        returnByValue: true,
      });
      const fit = listFit.result.value;
      results.at(-1).listFit = fit;
      check(fit.partialRows === 0,
        `transition ${viewport.width}: ${fit.partialRows} row(s) are cut in half at the list edge`);
      check(fit.rowCount <= 1 || fit.trailingGap < fit.rowHeight,
        `transition ${viewport.width}: a full empty row is left unused (gap ${fit.trailingGap}px >= row ${fit.rowHeight}px)`);
    }

    // An accepted open must not leave the fallback behind.
    await cdp.send("Page.navigate", { url: `http://127.0.0.1:${port}/panel.html?scenario=unreachable` });
    await waitReady(cdp);
    await cdp.send("Runtime.evaluate", { expression: "document.querySelector('#download-mac').click()" });
    await new Promise((resolve) => setTimeout(resolve, 200));
    const opened = await measure(cdp);
    const calls = await cdp.send("Runtime.evaluate", { expression: "window.__openCalls", returnByValue: true });
    results.push({ name: "download-accepted", ...opened, openCalls: calls.result.value });
    check(opened.fallback.hidden === true, "accepted: the fallback block should stay hidden");
    check(Array.isArray(calls.result.value) && calls.result.value.length === 1 &&
      calls.result.value[0].endsWith("HanaDesktopPet-crosspet-v0.5.8-local.zip"),
      `accepted: unexpected open calls ${JSON.stringify(calls.result.value)}`);
    check(opened.document.scrollHeight <= 665, "accepted: page overflow after opening the link");
    const notice = await cdp.send("Runtime.evaluate", {
      expression: `(() => {
        const node = document.querySelector("#panel-notice");
        return { text: node?.textContent ?? "", tone: node?.dataset.tone ?? null };
      })()`,
      returnByValue: true,
    });
    results.at(-1).notice = notice.result.value;
    check(notice.result.value.text.includes("已在浏览器打开"),
      "accepted: no confirmation is shown after the host opened the link");
    check(notice.result.value.tone === "ok",
      "accepted: the success confirmation is styled as an error");
  } finally {
    cdp?.close();
    chrome.child.kill("SIGTERM");
    server.close();
  }

  const summary = results.map((item) => ({
    name: item.name,
    viewport: item.viewport ? `${item.viewport.width}x${item.viewport.height}` : null,
    pageScroll: item.document ? `${item.document.scrollWidth}x${item.document.scrollHeight}` : null,
    bridgeState: item.bridgeState ?? null,
    guideHidden: item.guide?.hidden ?? null,
    guideState: item.guide?.state ?? null,
    guideHeight: item.guide?.box?.height ?? null,
    lead: item.guide?.lead ?? null,
    visibleRows: item.list?.visibleRows ?? null,
    listFit: item.listFit ?? null,
    helpOpen: item.help?.open ?? null,
    fallback: item.fallback?.hidden === false ? item.fallback.url : null,
    tabbed: item.tabbed ?? null,
  }));
  console.log(JSON.stringify({ shots: SHOT_DIR, cases: summary }, null, 2));

  if (failures.length) {
    for (const failure of failures) console.error("FAIL " + failure);
    console.error(`PANEL_ONBOARDING_FAIL ${failures.length} check(s)`);
    return 1;
  }
  console.log("PANEL_ONBOARDING_OK");
  return 0;
}

run().then((code) => process.exit(code)).catch((error) => {
  console.error("PANEL_ONBOARDING_ERROR", error);
  process.exit(1);
});
