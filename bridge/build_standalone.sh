#!/usr/bin/env bash
# Build the PyInstaller one-folder bundle for the bridge.
# Output: bridge/dist/bridge_app/ (Mach-O `bridge` + _internal/).

set -euo pipefail

cd "$(dirname "$0")"

if ! command -v pyinstaller >/dev/null 2>&1; then
    echo "error: pyinstaller not on PATH." >&2
    echo "       install with: pip install pyinstaller" >&2
    exit 127
fi

echo "==> cleaning previous build artifacts"
rm -rf build dist

echo "==> running pyinstaller build_standalone.spec"
pyinstaller build_standalone.spec --clean --noconfirm

if [[ ! -x dist/bridge_app/bridge ]]; then
    echo "error: dist/bridge_app/bridge not produced by pyinstaller" >&2
    exit 70
fi

echo "==> done"
echo "    bundle: $(pwd)/dist/bridge_app/"
echo "    entry : $(pwd)/dist/bridge_app/bridge"
ls -la dist/bridge_app/ | head -20
