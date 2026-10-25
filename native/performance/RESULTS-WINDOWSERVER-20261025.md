# Working WindowServer prototype versus Dock — 25 October 2026

**WindowServer had lower observed mean displayed-pose latency in this VM.
Smoothness was mixed, so there is no overall smoothness winner.**

The fixture-scoped WindowServer prototype now works through private file-backed
shared memory. The existing sandbox policy stays in place. It applied real
transforms, its final pose was checked independently, and every experiment
restored all eight original window transforms and alpha before reaping its
disposable child. This supersedes the earlier socket-blocked prototype result;
the [earlier Dock comparison](RESULTS-20261025.md) remains historical evidence.

## Latency

The final held-pose experiment used 48 unique poses, approximately 100 ms each,
split between pan and zoom. Input phases were distributed across six refresh
phase buckets. All 48 poses and all six actual captured-clock phase buckets were
observed in every trial. Each backend ran three times in alternating order.

Equal-weight averaging across phase buckets, then across the three trials:

- Optimized scalar Dock: **39.78 ms**.
- WindowServer resident prototype: **30.27 ms**.
- Observed mean reduction: **9.50 ms**, approximately **24%**.

Paired reductions were **0.39, 18.51 and 9.61 ms**. WindowServer was lower in all
three pairs, but the first difference was tiny and three pairs do not establish
a universal ranking or statistical significance. These are captured display-pose
latencies, not physical pointer input-to-photon measurements.

Control acknowledgements also favored WindowServer: the median of the three
per-trial acknowledgement p99 values was **4.99 ms**, versus **58.20 ms** for
Dock. This is a separate control-path result and is not substituted for displayed
latency.

## Continuous pan/zoom and smoothness

Each continuous trial scheduled 240 camera poses at 60 Hz: two seconds of pan
over 600 points and two seconds of zoom. The display mode was independently read
as 60 Hz. Actual captured command-pose coverage was only **60–75%**, so the
existing 90% gate correctly refused a global smoothness winner. It was not
lowered to obtain a result.

A narrower measurement examines only two adjacent, admissible captures exactly
one requested refresh apart, within a 10% timestamp tolerance. Both endpoints
must have a fresh visibility witness and an unambiguous marker pose. Missing,
ambiguous or rejected captures are excluded, not declared stutters:

- Dock: **333/376** observed transitions had a fresh pose (**88.6%**).
- WindowServer: **350/377** had a fresh pose (**92.8%**).

WindowServer favored this conditional metric in two trials; Dock was better in
the third. The per-trial fresh fractions were Dock **78.7%, 91.4%, 96.9%** and
WindowServer **99.2%, 100%, 81.9%**. Only 58–75% of recorded transitions qualified
for this conditional analysis. It is not total output FPS and cannot account for
the missing display intervals.

The latency evidence favors the current WindowServer path. The smoothness
evidence does not justify declaring it consistently smoother. Production remains
on Dock: the prototype implements a bounded, transform-only fixture experiment,
not the production alpha, Spaces, pinning, enrollment and recovery contract.

## Comparison controls and provenance

Both paths used the same marker fixture, immutable trace within each experiment,
eight window sizes/positions, independent geometry sampler, ScreenCaptureKit
display observer, 60 Hz request, shared Mach clock and exact restoration checks.
The guest was Apple Silicon `VirtualMac2,1`, macOS 27.0.1 build 26A434, with the
pinned SkyLight image documented in [SERVER-ABI.md](../windowserver-prototype/SERVER-ABI.md).

Dock used its production Unix socket; WindowServer used the bounded mmap
transport. This compares the complete paths and includes the transport and
implementation differences. It does not isolate residency as the sole cause.
The prototype changes no server routine ABI or bootstrap byte sequence.

Primary evidence is [results-windowserver-20261025.json](results-windowserver-20261025.json):
continuous comparison 14 and held-48 comparison 16. Each contains three pairs.
The summary retains all per-trial values, producer/decoder/artifact hashes,
coverage limits and cleanup receipts. Raw pixels, decoded samples, source
snapshots matching producer hashes, replies, geometry and command logs remain
under `target/native-perf/evidence/if-native-comparison-{11..16}` in this worktree.
Original reports from before the final decoder are retained beside the updated
reports. The final decoder's hash is explicit; capture data was not changed.

Exploratory comparisons 12/13 ran with poorer capture cadence; comparison 15
used 24 held poses and lacked one phase bucket in a trial. They are retained as
separate evidence and are not pooled into the headline latency result. UTM was
raised before primary comparisons 14/16; actual observer health, rather than the
60 Hz mode alone, determines each result's limits. The longer held workload
provided eight planned steps per phase bucket without relaxing eligibility.

## VM validation and cleanup

No tests, native programs or builds for this continuation ran on the laptop.
The VM passed 109 selected Rust tests, targeted check/Clippy and formatting;
native discovery/events/capture/frame adapter regressions; 15 benchmark contracts;
and a 256-round-trip kernel IPC test across UIDs 501/88. The IPC test proves
read-only peer enforcement, rejection of a writable directory ACL, shared wake
behavior and HMAC tamper rejection; it is not a native compositing proof.

The final prototype compiled and signed in the VM with `-O2 -Wall -Wextra -Werror`.
The initial WindowServer smoke and all 30 subsequent paired runs verified exact
original restoration and reaped their own fixture. Successful native execution
is established separately from compilation or acknowledgement counters by the
independent geometry and captured display observations.

The temporary guest Library Validation preference is restored to its original
absence and the guest rebooted after evidence was copied out. Exact staged GPU
payload directories are removed only after that server exits. SIP, boot arguments
and the sandbox profile are unchanged. The restoration receipt is retained with
the raw evidence. No runtime credentials, scene saves or build products are
included in the source commit.
