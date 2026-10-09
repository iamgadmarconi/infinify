# Configuration, ABI 1

The controller is configured by one TOML file in DriftWM's own grammar. The
parser, the defaults, the action grammar and the binding tables are upstream's
code, carried in `driftwm-core` (malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d`, `src/config/`); nothing here
re-implements them. What is new is the map from upstream's modifiers and keysyms
to a Mac keyboard, and four additive ABI 1 commands. Existing commands, their
shapes, `ABI_VERSION` and `SAVE_VERSION` are unchanged.

| `command.op` | Fields | Result data |
| --- | --- | --- |
| `load_config` | `path` string or `null` | `{path, exists, errors, warnings, dirty}` |
| `set_platform` | `super`: a `+`-joined subset of `ctrl`, `alt`, `cmd` | `{super}` in canonical order |
| `bindings` | none | key bindings as macOS chords, see [Key bindings](#key-bindings) |
| `mouse_binding` | `trigger`, `source`, `modifiers`, `context` | `{binding}`, see [Mouse bindings](#mouse-bindings) |

The controller reads the file and nothing else: it registers no hot key,
watches no directory and runs no command. The shell does those.

## The file

`load_config` with `path: null` uses upstream's own path logic:
`$XDG_CONFIG_HOME/infinify/config.toml`, else `~/.config/infinify/config.toml`.
The directory name is the `driftwm-core` constant `CONFIG_DIR_NAME`; upstream's
is `driftwm`. Upstream's `DRIFTWM_CONFIG` environment override is kept by that
code and wins over both.

- A **missing file** is not an error while no file has been accepted in this
  run: the built-in defaults apply, `exists` is false, and `errors` and
  `warnings` are empty. This is upstream's startup.
- A file that **cannot be read or parsed** leaves the configuration that was in
  force untouched. `errors` holds upstream's one message,
  `config: failed to read <path>: <io error>` or `config error: <toml error>`.
  On the first load of a run that configuration is the built-in defaults, which
  is what upstream's startup falls back to as well.
- A file that **goes missing after one was accepted** is such a read failure,
  as in upstream's reload: `exists` is false, `errors` holds
  `config: failed to read <path>: No such file or directory (os error 2)`, the
  configuration and the bookmark registry stay as they are, and `dirty` is
  false.
- An accepted file replaces the configuration whole. `warnings` are upstream's
  own value warnings, verbatim and in upstream's order (rejected values before
  corrected ones), for example
  `config: navigation.camera_speed 0 must be in (0, 1] (0 freezes the camera), using 0.3`.
- `dirty` is true when the reload changed the bookmark registry and the shell
  should save.

Files larger than 4 MiB are refused as unreadable. That bound is not upstream's.

The first `load_config` of a controller is its **launch**. Until then the
controller is unconfigured and behaves exactly as it did before configuration
existed: nothing is seeded from the config, a scene file restores its bookmarks
and cameras, and `set_navigation_context` supplies placement, speed and gap.
Modes of the shell that never send `load_config` keep that behaviour. The
settings below still read the built-in defaults in that state, which equal the
constants they replaced.

## Applied now

| Config | Effect here |
| --- | --- |
| `mod_key` | which modifier `mod` means in every binding |
| `[keybindings]`, `[bindings] disable_defaults = ["keys"]` | the `bindings` reply |
| `[mouse.on-window]`, `[mouse.on-canvas]`, `[mouse.anywhere]`, `disable_defaults = ["mouse"]` | the `mouse_binding` reply |
| `[input.keyboard] repeat_delay`, `repeat_rate`, `layout_independent` | reported by `bindings` for the shell's key repeat and key lookup |
| `[navigation] pan_step` | `pan-viewport`, `pan_viewport` |
| `[navigation] nudge_step` | `nudge-window` |
| `[navigation] camera_speed` | every `tick_navigation` |
| `[navigation] anchors` | `zoom-to-fit` fits them with the windows, as upstream's `ZoomToFit` does |
| `[navigation.bookmarks]` | seeds of the bookmark registry, see [Session](#session) |
| `[navigation] trackpad_speed`; `[zoom] mouse_speed` | reported with each pointer binding and by `bindings`; the shell scales a bound scroll pan and a bound wheel zoom by them |
| `[zoom] step` | `zoom-in`, `zoom-out`; reported to the shell for wheel zoom |
| `[zoom] fit_padding` | `zoom-to-fit`, and the dynamic minimum zoom |
| `[snap] enabled`, `gap`, `distance`, `break_force`, `corners`, `centers` | `begin_drag`, `begin_resize`, `gesture_to` and the native resize transaction's snap intent |
| `[snap] outer_gap` | the inset of a placed window in window navigation |
| `focus_placement`, `[[outputs]] focus_placement` | where window navigation parks the window |
| `[session] restore_camera`, `restore_bookmarks` | what `load` restores, see [Session](#session) |
| `[env]`, `[cursor] theme`, `size` | the environment of an `exec` effect |

Once a config is loaded, `focus_placement`, `navigation.camera_speed` and
`snap.outer_gap` supersede the `focus_placement`, `camera_speed` and `outer_gap`
of `set_navigation_context`; only its `usable_rect_local` is still taken. An
`[[outputs]]` entry is matched by the output's `stable_id` (or `name = "*"`),
where upstream matches a connector name.

`snap.enabled = false` is a zero snap distance: nothing docks, and a group drag
still finds its cluster through `snap.gap`. Snap distances are measured between
edges and divided by the current zoom on each update, as before.

## Read, not applied yet

Everything else in the file is parsed, validated and warned about by upstream's
code, and then unused, because the feature it configures does not exist here:

- `focus_follows_mouse`, `window_placement`, `autostart`, `[xwayland]`
- `[session] suspend_on_close`, `restore_windows` (the scene always saves and
  restores its placeholders)
- `[navigation] mouse_speed` and `[zoom] trackpad_speed`: reported with each
  pointer binding and by `bindings`, but the shell's drag pan follows the
  pointer 1:1 and its pinch is unscaled
- `[navigation] resize_step`, `drift`, `touch_speed`, `auto_navigate_on_close`,
  `auto_navigate_on_click`, `[navigation.edge_pan]`
- `[zoom] touch_speed`, `reset_on_new_window`, `reset_on_activation`,
  `interact_min`
- `[input.keyboard] layout`, `variant`, `options`, `model`,
  `remember_layout_per_window`, `num_lock`, `caps_lock`; `[input.trackpad]`,
  `[input.mouse]`, `[input.touch]`, `[input.tablet]`
- `[cursor] inactive_opacity` (theme and size reach only the `exec` environment)
- `[background]`, `[decorations]`, `[effects]`, `[backend]`, `[output]`
- `[[outputs]]` other than `focus_placement`; `[[window_rules]]`, including
  `pass_keys` and `pass_mouse`
- `[gestures.*]`, `[touch.*]`, and their thresholds
- `[mouse] resize_on_border`, `decoration_resize_snapped`, `decoration_fit_snapped`
- the mouse triggers `wheel-up` and `wheel-down`: `mouse_binding` has no notch
  direction, so a binding on one is never returned
- tap-modifier bindings (a bare `alt+shift`): reported and skipped, see below

## macOS modifiers

Upstream's modifiers are `ctrl`, `alt`, `shift`, `logo` (written `super` or
`logo`, and `mod` when `mod_key = "super"`, upstream's default) and `mod3`.

| Upstream | macOS |
| --- | --- |
| `ctrl` | Control ⌃ |
| `alt` | Option ⌥ |
| `shift` | Shift ⇧ |
| `logo` | the **super chord**: Control+Option ⌃⌥ by default |
| `mod3` | none; the binding is skipped with a warning |

`set_platform` chooses another super chord, any non-empty subset of `ctrl`,
`alt` and `cmd`. `{"super":"cmd"}` makes upstream's chords literal with ⌘ as
super. The chord is not part of the config file and is not saved.

**Displacement.** A binding that holds `logo` and also names a modifier the
super chord already contains would be indistinguishable from the binding
without it, so that modifier is re-expressed: displaced `ctrl` becomes Command,
displaced `alt` becomes Command+Shift. With the default chord `mod+ctrl+Right`
is ⌃⌥⌘→ and `mod+alt+Right` is ⌃⌥⇧⌘→. When the chord itself contains Command
there is nothing left to displace to, and the binding is skipped with a warning.

**Collisions.** The map is not one to one: under the default chord `mod+alt+X`,
`mod+ctrl+shift+X` and `mod+alt+shift+X` are all ⌃⌥⇧⌘X, and `ctrl+alt+X` is
`mod+X`. Upstream's binding table is unordered, so bindings are sorted by their
upstream combo text (bytewise): the first one on a chord keeps it, every later
one is skipped and named in `warnings` together with the winner. Upstream's
defaults do not collide under ⌃⌥, under ⌘, or with `mod_key = "alt"`.

**Reserved.** Control+Option+Escape is the shell's exit chord. `bindings`
reports it under `reserved` with `claimed_by`: the combo of a binding that maps
to it, or null. A binding that claims it is registered like any other.

## Key identity

Each registrable keysym has a US ANSI virtual key code (HIToolbox `kVK_*`) and,
when it types a character, that character:

- letters, digits and the unshifted ANSI punctuation (`equal`, `minus`,
  `bracketleft`, `bracketright`, `apostrophe`, `semicolon`, `backslash`,
  `comma`, `slash`, `period`, `grave`) carry `character`;
- `Return`, `Tab`, `space`, `Escape`, `BackSpace` (the Mac Delete key),
  `Delete` (Forward Delete), `Home`, `End`, `Page_Up`, `Page_Down`, the arrows,
  `F1` to `F20`, `Help`, `Insert` (the Help key), `Menu`, the keypad digits and
  operators, `KP_Enter`, `Clear` and `Num_Lock` (the keypad Clear key) carry
  `character: null`.

Upstream always matches a binding against the active layout's keysym first
(`src/input/keyboard.rs`: `modified_sym`, then `Config::lookup`).
`layout_independent = true`, **upstream's default**, only adds a fallback for a
key whose own keysym found no binding. So in both modes the shell registers a
binding on the key that types `character` in the current keyboard layout:
unshifted, or with Shift for a binding that holds Shift. When no key types it,
the binding falls back to `key_code`, the US ANSI position, if the flag is true,
and is left out with a note if it is false. A key the layout resolves takes its
chord before any that fell back. The controller reports both and the flag; the
lookup is the shell's.

Media keys are not virtual key codes and cannot be Carbon hot keys. Bindings on
`XF86AudioRaiseVolume`, `XF86AudioLowerVolume`, `XF86AudioMute`,
`XF86MonBrightnessUp`, `XF86MonBrightnessDown`, `XF86AudioPlay`,
`XF86AudioNext`, `XF86AudioPrev`, `XF86AudioForward`, `XF86AudioRewind`,
`XF86KbdBrightnessUp`, `XF86KbdBrightnessDown`, `XF86KbdLightOnOff` and
`XF86Eject` are listed apart, under `media_keys`, with their IOKit
`NX_KEYTYPE_*` as `nx_key_type` and no `key_code`.

Not bindable: a symbol that needs Shift or a non-US layout (`plus`,
`udiaeresis`), `Print`, `Scroll_Lock`, `Pause`, `XF86AudioPause`,
`XF86AudioStop`, and every other keysym. A binding on one is listed under
`skipped`. It is also a warning, unless it is one of upstream's own defaults,
which the user did not ask for.

## Key bindings

```json
{"keys":[{"key_code":0,"character":"a","modifiers":{"control":true,"option":true,"shift":false,"command":false},
          "action":"home-toggle","combo":"mod+a","chord":"⌃⌥A","repeat":false,"implemented":true}],
 "media_keys":[{"nx_key_type":0,"modifiers":{…},"action":"spawn …","combo":"XF86AudioRaiseVolume","chord":"…","repeat":true,"implemented":true}],
 "skipped":[{"combo":"Print","action":"spawn grim - | wl-copy","reason":"the key has no macOS equivalent"}],
 "reserved":[{"purpose":"exit","key_code":53,"modifiers":{…},"claimed_by":null}],
 "layout_independent":true,"repeat_delay_ms":200,"repeat_rate_hz":25,"super":"ctrl+alt",
 "settings":{"trackpad_speed":1.5,"mouse_speed":1.0,"zoom_step":1.1,"zoom_mouse_speed":1.0,"zoom_trackpad_speed":1.0},
 "warnings":[]}
```

- `keys` is sorted by `combo`. `key_code` is always a number.
- `action` is the canonical config string of the action: `parse_action` reads
  it back as the same action, and the `action` command accepts it.
- `repeat` is upstream's `Action::is_repeatable`: `zoom-in`, `zoom-out`,
  `nudge-window`, `grow-window`, `shrink-window`, `pan-viewport`,
  `cycle-windows` and `spawn` repeat while held, after `repeat_delay_ms` and
  then `repeat_rate_hz` times a second.
- `implemented` is false when the `action` command would refuse the action with
  `action not implemented on macOS yet: <name>`. The binding is listed all the
  same; registering its chord takes the chord from every app for nothing.
- `chord` is a display string: the modifiers as glyphs and the US key label.
- `settings` are the speeds a pointer gesture scales by, see below.
- `warnings` are this map's own, one per skipped binding the user should know
  about: `binding '<combo>' = '<action>' skipped: <reason>`.

The key table is private to `driftwm-core`, which this crate may not change, so
the bindings are found by asking `Config::lookup` for every known keysym under
each of the 32 modifier sets. A key named in the file's `[keybindings]` table
that the Mac key table lacks is added to that search, so its binding is reported
as skipped instead of vanishing.

### Upstream's defaults as registered

With no config file, the default super chord and `mod_key = "super"`. "Runs" is
`implemented`. Upstream binds 57 keys: 45 land on Mac keys, 8 on media keys, and
4 have no Mac key.

| Upstream | macOS chord | `key_code` | Action | Repeats | Runs |
| --- | --- | --- | --- | --- | --- |
| `alt+Tab` | ⌥Tab | 48 | `cycle-windows forward` | yes | no |
| `alt+shift+Tab` | ⌥⇧Tab | 48 | `cycle-windows backward` | yes | no |
| `mod+0` | ⌃⌥0 | 29 | `zoom-reset` |  | yes |
| `mod+1` | ⌃⌥1 | 18 | `go-to-bookmark 1` |  | yes |
| `mod+2` | ⌃⌥2 | 19 | `go-to-bookmark 2` |  | yes |
| `mod+3` | ⌃⌥3 | 20 | `go-to-bookmark 3` |  | yes |
| `mod+4` | ⌃⌥4 | 21 | `go-to-bookmark 4` |  | yes |
| `mod+Down` | ⌃⌥Down | 125 | `center-nearest down` |  | no |
| `mod+Left` | ⌃⌥Left | 123 | `center-nearest left` |  | no |
| `mod+Return` | ⌃⌥Return | 36 | `exec-terminal` |  | yes |
| `mod+Right` | ⌃⌥Right | 124 | `center-nearest right` |  | no |
| `mod+Up` | ⌃⌥Up | 126 | `center-nearest up` |  | no |
| `mod+a` | ⌃⌥A | 0 | `home-toggle` |  | yes |
| `mod+alt+Down` | ⌃⌥⇧⌘Down | 125 | `send-to-output down` |  | no |
| `mod+alt+Left` | ⌃⌥⇧⌘Left | 123 | `send-to-output left` |  | no |
| `mod+alt+Right` | ⌃⌥⇧⌘Right | 124 | `send-to-output right` |  | no |
| `mod+alt+Up` | ⌃⌥⇧⌘Up | 126 | `send-to-output up` |  | no |
| `mod+c` | ⌃⌥C | 8 | `center-window` |  | no |
| `mod+ctrl+Down` | ⌃⌥⌘Down | 125 | `pan-viewport down` | yes | yes |
| `mod+ctrl+Left` | ⌃⌥⌘Left | 123 | `pan-viewport left` | yes | yes |
| `mod+ctrl+Right` | ⌃⌥⌘Right | 124 | `pan-viewport right` | yes | yes |
| `mod+ctrl+Up` | ⌃⌥⌘Up | 126 | `pan-viewport up` | yes | yes |
| `mod+ctrl+shift+q` | ⌃⌥⇧⌘Q | 12 | `quit` |  | yes |
| `mod+d` | ⌃⌥D | 2 | `exec-launcher` |  | yes |
| `mod+e` | ⌃⌥E | 14 | `toggle-cursor-pan` |  | no |
| `mod+equal` | ⌃⌥= | 24 | `zoom-in` | yes | yes |
| `mod+f` | ⌃⌥F | 3 | `toggle-fullscreen` |  | no |
| `mod+l` | ⌃⌥L | 37 | `spawn swaylock -f -c 000000 -kl` | yes | yes |
| `mod+m` | ⌃⌥M | 46 | `fit-window` |  | no |
| `mod+minus` | ⌃⌥- | 27 | `zoom-out` | yes | yes |
| `mod+q` | ⌃⌥Q | 12 | `close-window` |  | no |
| `mod+shift+1` | ⌃⌥⇧1 | 18 | `set-bookmark 1` |  | yes |
| `mod+shift+2` | ⌃⌥⇧2 | 19 | `set-bookmark 2` |  | yes |
| `mod+shift+3` | ⌃⌥⇧3 | 20 | `set-bookmark 3` |  | yes |
| `mod+shift+4` | ⌃⌥⇧4 | 21 | `set-bookmark 4` |  | yes |
| `mod+shift+Down` | ⌃⌥⇧Down | 125 | `nudge-window down` | yes | yes |
| `mod+shift+Left` | ⌃⌥⇧Left | 123 | `nudge-window left` | yes | yes |
| `mod+shift+Right` | ⌃⌥⇧Right | 124 | `nudge-window right` | yes | yes |
| `mod+shift+Up` | ⌃⌥⇧Up | 126 | `nudge-window up` | yes | yes |
| `mod+shift+m` | ⌃⌥⇧M | 46 | `fit-window-snapped` |  | no |
| `mod+shift+w` | ⌃⌥⇧W | 13 | `zoom-to-fit-snapped` |  | no |
| `mod+t` | ⌃⌥T | 17 | `toggle-pin-to-screen` |  | no |
| `mod+w` | ⌃⌥W | 13 | `zoom-to-fit` |  | yes |
| `mod+x` | ⌃⌥X | 7 | `focus-center` |  | no |
| `mod+z` | ⌃⌥Z | 6 | `zoom-reset` |  | yes |

Under `{"super":"cmd"}` every ⌃⌥ above is ⌘, `mod+ctrl+…` is ⌃⌘…, `mod+alt+…`
is ⌥⌘… and `mod+ctrl+shift+q` is ⌃⇧⌘Q; nothing is displaced.

`media_keys`, listed and not registrable as hot keys:

| Upstream | `nx_key_type` | Action |
| --- | --- | --- |
| `XF86AudioLowerVolume` | 1 | `spawn wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-` |
| `XF86AudioMute` | 7 | `spawn wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle` |
| `XF86AudioNext` | 17 | `spawn playerctl next` |
| `XF86AudioPlay` | 16 | `spawn playerctl play-pause` |
| `XF86AudioPrev` | 18 | `spawn playerctl previous` |
| `XF86AudioRaiseVolume` | 0 | `spawn wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+` |
| `XF86MonBrightnessDown` | 3 | `spawn brightnessctl set 5%-` |
| `XF86MonBrightnessUp` | 2 | `spawn brightnessctl set +5%` |

`skipped`, with no Mac key: `Print` and `shift+Print` (`spawn grim …`),
`XF86AudioPause` (`spawn playerctl play-pause`) and `XF86AudioStop`
(`spawn playerctl stop`).

Upstream's default commands (`swaylock`, `wpctl`, `brightnessctl`, `playerctl`,
`grim`) are Linux programs. They are passed through unchanged; on a Mac the
shell's `sh -c` will not find them until the file rebinds those keys.

## Mouse bindings

```json
{"op":"mouse_binding","trigger":"left","source":null,
 "modifiers":{"control":true,"option":true,"shift":false,"command":false},"context":"window"}
```

- `trigger`: `left`, `right`, `middle`, `back`, `forward` or `scroll`.
  Upstream's grammar names only the first three buttons, so `back` and
  `forward` never have a binding.
- `source`, for `scroll`: `finger` is upstream's `trackpad-scroll`; `wheel`,
  `continuous` and `null` are `wheel-scroll`, as upstream treats every source
  that is not a finger.
- `modifiers`: the physical modifiers held. A missing member is not held.
- `context`: `window` when the pointer is over a window, else `canvas`.

The reply is `{"binding":null}` or

```json
{"binding":{"kind":"pan_viewport","action":null,"combo":"mod+left","implemented":null,
            "trackpad_speed":1.5,"mouse_speed":1.0,"zoom_step":1.1,"zoom_mouse_speed":1.0,"zoom_trackpad_speed":1.0}}
```

`kind` is `move_window`, `move_snapped_windows`, `resize_window`,
`resize_window_snapped`, `pan_viewport`, `zoom`, `center_nearest` or `action`.
For `action`, `action` is the canonical action string and `implemented` says
whether the `action` command runs it; otherwise both are null.

The lookup is upstream's: the physical chord is turned back into every upstream
modifier set that maps onto it (displacement included), and, as
`ContextBindings::lookup` prefers the pointer's own context table over
`anywhere`, all of those are tried in combo order in the pointer's own context
table before any is tried in `anywhere`. Two mouse bindings that land on one
physical chord are not reported: within one table the first in combo order
answers, and a binding in `anywhere` gives way to one in the pointer's own
table.

The five speeds are upstream `Config` fields by name. Upstream pans a scroll by
`trackpad_speed / zoom` and a drag by `mouse_speed`, zooms a wheel by
`zoom_step ^ (-v / 30 · zoom_mouse_speed)` clamped to the dynamic minimum, and
scales a pinch by `zoom_trackpad_speed`. Applying them is the shell's, which
uses `trackpad_speed`, `zoom_step` and `zoom_mouse_speed` and not yet
`mouse_speed` or `zoom_trackpad_speed`.

Upstream's defaults under the default super chord:

| Chord | On a window | On the canvas |
| --- | --- | --- |
| left drag | the app's | `pan_viewport` |
| ⌥ left | `move_window` | none |
| ⌥⇧ left | `move_snapped_windows` | none |
| ⌥ right | `resize_window` | none |
| ⌥⇧ right | `resize_window_snapped` | none |
| ⌥ middle | `action` `fit-window` (refused) | none |
| ⌥⇧ middle | `action` `fit-window-snapped` (refused) | none |
| ⌃⌥ middle | `action` `toggle-fullscreen` (refused) | none |
| ⌃⌥ left | `pan_viewport` | `pan_viewport` |
| ⌃⌥⌘ left (`mod+ctrl`) | `center_nearest` | `center_nearest` |
| finger scroll | the app's | `pan_viewport` |
| wheel scroll | the app's | `zoom` |
| ⌃⌥ finger scroll | `pan_viewport` | `pan_viewport` |
| ⌃⌥ wheel scroll | `zoom` | `zoom` |

## Actions that run now

`nudge-window <dir>` moves the focused window by `navigation.nudge_step` world
points along the unit vector, each axis rounded as upstream rounds it. It is a
logical world move, refused during a gesture or a live native resize and for a
destination outside the integer range, exactly as the IPC `Move` is. With no
focused window nothing happens and nothing is dirty, as upstream.

`exec <cmd>` and `spawn <cmd>` return the effect
`{"op":"exec","command":"<cmd>","env":{…}}`. Upstream's `spawn_command` runs
`sh -c <cmd>` with `Config::child_env`; the shell does the same, detached.

`exec-terminal` is `exec` of `$TERMINAL`, and `exec-launcher` of `$LAUNCHER`,
read from the controller's own environment, as upstream reads them. Upstream
then probes a list of Linux programs with `which` and falls back to `foot` and
`fuzzel`; here the fallbacks are `open -a Terminal "$HOME"` (a new Terminal
window) and `open -a Apps` (the macOS 26 application launcher).

`reload-config` returns the effect `{"op":"reload_config"}`: the shell sends
`load_config` again and re-reads `bindings`.

## Session

Upstream keeps bookmarks in a live registry seeded from the config, and reads
`session.restore_bookmarks` and `session.restore_camera` at launch.

- **Launch** (the first `load_config`): the registry becomes the config seeds.
  `[navigation.bookmarks]` absent means upstream's four corner seeds `1` to `4`;
  present and empty means none. With `restore_bookmarks` on, the scene file's
  registry is laid over the seeds, a saved value winning per name.
- **`load`** under a config does the same with the file it reads.
- **Reload** (every later `load_config`): upstream's seed diff. A name added or
  changed in the file is re-asserted, a name removed from the file is dropped,
  and a name the file did not touch keeps its runtime value.
- **`save`**: with `restore_bookmarks` on, the live registry is written. With it
  off runtime edits are ephemeral and the registry read from the scene file is
  carried forward untouched, so turning the flag on later loses nothing.
- **Cameras** are always saved. With `restore_camera` off (upstream's default)
  an output that connects starts at a new output's camera instead of the saved
  one; an output this session has already shown keeps its camera across a
  disconnect, and one that never connects keeps its saved camera in the file.

`load` and `load_config` may arrive in either order, and an output may even be
registered between them: the first config still decides, taking a camera that
was restored too early back to a new output's pose.

## Differences from upstream

- The shell's file watch also reloads when the file is deleted, so a file that
  goes missing after it was accepted reports the read failure at once.
  Upstream's watcher ignores a deleted file; only its `reload-config` reports
  it.
- A reload while no file has been accepted yet reports no error for a missing
  file, where upstream's `reload_config` reports a read failure. The built-in
  defaults stay in force either way.
- Key lookup. Upstream's `layout_independent = true` falls back to the key's
  Latin keysym, taken from another configured layout when the active one has
  none there; the shell falls back to the US ANSI position. A binding that
  holds Shift is found on the key that types its character with or without
  Shift in both modes; upstream's first lookup uses the keysym the key gives
  with Shift held, so `mod+shift+1` matches there only through the fallback
  that `true` adds.
- `zoom-in` with a `zoom.step` below 1 zooms out and stops at the scene's
  minimum zoom, 0.001. Upstream sets no lower bound there.
- An `exec` effect's `env` is upstream's `child_env` less its five Wayland
  toolkit fallbacks (`MOZ_ENABLE_WAYLAND`, `QT_QPA_PLATFORM`, `SDL_VIDEODRIVER`,
  `GDK_BACKEND`, `ELECTRON_OZONE_PLATFORM_HINT`), which would stop a Qt, SDL or
  GTK program from starting on macOS. One the file's own `[env]` sets is kept.
- `exec` does not reveal the cursor; upstream's does for a few seconds.
- `nudge-window` is applied at once; upstream animates the frame from its old
  place. It does not raise the window, and there is no fill restore point to
  clear.
- A new output's camera is the world origin at its top-left corner, as before;
  upstream centers the origin.
- Window placeholders are saved and restored whatever `restore_windows` says.
- `[navigation] anchors` join `zoom-to-fit` only. Upstream also uses them in
  `center-nearest`, which does not run here.
- A reload re-applies only what the table above lists. Upstream also rebuilds
  its keyboard layout, cursor theme, device settings, output rules and render
  caches, none of which exist here.

## Evidence and limits

`tests/config_flow.rs` drives the exported C ABI with config files in a
throwaway directory: the defaults without a file; files that change the pan
step, zoom step, fit padding, navigation anchors, each snap setting, camera
speed, focus placement, nudge step and bookmark seeds, each observed through the
command it governs; a `zoom.step` below 1 landing on the minimum zoom; broken
and unreadable files with upstream's messages; a file that vanishes after it
was accepted (the config and the runtime bookmarks kept, upstream's read
failure, nothing dirty) and a missing file loaded again before any was
accepted; the default key table (exact chords for a representative set, the 45 /
8 / 4 split, no collision, no warning, and every listed action executed or
refused according to `implemented`); `--super cmd`, a super chord holding
Command, `mod_key = "alt"` and `mod_key = "mod3"`; collisions with their
deterministic winner; one binding of every action through a config file and
back; upstream's default mouse bindings in both contexts with every scroll
source, and two bindings on one physical chord answered from the pointer's own
context table first; the new actions' effects; and both session flags in both orders of
`load` and `load_config`.

Those are controller scenarios. They are not evidence that a chord is registered
with macOS, that a key press, button or scroll reaches the shell, that a
character resolves through a keyboard layout, that an `exec` effect starts a
process, that the config file is watched, or that anything is drawn. The key
codes were read from the macOS SDK headers; none was pressed.

The shell's side is described in the
[shell notes](../../native/desktop/README.md#configuration). Their
[What has been run](../../native/desktop/README.md#what-has-been-run) lists a
scripted session against the built app on 2026-10-09 in which the file watch,
`reload-config`, a broken file, a file moved away and back, `nudge-window`,
`spawn` and `exec` were observed over the IPC socket, and names what stayed unrun: every hot key
and every pointer binding.
