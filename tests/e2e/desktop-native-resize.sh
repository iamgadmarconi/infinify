#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/../.."
case "${1:-}" in
  '')
    ./scripts/build-app.sh
    ./target/app/Infinify.app/Contents/MacOS/Infinify --help | rg -- '--owned-resize-probe'
    ./tests/e2e/desktop-resize.sh
    python3 native/desktop/resize-verify-regression.py
    python3 - <<'PYCODE'
import hashlib, json
from pathlib import Path
files = list(Path('native/desktop').glob('*.m')) + list(Path('native/desktop').glob('*.h'))
files += [Path('native/captured-windows/captured.m'), Path('native/resize/resize.m'),
          Path('native/resize/resize.h'), Path('native/families/window-server-family.h'),
          Path('native/desktop/resize-live.py'), Path('native/desktop/resize-verify.py'),
          Path('native/desktop/resize-verify-regression.py'), Path('scripts/build-app.sh'),
          Path('tests/e2e/desktop-native-resize.sh')]
files += list(Path('native/focus').glob('*.m')) + list(Path('native/focus').glob('*.h'))
files += [Path('Cargo.toml'), Path('Cargo.lock')]
for crate in ('desktop', 'canvas'):
    files += list(Path('crates', crate).rglob('*.rs'))
    files += [Path('crates', crate, 'Cargo.toml')]
files += list(Path('crates/desktop/include').glob('*.h'))
receipt = {'checks': ['signed app build', 'pre-AppKit help', 'headless resize ABI', 'offline PNG oracle'],
           'native_runtime': 'UNRUN',
           'executable_sha256': hashlib.sha256(Path('target/app/Infinify.app/Contents/MacOS/Infinify').read_bytes()).hexdigest(),
           'source_sha256': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                                                     for p in sorted(set(files))}}
Path('target/resize/native-probe-headless.json').write_text(json.dumps(receipt, indent=2) + '\n')
PYCODE
    printf '%s\n' 'Safe build/headless checks passed. Native fixture, capture, AX resizing and live cleanup: UNRUN.'
    ;;
  --live-owned-fixture)
    shift
    exec python3 native/desktop/resize-live.py --live-owned-fixture "$@"
    ;;
  --help)
    printf '%s\n' 'Default: build, help, resize headless integration, offline PNG oracle only.' \
      'Live (explicit authorization required): --live-owned-fixture [--scenario right-shrink] [--directory EMPTY_DIR]' \
      'Scenarios: EDGE-grow|shrink|clamp (eight edges), static, family, sigint, sigterm, controller-death.' \
      'One bounded session by default; --scenario matrix explicitly requests the full matrix.'
    ;;
  *) exit 64 ;;
esac
