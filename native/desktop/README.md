# Infinify native desktop shell

`./scripts/build-app.sh` builds and ad-hoc signs `target/app/Infinify.app` for
Apple Silicon / macOS 26+. The build does not launch anything. Open the app to
choose ordinary local application windows. No window is automatically selected.
Screen Recording permission is required for capture; Accessibility permission
is required for native input. The chooser explains a missing grant and offers an
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
  (Control-Option). The status line shows the pointer, view, pan and bookmark
  chords the running app resolved, and each toolbar tooltip its own action's;
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
  actions move cameras only; they never move, resize, focus or otherwise touch
  native windows. If macOS refuses a hot key the status line names it and the
  toolbar still works. The Quit button and Control-Option-Escape call the
  shell's quit directly instead of sending the `quit` action, so exit never
  depends on the controller or on an active output. Control-Option-Escape stays
  the exit chord unless a config binding resolves to that chord, which then
  takes it. DriftWM's own `quit` binding, `mod+ctrl+shift+q`, is
  Control-Option-Command-Shift-Q. The experimental navigation and resize
  controls below keep their own gates.
- Option-drag on a window: move the logical world window, using Rust snapping
  and hysteresis with the `[snap]` settings. Add Shift to move its connected
  cluster. Control-Option-Shift with an arrow key (`nudge-window <direction>`)
  moves the focused logical window by `navigation.nudge_step` world points.
  Neither moves a native window.
- An unbound click, drag or scroll on a window is forwarded through Rust inverse
  hit mapping to the selected native source. With DriftWM's defaults that is
  every unmodified one, with the left, right or middle button. The original
  application owns keyboard focus, text editing, shortcuts, and IME; the overlay
  does not emulate a text field. Right and middle buttons travel the same
  validated per-window route as the left one, down, drag and up. Whether real
  applications accept them there has not been tried, and a context menu, if one
  opens, opens at the native window's real screen position, not in the canvas.
  An unbound press on empty canvas does nothing, as upstream.
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

A normal source click requests activation only for its freshly validated owning
application. Identity validation checks PID, process birth, window number, current
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
| ⌃⌥1 to ⌃⌥4 | `mod+1` to `mod+4` | `go-to-bookmark 1` to `4` |
| ⌃⌥⇧1 to ⌃⌥⇧4 | `mod+shift+1` to `mod+shift+4` | `set-bookmark 1` to `4` |
| ⌃⌥Return | `mod+return` | `exec-terminal`: `$TERMINAL`, else `open -a Terminal "$HOME"` |
| ⌃⌥D | `mod+d` | `exec-launcher`: `$LAUNCHER`, else `open -a Apps` |
| ⌃⌥L | `mod+l` | `spawn swaylock -f -c 000000 -kl` (repeat) |
| ⌃⌥⇧⌘Q | `mod+ctrl+shift+q` | `quit` |
| ⌃⌥Esc | none (the shell's own) | exit, until a binding takes the chord |

Those are 26 of upstream's 57 default key bindings. The rest are not
registered, so their chords stay with the applications:

- 19 whose action does not run on macOS yet: ⌥Tab and ⌥⇧Tab (`cycle-windows`),
  ⌃⌥ arrows (`center-nearest`), ⌃⌥⇧⌘ arrows (`send-to-output`), ⌃⌥Q
  (`close-window`), ⌃⌥C (`center-window`), ⌃⌥X (`focus-center`), ⌃⌥E
  (`toggle-cursor-pan`), ⌃⌥F (`toggle-fullscreen`), ⌃⌥M and ⌃⌥⇧M (`fit-window`,
  `fit-window-snapped`), ⌃⌥⇧W (`zoom-to-fit-snapped`) and ⌃⌥T
  (`toggle-pin-to-screen`). Bound in a config file they are skipped the same
  way, without a message; `Infinify msg action` answers the not-implemented
  error for each.
- 8 on media keys (volume, mute, brightness, play, next, previous), and 4 on
  keys a Mac keyboard lacks (`Print`, `shift+Print`, `XF86AudioPause`,
  `XF86AudioStop`).

Upstream's default commands are Linux programs and are passed through
unchanged: ⌃⌥L is registered and runs `swaylock`, which `sh` will not find on a
Mac. Rebind it (for example `"mod+l" = "exec pmset displaysleepnow"`) or remove
it (`"mod+l" = "none"`). With `--experimental-native-navigation`, ⌥Tab and ⌥⇧Tab
belong to that feature: a binding on either is skipped and the status line says
so once after each load.

**Key repeat.** A held hot key whose action upstream marks repeatable
(`zoom-in`, `zoom-out`, `pan-viewport`, `nudge-window` and `spawn` among those
that run) fires again after `[input.keyboard] repeat_delay` (200 ms) and then
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
| left drag | the application's | pan (`left`) |
| two-finger scroll | the application's | pan (`trackpad-scroll`) |
| mouse wheel | the application's | zoom (`wheel-scroll`) |
| ⌥ left drag | move the logical window (`alt+left`) | nothing |
| ⌥⇧ left drag | move its cluster (`alt+shift+left`) | nothing |
| ⌥ / ⌥⇧ right drag | `resize-window` / `resize-window-snapped`: only with `--experimental-native-resize`, else a status note | nothing |
| ⌥ / ⌥⇧ / ⌃⌥ middle | `fit-window` / `fit-window-snapped` / `toggle-fullscreen`: not implemented, the status line says so | nothing |
| ⌃⌥ left drag | pan (`mod+left`) | pan |
| ⌃⌥ two-finger scroll / wheel | pan / zoom (`mod+trackpad-scroll`, `mod+wheel-scroll`) | pan / zoom |
| ⌃⌥⌘ left drag | `center-nearest`: not implemented, a status note | the same |
| anything else | the application's | nothing |

A resize binding picks its edges from the pointer's place in the window, a 3×3 grid whose centre resizes from the
bottom right, as upstream's resize grab does. A mouse binding that names an
action first focuses the window under the pointer, then runs the action. After a
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
| `[navigation] anchors` | points `zoom-to-fit` frames together with the windows |
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
resize_step`, `drift`, `touch_speed`, `auto_navigate_on_*` and `edge_pan`,
`[zoom] touch_speed`, `reset_on_*` and `interact_min`, keyboard layout and lock
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
canvas first opens there is none: `camera`, `zoom`, setting `focus` and the view
and bookmark actions (`pan-viewport`, `home-toggle`, the zoom actions,
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
| `focus [APP_ID] [--id N]` | Read the focused window. Setting makes a window the logical focus and, unless it is already wholly in view, flies the camera to it as upstream does: at 1:1 for a window with a bound source, at the current zoom for a detached placeholder. Native application focus does not change: the app does not perform the focus request the controller returns. |
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
`zoom-to-fit`, `go-to-bookmark NAME`, `set-bookmark NAME`,
`nudge-window <direction>`, `exec COMMAND`, `spawn COMMAND`, `exec-terminal`,
`exec-launcher`, `reload-config` and `quit`. `exec` and `spawn` make the app run
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
only through Return to desktop or Quit, and a display change rebuilds it. With
`--experimental-native-navigation` the Option-Tab hot keys are not registered, but
that flag's listen-only input observer still is.

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
works with the tested native window, but choosing among multiple native windows
of one application and app-specific focus rules needs broader validation.
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
Nineteen of upstream's default key bindings and four of its default mouse
bindings (three window actions and `center-nearest`) do not run here yet, and
its two resize bindings need the experimental flag. Upstream's default `spawn`
commands are Linux programs. With the default bindings a detached placeholder
cannot be dismissed with the pointer.
The IPC surface is a subset of DriftWM's. Most upstream actions parse but are
not implemented; `layout`, `opacity`, `pin`, `close`, `suspend`, `relaunch`,
`screenshot` and `subscribe` are not implemented; `resize` is read-only. An IPC
focus is logical focus and camera navigation only and changes no native focus, and
an IPC move is a logical world move that never moves the native window. Nested
`--windowed` mode registers no global shortcuts and has one output.
Cluster behavior uses the controller contract; fixture evidence currently has a
single source. Production chooser/managing of existing user windows has not been
run during development. Ad-hoc signing is local development packaging, not a
notarized distribution build. Private SkyLight input symbols can change with OS
updates; unavailable symbols leave live viewing functional and input disabled.

## Experimental native navigation

`--experimental-native-navigation` opts into the native navigation integration.
It can accompany `--state /absolute/file.json` or the interactive `--demo DIR`;
probe and internal child modes reject it. The default click/activation path is
unchanged. This flag is an experimental runtime authorization for explicitly
selected sources, not evidence of third-party compatibility.

The gated toolbar adds **Center selected**, **Previous**, and **Next**. Center
uses the controller's `navigate_window` with reset zoom; this does not claim the
complete upstream `CenterWindow` action. Previous/Next use unheld cycles. Toolbar
navigation resolves the toolbar's display; shortcuts resolve the pointer's
output. A multi-output demo toolbar requires the pointer inside an output.
No arbitrary first display is selected. Already-reserved toolbar space is not
subtracted a second time.

Option-Tab and Option-Shift-Tab use Carbon hotkeys only while the experimental
panels are open. A listen-only event observer tracks the accepted keypress,
actual Option release, and human interruption. Delayed Carbon delivery after
release is unheld; delivery after cancellation is rejected. Canceled presses
remain as tombstones so an old callback cannot borrow a later press; each panel
lifecycle uses fresh hotkey IDs. Excessive queued presses fail closed; reopening
panels resets the queue. Actual native event ordering still requires live validation. Failed registration
leaves the buttons available. A missing or disabled input observer disables
native focus dispatch, including button focus, while camera navigation remains
available. No event-suppression fallback or permission prompt is used.

Only these explicit navigation actions dispatch native focus effects. A serial
worker receives immutable effect/identity/generation tickets, bounded deadlines,
and cancellation epochs. Ownership, unchanged native bounds, and foreground
process birth are checked without entering the controller from the worker.
Workspace activation notifications permanently invalidate a lease after a
foreign foreground transition. Success requires independent exact-window
readback from the focus adapter. Mouse, keyboard and other human intent cancel
pending focus work and the held cycle before the legacy pointer path; clicks are
never saved for later replay. Observed input does not stop camera flights: a
pointer press, scroll or pinch on a canvas stops them, as in the default app,
and so does the system disabling the observer. Detach, rebind, chooser, screen
changes, cleanup, and shutdown invalidate work, camera flights included, before
teardown. Unsupported non-null owner authority fails closed rather than being
silently discarded.

Coalesced bounded observation runs at most once per half second on the same
serial worker. Expected confirmations use `focus_result`, duplicate confirmed
observations do nothing, independently validated external focus ends cycling,
and failed/unknown readback does not claim focus loss. A single common-mode
60 Hz main-thread timer advances all active camera flights and renders once per
frame; idle polling keeps the clock current and completed flights save once.
The default app runs the same timer for view-action flights without this flag,
ticking the controller directly on the same clock. With the flag the coordinator
ticks them, and they stop on the same input as without it: the observer's
cancellation above is limited to focus work, so a shortcut's own key release,
pointer movement, or a click outside a canvas leaves a flight flying. View
actions combined with this flag are unrun.
The navigation flag does not enable resizing; resizing has a separate experimental flag.

`./tests/e2e/desktop-navigation.sh` runs the real Objective-C coordinator and
input-order policy against the actual Rust C ABI with injected nonmutating
focus, clock, and scheduling. It covers exact identities, binding generations,
held/reverse/release-pending cycles, supersession, rejected commands, teardown,
observation reconciliation, pointer cancellation, focus-only cancellation that
leaves a camera flight armed, two-output intermediate camera poses, and saved
final poses. It starts no NSApplication, windows, fixture,
capture, hotkeys, or event taps. The app build and this test are integration
checks only. Live native focus, multiple windows of one app, third-party apps,
physical displays, shortcut delivery, foreground notifications, and input-tap
behavior remain unrun and unproven for this path.

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
