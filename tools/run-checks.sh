#!/bin/sh
set -eu

# Reproducible local acceptance flow for the Hana desk pet prototype.
#
# It runs every check this repository relies on, in one command, without a GUI,
# without installing anything, and without touching a real Hana host. It writes
# only into .build/parallel-integration-precheck/.
#
#   sh tools/run-checks.sh
#
# The Node, planner, timeline and cross-layer drivers are independent compilations
# of the production sources; none of them reuse a previously built binary.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
PACKAGE_DIR="$PROJECT_ROOT/pet-macos"
CORE_DIR="$PACKAGE_DIR/Sources/PetCore"
CHECK_DIR="$PROJECT_ROOT/.build/parallel-integration-precheck"
MODULE_CACHE="$CHECK_DIR/ModuleCache"
FIXTURE="$CHECK_DIR/lifecycle-fixture.json"
ASSETS="$PROJECT_ROOT/assets/crosspet"

cd "$PROJECT_ROOT"
mkdir -p "$MODULE_CACHE"

echo "== Node unit tests =="
node --test tests/*.test.mjs

echo "== JS syntax =="
for file in apps/hana-desktop-pet/state-core.mjs apps/hana-desktop-pet/pet-bridge.mjs \
            apps/hana-desktop-pet/index.js apps/hana-desktop-pet/ui/assets/panel.js \
            tests/lifecycle-fixture.mjs; do
  node --check "$file"
done
echo "JS syntax OK"

# `node --check` silently accepts some token errors in ES modules, so the App
# scripts also get a real parse of their module bodies. This is the check that
# catches a stray literal `\n` inside a template literal.
echo "== JS module parse (catches ESM token errors) =="
node -e '
const fs = require("fs"), vm = require("vm");
const files = process.argv.slice(1);
let bad = 0;
for (const file of files) {
  const source = fs.readFileSync(file, "utf8")
    .replace(/^\s*import\s+[^;]*;?\s*$/gm, "")
    .replace(/^\s*export\s+(default\s+)?/gm, "");
  try {
    new vm.Script(source, { filename: file });
  } catch (error) {
    bad += 1;
    console.log("SYNTAX_FAIL " + file + " :: " + error.message);
  }
}
console.log(bad === 0 ? "JS module parse OK" : "JS module parse failures: " + bad);
process.exit(bad === 0 ? 0 : 1);
' apps/hana-desktop-pet/index.js apps/hana-desktop-pet/state-core.mjs \
  apps/hana-desktop-pet/pet-bridge.mjs apps/hana-desktop-pet/ui/assets/panel.js

echo "== Synthetic cross-layer lifecycle fixture =="
node tests/lifecycle-fixture.mjs --out "$FIXTURE"

# The panel's own module body is executed against a minimal DOM stub: a syntax
# error alone would not prove that role buttons, follow options and session rows
# actually render.
echo "== Control panel render smoke =="
node tests/panel-smoke.mjs

echo "== Control panel layout probe (headless Chrome; skipped when Chrome is absent) =="
node tools/panel-layout-probe.mjs

echo "== Pose planner checks (B) =="
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" -o "$CHECK_DIR/PosePlannerChecks" \
  "$CORE_DIR/PetState.swift" \
  "$CORE_DIR/PetArtworkCatalog.swift" \
  "$CORE_DIR/PetPosePlanner.swift" \
  "$CORE_DIR/PetPoseMood.swift" \
  "$CORE_DIR/PetWorkPoseScheduler.swift" \
  tests/pose-planner-checks.swift
"$CHECK_DIR/PosePlannerChecks" "$ASSETS"

echo "== Pose work scheduler checks (A) =="
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" -o "$CHECK_DIR/PoseWorkSchedulerChecks" \
  "$CORE_DIR/PetState.swift" \
  "$CORE_DIR/PetArtworkCatalog.swift" \
  "$CORE_DIR/PetPosePlanner.swift" \
  "$CORE_DIR/PetPoseMood.swift" \
  "$CORE_DIR/PetWorkPoseScheduler.swift" \
  tests/pose-work-scheduler-checks.swift
"$CHECK_DIR/PoseWorkSchedulerChecks" "$ASSETS"

echo "== Pose timeline checks (C) =="
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" -o "$CHECK_DIR/PoseTimelineChecks" \
  "$CORE_DIR/PetState.swift" \
  "$CORE_DIR/PetPointerGesture.swift" \
  "$CORE_DIR/PetWindowInteraction.swift" \
  "$CORE_DIR/PetPoseTimeline.swift" \
  "$CORE_DIR/PetPosePlanner.swift" \
  "$CORE_DIR/PetPoseMood.swift" \
  "$CORE_DIR/PetWorkPoseScheduler.swift" \
  "$CORE_DIR/PetPickUpAnimation.swift" \
  tests/pose-timeline-checks.swift
"$CHECK_DIR/PoseTimelineChecks"

echo "== Pose drag pick-up checks (D) =="
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" -o "$CHECK_DIR/PoseDragPickUpChecks" \
  "$CORE_DIR/PetState.swift" \
  "$CORE_DIR/PetPointerGesture.swift" \
  "$CORE_DIR/PetWindowInteraction.swift" \
  "$CORE_DIR/PetPoseTimeline.swift" \
  "$CORE_DIR/PetArtworkCatalog.swift" \
  "$CORE_DIR/PetPosePlanner.swift" \
  "$CORE_DIR/PetPoseMood.swift" \
  "$CORE_DIR/PetWorkPoseScheduler.swift" \
  "$CORE_DIR/PetPickUpAnimation.swift" \
  tests/pose-drag-pickup-checks.swift
"$CHECK_DIR/PoseDragPickUpChecks" "$ASSETS"

echo "== Cross-layer lifecycle checks (JS projection -> native v2 -> planner -> timeline) =="
swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" -o "$CHECK_DIR/PoseLifecycleChecks" \
  "$CORE_DIR/PetState.swift" \
  "$CORE_DIR/HTTPCodec.swift" \
  "$CORE_DIR/PetAPI.swift" \
  "$CORE_DIR/PetPointerGesture.swift" \
  "$CORE_DIR/PetWindowInteraction.swift" \
  "$CORE_DIR/PetPoseTimeline.swift" \
  "$CORE_DIR/PetArtworkCatalog.swift" \
  "$CORE_DIR/PetPoseHitCoverage.swift" \
  "$CORE_DIR/PetPosePlanner.swift" \
  "$CORE_DIR/PetPoseMood.swift" \
  "$CORE_DIR/PetWorkPoseScheduler.swift" \
  tests/pose-lifecycle-checks.swift
"$CHECK_DIR/PoseLifecycleChecks" "$FIXTURE" "$ASSETS"

echo "== SwiftPM build and PetCoreChecks =="
swift build --package-path "$PACKAGE_DIR"
swift run --package-path "$PACKAGE_DIR" PetCoreChecks

echo "All local checks completed. Fixture: $FIXTURE"
