#!/usr/bin/env bash
# Provision the Python bridge into the .app's Resources/.
#
# Two modes:
#
#   default (--venv)      Builds a Python venv next to bridge.py. Used by
#                         the dev workflow — fast, no PyInstaller dep,
#                         but requires a Python on the user's machine.
#
#   --standalone          Runs bridge/build_standalone.sh (PyInstaller)
#                         and copies the resulting one-folder bundle to
#                         <Resources>/bridge_bundled/bridge_app/. The
#                         shipping DMG uses this mode so end users do
#                         not need Python installed.
#
# Usage:
#   ./scripts/install_bridge_deps.sh /path/to/Ductor\ Companion.app
#   ./scripts/install_bridge_deps.sh ./Jarvis/Jarvis/Resources
#   ./scripts/install_bridge_deps.sh --standalone /path/to/built.app
#   ./scripts/install_bridge_deps.sh --standalone ./Jarvis/Jarvis/Resources

set -euo pipefail

MODE="venv"
TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --standalone)
            MODE="standalone"
            shift
            ;;
        --venv)
            MODE="venv"
            shift
            ;;
        --help|-h)
            sed -n '1,30p' "$0"
            exit 0
            ;;
        *)
            if [[ -z "${TARGET}" ]]; then
                TARGET="$1"
                shift
            else
                echo "unknown arg: $1" >&2
                exit 64
            fi
            ;;
    esac
done

if [[ -z "${TARGET}" ]]; then
    echo "usage: $0 [--standalone] <.app | path/to/Resources>" >&2
    exit 64
fi

if [[ "${TARGET}" == *.app ]]; then
    RESOURCES="${TARGET}/Contents/Resources"
else
    RESOURCES="${TARGET}"
fi

if [[ ! -d "${RESOURCES}" ]]; then
    echo "error: resources directory not found at ${RESOURCES}" >&2
    exit 66
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ "${MODE}" == "standalone" ]]; then
    echo "==> building PyInstaller bundle"
    bash "${ROOT}/bridge/build_standalone.sh"

    BUNDLE_SRC="${ROOT}/bridge/dist/bridge_app"
    BUNDLE_DST="${RESOURCES}/bridge_bundled/bridge_app"
    if [[ ! -d "${BUNDLE_SRC}" ]]; then
        echo "error: PyInstaller output not found at ${BUNDLE_SRC}" >&2
        exit 70
    fi
    rm -rf "${RESOURCES}/bridge_bundled"
    mkdir -p "$(dirname "${BUNDLE_DST}")"
    cp -R "${BUNDLE_SRC}" "${BUNDLE_DST}"
    chmod +x "${BUNDLE_DST}/bridge"
    echo "==> bundled bridge at ${BUNDLE_DST}/bridge"
    exit 0
fi

# ---------- venv mode (dev workflow) ----------

BRIDGE_DIR="${RESOURCES}/bridge"
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
