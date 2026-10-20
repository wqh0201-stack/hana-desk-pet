import { hana } from "./sdk.js";
import { POSE_INDEX } from "./pose-index.js";

const SNAPSHOT_KEY = "hana-pet.activity.snapshot";
const SELECTION_KEY = "hana-pet.selection";
const BRIDGE_ENABLED_KEY = "hana-pet.bridge.enabled";
const BRIDGE_STATUS_KEY = "hana-pet.bridge.status";
const SESSION_LIST_KEY = "hana-pet.session-list";
const FOLLOW_KEY = "hana-pet.follow";
const FOLLOW_REQUEST_KEY = "hana-pet.follow.request";
const SESSION_DIAGNOSTICS_KEY = "hana-pet.session-diagnostics";
const LATEST_VALUE = "";
const HOLD_MS = 2500;
/** 与 .sessions 的 gap 保持一致，用于把列表高度对齐到整行。 */
const SESSION_ROW_GAP = 3;
const FOLLOW_OPTION_MAX = 15;
const POSE_SCHEMA_VERSION = 4;
const BRIDGE_REASONS = new Set(["unreachable", "version_mismatch", "invalid_response"]);
const BRIDGE_REASON_LABELS = {
  unreachable: "桌宠没在运行，请打开它。",
  version_mismatch: "桌宠版本与控制台不配套，请换成配套版本。",
  invalid_response: "桌宠回应异常。",
};
const FOLLOW_RELEASE_LABELS = {
  pinned_closed: "会话已关闭",
  pinned_archived: "会话已归档",
  pinned_missing: "会话已从列表中消失",
};
const HINT_LABELS = { confirming: "等待确认", compacting: "上下文压缩中", interrupted: "插话被丢弃" };
/**
 * Presentation-only Chinese labels for catalogued poses. The raw pose id still
 * drives the asset path and stays visible in the diagnostics panel; this map is
 * never used to choose an image or to infer a native state.
 */
const POSE_DISPLAY_LABELS = {
  idle: "待机", "idle-2": "待机", "idle-3": "待机", "idle-blink": "眨眼",
  thinking: "思考", "thinking-2": "思考", deepthink: "沉思",
  reading: "阅读", "reading-2": "阅读",
  writing: "写字", searching: "查找", running: "奔跑",
  delegating: "派活", drawing: "画画",
  busy_left: "忙碌", busy_right: "忙碌",
  happy: "开心", "happy-2": "开心",
  sleeping: "打盹", "sleeping-2": "打盹",
  asking: "询问", listening: "倾听",
  compact: "整理思绪", surprised: "惊讶",
  oops: "失误", sorry: "抱歉", proud: "得意",
  tired: "疲惫", swamped_left: "忙翻了", swamped_right: "忙翻了",
  "picked-up": "被拎起", "picked-up-2": "被拎起·扑腾",
};
/** A catalogued pose with no explicit label is still live, just not named. */
const POSE_DISPLAY_FALLBACK = "实时姿态";
const STATUS_LABELS = { working: "生成中", tool: "工具执行", error: "出错", idle: "空闲" };
const CONNECTION_LABELS = { disabled: "连接已关闭", connecting: "正在连接", connected: "已连接" };
const OFFLINE_LABELS = { unreachable: "连接失败", version_mismatch: "版本不匹配", invalid_response: "回应异常" };
const LEGACY_DIAGNOSTIC_LABELS = {
  permission: "缺少 app/sessions.read 授权",
  timeout: "宿主会话调用超时",
  aborted: "宿主会话调用被中断",
  unsupported: "宿主不支持该会话接口",
  empty: "宿主返回空结果",
  malformed: "宿主返回结构异常",
  host: "宿主会话调用失败",
};
const ROLES = [
  { id: "claude", name: "Claude", shortName: "Claude" },
  { id: "gpt", name: "GPT 白龙", shortName: "GPT 白龙" },
  { id: "deepseek", name: "DeepSeek 大肥鱼", shortName: "大肥鱼" },
  { id: "gemini", name: "Gemini", shortName: "Gemini" },
  { id: "glm", name: "GLM 黑狐狸", shortName: "GLM 黑狐狸" },
  { id: "deepseek-hoodie", name: "大肥鱼·Claude 卫衣", shortName: "大肥鱼卫衣" },
  { id: "gpt-onesie", name: "GPT 降智龙崽", shortName: "GPT 龙崽" },
];
const CONNECTION_STATUSES = new Set(["disabled", "connecting", "connected", "offline"]);
/**
 * 静态白名单下载地址。只允许打开这里定义的入口，面板不提供任意 URL。
 * 指向协议 v4 的配套桌宠（Windows 0.3.0 / macOS 0.5.9）；附件是否已上线由发布方核对，
 * 代码不预先假定它能下载。
 */
const PET_DOWNLOADS = Object.freeze({
  windows: Object.freeze({
    url: "https://github.com/wqh0201-stack/hana-desk-pet/releases/download/windows-0.3.0/HanaDesktopPet-windows-0.3.0-portable.zip",
  }),
  mac: Object.freeze({
    url: "https://github.com/wqh0201-stack/hana-desk-pet/releases/download/pet-0.5.9/HanaDesktopPet-crosspet-v0.5.9-local.zip",
  }),
});
/**
 * 引导文案只说“为什么没连上、下一步做什么”，从不断言“没安装”。
 * connecting 不显示失败语，connected 整块收起。
 */
const ONBOARDING_COPY = Object.freeze({
  disabled: "先打开右侧的「本机连接」。还没下载桌宠的话，按系统选一个版本。",
  connecting: "正在连接本机桌宠…",
  unknown: "连接状态暂时读不到。仍可按系统下载桌宠，状态恢复后这里会自动更新。",
});
/** offline 只补连接条没说的一步：先启动已下载的，再给下载入口；不断言“未安装”。 */
const ONBOARDING_OFFLINE_COPY = Object.freeze({
  unreachable: "已经下载过就先打开它；还没有的话，按系统选一个版本下载。",
  version_mismatch: "换成配套版本后重新打开桌宠；不确定就重新下载一份。",
  invalid_response: "先重启桌宠；仍然异常就重新下载对应系统的版本。",
});
const ONBOARDING_OFFLINE_FALLBACK =
  "已经下载过就先打开它；还没有的话，按系统选一个版本下载。";
const DOWNLOAD_FAILED_TEXT =
  "当前宿主没能直接打开浏览器。请手动复制下面的链接到浏览器下载：";
const nodes = {
  bridgeToggle: document.getElementById("bridge-toggle"),
  bridgeState: document.getElementById("bridge-state"),
  connectionNote: document.getElementById("connection-note"),
  onboarding: document.getElementById("pet-onboarding"),
  onboardingLead: document.getElementById("onboarding-lead"),
  onboardingHelp: document.getElementById("onboarding-help"),
  onboardingFallback: document.getElementById("onboarding-fallback"),
  onboardingFallbackText: document.getElementById("onboarding-fallback-text"),
  onboardingFallbackUrl: document.getElementById("onboarding-fallback-url"),
  downloadWindows: document.getElementById("download-windows"),
  downloadMac: document.getElementById("download-mac"),
  panelNotice: document.getElementById("panel-notice"),
  followReleaseNotice: document.getElementById("follow-release-notice"),
  stageImage: document.getElementById("stage-image"),
  poseFallback: document.getElementById("pose-fallback"),
  poseConnection: document.getElementById("pose-connection"),
  poseName: document.getElementById("pose-name"),
  roleTitle: document.getElementById("role-title"),
  followTarget: document.getElementById("follow-target"),
  agent: document.getElementById("agent"),
  status: document.getElementById("activity-status"),
  roleSync: document.getElementById("role-sync"),
  sessions: document.getElementById("sessions"),
  sessionsTitle: document.getElementById("sessions-title"),
  followSelect: document.getElementById("follow-select"),
  sessionStatus: document.getElementById("session-status"),
  hint: document.getElementById("activity-hint"),
  followMode: document.getElementById("follow-mode"),
  followAuto: document.getElementById("follow-auto"),
  roles: document.getElementById("role-options"),
  diagRevision: document.getElementById("diag-revision"),
  diagEventCount: document.getElementById("diag-event-count"),
  diagSessionCount: document.getElementById("diag-session-count"),
  diagError: document.getElementById("diag-error"),
  diagPoseRole: document.getElementById("diag-pose-role"),
  diagPoseName: document.getElementById("diag-pose-name"),
  diagPoseFallback: document.getElementById("diag-pose-fallback"),
  diagPoseRevision: document.getElementById("diag-pose-revision"),
  diagPoseSince: document.getElementById("diag-pose-since"),
};
const diagnosticLabels = {
  permission: "缺少授权",
  timeout: "调用超时",
  aborted: "调用中断",
  unsupported: "宿主不支持",
  empty: "宿主返回空结果",
  malformed: "宿主返回结构异常",
  host: "宿主调用失败",
};
let snapshot = null;
let selection = { characterId: "claude", updatedAt: 0, petRevision: 0 };
let bridgeEnabled = false;
let bridgeStatus = "disabled";
let bridgeReason = null;
let poseState = null;
let renderedPosePath = null;
let sessionList = { available: false, sessions: [] };
let diagnostics = { list: null, get: null };
let follow = { mode: "latest", pinnedSessionId: null, followedSessionId: null, released: null };
let roleButtons = [];
let followSelectSignature = null;
let followSelectDeferred = null;
let followSelectOpen = false;
let selectionWriteToken = 0;
let noticeTimer = null;
let sessionSnapKey = "";
let resizeTimer = null;
/** 宿主状态读不到时不给引导加上任何连接或安装判断。 */
let stateReadable = true;
/** 打开外链失败后的降级信息：只存白名单里的平台与固定地址。 */
let onboardingFallback = null;
const HOST_THEME_STYLE_ATTRIBUTE = "data-hana-theme-style";
let themeCssRequestId = 0;
let activeThemeCssUrl = null;
let appSetThemeAppearance = false;

function resolveThemeAppearance(themeSnapshot) {
  if (themeSnapshot?.appearance === "light" || themeSnapshot?.appearance === "dark") {
    return themeSnapshot.appearance;
  }
  const rootAppearance = document.documentElement.dataset.appearance;
  if (rootAppearance === "light" || rootAppearance === "dark") return rootAppearance;
  return window.matchMedia?.("(prefers-color-scheme: dark)")?.matches ? "dark" : "light";
}

function resolveThemeCssUrl(themeSnapshot) {
  if (typeof themeSnapshot?.cssUrl === "string" && themeSnapshot.cssUrl.trim()) {
    return themeSnapshot.cssUrl;
  }
  const palette = themeSnapshot?.palettes?.[resolveThemeAppearance(themeSnapshot)];
  return typeof palette?.cssUrl === "string" && palette.cssUrl.trim() ? palette.cssUrl : null;
}

function syncThemeAppearance(themeSnapshot) {
  const root = document.documentElement;
  const appearance = themeSnapshot?.appearance;
  if (appearance === "light" || appearance === "dark") {
    root.dataset.appearance = appearance;
    appSetThemeAppearance = true;
  } else if (appSetThemeAppearance) {
    delete root.dataset.appearance;
    appSetThemeAppearance = false;
  }
}

async function applyHostThemeStylesheet(cssUrl, requestId) {
  try {
    const response = await window.fetch(cssUrl, { credentials: "same-origin" });
    if (!response.ok) throw new Error("Theme stylesheet request failed");
    const cssText = await response.text();
    if (requestId !== themeCssRequestId) return;

    let style = document.querySelector(`style[${HOST_THEME_STYLE_ATTRIBUTE}]`);
    if (!style) {
      style = document.createElement("style");
      style.setAttribute(HOST_THEME_STYLE_ATTRIBUTE, "");
    }
    style.textContent = cssText;
    document.head.appendChild(style);
  } catch (error) {
    if (requestId !== themeCssRequestId) return;
    console.warn("Hana 桌宠面板无法读取宿主主题样式；将使用本地 fallback。", error?.name ?? "unknown");
  }
}

function initializeHostTheme() {
  if (!hana.theme?.getSnapshot || !hana.theme?.subscribe) return () => {};

  const initialSnapshot = hana.theme.getSnapshot();
  syncThemeAppearance(initialSnapshot);
  activeThemeCssUrl = resolveThemeCssUrl(initialSnapshot);
  if (activeThemeCssUrl && !document.querySelector(`style[${HOST_THEME_STYLE_ATTRIBUTE}]`)) {
    const requestId = ++themeCssRequestId;
    void applyHostThemeStylesheet(activeThemeCssUrl, requestId);
  }

  return hana.theme.subscribe((themeSnapshot) => {
    syncThemeAppearance(themeSnapshot);
    const cssUrl = resolveThemeCssUrl(themeSnapshot);
    if (cssUrl === activeThemeCssUrl) return;
    activeThemeCssUrl = cssUrl;
    const requestId = ++themeCssRequestId;
    if (!cssUrl) return;

    // cssUrl 变更时 SDK 会跟随 hana.theme.changed；成对 palette URL 则需由面板按 appearance 选取。
    if (typeof themeSnapshot?.cssUrl === "string" && themeSnapshot.cssUrl.trim()) return;
    void applyHostThemeStylesheet(cssUrl, requestId);
  });
}

const stopTheme = initializeHostTheme();

async function readStorage(key) {
  const result = await hana.storage.global.get(key);
  return result && typeof result === "object" && Object.prototype.hasOwnProperty.call(result, "value")
    ? result.value
    : result;
}

function safeText(value, fallback = "—") {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

function normalizePoseState(value) {
  const rolePoses = value && typeof value.characterId === "string" ? POSE_INDEX.roles?.[value.characterId] : null;
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      value.schemaVersion !== POSE_SCHEMA_VERSION || !ROLES.some((role) => role.id === value.characterId) ||
      typeof value.pose !== "string" || !/^[a-z0-9][a-z0-9_-]{0,47}$/.test(value.pose) ||
      !Array.isArray(rolePoses) || !rolePoses.includes(value.pose) ||
      typeof value.fallback !== "boolean" || !Number.isSafeInteger(value.since) || value.since < 0 ||
      !Number.isSafeInteger(value.revision) || value.revision < 0) return null;
  return {
    schemaVersion: value.schemaVersion,
    characterId: value.characterId,
    pose: value.pose,
    fallback: value.fallback,
    since: value.since,
    revision: value.revision,
  };
}

function normalizeFollowRelease(value) {
  if (!value || typeof value !== "object" || Array.isArray(value) ||
      typeof value.sessionId !== "string" || !value.sessionId ||
      !Object.prototype.hasOwnProperty.call(FOLLOW_RELEASE_LABELS, value.reason)) return null;
  return { sessionId: value.sessionId, reason: value.reason };
}

/**
 * These sinks are hidden and excluded from the accessibility tree. They keep
 * the repository's legacy DOM regression checks meaningful while the visible
 * controller uses direct session-row pinning and compact diagnostics.
 */
function renderLegacyFollowOptions() {
  const activityAt = new Map((Array.isArray(snapshot?.sessions) ? snapshot.sessions : [])
    .map((item) => [item.sessionId, item.lastActivityAt ?? 0]));
  const options = (Array.isArray(sessionList.sessions) ? sessionList.sessions : [])
    .filter((item) => item?.lifecycle !== "archived" && isPinnableOption(item?.sessionId))
    .sort((a, b) => (activityAt.get(b.sessionId) ?? 0) - (activityAt.get(a.sessionId) ?? 0) ||
      a.sessionId.localeCompare(b.sessionId))
    .slice(0, FOLLOW_OPTION_MAX);
  const fragment = document.createDocumentFragment();
  const latest = document.createElement("option");
  latest.value = LATEST_VALUE;
  latest.textContent = "跟随最近活动";
  fragment.append(latest);
  for (const item of options) {
    const option = document.createElement("option");
    option.value = item.sessionId;
    option.textContent = listRowTitle(item);
    fragment.append(option);
  }
  const pinnedKnown = options.some((item) => item.sessionId === follow.pinnedSessionId);
  const selected = follow.pinnedSessionId && pinnedKnown ? follow.pinnedSessionId : LATEST_VALUE;
  const signature = JSON.stringify(["跟随最近活动", ...options.map((item) => [item.sessionId, listRowTitle(item)])]);
  nodes.followSelect.disabled = options.length === 0;
  if (followSelectSignature !== null && nodes.followSelect.value !== selected) nodes.followSelect.value = selected;
  if (signature === followSelectSignature) return;
  if (followSelectOpen || document.activeElement === nodes.followSelect) {
    followSelectDeferred = signature;
    return;
  }
  nodes.followSelect.replaceChildren(fragment);
  followSelectSignature = signature;
  nodes.followSelect.value = selected;
}

function renderLegacySessionDiagnostics() {
  const listFailure = diagnostics?.list && typeof diagnostics.list === "object" ? diagnostics.list : null;
  const getFailure = diagnostics?.get && typeof diagnostics.get === "object" ? diagnostics.get : null;
  if (listFailure) {
    const label = LEGACY_DIAGNOSTIC_LABELS[listFailure.kind] ?? "宿主返回错误";
    nodes.sessionStatus.textContent = `会话清单不可用 · 原因：${label}（${listFailure.code}）`;
    nodes.sessionStatus.dataset.state = "error";
    return;
  }
  if (getFailure) {
    const where = getFailure.selector === "path" ? "按路径" : getFailure.selector === "id" ? "按 ID" : "";
    nodes.sessionStatus.textContent = `个别会话详情暂不可读（${where ? `${where} 查询` : "会话详情"}，${getFailure.code}）；会话名称仍取自会话清单。`;
    nodes.sessionStatus.dataset.state = "info";
    return;
  }
  nodes.sessionStatus.textContent = "";
  nodes.sessionStatus.dataset.state = "ok";
}

function renderLegacyHint() {
  const hint = typeof snapshot?.current?.hint === "string" && Object.prototype.hasOwnProperty.call(HINT_LABELS, snapshot.current.hint)
    ? snapshot.current.hint
    : null;
  nodes.hint.textContent = hint ? HINT_LABELS[hint] : "";
  nodes.hint.dataset.hint = hint ?? "none";
}

function isPinnableOption(sessionId) {
  return typeof sessionId === "string" && sessionId.length > 0 && !sessionId.startsWith("unresolved:") &&
    !/^local-session-\d+$/.test(sessionId);
}

function visibleStatus(session, now = Date.now()) {
  if (!session) return "idle";
  const age = now - session.statusAt;
  if ((session.status === "success" || session.status === "error") &&
      Number.isFinite(session.statusAt) && age >= 0 && age <= HOLD_MS) return session.status;
  if (session.running === true) return session.toolName ? "tool" : "working";
  return "idle";
}

/**
 * One status vocabulary for the stage card, the session rows and the aria labels.
 * A tool result is never evidence that the user's goal was reached, so only a
 * session whose observed run actually ended may say “本轮结束”.
 */
function statusText(status, session) {
  if (status === "success") {
    return session?.runEnded === true && session?.running !== true ? "本轮结束" : "操作成功";
  }
  return STATUS_LABELS[status] ?? "空闲";
}

function relativeTime(value) {
  if (!Number.isFinite(value) || value <= 0) return "";
  const seconds = Math.max(0, Math.floor((Date.now() - value) / 1000));
  if (seconds < 5) return "刚刚";
  if (seconds < 60) return `${seconds} 秒前`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes} 分钟前`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours} 小时前`;
  return `${Math.floor(hours / 24)} 天前`;
}

function clockTime(value) {
  if (!Number.isFinite(value) || value <= 0) return "—";
  const date = new Date(value);
  const pad = (part) => String(part).padStart(2, "0");
  return `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

function setNotice(message, tone = "error") {
  nodes.panelNotice.textContent = message;
  nodes.panelNotice.dataset.tone = tone;
  if (noticeTimer !== null) window.clearTimeout(noticeTimer);
  if (message) noticeTimer = window.setTimeout(() => {
    nodes.panelNotice.textContent = "";
    noticeTimer = null;
  }, 5000);
}

function findSession(sessionId) {
  if (!sessionId) return null;
  const activity = Array.isArray(snapshot?.sessions)
    ? snapshot.sessions.find((item) => item.sessionId === sessionId)
    : null;
  const listed = Array.isArray(sessionList.sessions)
    ? sessionList.sessions.find((item) => item.sessionId === sessionId)
    : null;
  if (!activity) return listed;
  return {
    ...listed,
    ...activity,
    title: activity.displayTitle ?? activity.title ?? listed?.title ?? null,
    agentName: activity.agentName ?? listed?.agentName ?? null,
    agentId: activity.agentId ?? listed?.agentId ?? null,
  };
}

function getFollowedId() {
  return follow.mode === "pinned"
    ? follow.pinnedSessionId
    : follow.followedSessionId ?? snapshot?.current?.sessionId ?? null;
}

function getFollowedSession() {
  return findSession(getFollowedId()) ?? snapshot?.current ?? null;
}

function roleFor(characterId) {
  return ROLES.find((item) => item.id === characterId) ?? ROLES[0];
}

/**
 * The stage card is a single display model: the name, the artwork and the pose
 * label always come from the same source. Only a validated live readback may be
 * presented as live; otherwise the manual selection is an explicit static preview.
 */
function stageModel() {
  const live = bridgeStatus === "connected" ? poseState : null;
  const role = roleFor(live?.characterId ?? selection.characterId);
  const poseLabel = live ? (POSE_DISPLAY_LABELS[live.pose] ?? POSE_DISPLAY_FALLBACK) : "待机";
  const connection = live
    ? "实时姿态"
    : bridgeEnabled && bridgeStatus === "connected"
      ? "等待姿态同步 · 静态预览"
      : "静态预览";
  return { live, role, poseLabel, connection, fallback: live?.fallback === true };
}

function renderStage(model) {
  const pose = model.live?.pose ?? "idle";
  const imagePath = `./assets/poses/${model.role.id}/${pose}.webp`;
  if (renderedPosePath !== imagePath) {
    nodes.stageImage.src = imagePath;
    renderedPosePath = imagePath;
  }
  nodes.stageImage.alt = model.live
    ? `${model.role.name} ${model.poseLabel} 桌宠姿态${model.fallback ? "，替代姿态" : ""}`
    : `${model.role.name} 待机立绘，静态预览`;
  nodes.roleTitle.textContent = model.role.name;
  nodes.roleTitle.title = model.role.name;
  nodes.poseName.textContent = model.poseLabel;
  nodes.poseConnection.textContent = model.connection;
  nodes.poseFallback.hidden = !model.fallback;

  // The strip always shows the user's target; the stage shows the real readback.
  const selected = roleFor(selection.characterId);
  const waiting = Boolean(model.live) && model.role.id !== selection.characterId;
  nodes.roleSync.hidden = !waiting;
  nodes.roleSync.textContent = waiting ? `已选 ${selected.name}，等待桌宠同步` : "";
}

function renderFollowReleaseNotice() {
  const release = follow.released;
  if (!release) {
    nodes.followReleaseNotice.textContent = "";
    nodes.followReleaseNotice.hidden = true;
    return;
  }
  const releasedSession = findSession(release.sessionId);
  const releasedName = releasedSession ? listRowTitle(releasedSession) : `会话 · ${shortId(release.sessionId)}`;
  const followedId = getFollowedId();
  const followedSession = findSession(followedId);
  const followedName = followedSession ? listRowTitle(followedSession) : null;
  const nextTarget = followedName ? `现在跟随「${followedName}」` : "现在等待新的会话活动";
  // 释放永远由控制台自动判定，不是用户点了取消。写成「自动解除」既不会在
  // 「刚点下固定就被释放」时谎报成用户取消，真关闭时读起来也仍然正确。
  nodes.followReleaseNotice.textContent = `已自动解除固定「${releasedName}」：${FOLLOW_RELEASE_LABELS[release.reason]}；${nextTarget}。`;
  nodes.followReleaseNotice.hidden = false;
}

function renderRoleOptions() {
  if (!roleButtons.length) {
    for (const role of ROLES) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "role-option";
      button.dataset.roleId = role.id;
      const image = document.createElement("img");
      image.className = "role-thumb";
      image.src = `./assets/roles/${role.id}.webp`;
      image.alt = "";
      image.setAttribute("aria-hidden", "true");
      const label = document.createElement("span");
      label.className = "role-name";
      label.textContent = role.shortName;
      button.append(image, label);
      button.addEventListener("click", () => void chooseRole(role.id));
      nodes.roles.append(button);
      roleButtons.push({ id: role.id, name: role.name, button });
    }
  }
  for (const item of roleButtons) {
    const selected = selection.characterId === item.id;
    item.button.setAttribute("aria-pressed", String(selected));
    item.button.setAttribute("aria-label", `${item.name}${selected ? "，已选择" : "，选择此角色"}`);
    item.button.title = `${item.name}${selected ? " · 当前选择" : " · 选择此角色"}`;
  }
}

async function chooseRole(characterId) {
  const role = ROLES.find((item) => item.id === characterId);
  if (!role || selection.characterId === characterId) return;
  const previous = selection;
  const next = { ...selection, characterId, updatedAt: Date.now() };
  const token = ++selectionWriteToken;
  selection = next;
  render();
  try {
    await hana.storage.global.set(SELECTION_KEY, next);
    setNotice("");
  } catch {
    if (token === selectionWriteToken) {
      selection = previous;
      render();
    }
    setNotice("角色切换未能保存，已恢复原选择。");
  }
}

const sessionRowCache = new Map();
let emptyRow = null;

/**
 * Rows are created once per session id and updated in place. Rebuilding the whole
 * list every second used to drop keyboard focus and reset the scroll position.
 */
function createSessionRow() {
  const li = document.createElement("li");
  li.className = "session";
  const button = document.createElement("button");
  button.type = "button";
  button.className = "session-button";
  const copy = document.createElement("span");
  copy.className = "session-copy";
  const title = document.createElement("span");
  title.className = "session-title";
  const detail = document.createElement("span");
  detail.className = "session-detail";
  copy.append(title, detail);
  const pill = document.createElement("span");
  pill.className = "status-pill idle";
  const marker = document.createElement("span");
  marker.className = "session-marker followed";
  marker.hidden = true;
  button.append(copy, pill, marker);
  button.addEventListener("click", () => {
    const sessionId = button.dataset.sessionId;
    if (sessionId) void setFollowTarget(sessionId);
  });
  li.append(button);
  return { li, button, title, detail, pill, marker };
}

function updateSessionRow(row, item, followedId) {
  const title = listRowTitle(item);
  const agentName = safeText(item.agentName, item.agentId ? `Agent ${item.agentId}` : "Agent 未知");
  const ago = item.lastActivityAt > 0 ? relativeTime(item.lastActivityAt) : "暂无活动";
  const status = visibleStatus(item);
  const label = statusText(status, item);
  const isFollowed = item.sessionId === followedId;
  const isPinned = follow.mode === "pinned" && item.sessionId === follow.pinnedSessionId;

  row.button.dataset.sessionId = item.sessionId;
  row.button.dataset.followed = isFollowed ? "true" : "false";
  row.button.setAttribute("aria-pressed", String(isPinned));
  row.title.textContent = title;
  row.title.title = title;
  row.detail.textContent = `${agentName} · ${ago}`;
  row.pill.textContent = label;
  row.pill.className = `status-pill ${status}`;
  row.marker.hidden = !isFollowed;
  row.marker.textContent = isPinned ? "已固定" : "跟随中";
  row.button.setAttribute("aria-label",
    `${title}，${agentName}，${label}${isFollowed ? "，正在跟随" : "，点击固定跟随"}`);
}

function computeSessionRows() {
  const activityById = new Map((Array.isArray(snapshot?.sessions) ? snapshot.sessions : [])
    .map((item) => [item.sessionId, item]));
  const listed = Array.isArray(sessionList.sessions) ? sessionList.sessions : [];
  const rowsById = new Map(listed
    .filter((item) => item?.lifecycle !== "archived" && isPinnableOption(item?.sessionId))
    .map((item) => {
      const activity = activityById.get(item.sessionId);
      return [item.sessionId, activity ? {
        ...item,
        ...activity,
        title: activity.displayTitle ?? activity.title ?? item.title,
        agentName: activity.agentName ?? item.agentName,
        agentId: activity.agentId ?? item.agentId,
      } : item];
    }));
  // If the host session-list capability is unavailable, keep known active event
  // rows pinnable; never override an explicit archived lifecycle from the list.
  // A row only counts as closed when nothing happened after the close, matching
  // the backend rule: a resumed session must stay pickable.
  const closedRow = (item) => (item?.closedAt ?? 0) > 0 && (item.closedAt >= (item.lastActivityAt ?? 0));
  if (!sessionList.available) {
    for (const item of Array.isArray(snapshot?.sessions) ? snapshot.sessions : []) {
      if (closedRow(item) || !isPinnableOption(item?.sessionId) || rowsById.has(item.sessionId) ||
          listed.some((entry) => entry?.sessionId === item?.sessionId && entry.lifecycle === "archived")) continue;
      rowsById.set(item.sessionId, item);
    }
  }
  return [...rowsById.values()].sort((a, b) => (b.lastActivityAt ?? 0) - (a.lastActivityAt ?? 0) ||
    listRowTitle(a).localeCompare(listRowTitle(b)));
}

function ensureEmptyRow() {
  if (!emptyRow) {
    emptyRow = document.createElement("li");
    emptyRow.className = "empty";
  }
  return emptyRow;
}

function renderSessions(followedId) {
  const rows = computeSessionRows();
  if (!rows.length) {
    for (const row of sessionRowCache.values()) row.li.remove();
    sessionRowCache.clear();
    const empty = ensureEmptyRow();
    empty.textContent = diagnostics?.list
      ? "会话清单暂不可用"
      : sessionList.available ? "暂无可跟随的会话" : "等待公开会话事件";
    nodes.sessions.replaceChildren(empty);
    nodes.sessionsTitle.textContent = "会话";
    return;
  }
  if (emptyRow) {
    emptyRow = null;
    nodes.sessions.replaceChildren();
  } else {
    // The static placeholder from panel.html is not in the row cache; drop it
    // before the first real rows are inserted, or it would linger at the end.
    const stale = [...nodes.sessions.children].filter((child) => child.className === "empty");
    for (const child of stale) child.remove();
  }
  const seen = new Set(rows.map((item) => item.sessionId));
  for (const [sessionId, row] of sessionRowCache) {
    if (seen.has(sessionId)) continue;
    row.li.remove();
    sessionRowCache.delete(sessionId);
  }
  rows.forEach((item, index) => {
    let row = sessionRowCache.get(item.sessionId);
    if (!row) {
      row = createSessionRow();
      sessionRowCache.set(item.sessionId, row);
    }
    updateSessionRow(row, item, followedId);
    const current = nodes.sessions.children[index] ?? null;
    if (current !== row.li) nodes.sessions.insertBefore(row.li, current);
  });
  nodes.sessionsTitle.textContent = `会话 · ${rows.length}`;
}

function listRowTitle(item) {
  return safeText(item?.displayTitle ?? item?.title, `会话 · ${shortId(item?.sessionId)}`);
}

function shortId(sessionId) {
  const safe = typeof sessionId === "string" ? sessionId.replace(/[^A-Za-z0-9_-]/g, "") : "";
  return safe.slice(-8) || "未知";
}

function renderDiagnostics() {
  nodes.diagRevision.textContent = Number.isSafeInteger(snapshot?.revision) ? String(snapshot.revision) : "—";
  nodes.diagEventCount.textContent = "当前快照不提供";
  nodes.diagSessionCount.textContent = String(Array.isArray(snapshot?.sessions) ? snapshot.sessions.length : 0);

  // Technical fields only; a manual idle preview is never dressed up as a readback.
  const live = bridgeStatus === "connected" ? poseState : null;
  nodes.diagPoseRole.textContent = live ? live.characterId : "—";
  nodes.diagPoseName.textContent = live ? live.pose : "—";
  nodes.diagPoseFallback.textContent = live ? (live.fallback ? "是" : "否") : "—";
  nodes.diagPoseRevision.textContent = live ? String(live.revision) : "—";
  nodes.diagPoseSince.textContent = live ? clockTime(live.since) : "—";

  let recentError = null;
  if (bridgeEnabled && bridgeStatus === "offline") {
    recentError = BRIDGE_REASON_LABELS[bridgeReason] ?? "桌宠连接失败";
  } else {
    const diagnostic = diagnostics?.get ?? diagnostics?.list ?? null;
    if (diagnostic) {
      const operation = diagnostic.operation === "session:get" ? "会话详情" : "会话清单";
      const reason = diagnosticLabels[diagnostic.kind] ?? "调用失败";
      recentError = `${operation}：${reason} · ${safeText(diagnostic.code, "未知错误码")}`;
    }
  }
  nodes.diagError.textContent = recentError ?? "无";
  nodes.diagError.dataset.state = recentError ? "error" : "ok";
}

/**
 * Space the list can use inside its own panel. Measuring the panel minus the
 * current list height would treat the first (short) list as permanent chrome and
 * lock the panel to too few rows — which is exactly what happened on first paint.
 */
function availableListHeight() {
  const panel = nodes.sessions.parentElement;
  const style = getComputedStyle(panel);
  const padding = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
  const heading = panel.querySelector(".section-heading");
  const headingHeight = heading && typeof heading.getBoundingClientRect === "function"
    ? heading.getBoundingClientRect().height
    : 0;
  const headingMargin = heading ? (parseFloat(getComputedStyle(heading).marginBottom) || 0) : 0;
  return panel.clientHeight - padding - headingHeight - headingMargin;
}

function syncSessionListHeight() {
  const list = nodes.sessions;
  // 面板冒烟测试用最小 DOM stub 跑模块体，没有布局 API 时直接跳过测量。
  if (typeof list.querySelector !== "function" || typeof list.getBoundingClientRect !== "function" ||
      typeof getComputedStyle !== "function") return;
  const panel = list.parentElement;
  if (!panel || typeof panel.getBoundingClientRect !== "function") return;
  const first = list.querySelector(".session");
  if (!first) {
    sessionSnapKey = "";
    if (list.style.maxHeight) list.style.maxHeight = "";
    panel.classList.remove("is-compact");
    return;
  }
  const rowHeight = first.getBoundingClientRect().height + SESSION_ROW_GAP;
  if (!(rowHeight > SESSION_ROW_GAP)) return;
  const key = `${list.childElementCount}|${Math.round(rowHeight)}|${panel.clientHeight}|${panel.clientWidth}`;
  if (key === sessionSnapKey) return;
  sessionSnapKey = key;
  const available = availableListHeight();
  if (!(available > rowHeight)) {
    list.style.maxHeight = "";
    return;
  }
  const fit = Math.max(1, Math.floor((available + SESSION_ROW_GAP) / rowHeight));
  if (list.childElementCount <= fit) {
    panel.classList.add("is-compact");
    list.style.maxHeight = "";
    return;
  }
  panel.classList.remove("is-compact");
  list.style.maxHeight = `${Math.round(fit * rowHeight - SESSION_ROW_GAP)}px`;
}

/** 面板显示的连接状态：关闭意味着一律当 disabled，不把旧失败原因带回来。 */
function visibleConnectionState() {
  return bridgeEnabled ? bridgeStatus : "disabled";
}

function renderConnection() {
  const visible = visibleConnectionState();
  let label = CONNECTION_LABELS[visible] ?? "连接状态未知";
  let note = "";
  if (visible === "offline") {
    label = OFFLINE_LABELS[bridgeReason] ?? "连接失败";
    note = BRIDGE_REASON_LABELS[bridgeReason] ?? "暂时无法连接桌宠，请确认它已打开。";
  }
  nodes.bridgeState.textContent = label;
  nodes.bridgeState.dataset.status = CONNECTION_STATUSES.has(visible) ? visible : "error";
  nodes.connectionNote.textContent = note;
  nodes.connectionNote.hidden = !note;
  nodes.bridgeToggle.checked = bridgeEnabled;
  return visible;
}

const DOWNLOAD_PLATFORM_LABELS = Object.freeze({ windows: "Windows 版", mac: "macOS 版" });

/**
 * 引导只做三件事：解释现在的连接状态、指向两个固定平台入口、在打开失败时
 * 给出可手动复制的同一地址。它不根据状态推断「装了/没装」，也不猜宿主系统。
 */
function onboardingModel(visible) {
  if (!stateReadable) return { lead: ONBOARDING_COPY.unknown, state: "unknown" };
  if (visible === "connected") return null;
  if (visible === "offline") {
    return {
      lead: ONBOARDING_OFFLINE_COPY[bridgeReason] ?? ONBOARDING_OFFLINE_FALLBACK,
      state: "offline",
    };
  }
  const state = visible === "connecting" ? "connecting" : "disabled";
  return { lead: ONBOARDING_COPY[state], state };
}

function renderOnboarding(visible) {
  const model = onboardingModel(visible);
  if (!model) {
    // 连上以后收起主要引导；降级提示和已展开的说明都不留在屏幕上，
    // 下次断开时重新从真实结果开始。
    onboardingFallback = null;
    if (nodes.onboardingHelp?.open) nodes.onboardingHelp.open = false;
    nodes.onboarding.hidden = true;
    nodes.onboardingLead.textContent = "";
    nodes.onboardingFallback.hidden = true;
    if (nodes.onboardingFallbackUrl.textContent) nodes.onboardingFallbackUrl.textContent = "";
    return;
  }
  nodes.onboarding.hidden = false;
  nodes.onboarding.dataset.state = model.state;
  nodes.onboardingLead.textContent = model.lead;
  nodes.onboardingLead.dataset.state = model.state;

  const fallback = onboardingFallback;
  nodes.onboardingFallback.hidden = !fallback;
  if (fallback) {
    nodes.onboardingFallbackText.textContent = `${DOWNLOAD_FAILED_TEXT}（${fallback.platformLabel}）`;
    if (nodes.onboardingFallbackUrl.textContent !== fallback.url) {
      nodes.onboardingFallbackUrl.textContent = fallback.url;
    }
  } else if (nodes.onboardingFallbackUrl.textContent) {
    nodes.onboardingFallbackUrl.textContent = "";
  }
}

/** 把降级地址整体选中，键盘用户可直接 Ctrl/⌘+C；不自动写剪贴板。 */
function selectFallbackUrl() {
  const node = nodes.onboardingFallbackUrl;
  node.focus?.();
  try {
    if (typeof document.createRange !== "function" || !window.getSelection) return;
    const range = document.createRange();
    range.selectNodeContents(node);
    const selection = window.getSelection();
    selection?.removeAllRanges?.();
    selection?.addRange?.(range);
  } catch {
    // 选区不可用时仍保留可点击、可拖选的文本，不阻断用户。
  }
}

/**
 * 只允许打开白名单里的固定 HTTPS 地址。宿主拒绝或调用失败时退到可复制的
 * 同一地址：不新增剪贴板能力，也不尝试其它跳转路径。
 */
async function openPetDownload(platform) {
  const entry = PET_DOWNLOADS[platform];
  if (!entry) return;
  const platformLabel = DOWNLOAD_PLATFORM_LABELS[platform];
  let failure = null;
  try {
    const external = hana.external;
    if (!external || typeof external.open !== "function") {
      throw new Error("hana.external.open is unavailable");
    }
    await external.open({ url: entry.url });
  } catch (error) {
    failure = error;
  }
  if (failure) {
    console.warn("Hana 桌宠面板无法直接打开下载链接；已退到可复制链接。",
      failure?.code ?? failure?.name ?? "unknown");
    onboardingFallback = { platform, platformLabel, url: entry.url };
    render();
    selectFallbackUrl();
    return;
  }
  onboardingFallback = null;
  renderOnboarding(visibleConnectionState());
  // 浏览器已经接手，这里只是回显；用中性色，不把成功消息画画成告警。
  setNotice("已在浏览器打开下载链接。", "ok");
}

function render() {
  const visibleConnection = renderConnection();
  const followedId = getFollowedId();
  const current = getFollowedSession() ?? null;
  const status = visibleStatus(current);
  renderStage(stageModel());

  nodes.followTarget.textContent = current ? `跟随会话：${listRowTitle(current)}` : "等待会话活动";
  nodes.followTarget.title = current ? listRowTitle(current) : "";
  const agent = safeText(current?.agentName, current?.agentId ? `Agent ${current.agentId}` : "Agent 未知");
  const age = current?.lastActivityAt > 0 ? relativeTime(current.lastActivityAt) : "暂无活动";
  nodes.agent.textContent = `${agent} · ${age}`;
  nodes.status.textContent = statusText(status, current);
  nodes.status.className = `status-pill ${status}`;

  nodes.followMode.textContent = follow.mode === "pinned" ? "固定跟随" : "自动跟随";
  nodes.followMode.dataset.mode = follow.mode;
  nodes.followAuto.hidden = follow.mode !== "pinned";
  renderRoleOptions();
  renderOnboarding(visibleConnection);
  renderFollowReleaseNotice();
  renderSessions(followedId);
  syncSessionListHeight();
  renderDiagnostics();
  renderLegacyFollowOptions();
  renderLegacySessionDiagnostics();
  renderLegacyHint();
}

async function refresh() {
  try {
    const [nextSnapshot, nextSelection, nextEnabled, nextStatus, nextList, nextFollow, nextDiagnostics] = await Promise.all([
      readStorage(SNAPSHOT_KEY),
      readStorage(SELECTION_KEY),
      readStorage(BRIDGE_ENABLED_KEY),
      readStorage(BRIDGE_STATUS_KEY),
      readStorage(SESSION_LIST_KEY),
      readStorage(FOLLOW_KEY),
      readStorage(SESSION_DIAGNOSTICS_KEY),
    ]);
    snapshot = nextSnapshot && typeof nextSnapshot === "object" ? nextSnapshot : null;
    sessionList = nextList && typeof nextList === "object"
      ? { available: nextList.available === true, sessions: Array.isArray(nextList.sessions) ? nextList.sessions : [] }
      : { available: false, sessions: [] };
    follow = nextFollow && typeof nextFollow === "object"
      ? {
          mode: nextFollow.mode === "pinned" ? "pinned" : "latest",
          pinnedSessionId: typeof nextFollow.pinnedSessionId === "string" ? nextFollow.pinnedSessionId : null,
          followedSessionId: typeof nextFollow.followedSessionId === "string" ? nextFollow.followedSessionId : null,
          released: normalizeFollowRelease(nextFollow.released),
        }
      : { mode: "latest", pinnedSessionId: null, followedSessionId: null, released: null };
    diagnostics = nextDiagnostics && typeof nextDiagnostics === "object" && !Array.isArray(nextDiagnostics)
      ? {
          list: nextDiagnostics.list && typeof nextDiagnostics.list === "object" ? nextDiagnostics.list : null,
          get: nextDiagnostics.get && typeof nextDiagnostics.get === "object" ? nextDiagnostics.get : null,
        }
      : { list: null, get: null };
    if (nextSelection && typeof nextSelection === "object") {
      selection = {
        characterId: ROLES.some((role) => role.id === nextSelection.characterId) ? nextSelection.characterId : ROLES[0].id,
        updatedAt: Number.isSafeInteger(nextSelection.updatedAt) && nextSelection.updatedAt >= 0 ? nextSelection.updatedAt : 0,
        petRevision: Number.isSafeInteger(nextSelection.petRevision) && nextSelection.petRevision >= 0 ? nextSelection.petRevision : 0,
      };
    }
    bridgeEnabled = nextEnabled === true;
    const statusRecord = nextStatus && typeof nextStatus === "object" && !Array.isArray(nextStatus) ? nextStatus : null;
    const rawStatus = typeof nextStatus === "string" ? nextStatus : statusRecord?.status;
    bridgeStatus = bridgeEnabled
      ? (CONNECTION_STATUSES.has(rawStatus) && rawStatus !== "disabled" ? rawStatus : "connecting")
      : "disabled";
    bridgeReason = BRIDGE_REASONS.has(statusRecord?.reason) ? statusRecord.reason : null;
    poseState = bridgeEnabled && bridgeStatus === "connected" ? normalizePoseState(statusRecord?.poseState) : null;
    stateReadable = true;
    render();
  } catch {
    // 状态读不到就不写任何连接结论，也不根据旧值推断安装情况。
    stateReadable = false;
    nodes.bridgeState.textContent = "状态暂不可读";
    nodes.bridgeState.dataset.status = "error";
    nodes.connectionNote.textContent = "控制台状态暂不可读，请稍后重试。";
    nodes.connectionNote.hidden = false;
    renderOnboarding(null);
    setNotice("");
  }
}

async function setFollowTarget(value) {
  const pinnedSessionId = typeof value === "string" && value !== LATEST_VALUE ? value : null;
  const previous = follow;
  follow = {
    ...follow,
    mode: pinnedSessionId ? "pinned" : "latest",
    pinnedSessionId,
    followedSessionId: pinnedSessionId ?? snapshot?.current?.sessionId ?? null,
    released: null,
  };
  render();
  try {
    await hana.storage.global.set(FOLLOW_REQUEST_KEY, {
      requestId: `req-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      pinnedSessionId,
    });
    setNotice("");
  } catch {
    follow = previous;
    render();
    setNotice(pinnedSessionId ? "固定会话请求未能保存，已恢复原跟随方式。" : "恢复自动跟随失败，已恢复原选择。");
  }
}

nodes.followAuto.addEventListener("click", () => void setFollowTarget(LATEST_VALUE));
nodes.followSelect.addEventListener("change", () => void setFollowTarget(nodes.followSelect.value));
nodes.followSelect.addEventListener("mousedown", () => { followSelectOpen = true; });
nodes.followSelect.addEventListener("focus", () => { followSelectOpen = true; });
nodes.followSelect.addEventListener("blur", () => {
  followSelectOpen = false;
  if (followSelectDeferred !== null) {
    followSelectSignature = null;
    followSelectDeferred = null;
    renderLegacyFollowOptions();
  }
});
nodes.followSelect.addEventListener("keydown", (event) => {
  if (event.key === "Escape" || event.key === "Enter") {
    followSelectOpen = false;
    if (followSelectDeferred !== null) {
      followSelectSignature = null;
      followSelectDeferred = null;
      renderLegacyFollowOptions();
    }
  }
});
nodes.bridgeToggle.addEventListener("change", async () => {
  const previousEnabled = bridgeEnabled;
  const previousStatus = bridgeStatus;
  const previousReason = bridgeReason;
  const previousPoseState = poseState;
  const requested = nodes.bridgeToggle.checked;
  bridgeEnabled = requested;
  bridgeStatus = requested ? "connecting" : "disabled";
  bridgeReason = null;
  poseState = null;
  render();
  try {
    await hana.storage.global.set(BRIDGE_ENABLED_KEY, bridgeEnabled);
    setNotice("");
  } catch {
    bridgeEnabled = previousEnabled;
    bridgeStatus = previousStatus;
    bridgeReason = previousReason;
    poseState = previousPoseState;
    render();
    setNotice("连接开关未能保存，已恢复原状态。");
  }
});

// 下载入口是真实的 <a href>（带说明的 Release 附件），让键盘与辅助技术看到链接语义；
// 点击时交给宿主的外部打开能力，避免在沙箱 iframe 里导航或静默失败。
for (const [platform, anchor] of [["windows", nodes.downloadWindows], ["mac", nodes.downloadMac]]) {
  if (!anchor) continue;
  anchor.addEventListener("click", (event) => {
    event.preventDefault();
    void openPetDownload(platform);
  });
}

// 安装说明是浮层：键盘用户用 Esc 或点外面关掉，不抢焦点、不留隐性遮挡。
const onboardingHelpNode = nodes.onboardingHelp;
if (onboardingHelpNode) {
  document.addEventListener?.("keydown", (event) => {
    if (event.key === "Escape" && onboardingHelpNode.open) onboardingHelpNode.open = false;
  });
  document.addEventListener?.("pointerdown", (event) => {
    if (!onboardingHelpNode.open) return;
    const path = typeof event.composedPath === "function" ? event.composedPath() : [];
    if (!path.includes(onboardingHelpNode)) onboardingHelpNode.open = false;
  });
}

hana.ready();
const stop = hana.storage.global.onChanged((keys) => {
  const watched = [SNAPSHOT_KEY, SELECTION_KEY, BRIDGE_ENABLED_KEY, BRIDGE_STATUS_KEY, SESSION_LIST_KEY, FOLLOW_KEY, SESSION_DIAGNOSTICS_KEY];
  if (keys.some((key) => watched.includes(key))) void refresh();
});
const ticker = window.setInterval(() => {
  if (snapshot) render();
}, 1000);
// 展开诊断、出现提示条或窗口尺寸变化都会改变列表可用高度，重算一次整行对齐。
if (typeof ResizeObserver === "function") {
  const sessionPanel = nodes.sessions.parentElement;
  new ResizeObserver(() => {
    sessionSnapKey = "";
    syncSessionListHeight();
  }).observe(sessionPanel);
}
window.addEventListener("resize", () => {
  if (resizeTimer !== null) window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(() => {
    resizeTimer = null;
    sessionSnapKey = "";
    syncSessionListHeight();
  }, 120);
});
window.addEventListener("pagehide", () => {
  stop();
  stopTheme();
  window.clearInterval(ticker);
  if (noticeTimer !== null) window.clearTimeout(noticeTimer);
  if (resizeTimer !== null) window.clearTimeout(resizeTimer);
}, { once: true });
void refresh();
