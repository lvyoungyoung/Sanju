#!/bin/zsh

set -euo pipefail

PROJECT="三句.xcodeproj"
SCHEME="三句"
CONFIGURATION="${CONFIGURATION:-Debug}"
MODE="${1:-simulator}"

case "$MODE" in
  simulator)
    DESTINATION="generic/platform=iOS Simulator"
    DERIVED_DATA_PATH=".codex-derived-data"
    ;;
  device)
    DESTINATION="generic/platform=iOS"
    DERIVED_DATA_PATH=".codex-derived-data-device"
    ;;
  *)
    echo "Usage: bash scripts/build-ios.sh [simulator|device]" >&2
    exit 64
    ;;
esac

echo "Building ${SCHEME} (${CONFIGURATION}) for ${MODE}"
echo "Project: ${PROJECT}"
echo "DerivedData: ${DERIVED_DATA_PATH}"
echo

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -destination "${DESTINATION}" \
  -derivedDataPath "${DERIVED_DATA_PATH}" \
  CODE_SIGNING_ALLOWED=NO \
  build
