#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
cargo build -p driftwm-macos-backend --bins --locked
cargo test -p driftwm-macos-backend --test native_fixture --locked
receipt="${1:-native/backend/evidence/latest-probe.json}"
./target/debug/driftwm-native-probe probe > "$receipt"
python3 - "$receipt" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
# Saved evidence does not need the disposable fixture's handshake token.
r.pop('nonce', None)
with open(sys.argv[1], 'w') as receipt:
    json.dump(r, receipt, indent=2)
    receipt.write('\n')
assert r['foreign_error'] is None, r['foreign_error']
for name in ('own_process', 'foreign_process'):
    p = r[name]
    assert p['restored'], (name, p)
    assert p['original']['transform'] == p['restoration']['transform'], name
    assert p['runtime_transform_supported'] == (p['set_status'] == 0 and p['readback_matches_requested']), name
    if not p['readback_matches_requested']:
        assert not p['runtime_transform_supported'], 'native status alone cannot establish support'
assert r['doctor']['prompts_requested'] is False
assert 'unsupported' in r['multiple_live_presentations']
assert r['input_probe_error'] is None, r['input_probe_error']
assert r['input_probe']['restored']
if r['input_probe']['posted']['posted']:
    assert r['input_probe']['posted']['pointer_restore_status'] == 0
    assert r['input_probe']['scaled_button_input_proven']
    local = r['input_probe']['restoration']['telemetry']['last_mouse_in_window']
    layout = r['input_probe']['hold']['layout']
    expected = [layout['button_buffer_point'][0], layout['appkit_frame'][3] - layout['button_buffer_point'][1]]
    assert all(abs(a-b) < 0.01 for a,b in zip(local, expected)), local
print('PASS: fixture identity, validation, native readback and exact restoration; scaled native button input verified when permission/visibility allow; multiview remains unproven')
PY
