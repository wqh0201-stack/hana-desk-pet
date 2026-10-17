/**
 * A synthetic Hana v2 App host used only by the Node tests.
 *
 * It reproduces the entry shape `createAppSdk` expects (`dataDir`, `bus.request`,
 * `bus.subscribe`, `network.fetch`, `storage.global`, `logger`) so the real App
 * entry can be driven with synthetic sessions. Nothing here touches a real Hana
 * host, a real session, the network, or the disk.
 *
 * Timers are captured instead of scheduled: the App's poll and refresh intervals
 * must be stepped explicitly, which is what makes the pin/grace behaviour
 * testable without real time.
 */
import { APP_SDK_BUS_METHODS } from "../apps/hana-desktop-pet/sdk/app-contract/bus-requests.js";

const SESSION_METHODS = APP_SDK_BUS_METHODS.sessions;

function clone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

/** Matches the host `AppRegistration` shape: callable, with `ready` and `disposeAsync`. */
function registration(release = () => {}) {
  let disposed = false;
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    release();
  };
  dispose.ready = Promise.resolve();
  dispose.disposeAsync = async () => {
    dispose();
  };
  dispose.isDisposed = () => disposed;
  return dispose;
}

function makeError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

/**
 * @param {object} options
 * @param {Array<object>} [options.sessions]   Synthetic `session:list` entries (full SDK shape).
 * @param {"ok"|"denied"|"throw"|"malformed"} [options.listMode]
 * @param {"ok"|"denied"} [options.getMode]
 * @param {number} [options.startTime]
 */
export function createHarness({
  sessions = [],
  listMode = "ok",
  getMode = "ok",
  seed = null,
  startTime = 1700000000000,
} = {}) {
  const store = new Map(Object.entries(seed ?? {}).map(([k, v]) => [k, clone(v)]));
  let listed = clone(sessions);
  let pendingGet = null;
  let legacyId = null;
  const state = {
    storageWrites: 0,
    listCalls: [],
    getCalls: [],
    published: [],
    logs: [],
    subscriptions: [],
    errors: [],
  };
  const storageListeners = new Set();
  const timers = new Map();
  let timerSequence = 0;
  let clock = startTime;
  let savedTimers = null;
  let savedNow = null;


  // The App timestamps with `Date.now()`; make the synthetic clock authoritative
  // so pin/grace arithmetic is exercised against the same readings the code uses.
  function useClock() {
    if (savedNow) return;
    savedNow = Date.now;
    Date.now = () => clock;
  }

  function restoreClock() {
    if (!savedNow) return;
    Date.now = savedNow;
    savedNow = null;
  }

  const storage = {
    get: (key, fallback) => Promise.resolve(clone(store.has(key) ? store.get(key) : fallback)),
    getAll: () => Promise.resolve(Object.fromEntries([...store].map(([k, v]) => [k, clone(v)]))),
    set: (key, value) => {
      store.set(key, clone(value));
      state.storageWrites += 1;
      for (const listener of [...storageListeners]) listener([key]);
      return Promise.resolve({ ok: true });
    },
    delete: (key) => {
      store.delete(key);
      return Promise.resolve({ ok: true });
    },
    keys: () => Promise.resolve([...store.keys()]),
    onChanged: (callback) => {
      storageListeners.add(callback);
      return registration(() => storageListeners.delete(callback));
    },
  };

  const bus = {
    request: async (verb, input) => {
      if (verb === SESSION_METHODS.list) {
        state.listCalls.push(clone(input ?? null));
        if (listMode === "denied") throw makeError("APP_CAPABILITY_DENIED");
        if (listMode === "throw") throw makeError("APP_UNEXPECTED");
        if (listMode === "malformed") return { sessions: "not-an-array" };
        return { sessions: clone(listed) };
      }
      if (verb === SESSION_METHODS.get) {
        state.getCalls.push(clone(input ?? null));
        if (getMode === "denied") throw makeError("APP_CAPABILITY_DENIED");
        // A `getError` lets a test raise a specific SDK error shape for session:get.
        if (pendingGet) {
          const error = pendingGet;
          pendingGet = null;
          throw error;
        }
        // `sessionPath` is rejected but `legacySessionPath` answers: the real host
        // validates a path against its agents directory and throws a generic error.
        if (input?.sessionPath && legacyId !== null) {
          throw makeError("APP_HOST_ERROR");
        }
        if (input?.legacySessionPath && legacyId !== null) {
          return { session: { sessionId: legacyId, title: "legacy 命中", path: input.legacySessionPath } };
        }
        const target = listed.find((item) => (input?.sessionId && item.sessionId === input.sessionId) ||
          (input?.sessionPath && item.path === input.sessionPath));
        return { session: target ? clone(target) : null };
      }
      throw makeError("APP_VERB_UNSUPPORTED");
    },
    subscribe: (callback, options) => {
      state.subscriptions.push({ callback, options: clone(options ?? null) });
      return registration();
    },
  };

  const sdk = {
    dataDir: "/synthetic/hana-data",
    config: {},
    models: {},
    tools: {},
    hooks: {},
    media: {},
    providers: {},
    bus,
    network: {
      fetch: async (url, init) => {
        const path = new URL(url).pathname;
        if (path === "/v3/hello") {
          return { ok: true, status: 200, url, redirected: false,
            json: async () => ({ service: "hana-desktop-pet", protocolVersion: 3 }) };
        }
        if (path === "/v3/snapshot") {
          state.published.push(clone(JSON.parse(init.body)));
          return { ok: true, status: 200, url, redirected: false,
            json: async () => ({ schemaVersion: 3, accepted: true }) };
        }
        if (path === "/v3/selection") {
          if (init?.method === "POST") {
            const body = JSON.parse(init.body);
            return { ok: true, status: 200, url, redirected: false,
              json: async () => ({
                schemaVersion: 3, characterId: body.characterId, revision: 2, updatedAt: body.updatedAt,
              }) };
          }
          return { ok: true, status: 200, url, redirected: false,
            json: async () => ({ schemaVersion: 3, characterId: "claude", revision: 0, updatedAt: 0 }) };
        }
        throw makeError("PET_ROUTE_NOT_ALLOWED");
      },
    },
    storage: { global: storage, agent: () => storage },
    logger: {
      info: (message) => {
        state.logs.push(String(message));
        return Promise.resolve();
      },
      warn: (message) => {
        state.logs.push(String(message));
        return Promise.resolve();
      },
      error: (message) => {
        state.logs.push(String(message));
        return Promise.resolve();
      },
    },
  };

  /** Capture the timers the App schedules, keyed by delay, so tests can step them. */
  function installTimers() {
    useClock();
    savedTimers = { setInterval: globalThis.setInterval, clearTimeout: globalThis.clearTimeout, setTimeout: globalThis.setTimeout };
    globalThis.setInterval = (fn, delay) => {
      const id = `interval-${++timerSequence}`;
      timers.set(id, { fn, delay, once: false });
      return id;
    };
    globalThis.setTimeout = (fn, delay) => {
      const id = `timeout-${++timerSequence}`;
      timers.set(id, { fn, delay, once: true });
      return id;
    };
    globalThis.clearTimeout = (id) => {
      timers.delete(id);
    };
  }

  function restoreTimers() {
    if (savedTimers) {
      Object.assign(globalThis, savedTimers);
      savedTimers = null;
    }
    restoreClock();
    timers.clear();
  }

  /** Advance the synthetic clock and run every due timer. */
  async function tick(ms) {
    clock += ms;
    useClock();
    try {
      for (const [id, entry] of [...timers]) {
        if (entry.delay > ms) continue;
        if (entry.once) timers.delete(id);
        await entry.fn();
      }
    } finally {
      // Keep the fake clock installed outside `tick` too, so any asynchronous
      // continuation still reads synthetic time.
      useClock();
    }
    // Let the callback queues the timers started settle.
    for (let i = 0; i < 4; i += 1) await new Promise((resolve) => setImmediate(resolve));
  }

  /** Reproduce the `AppSessionListEntryV2` extras the App must never persist. */
  const fullEntry = (overrides = {}) => ({
    sessionId: null, path: "/private/session/path", title: null, firstMessage: "private first message",
    agentId: null, agentName: null, modelId: "private-model", messageCount: 3, cwd: "/private/cwd",
    modified: 1700000000000, ownerPluginId: "private-owner", kind: "chat", visibility: "private",
    lifecycle: "active", archivedAt: null, ...overrides,
  });

  return {
    sdk,
    state,
    store,
    fullEntry,
    installTimers,
    restoreTimers,
    tick,
    read: (key) => clone(store.get(key)),
    write: (key, value) => storage.set(key, value),
    /** Swap what the host reports, so lifecycle transitions can be observed. */
    setSessions: (next) => {
      listed = clone(next);
    },
    /** Flip how the host answers `session:list`, to model a later recovery. */
    setListMode: (next) => {
      listMode = next;
    },
    /** Make `legacySessionPath` the selector that works, while `sessionPath` throws. */
    setLegacyId: (sessionId) => {
      legacyId = sessionId;
    },
    /** Make the next `session:get` throw this error object (AppSdkError-like). */
    failNextGet: (error) => {
      pendingGet = error;
    },
    /** Build an SDK-shaped error, as `toAppSdkError` would produce. */
    sdkError: (code, kind = "host") => {
      const error = new Error(`synthetic ${code}`);
      error.code = code;
      error.kind = kind;
      error.name = "AppSdkError";
      return error;
    },
    now: () => clock,
    restoreClock,
  };
}

export { makeError, registration };
