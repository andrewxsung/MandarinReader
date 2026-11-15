#!/bin/bash
# Captures App Store screenshots on an iPhone and an iPad simulator.
#
#   1. Start the backend locally (README: Local Development Setup).
#   2. Run:  ios/MandarinReader/scripts/take_screenshots.sh
#
# PNGs land in ios/MandarinReader/screenshots/<simulator name>/.
# Pick other simulators with IPHONE_SIM / IPAD_SIM, for example:
#   IPHONE_SIM="iPhone 17 Pro" ios/MandarinReader/scripts/take_screenshots.sh
# List the ones you have with:  xcrun simctl list devices available
set -euo pipefail

cd "$(dirname "$0")/.."
OUT="$PWD/screenshots"
IPHONE_SIM="${IPHONE_SIM:-iPhone 17 Pro Max}"
IPAD_SIM="${IPAD_SIM:-iPad Pro 13-inch (M5)}"

if ! curl -sf http://localhost:8000/health >/dev/null; then
  echo "The backend isn't answering on localhost:8000. Start it first (see README)." >&2
  exit 1
fi

for SIM in "$IPHONE_SIM" "$IPAD_SIM"; do
  if ! xcrun simctl list devices available | grep -qF "$SIM ("; then
    echo "No simulator named \"$SIM\". Available ones:" >&2
    xcrun simctl list devices available | grep -E "iPhone|iPad" >&2
    exit 1
  fi
  echo "==> $SIM"
  rm -rf "$OUT/$SIM" "$OUT/$SIM.xcresult"
  mkdir -p "$OUT/$SIM"

  # Clean status bar (9:41, full battery and signal), as in Apple's own shots.
  xcrun simctl boot "$SIM" 2>/dev/null || true
  xcrun simctl status_bar "$SIM" override --time "9:41" --batteryState charged \
    --batteryLevel 100 --cellularBars 4 --wifiBars 3 2>/dev/null || true

  TEST_RUNNER_SCREENSHOT_DIR="$OUT/$SIM" xcodebuild test \
    -project MandarinReader.xcodeproj \
    -scheme MandarinReader \
    -destination "platform=iOS Simulator,name=$SIM" \
    -only-testing:MandarinReaderUITests/AppStoreScreenshotTests \
    -resultBundlePath "$OUT/$SIM.xcresult" \
    -quiet

  if ! ls "$OUT/$SIM"/*.png >/dev/null 2>&1; then
    echo "No PNGs were written for $SIM. They're still in the test report:" >&2
    echo "open \"$OUT/$SIM.xcresult\" and save them from the test's attachments." >&2
  fi
done

echo "Screenshots saved in $OUT"
