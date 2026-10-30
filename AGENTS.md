# DriftWM macOS development rules

Target Apple Silicon, macOS 26 or later. The Rust canvas is platform-independent;
platform integration belongs in native/ adapters (native/desktop, native/privileged,
native/focus, native/resize).

Preserve GPL-3.0-or-later attribution and exact upstream source provenance.
Keep camera/world geometry independent of native ownership and screen coordinates.
Do not label reducer tests, symbol presence, successful API return codes, or fixture
self-observations as proof of usable third-party native-window compositing.

Default host commands must be read-only. Native mutation experiments may touch only
the explicitly spawned disposable fixture. Preserve/restore the original transform
and clean up children on all exits. Do not change SIP, permissions, user settings,
or unrelated application windows as part of tests. Expanded runtime access needs an
explicitly authorized scope and evidence that the native path is safe.

Use focused end-to-end CLI scenarios and the test modules of changed files.
Do not run full suites unless the owner explicitly requests them. Prefer end-to-end
coverage over unit tests. Format touched Rust files and run targeted clippy/check.
Do not commit generated build products, local scene saves, or runtime credentials.
