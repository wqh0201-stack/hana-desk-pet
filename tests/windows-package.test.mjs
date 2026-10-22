import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { ROOT, buildWindowsPackage, safeRelative, walk, verifyWindowsAssets } from '../tools/package-windows-pet.mjs';

test('Windows packaging rejects path traversal, drive paths and alternate streams', () => {
  for (const input of ['', '..', '../outside', '/etc/file', 'a/../b', 'a/./b', 'a//b', 'a\\b', 'C:/file', 'file:stream', null]) {
    assert.throws(() => safeRelative(input), /Unsafe package path/);
  }
  assert.equal(safeRelative('CrossPet/gpt/idle.png'), 'CrossPet/gpt/idle.png');
  assert.equal(safeRelative('启动桌宠.cmd'), '启动桌宠.cmd');
});

test('Windows packaging refuses symlinks rather than following files outside its inputs', () => {
  fs.mkdirSync(path.join(ROOT, '.build'), { recursive: true });
  const directory = fs.mkdtempSync(path.join(ROOT, '.build/windows-path-test-'));
  try {
    fs.writeFileSync(path.join(directory, 'own.txt'), 'synthetic');
    fs.symlinkSync(path.join(ROOT, 'README.md'), path.join(directory, 'outside.txt'));
    assert.throws(() => walk(directory), /symlinks/);
  } finally {
    fs.rmSync(directory, { recursive: true, force: true });
  }
});

const prepared = path.join(ROOT, '.build/windows-assets');
test('Windows PNG catalog covers exactly the licensed source catalog and preserves source/output hashes', {
  skip: !fs.existsSync(prepared) && 'Run the macOS Windows asset preparation tool first; conversion is not a Windows runtime requirement.',
}, () => {
  assert.deepEqual(verifyWindowsAssets(prepared), { poseCount: 211, upstreamCount: 193, generatedCount: 18 });
  const basin = path.join(prepared, 'CrossPet/shared/basin.png');
  assert.ok(fs.existsSync(basin), 'the shared double-click basin must ship with the Windows assets');
  assert.deepEqual(fs.readFileSync(basin), fs.readFileSync(path.join(ROOT, 'assets/crosspet/shared/basin.png')),
    'the packed basin must be byte-identical to the canonical artwork');
});

test('the retired first-start-compilation package can no longer produce an archive', () => {
  // 0.2.0 ships a prebuilt single-file exe; the old sidecar package must not come back.
  assert.throws(() => buildWindowsPackage(), /retired/);
});

test('Windows single-file sources and build entries exist at the repository layout', () => {
  const source = path.join(ROOT, 'pet-windows');
  for (const relative of [
    'HanaDesktopPet.Windows/PetAssetStore.cs',
    'HanaDesktopPet.Windows/Program.cs',
    'HanaDesktopPet.Core/Protocol/PetAPI.cs',
    'Resources/App.ico',
    'Resources/app.manifest',
    'version.json',
  ]) {
    assert.ok(fs.existsSync(path.join(source, relative)), `missing Windows source: ${relative}`);
  }
  // The first-start launchers and sidecar config must stay retired.
  for (const retired of [
    'Start-HanaDesktopPet.ps1', 'Start-HanaDesktopPet.cmd', 'Check-HanaDesktopPet.cmd',
    'Resources/HanaDesktopPet.exe.config',
  ]) {
    assert.ok(!fs.existsSync(path.join(source, retired)), `retired first-start file is back: ${retired}`);
  }
  const version = JSON.parse(fs.readFileSync(path.join(source, 'version.json'), 'utf8'));
  assert.equal(version.version, '0.3.1');
  assert.equal(version.protocolVersion, 4);
  assert.equal(version.distribution, 'single-file-portable');
  for (const tool of ['build-windows-portable.py', 'run-windows-checks.py']) {
    assert.ok(fs.existsSync(path.join(ROOT, 'tools', tool)), `missing Windows build entry: ${tool}`);
  }
});
