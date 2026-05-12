# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for the Ductor Companion bridge.
#
# Produces dist/bridge_app/ — a "one-folder" bundle containing a
# self-contained `bridge` Mach-O launcher plus a `_internal/` directory
# of vendored libraries (telethon, websockets, keyring, Pillow, …).
#
# The resulting bundle is copied into the .app's Resources/bridge_bundled/
# at packaging time so end users don't need Python installed.
#
# Build:
#   pyinstaller build_standalone.spec --clean --noconfirm
# or:
#   bash build_standalone.sh
#
# Architecture: defaults to the host architecture (arm64 on Apple
# Silicon CI runners). True universal2 builds require both arm64 and
# x86_64 Python toolchains side-by-side, which is fiddly in CI; for
# v0.1.0 we ship arm64-only and document the Rosetta trade-off in
# README.md. Set target_arch='universal2' below to enable it once the
# CI image supports it.

from PyInstaller.utils.hooks import collect_submodules

block_cipher = None

# Telethon / websockets / keyring use late-binding imports and module
# discovery tricks; PyInstaller can't see them through Analysis alone.
hidden_imports = (
    collect_submodules('keyring')
    + collect_submodules('keyring.backends')
    + collect_submodules('telethon')
    + collect_submodules('websockets')
)

a = Analysis(
    ['bridge.py'],
    pathex=[],
    binaries=[],
    datas=[],
    hiddenimports=hidden_imports,
    hookspath=[],
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)
pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='bridge',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name='bridge_app',
)
