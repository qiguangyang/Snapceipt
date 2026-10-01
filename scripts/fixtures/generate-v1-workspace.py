#!/usr/bin/env python3
"""Rebuild the authentic v1 SwiftData store; requires macOS/Xcode and baseline Git object."""
import argparse, hashlib, json, os, pathlib, sqlite3, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = 'e22d9952a1c7eccdca08e2e70976ddee0a59ccb0'
OUT = ROOT / 'SnapceiptTests/Fixtures/v1-workspace.store'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--simulator', required=True, help='Booted arm64 iOS simulator UUID')
simulator = parser.parse_args().simulator
devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', '--json'], text=True))['devices']
runtime = next(key for key, rows in devices.items() if any(row['udid'] == simulator and row['state'] == 'Booted' for row in rows))
with tempfile.TemporaryDirectory(prefix='snapceipt-v1-', dir='/private/tmp') as tmp:
    archive = pathlib.Path(tmp)
    data = subprocess.check_output(['git', 'archive', BASE, 'Snapceipt/Model', 'Snapceipt/Features/Capture/PendingReceipt.swift'], cwd=ROOT)
    subprocess.run(['tar', '-x', '-C', tmp], input=data, check=True)
    model = archive / 'Snapceipt/Model'
    sources = sorted((model / 'Entities').glob('*.swift')) + [model / n for n in ['IDClock.swift', 'Syncable.swift', 'EntityType.swift', 'OutboxMutation.swift', 'ModelContainer+Snapceipt.swift']] + [archive / 'Snapceipt/Features/Capture/PendingReceipt.swift']
    exe = archive / 'fixture-generator'
    sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-module-name', 'Snapceipt', '-parse-as-library', '-target', 'arm64-apple-ios17.0-simulator', *map(str, sources), str(ROOT / 'scripts/fixtures/v1-workspace-main.swift'), '-o', str(exe)], check=True, env={**os.environ, 'SDKROOT': sdk})
    store = archive / 'v1-workspace.store'
    subprocess.run(['xcrun', 'simctl', 'spawn', simulator, str(exe), str(store)], check=True)
    # SQLite backup includes committed WAL contents; ship a single self-contained DB.
    OUT.parent.mkdir(parents=True, exist_ok=True)
    if OUT.exists(): OUT.unlink()
    with sqlite3.connect(store) as src, sqlite3.connect(OUT) as dst: src.backup(dst)
    provenance = {'baselineCommit': BASE, 'module': 'Snapceipt', 'generator': 'scripts/fixtures/generate-v1-workspace.py', 'platform': runtime, 'target': 'arm64-apple-ios17.0-simulator', 'recipeSHA256': hashlib.sha256((ROOT / 'scripts/fixtures/v1-workspace-main.swift').read_bytes()).hexdigest(), 'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(), 'storeSHA256': hashlib.sha256(OUT.read_bytes()).hexdigest(), 'sourcesSHA256': {str(p.relative_to(archive)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}}
    OUT.with_suffix('.provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')
