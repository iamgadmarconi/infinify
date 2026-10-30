# Native focus adapter

GPL-3.0-or-later; Apple Silicon / macOS 26+. `focus.h` exposes a C ABI for the
Objective-C desktop shell (`native/desktop`); `focus.m` is compiled into the app by
`scripts/build-app.sh` and needs AppKit and ApplicationServices. Serial background use.
Nothing here claims more than the headless test and the packaged-app tests below observe.

## API

Enrollment binds PID + kernel process-birth seconds and microseconds + CGWindowID
(`dw_focus_identity`; `dw_focus_birth` and `dw_focus_owner` are its read-only parts).
`dw_focus_observe` is read-only. `dw_focus_select` requires an explicit caller guard,
called before activation, each exact AX setter/raise, and while polling. Guard
cancellation, stale identity/bounds, missing or ambiguous AX identity, AX errors, and a
1.5 second call deadline are distinct outcomes (`dw_focus_outcome_name`):

| Outcome | Meaning |
|---|---|
| `observed`, `focused` | the reads agreed; `focused` also says the window is the focused one |
| `invalid` | `dw_focus_select` was given no guard |
| `stale_identity_or_bounds` | the window is another one: its process, start time or window number is no longer the one asked for (a frame that only moved or changed size is the same window) |
| `unavailable` | Accessibility is not trusted, `_AXUIElementGetWindow` is absent, the application's window list cannot be read, or a window's number cannot be read from it |
| `missing_window`, `ambiguous_window` | no AX window, or more than one, has the window number |
| `readback_failed` | AX and CG bounds disagree beyond one point, the frame changed while it was read, or a focus read failed |
| `guard_denied` | the caller's guard refused |
| `ax_failed` | activation or an AX setter failed |
| `timed_out` | the call deadline passed |

One case is not left at "missing": a window the window server still lists as its
process's, that is not on screen and that is in no Accessibility list, which is what a
window on another desktop (Space) is while another desktop is shown; one that is on
screen and missing from the list stays "missing". After the guard has allowed it,
`dw_focus_select` brings it forward by window number as yabai does
(`_SLPSSetFrontProcessWithOptions` and two `SLPSPostEventRecordTo` records to that
process, adapted from yabai dd845723416f5fe92af49fad5ebab00369e07edd,
`src/window_manager.c:1269-1335`, MIT), waits for it in the Accessibility list under
the same guard and deadline, and goes on with the steps above; the result's
`brought_forward` says so. All three symbols are looked up by name and the answer
stays "missing" when one is absent. **Never run:** no test here can put a window on
another desktop, so that this works is unobserved.

Successful selection requires current CG ownership, AX/CG bounds agreement,
system-wide AX focused application and its focused CGWindowID, the selected app's
AX focused CGWindowID, and the native foreground PID. API return codes alone do not
establish focus: `focused` is set only when those reads agree. The caller must
independently establish ownership/authorization; enrollment is not authorization.

The other entry points, as documented in `focus.h`:

- `dw_focus_set_bounds` sets where a window's frame is read from, for every bounds this
  file reports and compares with Accessibility's. The default is the window list's
  `kCGWindowBounds`; under native presentation the shell sets a reader of the window's
  own frame, and a window it cannot read is then no owner. Set it once, before any
  other call.
- `dw_focus_frontmost` is a read-only shortcut target, independent of cached logical
  focus. It reads only the frontmost application's focused AX window with one shared
  50 ms deadline, pins process birth before the AX read and validates the exact
  PID/window ownership, birth and foreground afterward. It does no AXWindows
  enumeration, retry or activation. False zeroes the output and covers unknown and
  expired reads; revalidate before executing a queued action.
- `dw_focus_minimized` reads AXMinimized for one exact identity with the same bounded
  resolver and before/after ownership checks. Unknown is not false.
- `dw_focus_set_minimized` is an explicit minimize/deminimize request. It never closes or
  focuses, and the guard must approve the exact live binding immediately before the write.

## Test

```
sh tests/e2e/native-focus.sh
```

Builds `focus.m` and `focus-regression.c` with warnings as errors and checks, through
the C ABI, that an identity which is not a live window of the process it names is never
owned, that `dw_focus_select` refuses it before its guard runs, and that neither it nor
`dw_focus_set_minimized` changes anything for it. It is read-only: no
window is launched or activated, no Accessibility message is sent, no permission is
requested and no input is posted. Real-window coverage of `dw_focus_select` goes
through the packaged app: `tests/e2e/scoped-windows.sh --live-owned-fixture` asserts
that native focus requests on disposable fixture windows are answered focused.

## Provenance

Private AX signature provenance: [yabai](https://github.com/asmvik/yabai) commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, `src/misc/extern.h:8` and
`src/misc/helpers.h:499-504`. `forward()` in `focus.m` is adapted from the same commit
(MIT): `src/window_manager.c:1269-1291` (`window_manager_make_key_window`) and
`1324-1335` (`window_manager_focus_window_with_raise`), with the signatures of
`src/misc/extern.h:81-82` and `kCPSUserGenerated` of `src/window_manager.h:5`. The rest
is new, with no title matching. The licence text is
[native/desktop/YABAI-NOTICE.txt](../desktop/YABAI-NOTICE.txt).
