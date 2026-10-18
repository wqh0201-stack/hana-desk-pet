import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const read = file => fs.readFileSync(file);
const json = file => JSON.parse(read(file));
const ROLES = ['claude', 'gpt', 'deepseek', 'gemini', 'glm', 'deepseek-hoodie', 'gpt-onesie'];
const POSE = /^[a-z0-9][a-z0-9_-]{0,47}\.webp$/;

export function safeRelative(relative) {
  if (typeof relative !== 'string' || !relative || relative.includes('\\') || relative.includes(':') || relative.startsWith('/') || relative.split('/').some(part => !part || part === '.' || part === '..')) {
    throw new Error('Unsafe package path');
  }
  return relative;
}

function regular(file) {
  if (!fs.lstatSync(file).isFile()) throw new Error(`Expected regular file: ${file}`);
  return file;
}

function pngSize(bytes) {
  if (bytes.length < 33 || !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) || bytes.toString('ascii', 12, 16) !== 'IHDR') {
    throw new Error('Invalid PNG image');
  }
  return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
}

export function verifyWindowsAssets(preparedRoot = path.join(ROOT, '.build/windows-assets')) {
  const sourceRoot = path.join(ROOT, 'assets/crosspet');
  const artworkRoot = path.join(preparedRoot, 'CrossPet');
  const sourceBytes = read(path.join(sourceRoot, 'catalog.json'));
  const source = JSON.parse(sourceBytes);
  const catalog = json(path.join(artworkRoot, 'catalog.json'));
  const manifest = json(path.join(artworkRoot, 'build-manifest.json'));
  if (manifest.schemaVersion !== 1 || manifest.sourceCatalogSHA256 !== hash(sourceBytes)) throw new Error('Prepared assets have a stale source catalog');
  if (!read(path.join(artworkRoot, 'source-catalog.json')).equals(sourceBytes)) throw new Error('Source catalog copy changed');
  if (source.schemaVersion !== 1 || catalog.schemaVersion !== 1 || JSON.stringify(source.characters.map(item => item.id)) !== JSON.stringify(ROLES) || JSON.stringify(catalog.characters.map(item => item.id)) !== JSON.stringify(ROLES)) throw new Error('Unexpected character catalog');
  const records = new Map();
  for (const item of manifest.assets) {
    safeRelative(item.source); safeRelative(item.output);
    if (records.has(item.source)) throw new Error('Duplicate conversion record');
    records.set(item.source, item);
  }
  let poseCount = 0, generatedCount = 0;
  const expected = new Set(['catalog.json', 'source-catalog.json', 'build-manifest.json', 'WINDOWS-ASSETS.md', 'CHARACTERS-LICENSE.md', 'ATTRIBUTION.md']);
  for (const [index, character] of source.characters.entries()) {
    if (character.assetDirectory !== character.id || !character.poseFiles.includes('idle.webp') || new Set(character.poseFiles).size !== character.poseFiles.length || character.poseFiles.some(file => !POSE.test(file))) throw new Error('Invalid source character');
    const counterpart = catalog.characters[index];
    const pngName = file => file.replace(/\.webp$/, '.png');
    if (counterpart.assetDirectory !== character.id || JSON.stringify(counterpart.poseFiles) !== JSON.stringify(character.poseFiles.map(pngName)) || JSON.stringify(counterpart.generatedPoses ?? []) !== JSON.stringify((character.generatedPoses ?? []).map(pngName))) throw new Error('PNG catalog differs from source poses');
    const generated = new Set(character.generatedPoses ?? []);
    if ([...generated].some(file => !character.poseFiles.includes(file))) throw new Error('Generated pose is outside catalog');
    for (const filename of character.poseFiles) {
      const sourceName = `${character.id}/${filename}`;
      const outputName = `${character.id}/${pngName(filename)}`;
      const record = records.get(sourceName);
      const sourceData = read(regular(path.join(sourceRoot, sourceName)));
      const outputData = read(regular(path.join(artworkRoot, outputName)));
      if (!record || record.output !== outputName || record.sourceSHA256 !== hash(sourceData) || record.outputSHA256 !== hash(outputData) || record.generated !== generated.has(filename)) throw new Error(`Conversion mismatch: ${sourceName}`);
      const [width, height] = pngSize(outputData);
      if (width !== record.width || height !== record.height || width < 1 || height < 1 || width > 4096 || height > 4096 || !/^[a-f0-9]{64}$/.test(record.rgbaSHA256)) throw new Error('Invalid image dimensions or pixel hash');
      expected.add(outputName); poseCount++;
      if (generated.has(filename)) generatedCount++;
    }
  }
  if (records.size !== poseCount || manifest.poseCount !== poseCount || manifest.generatedCount !== generatedCount || manifest.upstreamCount !== poseCount - generatedCount) throw new Error('Conversion counts differ');
  for (const file of ['CHARACTERS-LICENSE.md', 'ATTRIBUTION.md']) {
    if (!read(path.join(sourceRoot, file)).equals(read(path.join(artworkRoot, file)))) throw new Error(`License or attribution changed: ${file}`);
  }
  const actual = walk(artworkRoot).map(file => file.relative);
  if (actual.length !== expected.size || actual.some(file => !expected.has(file))) throw new Error('Unexpected artwork file outside catalog');
  const icon = read(regular(path.join(preparedRoot, 'App.ico')));
  if (manifest.iconSourceSHA256 !== hash(read(path.join(ROOT, 'apps/hana-desktop-pet/assets/icon.png'))) || manifest.iconSHA256 !== hash(icon)) throw new Error('Prepared Windows icon is stale');
  if (icon.readUInt16LE(0) !== 0 || icon.readUInt16LE(2) !== 1 || icon.readUInt16LE(4) !== 6) throw new Error('Invalid Windows icon');
  for (let i = 0; i < 6; i++) {
    const offset = icon.readUInt32LE(6 + i * 16 + 12), size = icon.readUInt32LE(6 + i * 16 + 8);
    if (offset + size > icon.length) throw new Error('Invalid icon frame');
    pngSize(icon.subarray(offset, offset + size));
  }
  return { poseCount, upstreamCount: poseCount - generatedCount, generatedCount };
}

export function walk(directory, prefix = '') {
  const output = [];
  for (const entry of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
    const relative = safeRelative(prefix + entry.name);
    const file = path.join(directory, entry.name);
    if (entry.isSymbolicLink()) throw new Error('Package inputs cannot be symlinks');
    if (entry.isDirectory()) output.push(...walk(file, relative + '/'));
    else if (entry.isFile()) output.push({ path: file, relative });
    else throw new Error('Package inputs must be files or folders');
  }
  return output;
}

function copy(source, destination) {
  regular(source);
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  fs.copyFileSync(source, destination);
}

export function buildWindowsPackage() {
  throw new Error('The first-start-compilation Windows package is retired. '
    + 'Use `node tools/package-windows-pet.mjs --prepare-assets` to prepare artwork, '
    + 'then `python3 tools/build-windows-portable.py` for the single-file build.');
}

export function prepareWindowsAssets() {
  if (process.platform !== 'darwin') throw new Error('Asset conversion uses the existing macOS ImageIO decoder. Windows users should extract the prepared test zip.');
  const destination = path.join(ROOT, '.build/windows-assets');
  try { verifyWindowsAssets(destination); return destination; } catch { /* Rebuild stale or absent generated output. */ }
  const toolsRoot = path.join(ROOT, '.build/windows-tools');
  fs.mkdirSync(toolsRoot, { recursive: true });
  const executable = path.join(toolsRoot, 'PrepareWindowsAssets');
  const compile = spawnSync('/usr/bin/swiftc', ['-module-cache-path', path.join(toolsRoot, 'ModuleCache'), path.join(ROOT, 'tools/prepare-windows-assets.swift'), '-o', executable], { encoding: 'utf8' });
  if (compile.status !== 0) throw new Error(compile.stderr || 'Could not build the local image conversion tool');
  const staging = path.join(ROOT, '.build/windows-assets-' + crypto.randomUUID());
  const backup = path.join(ROOT, '.build/windows-assets-previous-' + crypto.randomUUID());
  try {
    const convert = spawnSync(executable, [path.join(ROOT, 'assets/crosspet'), path.join(ROOT, 'apps/hana-desktop-pet/assets/icon.png'), staging], { encoding: 'utf8' });
    if (convert.status !== 0) throw new Error(convert.stderr || 'Could not convert the licensed catalog');
    verifyWindowsAssets(staging);
    if (fs.existsSync(destination)) fs.renameSync(destination, backup);
    try { fs.renameSync(staging, destination); }
    catch (error) { if (fs.existsSync(backup)) fs.renameSync(backup, destination); throw error; }
    return destination;
  } finally {
    fs.rmSync(staging, { recursive: true, force: true });
    fs.rmSync(backup, { recursive: true, force: true });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    if (process.argv[2] === '--verify-assets') console.log(JSON.stringify(verifyWindowsAssets(), null, 2));
    else if (process.argv[2] === '--prepare-assets') console.log(JSON.stringify(verifyWindowsAssets(prepareWindowsAssets()), null, 2));
    else console.log(JSON.stringify(buildWindowsPackage(process.argv[2] === '--prepare' ? prepareWindowsAssets() : undefined), null, 2));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 1;
  }
}
