# Infinify native desktop shell

`./scripts/build-app.sh` builds and ad-hoc signs `target/app/Infinify.app` for
Apple Silicon / macOS 26+. The build does not launch anything. Open the app to
choose ordinary local application windows. No window is automatically selected.
Screen Recording permission is required for capture; Accessibility permission
is required for native input and for focusing a native window from the canvas.
The chooser explains a missing grant and offers an
Allow… button: the app asks macOS for access only from that click, then opens
the matching System Settings pane. Screen Recording takes effect after a
relaunch. Automated probes and tests never request permissions or change privacy
settings or SIP. An ad-hoc signature changes with every build, so macOS drops
both grants on each rebuild; build with
`INFINIFY_SIGN_IDENTITY="<stable signing identity>" ./scripts/build-app.sh` to
keep them.

The app links the actual Rust desktop static library. Every connected display
gets a nonactivating panel and an independently persisted camera on the shared
world. Each visible `(logical window, display)` has its own
`AVSampleBufferDisplayLayer`; one ScreenCaptureKit stream feeds all placements of
a source. This is continuous live capture of native application content.
Ordinary native windows remain where their owners put them. Cameras and world
movement do not move, transform, park, or resize native windows.
[Window navigation](#window-navigation-and-native-focus) activates and raises
the one window it focuses, and nothing else.

## Controls

- Choose windows: add a selected native source, or explicitly rebind a saved
  placeholder using the chooser's drop-down. Same-source duplicate attachments
  are rejected; the existing world window is visible through every display camera.
- Open canvas (chooser): show the saved world without adding a window, at its
  saved cameras only with `[session] restore_camera = true` (see
  [Persistence](#persistence-and-lifecycle)). Placeholders, panning, zooming and the view actions need no capture,
  so this works before any source is chosen and without Screen Recording access.
- Keys, pointer gestures and settings come from one TOML file in DriftWM's own
  grammar; [Configuration](#configuration) has the file, the modifier mapping
  and the default tables. With no file, DriftWM's default bindings apply. The
  chords named in this list are those defaults under the default super chord
  (Control-Option). The status line shows the pointer, window, view, pan and
  bookmark chords the running app resolved, and each toolbar tooltip its own
  action's;
  it does not list every bound key (the default table under
  [Configuration](#configuration) has the rest, three of which start a program).
- Pan a display's camera: drag or two-finger scroll on empty canvas, or
  Control-Option-drag / Control-Option-scroll anywhere. Zoom, pointer-anchored,
  from 0.001 to 1.0: mouse wheel on empty canvas, Control-Option-wheel anywhere,
  or pinch. The view actions below are the animated toolbar and keyboard
  equivalents.
- View actions: toolbar buttons Home, Fit, −, 1:1 and + on every canvas panel,
  and while panels are open the global hot keys bound to `home-toggle`
  (Control-Option-A), `zoom-to-fit` (Control-Option-W; press again to return),
  `zoom-in` (Control-Option-=), `zoom-out` (Control-Option--), `zoom-reset`
  (Control-Option-0 or Control-Option-Z) and `pan-viewport <direction>`
  (Control-Option-Command with an arrow key, one `navigation.pan_step`). Buttons
  act on their own display (in the two-viewport demo panel, the viewport last
  clicked, scrolled or pinched, else the first); hot keys act on the display
  under the pointer, or the first display when the pointer is over no panel.
  Home goes to the origin at 1:1 and Fit frames every window, detached
  placeholders included, together with any `navigation.anchors`; a second press
  returns to the view left, and any other pan or zoom forgets the Fit return.
  Zoom in stops at 1:1. Zoom out stops at half the zoom that fits all windows
  and does nothing if a gesture already zoomed past that. A pointer press, a
  pinch, or a scroll that actually pans or zooms the canvas stops a flight where
  it is. A scroll that is forwarded to a window, has no delta, or is already at
  the zoom limit leaves the flight alone.
- Window navigation, in every normal run (toolbar buttons Center, Previous and
  Next; the hot keys only while panels are open and not with `--windowed`):
  Control-Option with an arrow key (`center-nearest <direction>`) focuses the
  nearest window in that direction and flies the camera to it at the current
  zoom; Control-Option-C (`center-window`) centres the focused window, or the
  one nearest the middle of the view, at 1:1; Control-Option-X (`focus-center`)
  does the same for the window under the pointer; Option-Tab and
  Option-Shift-Tab (`cycle-windows forward` / `backward`) step through the
  windows most recently focused first, and letting go of Option commits the
  choice. A click on a window gives it canvas focus and starts its native
  focus, then the click is forwarded; a click on empty canvas unfocuses, and
  focusing a canvas window in its own application (Command-Tab, the Dock) is
  followed by the canvas. Focusing means logical focus, raising in the canvas,
  and, when Infinify has Accessibility access, activating and raising the real
  window.
  [Window navigation and native focus](#window-navigation-and-native-focus) has
  the rules, the flags and what has and has not been run.
- Bookmarks: Control-Option-1 to 4 (`go-to-bookmark N`) fly the camera of the
  display under the pointer to bookmark 1 to 4 (zoom is left alone and any Fit
  return is forgotten); Control-Option-Shift-1 to 4 (`set-bookmark N`) save the
  usable-area centre of the current view as that bookmark. Pressed while a pan
  step or a bookmark jump is still flying, they save where it is heading. During
  a Home, Fit or zoom flight the saved point is not reliably the destination,
  here as upstream (mid-flight it is whatever point is passing under the
  centre), so let those land first. The status line confirms ("Bookmark 2
  saved") or says the bookmark is missing ("No bookmark 2 yet", with the chord
  that sets it when one is bound). A bookmark holds a canvas position only,
  never a zoom. There is one registry of bookmarks for every display. It starts
  from the config's `[navigation.bookmarks]`, or from DriftWM's four corner
  bookmarks `1` to `4` at (±1750, ±1750) when the file has no such table;
  [Persistence](#persistence-and-lifecycle) says what a restart keeps. These are
  global hot keys only: with `--windowed`, use `Infinify msg bookmark` or
  `Infinify msg action` below.
- Every hot key, every mouse binding that names an action, and every view button
  on the toolbar runs an upstream action string through the same controller
  command as `Infinify msg action`. Camera motion is animated with the
  controller's upstream-derived lerp at `navigation.camera_speed`. The view
  and bookmark actions move cameras only; they never move, resize, focus or
  otherwise touch native windows. The window navigation actions also focus a
  window. If macOS refuses a hot key the status line names it and the
  toolbar still works. The Quit button and Control-Option-Escape call the
  shell's quit directly instead of sending the `quit` action, so exit never
  depends on the controller or on an active output. Control-Option-Escape stays
  the exit chord unless a config binding resolves to that chord, which then
  takes it. DriftWM's own `quit` binding, `mod+ctrl+shift+q`, is
  Control-Option-Command-Shift-Q. The experimental resize controls below keep
  their own gate.
- Option-drag on a window: move the logical world window, using Rust snapping
  and hysteresis with the `[snap]` settings. Add Shift to move its connected
  cluster. Control-Option-Shift with an arrow key (`nudge-window <direction>`)
  moves the focused logical window by `navigation.nudge_step` world points.
  Neither moves a native window.
- An unbound click, drag or scroll on a window is forwarded through Rust inverse
  hit mapping to the selected native source. With DriftWM's defaults that is
  every unmodified one, with the left, right or middle button. An unbound press
  first focuses the window (click-to-focus, see
  [Window navigation and native focus](#window-navigation-and-native-focus));
  a detached placeholder is focused the same way and receives nothing. The original
  application owns keyboard focus, text editing, shortcuts, and IME; the overlay
  does not emulate a text field. Right and middle buttons travel the same
  validated per-window route as the left one, down, drag and up. Whether real
  applications accept them there has not been tried, and a context menu, if one
  opens, opens at the native window's real screen position, not in the canvas.
  An unbound press on empty canvas does nothing, as upstream. A press there
  that is bound to pan (the default left button) and is released within 5
  points of where it went down leaves no window focused, as upstream's pan
  grab does.
- Control-Option-click a detached placeholder dismisses it only while no mouse
  binding claims that press, and the placeholder shows the hint only then.
  DriftWM's defaults do claim it under the default super chord (`mod+left` pans
  anywhere), so out of the box there is no pointer way to dismiss a placeholder.
  `[mouse.anywhere]` with `"mod+left" = "none"`, or a `--super` chord other than
  `ctrl+alt`, frees the press.
- Return to desktop: stop capture, close panels, and show the chooser.
- Quit, the registered Control-Option-Escape hot key, or a key bound to `quit`:
  save and exit. The visible Quit button remains available if hot key
  registration fails.
- Resize status: explains that native layout resizing is currently unavailable.
  Resize the original application on the desktop; observation reconciles native
  bounds and capture dimensions without replacing persistent world geometry.

A click on a source asks for native focus of that one window only: in a normal
run through the controller's focus request and the focus driver, which acts on
the window whose freshly validated identity matches the binding the controller
named; in the fixture modes by activating its owning application, as before.
With `--no-native-focus` the shell activates nothing on a click (what the
forwarded click makes the application do itself was not tried); without
Accessibility access no input is delivered at all. Identity validation checks PID, process birth, window number, current
owner PID, and the last observed native bounds immediately around delivery.
Private per-window routing is reused verbatim from
`../captured-windows/captured.m`, including its Cantrip signature provenance.
There is no global synthetic event fallback. Release-on-cleanup applies only to
the button this shell pressed in a source; user keyboard state is never
synthesized or released. Lost/closed sources become inert placeholders. Stream errors detach
rather than leaving stale content eligible for input.

## Configuration

A normal run is configured exactly like DriftWM: one TOML file in upstream's
grammar decides key bindings, mouse bindings and settings. The parser, defaults
and binding tables are upstream's own code (`driftwm-core`); the controller maps
them to a Mac keyboard and the shell registers what it reports.
[CONFIG.md](../../crates/desktop/CONFIG.md) is the controller's contract and has
the complete default table.

- **File.** `--config /absolute/path.toml`, else
  `$XDG_CONFIG_HOME/infinify/config.toml`, else `~/.config/infinify/config.toml`
  (upstream's own path logic with `infinify` as the directory name; its
  `DRIFTWM_CONFIG` variable still overrides the default path). A missing file is
  not an error while the run has read no file: DriftWM's built-in defaults
  apply. The app never writes the file.
- **Problems.** A file that cannot be read or parsed leaves the previous
  configuration in force (at launch: the defaults). So does a file that goes
  missing after the run has read it, which is upstream's read failure
  (`config: failed to read <path>: No such file or directory`): settings,
  bindings and bookmarks stay as they were. While the file has such an
  error, or a value upstream's parser warns about, the status line rests on the
  first message, a count of the rest and the path, as upstream's error bar
  does, until a later load is clean. Notes about bindings that were skipped are
  shown once, until the next status message. Every message also goes to stderr,
  upstream's own verbatim.
- **Live reload.** The app watches the file and its directory and reloads
  within about 150 ms of a change, whether the file is written in place,
  replaced by a rename, created or deleted. The `reload-config` action does the
  same on demand. Every load re-registers the hot keys and refreshes the status
  line, the tooltips and the Quit button. Deleting or moving the file away
  keeps the configuration and reports the read failure until the file is back;
  upstream's watcher says nothing about a deleted file and reports it only on
  `reload-config`.
- **Modes.** `--source`, `--demo`, `--demo-probe`, `--demo-probe-guard` and the
  owned-resize modes read no config, reject `--config` and `--super`, and keep
  the fixed controls they were validated with (in `--demo`: Option-drag pan,
  Command-wheel zoom, Control-Option-drag move, and the Control-Option view and
  bookmark chords).

### Modifiers and `--super`

| DriftWM | macOS |
| --- | --- |
| `ctrl` | Control ⌃ |
| `alt` | Option ⌥ |
| `shift` | Shift ⇧ |
| `super`, and `mod` while `mod_key = "super"` (the default) | the super chord: Control-Option ⌃⌥ unless `--super` says otherwise |
| `mod3` | none; such a binding is skipped with a warning |

`--super CHORD` picks the super chord at launch: a `+`-joined subset of `ctrl`,
`alt` and `cmd`. `--super cmd` gives upstream-literal chords (`mod+a` is ⌘A,
`mod+ctrl+Right` is ⌃⌘→), which takes ⌘A, ⌘W, ⌘Z, ⌘0 to ⌘4 and others away from
every application while the canvas is open. A chord the controller rejects is
reported in the status line and the default stays.

A binding that holds super together with a modifier the super chord already
contains would be indistinguishable from the binding without it, so that
modifier is displaced: `ctrl` becomes Command and `alt` becomes Command-Shift.
With the default chord `mod+ctrl+Right` is ⌃⌥⌘→ and `mod+alt+Right` is ⌃⌥⇧⌘→.
When the super chord itself contains Command there is nowhere to displace to and
the binding is skipped with a warning. Two bindings that land on one physical
chord are settled by upstream combo text: the first in sorted order keeps the
chord and the other is reported.

A binding on a character is registered on the key that types that character in
the current keyboard layout (unshifted, or with Shift for a binding that holds
Shift), and resolved again when the input source changes: `mod+z` is the key
labelled Z on QWERTZ and on AZERTY alike. Upstream matches the active layout's
keysym first in the same way. When no key types the character,
`[input.keyboard] layout_independent = true` (upstream's default) falls back to
the key's US ANSI position, where upstream falls back to another configured
layout's Latin keysym; with `false` the binding is left out and the status line
says so. A key the layout resolves takes its chord before one that fell back.
Media keys
(volume, brightness, play) are not Carbon hot keys and are not registered, so
the Mac's own handling of them is untouched.

### Default key bindings as registered

With no config file and the default super chord. Hot keys are global and exist
only while a canvas panel is open; `--windowed` registers none.

| Chord | DriftWM binding | Action |
| --- | --- | --- |
| ⌃⌥A | `mod+a` | `home-toggle` |
| ⌃⌥W | `mod+w` | `zoom-to-fit` |
| ⌃⌥= / ⌃⌥- | `mod+equal` / `mod+minus` | `zoom-in` / `zoom-out` (repeat) |
| ⌃⌥0, ⌃⌥Z | `mod+0`, `mod+z` | `zoom-reset` |
| ⌃⌥⌘ arrows | `mod+ctrl+<arrow>` | `pan-viewport <direction>` (repeat) |
| ⌃⌥⇧ arrows | `mod+shift+<arrow>` | `nudge-window <direction>` (repeat) |
| ⌃⌥ arrows | `mod+<arrow>` | `center-nearest <direction>` |
| ⌃⌥C | `mod+c` | `center-window` |
| ⌃⌥X | `mod+x` | `focus-center` |
| ⌥Tab / ⌥⇧Tab | `alt+Tab` / `alt+shift+Tab` | `cycle-windows forward` / `backward` (repeat) |
| ⌃⌥1 to ⌃⌥4 | `mod+1` to `mod+4` | `go-to-bookmark 1` to `4` |
| ⌃⌥⇧1 to ⌃⌥⇧4 | `mod+shift+1` to `mod+shift+4` | `set-bookmark 1` to `4` |
| ⌃⌥Return | `mod+return` | `exec-terminal`: `$TERMINAL`, else `open -a Terminal "$HOME"` |
| ⌃⌥D | `mod+d` | `exec-launcher`: `$LAUNCHER`, else `open -a Apps` |
| ⌃⌥L | `mod+l` | `spawn swaylock -f -c 000000 -kl` (repeat) |
| ⌃⌥⇧⌘Q | `mod+ctrl+shift+q` | `quit` |
| ⌃⌥Esc | none (the shell's own) | exit, until a binding takes the chord |

Those are 34 of upstream's 57 default key bindings. ⌥Tab and ⌥⇧Tab are taken
from every application while a canvas panel is open; rebind or unbind
`cycle-windows` in the config file to give them back. The rest are not
registered, so their chords stay with the applications:

- 11 whose action does not run on macOS yet: ⌃⌥⇧⌘ arrows (`send-to-output`),
  ⌃⌥Q (`close-window`), ⌃⌥E (`toggle-cursor-pan`), ⌃⌥F (`toggle-fullscreen`),
  ⌃⌥M and ⌃⌥⇧M (`fit-window`, `fit-window-snapped`), ⌃⌥⇧W
  (`zoom-to-fit-snapped`) and ⌃⌥T (`toggle-pin-to-screen`). Bound in a config
  file they are skipped the same way, without a message; `Infinify msg action`
  answers the not-implemented error for each.
- 8 on media keys (volume, mute, brightness, play, next, previous), and 4 on
  keys a Mac keyboard lacks (`Print`, `shift+Print`, `XF86AudioPause`,
  `XF86AudioStop`).

Upstream's default commands are Linux programs and are passed through
unchanged: ⌃⌥L is registered and runs `swaylock`, which `sh` will not find on a
Mac. Rebind it (for example `"mod+l" = "exec pmset displaysleepnow"`) or remove
it (`"mod+l" = "none"`).

**Key repeat.** A held hot key whose action upstream marks repeatable
(`zoom-in`, `zoom-out`, `pan-viewport`, `nudge-window`, `cycle-windows` and
`spawn` among those that run) fires again after `[input.keyboard] repeat_delay` (200 ms) and then
`repeat_rate` (25) times a second. It stops when the key is released, when
another hot key is pressed, when the chord's modifiers are let go, and on Return
to desktop or quit. A held `spawn` binding therefore starts its command again
on every repeat, as upstream's does.

### Default mouse bindings as dispatched

Every left, right, middle and other button press and every scroll first asks
the controller for the binding of the physical modifiers held, in the `window`
context when the pointer is over a window (placeholders included) and the
`canvas` context otherwise. Upstream's precedence applies: the pointer's own
context before `anywhere`.

| Press or scroll | On a window | On empty canvas |
| --- | --- | --- |
| left click or drag | focuses the window, then the application's | pan (`left`); released within 5 points, unfocus |
| two-finger scroll | the application's | pan (`trackpad-scroll`) |
| mouse wheel | the application's | zoom (`wheel-scroll`) |
| ⌥ left drag | move the logical window (`alt+left`) | nothing |
| ⌥⇧ left drag | move its cluster (`alt+shift+left`) | nothing |
| ⌥ / ⌥⇧ right drag | `resize-window` / `resize-window-snapped`: only with `--experimental-native-resize`, else a status note | nothing |
| ⌥ / ⌥⇧ / ⌃⌥ middle | `fit-window` / `fit-window-snapped` / `toggle-fullscreen`: not implemented, the status line says so | nothing |
| ⌃⌥ left drag | pan (`mod+left`) | pan |
| ⌃⌥ two-finger scroll / wheel | pan / zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | pan / zoom |
| ⌃⌥⌘ left drag | `center-nearest` by pointer swipe: not implemented, a status note (the keyboard action runs) | the same |
| anything else | the application's; a press focuses the window first | nothing |

A resize binding picks its edges from the pointer's place in the window, a 3×3 grid whose centre resizes from the
bottom right, as upstream's resize grab does. A mouse binding that names an
action first focuses the window under the pointer, a placeholder included, then
runs the action. A press bound to move or resize a window does not focus it,
where upstream's does. After a
two-finger scroll has panned, scrolls stay with the canvas for 150 ms even if a
window slides under the pointer, as upstream. One gesture runs at a time: a
second button pressed during a gesture is ignored. Upstream's `wheel-up` and
`wheel-down` triggers are parsed but never fire, and the grammar has no name for
the back and forward buttons. Pinch is not a mouse binding and is unchanged.

### Settings

Applied now:

| Config | Effect |
| --- | --- |
| `mod_key`, `[keybindings]`, `[mouse.*]`, `[bindings] disable_defaults` | the hot keys registered and the pointer dispatch above |
| `[input.keyboard] repeat_delay`, `repeat_rate`, `layout_independent` | key repeat and key lookup |
| `[navigation] pan_step`, `nudge_step`, `camera_speed` | `pan-viewport`, `nudge-window`, the speed of every camera flight |
| `[navigation] anchors` | points `zoom-to-fit` frames together with the windows, and that `center-nearest` can land on (focus is then cleared) |
| `[navigation] auto_navigate_on_click` | off by default; on, a completed click (released within 5 points of the press) on a window that is not wholly in view also flies the camera to it, when the button comes up |
| `[zoom] reset_on_activation` | on by default: a canvas window focused in its own application, or by `msg focus`, is flown to at 1:1 when it is clipped; off keeps the zoom |
| the `cycle-windows forward` binding's modifiers | the modifiers that hold a cycle open (upstream's `cycle_hold`): Option by default |
| `[navigation.bookmarks]` | the bookmarks every launch starts from |
| `[navigation] trackpad_speed` | multiplies a bound two-finger scroll pan (1.5 by default) |
| `[zoom] step`, `fit_padding` | `zoom-in` / `zoom-out`, `zoom-to-fit` and the zoom-out limit |
| `[zoom] step`, `mouse_speed` | a bound wheel zooms by `step ^ (lines / 2 × mouse_speed)` |
| `[snap] enabled`, `gap`, `distance`, `break_force`, `corners`, `centers` | the logical window drag and its cluster |
| `[snap] outer_gap`, `focus_placement`, `[[outputs]] focus_placement` | where window navigation parks a window; an `[[outputs]]` entry is matched by display UUID, `windowed`, or `*` |
| `[session] restore_camera`, `restore_bookmarks` | what a restart restores, see [Persistence](#persistence-and-lifecycle) |
| `[env]` | the environment of commands run by `exec`, `spawn`, `exec-terminal` and `exec-launcher` |

`exec` and `spawn` run their command as `/bin/sh -c`, detached in a session of
their own with standard input and output on `/dev/null`; the app never waits for
it. Upstream's Wayland toolkit variables (`QT_QPA_PLATFORM` and four others) are
left out of that environment unless `[env]` sets them.

Read and validated by upstream's parser, then unused because the feature does
not exist here: `[navigation] mouse_speed` (a drag pans 1:1), `[zoom]
trackpad_speed` (pinch is unscaled), `focus_follows_mouse`, `window_placement`,
`autostart`, `[session] suspend_on_close` and `restore_windows`, `[navigation]
resize_step`, `drift`, `touch_speed`, `auto_navigate_on_close` and `edge_pan`,
`[zoom] touch_speed`, `reset_on_new_window` and `interact_min`, keyboard layout and lock
keys, `[input.trackpad]`, `[input.mouse]`, `[input.touch]`, `[input.tablet]`,
`[cursor]` (theme and size reach only the environment of a run command),
`[background]`, `[decorations]`, `[effects]`, `[backend]`,
`[output]`, the rest of `[[outputs]]`, `[[window_rules]]`, `[gestures.*]`,
`[touch.*]`, `[mouse] resize_on_border` and the decoration settings, and
tap-modifier bindings (a bare `alt+shift`), which are reported and skipped.

### Removed fixed gestures

Normal runs no longer have Option-drag or Option-scroll pan, Command-scroll
zoom, or Control-Option-drag move with Shift for the cluster. Their DriftWM
equivalents are in the tables above: Control-Option-drag or -scroll pans,
Control-Option-wheel zooms, Option-drag moves a window. Two more things changed
with them: a mouse wheel on empty canvas now zooms where every scroll there
used to pan, and a two-finger scroll pans 1.5 times the finger's travel
(`navigation.trackpad_speed`) where it used to pan 1:1. Control-Option-click on
a detached placeholder survives only while no binding claims it (see Controls).

### What has been run

`crates/desktop/tests/config_flow.rs` drives the controller side through the
exported C ABI. On 2026-10-09 the built app (ad-hoc signed, macOS 27.2, Apple
Silicon) was also launched twice as `--windowed 1100x700` with its own
`--state`, `--config` and `--socket` on a seeded scene of three detached
placeholders and driven through `Infinify msg`; nothing from those runs is
saved as evidence. Observed there, each read back over the socket:

- no config file: bookmarks `1` to `4` at the four corners, `pan-viewport right`
  moving the camera 100 points, `zoom-in` from 0.5 landing on 0.55, and
  `zoom-to-fit` on 0.2848… (padding 80);
- the file then created by rename, with no restart and no request: the bookmark
  list became the file's single `desk`, the pan step 250, `zoom-in` from 0.4
  landing on 0.6 (`step = 1.5`), `zoom-to-fit` 0.3212… (`fit_padding = 20`),
  and `go-to-bookmark desk` landed on its point;
- the file edited in place (pan step 60 applied, and the warning for a `mod3`
  binding on stderr), then `reload-config` printing that warning again;
- a file with a syntax error: upstream's TOML message on stderr, the previous
  pan step and bookmarks still in force, the app still answering;
- the file, now with `restore_bookmarks = true`, moved away and 0.8 s later
  moved back unchanged, after bookmarks `1`, `desk` and `here` had been set at
  runtime: upstream's `config: failed to read …: No such file or directory (os
  error 2)` on stderr from the watch and again from `reload-config`, the pan
  step still 250 while the file was gone, and the three bookmarks unchanged in
  the registry and in the scene file before, during and after;
- `nudge-window right` moving the focused placeholder 40 points with
  `nudge_step = 40`, and `up-left` 28 on each axis;
- `spawn touch FILE` creating the file, and an `exec` whose command wrote its
  environment showing the `[env]` variable and none of the Wayland toolkit
  ones;
- `unknown action: frobnicate` and `action not implemented on macOS yet:
  close-window`, each with exit status 1; SIGTERM exiting 0 with the socket
  removed;
- a second launch on the scene that run saved, with no config file: the camera
  at a new output's pose (`msg camera` 550 -318, where the file held the view
  centred on 520 -360), the four corner bookmarks instead of the file's three,
  and a bookmark set at runtime left out of the save, which carried the file's
  three forward.

Not run at all: hot key registration and delivery, key repeat, any pointer
press, drag or scroll (the dispatch table above is what the controller answers
to the lookups the shell sends at each config load, as logged from a scratch
build of the same sources; no real press, drag or scroll was made), right and
middle button delivery to an application, key lookup inside the app on a
non-US layout or after an input-source change (the lookup code alone was linked
into a scratch harness and pointed at the installed US, British, German, French,
Dvorak and Russian layout tables, registering nothing),
`--super` with any value, `exec-terminal` and `exec-launcher`, the status line,
tooltips and anything else drawn, the default config path, and every one of
these with a bound source or more than one display.

## Persistence and lifecycle

The default scene file is
`~/Library/Application Support/Infinify/scene.json`. `--state /absolute/file.json`
selects another file whose parent directory already exists. Saves use the Rust
controller's private temporary file, fsync, atomic rename, and directory sync.
Only world geometry, display UUID cameras, bookmarks and app/title metadata are
persisted; PIDs, window IDs, process births, and captures are not saved. Bookmarks
are an additive field of the same file and the format version is unchanged: scene
files written by older builds still load, with no bookmarks. Older builds reject
fields they do not know, so an older build cannot read a scene file that contains
bookmarks; keep a copy of a scene file before opening it with an older build.
A bookmark change or window move made over the IPC socket below is saved the same
way. What a restart brings back follows DriftWM's `[session]` settings, whose
defaults are both off. With `restore_camera = false` every display starts as a
new one does, its top-left corner on the world origin at zoom 1, instead of at
its saved camera (cameras are still written, and a display that reconnects
during a run keeps the camera it had). With
`restore_bookmarks = false` the bookmarks start from the config's seeds alone,
bookmarks set at runtime last until quit, and a save carries the file's earlier
bookmarks forward untouched; set it to `true` to have runtime bookmarks saved
and laid over the seeds at launch. On a config reload a bookmark the file adds
or changes is re-asserted, one it removes is dropped, and the others keep their
runtime value. Home and Fit return positions are per display, in memory only: not saved, and
dropped on reload, on Return to desktop, and whenever a display change recreates
the panels. Reloaded windows are unbound placeholders. A chooser selection is
always required to rebind; there is no PID or title guess. A failed load blocks
source selection and disables every save path, preserving the original bytes until
an explicit different state path or repaired file is provided. Display changes
recreate panels while retaining cameras by stable display UUID. Source lifecycle and normal bounds are polled on the
main event loop; ScreenCaptureKit buffers independently report pixel dimensions.

## Scripting (IPC)

A normal run listens on a Unix-domain socket, and `Infinify msg` is the macOS
counterpart of `driftwm msg`: upstream's requests and JSON shapes (one JSON line
out, one back), with the arguments after `msg` mirroring upstream's CLI.

```sh
APP=./target/app/Infinify.app/Contents/MacOS/Infinify
$APP msg state
$APP msg --json camera 500 300
$APP msg action zoom-to-fit
$APP msg bookmark inbox 500 300
```

`msg` runs before AppKit starts, so it opens no window and asks for no permission.
It prints a readable reply, or the reply as JSON with `--json`. An error reply or
a failed connection prints `error: …` on stderr and exits 1; with `--json` an
error reply is printed as JSON on stdout instead, still with status 1, as upstream
does. A usage error exits 2. `--json` and `--socket` may go before or after the
command (upstream takes them before it); command options such as `--id N` go
after it.

The default socket is `~/Library/Application Support/Infinify/infinify.sock`. The
app's `--socket PATH` flag moves it; the path must be absolute. `--state` does not
move the socket, so a second instance on its own scene file needs its own
`--socket` as well. `msg` looks for `--socket PATH`, then the `INFINIFY_SOCKET`
environment variable, then the default; the app itself does not read
`INFINIFY_SOCKET`. The socket's parent directory must exist, be owned by you and
not be group- or world-writable, the socket is mode 0600, and a peer with another
user ID is hung up on. A request is one line of at most 64 KiB (a longer one is
hung up on without a reply), at most 16 connections are served at once, and one
that completes no request for 30 seconds is closed. A stale socket file is removed
only after connecting to it fails. Nothing serializes that check and the bind
between instances, so two started on one path at the same moment can both find it
stale, and the later one then replaces the earlier one's socket; give instances
their own paths rather than rely on the check. If another running Infinify
answers, or the
path is unusable (longer than 103 bytes, a directory that fails the checks above,
a file that is not a socket), this app keeps running without IPC and says so in
its status line and on stderr rather than taking the socket over. The socket is
removed on quit. The server runs in normal runs only, never in `--source`,
`--demo`, `--demo-probe`, `--demo-probe-guard` or owned-resize modes. As
upstream's does, the socket is a full control surface (`msg action quit` quits the
app), guarded only by those checks.

Coordinates follow DriftWM, not the scene file: camera, window and bookmark
positions are canvas points with Y up (larger Y is higher). A camera position is
the centre of the view (the output below the toolbar strip), a window position the
centre of its frame in whole points, and a bookmark the point under the centre of
the view's usable area. The app registers no usable area yet, so that is the whole
view and a bookmark set at a view equals its camera position. The controller's own
world is top-left, Y-down, and the controller converts. A window is selected by
`--id N`, the Infinify window id that `state` prints, or by a case-insensitive
part of its bundle identifier, where a window with a bound source wins over a
detached placeholder. Requests act on the active output: the one under the
pointer, else the one of the panel under the pointer, else the first. Before the
canvas first opens there is none: `camera`, `zoom`, setting `focus` and the view,
window and bookmark actions (`pan-viewport`, `home-toggle`, the zoom actions,
`center-window`, `center-nearest`, `cycle-windows`, `focus-center`,
`go-to-bookmark`, `set-bookmark`) answer `no active output`, and everything else
answers as it always does: `state`, `bookmark`, `move`, `debug-counters`, reading
`focus` or `resize`, `action quit`, and the unknown and not-implemented replies.
After Return to desktop every request answers `the
canvas is closed`, after a failed scene load the load error, and while an
experimental native resize is unresolved `a native resize is pending`.

| Command | What it does now |
| --- | --- |
| `state` | Camera, zoom, windows (id, bundle id as `app_id`, title, centre position, size, `suspended` for a detached placeholder), outputs (stable id as `name`, `active`) and the active bookmark. `layout`, `fullscreen`, `pinned` and the layer lists are always empty. |
| `camera [X Y]` | Read the view centre, or fly the camera there at the current zoom. |
| `zoom [LEVEL]` | Read the zoom, or animate to a level about the view centre. The level is clamped to the range the zoom shortcuts use and the reply is the level applied. |
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source (at the current zoom with `[zoom] reset_on_activation = false`), at the current zoom for a detached placeholder. For a window with a bound source the app also performs the controller's focus request on the native window when native focus is allowed (see [Window navigation and native focus](#window-navigation-and-native-focus)); that has not been run. |
| `move [X Y] [--id N]` | Read a window's centre, or move the logical window there (whole points). The native window is not touched. A move is refused while a gesture is active, and when it would put the frame outside the 32-bit integer range every other request reads positions in. |
| `resize [WIDTH HEIGHT] [--id N]` | Read the size only. Setting one answers an error: native layout resize is not available yet. |
| `action SPEC...` | Run an upstream action string, below. |
| `bookmark [NAME] [X Y] [--delete]` | List bookmarks, get or set one, or delete it. |
| `debug-counters` | A small map of controller collection sizes; the keys are Infinify's own and not stable. |

`layout`, `opacity`, `pin`, `close`, `suspend`, `relaunch`, `screenshot` and
`subscribe` answer `<name> is not implemented on macOS yet`.

`action` parses the full upstream action grammar with upstream's spelling: it
is the grammar the config file's bindings use. These run:
`pan-viewport <direction>`, `home-toggle`, `zoom-in`, `zoom-out`, `zoom-reset`,
`zoom-to-fit`, `center-window`, `center-nearest <direction>`,
`cycle-windows forward|backward`, `focus-center`, `go-to-bookmark NAME`,
`set-bookmark NAME`, `nudge-window <direction>`, `exec COMMAND`, `spawn COMMAND`,
`exec-terminal`, `exec-launcher`, `reload-config` and `quit`. Over the socket
`cycle-windows` is always one committed step, where upstream keeps the cycle
open if a modifier happens to be down, and `focus-center` uses the real pointer's
position at that moment. Every action but `cycle-windows` first ends a cycle in
progress, as upstream's does. `exec` and `spawn` make the app run
the command through `/bin/sh -c`, so the socket lets any process of yours that
can write to it run a command, as upstream's does. Every other upstream action
parses and answers `action not implemented on
macOS yet: …`; a string upstream does not parse answers upstream's own message,
such as `unknown action: …` or `unknown direction: …`. Upstream replies Ok to any
spec that parses; Infinify reports the not-implemented case instead.
`go-to-bookmark` with a name that is not set answers Ok and does nothing, as
upstream's does.

On the socket itself the members of a reply object arrive in alphabetical order,
not upstream's declaration order; `msg --json` prints upstream's order. The app
re-encodes each request line before the controller decodes it, so a raw client
can send a whole-valued float where upstream requires an integer (`100.0` for
`100` in `move`) and have it accepted, and a line holding a number such as `1e999`
answers a bare `invalid request`. `msg` sends neither. Requests
that move a camera start a flight and answer at once: poll `camera` or `zoom` to
see it land. A pointer press or pinch on the canvas, or a scroll that pans or
zooms it, stops a scripted flight where it is, like any other. A client must wait for its reply: a
connection whose peer has already closed when the server accepts it is dropped
unread, where upstream would still run the request.

Status: automated coverage is controller scenarios through the exported C ABI/JSON
path. On 2026-10-09 the built app was also driven by a script over a private
socket in `--windowed` mode on a seeded scene of three detached placeholders
(macOS 27.2, Apple Silicon); nothing from those runs is saved as evidence.
Observed there through `Infinify msg` and the raw socket: `state`;
camera and zoom reads and writes landing on their targets (with the exceptions
below), the zoom clamp included; `zoom-in`, `zoom-out`, `zoom-reset`; `zoom-to-fit` to the pose that
frames the seeded windows and back; `home-toggle` there and back; `pan-viewport`;
bookmark set, get, list, delete, `set-bookmark` and `go-to-bookmark` with the
active bookmark in `state`; `move` by id, and a move past the integer range
refused with the scene still readable; `focus` by id and by bundle identifier
flying to an out-of-view placeholder with the zoom left at 0.5, and moving
nothing for one already in view; `zoom nan` and `camera inf 0` refused by `msg`;
the unknown, not-implemented and refused replies with their exit statuses; an
invalid line; `debug-counters`; `INFINIFY_SOCKET`; the socket's 0600 mode; a
stale socket replaced; a second instance on the same path left without IPC while
the first kept answering; bookmarks, the moved window, focus and the camera in
the scene file and after a restart; `msg action quit` and SIGTERM both answering,
exiting 0 and removing the socket. The last two runs were made after the review fixes
to `focus`, `move` and `msg`, and every flight in them landed; they did not repeat
the zoom clamp, `zoom-in`, `zoom-out`, `zoom-reset`, `INFINIFY_SOCKET`, the stale
socket, the restart or `msg action quit`, which stand as observed before those
fixes. Three flights in the earlier runs did not land
exactly: `camera 0 0` stopped short in one full run and in one of six short
launches, having landed in the first full run and the other five, and one flight
ended 0.31 points off in x alone. The machine's own pointer input reaching the
panel is the likely cause and was not confirmed. Not observed:
anything drawn (the panel, tiles, animation frames, the status line), the
toolbar, every shortcut and its status feedback, bound sources and so the focus
effect and the 1:1 focus flight, a multi-display active output, requests before the canvas opens or after
Return to desktop, the default socket path, the peer user check, and the
connection, line-length and idle limits against the app.

## Nested development window

`--windowed [WIDTHxHEIGHT]` (default 1200x800) is the macOS analogue of upstream's
nested winit backend. Instead of one full-screen floating panel per display it
opens the canvas immediately in one ordinary-level, non-activating panel with a
single output whose stable id is `windowed`. No global hot keys are registered, so
use the toolbar, the pointer and `Infinify msg`; the chooser is not shown at
launch but stays reachable from the toolbar. It is rejected in `--source`,
`--demo`, `--demo-probe`, `--demo-probe-guard` and owned-resize modes. It saves to
the default scene file, takes the default socket and reads the default config
file unless `--state`, `--socket` and `--config` say otherwise, so give a
development window its own when you also use Infinify normally. Pointer
bindings and settings from the config apply; key bindings are read but not
registered. A size must be at least 960x480 (the width that keeps the toolbar and
status line visible) and at most 16384 in each direction, or the app exits 64; the
panel is then clamped to the main display's visible area and centred on it. It is
the same borderless panel as the full-screen ones: it cannot be dragged, it closes
only through Return to desktop or Quit, and a display change rebuilds it. Window
navigation and native focus run here as in any normal run; with no hot keys,
cycling is the toolbar's Previous and Next or `msg action cycle-windows …`, one
committed step each.

Launched on 2026-10-09 as `--windowed 1100x700` with `--state`, `--config` and
`--socket`: `msg state` reported one output named `windowed` of 1100x636 (the
panel less its 64-point toolbar strip), and its camera was saved under that
name. The next launch, with no config file, did not restore it
(`session.restore_camera` is off by default) and started at a new output's
pose. The panel itself, its window level, the toolbar and the absence
of global hot keys were not inspected.

## Safe disposable demo and verification

```sh
./scripts/build-app.sh
mkdir /tmp/infinify-demo-unique
./target/app/Infinify.app/Contents/MacOS/Infinify --demo /tmp/infinify-demo-unique
./tests/e2e/desktop-app.sh --live-owned-fixture
```

Both demo modes accept only an empty evidence directory, launch their own
nonce-enrolled native AppKit child, and restrict the chooser to that exact PID.
Interactive demo stops after 60 seconds; the child has a 65-second deadline and
also exits when its parent exits. Automated probe requires existing grants,
never prompts, and writes all state into a fresh temporary directory. It blocks physical input to its test canvas and stops
scripted controls when foreground ownership changes or source events show any
untagged input, including before capture starts. Interrupted runs delete captured
screenshots. A second `--demo-probe-guard` regression injects an untagged click
only into its disposable source and verifies suppression and cleanup. Previous foreground is restored only if the fixture is still
foreground and the prior process is still the same running application.

The E2E drives the chooser selection and real capture pipeline, inspects exact
host-window screenshots for independently updating red/blue content in both
clipped views, changes the Rust cameras, sends scoped native button/text/scroll
input through the changed views, checks saved-state reload remains unbound,
and verifies stale-input rejection and cleanup. Text assertions use SHA-256 of
the fixture's actual native control contents. This proof uses two viewports in
one panel on the development machine; it does not claim physical multi-display
or arbitrary third-party app compatibility.

## Known limits

Native AX layout resizing is deliberately gated, not simulated by changing
world geometry. Hover, cross-boundary pointer capture, context-menu/popover
capture, native drag-and-drop, and application-specific floating child windows
are not implemented. Right and middle clicks are forwarded through the
per-window route but have never been delivered to a real application. Ordinary selected app activation
works with the tested native window in the fixture modes; a normal run's click
now focuses through the focus driver instead, which has not been exercised, and
choosing among multiple native windows of one application and app-specific
focus rules needs broader validation.
A held pointer drag cannot retarget another source. Only the last validated
in-window point receives a synthetic button-up if a pointer leaves its source; arbitrary outside-source drag delivery is not claimed.
Minimized/hidden/Space transitions, display hotplug, IME composition, the
registered exit hotkey and the view-action and bookmark shortcuts require manual
validation on the intended workstation. The view actions, bookmarks and IPC
requests have exported-C-ABI/JSON controller test coverage, and scripted `msg`
sessions against a running `--windowed` app (see Scripting above) that left no
saved evidence. Their rendered animation, toolbar buttons, global-shortcut
delivery and status feedback have not been verified on a live run, and neither
has IPC with bound sources or more than one display. The view actions omit upstream's fullscreen
interaction (Infinify has no fullscreen yet, so Home has no fullscreen-return
leg or pointer warp). Configuration covers key bindings, mouse bindings and the
settings listed under [Configuration](#configuration); hot key registration,
key repeat and every pointer binding are compiled and reviewed but have not
been exercised in a running app, and neither has a non-US keyboard layout.
Media keys, tap-modifier bindings, `wheel-up` / `wheel-down`, trackpad and
touch gestures, and every setting whose feature is absent are read and unused.
Eleven of upstream's default key bindings and four of its default mouse
bindings (three window actions and the pointer `center-nearest` swipe) do not
run here yet, and its two resize bindings need the experimental flag. Window
navigation and native focus have their own list of limits under
[Window navigation and native focus](#window-navigation-and-native-focus):
above all, native focus has never been exercised live, and a click reaches
the application before its window has native focus. Upstream's default `spawn`
commands are Linux programs. With the default bindings a detached placeholder
cannot be dismissed with the pointer.
The IPC surface is a subset of DriftWM's. Many upstream actions parse but are
not implemented; `layout`, `opacity`, `pin`, `close`, `suspend`, `relaunch`,
`screenshot` and `subscribe` are not implemented; `resize` is read-only. An IPC
focus is logical focus and camera navigation, plus a native focus request for a
window with a bound source that no run has yet performed, and
an IPC move is a logical world move that never moves the native window. Nested
`--windowed` mode registers no global shortcuts and has one output.
Cluster behavior uses the controller contract; fixture evidence currently has a
single source. Production chooser/managing of existing user windows has not been
run during development. Ad-hoc signing is local development packaging, not a
notarized distribution build. Private SkyLight input symbols can change with OS
updates; unavailable symbols leave live viewing functional and input disabled.

## Window navigation and native focus

Every normal run (the default launch and `--state`, with or without
`--windowed`) navigates between windows as DriftWM does and tries to give the
real window native focus. The fixture and child modes (`--source`, `--demo`,
`--demo-probe`, `--demo-probe-guard`, the owned-resize modes) have none of it
and keep their fixed click activation. The controller's rules are in
[NAVIGATION.md](../../crates/desktop/NAVIGATION.md#window-navigation-actions)
and [FOCUS.md](../../crates/desktop/FOCUS.md); this section says what the shell
does with them.

**Native focus (raising the real window) was not exercised live in this
milestone. It is compiled, reviewed and covered by the headless coordinator
regression only.** No hot key, toolbar button, click or Option release was
exercised live either;
[What has been run for navigation](#what-has-been-run-for-navigation) has the
exact boundary.

### Flags

- `--experimental-native-navigation` is still accepted and does nothing: what
  it used to gate is now the default. It is still rejected (exit 64) together
  with `--source`, `--demo-probe` and `--demo-probe-guard`, and no longer adds
  anything to `--demo`.
- `--no-native-focus` keeps focus logical: the shell activates no application
  and raises no window, for navigation or for a click, and installs no input
  observer. What a forwarded click makes the application do itself was not
  tried. Everything else in this section still happens. It is rejected (exit
  64) in the fixture and child modes and when given twice.

### Actions

| Control | Action | What it does |
| --- | --- | --- |
| ⌃⌥ arrow | `center-nearest <direction>` | Focuses the nearest window in a 90° cone and flies the camera to it at the current zoom. The search starts at the focused window while all of it is on the display, otherwise at the middle of the view. Detached placeholders are candidates, and so are `[navigation] anchors`: landing on an anchor flies the camera there and leaves no window focused. Nothing in the cone: nothing happens. |
| ⌃⌥C, toolbar Center | `center-window` | Flies to the focused window, or with none to the window nearest the middle of the view, and focuses it, at 1:1. |
| ⌃⌥X | `focus-center` | The same for the topmost window under the pointer; over empty canvas, nothing. |
| ⌥Tab / ⌥⇧Tab, toolbar Next / Previous | `cycle-windows forward` / `backward` | One step through the windows in most-recently-focused order, flown to at the current zoom. |

The chords are DriftWM's defaults under the default super chord; a config file
rebinds them like any other key. Center, Previous and Next are on the toolbar of
every normal run, `--windowed` included, and not in the fixture modes. Hot keys
act on the display under the pointer, toolbar buttons on their own display, and
every one of them goes through the same `action` command as
`Infinify msg action`, with the pointer's position and whether a modifier is
physically down added by the shell.

`center-window` is upstream's `RestoreFillElseReset`. Infinify has no fill
yet, so there is never a stored view to restore and the action always resets
the zoom to 1.

### Cycling and hold-to-commit

A `cycle-windows` hot key that fires while any of Control, Option, Shift or
Command is physically down opens a cycle that stays open: each further press
steps deeper into the order as it was when the cycle began. While it is open the
shell reads the session's modifier state 60 times a second
(`CGEventSourceFlagsState`, which needs no event tap and no Input Monitoring
grant), and at the first reading where the hold modifiers are no longer all
down it ends the cycle, which commits the selection to the front of the order.
The hold modifiers are upstream's `cycle_hold`: those of the
`cycle-windows forward` binding, Option by default. Upstream ends the cycle on
the key event of the release; sampling ends it up to 17 ms later.

A hot key step with no modifier down is committed at once, and so is every step
from the toolbar's Previous and Next and from `msg action cycle-windows …`,
which are never held. Any other action ends an open cycle first, committing it,
as upstream's does.

### Clicks

A press on a window that no mouse binding claims focuses that window first
(upstream's click-to-focus) and is then forwarded to the application as before.
"First" is the canvas's own focus: the window is the logical focus and raised
in the canvas before the press is forwarded. The native focus request is only
started by then. It runs on a worker, so the application receives the press
while that request is still in flight, not after its window has been made main
and raised. A detached placeholder is focused the same way and has nothing to
forward to.

With `[navigation] auto_navigate_on_click = true` a completed click on a window
that is not wholly in view also flies the camera to it at the current zoom, as
upstream does: when the button comes up, after the release has been forwarded,
and only if the pointer is within 5 points of where it went down, on the same
display, and the window still holds focus. The press itself never moves the
camera, so a drag that begins inside a clipped window reaches the application
as the drag it is. Upstream's extra wait after a title-bar click (so that a
double-click can still fit the window) does not exist here.

Any canvas press ends an open cycle the way letting go of its modifiers does: a
selection that has settled is committed, and a click on a window then puts that
window in front of it, as upstream does. A selection whose native focus is
still in flight is dropped with its request.

A press on empty canvas that is bound to pan and released within 5 points of
where it went down leaves no window focused; that is logical only, nothing is
asked of any application.

### What focusing does natively

Each of the above makes the window the logical focus and raises it in the
canvas at once. For a window with a bound source the controller also returns a
focus request, and the shell performs it when native focus is allowed: on a
serial worker the focus driver validates the window's identity (PID, process
birth, window id, current owner and unchanged bounds) against the binding the
controller named, activates its application, sets the window main and focused
through Accessibility, raises it, and reads back that exactly that window now
holds focus, all inside 1.5 seconds. Only that window is acted on; no other
application's window is raised, moved or resized. The result goes back to the
controller, and only a confirmed focus enters the most-recently-focused order;
a request the driver tried and failed cancels an open cycle.
A newer request, a canvas press, a scroll that pans or zooms the canvas, a
pinch, opening the chooser, adding, rebinding or losing a source, Return to
desktop and a display change all withdraw a request that is still in flight.

Native focus is allowed when Infinify has Accessibility access and
`--no-native-focus` was not given. Access is re-read twice a second, so a grant
made while the app runs should take effect without a restart (not tried).
Without it focus stays logical, all of the navigation above still works,
cycling included, and the status line and stderr say so once:
`Native window focus needs Accessibility access: focus is logical only;
navigation still works.`

When native focus is not allowed the focus driver is never asked. The shell
answers each of the controller's focus requests at once as logical
(`focus_logical`), which claims nothing about any native window: the window
enters the most-recently-focused order as it would under upstream, where
focusing is all there is, and a held cycle steps on and commits on release.
What is lost is only the native half: the real window is not activated or
raised, so keys still go to whichever application was frontmost.

Native focus does not depend on Input Monitoring. If that access has already
been granted (the app never asks for it), a listen-only observer of mouse
presses and scrolls is also installed: a press or scroll outside the canvas
panels while a focus request is in flight withdraws that request. It observes
no keys and nothing else depends on it.

### Native focus is followed

Twice a second, when Accessibility access exists, the shell reads which window
the frontmost application has focused. If that is a window on the canvas and
the canvas did not ask for it (Command-Tab, the Dock, an application raising
its own window), the canvas follows as upstream follows an activation request:
the window becomes the logical focus, is raised and moves to the front of the
most-recently-focused order; if it is clipped on the display that shows its
centre, that display's camera flies to it, at 1:1 unless `[zoom]
reset_on_activation = false`; a window already wholly visible there is left
where it is. If the frontmost window is not on the canvas, the canvas forgets
that a canvas window held native focus and drops an open cycle without
committing it; logical focus stays.

### Limits the owner will notice

- **What enters the cycle order.** With native focus allowed, the
  most-recently-focused order holds only windows whose native focus the driver
  confirmed or the shell observed: a window whose focus request fails, or is
  overtaken by the next one before it is confirmed, is not in it, where
  upstream would have put it there. Without native focus (no Accessibility
  access, or `--no-native-focus`) every window you focus on the canvas enters
  it. A detached placeholder is never in the order (upstream's stand-ins are
  not either), so a canvas of placeholders alone cannot be cycled.
- **A click reaches the application before its window has native focus.** The
  press is forwarded while the native focus request is still in flight. What an
  application does with a press that arrives while it is not yet active (take
  it as an activation click, for instance) has not been tried.
- Option-Tab and Option-Shift-Tab are global hot keys while a canvas panel is
  open: other applications do not receive them.
- A canvas press ends an open cycle at the press, on empty canvas too, where
  upstream ends it when another window takes focus or the modifiers are let go.
- Every click on a window with a bound source, including one inside the window
  that already has focus, runs the whole native focus sequence again.
- `auto_navigate_on_click` has no double-click deferral and no title-bar case:
  every completed click on a clipped window pans at once.
- A press bound to move or resize a window does not focus it, where upstream's
  does. The pointer form of `center-nearest` (upstream's ⌃⌥⌘-drag swipe) is not
  implemented; the status line says so.
- `focus_follows_mouse` and `auto_navigate_on_close` are read from the config
  and do nothing. Fullscreen, fit-window, pinned and modal windows do not exist
  here, so none of upstream's special cases for them apply.
- Following native focus moves the camera by itself when an application on the
  canvas takes focus while its window is clipped.
- If the controller refuses to follow a native focus change (a drag or resize
  is in progress), the focus is still recorded, the camera stays, and the
  refusal text shows in the status line.

### What has been run for navigation

Automated, no window and no native effect:
`crates/desktop/tests/navigation_actions_flow.rs` and the other controller
scenarios drive the actions, `activate`, `clear_focus` and the cycle rules
through the exported C ABI with synthetic identities and focus results, and
`./tests/e2e/desktop-navigation.sh` runs the real Objective-C coordinator
against the real Rust library with an injected focus driver, clock and
scheduler. The regression covers exact identities and binding generations,
held, reverse and release-pending cycles, the hold opened and ended by injected
modifier readings, a canvas press on a held cycle with its selection settled and
still in flight, unrelated input with and without a request in flight, a focus
request carried inside an action reply's `effects`, a request the controller
dropped, logical-only focus never reaching the driver while it enters the order
and a held cycle steps and commits on it, authorization, failure
and deadline, supersession, rejected commands, native focus followed through
`activate`, focus lost, two-output camera flights and their saved poses, and
teardown. It starts no NSApplication, window, hot key or event tap and focuses
nothing.

Live, on 2026-10-09 (ad-hoc signed build of this tree, macOS 27.2, Apple
Silicon): four launches as `--windowed 1100x700` with a private `--state`,
`--config` and `--socket`, on a seeded scene of three detached placeholders
(Notes 640x420 centred on 520,-360; Browser 900x600 on 1950,0; Terminal 560x380
on -620,-890, in `msg` coordinates), driven only through `Infinify msg` and
read back with `msg camera`, `msg zoom`, `msg focus` and `msg state` once each
flight had settled. Nothing from them is saved as evidence. Observed:

- `center-nearest right` with nothing focused, from the launch view (camera
  550 -318): focus on Browser, camera 1950 0;
- from there `left`: Notes, camera 520 -360; `down` and `up` from Notes with no
  anchors: nothing changed; `left`: Terminal, camera -620 -890; `up-right` from
  Terminal: Notes;
- `[navigation] anchors = [[520.0, -3000.0]]` written to the config file
  while running: `down` from Notes then landed on 520 -3000 with no window
  focused, `up` from there chose Terminal over Notes, as the scoring rule says
  (2305 against 2430), and `down` from Terminal went back to the anchor;
- with nothing focused and the view moved to 520 600, above Notes, `down`
  chose Notes; with Notes focused and the view moved to 520 -1500, so that
  Notes was off the display, `up` chose Notes, which only a search from the
  middle of the view finds;
- at zoom 0.5, `right` from Notes: Browser, zoom still 0.5;
- `center-window` with Terminal focused after `msg camera 2000 2000`: camera
  -620 -890, zoom 1; after `msg zoom 0.5` and `msg focus --id 2` (camera 1950 0,
  zoom still 0.5), `center-window` kept the camera and brought the zoom to 1;
  with focus cleared on the anchor at zoom 0.5, `center-window` chose
  Terminal, the window nearest the middle of the view, at zoom 1;
- `cycle-windows forward`, `forward`, `backward`: `ok` each time, and focus,
  camera and `msg state` were the same before and after, because no
  placeholder is ever in the order (the first limit above). `msg state` lists
  the focused window and then the stacking order, not the
  most-recently-focused order, so that order is not readable through `msg`;
- `center-nearest sideways` answered `unknown direction: sideways`, a bare
  `center-nearest` `center-nearest requires a direction`, a bare
  `cycle-windows` `cycle-windows requires forward or backward`, and
  `cycle-windows sideways` `cycle-windows: expected forward or backward, got
  'sideways'`, each with exit status 1;
- `focus-center` answered `ok` with the pointer wherever it happened to be and
  changed nothing; its effect was not established;
- a launch with `--experimental-native-navigation --no-native-focus` started,
  navigated and answered like the others;
- each launch exited 0 on SIGTERM with its socket removed, and the scene file
  read after the last held that run's focus, stacking order, camera and zoom.

No launch printed the missing-Accessibility note, so the session presumably
had Accessibility access and native focus was allowed in the three launches
without `--no-native-focus`; that was not checked separately. With no bound
source the controller produced no focus request, so neither the focus driver
nor the logical-only answer was reached, and no window on the canvas could be
found frontmost; nothing in the output shows any of those paths doing
anything.

Not run at all: native focus of a real window by any route; a window with a
bound source; any hot key, Option-Tab and the release that commits it; the
toolbar's Center, Previous and Next; any click, click-to-focus, the reveal at
a completed click's release, a press that ends a cycle, and the empty-canvas
unfocus; native focus being followed; the observer withdrawing a request; a
cycle that changes the order in the running app, with native focus or on
logical focus alone; the status note for missing Accessibility;
`auto_navigate_on_click` and `reset_on_activation` in the app; anything drawn;
more than one display.

## Experimental native resizing

`--experimental-native-resize` independently enables eight orange handles on the
selected ordinary source. Handles use true projected world edges; viewport clipping
does not invent resize edges. Shift/group resize is rejected. Default controls stay
unchanged. Escape requests cancellation (the global observer does not suppress the
native app's Escape); release ends the gesture. The OS must already permit event
observation; no permission prompt is requested. Global Escape observation remains
unproved on a live host.

`resize-coordinator.m` calls the real Rust JSON C ABI only on the main thread. Every
emitted adapter effect is registered before its serial worker dispatch, matched to
the controller's current pending effect, and reconciled on main even after cancel,
output removal, or quit. Duplicate dispatch is rejected for the coordinator lifetime.
There is no second motion queue. Setter timeout uncertainty retains the source;
unknown geometry, temporary CG absence, or stream failure never attests lifetime end.
Chooser/load/detach/return require the controller's structural guard to permit them.
Quit drains every dispatched call without a timeout-based destruction deadline, then
saves committed geometry; unresolved uncertainty is reported, not rolled back or
reported successful. An OS call that stalls leaves shutdown visibly pending.

The native driver reuses `native/families/window-server-family.h`: read-only yabai
MIT-derived WindowServer queries at commit
`dd845723416f5fe92af49fad5ebab00369e07edd`, with `YABAI-NOTICE.txt` copied into the app.
Unknown ancestry, children, foreign association, and unmapped extent are unsupported.
A fresh root-only guard is checked immediately before AX size mutation. Its veto is
an adapter policy refusal, not evidence about AX resize capability. Original adapter
results, including actual AX/CG rectangles and timeout flags, pass through unchanged.

Managed capture never unconditionally enqueues frames. Initial binding explicitly
invalidates capture authority. Acceptance requires exact stream/source/generation/
revision, complete typed metadata, a strictly newer WindowServer mach display time
than the main-thread observation cutoff and last displayed frame, real CV buffer
dimensions, a bounded pixel crop derived from contentRect and scaleFactor, and
screenRect plus content extent matching a freshly verified root-only native frame.
Missing metadata has no arrival-time, frame-count, or configuration-callback fallback.
The same sample acknowledged by the C ABI is installed. Placement and input mappings
include content padding; input native coordinates remain native geometry. Lost
mapping immediately removes every existing surface and clears retained frames. The
last accepted sample is retained with its revision for newly visible placements of
static sources; a new layer that cannot install it remains inert. Generic geometry
polling is disabled for managed sources; the capture gate reconciles fresh idle
geometry only when the controller permits structural changes, then requires a
post-observation frame. Active or uncertain transactions retain exclusive ownership. A half-second read-only
validation tick also checks roots independently of frame arrival; input delivery
performs the same validation. Newly observed loss after recovery advances the token
even when no frame has restored capture authority.

A revision change requests updated stream dimensions after the cutoff; its callback
is never proof of fresh pixels. Whether static native applications reliably emit a
new Complete frame after this request is **unproved**. Strict metadata checks may
leave a tile inert. Metadata proves geometric freshness, not semantic layout or
pixel correctness; current screenRect coordinate assumptions require live validation.

`tests/e2e/desktop-resize.sh` exercises the production coordinator, Rust C ABI, and
real synthetic CVPixelBuffer/CMSampleBuffer objects without NSApplication startup or
any native windows, AX calls, capture streams, activation, event taps, or fixtures.
This is headless contract evidence only. The signed app is built without launching.
The existing independent resize fixture does **not** prove this integration. A future
explicitly authorized owned-fixture gate must cross real handles, AX mutation, SCK,
renderer pixels, independent AX/CG observation, clamp behavior, static-frame refresh,
Escape handling, and cleanup. No such integrated live proof has been run or claimed.

## Prepared noninteractive owned resize gate — runtime UNRUN

`tests/e2e/desktop-native-resize.sh` defaults to building the signed app, reading
pre-AppKit help, the existing headless resize integration, and 66 offline PNG
oracle CLI regressions. It creates no windows, starts no capture, makes no AX
calls, and registers no input observers. Its success proves preparation only.

After an explicitly authorized desktop test interval, select one bounded case:

```sh
./tests/e2e/desktop-native-resize.sh --live-owned-fixture --scenario right-shrink
```

The native internal entry point is `--owned-resize-probe EMPTY_DIRECTORY [SCENARIO]`.
Only this entry point spawns/enrolls its exact nonce/PID/kernel-birth/window fixture;
there is no arbitrary PID/window option. `--owned-resize-fixture` validates its
actual parent identity and lease before AppKit startup. The foreground PID and
kernel birth are captured **before** NSApplication initialization and rechecked
after startup and before every window order. Startup self-activation fails; it
never becomes an accepted baseline. A fresh isolated scene is used. The chooser attaches the exact SCK source. The runner selects that source through the real
controller focus command without dispatching its returned native-focus effect;
this establishes logical selection only. It verifies the focused source, settled
placement, actual rendered handle layer and converted pointer/output before calling
the gesture path. Receipts record those checks and the resulting gesture/transaction.
The runner calls the real
DesktopView mouseDown/Dragged/Up at a real projected orange handle. Normal input
forwarding is disabled only for this internal mode, so a vanished handle cannot
fall through to activation. Production capture policies and reconfiguration are
unchanged. A driver lease composes with the existing root-only check immediately
before AXSize. Its hooks are frozen before dispatch; native results pass through
unchanged and are drained during shutdown.

Cases are `EDGE-grow`, `EDGE-shrink`, and `EDGE-clamp` for `top_left`, `top`,
`top_right`, `right`, `bottom_right`, `bottom`, `bottom_left`, and `left`; also
`static`, `family`, `sigint`, `sigterm`, and `controller-death`. Default is one
right-shrink case. `--scenario matrix` explicitly requests all cases and stops on
the first failure. Each controller has a 23-second work deadline and each fixture
an independent 25-second lifetime. Synchronous OS-call stalls cannot be forcibly
bounded safely: a stalled controller is terminated and, after a four-second drain grace, killed
and reaped as an explicitly failed run. SIGKILL is also used for the selected
controller-death case, never as fixture restoration proof.

The fixture is deliberately a **borderless resizable AppKit window** with real
min/max constraints, a same-title decoy, and (for `family`) a real attached child.
It does not override AX setters. Unsupported exact AX identity or AXSize fails;
it does not widen the scope or claim ordinary titled/third-party compatibility.
Before publishing readiness, it preserves both original created frames and spends
at most two seconds servicing the event loop while observing exact CG IDs/owners,
process birth and matching original top-coordinate bounds. No transform is queried
until both windows are registered. Two consecutive registered observations,
separated by an event pump, must have identical finite transforms; any subsequent
registered change, unknown transform, changed geometry or interference fails and
closes only the owned windows. Missing registration remains pending, never a usable
baseline. The observation sequence is retained in `fixture-readiness.json`.
The first registered transform candidates are frozen once: there is no rebase on
change or after readiness. Before chooser use, the controller independently confirms
that the current transform and AX/CG geometry equal this published baseline.
It draws once and invalidates only when actual content bounds resize: fixed
24-point markers on opposite edges and six 36-point saturated tiles wrap at a
400-point content width. No animation or manual redraw during capture waiting
makes static refresh appear successful. Two actual AV render surfaces use .6 and
.9 cameras; independent AX/CG rectangles plus fixed layout/output constants drive
the external saved-byte PNG oracle. Native origin movement is recorded honestly;
world opposite-edge anchoring and unchanged cameras are separate assertions.
Controller crop metadata and fixture child frames are not oracle inputs.

This mode is exclusively a **noninteractive owned layout/capture probe**. Its
root, decoy, child and chooser use a dedicated NSWindow subclass that refuses key
and main status and sets ignoresMouseEvents before any ordering or child attachment.
Its host panel has the same contract plus the nonactivating style. A dedicated
NSApplication is installed from startup and rejects unexpected queued pointer,
button, drag, scroll, keyboard, flags, gesture, tablet and unknown events before
normal dispatch, atomically latching failure. Framework housekeeping alone passes;
passive MouseEntered, MouseExited and CursorUpdate notifications are discarded
before dispatch without latching failure or clearing any existing latch. MouseMoved
and all actionable or unknown events still latch failure. There is no event-tag
exemption. Scripted DesktopView calls bypass the event queue. All owned-window
exclusion contracts are checked before capture and mutation. Diagnostics preserve
the first failing window's class, ID, visibility and mouse/key/main exclusion flags;
unknown windows remain forbidden except an enumeration-only AppKit auxiliary:
the exact class NSLocalWindowSharingWindow, hidden, unable to become key/main
and currently neither key nor main. ID -1 is accepted before registration; a
positive ID additionally requires an exact current CG row owned by this process,
its unchanged birth identity and explicit CG onscreen=false. Missing facts fail.
The first validated positive ID is frozen per object; later ID changes, including
returning to -1, fail. Every scan rechecks those conditions and records actual CG
facts separately from the first helper failure. This observed-state exception
does not establish the private class's purpose or compatibility on other OS builds.
The probe never alters that helper. Direct owned-window checks and before-order checks retain their strict
mouse exclusion requirement. No window titles or human text are recorded.

Every setter checks the exact owned identity, unchanged read-only transform,
recognized geometry, deadline, foreground identity, fresh fixture exclusion state,
and sticky input-exclusion status. The same foreground application's unrelated
input is allowed: this mode does not query global HID inactivity or require an
input-observation grant. Switching foreground apps still aborts, and unexpected
actionable or unknown input delivered to the probe is dropped and permanently
aborts the session.
Owned mode registers neither the global Escape monitor, the exit hotkey nor the
view-action shortcuts, and its toolbar has no view-action buttons; use
the supervisor's SIGINT or the bounded deadline. Visible chooser buttons are inert
in this probe, and the host toolbar explicitly labels the noninteractive mode.
Other desktop/demo modes retain their existing controls. This does not prove physical-input handling or ordinary
application compatibility. Source and host screenshots are only of enrolled owned windows and are deleted after
interruption. No global event posting, foreground activation/restoration, transform
setter, permission prompt, SIP or settings change is used. The fixture watchdog
runs in common and event-tracking modes, checks exact parent birth, reconciles only
recognized pending resize intent, and skips restoration after unknown/human state.
It closes only its own windows and writes an honest receipt. Normal and signal restoration
are independently checked through AX/CG while the fixture remains alive. On
controller death, the fixture holds its restored window for at most two seconds so
the surviving supervisor can independently read AX/CG and transform before
acknowledging closure. A missed hold or missing readback is restoration-unproved
and fails; a fixture receipt plus disappearance alone cannot pass cleanup.

`resize-live.py` records exact source hashes including the `.inc.m` inputs and
runs `resize-verify.py` only after native-path completion. Abnormal/family scenarios
never claim pixel/layout proof; missing scenarios are not marked passed. No
successful live result has been frozen for this integration. Startup/preflight,
AX enrollment, per-guard conditions, first contamination, and restoration evidence
record separate booleans, exact owned bounds and initial/current transforms; no
human text is recorded. A transform failure does not silently replace the initial
baseline. The new noninteractive path remains runtime-unrun. Full native resizing
parity, reliable
static SCK refresh, real desktop interruption handling, and third-party support
remain **unrun and incomplete**.
