#!/usr/bin/env bash
# Builds the Jarvis.app with xcodebuild, installs the Python bridge venv
# into the app's Resources/, and zips the result for distribution.
#
# Usage:  ./scripts/package_app.sh [--configuration Release]

set -euo pipefail

CONFIG="Release"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIG="$2"; shift 2;;
        *) echo "unknown flag: $1" >&2; exit 64;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build"
mkdir -p "${BUILD_DIR}"

echo "==> xcodebuild (${CONFIG})"
xcodebuild \
    -project "${ROOT}/Jarvis/Jarvis.xcodeproj" \
    -scheme Jarvis \
    -configuration "${CONFIG}" \
    -derivedDataPath "${BUILD_DIR}/DerivedData" \
    CODE_SIGN_IDENTITY="-" \
    build

APP_PATH="${BUILD_DIR}/DerivedData/Build/Products/${CONFIG}/Jarvis.app"
if [[ ! -d "${APP_PATH}" ]]; then
    echo "error: Jarvis.app not found at ${APP_PATH}" >&2
    exit 70
fi

echo "==> installing bridge venv"
"${ROOT}/scripts/install_bridge_deps.sh" "${APP_PATH}"

echo "==> zipping"
(cd "$(dirname "${APP_PATH}")" && ditto -c -k --sequesterRsrc --keepParent Jarvis.app "${BUILD_DIR}/Jarvis.zip")
echo "==> done: ${BUILD_DIR}/Jarvis.zip"
