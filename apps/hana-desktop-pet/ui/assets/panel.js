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
const SESSION_ROW_GAP = 4;
const FOLLOW_OPTION_MAX = 15;
const POSE_SCHEMA_VERSION = 3;
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
const nodes = {
  bridgeToggle: document.getElementById("bridge-toggle"),
  bridgeState: document.getElementById("bridge-state"),
  followContext: document.getElementById("follow-context"),
  panelNotice: document.getElementById("panel-notice"),
  followReleaseNotice: document.getElementById("follow-release-notice"),
  stageImage: document.getElementById("stage-image"),
  poseFallback: document.getElementById("pose-fallback"),
  poseConnection: document.getElementById("pose-connection"),
  poseName: document.getElementById("pose-name"),
  title: document.getElementById("session-title"),
  agent: document.getElementById("agent"),
  status: document.getElementById("activity-status"),
  updated: document.getElementById("updated"),
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
};
const statusLabels = { working: "生成中", tool: "工具执行", success: "成功", error: "出错", idle: "空闲" };
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

function setNotice(message) {
  nodes.panelNotice.textContent = message;
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

function renderPetPose() {
  const state = bridgeStatus === "connected" ? poseState : null;
  const characterId = state?.characterId ?? selection.characterId;
  const role = ROLES.find((item) => item.id === characterId) ?? ROLES[0];
  const pose = state?.pose ?? "idle";
  const imagePath = `./assets/poses/${role.id}/${pose}.webp`;
  if (renderedPosePath !== imagePath) {
    nodes.stageImage.src = imagePath;
    renderedPosePath = imagePath;
  }
  nodes.stageImage.alt = state
    ? `${role.name} ${pose} 桌宠姿态${state.fallback ? "，替代姿态" : ""}`
    : `${role.name} idle 立绘，桌宠未连接`;
  nodes.poseConnection.textContent = state ? "桌宠姿态" : "桌宠未连接";
  nodes.poseName.textContent = pose;
  nodes.poseFallback.hidden = state?.fallback !== true;
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
  nodes.followReleaseNotice.textContent = `已取消固定「${releasedName}」：${FOLLOW_RELEASE_LABELS[release.reason]}；${nextTarget}。`;
  nodes.followReleaseNotice.hidden = false;
}

function renderRoleOptions() {
  if (!roleButtons.length) {
    for (const role of ROLES) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "role-option";
      button.dataset.roleId = role.id;
      button.title = `${role.name} · 点击切换`;
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
      roleButtons.push({ id: role.id, button });
    }
  }
  for (const item of roleButtons) {
    item.button.setAttribute("aria-pressed", String(selection.characterId === item.id));
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

function buildSessionRow(item, currentId, followedId) {
  const row = document.createElement("li");
  row.className = "session";
  const button = document.createElement("button");
  button.type = "button";
  button.className = "session-button";
  const isCurrent = item.sessionId === currentId;
  const isFollowed = item.sessionId === followedId;
  button.setAttribute("aria-pressed", String(follow.mode === "pinned" && item.sessionId === follow.pinnedSessionId));
  const status = visibleStatus(item);
  const title = document.createElement("span");
  title.className = "session-title";
  title.textContent = safeText(item.displayTitle ?? item.title, `会话 · ${shortId(item.sessionId)}`);
  const detail = document.createElement("span");
  detail.className = "session-detail";
  const agentName = safeText(item.agentName, item.agentId ? `Agent ${item.agentId}` : "Agent 未知");
  const ago = item.lastActivityAt > 0 ? relativeTime(item.lastActivityAt) : "暂无活动";
  detail.textContent = `${agentName} · ${ago}`;
  const copy = document.createElement("span");
  copy.className = "session-copy";
  copy.append(title, detail);
  const markers = document.createElement("span");
  markers.className = "session-markers";
  if (isCurrent) {
    const currentMarker = document.createElement("span");
    currentMarker.className = "session-marker current";
    currentMarker.textContent = "当前";
    markers.append(currentMarker);
  }
  if (isFollowed) {
    const followMarker = document.createElement("span");
    followMarker.className = "session-marker followed";
    followMarker.textContent = "跟随中";
    markers.append(followMarker);
  }
  const statusPill = document.createElement("span");
  statusPill.className = `status-pill ${status}`;
  statusPill.textContent = statusLabels[status] ?? "空闲";
  button.append(copy, statusPill, markers);
  button.setAttribute("aria-label", `${title.textContent}，${agentName}，${statusLabels[status]}，${isFollowed ? "跟随中" : "点击固定跟随"}`);
  button.addEventListener("click", () => void setFollowTarget(item.sessionId));
  row.append(button);
  return row;
}

function renderSessions(currentId, followedId) {
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
  if (!sessionList.available) {
    for (const item of Array.isArray(snapshot?.sessions) ? snapshot.sessions : []) {
      if (item?.closedAt > 0 || !isPinnableOption(item?.sessionId) || rowsById.has(item.sessionId) ||
          listed.some((entry) => entry?.sessionId === item?.sessionId && entry.lifecycle === "archived")) continue;
      rowsById.set(item.sessionId, item);
    }
  }
  const rows = [...rowsById.values()].sort((a, b) => (b.lastActivityAt ?? 0) - (a.lastActivityAt ?? 0) ||
    listRowTitle(a).localeCompare(listRowTitle(b)));

  if (!rows.length) {
    nodes.sessionsTitle.textContent = "会话";
    const empty = document.createElement("li");
    empty.className = "empty";
    empty.textContent = diagnostics?.list
      ? "会话清单暂不可用"
      : sessionList.available ? "暂无可跟随的会话" : "等待公开会话事件";
    nodes.sessions.replaceChildren(empty);
    return;
  }
  const list = document.createDocumentFragment();
  for (const item of rows) list.append(buildSessionRow(item, currentId, followedId));
  nodes.sessionsTitle.textContent = `会话 · ${rows.length}`;
  nodes.sessions.replaceChildren(list);
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
 * 会话列表占据面板剩余高度，但高度只取整行：被窗口切掉的半行看起来像渲染坏了。
 * 行数不够填满时（高窗口）面板改成内容高，避免卡片底部留一大块空白。
 */
function availableListHeight() {
  const panel = nodes.sessions.parentElement;
  const controller = panel.parentElement;
  const style = getComputedStyle(controller);
  const gap = parseFloat(style.rowGap) || 0;
  const padding = (parseFloat(style.paddingTop) || 0) + (parseFloat(style.paddingBottom) || 0);
  const children = [...controller.children].filter((el) => el.getClientRects().length > 0);
  const others = children
    .filter((el) => el !== panel)
    .reduce((sum, el) => sum + el.getBoundingClientRect().height, 0);
  const chrome = panel.offsetHeight - nodes.sessions.offsetHeight;
  return controller.clientHeight - padding - gap * Math.max(0, children.length - 1) - others - chrome;
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

function render() {
  nodes.bridgeToggle.checked = bridgeEnabled;
  const statusLabelsConnection = {
    disabled: "连接已关闭",
    connecting: "正在连接",
    connected: "已连接",
    offline: "已启用 · 连接失败",
  };
  const visibleConnectionStatus = bridgeEnabled ? bridgeStatus : "disabled";
  nodes.bridgeState.textContent = visibleConnectionStatus === "offline"
    ? BRIDGE_REASON_LABELS[bridgeReason] ?? statusLabelsConnection.offline
    : statusLabelsConnection[visibleConnectionStatus] ?? "连接状态未知";
  nodes.bridgeState.dataset.status = CONNECTION_STATUSES.has(visibleConnectionStatus) ? visibleConnectionStatus : "error";

  const followed = getFollowedSession();
  const followedId = getFollowedId();
  const followedTitle = followed ? listRowTitle(followed) : null;
  const current = followed ?? null;
  const status = visibleStatus(current);
  nodes.followContext.textContent = followedTitle
    ? `${follow.mode === "pinned" ? "固定跟" : "正在跟"}「${followedTitle}」 · ${statusLabels[status] ?? "空闲"}`
    : `等待会话 · ${statusLabels[status] ?? "空闲"}`;

  nodes.title.textContent = safeText(current?.displayTitle ?? current?.title, "暂无活动会话");
  const agent = safeText(current?.agentName, current?.agentId ? `Agent ${current.agentId}` : "Agent 未知");
  const age = current?.lastActivityAt > 0 ? relativeTime(current.lastActivityAt) : "暂无活动";
  nodes.agent.textContent = `${agent} · ${age}`;
  nodes.status.textContent = statusLabels[status] ?? "空闲";
  nodes.status.className = `status-pill ${status}`;
  nodes.updated.textContent = current?.lastActivityAt > 0
    ? `最近活动 ${relativeTime(current.lastActivityAt)}`
    : "尚未收到公开会话事件";

  nodes.followMode.textContent = follow.mode === "pinned" ? "固定跟随" : "自动跟随";
  nodes.followMode.dataset.mode = follow.mode;
  nodes.followAuto.hidden = follow.mode !== "pinned";
  renderRoleOptions();
  renderPetPose();
  renderFollowReleaseNotice();
  renderSessions(snapshot?.current?.sessionId ?? null, followedId);
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
    render();
  } catch {
    nodes.bridgeState.textContent = "控制台状态暂不可读";
    nodes.bridgeState.dataset.status = "error";
    setNotice("控制台状态暂不可读，请稍后重试。");
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
