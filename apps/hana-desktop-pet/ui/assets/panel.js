import { hana } from "./sdk.js";

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
const ROLES = [
  { id: "claude", name: "Claude", color: "#c96e43" },
  { id: "gpt", name: "GPT 白龙", color: "#729bc2" },
  { id: "deepseek", name: "DeepSeek 大肥鱼", color: "#2b75bd" },
  { id: "gemini", name: "Gemini", color: "#835bc7" },
  { id: "glm", name: "GLM 黑狐狸", color: "#343b50" },
  { id: "deepseek-hoodie", name: "大肥鱼·Claude 卫衣", color: "#5473a4" },
  { id: "gpt-onesie", name: "GPT 降智龙崽", color: "#9a83cd" },
];
const nodes = {
  bridgeToggle: document.getElementById("bridge-toggle"),
  sessionStatus: document.getElementById("session-status"),
  bridgeState: document.getElementById("bridge-state"),
  roles: document.getElementById("role-options"),
  status: document.getElementById("activity-status"),
  title: document.getElementById("session-title"),
  agent: document.getElementById("agent"),
  tool: document.getElementById("tool"),
  updated: document.getElementById("updated"),
  hint: document.getElementById("activity-hint"),
  sessions: document.getElementById("sessions"),
  followSelect: document.getElementById("follow-select"),
  followMode: document.getElementById("follow-mode"),
  followNote: document.getElementById("follow-note"),
};
const HINT_LABELS = {
  confirming: "等待确认",
  compacting: "上下文压缩中",
  interrupted: "插话被丢弃",
};

/**
 * Mirror the hint the pet is showing. Mirrors only: the enum is validated here too,
 * so a tampered storage value can never reach the DOM.
 */
function renderHint(current) {
  if (!nodes.hint) return;
  const hint = typeof current?.hint === "string" && Object.prototype.hasOwnProperty.call(HINT_LABELS, current.hint)
    ? current.hint
    : null;
  nodes.hint.textContent = hint ? HINT_LABELS[hint] : "";
  nodes.hint.dataset.hint = hint ?? "none";
}

const statusLabels = { working: "工作中", tool: "工具运行", success: "成功反馈", error: "工具报错", idle: "空闲" };
let snapshot = null;
let selection = { characterId: "claude", updatedAt: 0, petRevision: 0 };
let bridgeEnabled = false;
let bridgeStatus = "disabled";
let sessionList = { available: false, sessions: [] };
let diagnostics = { list: null, get: null };
let followSelectSignature = null;
let followSelectDeferred = null;
let followSelectOpen = false;
let follow = { mode: "latest", pinnedSessionId: null, followedSessionId: null, reason: "no_activity", released: null };
let roleButtons = [];

async function readStorage(key) {
  const result = await hana.storage.global.get(key);
  return result && typeof result === "object" && Object.prototype.hasOwnProperty.call(result, "value")
    ? result.value
    : result;
}

function safeText(value, fallback = "—") {
  return typeof value === "string" && value.trim() ? value.trim() : fallback;
}

/**
 * Reject ids this App invented itself. The list and the snapshot both carry
 * unresolved placeholders, and a placeholder is not something the user can name.
 */
function isPinnableOption(sessionId) {
  return typeof sessionId === "string" && sessionId.length > 0 && !sessionId.startsWith("unresolved:") &&
    !/^local-session-\d+$/.test(sessionId);
}

const DIAGNOSTIC_LABELS = {
  permission: "缺少 app/sessions.read 授权",
  timeout: "宿主会话调用超时",
  aborted: "宿主会话调用被中断",
  unsupported: "宿主不支持该会话接口",
  empty: "宿主返回空结果",
  malformed: "宿主返回结构异常",
  host: "宿主会话调用失败",
};

const RELEASE_LABELS = {
  pinned_closed: "已关闭",
  pinned_archived: "已归档",
  pinned_missing: "已从会话列表消失",
};

/** Rows come from the stored metadata allowlist, so no path/body ever reaches the DOM. */
function listRowTitle(item) {
  return safeText(item?.displayTitle ?? item?.title, `会话 · ${shortId(item?.sessionId)}`);
}

function shortId(sessionId) {
  const safe = typeof sessionId === "string" ? sessionId.replace(/[^A-Za-z0-9_-]/g, "") : "";
  return safe.slice(-8) || "未知";
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
  return `${minutes} 分钟前`;
}

function renderRoleOptions() {
  if (!roleButtons.length) {
    for (const role of ROLES) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "role-option";
      button.dataset.roleId = role.id;
      const swatch = document.createElement("span");
      swatch.className = "role-swatch";
      swatch.style.setProperty("--role-color", role.color);
      swatch.setAttribute("aria-hidden", "true");
      const label = document.createElement("span");
      label.textContent = role.name;
      button.append(swatch, label);
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
  if (!role) return;
  selection = { ...selection, characterId, updatedAt: Date.now() };
  renderRoleOptions();
  try {
    await hana.storage.global.set(SELECTION_KEY, selection);
  } catch {
    nodes.bridgeState.textContent = "角色未能保存";
    nodes.bridgeState.dataset.status = "error";
  }
}

function buildSessionRow(item, currentId, pinnedId) {
  const row = document.createElement("li");
  row.className = item.sessionId === currentId ? "session current-row" : "session";
  const top = document.createElement("div");
  top.className = "session-top";
  const title = document.createElement("span");
  title.className = "session-title";
  title.textContent = listRowTitle(item);
  const status = visibleStatus(item);
  const pill = document.createElement("span");
  pill.className = `status-pill ${status}`;
  pill.textContent = statusLabels[status] ?? "空闲";
  top.append(title, pill);
  if (item.sessionId === pinnedId) {
    const pin = document.createElement("span");
    pin.className = "pin-tag";
    pin.textContent = "已钉住";
    title.append(" ", pin);
  }
  const detail = document.createElement("p");
  detail.className = "session-detail";
  const agent = safeText(item.agentName, item.agentId ? `Agent ${item.agentId}` : "Agent 未知");
  const tool = safeText(item.toolName, "无工具");
  const ago = item.lastActivityAt > 0 ? relativeTime(item.lastActivityAt) : "暂无活动";
  detail.textContent = `${agent} · ${tool} · ${ago}`;
  row.append(top, detail);
  return row;
}

function renderSessions(items, currentId, pinnedId) {
  const rows = (Array.isArray(items) ? items : [])
    .filter((item) => item?.lastActivityAt > 0 || item?.sessionId === pinnedId)
    .slice(0, 6);
  if (!rows.length) {
    const empty = document.createElement("li");
    empty.className = "empty";
    empty.textContent = "等待公开会话事件";
    nodes.sessions.replaceChildren(empty);
    return;
  }
  const list = document.createDocumentFragment();
  for (const item of rows) list.append(buildSessionRow(item, currentId, pinnedId));
  nodes.sessions.replaceChildren(list);
}

/**
 * Rebuild the option list only when its content actually changed, and never while
 * the user has the dropdown open or focused — the panel re-renders every second,
 * and a full rebuild would make the open list flicker and fight the selection.
 */
const FOLLOW_OPTION_MAX = 15;

/**
 * The picker lists active sessions only, most recently active first.
 *
 * Archived sessions are deliberately excluded with no opt-out toggle: they exist only
 * to backfill a title inside the snapshot. A previous round let them into this list and
 * a user with 63 archived sessions got an unusable wall of "已归档 · 不可钉" entries.
 */
function pickableSessions() {
  const entries = Array.isArray(sessionList.sessions) ? sessionList.sessions : [];
  const activity = new Map();
  for (const item of (Array.isArray(snapshot?.sessions) ? snapshot.sessions : [])) {
    if (item?.sessionId) activity.set(item.sessionId, item.lastActivityAt ?? 0);
  }
  return entries
    .filter((item) => item?.lifecycle !== "archived" && isPinnableOption(item?.sessionId))
    .sort((a, b) => (activity.get(b.sessionId) ?? 0) - (activity.get(a.sessionId) ?? 0) ||
      a.sessionId.localeCompare(b.sessionId))
    .slice(0, FOLLOW_OPTION_MAX);
}

function renderFollowOptions() {
  const options = pickableSessions();
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

  if (nodes.followSelect.disabled !== (options.length === 0)) {
    nodes.followSelect.disabled = options.length === 0;
  }
  // Only touch `value` when it is wrong; assigning it can disturb an open list.
  if (followSelectSignature !== null && nodes.followSelect.value !== selected) {
    nodes.followSelect.value = selected;
  }
  if (signature === followSelectSignature) return;
  if (isFollowSelectBusy()) {
    // Defer the rebuild until the dropdown is closed.
    followSelectDeferred = signature;
    return;
  }
  nodes.followSelect.replaceChildren(fragment);
  followSelectSignature = signature;
  nodes.followSelect.value = selected;
}

/** True while the dropdown is open or focused, so we never rebuild under the user. */
function isFollowSelectBusy() {
  return followSelectOpen === true ||
    (typeof document.activeElement === "object" && document.activeElement === nodes.followSelect);
}

function renderFollow() {
  nodes.followMode.textContent = follow.mode === "pinned" ? "已钉住会话" : "跟随最近活动";
  nodes.followMode.dataset.mode = follow.mode;

  const current = snapshot?.current ?? null;
  const followedId = follow.followedSessionId ?? current?.sessionId ?? null;
  const followedTitle = (Array.isArray(snapshot?.sessions)
    ? snapshot.sessions.find((item) => item.sessionId === followedId)
    : null) ?? (Array.isArray(sessionList.sessions)
    ? sessionList.sessions.find((item) => item.sessionId === followedId)
    : null) ?? null;
  const name = followedTitle ? listRowTitle(followedTitle) : (followedId ? `会话 · ${shortId(followedId)}` : null);

  if (!followedId) {
    nodes.followNote.textContent = "还没有会话活动；桌宠保持空闲，等到有会话产生事件时会跟随。";
  } else if (follow.mode === "pinned") {
    nodes.followNote.textContent = `桌宠跟随被钉住的会话「${name}」；即使其他会话有动静也不会切换。`;
  } else {
    nodes.followNote.textContent = `桌宠跟随最近有活动的会话「${name}」。`;
  }

  const released = follow.released;
  if (released && typeof released === "object") {
    const reason = RELEASE_LABELS[released.reason];
    const releasedName = released.sessionId ? `会话 · ${shortId(released.sessionId)}` : "该会话";
    if (reason) {
      nodes.followNote.textContent +=
        ` 之前钉住的${releasedName}${reason}，已自动取消钉住并回到跟随最近活动。`;
    }
  }
  renderFollowOptions();
  renderSessionDiagnostics();
}

/**
 * The session list is the primary naming source, so only a list failure is a
 * real capability problem. A `session:get` failure is a minor enrichment gap:
 * the list already supplies names, so it must not be shown as an equal warning.
 * Only `kind`/`code` are ever rendered; no message, path or body is stored.
 */
function renderSessionDiagnostics() {
  if (!nodes.sessionStatus) return;
  const listFailure = diagnostics?.list && typeof diagnostics.list === "object" ? diagnostics.list : null;
  const getFailure = diagnostics?.get && typeof diagnostics.get === "object" ? diagnostics.get : null;

  if (listFailure) {
    const label = DIAGNOSTIC_LABELS[listFailure.kind] ?? "宿主返回错误";
    nodes.sessionStatus.textContent = `会话清单不可用 · 原因：${label}（${listFailure.code}）`;
    nodes.sessionStatus.dataset.state = "error";
    return;
  }

  if (getFailure) {
    // Deliberately quiet: the list still names sessions, so this is a caveat.
    const where = getFailure.selector === "path" ? "按路径" : getFailure.selector === "id" ? "按 ID" : "";
    nodes.sessionStatus.textContent = `个别会话详情暂不可读（${where ? `${where} 查询` : "会话详情"}，${getFailure.code}）；会话名称仍取自会话清单。`;
    nodes.sessionStatus.dataset.state = "info";
    return;
  }

  nodes.sessionStatus.textContent = "";
  nodes.sessionStatus.dataset.state = "ok";
}

function render() {
  const statusLabelsConnection = {
    disabled: "未启用",
    connecting: "正在连接",
    connected: "已连接",
    offline: "离线 · 宠物端未响应",
  };
  nodes.bridgeToggle.checked = bridgeEnabled;
  nodes.bridgeState.textContent = statusLabelsConnection[bridgeStatus] ?? "状态未知";
  nodes.bridgeState.dataset.status = bridgeStatus;
  renderRoleOptions();

  const current = snapshot?.current ?? null;
  const state = visibleStatus(current);
  nodes.status.textContent = statusLabels[state] ?? "空闲";
  nodes.status.className = `status-pill ${state}`;
  renderHint(current);
  nodes.title.textContent = safeText(current?.displayTitle, "暂无活动会话");
  nodes.agent.textContent = `Agent：${safeText(current?.agentName, current?.agentId ? `ID ${current.agentId}` : "未知")}`;
  nodes.tool.textContent = `工具：${safeText(current?.toolName, "—")}`;
  nodes.updated.textContent = current ? `最近活动 ${relativeTime(current.lastActivityAt)}` : "尚未收到公开会话事件";
  renderFollow();
  renderSessions(snapshot?.sessions, current?.sessionId, follow.pinnedSessionId);
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
          reason: typeof nextFollow.reason === "string" ? nextFollow.reason : "no_activity",
          released: nextFollow.released && typeof nextFollow.released === "object" ? nextFollow.released : null,
        }
      : { mode: "latest", pinnedSessionId: null, followedSessionId: null, reason: "no_activity", released: null };
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
    bridgeStatus = typeof nextStatus === "string" ? nextStatus : nextStatus?.status ?? (bridgeEnabled ? "offline" : "disabled");
    render();
  } catch {
    nodes.bridgeState.textContent = "控制台状态暂不可读";
    nodes.bridgeState.dataset.status = "error";
  }
}

async function setFollowTarget(value) {
  const pinnedSessionId = typeof value === "string" && value !== LATEST_VALUE ? value : null;
  follow = { ...follow, mode: pinnedSessionId ? "pinned" : "latest", pinnedSessionId };
  render();
  try {
    await hana.storage.global.set(FOLLOW_REQUEST_KEY, {
      requestId: `req-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
      pinnedSessionId,
    });
  } catch {
    nodes.followNote.textContent = "钉住请求没能写入存储，仍按当前跟随方式运行。";
  }
}

nodes.followSelect.addEventListener("change", () => {
  void setFollowTarget(nodes.followSelect.value);
});

// Track open/focus state so a per-second re-render never rebuilds the open list.
nodes.followSelect.addEventListener("mousedown", () => {
  followSelectOpen = true;
});
nodes.followSelect.addEventListener("focus", () => {
  followSelectOpen = true;
});
nodes.followSelect.addEventListener("blur", () => {
  followSelectOpen = false;
  if (followSelectDeferred !== null) {
    followSelectSignature = null;
    followSelectDeferred = null;
    renderFollowOptions();
  }
});
nodes.followSelect.addEventListener("keydown", (event) => {
  if (event.key === "Escape" || event.key === "Enter") {
    followSelectOpen = false;
    if (followSelectDeferred !== null) {
      followSelectSignature = null;
      followSelectDeferred = null;
      renderFollowOptions();
    }
  }
});

nodes.bridgeToggle.addEventListener("change", async () => {
  bridgeEnabled = nodes.bridgeToggle.checked;
  bridgeStatus = bridgeEnabled ? "connecting" : "disabled";
  render();
  try {
    await hana.storage.global.set(BRIDGE_ENABLED_KEY, bridgeEnabled);
  } catch {
    bridgeEnabled = !bridgeEnabled;
    bridgeStatus = "offline";
    render();
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
window.addEventListener("pagehide", () => {
  stop();
  window.clearInterval(ticker);
}, { once: true });
void refresh();
