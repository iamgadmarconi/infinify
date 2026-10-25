# Native path comparison

These original GPL-3.0-or-later tools compare a frozen camera trace through
prepared scalar Dock, optimized Dock, and WindowServer-resident DWv2 endpoints.
The individual runner does not load helpers, change SIP or permissions, or admit arbitrary apps.
Run all tests and native programs in the owner-authorized VM, not on the laptop.

Schema 2 uses the explicit shared `mach_absolute_time_ns` clock in every process:
`mach_absolute_time() * timebase.numer / timebase.denom`. Python before3.10 can
offset `time.monotonic_ns()` independently in each process, so schema1 visible
latencies are invalid and cannot be decoded or compared by this version.
Regenerate the trace and rerun rather than converting old optical results.
The VM-only parent/child clock contract brackets a child's timestamp with the
parent's native timestamps and independently checks the observer conversion.

`sh scripts/build-native-path-bench.sh` only compiles the marker fixture and
read-only display observer. The Python runner needs no third-party packages.
`python3 native/performance/test_native_path_bench.py` checks the workload and
evidence contracts without native calls; it is not a native smoothness test.

The display observer's exact scalar/NEON pixel-scan contract includes the actual
observer implementation with its program entry point renamed. It checks colour
threshold boundaries, empty/full/sparse/checkerboard/random images, widths around
16-pixel boundaries, scalar tails and odd padded strides. Compile on the host if
needed, but execute this contract only in the VM; its entry point refuses other
hardware models. From the repository root in the VM:

```sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc \
  -Wall -Wextra -Werror native/performance/display_observer_scan_test.m \
  -framework Foundation -framework ScreenCaptureKit -framework CoreGraphics \
  -framework CoreMedia -framework CoreVideo -o target/native-performance/display-observer-scan-test
target/native-performance/display-observer-scan-test
```

This establishes pixel-scan equivalence, not native presentation or a latency win.

## Prepared VM comparison

`compare_vm.py` is the root orchestrator for the explicitly authorized disposable
VM experiment. It refuses non-macOS hosts, `hw.model` values outside
`VirtualMac*`, non-root orchestration and a missing `--live-owned-fixture` flag.
It loads fixture-scoped helpers; do not execute it or its component tests on the
laptop. It contains no SSH invocation, password or build step.

With already-built artifacts under `/Users/admin/InfinifyPerf/variants`, run in
the VM after stopping any earlier marker comparison:

```sh
sudo python3 source/native/performance/compare_vm.py --live-owned-fixture \
  --root /Users/admin/InfinifyPerf --output /tmp/if-comparison-01 \
  --variant candidate-scalar-inline --variant windowserver --repeats 3
```

The default pair is `candidate-scalar-inline` and `windowserver`. `--repeats 1`
supports a separate admission/observer smoke run. Other Dock variant names are
`baseline`, `baseline-o2`, `candidate-scalar`, `candidate-transaction` and
`candidate-list`; choose one Dock variant when including WindowServer so its six
four-second measurements fit within one 60-second outer lifetime. Dock-only comparisons can select several
variants. Every repeat reverses the preceding order, and measurements are serial.

The production helper build now uses `-O2` and retains the ordinary scalar loop;
the transaction and transform-list paths remain explicit comparison builds.
`candidate-scalar-inline` names the current scalar-loop comparison with the
batching-only path compiled out. Keep `candidate-scalar` as its distinct earlier
comparison artifact and preserve each payload's hash rather than treating the
two names as interchangeable. The orchestrator's default pair is a requested
experiment, not a statement that either backend is fastest or already ready.

Expected files are `variants/{VARIANT}/helper/payload-arm64e.dylib`, the common
`variants/loader-pinned-arm64e`, `variants/windowserver-prototype/{ws-loader-arm64e,payload-arm64e.dylib}`,
and `variants/native-performance/{marker-fixture,display-observer}`. The common
fixture uses `variants/candidate-list/helper/payload-arm64.dylib`; an explicit
`--fixture-payload /absolute/path` can choose another cooperative payload. The
common Dock loader must support `--only-pid` together with `--expected-dock`.

The orchestrator starts exactly one admin-owned marker supervisor, captures its
exact identity and original native state, and loads every Dock endpoint before
starting WindowServer's bounded lifetime. It uses fresh short `/tmp/ifp-*`
runtimes, a private fixture nonce file and exact expected Dock/server identities.
Dock payloads are copied into their own runtimes. For WindowServer the executable
payload and its adjacent `.ifwsp` sidecar instead use a separate fresh
`/Library/GPUBundles/InfinifyPerf-*` directory, while the socket and restoration
report retain the short temporary runtime. This split follows the reviewed VM
sandbox's distinct executable-mapping and temporary-write paths; the benchmark
does not edit the sandbox profile. Both directory paths are retained in receipts.
One immutable 60 Hz trace contains two seconds of pan and two seconds of zoom,
with 600 points of pan by default (`--pan-points` can select another bounded span).
Hardware display-mode refresh is queried independently;
a zero result is recorded as unknown rather than interpreted as 60 Hz. Each
observer requests 60 Hz; delivered visible cadence is assessed from its samples.
Before discovery it starts its own temporary `caffeinate -d -i -u` assertion,
scoped to the orchestrator process, so an idle guest display wakes and remains
awake during measurement. Cleanup ends that process. No power setting changes;
the receipt retains online, active and awake display counts and assertion cleanup.

Every run starts the same observer executable, waits for its READY marker, runs
the same client and trace, stops and decodes its own pixel recording, and verifies
the fixture's original transforms and alpha independently. A failed run or
unresolved restoration stops the comparison. Cleanup verifies originals again
before asking the exact supervisor to close its child. Endpoint runtimes remain
on disk because their payloads can remain resident; their paths are retained in
the receipt rather than deleted while a helper may still need them.

The output directory retains pinned executable/source hashes, actual display-mode
configuration, the trace and fixture manifest, stage command/stdout/stderr files,
each run's raw/decoded observer samples and report, per-repeat comparisons, and
`receipt.json` with restoration/cleanup results. Missing or insufficient optical
evidence yields no smoothness winner; acknowledgement and geometry timing alone
never establish the fastest displayed path.

Current WindowServer startup evidence establishes that the experimental dylib
loaded in the authorized VM, but its endpoint socket has not become ready.
No WindowServer timing run or Dock-versus-WindowServer winner is established.
Retain these failed-startup records separately from completed Dock measurements;
successful mapping or bootstrap alone is not a measured native presentation path.

Start one disposable fixture supervisor in the guest, leaving it alive for the
entire matched comparison:

```sh
python3 native/performance/native_path_bench.py fixture --live-owned-fixture \
  --host "$PWD/target/native-performance/marker-fixture" \
  --payload "$PWD/target/privileged/payload-arm64.dylib" \
  --windows 4 --size 480x320 --hold-seconds 300 --output /tmp/if-perf-fixture
```

This writes `fixture.json`, original transforms/bounds/alpha, exact process birth
and executable hash, plus a private nonce. The first opaque fixture window is
magenta and has no shadow; it is ordered over the other disposable windows.
Its helper listener need not be used: the same manifest may scope the prepared
Dock and WindowServer endpoints. All frames name precisely these window IDs.
Do not run another controller against the same fixture while measuring it.

Freeze one workload and machine/display/observer configuration for every run:

```sh
python3 native/performance/native_path_bench.py trace --hz 60 --seconds 2 \
  --pan-points 600 --output /tmp/if-perf-trace.json
```

Keep display mode, fixture positions, window count, CPU load and observer settings
fixed. Run at the actual guest display rate. Repeat in interleaved order (for
example scalar/optimized/server/server/optimized/scalar); isolated averages do
not establish a latency improvement. The trace contains no fixture IDs, so its
hash is identical across modes, and every run also records fixture geometry,
the host hash, platform, and supplied artifact hashes.

After explicitly preparing a fixture-scoped endpoint, record it with raw DWv2:

```sh
python3 native/performance/native_path_bench.py run --live-owned-fixture \
  --runtime /tmp/PREPARED_RUNTIME --nonce-file /tmp/PRIVATE_NONCE \
  --server-pid SERVER_PID --server-uid SERVER_UID \
  --fixture-manifest /tmp/if-perf-fixture/fixture.json \
  --trace /tmp/if-perf-trace.json --variant dock-scalar --output /tmp/if-perf-run-a \
  --artifact payload=/absolute/path/to/payload.dylib --environment /tmp/environment.json
```

The expected PID/UID come from the loader's read-only identity report. They are
checked against the socket peer, including `_windowserver` peers whose UID
differs from the controller. The runner keeps the lease separately, sends
complete frames asynchronously, reads acknowledgements in another thread, and
polls the first fixture's transform through its own read-only SkyLight connection.
Changing `--sample-hz` changes measurement load; keep it identical for all modes.
The endpoint must start with no existing restoration obligations. The runner
requests restoration on all exits and independently verifies the exact original
transform and alpha while the fixture still exists. The supervisor reaps only its
own child and writes `cleanup.json`; end it only after restoration is verified.

Each run saves:

- `frames.jsonl`: scheduled input time, send-call interval, wire sequence, pose.
- `replies.jsonl`: acknowledgement time/status and helper-reported supersession.
- `geometry.jsonl`: independent transform observations and query overhead.
- `run.json`: p50/p95/p99/max stage timings, pinned inputs and restoration result.

Send-call, acknowledgement and sampled geometry timings are distinct metrics.
They do not establish input-to-visible latency or optical native-window FPS.
Server queue time is not isolated by the wire protocol; acknowledgement time
includes transport, queueing, application and response work.

## Independent displayed-pixel observation

If the guest already grants Screen Recording to the observer's launch context,
start this before the run and leave it recording for all phases:

```sh
target/native-performance/display-observer /tmp/if-perf-fixture/fixture.json \
  /tmp/if-perf-display-a.jsonl 60 12
```

It checks existing access without prompting. It uses a **display** content filter
including only the exact disposable fixture windows, excludes all unlisted apps,
and records magenta marker bounds and display timestamps, not screenshots or
third-party pixels. This measures the captured transformed display composition;
it is not a high-speed-camera measurement of the physical panel. Capture itself
adds load, so capture configuration must match across variants.
Each decoded sample additionally requires an independent front-to-back native
window metadata witness: no higher window may intersect the marker, unknown
geometry is refused, and a witness older than two requested refresh periods is
refused. A filtered source alone never establishes that the marker was visible.
If a virtual display delivers a buffer just before its declared display time,
the observer waits until that time before taking the metadata witness, bounded
by two refresh periods. Raw display time, actual callback time, skew and wait
duration remain separate fields. Larger skew is refused, and observer hashes
and witness policy are part of the matched comparison configuration.

After both programs finish, decode and compare saved output:

```sh
python3 native/performance/native_path_bench.py decode-pixels \
  --run-dir /tmp/if-perf-run-a --fixture-manifest /tmp/if-perf-fixture/fixture.json \
  --raw-pixels /tmp/if-perf-display-a.jsonl --output /tmp/if-perf-decoded-a.jsonl
python3 native/performance/native_path_bench.py compare \
  /tmp/if-perf-run-a/run.json /tmp/if-perf-run-b/run.json --output /tmp/comparison.json
```

Neighbouring camera poses can quantize to indistinguishable pixel bounds,
especially during slow zoom. The decoder omits ambiguous observations and
reports coverage. Less than 90% unambiguous coverage, an observer requested below
the workload rate, unmatched input/environment, or missing restoration prevents
a smoothness winner. Increase capture resolution or shorten the workload before
interpreting sparse matches. Producer drawable timestamps and helper counters
are explicitly inadmissible as output-pixel evidence. A result that improves
only acknowledgement latency remains a control-path result.

The VM orchestrator defaults to `--pan-points 600` (the trace permits0..600):
at60Hz and two seconds per phase, neighbouring poses move about five points,
which improves marker-boundary observability. Retain older300-point raw runs as
their original workload; do not reinterpret their decoder omissions as output
stutters. `observed_pose_gap_intervals` counts unobserved intervals between
decoded poses and can include capture or decoder omissions. It never counts
proven physical missed refreshes. The comparator uses that limited captured-pose
metric and captured-pose latency; its result is not a physical-panel FPS claim.

This fixture comparison does not prove third-party app compatibility, independent
display clipping, live replicas, or real physical pointer input-to-photon latency.
