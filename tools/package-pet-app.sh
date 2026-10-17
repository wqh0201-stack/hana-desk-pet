#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE_DIR="$PROJECT_ROOT/pet-macos"
INFO_PLIST="$PACKAGE_DIR/Resources/Info.plist"
DIST_DIR="$PROJECT_ROOT/dist"
APP_NAME="HanaDesktopPet"
APP_BUNDLE_NAME="$APP_NAME-crosspet-v0.5.4-local"
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
if [ "$POSE_COUNT" -ne 193 ]; then
  echo "Expected exactly 193 catalogued WebP poses, found $POSE_COUNT" >&2
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
