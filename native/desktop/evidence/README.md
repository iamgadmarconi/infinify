# Desktop app verification evidence

This directory preserves historical own-fixture observations and later build and
headless integration receipts on macOS 27.2 with SDK 27.0; the app targets
macOS 26.0+ on arm64. No ordinary user application was selected for management. Enrollment
nonces were removed only after each child was reaped. All PNGs depict the
app's own native fixture, captured from the exact compositor host window.

## Historical complete core path

`desktop-receipt.json` and `desktop-frame-0.png` through `desktop-frame-5.png`
belong to the earlier full passing packaged-app probe, before the three review
fixes. That receipt records source SHA-256
`64fb223fc20215b3547d243a25d011f2937c53af324c99a72eff95ab56c7cf9c`
and binary SHA-256
`98a919d1552df5920ff6d9315841f083fa77b6c9d5d6b1906614e027111d7db7`.
It proves chooser selection, two actual live views, camera/world invariance,
anchored zoom, native-handler world dragging, native button/text/scroll behavior
in both views, unbound restore, stale-input rejection, and cleanup for that exact
historical implementation. It is not a full-control result for the newest binary.

## Review fixes and safety regression at the initial checkpoint

`current-build.json` records the initial checkpoint's source and compiled binary hashes, build
success, arm64 / minimum macOS 26.0 metadata, strict signature verification,
Info.plist validity, and shell syntax checks.

`review-fixes-guard-receipt.json` is the current `--demo-probe-guard` run. Its
`passed: false` and process exit 2 are the expected safe rejection: a deliberately
untagged click was routed only to the enrolled disposable source before capture.
The probe emitted no screenshots or scripted control sequence. It stopped
streams, closed panels, and reaped its child. `review-fixes-validation.json`
independently asserts that expected rejection, original-byte preservation after
failed state loading, and refusal to deliver a native drag without a matching
pressed source. This covers the production guard that also refuses retargeting
an already held drag to a different source; a two-source native drag scenario
has not been run.

The clean full-control reruns for that checkpoint were interrupted by physical canvas input or
foreground changes. The hardened probe correctly removed screenshots and stopped
input. Further focus-changing attempts were stopped while the workstation was
active. Current full native-control proof remains unestablished; retain this
boundary when describing readiness. The historical core proof and current
focused safety regression are deliberately separate.

## Build after snapping changes

`build-snapping.json` records the packaged build at revision `4ca7f5e`, including
all canvas/controller source inputs, native source, static library and executable
hashes. Signature, architecture and deployment-target checks passed. Snapping
semantics have separate focused differential/controller tests; no full native
control run was performed on this newly linked binary. Earlier native-control
and safety-regression receipts remain evidence for their own recorded builds.

## Build after controller focus and navigation integration

`build-navigation.json` records the packaged build at revision `21b454d`.
The current canvas/controller sources, native shell, static library and signed
executable are hashed; arm64, minimum macOS 26.0 and signature checks pass.
The new Stage/focus and normal-window navigation APIs have separately reviewed
C ABI tests. The native shell has not yet connected those new actions/effects,
and this binary has no new native-control E2E result. The build was not launched.

## Build after controller resize integration

`build-resize-transactions.json` records the build at revision `f5007b8`, after
independent review of the transaction and its outcome-validation fix. It hashes
the current source inputs, static library and every packaged app file. Signature,
arm64 and minimum macOS 26.0 checks pass. New controller APIs remain disconnected
from native shell actions, and no live native test ran against this build.

## Experimental native navigation integration

`build-shell-navigation.json` records the signed build at revision `9a190b1`.
`navigation-headless.json` records the production Objective-C coordinator and
input-order policy exercised with the real Rust C ABI and injected focus/clock/
scheduling. Independent Astra review approved worker revision `1f4ee5b`, whose
implementation matches the landed source. Review reproduced and then verified
fixes for an orphaned request after command rejection and stale shortcut delivery.

This path requires `--experimental-native-navigation`. No application launch,
capture, activation, native focus mutation, hotkey registration or event tap ran
in these checks. Production driver concurrency, actual Carbon/tap ordering,
foreground notifications and visible animation still require live verification.
Existing first-click delivery and native resize integration remain separate work.

`SHA256SUMS` covers the final bytes of all evidence files except itself.
