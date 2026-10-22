/**
 * 控制台与桌宠的兼容关系守卫。
 *
 * 公开基线是控制台 0.6.6（协议 v3），它只能配 Windows 0.2.0 / macOS 0.5.8；
 * 本地 0.6.7 候选是协议 v4，控制台下载地址配 Windows 0.3.0 / macOS 0.5.9。两套下载地址都是
 * 固定白名单，不随“最新版”漂移。
 *
 * 兼容判定按协议版本与所需字段/能力，而不是“版本号相等”：将来控制台小版本
 * 可以继续共用同一桌宠，只要协议与用到的字段一致。这里只钉住已知的两组，
 * 新增一组时显式加一行，避免默默串版。
 *
 * dist/ 不入库；已发布产物的检查在文件存在时执行，缺失时明确 skip。
 */
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { execFileSync } from "node:child_process";

const MANIFEST = JSON.parse(fs.readFileSync("apps/hana-desktop-pet/manifest.json", "utf8"));
const PANEL_SOURCE = fs.readFileSync("apps/hana-desktop-pet/ui/assets/panel.js", "utf8");
const PANEL_HTML = fs.readFileSync("apps/hana-desktop-pet/ui/panel.html", "utf8");
const WINDOWS_VERSION = JSON.parse(fs.readFileSync("pet-windows/version.json", "utf8"));
const MAC_VERSION = fs.readFileSync("pet-macos/Resources/Info.plist", "utf8")
  .match(/<key>CFBundleShortVersionString<\/key>\s*<string>([^<]+)<\/string>/)?.[1];

const RELEASE_BASE = "https://github.com/wqh0201-stack/hana-desk-pet/releases/download";
const windowsUrl = (version) =>
  `${RELEASE_BASE}/windows-${version}/HanaDesktopPet-windows-${version}-portable.zip`;
const macUrl = (version) =>
  `${RELEASE_BASE}/pet-${version}/HanaDesktopPet-crosspet-v${version}-local.zip`;

/**
 * 已经确定的兼容组合。下载地址按各版本实际发布位置固定：
 * 0.6.6 的 macOS 附件留在既有的 console-0.6.5 Release，0.6.7 的 0.5.9 走新 tag。
 * protocol 是控制台与桌宠共用的本机协议版本。
 */
const COMPATIBILITY = {
  "0.6.6": {
    protocol: 3,
    windowsVersion: "0.2.0",
    macVersion: "0.5.8",
    windows: windowsUrl("0.2.0"),
    mac: `${RELEASE_BASE}/console-0.6.5/HanaDesktopPet-crosspet-v0.5.8-local.zip`,
    note: "公开基线（市场当前收录）",
  },
  "0.6.7": {
    protocol: 4,
    windowsVersion: "0.3.0",
    macVersion: "0.5.9",
    windows: windowsUrl("0.3.0"),
    mac: macUrl("0.5.9"),
    note: "本轮本地候选，未发布",
  },
};

function panelUrls(source) {
  const block = source.slice(source.indexOf("const PET_DOWNLOADS"),
    source.indexOf("const nodes = {"));
  return Object.fromEntries([...block.matchAll(
    /(windows|mac): Object\.freeze\(\{\s*url: "([^"]+)"/g)].map(([, platform, url]) => [platform, url]));
}

function zipText(archive, entry) {
  return execFileSync("unzip", ["-p", archive, entry], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
}

function versionParts(version) {
  return String(version).split(".").map((part) => Number.parseInt(part, 10) || 0);
}

/** True when `candidate` is the same or a newer release than `floor` (numeric, per part). */
function versionAtLeast(candidate, floor) {
  const left = versionParts(candidate);
  const right = versionParts(floor);
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const a = left[index] ?? 0;
    const b = right[index] ?? 0;
    if (a !== b) return a > b;
  }
  return true;
}

test("the current console candidate pairs with the desktop versions in the compatibility table", () => {
  const expected = COMPATIBILITY[MANIFEST.version];
  assert.ok(expected, `console ${MANIFEST.version} has no declared desktop pairing`);
  // What pairs the console is its allow-list: the builds it downloads for this protocol.
  // The desktop sources in this repo may already be a newer patch of the same protocol
  // (e.g. 0.3.1 / 0.5.10 while the console still links 0.3.0 / 0.5.9), but they must never
  // be older than the build the console points at.
  assert.ok(versionAtLeast(WINDOWS_VERSION.version, expected.windowsVersion),
    `Windows ${WINDOWS_VERSION.version} is older than the paired ${expected.windowsVersion}`);
  assert.equal(WINDOWS_VERSION.protocolVersion, expected.protocol,
    "the Windows package declares the console's protocol");
  assert.ok(versionAtLeast(MAC_VERSION, expected.macVersion),
    `macOS ${MAC_VERSION} is older than the paired ${expected.macVersion}`);

  assert.deepEqual(panelUrls(PANEL_SOURCE), {
    windows: expected.windows,
    mac: expected.mac,
  }, "the allow-list matches the declared pairing");

  for (const href of [expected.windows, expected.mac]) {
    assert.ok(PANEL_HTML.includes(href), `panel.html lacks the paired download: ${href}`);
  }
});

test("the retired pairing is still described by its own versions, never by v4 ones", () => {
  // 0.6.6 是公开基线；它和它的两个下载地址必须继续存在且保持 v3 语义。
  const published = COMPATIBILITY["0.6.6"];
  assert.equal(published.protocol, 3);
  assert.ok(published.windows.endsWith("/windows-0.2.0/HanaDesktopPet-windows-0.2.0-portable.zip"));
  assert.ok(published.mac.endsWith("/console-0.6.5/HanaDesktopPet-crosspet-v0.5.8-local.zip"));
  // 当前候选不得重新用回旧地址（这正是本轮修掉的回归）。
  const current = COMPATIBILITY[MANIFEST.version];
  assert.notDeepEqual(current, published, "the candidate must not reuse the v3 pairing");
});

test("dist keeps the published 0.6.6 package and its v3 links untouched", (t) => {
  const archive = "dist/app-hana-desktop-pet-0.6.6.zip";
  if (!fs.existsSync(archive)) return t.skip("published 0.6.6 archive is not present locally");
  const entry = JSON.parse(fs.readFileSync("dist/app-hana-desktop-pet-0.6.6.entry.json", "utf8"));
  assert.equal(entry.version, "0.6.6");
  const urls = panelUrls(zipText(archive, "ui/assets/panel.js"));
  assert.deepEqual(urls, {
    windows: windowsUrl("0.2.0"),
    mac: `${RELEASE_BASE}/console-0.6.5/HanaDesktopPet-crosspet-v0.5.8-local.zip`,
  }, "the published 0.6.6 package must keep its own compatible v3 downloads");
  const html = zipText(archive, "ui/panel.html");
  assert.ok(html.includes(windowsUrl("0.2.0")) &&
    html.includes(`${RELEASE_BASE}/console-0.6.5/HanaDesktopPet-crosspet-v0.5.8-local.zip`));
  assert.ok(!html.includes("windows-0.3.0") && !html.includes("pet-0.5.9"),
    "a published v3 package must not be rewritten to v4 links");
});

test("dist keeps the published Windows 0.2.0 attachment as a v3 build", (t) => {
  const archive = "dist/HanaDesktopPet-windows-0.2.0-portable.zip";
  if (!fs.existsSync(archive)) return t.skip("published Windows 0.2.0 archive is not present locally");
  const version = JSON.parse(zipText(archive, "version.json"));
  assert.equal(version.version, "0.2.0", "the old release URL still serves the old build");
  assert.equal(version.protocolVersion, 3, "the old attachment must stay protocol v3");
});

test("a locally built 0.6.7 candidate carries only the v4 pairing", (t) => {
  const archive = "dist/app-hana-desktop-pet-0.6.7.zip";
  if (!fs.existsSync(archive)) return t.skip("0.6.7 candidate archive is not present locally");
  const urls = panelUrls(zipText(archive, "ui/assets/panel.js"));
  assert.deepEqual(urls, {
    windows: windowsUrl("0.3.0"),
    mac: macUrl("0.5.9"),
  });
  const html = zipText(archive, "ui/panel.html");
  assert.ok(!html.includes("windows-0.2.0"), "the v4 candidate still offers the v3 Windows build");
  assert.ok(!html.includes("v0.5.8-local"), "the v4 candidate still offers the v3 macOS build");
});
