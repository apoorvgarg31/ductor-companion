#!/usr/bin/env bash
# Builds a self-contained Python venv inside Jarvis.app/Contents/Resources/bridge/.venv
# so the Swift host can launch bridge.py without polluting the user's global Python.
#
# Usage:
#   ./scripts/install_bridge_deps.sh /path/to/built/Jarvis.app
#   # or, for development against the source tree:
#   ./scripts/install_bridge_deps.sh ./Jarvis/Jarvis/Resources

set -euo pipefail

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
    echo "usage: $0 <Jarvis.app | path/to/Resources>" >&2
    exit 64
fi

if [[ "${TARGET}" == *.app ]]; then
    BRIDGE_DIR="${TARGET}/Contents/Resources/bridge"
else
    BRIDGE_DIR="${TARGET}/bridge"
fi

if [[ ! -d "${BRIDGE_DIR}" ]]; then
    echo "error: bridge directory not found at ${BRIDGE_DIR}" >&2
    exit 66
fi

PYTHON="${PYTHON:-python3.11}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
    PYTHON="python3"
fi

echo "==> using ${PYTHON} ($(${PYTHON} --version))"
echo "==> creating venv in ${BRIDGE_DIR}/.venv"

rm -rf "${BRIDGE_DIR}/.venv"
"${PYTHON}" -m venv "${BRIDGE_DIR}/.venv"

# shellcheck disable=SC1091
source "${BRIDGE_DIR}/.venv/bin/activate"
pip install --upgrade pip
pip install -r "${BRIDGE_DIR}/requirements.txt"
deactivate

echo "==> done. python is at ${BRIDGE_DIR}/.venv/bin/python3"
