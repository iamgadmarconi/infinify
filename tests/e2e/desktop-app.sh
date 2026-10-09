#!/bin/sh
# Only the packaged app's disposable child is eligible for automated input.
set -eu
cd "$(dirname "$0")/../.."
app=target/app/Infinify.app
[ -x "$app/Contents/MacOS/Infinify" ] || ./scripts/build-app.sh
"$app/Contents/MacOS/Infinify" --help >/dev/null
plutil -lint "$app/Contents/Info.plist"
codesign --verify --strict "$app"
evidence=$(mktemp -d "${TMPDIR:-/tmp}/infinify-desktop-e2e.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
"$app/Contents/MacOS/Infinify" --demo-probe "$evidence"
python3 - "$evidence" <<'PY'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); r=json.loads((p/'desktop-receipt.json').read_text())
assert r['passed'], r
assert r['permission_requests']==r['global_input_posts']==r['native_moves']==0
for key in ['enrolled','invalid_scene_preserved','orphan_native_drag_rejected','chooser_selection_attached','world_drag_changed_only_world','separate_live_layers','world_fixed_during_camera_changes',
            'pointer_anchor_stable','independent_second_camera','native_bounds_unchanged',
            'reopen_unbound','detached_input_rejected','panels_closed','sources_detached','streams_stopped','source_reaped']:
    assert r[key], key
assert len(r['controls'])==2
for c in r['controls']:
    assert all(c[k] for k in ['button','text','scroll','native_key_focus','uncontaminated']), c
assert r['stream_frames']>30
assert len(r['frames'])==6
for view in range(2):
    assert any(f['views'][view]['red']>500 for f in r['frames'])
    assert any(f['views'][view]['blue']>500 for f in r['frames'])
    assert all(f['views'][view]['outside_clip']==0 for f in r['frames'])
    assert all((p/pathlib.Path(f['png']).name).is_file() for f in r['frames'])
state=json.loads((p/'scene.json').read_text())
assert 'birth_sec' not in json.dumps(state)
assert not r.get('human_interrupted')
print('PASS: packaged app, two actual live views, native controls after camera changes, unbound reopen, fixture cleanup')
PY

guard_evidence=$(mktemp -d "${TMPDIR:-/tmp}/infinify-desktop-guard.XXXXXX")
printf 'Guard evidence: %s\n' "$guard_evidence"
if "$app/Contents/MacOS/Infinify" --demo-probe-guard "$guard_evidence"; then
  echo 'FAIL: interrupted probe unexpectedly succeeded' >&2
  exit 1
else
  code=$?
  [ "$code" -eq 2 ]
fi
python3 - "$guard_evidence" <<'PY_GUARD'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]);r=json.loads((p/'desktop-receipt.json').read_text())
assert r['self_test_untagged_injection'] and r['human_interrupted']
assert r['screenshots_suppressed'] and not r['passed']
assert not r['frames'] and not r['controls'] and not list(p.glob('*.png'))
assert r['streams_stopped'] and r['panels_closed'] and r['source_reaped']
assert r['permission_requests']==r['global_input_posts']==0
print('PASS: preexisting untagged fixture input suppresses screenshots and scripted controls')
PY_GUARD
