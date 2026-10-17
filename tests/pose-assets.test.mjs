import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const ROOT = process.cwd();
const APP_UI = path.join(ROOT, "apps/hana-desktop-pet/ui");
const POSE_ROOT = path.join(APP_UI, "assets/poses");
const SOURCE_ROOT = path.join(ROOT, "assets/crosspet");
const catalog = JSON.parse(fs.readFileSync(path.join(SOURCE_ROOT, "catalog.json"), "utf8"));
const indexSource = fs.readFileSync(path.join(APP_UI, "assets/pose-index.js"), "utf8");
const { POSE_INDEX } = await import(`data:text/javascript;base64,${Buffer.from(indexSource).toString("base64")}`);

const BASE_POSES = [
  "idle", "idle-blink", "idle-2", "idle-3", "thinking", "reading", "writing", "searching",
  "running", "delegating", "drawing", "happy", "proud", "oops", "tired", "sleeping",
  "swamped_left", "swamped_right", "asking", "compact", "surprised", "listening", "busy_left", "busy_right",
];
const catalogPoseIds = new Set(catalog.characters.flatMap((role) => role.poseFiles.map((file) => file.replace(/\.webp$/i, ""))));
const parsedPoseCandidates = new Set([
  ...BASE_POSES,
  ...[...catalogPoseIds].filter((pose) => /-(?:2|3)$/.test(pose)),
  "sorry",
]);

function webpNames(dir) {
  return fs.readdirSync(dir).filter((name) => name.endsWith(".webp")).sort();
}

test("generated pose index and WebP files match in both directions", () => {
  assert.equal(POSE_INDEX.schemaVersion, 1);
  const roleIds = catalog.characters.map((role) => role.id).sort();
  assert.deepEqual(Object.keys(POSE_INDEX.roles).sort(), roleIds, "index roles must match the installed character set");
  const actualRoleDirs = fs.readdirSync(POSE_ROOT, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort();
  assert.deepEqual(actualRoleDirs, roleIds, "pose directory roles must match the index");

  for (const role of catalog.characters) {
    const roleDir = path.join(POSE_ROOT, role.id);
    const actual = webpNames(roleDir);
    const indexed = [...POSE_INDEX.roles[role.id]].map((pose) => `${pose}.webp`).sort();
    const catalogFiles = [...role.poseFiles].sort();
    assert.equal(new Set(POSE_INDEX.roles[role.id]).size, POSE_INDEX.roles[role.id].length,
      `${role.id}: index must not contain duplicate poses`);
    assert.deepEqual(indexed, actual, `${role.id}: every indexed image must exist and every image must be indexed`);
    assert.deepEqual(actual, catalogFiles, `${role.id}: copied files must exactly match catalog.poseFiles`);
    for (const filename of actual) {
      const source = fs.readFileSync(path.join(SOURCE_ROOT, role.assetDirectory, filename));
      const packed = fs.readFileSync(path.join(roleDir, filename));
      assert.ok(source.equals(packed), `${role.id}/${filename}: copied bytes differ from catalog source`);
    }
  }
});

test("every catalog-resolvable character/pose pair is indexed, including variants and special poses", () => {
  const combinations = [];
  let parsedCandidates = 0;
  for (const role of catalog.characters) {
    const indexed = new Set(POSE_INDEX.roles[role.id]);
    for (const filename of role.poseFiles) {
      const pose = filename.replace(/\.webp$/i, "");
      combinations.push([role.id, pose]);
      assert.ok(indexed.has(pose), `${role.id}/${pose} must be accepted for poseState resolution`);
      if (parsedPoseCandidates.has(pose)) parsedCandidates += 1;
    }
  }
  const expectedCount = catalog.characters.reduce((sum, role) => sum + role.poseFiles.length, 0);
  assert.equal(combinations.length, expectedCount, "test must enumerate each catalog character/pose combination");
  assert.ok(parsedCandidates > 0, "coverage must include the supported pose names, numbered variants and sorry");
  for (const pose of ["reading-2", "happy-2", "sleeping-2", "thinking-2", "sorry", "listening", "idle-blink"]) {
    assert.ok(combinations.some(([, resolved]) => resolved === pose), `coverage must include ${pose}`);
  }
  console.log(`POSE_COVERAGE_OK combinations=${combinations.length} base_variant_candidates=${parsedCandidates}`);
});
