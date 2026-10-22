#!/usr/bin/env python3
"""Build the single-file Windows portable pet from this repository's layout.

Everything the pet needs - code, catalog and all 211 PNGs - ends up inside one
executable. Artwork is packed into a blob plus an offset index; both are embedded
as resources and read by offset at runtime, so no sibling CrossPet folder and no
first-start compilation are involved.

Repository layout (differs from the original standalone source bundle):

    pet-windows/                    Windows source, version.json, Resources
    .build/windows-assets/CrossPet  PNG set prepared on macOS from the canonical
                                    assets/crosspet catalog (never committed)
    .build/windows-build/           regenerable scratch + generated manifest

Usage:
    python3 tools/build-windows-portable.py [--no-zip] [--check-assets-only]

Compiling needs csc.exe from the Windows .NET Framework (Windows only). Asset
packing, hashing and zip creation are pure Python and run on macOS too, which is
also how `--check-assets-only` verifies the blob/index without csc.
"""

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import zipfile

FRAMEWORK_CSC = r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
FRAMEWORK_ROOT = r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319"
RESOURCE_INDEX = "HanaDesktopPet.Assets.idx.json"
RESOURCE_BLOB = "HanaDesktopPet.Assets.bin"

DEFAULT_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_DIR = "pet-windows"
ASSET_DIR = ".build/windows-assets"
WORK_DIR = ".build/windows-build"

# Shipped next to the executable so the CC BY-NC-SA attribution travels with it.
DOCUMENTS = ["README.md", "LICENSE"]
CROSSPET_DOCUMENTS = ["ATTRIBUTION.md", "CHARACTERS-LICENSE.md"]


def read_version_metadata(source: pathlib.Path):
    """version.json is the only place the candidate version and protocol are declared."""
    document = json.loads((source / "version.json").read_text(encoding="utf-8"))
    return document["version"], int(document["protocolVersion"])


def verify_protocol_matches_sources(source: pathlib.Path, protocol: int):
    """Fail the build when version.json and the C# protocol constant disagree.

    The executable has no sidecar metadata at runtime, so the C# constant cannot be
    derived from version.json; a guard keeps the two from drifting apart instead.
    """
    api = (source / "HanaDesktopPet.Core" / "Protocol" / "PetAPI.cs").read_text(encoding="utf-8-sig")
    matches = re.findall(r"protocolVersion\s*=\s*(\d+)", api)
    if not matches:
        raise SystemExit("PetAPI.cs no longer declares protocolVersion; update this guard")
    declared = sorted(set(int(value) for value in matches))
    if declared != [protocol]:
        raise SystemExit("version.json says protocol {0} but PetAPI.cs declares {1}".format(
            protocol, ", ".join(str(value) for value in declared)))


def require_travel_documents(source: pathlib.Path, assets: pathlib.Path):
    """Licence and attribution are part of the distribution, never optional.

    The original script silently skipped any document that was absent, which
    produced archives without attribution. Missing documents are a build failure.
    """
    required = [(source / name) for name in DOCUMENTS]
    required += [(assets / "CrossPet" / name) for name in CROSSPET_DOCUMENTS]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        raise SystemExit("missing licence/attribution documents: " + ", ".join(missing))
    return required


def catalog_entries(assets: pathlib.Path):
    """The catalog itself, then every artwork file it lists, in catalog order."""
    artwork = assets / "CrossPet"
    catalog_path = artwork / "catalog.json"
    if not catalog_path.is_file():
        raise SystemExit("missing prepared artwork catalog: " + str(catalog_path)
                         + "\nrun: node tools/package-windows-pet.mjs --prepare-assets")
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    entries = [("catalog.json", catalog_path)]
    # The subtitle table is a native-layer resource; it rides in the same blob so the
    # single-file build needs no sibling file and no protocol change.
    lines_path = artwork / "pet-lines.json"
    if not lines_path.is_file():
        raise SystemExit("missing prepared subtitle table: " + str(lines_path))
    entries.append(("pet-lines.json", lines_path))
    # The shared basin artwork is a single optional prop for the double-click pile; it is
    # not a catalog pose, so it rides in the blob without touching the pose count.
    shared_basin = artwork / "shared" / "basin.png"
    if shared_basin.is_file():
        entries.append(("shared/basin.png", shared_basin))
    for character in catalog["characters"]:
        directory = character["assetDirectory"]
        for name in character["poseFiles"]:
            relative = directory + "/" + name
            path = artwork / directory / name
            if not path.is_file():
                raise SystemExit("catalog lists a missing file: " + relative)
            entries.append((relative, path))
    return entries


def pack_assets(assets: pathlib.Path, work: pathlib.Path):
    """Write assets.bin + assets.idx.json and return (blob, index, png count, bytes)."""
    entries = catalog_entries(assets)
    blob_path = work / "assets.bin"
    index_path = work / "assets.idx.json"
    records = []
    offset = 0
    with open(blob_path, "wb") as blob:
        for relative, path in entries:
            data = path.read_bytes()
            if relative.endswith(".png") and (len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n"):
                raise SystemExit("not a PNG: " + relative)
            blob.write(data)
            records.append({"name": relative, "offset": offset, "length": len(data)})
            offset += len(data)
    index_path.write_text(
        json.dumps({"schemaVersion": 1, "files": records}, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    return blob_path, index_path, sum(1 for record in records if record["name"].endswith(".png")), offset


def icon_path(assets: pathlib.Path) -> pathlib.Path:
    icon = assets / "App.ico"
    if not icon.is_file():
        raise SystemExit("missing prepared Windows icon: " + str(icon)
                         + "\nrun: node tools/package-windows-pet.mjs --prepare-assets")
    return icon


def compile_exe(source: pathlib.Path, assets: pathlib.Path, work: pathlib.Path,
                blob: pathlib.Path, index: pathlib.Path, output: pathlib.Path):
    csc = pathlib.Path(FRAMEWORK_CSC)
    if not csc.is_file():
        raise SystemExit("csc.exe was not found; single-file builds need Windows .NET Framework 4.8.")

    framework = pathlib.Path(FRAMEWORK_ROOT)
    references = [
        framework / "System.dll",
        framework / "System.Core.dll",
        framework / "System.Web.Extensions.dll",
        framework / "System.Xaml.dll",
        framework / "WPF" / "WindowsBase.dll",
        framework / "WPF" / "PresentationCore.dll",
        framework / "WPF" / "PresentationFramework.dll",
    ]
    for reference in references:
        if not reference.is_file():
            raise SystemExit("missing .NET Framework component: " + str(reference))

    sources = sorted((source / "HanaDesktopPet.Core").rglob("*.cs"))
    sources += sorted((source / "HanaDesktopPet.Windows").glob("*.cs"))
    if not sources:
        raise SystemExit("no C# sources found under " + str(source))

    manifest = source / "Resources" / "app.manifest"
    if not manifest.is_file():
        raise SystemExit("missing application manifest: " + str(manifest))

    arguments = [
        str(csc), "/nologo", "/noconfig", "/utf8output", "/codepage:65001", "/langversion:5",
        "/optimize+", "/debug-", "/platform:anycpu", "/target:winexe", "/out:" + str(output),
        "/win32manifest:" + str(manifest),
        "/win32icon:" + str(icon_path(assets)),
        "/resource:{0},{1}".format(blob, RESOURCE_BLOB),
        "/resource:{0},{1}".format(index, RESOURCE_INDEX),
    ]
    for reference in references:
        arguments.append("/reference:" + str(reference))
    arguments += [str(item) for item in sources]

    print("compiling {0} sources into {1}".format(len(sources), output.name))
    completed = subprocess.run(arguments, capture_output=True, text=True, encoding="utf-8", errors="replace")
    log = work / "compile.log"
    log.write_text((completed.stdout or "") + (completed.stderr or ""), encoding="utf-8")
    if completed.returncode != 0:
        print((completed.stdout or "") + (completed.stderr or ""))
        if "CS0016" in (completed.stdout or ""):
            raise SystemExit("the output executable is locked - quit the running HanaDesktopPet.exe and build again")
        raise SystemExit("csc failed with exit code {0}; see {1}".format(completed.returncode, log))
    for line in (completed.stdout or "").splitlines():
        if "warning" in line.lower():
            print("  " + line.strip())


def run_asset_check(exe: pathlib.Path):
    """The executable decodes all 211 PNGs from its own resources."""
    completed = subprocess.run([str(exe), "--check-assets"], capture_output=True, text=True,
                               encoding="utf-8", errors="replace", timeout=180)
    print("asset self-check:", (completed.stdout or "").strip() or "(no output)")
    if completed.returncode != 0:
        print((completed.stderr or "").strip())
        raise SystemExit("embedded asset check failed")


def build_zip(exe: pathlib.Path, source: pathlib.Path, assets: pathlib.Path,
              output: pathlib.Path, version: str, protocol: int):
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        archive.write(exe, exe.name)
        for path in require_travel_documents(source, assets):
            archive.write(path, pathlib.Path(path.name).name)
        archive.writestr(
            "version.json",
            json.dumps(
                {
                    "version": version,
                    "protocolVersion": protocol,
                    "target": "Windows 10 1903+ / Windows 11 x64",
                    "distribution": "single-file-portable",
                },
                ensure_ascii=False,
                indent=2,
            ) + "\n",
        )
    return output


def write_build_manifest(work: pathlib.Path, root: pathlib.Path, source: pathlib.Path,
                         exe: pathlib.Path, version: str, protocol: int,
                         artwork_count: int, artwork_bytes: int):
    """Write a fresh manifest for THIS build; never rewrite the historical record.

    `pet-windows/package-manifest.json` ships inside the original standalone
    source bundle and documents the 0.2.0 executable that was actually released.
    It is kept as source evidence, so a rebuild writes here instead of mutating
    it, and this manifest never hashes itself.
    """
    manifest_path = work / "package-manifest.json"
    tracked_roots = [source]
    files = []
    for tracked in tracked_roots:
        for path in sorted(tracked.rglob("*")):
            if not path.is_file():
                continue
            relative = str(path.relative_to(root)).replace("\\", "/")
            if relative.endswith(".exe") or relative == "pet-windows/package-manifest.json":
                continue
            if ".build" in path.parts or "__pycache__" in path.parts:
                continue
            files.append({"path": relative, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    manifest = {
        "schemaVersion": 1,
        "kind": "windows-single-file-build",
        "version": version,
        "protocolVersion": protocol,
        "distribution": "single-file-portable",
        "sourceRoot": "pet-windows",
        "executable": {
            "name": exe.name,
            "sha256": hashlib.sha256(exe.read_bytes()).hexdigest(),
            "bytes": exe.stat().st_size,
            "embeddedArtworkBytes": artwork_bytes,
        },
        "poseCount": artwork_count,
        "files": files,
    }
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("build manifest: {0} ({1} files)".format(manifest_path, len(files)))
    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="repository root (default: parent of tools/)")
    parser.add_argument("--no-zip", action="store_true", help="build the exe only")
    parser.add_argument("--check-assets-only", action="store_true",
                        help="pack the artwork blob/index and report counts without compiling (macOS-friendly)")
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    source = root / SOURCE_DIR
    assets = root / ASSET_DIR
    if not (source / "version.json").is_file():
        raise SystemExit("not a repository root: " + str(root))

    version, protocol = read_version_metadata(source)
    verify_protocol_matches_sources(source, protocol)
    require_travel_documents(source, assets)

    work = root / WORK_DIR
    # Only the project-owned, regenerable scratch directory is ever removed.
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    dist = source.parent / "dist"
    dist.mkdir(exist_ok=True)

    blob, index, count, total = pack_assets(assets, work)
    print("packed {0} images, {1:.1f} MB".format(count, total / 1024 / 1024))

    if args.check_assets_only:
        print("asset packing verified; no compilation attempted")
        return 0

    exe = dist / "HanaDesktopPet.exe"
    compile_exe(source, assets, work, blob, index, exe)
    print("built {0} ({1:.1f} MB)".format(exe.name, exe.stat().st_size / 1024 / 1024))

    run_asset_check(exe)

    if not args.no_zip:
        archive = build_zip(exe, source, assets,
                            dist / ("HanaDesktopPet-windows-{0}-portable.zip".format(version)),
                            version, protocol)
        print("zip: {0} ({1:.1f} MB)".format(archive.name, archive.stat().st_size / 1024 / 1024))

    write_build_manifest(work, root, source, exe, version, protocol, count, total)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
