#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE_DIR="$PROJECT_ROOT/pet-macos"
INFO_PLIST="$PACKAGE_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="HanaDesktopPet"
APP_BUNDLE_NAME="$APP_NAME-crosspet-v0.5.5-local"
APP_BUNDLE="$DIST_DIR/$APP_BUNDLE_NAME.app"

if [ ! -f "$INFO_PLIST" ]; then
  echo "Missing bundle metadata: $INFO_PLIST" >&2
  exit 1
fi
if [ -e "$APP_BUNDLE" ]; then
  echo "Refusing to overwrite existing bundle: $APP_BUNDLE" >&2
  echo "Move or remove that generated bundle manually, then rerun this script." >&2
  exit 1
fi

mkdir -p "$DIST_DIR"

# Build only; this script never launches the GUI or installs the app.
swift build --package-path "$PACKAGE_DIR" --configuration release --product "$APP_NAME"
BIN_DIR=$(swift build --package-path "$PACKAGE_DIR" --configuration release --show-bin-path)
EXECUTABLE="$BIN_DIR/$APP_NAME"
if [ ! -x "$EXECUTABLE" ]; then
  echo "Expected executable was not produced: $EXECUTABLE" >&2
  exit 1
fi

RESOURCE_DIR="$PACKAGE_DIR/Sources/HanaDesktopPet/Resources/CrossPet"
if [ ! -f "$RESOURCE_DIR/catalog.json" ] || [ ! -f "$RESOURCE_DIR/CHARACTERS-LICENSE.md" ] || [ ! -f "$RESOURCE_DIR/ATTRIBUTION.md" ]; then
  echo "Missing bundled CrossPet catalog, license or attribution: $RESOURCE_DIR" >&2
  exit 1
fi
POSE_COUNT=$(find "$RESOURCE_DIR" -type f -name '*.webp' | wc -l | tr -d ' ')
CATALOG_POSE_COUNT=$(node -e '
const fs = require("node:fs");
const catalog = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
if (!Array.isArray(catalog.characters)) throw new Error("catalog characters must be an array");
const count = catalog.characters.reduce((sum, character) => sum + character.poseFiles.length, 0);
console.log(count);
' "$RESOURCE_DIR/catalog.json")
if [ "$POSE_COUNT" -ne "$CATALOG_POSE_COUNT" ]; then
  echo "Expected $CATALOG_POSE_COUNT catalog-listed WebP poses, found $POSE_COUNT" >&2
  exit 1
fi

TEMP_BUNDLE="$DIST_DIR/.$APP_BUNDLE_NAME.app.tmp.$$"
if [ -e "$TEMP_BUNDLE" ]; then
  echo "Temporary bundle path already exists: $TEMP_BUNDLE" >&2
  exit 1
fi
cleanup() {
  if [ -d "$TEMP_BUNDLE" ]; then
    /bin/rm -rf "$TEMP_BUNDLE"
  fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

/bin/mkdir -p "$TEMP_BUNDLE/Contents/MacOS" "$TEMP_BUNDLE/Contents/Resources"
/bin/cp "$EXECUTABLE" "$TEMP_BUNDLE/Contents/MacOS/$APP_NAME"
/bin/cp "$INFO_PLIST" "$TEMP_BUNDLE/Contents/Info.plist"
/bin/cp -R "$RESOURCE_DIR" "$TEMP_BUNDLE/Contents/Resources/CrossPet"
BUNDLED_ASSETS="$TEMP_BUNDLE/Contents/Resources/CrossPet"
node - "$BUNDLED_ASSETS" "$PROJECT_ROOT/assets/crosspet" <<'NODE'
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const [bundleRoot, sourceRoot] = process.argv.slice(2);
const catalog = JSON.parse(fs.readFileSync(path.join(bundleRoot, "catalog.json"), "utf8"));
let upstreamCount = 0;
let generatedCount = 0;
for (const character of catalog.characters) {
  const generated = new Set(character.generatedPoses ?? []);
  if ([...generated].some((filename) => !character.poseFiles.includes(filename))) {
    throw new Error(`${character.id}: generatedPoses must be a subset of poseFiles`);
  }
  for (const filename of character.poseFiles) {
    const bundled = path.join(bundleRoot, character.assetDirectory, filename);
    const source = path.join(sourceRoot, character.assetDirectory, filename);
    if (!fs.existsSync(bundled) || !fs.existsSync(source)) {
      throw new Error(`Missing catalog asset: ${character.id}/${filename}`);
    }
    const bundleHash = crypto.createHash("sha256").update(fs.readFileSync(bundled)).digest("hex");
    const sourceHash = crypto.createHash("sha256").update(fs.readFileSync(source)).digest("hex");
    if (bundleHash !== sourceHash) {
      throw new Error(`${character.id}/${filename}: bundled SHA-256 differs from repository source`);
    }
    if (generated.has(filename)) generatedCount += 1;
    else upstreamCount += 1;
  }
}
console.log(`Verified bundled SHA-256: upstream-source=${upstreamCount}, generated-repository-copy=${generatedCount}`);
NODE
/bin/chmod 755 "$TEMP_BUNDLE/Contents/MacOS/$APP_NAME"
/usr/bin/plutil -lint "$TEMP_BUNDLE/Contents/Info.plist" >/dev/null

# Local ad-hoc signing uses no Developer ID certificate and does not notarize the app.
/usr/bin/codesign --force --sign - "$TEMP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$TEMP_BUNDLE"
/usr/bin/codesign --verify --strict --verbose=2 "$TEMP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ -e "$APP_BUNDLE" ]; then
  echo "Refusing to overwrite existing bundle: $APP_BUNDLE" >&2
  exit 1
fi
/bin/mv "$TEMP_BUNDLE" "$APP_BUNDLE"
trap - EXIT HUP INT TERM

printf 'Created locally ad-hoc-signed app bundle: %s\n' "$APP_BUNDLE"
printf 'Bundle identifier: %s\n' "com.hanaagent.prototype.hana-desktop-pet"
printf 'Bundled character poses: %s\n' "$POSE_COUNT"
printf 'Signing: ad-hoc only; no Developer ID certificate or notarization.\n'
