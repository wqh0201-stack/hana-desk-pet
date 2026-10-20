import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const CANONICAL = path.join(ROOT, "assets/crosspet/pet-lines.json");
const NATIVE_COPY = path.join(ROOT, "pet-macos/Sources/HanaDesktopPet/Resources/CrossPet/pet-lines.json");
const CATALOG = JSON.parse(fs.readFileSync(path.join(ROOT, "assets/crosspet/catalog.json"), "utf8"));
const TABLE = JSON.parse(fs.readFileSync(CANONICAL, "utf8"));

const ROLES = ["claude", "gpt", "deepseek", "gemini", "glm", "deepseek-hoodie", "gpt-onesie"];

/** Every pose name the catalog can actually put on screen. */
function catalogPoses() {
  const poses = new Set();
  for (const character of CATALOG.characters) {
    for (const file of character.poseFiles) poses.add(file.replace(/\.webp$/, ""));
  }
  return poses;
}

test("the subtitle table ships as a canonical resource and a byte-identical native copy", () => {
  assert.ok(fs.existsSync(CANONICAL), "canonical subtitle table must exist in assets/crosspet");
  assert.ok(fs.existsSync(NATIVE_COPY), "the macOS pet must bundle the subtitle table");
  assert.deepEqual(fs.readFileSync(NATIVE_COPY), fs.readFileSync(CANONICAL),
    "the bundled copy must match the canonical table byte for byte; copy, do not re-edit");
});

test("the subtitle table is well formed: 20 states, a dwell entry for each, two lines per role", () => {
  assert.equal(TABLE.schemaVersion, 1);
  assert.equal(TABLE.stateOrder.length, 20, "the reviewed table has 20 logical states");
  assert.equal(new Set(TABLE.stateOrder).size, TABLE.stateOrder.length, "state keys must be unique");
  assert.deepEqual(Object.keys(TABLE.dwellSeconds).sort(), [...TABLE.stateOrder].sort(),
    "every state needs exactly one dwell entry (null = persist)");
  assert.equal(TABLE.minDwellSeconds, 2.5, "the reviewed minimum dwell is 2.5 s");
  for (const state of TABLE.stateOrder) {
    const dwell = TABLE.dwellSeconds[state];
    if (dwell !== null) {
      assert.equal(typeof dwell, "number", `${state}: a non-null dwell must be a number`);
      assert.ok(dwell > 0 && dwell <= 600, `${state}: dwell must be a sane positive bound`);
    }
  }
  assert.deepEqual([...new Set(TABLE.unreachableStates)].sort(), ["pat"],
    "only `pat` has no reachable pose, and that is recorded");
  assert.deepEqual(Object.keys(TABLE.characters).sort(), [...ROLES].sort(), "all seven roles, no extras");

  for (const role of ROLES) {
    assert.deepEqual(Object.keys(TABLE.characters[role]).sort(), [...TABLE.stateOrder].sort(),
      `${role} must cover every state exactly once`);
    for (const state of TABLE.stateOrder) {
      const lines = TABLE.characters[role][state];
      assert.ok(Array.isArray(lines) && lines.length >= 1 && lines.length <= 2,
        `${role}/${state} must have one or two candidate lines`);
      assert.equal(new Set(lines).size, lines.length, `${role}/${state} must not repeat a candidate`);
      for (const line of lines) {
        assert.equal(line, line.trim(), `${role}/${state} must not carry stray whitespace`);
        assert.ok(line.length > 0 && line.length <= 120, `${role}/${state} lines stay within the bounded length`);
      }
    }
  }
});

test("the pose→state table is exhaustive for the bundled catalog, with no invented or dangling pose", () => {
  const poses = catalogPoses();
  const table = TABLE.poseStates;
  const states = new Set(TABLE.stateOrder);
  for (const [pose, state] of Object.entries(table)) {
    assert.ok(poses.has(pose), `poseStates lists ${pose}, which the catalog cannot display`);
    assert.ok(states.has(state), `${pose} maps to an unknown state ${state}`);
  }
  for (const pose of poses) {
    assert.ok(table[pose], `every catalog pose needs a normalised state: ${pose} is missing`);
  }
  // The variant normalisation the native side also applies must be redundant, not load-bearing.
  for (const [variant, base] of [
    ["thinking-2", "thinking"], ["idle-2", "idle"], ["idle-3", "idle"], ["idle-blink", "idle"],
    ["busy_left", "busy"], ["busy_right", "busy"], ["swamped_left", "swamped"], ["swamped_right", "swamped"],
    ["sleeping-2", "sleeping"], ["happy-2", "happy"], ["reading-2", "reading"], ["deepthink", "thinking"],
    ["picked-up-2", "picked-up"], ["sorry", "oops"], ["listening", "asking"], ["surprised", "interrupted"],
  ]) {
    assert.ok(poses.has(variant), `the catalog must still list ${variant}`);
    assert.equal(table[variant], base, `${variant} must normalise to ${base}`);
  }
});

test("every state a pose can reach has real lines for every role", () => {
  const reachable = new Set(Object.values(TABLE.poseStates));
  for (const role of ROLES) {
    for (const state of reachable) {
      assert.ok(TABLE.characters[role][state].length >= 1,
        `${role}/${state} is reachable from artwork and must have a line`);
    }
  }
  // `pat` is the one state with no reachable pose; it keeps its reviewed wording for later.
  assert.ok(!reachable.has("pat"), "no catalog pose may claim the unreachable pat state");
});

test("the wording is original: no line is an upstream CrossPet copy and none names a session", () => {
  const all = [];
  for (const role of ROLES) for (const state of TABLE.stateOrder) all.push(...TABLE.characters[role][state]);
  assert.ok(new Set(all).size > 200, "the table carries the full reviewed wording");
  // The table must not smuggle data it is not allowed to hold: no paths, no ids, no args.
  for (const line of all) {
    assert.doesNotMatch(line, /[/\\]|session|prompt|token|[0-9a-f]{16,}/i,
      `a subtitle line must stay pure wording: ${line}`);
  }
  assert.equal(TABLE.note.includes("no upstream CrossPet lines are used"), true,
    "the table must state the provenance boundary it is published under");
});

// The Windows single-file build embeds pet-lines.json from the prepared asset folder, and the
// C# side parses exactly that file. Preparation must copy the canonical table unchanged.
test("the Windows prepared asset folder carries the same subtitle table byte for byte", {
  skip: !fs.existsSync(path.join(ROOT, ".build/windows-assets/CrossPet")) &&
    "Run `node tools/package-windows-pet.mjs --prepare-assets` first.",
}, () => {
  const prepared = path.join(ROOT, ".build/windows-assets/CrossPet/pet-lines.json");
  assert.ok(fs.existsSync(prepared), "the prepared Windows asset folder must contain pet-lines.json");
  assert.deepEqual(fs.readFileSync(prepared), fs.readFileSync(CANONICAL),
    "Windows must embed the canonical subtitle table unchanged");
});

// The single-file packer lists catalog.json first, then the subtitle table; both must be present
// in the blob index or the C# renderer silently degrades to notices only.
test("the Windows asset packer includes the subtitle table in the blob", () => {
  const source = fs.readFileSync(path.join(ROOT, "tools/build-windows-portable.py"), "utf8");
  assert.match(source, /entries\.append\(\("pet-lines\.json", lines_path\)\)/,
    "the single-file packer must pack pet-lines.json");
  assert.match(source, /missing prepared subtitle table/,
    "a missing subtitle table must fail the build instead of being skipped");
  const prepare = fs.readFileSync(path.join(ROOT, "tools/prepare-windows-assets.swift"), "utf8");
  assert.match(prepare, /"ATTRIBUTION\.md", "pet-lines\.json"/,
    "asset preparation must copy the subtitle table into the prepared folder");
  const verify = fs.readFileSync(path.join(ROOT, "tools/package-windows-pet.mjs"), "utf8");
  assert.match(verify, /'ATTRIBUTION\.md', 'pet-lines\.json'/,
    "the exact-file-allowlist verification must accept pet-lines.json");
});
