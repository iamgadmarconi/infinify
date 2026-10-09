#!/usr/bin/env python3
"""Remove expired fixture handshakes only after every source has exited.

This is an export step, never part of live enrollment or native verification.
It refuses to edit a tree containing a live source or missing cleanup evidence.
"""
import hashlib
import json
import os
import pathlib
import sys
import time


def read(path):
    return json.loads(path.read_text())


def gone(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def cleaned(value):
    removed = 0
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key == 'nonce':
                removed += 1
            else:
                result[key], count = cleaned(item)
                removed += count
        return result, removed
    if isinstance(value, list):
        result = []
        for item in value:
            entry, count = cleaned(item)
            result.append(entry)
            removed += count
        return result, removed
    return value, removed


def write(path, value):
    temporary = path.with_name(path.name + '.sanitizing')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def sanitize(root):
    root = root.resolve()
    paths = list(root.rglob('*'))
    if any(path.is_symlink() for path in paths):
        raise RuntimeError('Refusing evidence tree containing symbolic links')
    sources = sorted(root.rglob('source.json'))
    if not sources:
        raise RuntimeError('No source identity records; cleanup cannot be checked')
    # Validate the entire export before modifying any live handshake file.
    deadline = time.monotonic() + 5
    for path in sources:
        identity = read(path)
        pid = identity.get('pid')
        while True:
            receipt = path.with_name('receipt.json')
            exit_record = path.with_name('source-exit.json')
            reaped = receipt.exists() and read(receipt).get('source_reaped') and read(receipt).get('source_pid') == pid
            exited = exit_record.exists() and read(exit_record).get('pid') == pid
            if (reaped or exited) and gone(pid):
                break
            if time.monotonic() >= deadline:
                raise RuntimeError(f'Refusing to sanitize {path}: source still live or cleanup unconfirmed')
            time.sleep(.05)
    count = 0
    for path in sorted(root.rglob('*.json')):
        if path.name == 'sha256.json':
            continue
        value, removed = cleaned(read(path))
        if removed:
            write(path, value)
            count += removed
    manifest = root / 'sha256.json'
    original = read(manifest) if manifest.exists() else None
    summary = root / 'sanitation.json'
    previous = read(summary) if summary.exists() else {}
    write(summary, {
        'redacted_fields': ['nonce'],
        'nonce_fields_removed': previous.get('nonce_fields_removed', 0) + count,
        'source_records_checked': len(sources),
        'cleanup_verified_before_redaction': True,
        'native_measurements_and_pixels_preserved': True,
        'implementation_lineage': 'preserved' if original and ('implementation' in original or 'implementation_sha256' in original) else 'not recorded in original manifest; not inferred',
        'export_tool': {
            'path': 'native/captured-windows/sanitize-evidence.py',
            'sha256': hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
        },
    })
    if original is not None:
        hashes = {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in sorted(root.rglob('*')) if path.is_file() and path != manifest}
        if 'files' in original:
            original['files'] = hashes
            # Historical implementation provenance belongs to the run. Never
            # replace it with the exporting checkout's files or add new tools.
        else:
            original = hashes
        write(manifest, original)
    return {'directory': str(root), 'removed_this_run': count, 'source_records_checked': len(sources)}


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: sanitize-evidence.py COMPLETED_EVIDENCE_DIRECTORY')
    print(json.dumps(sanitize(pathlib.Path(sys.argv[1]))))
