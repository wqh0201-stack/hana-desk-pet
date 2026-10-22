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
    assert.equal(new Set(POSE_INDEX.roles[role.id]).size, POSE_INDEX.roles[role.id].length,
      `${role.id}: index must not contain duplicate poses`);
    assert.deepEqual(indexed, actual, `${role.id}: every indexed image must exist and every image must be indexed`);
  }
});

test("the shared double-click basin ships byte-identical and keeps its display aspect", () => {
  const canonical = path.join(SOURCE_ROOT, "shared/basin.png");
  const native = path.join(ROOT, "pet-macos/Sources/HanaDesktopPet/Resources/CrossPet/shared/basin.png");
  assert.ok(fs.existsSync(canonical), "the canonical shared basin artwork must exist");
  assert.ok(fs.existsSync(native), "the macOS bundle must carry the shared basin artwork");
  assert.deepEqual(fs.readFileSync(native), fs.readFileSync(canonical),
    "the bundled basin copy must be byte-identical to the canonical artwork");
  const bytes = fs.readFileSync(canonical);
  assert.equal(bytes.toString("latin1", 1, 4), "PNG", "the basin artwork must be a PNG");
  const width = bytes.readUInt32BE(16);
  const height = bytes.readUInt32BE(20);
  assert.ok(width > 0 && height > 0, "the basin artwork must declare a real size");
  // The native renderer draws it into a 92×70 pt rect at scale 1; a wildly different source
  // aspect would distort it, so the asset and the geometry have to stay in the same family.
  const aspect = width / height;
  assert.ok(aspect > 2.3 && aspect < 2.7, `the basin artwork aspect ${aspect.toFixed(3)} no longer matches the renderer`);
});

test("the pick-up frames ship in both the native resources and the console previews, byte-identical", () => {
  const SOURCE_ASSETS = path.join(ROOT, "assets/crosspet");
  const NATIVE_ASSETS = path.join(ROOT, "pet-macos/Sources/HanaDesktopPet/Resources/CrossPet");
  const roles = catalog.characters.map((role) => role.id);
  assert.equal(roles.length, 7);

  let counted = 0;
  for (const roleId of roles) {
    const generated = new Set((catalog.characters.find((role) => role.id === roleId).generatedPoses ?? []));
    for (const filename of ["picked-up.webp", "picked-up-2.webp"]) {
      assert.ok(generated.has(filename), `${roleId}/${filename} must be declared as a locally generated pose`);
      const sourceBytes = fs.readFileSync(path.join(SOURCE_ASSETS, roleId, filename));
      for (const target of [NATIVE_ASSETS, POSE_ROOT]) {
        const targetBytes = fs.readFileSync(path.join(target, roleId, filename));
        assert.ok(sourceBytes.equals(targetBytes), `${roleId}/${filename} must be byte-identical in ${path.relative(ROOT, target)}`);
      }
      counted += 1;
    }
  }
  assert.equal(counted, 14, "all seven characters ship both pick-up frames");

  // The onesie skin deliberately uses the older pack, so it must differ from the new waving frames.
  const onesie = fs.readFileSync(path.join(SOURCE_ASSETS, "gpt-onesie/picked-up.webp"));
  const whiteDragon = fs.readFileSync(path.join(SOURCE_ASSETS, "gpt/picked-up.webp"));
  assert.ok(!onesie.equals(whiteDragon), "gpt-onesie must not reuse the white dragon's frame");

  const total = catalog.characters.reduce((sum, role) => sum + role.poseFiles.length, 0);
  const generatedTotal = catalog.characters.reduce((sum, role) => sum + (role.generatedPoses ?? []).length, 0);
  assert.equal(total, 211, "catalog lists 211 assets");
  assert.equal(generatedTotal, 18, "18 of them are locally generated");
});

/**
 * Read only the canvas size from a WebP header. The asset set uses VP8X
 * (extended) and VP8L (lossless); a lossy VP8 frame is rejected here so a new
 * format cannot silently bypass the aspect check.
 */
function webpSize(file) {
  const bytes = fs.readFileSync(file);
  if (bytes.toString("latin1", 0, 4) !== "RIFF" || bytes.toString("latin1", 8, 12) !== "WEBP") return null;
  const chunk = bytes.toString("latin1", 12, 16);
  if (chunk === "VP8X") {
    return { width: bytes.readUIntLE(24, 3) + 1, height: bytes.readUIntLE(27, 3) + 1 };
  }
  if (chunk === "VP8L") {
    const bits = bytes.readUInt32LE(21);
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  return null;
}

test("the console canvas covers the widest pose so the pet keeps one scale", () => {
  const panelCss = fs.readFileSync(path.join(APP_UI, "assets/panel.css"), "utf8");
  const frameRule = panelCss.match(/\.stage-image-frame\s*\{([^}]*)\}/)?.[1] ?? "";
  const ratio = frameRule.match(/aspect-ratio:\s*([\d.]+)\s*\/\s*([\d.]+)/);
  assert.ok(ratio, "the stage frame must declare an aspect ratio");
  const cssAspect = Number(ratio[1]) / Number(ratio[2]);
  const stageRule = panelCss.match(/\.stage\s*\{([^}]*)\}/)?.[1] ?? "";
  const columns = stageRule.match(/grid-template-columns:\s*([\d.]+)px/);
  const frameWidth = frameRule.match(/width:\s*([\d.]+)px/);
  assert.ok(columns && frameWidth, "the stage column and frame width must be explicit");

  let maxAspect = 0;
  let widest = null;
  let parsed = 0;
  for (const role of Object.keys(POSE_INDEX.roles)) {
    for (const pose of POSE_INDEX.roles[role]) {
      const size = webpSize(path.join(POSE_ROOT, role, `${pose}.webp`));
      assert.ok(size, `${role}/${pose} must be a readable VP8X or VP8L WebP`);
      parsed += 1;
      const aspect = size.width / size.height;
      if (aspect > maxAspect) {
        maxAspect = aspect;
        widest = `${role}/${pose} ${size.width}x${size.height}`;
      }
    }
  }
  assert.ok(parsed >= 200, `expected the full pose set, parsed ${parsed}`);
  assert.ok(cssAspect + 1e-9 >= maxAspect,
    `stage aspect ${cssAspect.toFixed(4)} must cover the widest pose ${widest} (${maxAspect.toFixed(4)})`);
  assert.ok(cssAspect <= maxAspect + 0.02,
    `stage aspect ${cssAspect.toFixed(4)} is wider than needed (${maxAspect.toFixed(4)}); the pet would shrink`);
  assert.ok(Number(frameWidth[1]) <= Number(columns[1]),
    `stage column ${columns[1]}px must be at least the frame width ${frameWidth[1]}px`);
  console.log(`STAGE_ASPECT_OK widest=${widest} aspect=${maxAspect.toFixed(4)} css=${cssAspect.toFixed(4)}`);
});

test("every catalog-resolvable character/pose pair is indexed, including variants and special poses", () => {
  const combinations = [];
  let parsedCandidates = 0;
  for (const role of catalog.characters) {
    const indexed = new Set(POSE_INDEX.roles[role.id]);
    const generated = new Set(role.generatedPoses ?? []);
    for (const filename of role.poseFiles) {
      if (generated.has(filename)) continue;
      const pose = filename.replace(/\.webp$/i, "");
      combinations.push([role.id, pose]);
      assert.ok(indexed.has(pose), `${role.id}/${pose} must be accepted for poseState resolution`);
      if (parsedPoseCandidates.has(pose)) parsedCandidates += 1;
    }
  }
  const expectedCount = catalog.characters.reduce((sum, role) => {
    const generated = new Set(role.generatedPoses ?? []);
    return sum + role.poseFiles.filter((filename) => !generated.has(filename)).length;
  }, 0);
  assert.equal(combinations.length, expectedCount, "test must enumerate each catalog character/pose combination");
  assert.ok(parsedCandidates > 0, "coverage must include the supported pose names, numbered variants and sorry");
  for (const pose of ["reading-2", "happy-2", "sleeping-2", "thinking-2", "sorry", "listening", "idle-blink"]) {
    assert.ok(combinations.some(([, resolved]) => resolved === pose), `coverage must include ${pose}`);
  }
  console.log(`POSE_COVERAGE_OK combinations=${combinations.length} base_variant_candidates=${parsedCandidates}`);
});

// 包内许可副本是「同步副本」，不是第二份许可权威：canonical 在根 LICENSE 与
// assets/crosspet/。这里逐字节校验，确保 App 被官方 packer 归档时带着同一份文本。
const APP_ROOT = path.join(ROOT, "apps/hana-desktop-pet");
const LICENSE_COPIES = [
  { copy: path.join(APP_ROOT, "LICENSE"), canonical: path.join(ROOT, "LICENSE"), label: "MIT LICENSE" },
  { copy: path.join(APP_ROOT, "assets/ATTRIBUTION.md"), canonical: path.join(SOURCE_ROOT, "ATTRIBUTION.md"), label: "角色署名 ATTRIBUTION.md" },
  { copy: path.join(APP_ROOT, "assets/CHARACTERS-LICENSE.md"), canonical: path.join(SOURCE_ROOT, "CHARACTERS-LICENSE.md"), label: "角色许可 CHARACTERS-LICENSE.md" },
];

test("App-bundled license copies stay byte-identical to the canonical texts", () => {
  for (const { copy, canonical, label } of LICENSE_COPIES) {
    assert.ok(fs.existsSync(copy), `${label} must ship inside the App package: ${path.relative(ROOT, copy)}`);
    assert.ok(fs.existsSync(canonical), `${label} canonical text is missing: ${path.relative(ROOT, canonical)}`);
    assert.deepEqual(
      fs.readFileSync(copy),
      fs.readFileSync(canonical),
      `${label} must match its canonical text byte for byte; update the copy instead of editing it in place`,
    );
  }
});

test("the App README states the real pose provenance and does not deny distribution", () => {
  const readme = fs.readFileSync(path.join(APP_ROOT, "README.md"), "utf8");
  const poses = catalog.characters.reduce((sum, role) => sum + role.poseFiles.length, 0);
  const generated = catalog.characters.reduce((sum, role) => sum + (role.generatedPoses ?? []).length, 0);
  // 数字必须与 canonical catalog 一致，不能写死一个过期数字。
  assert.equal(poses, 211);
  assert.match(readme, new RegExp(`${poses} 张 WebP`), "README must state the real pose count");
  assert.match(readme, new RegExp(`${poses - generated} 张为 CrossPet 上游原样素材`),
    "README must state the real upstream count");
  assert.match(readme, new RegExp(`${generated} 张为本地 AI 生成`), "README must state the real generated count");
  assert.match(readme, /CC BY-NC-SA 4\.0/, "README must name the character license");
  assert.match(readme, /允许非商业转载与分发/, "README must not deny the non-commercial distribution the license allows");
  assert.match(readme, /不得商用/, "README must keep the non-commercial restriction");
  // 旧原型说明里的错误断言不得复活。
  assert.doesNotMatch(readme, /archive 不含这些图片/, "README must not claim the App archive has no character images");
  assert.doesNotMatch(readme, /仅随本机桌宠 `\.app` 分发/, "README must not restrict the images to the macOS app only");
  assert.doesNotMatch(readme, /不得商用、上传或对外发布/, "README must not forbid all outward distribution");
  // 两个平台与两项权限都要说清楚。
  assert.match(readme, /macOS 与 Windows/, "README must cover both desktop platforms");
  assert.match(readme, /app\/ui\.open-external/, "README must document the external-open capability");
  assert.match(readme, /app\/sessions\.read/, "README must document the session-read capability");
  // 后台只回环，网页由用户点击后交给浏览器。
  assert.match(readme, /127\.0\.0\.1/, "README must state the loopback-only backend");
  assert.match(readme, /浏览器去访问 GitHub/, "README must separate user-initiated browsing from backend network");
});
