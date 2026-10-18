#!/usr/bin/env python3
"""Compile and run the Windows synthetic protocol, transport and animation checks.

This is the Windows-side verification entry point for this repository. It compiles
`pet-windows/HanaDesktopPet.Core` with `pet-windows/HanaDesktopPet.Core.Tests` and
runs them; it needs nothing but the .NET Framework that ships with Windows 10 1903+.

Windows only: `csc.exe` does not exist on macOS, so there this script reports the
blocker and exits 2 instead of pretending the checks passed. The macOS-side checks
live in `tools/run-checks.sh`.

Usage:
    python tools/run-windows-checks.py [--root <repository root>]
"""

import argparse
import pathlib
import subprocess
import sys

FRAMEWORK_ROOT = r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319"
DEFAULT_ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE_DIR = "pet-windows"
WORK_DIR = ".build/windows-checks"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", default=str(DEFAULT_ROOT), help="repository root (default: parent of tools/)")
    args = parser.parse_args()

    root = pathlib.Path(args.root).resolve()
    source = root / SOURCE_DIR
    framework = pathlib.Path(FRAMEWORK_ROOT)
    csc = framework / "csc.exe"
    if not csc.is_file():
        print("csc.exe was not found; the synthetic checks need Windows .NET Framework 4.8.")
        print("This is a Windows-only entry point; macOS verification is `sh tools/run-checks.sh`.")
        return 2

    if not (source / "HanaDesktopPet.Core").is_dir():
        print("missing Windows Core sources under " + str(source))
        return 2

    references = [
        framework / "System.dll",
        framework / "System.Core.dll",
        framework / "System.Web.Extensions.dll",
        framework / "System.Xaml.dll",
        framework / "WPF" / "WindowsBase.dll",
        framework / "WPF" / "PresentationCore.dll",
        framework / "WPF" / "PresentationFramework.dll",
    ]
    sources = sorted((source / "HanaDesktopPet.Core").rglob("*.cs"))
    sources += sorted((source / "HanaDesktopPet.Core.Tests").glob("*.cs"))
    if not sources:
        raise SystemExit("no C# sources found under " + str(source))

    # Only the project-owned, regenerable scratch directory is used.
    work = root / WORK_DIR
    work.mkdir(parents=True, exist_ok=True)
    exe = work / "HanaDesktopPet.Checks.exe"

    arguments = [
        str(csc), "/nologo", "/noconfig", "/utf8output", "/codepage:65001", "/langversion:5",
        "/optimize+", "/debug-", "/platform:anycpu", "/target:exe", "/out:" + str(exe),
    ]
    for reference in references:
        arguments.append("/reference:" + str(reference))
    arguments += [str(item) for item in sources]

    print("compiling {0} sources into {1}".format(len(sources), exe.name))
    compiled = subprocess.run(arguments, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if compiled.returncode != 0:
        print((compiled.stdout or "") + (compiled.stderr or ""))
        return compiled.returncode
    for line in (compiled.stdout or "").splitlines():
        if "warning" in line.lower():
            print("  " + line.strip())

    run = subprocess.run([str(exe)], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
    print((run.stdout or "").strip())
    if run.returncode != 0:
        print((run.stderr or "").strip())
    return run.returncode


if __name__ == "__main__":
    sys.exit(main())
