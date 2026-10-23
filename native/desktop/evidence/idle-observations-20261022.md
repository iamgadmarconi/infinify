# Pinned-window idle observations, 2026-10-22

An unchanged native observation previously took the full controller transaction
path whenever any screen pin existed. Calculator therefore defeated snapshot
reuse for every other unchanged window in the six-window UTM scene. Pins alone
no longer veto the no-op path; pending structure, gestures and changed identity,
geometry or buffers still do.

Nineteen focused observation tests, two existing CLI pin-drag scenarios, targeted
check/clippy and formatting passed. Differential checks compare the complete
controller state with the full transaction, including partially offscreen pins.
Real-app Fill/restore and repeated overview round trips retained the original
scene and Calculator's independently read native/screen geometry.

Two cooled 12-second samples measured v32 at 5.66% and v33 at 5.26% of one guest
core. This is a small change, with other changes in the same build; it does not
establish an isolated or statistically robust CPU gain. RSS was 99.44 versus
133.28 MiB. The latter process had a 34 MiB empty malloc region retained by the
allocator; its physical footprint was 206.1 MiB. Neither a live leak nor a memory
improvement is established by these different measurements.

Raw samples, memory map and profiling notes are under the ignored
`target/performance/native-real-apps-20261022/` directory. These measurements do
not establish frame rate, absence of stutters, or hardware behavior outside the
macOS 27.0.1 (26A434) UTM guest.
