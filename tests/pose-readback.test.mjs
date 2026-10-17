import test from "node:test";
import assert from "node:assert/strict";
import controller from "../apps/hana-desktop-pet/index.js";
import {
  bridgeFailureReason,
  BRIDGE_ENABLED_KEY,
  BRIDGE_STATUS_KEY,
  PET_BASE_URL,
  PetBridgeClient,
} from "../apps/hana-desktop-pet/pet-bridge.mjs";
import { createHarness } from "./synthetic-host.mjs";

const initialPose = {
  schemaVersion: 3,
  characterId: "gpt",
  pose: "thinking",
  fallback: true,
  since: 1_760_000_000_000,
  revision: 42,
};

function response(status, data, url) {
  return {
    status,
    ok: status >= 200 && status < 300,
    redirected: false,
    url,
    async json() { return data; },
  };
}

function clientForState(state, { status = 200, hello = null } = {}) {
  return new PetBridgeClient(async (url) => {
    const path = new URL(url).pathname;
    if (path === "/v3/hello") {
      return response(200, hello ?? { service: "hana-desktop-pet", protocolVersion: 3 }, url);
    }
    if (path === "/v3/state") return response(status, state, url);
    throw new Error(`unexpected test route ${path}`);
  });
}

test("pose readback accepts the exact DTO and rejects missing, extra and malformed fields", async () => {
  const client = clientForState(initialPose);
  await client.probe();
  assert.deepEqual(await client.getPoseState(), initialPose);

  const invalid = [
    Object.fromEntries(Object.entries(initialPose).filter(([key]) => key !== "since")),
    { ...initialPose, extra: true },
    { ...initialPose, schemaVersion: 2 },
    { ...initialPose, characterId: "not-a-character" },
    { ...initialPose, pose: "Thinking" },
    { ...initialPose, fallback: 1 },
    { ...initialPose, since: -1 },
    { ...initialPose, revision: Number.MAX_SAFE_INTEGER + 1 },
  ];
  for (const state of invalid) {
    const candidate = clientForState(state);
    await candidate.probe();
    await assert.rejects(candidate.getPoseState(), /PET_POSE_STATE_INVALID/);
  }
});

test("pose revisions are nondecreasing and cannot reuse a revision for different state", async () => {
  let current = { ...initialPose };
  const client = new PetBridgeClient(async (url) => {
    if (new URL(url).pathname === "/v3/hello") {
      return response(200, { service: "hana-desktop-pet", protocolVersion: 3 }, url);
    }
    return response(200, current, url);
  });
  await client.probe();
  assert.equal((await client.getPoseState()).revision, 42);
  current = { ...current, revision: 43, pose: "busy_left" };
  assert.equal((await client.getPoseState()).revision, 43);
  current = { ...current, revision: 42, pose: "thinking" };
  await assert.rejects(client.getPoseState(), /PET_POSE_REVISION_INVALID/);
  current = { ...current, revision: 43, pose: "thinking" };
  await assert.rejects(client.getPoseState(), /PET_POSE_REVISION_INVALID/);
});

test("connection failures have stable unreachable, version-mismatch and invalid-response reasons", async () => {
  const unreachable = new PetBridgeClient(async () => { throw new Error("private network details"); });
  await assert.rejects(unreachable.probe(), (error) => bridgeFailureReason(error) === "unreachable");

  const oldPeer = clientForState(initialPose, { hello: { service: "hana-desktop-pet", protocolVersion: 2 } });
  await assert.rejects(oldPeer.probe(), (error) => bridgeFailureReason(error) === "version_mismatch");

  const invalid = new PetBridgeClient(async (url) => ({
    status: 200,
    ok: true,
    url,
    redirected: false,
    async json() { throw new Error("secret response body"); },
  }));
  await assert.rejects(invalid.probe(), (error) => bridgeFailureReason(error) === "invalid_response");

  const missingRoute = clientForState({ error: "not_found" }, { status: 404 });
  await missingRoute.probe();
  await assert.rejects(missingRoute.getPoseState(), (error) => bridgeFailureReason(error) === "version_mismatch");
});

async function settle() {
  for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setImmediate(resolve));
}

async function mountController(mode = "connected", initialEnabled = true) {
  const harness = createHarness({ seed: { [BRIDGE_ENABLED_KEY]: initialEnabled } });
  const baseFetch = harness.sdk.network.fetch;
  let poseState = { ...initialPose };
  harness.sdk.network.fetch = async (url, init) => {
    const path = new URL(url).pathname;
    if (mode === "unreachable") throw new Error("connection refused; must not persist this text");
    if (path === "/v3/hello" && mode === "version_mismatch") {
      return response(200, { service: "hana-desktop-pet", protocolVersion: 2 }, url);
    }
    if (path === "/v3/state") {
      return response(200, mode === "invalid_response" ? { ...poseState, extra: "reject" } : poseState, url);
    }
    return baseFetch(url, init);
  };
  harness.installTimers();
  try {
    await controller.apply(harness.sdk);
    await settle();
  } catch (error) {
    harness.restoreTimers();
    throw error;
  }
  return {
    harness,
    setMode(next) { mode = next; },
    setPoseState(next) { poseState = { ...next }; },
  };
}

test("controller polls actual pose on the bridge cadence and clears it when the pet stops", async () => {
  const mounted = await mountController();
  const { harness } = mounted;
  try {
    let bridge = harness.read(BRIDGE_STATUS_KEY);
    assert.equal(bridge.status, "connected");
    assert.deepEqual(bridge.poseState, initialPose);

    mounted.setPoseState({ ...initialPose, pose: "busy_left", fallback: false, since: initialPose.since + 1500, revision: 43 });
    await harness.tick(1500);
    bridge = harness.read(BRIDGE_STATUS_KEY);
    assert.equal(bridge.poseState.pose, "busy_left", "the regular poll reads a changed native pose without a second timer");
    assert.equal(bridge.poseState.revision, 43);

    mounted.setMode("unreachable");
    await harness.tick(1500);
    bridge = harness.read(BRIDGE_STATUS_KEY);
    assert.equal(bridge.status, "offline");
    assert.equal(bridge.reason, "unreachable");
    assert.equal(bridge.poseState, null, "a stopped pet never leaves its last pose in exposed bridge state");
    assert.equal(JSON.stringify(bridge).includes("private network details"), false);
  } finally {
    harness.restoreTimers();
  }
});

test("controller records a distinct protocol reason, invalid reply, and disabled state", async () => {
  for (const [mode, expected] of [["version_mismatch", "version_mismatch"], ["invalid_response", "invalid_response"], ["unreachable", "unreachable"]]) {
    const mounted = await mountController(mode);
    try {
      const bridge = mounted.harness.read(BRIDGE_STATUS_KEY);
      assert.equal(bridge.status, "offline");
      assert.equal(bridge.reason, expected);
      assert.equal(bridge.poseState, null);
    } finally {
      mounted.harness.restoreTimers();
    }
  }

  const disabled = await mountController("connected", false);
  try {
    const bridge = disabled.harness.read(BRIDGE_STATUS_KEY);
    assert.equal(bridge.status, "disabled");
    assert.equal(bridge.reason, null);
    assert.equal(bridge.poseState, null);
  } finally {
    disabled.harness.restoreTimers();
  }

  assert.equal(PET_BASE_URL, "http://127.0.0.1:43127");
});
