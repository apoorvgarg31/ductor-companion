# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for the bridge. Output: dist/bridge_app/ (one-folder).
# Build via: bash build_standalone.sh

from PyInstaller.utils.hooks import collect_submodules

block_cipher = None

# Telethon / keyring use late-binding module discovery.
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
