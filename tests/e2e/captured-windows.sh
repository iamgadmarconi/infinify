#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

case ${1:-} in
  '') live=false ;;
  --live-owned-fixture) live=true; shift ;;
  *) echo "Usage: $0 [--live-owned-fixture [--demo-input-only [evidence-directory]|evidence-directory]]" >&2; exit 2 ;;
esac
case ${1:-} in
  '') [ "$#" -eq 0 ] || exit 2 ;;
  --demo-input-only) [ "$#" -le 2 ] || { echo "Usage: $0 [--live-owned-fixture [--demo-input-only [evidence-directory]|evidence-directory]]" >&2; exit 2; } ;;
  -*) echo "Usage: $0 [--live-owned-fixture [--demo-input-only [evidence-directory]|evidence-directory]]" >&2; exit 2 ;;
  *) [ "$#" -eq 1 ] || { echo "Usage: $0 [--live-owned-fixture [--demo-input-only [evidence-directory]|evidence-directory]]" >&2; exit 2; } ;;
esac

./scripts/build-captured-windows.sh
[ "$live" = true ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to launch the disposable native fixture.'; exit 0; }
# Focused regression: no keyboard/focus sequence and no global event posting.
if [ "${1:-}" = --demo-input-only ]; then
  xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
    native/captured-windows/demo-input-regression.m -framework AppKit -framework AVFoundation \
    -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore \
    -o target/captured-windows/demo-input-regression
  mkdir -p "${2:-target/captured-windows/demo-input-evidence}"
  regression_dir=$(mktemp -d "${2:-target/captured-windows/demo-input-evidence}/run-XXXXXX")
  regression_status=0
  target/captured-windows/demo-input-regression "$PWD/target/captured-windows/captured-windows" "$regression_dir" || regression_status=$?
  # The harness has exited and reaped its sources before export sanitation.
  python3 native/captured-windows/sanitize-evidence.py "$regression_dir"
  exit "$regression_status"
fi
python3 - "${1:-target/captured-windows/evidence}" <<'PY'
import hashlib, json, os, pathlib, signal, subprocess, sys, tempfile, time
base=pathlib.Path(sys.argv[1]).resolve(); base.mkdir(parents=True, exist_ok=True)
run=pathlib.Path(tempfile.mkdtemp(prefix='run-',dir=base))
binary=pathlib.Path('target/captured-windows/captured-windows').resolve()
result={'evidence':str(run),'checks':[], 'passed':False}
children=[]
def load(p): return json.loads(p.read_text())
def gone(pid):
    try: os.kill(pid,0); return False
    except ProcessLookupError: return True

def launch(name,mode='--demo',seconds=20):
    folder=run/name; folder.mkdir()
    p=subprocess.Popen([str(binary),mode,str(folder),str(seconds)]);children.append(p)
    return folder,p

def ready(folder,p):
    end=time.monotonic()+5
    while time.monotonic()<end:
        f=folder/'source.json'
        if f.exists() and load(f).get('bounds'): return load(f)
        assert p.poll() is None, ('exited before ready',p.returncode)
        time.sleep(.03)
    raise AssertionError('no source identity')

try:
    # Default does not initialize AppKit, capture, or input.
    assert subprocess.run([str(binary)],capture_output=True,timeout=3).returncode==0
    result['checks'].append('default/help read-only')
    folder,p=launch('proof','--probe',16)
    assert p.wait(timeout=25)==0
    r=load(folder/'receipt.json')
    assert r['screen_capture_preflight'] and r['accessibility_preflight'], r
    assert r['identity_enrolled'] and r['identity_still_valid'] and r['source_behind_covering_host']
    assert r['source_initial']['bounds']==r['source_final']['bounds']
    assert r['source_final']['tick']>r['source_initial']['tick']+5
    assert r['permission_requests']==r['global_input_posts']==r['window_transform_calls']==r['source_custom_surface_exports']==0
    assert r['stream_frames']>=30 and r['stream_error']=='' and r['stream_stopped']
    assert r['source_reaped'] and r['source_exit_status']==0 and gone(r['source_pid']) and gone(r['host_pid'])
    phases=[set(),set()]
    assert len(r['frames'])==6
    for frame in r['frames']:
        assert [frame['width'],frame['height']]==[1040,600]
        observed=[]
        for i,v in enumerate(frame['views']):
            assert v['marker_bounds']==([244,148,32,32],[792,168,48,48])[i],v
            assert v['green']>=(1000,2280)[i] and v['outside_clip']==0,v
            phase='red' if v['red']>(5600,10600)[i] and v['blue']==0 else 'blue' if v['blue']>(5900,10600)[i] and v['red']==0 else None
            assert phase,v
            observed.append(phase); phases[i].add(phase)
        assert observed[0]==observed[1],frame
    assert phases==[{'red','blue'},{'red','blue'}]
    subprocess.run([sys.executable, 'native/captured-windows/verify-png.py', str(folder)], check=True, timeout=20)
    result['checks'].append('actual host pixels: two live copies, exact distinct scale/pan geometry, synchronized updates and clipping')
    public=[a for a in r['attempts'] if a['route']=='public']
    private=[a for a in r['attempts'] if a['route']=='private']
    assert len(public)==len(private)==2
    result['public_controls']=[{k:a[k] for k in ['camera','button_proven','text_proven','scroll_proven']} for a in public]
    for i,a in enumerate(private):
        assert a['camera']==i and a['uncontaminated'],a
        assert a['button_proven'] and a['text_proven'] and a['scroll_proven'],a
        assert a['after']['untagged_events']==a['before']['untagged_events']
        assert any(v['tag']==a['tag'] for v in a['after']['actions'])
        assert a['after']['clicks']>a['before']['clicks']
        assert a['after']['text_sha256']==hashlib.sha256(a['expected_text'].encode()).hexdigest()
        assert a['after']['scroll_y']>a['before']['scroll_y']
        events=[e for e in a['after']['events'] if e['tag']==a['tag']]
        assert all(e['window']==r['source_window'] for e in events)
        assert any(e['type']==1 and e['local']==[120,300] for e in events)
        assert any(e['type']==10 and e['marked_text_sha256']==hashlib.sha256(a['expected_text'].encode()).hexdigest() for e in events)
        assert any(e['type']==22 and e['local']==[200,120] for e in events)
    for mapping in r['input_mappings']:
        i=mapping['camera'];z=(.8,1.2)[i];pan=((0,0),(70,20))[i];port=((20,60),(540,60))[i]
        assert mapping['zoom']==z
        for axis in [0,1]: assert abs((mapping['canvas'][axis]-port[axis])/z+pan[axis]-mapping['source'][axis])<1e-8
    result['checks'].append('private scoped route: marked native button action, exact edited text and native scroll from each scaled view')
    result['checks'].append('source bounds unchanged and updating behind covering host; exact child reaped')

    # These short demo/lifecycle runs do not activate or inject keyboard input.
    folder,p=launch('deadline',seconds=1); assert p.wait(timeout=10)==0
    receipt=load(folder/'receipt.json');assert receipt['source_reaped'] and gone(receipt['source_pid'])
    for sig in (signal.SIGTERM,signal.SIGINT):
        folder,p=launch(sig.name);s=ready(folder,p);p.send_signal(sig);assert p.wait(timeout=8) in (0,2)
        receipt=load(folder/'receipt.json');assert receipt['signal']==sig and receipt['source_reaped'] and gone(s['pid'])
    folder,p=launch('host-SIGKILL');s=ready(folder,p);p.kill();assert p.wait(timeout=5)==-signal.SIGKILL
    end=time.monotonic()+5
    while time.monotonic()<end and (not (folder/'source-exit.json').exists() or not gone(s['pid'])):time.sleep(.03)
    assert load(folder/'source-exit.json')['reason']=='parent_exit' and gone(s['pid'])
    result['checks'].append('deadline, SIGTERM, SIGINT and host SIGKILL dispose source without user-window restoration')
    result['passed']=True
except BaseException as e:
    result['failure']=str(e)
    raise
finally:
    for p in children:
        if p.poll() is None:
            p.terminate()
            try:p.wait(timeout=5)
            except subprocess.TimeoutExpired:p.kill();p.wait()
    (run/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    subprocess.run([sys.executable, 'native/captured-windows/sanitize-evidence.py', str(run)], check=True, timeout=10)
    print(json.dumps(result,indent=2))
PY
