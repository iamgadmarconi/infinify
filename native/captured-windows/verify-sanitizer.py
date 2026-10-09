#!/usr/bin/env python3
"""Exercise the export CLI on saved copies; never launch a native fixture."""
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'native/captured-windows/sanitize-evidence.py'
HISTORICAL_HARNESS = '7c8ffedb816c53410e71ebbbf8fafa05b72670285cce86da8dde5e0ce2688ef4'


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stripped(value):
    if isinstance(value, dict):
        return {key: stripped(item) for key, item in value.items() if key != 'nonce'}
    if isinstance(value, list):
        return [stripped(item) for item in value]
    return value


def verify_manifest(root):
    manifest = json.loads((root / 'sha256.json').read_text())
    files = manifest.get('files', manifest)
    assert files == {str(p.relative_to(root)): digest(p) for p in root.rglob('*')
                     if p.is_file() and p.name != 'sha256.json'}
    return manifest


def run(root):
    subprocess.run([sys.executable, str(SCRIPT), str(root)], check=True, timeout=10,
                   stdout=subprocess.DEVNULL)


def main():
    original = REPO / 'native/captured-windows/evidence/demo-input-regression/run-K54ixM'
    assert digest(REPO / 'tests/e2e/captured-windows.sh') != HISTORICAL_HARNESS
    with tempfile.TemporaryDirectory(prefix='captured-evidence-export-') as temporary:
        root = pathlib.Path(temporary) / 'completed'
        shutil.copytree(original, root)
        manifest = json.loads((root / 'sha256.json').read_text())
        assert manifest['implementation']['tests/e2e/captured-windows.sh'] == HISTORICAL_HARNESS
        # Both lineage spellings are frozen metadata, not current file hashes.
        manifest['implementation_sha256'] = {'tests/e2e/captured-windows.sh': HISTORICAL_HARNESS}
        (root / 'sha256.json').write_text(json.dumps(manifest))
        for path in root.rglob('source.json'):
            value = json.loads(path.read_text())
            value['nonce'] = 'synthetic-export-only-handshake'
            value['sanitizer_fixture'] = [{'nonce': 'nested-export-only', 'retained': 42}]
            path.write_text(json.dumps(value))
        before = {p.relative_to(root): stripped(json.loads(p.read_text())) for p in root.rglob('*.json')
                  if p.name not in ('sha256.json', 'sanitation.json')}
        images = {p.relative_to(root): digest(p) for p in root.rglob('*.png')}
        run(root)
        after = verify_manifest(root)
        assert after['implementation'] == manifest['implementation']
        assert after['implementation_sha256'] == manifest['implementation_sha256']
        summary = json.loads((root / 'sanitation.json').read_text())
        assert summary['export_tool']['sha256'] == digest(SCRIPT)
        assert summary['implementation_lineage'] == 'preserved'
        for path, value in before.items():
            assert json.loads((root / path).read_text()) == value
        for path, value in images.items():
            assert digest(root / path) == value
        snapshot = {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        run(root)
        assert snapshot == {p.relative_to(root): p.read_bytes() for p in root.rglob('*') if p.is_file()}
        legacy = pathlib.Path(temporary) / 'legacy'
        shutil.copytree(REPO / 'native/captured-windows/evidence/verified/run-ch8fg6_e', legacy)
        legacy_images = {p.relative_to(legacy): digest(p) for p in legacy.rglob('*.png')}
        assert len(legacy_images) == 7
        legacy_values = {p.relative_to(legacy): json.loads(p.read_text()) for p in legacy.rglob('*.json')
                         if p.name not in ('sha256.json', 'sanitation.json')}
        run(legacy)
        legacy_manifest = verify_manifest(legacy)
        assert 'implementation' not in legacy_manifest and 'implementation_sha256' not in legacy_manifest
        assert json.loads((legacy / 'sanitation.json').read_text())['implementation_lineage'].startswith('not recorded')
        for path, value in legacy_images.items():
            assert digest(legacy / path) == value
        for path, value in legacy_values.items():
            assert json.loads((legacy / path).read_text()) == value
        live = pathlib.Path(temporary) / 'live'
        live.mkdir()
        (live / 'source.json').write_text(json.dumps({'pid': os.getpid(), 'nonce': 'live-guard-only'}))
        (live / 'receipt.json').write_text(json.dumps({'source_pid': os.getpid(), 'source_reaped': True}))
        snapshot = {p.name: p.read_bytes() for p in live.iterdir()}
        failure = subprocess.run([sys.executable, str(SCRIPT), str(live)], capture_output=True, timeout=10)
        assert failure.returncode != 0 and b'source still live' in failure.stderr
        assert snapshot == {p.name: p.read_bytes() for p in live.iterdir()}
    print(json.dumps({'passed': True, 'checks': ['historical implementation hashes preserved despite changed checkout',
        'current export hash recorded separately', 'recursive nonce removal only', 'manifest validity',
        'idempotency', 'missing historical lineage not inferred', 'seven PNGs and native measurements unchanged', 'live-source refusal without writes'], 'native_runs': 0}))


if __name__ == '__main__':
    main()
