# Native path comparison

The working comparison and current measurement limits are documented in
[RESULTS-WINDOWSERVER-20261025.md](RESULTS-WINDOWSERVER-20261025.md).
All builds/tests/runtime commands below belong in the disposable VM.

The orchestrator defaults to optimized scalar Dock versus the working file-mmap
WindowServer prototype. The C client is expected at
`variants/windowserver-mailbox/libmailbox-client.dylib`, alongside its payload and
loader. A direct runner uses `--mailbox-client ABS_DYLIB` for this transport;
omission selects the production Unix socket. This is a whole-path comparison,
including transport differences.

Use one workload kind per fresh fixture/60-second prototype. For example:

```sh
sudo python3 native/performance/compare_vm.py --live-owned-fixture \
  --root /Users/admin/InfinifyPerf --output /tmp/if-native-comparison-UNIQUE \
  --windows 8 --pan-points 600 --trace-kind held-step \
  --variant candidate-scalar-inline --variant windowserver --repeats 3
```

`continuous` remains the default:240poses over four seconds at60Hz. `held-step`
now uses48unique poses, approximately100ms each, distributed across six requested
refresh-phase offsets; actual captured-clock phases are reported. It requires
all poses and all six actual buckets to qualify for latency comparison. Legacy
24-pose held traces remain readable. Held poses never qualify for the continuous
smoothness winner. The existing90percent continuous command-pose gate is unchanged.

Capture diagnostics additionally report adjacent admissible samples one refresh
apart (10percent timestamp tolerance). Missing/rejected intervals are excluded;
the resulting fresh-pose fraction is conditional evidence, not overall outputFPS.
The decoder records its own source hash separately from the frozen producer hash.

VM-only primitive validation (root required only for the cross-UID child test):

```sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -std=gnu11 -O2 \
  -Wall -Wextra -Werror native/windowserver-prototype/mailbox-test.c \
  native/windowserver-prototype/mailbox.c -o /tmp/infinify-mailbox-test
sudo /tmp/infinify-mailbox-test
python3 native/performance/test_native_path_bench.py
```

The orchestrator verifies `VirtualMac*`, uses fresh artifact directories, pins
all inputs and always verifies exact original state before reaping its fixture.
It retains raw pixels, replies, geometry, trace and command receipts. It does not
change SIP, the sandbox profile or guest preferences. Any separately authorized
VM setup must have its own backup and restoration receipt.

`sh scripts/build-native-path-bench.sh` builds the common fixture and observer.
The expected production Dock artifacts are
`variants/candidate-scalar-inline/helper/payload-arm64e.dylib` and
`variants/loader-pinned-arm64e`; the cooperative fixture payload is
`variants/candidate-list/helper/payload-arm64.dylib`. Use explicit paths and pin
hashes when reproducing another artifact layout.

Shared-clock schema2 rejects legacy cross-process Python monotonic timestamps.
Pure clock/geometry/API return tests never establish displayed smoothness.
The observer section below explains the independent capture and visibility gate.

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
