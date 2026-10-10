# Configuration, ABI 1

The controller is configured by one TOML file in DriftWM's own grammar. The
parser, the defaults, the action grammar and the binding tables are upstream's
code, carried in `driftwm-core` (malbiruk/driftwm at
`352333a8fa1b22171492d4b71a54102045c9a19d`, `src/config/`); nothing here
re-implements them. What is new is the map from upstream's modifiers and keysyms
to a Mac keyboard, and six additive ABI 1 commands. Existing commands, their
shapes, `ABI_VERSION` and `SAVE_VERSION` are unchanged.

| `command.op` | Fields | Result data |
| --- | --- | --- |
| `load_config` | `path` string or `null` | `{path, exists, errors, warnings, dirty, effects, focus_follows_mouse}` |
| `set_platform` | `super`: a `+`-joined subset of `ctrl`, `alt`, `cmd` | `{super}` in canonical order |
| `bindings` | none | key bindings as macOS chords, see [Key bindings](#key-bindings) |
| `mouse_binding` | `trigger`, `source`, `modifiers`, `context`, optional `window`, optional `pick` | `{binding}`, or `{binding: null, passed: true}`, see [Mouse bindings](#mouse-bindings) |
| `hot_corner` | `output`, `corner`, optional `pointer`, `held` | `{navigation, effects, dirty}`, see [Hot corners](#hot-corners) |
| `layout_changed` | `name`, `short`, `index`, `count` | `{}`, see [Keyboard layouts](#keyboard-layouts) |

The controller reads the file, and looks on `PATH` for the programs its key
bindings run. It registers no hot key, watches no directory or pointer, selects
no input source and runs no command. The shell does those.

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
  is what upstream's startup falls back to as well, with one exception: those
  defaults do not decide the saved slots. While such a file is the only one
  the run has seen, `adoption_complete` drops no slot and makes no stand-in
  ([LIFECYCLE.md](LIFECYCLE.md#slots-and-re-adoption-the-macos-rule)); a typo
  elsewhere in the file must not cost what its `restore_windows` would keep.
- A file that **goes missing after one was accepted** is such a read failure,
  as in upstream's reload: `exists` is false, `errors` holds
  `config: failed to read <path>: No such file or directory (os error 2)`, the
  configuration and the bookmark registry stay as they are, and `dirty` is
  false.
- An accepted file replaces the configuration whole. `warnings` are upstream's
  own value warnings, verbatim and in upstream's order (rejected values before
  corrected ones), for example
  `config: navigation.camera_speed 0 must be in (0, 1] (0 freezes the camera), using 0.3`.
- `dirty` is true when the shell should save: the reload changed the bookmark
  registry, or it turned the trackpad off under a
  [gesture](GESTURES.md#set-trackpad) that had moved a camera or a window.
- `effects` holds the [autostart](#autostart) commands on the launch load and is
  empty on every later one.
- `focus_follows_mouse` is that setting in the configuration now in force, the
  previous one's when the file was refused. It is there for a shell to show,
  and the native shell does not read it: [`hover`](POINTER.md#hover) is sent
  either way and the controller decides.
- What a load reports is also the message of upstream's on-screen error bar:
  the snapshot's `render.errors` holds the one entry of `errors`, else the
  first of `warnings` with a count of the rest, until a load without either
  clears it ([EFFECTS.md](EFFECTS.md#errors)).

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
| `[navigation] anchors` | `zoom-to-fit` fits them with the windows, as upstream's `ZoomToFit` does; `center-nearest` lands on them |
| `[navigation] auto_navigate_on_click` | `activate` with cause `click_release` flies to a still-focused window that is not wholly in view |
| `[zoom] reset_on_activation` | whether `activate` with cause `native` and the IPC `Focus` fly to a clipped window at zoom 1 or at the current zoom |
| `[navigation.bookmarks]` | seeds of the bookmark registry, see [Session](#session) |
| `[navigation] trackpad_speed`, `mouse_speed` | a timed `pan` from a scroll and from a drag, and `trackpad_speed` a gesture's swipe pan, see [camera motion](MOTION.md) |
| `[navigation] drift` | how far a released pan coasts, a swipe pan included |
| `[navigation.edge_pan] zone`, `speed_min`, `speed_max`, `latency_ms` | the edge pan under a dragged window, by pointer or by move gesture, and the wait at an edge that borders another output |
| `[navigation.edge_pan] cursor_pan`, `cursor_zone` | cursor edge pan: its state at launch and its zone |
| `[zoom] step` | `zoom-in`, `zoom-out`, and a wheel `zoom_by` |
| `[zoom] mouse_speed`, `trackpad_speed` | a wheel `zoom_by`; a gesture's pinch zoom and a pinch `zoom_by` |
| `[gestures.on-window]`, `[gestures.on-canvas]`, `[gestures.anywhere]`, `disable_defaults = ["gestures"]` | the bindings a `gesture_begin` resolves, see [GESTURES.md](GESTURES.md) |
| `[gestures] swipe_threshold`, `pinch_in_threshold`, `pinch_out_threshold` | when a threshold gesture fires |
| `[input.trackpad] enable` | whether gestures are dispatched, until `set-trackpad` overrides it |
| `[zoom] fit_padding` | `zoom-to-fit`, `zoom-to-fit-snapped`, and the dynamic minimum zoom |
| `[navigation] resize_step` | the step of `grow-window` and `shrink-window`, which run only once the shell has sent `native_resize_capability`: [SIZES.md](SIZES.md#the-gate) |
| `[snap] enabled`, `gap`, `distance`, `break_force`, `corners`, `centers` | `begin_drag`, `begin_resize`, `gesture_to` and the native resize transaction's snap intent |
| `[snap] outer_gap` | the inset of a placed window in window navigation; with the capability, also the inset of `fit-window` and `fill-window` |
| `focus_placement`, `[[outputs]] focus_placement` | where window navigation and `send-to-output` park the window, and with it where `window_placement = "center"` spawns one |
| `[[outputs]] name`, `[outputs.hot_corners]` | which output an entry governs and its [hot corners](#hot-corners) |
| `autostart` | `exec` effects of the launch load, see [Autostart](#autostart) |
| `window_placement` | where a window that appears by itself is placed: `center`, `cursor` or `auto`, see [LIFECYCLE.md](LIFECYCLE.md#2-placement) |
| `[decorations] title_bar_height` | the diagonal step of the placement cascade; also part of `render.chrome` below |
| `[background] type`, `path`, `texture`, `mirror_tile`, `transparent_shader`, `animate_fps`, `cache_shader` | reported as the snapshot's `render.background` for the shell's compositor, see [RENDER.md](RENDER.md#render). Reporting is all the controller does: the app's compositor accepts `cache_shader` and ignores it (a shader always renders live) |
| `[decorations] bg_color`, `fg_color`, `corner_radius`, `title_bar_height`, `font`, `font_size`, `font_weight`, `title_align` | reported as `render.chrome`: what stand-ins and compositor title bars are rasterised from |
| `[decorations] default_mode`, `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `opacity`, `opacity_focused`, `blur` | each placement's `decoration`, through upstream's `effective_*` helpers, see [RENDER.md](RENDER.md#placements); border, shadow and bar also size a `screenshot window`. `opacity` and `opacity_focused` are also each placement's own `opacity`, the same number, for a window with no opacity of its own from a rule or an IPC `Opacity` write. They reach bound windows only: a stand-in is always 1.0, as upstream's, and a window captured alone by `screenshot window` is opaque unless a rule or an `Opacity` write pins its opacity |
| `[[window_rules]] decoration`, `border_width`, `border_color`, `border_color_focused`, `corner_radius`, `shadow`, `opacity`, `blur` | the same, for the window the rule matched when it mapped: kept with the window, reported in `snapshot.windows[].rule`, and what its `decoration` and `opacity` are resolved from until it is gone, whatever its title or the config becomes ([RULES.md](RULES.md#matching)); never for a stand-in |
| `[output.outline] color`, `thickness`, `opacity` | reported as `render.outline` |
| `[effects] blur_radius`, `blur_strength`, `animate_blur_fps`, `animation_speed`, `animation_scale` | reported as `render.effects` for the shell's compositor: the frost, and the open, close and stand-in animations, see [EFFECTS.md](EFFECTS.md#rendereffects) |
| `[zoom] fit_padding` | also the margin around a `screenshot all` |
| `[snap] gap` | also the spacing of an `auto` placement, the cluster test for who takes the focus after a close, the cluster `zoom-to-fit-snapped` frames and, with the capability, the cluster `fit-window-snapped` shifts and the clearance `fill-window` keeps |
| `[zoom] reset_on_new_window` | whether the navigation to a new window lands at zoom 1 |
| `[navigation] auto_navigate_on_close` | whether the camera flies to the window that takes the focus after a close, when that window is in the closed one's snap cluster or overlaps it and is not wholly in view |
| `[session] suspend_on_close`; `[[window_rules]] suspend_on_close` | whether a window that closes by itself leaves a stand-in; the rule's `app_id` is matched against the bundle identifier |
| `[session] restore_windows`; `[[window_rules]] restore_windows` | whether a saved slot whose window is gone stays as a stand-in at `adoption_complete`; not decided while the launch config file is refused |
| `[session] restore_camera`, `restore_bookmarks` | what `load` restores, see [Session](#session) |
| `[[window_rules]] app_id`, `title` | matched against the bundle identifier and the source title when a window maps, see [RULES.md](RULES.md) |
| `[[window_rules]] position`, `pinned_to_screen`, `output`, `widget`, `focus_on_open` | where a new window is placed, whether it is pinned to an output's screen or a widget, and whether it is focused |
| `[[window_rules]] size` | asked of a new canvas window once it is placed, only once the shell has sent `native_resize_capability`; otherwise recorded and named in `rule.not_applied`: [RULES.md](RULES.md#a-rules-size) |
| `[env]`, `[cursor] theme`, `size` | the environment of an `exec` effect |
| `focus_follows_mouse` | whether `hover` moves the focus to the window under the pointer, without raising it; see [POINTER.md](POINTER.md#sloppy-focus) |
| `[zoom] interact_min` | the zoom below which an output is in [pick mode](POINTER.md#pick-mode): `hit`, `input`, `hover`, `pick` and the `pick` flag of `mouse_binding` |

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

- `[xwayland]`
- `[navigation] touch_speed`
- `[zoom] touch_speed`
- `[input.keyboard] layout`, `variant`, `options`, `model`,
  `remember_layout_per_window`, `num_lock`, `caps_lock`: these have no macOS
  meaning, see [Keyboard layouts](#keyboard-layouts)
- `[input.trackpad]` other than `enable`, including
  `disable_on_external_mouse`, which counts as on; `[input.mouse]`,
  `[input.touch]`, `[input.tablet]`
- `[cursor] inactive_opacity` (theme and size reach only the `exec` environment)
- `[background] cache_budget_mb`; `[backend]`; `[output]` other than
  `[output.outline]`
- `[[outputs]] scale`, `transform`, `position`, `mode`, and
  `[outputs.hot_corners] disable_when_fullscreen`: macOS arranges the displays
  and there is no fullscreen, see [Outputs](#outputs)
- of `[[window_rules]]`, `fullscreen`, `preserve_aspect_ratio` and
  `layer_order`, which are recorded with the window and named in its
  `rule.not_applied`; `size` joins them without the capability, and for a
  widget or a screen-pinned window with it. `layer_order` is there by
  upstream's own rule, which ignores it for a regular window
  ([RULES.md](RULES.md#layer_order)). `pass_keys` and `pass_mouse` are applied
  ([RULES.md](RULES.md#pass-rules))
- `[touch.*]` and its thresholds: upstream's touchscreen gestures, see
  [GESTURES.md](GESTURES.md#why-this-path-and-not-the-touch-recogniser)
- `[mouse] resize_on_border`, `decoration_resize_snapped`, `decoration_fit_snapped`
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
          "action":"home-toggle","combo":"mod+a","chord":"⌃⌥A","repeat":false,"implemented":true,"passable":true}],
 "media_keys":[{"nx_key_type":16,"modifiers":{…},"action":"spawn …","combo":"XF86AudioPlay","chord":"…","repeat":true,"implemented":true,"passable":true}],
 "skipped":[{"combo":"Print","action":"spawn grim - | wl-copy","reason":"the key has no macOS equivalent"}],
 "hot_corners":[{"output":1,"stable_id":"…","threshold":4.0,"disable_while_dragging":true,"disable_when_fullscreen":true,"corners":{}}],
 "reserved":[{"purpose":"exit","key_code":53,"modifiers":{…},"claimed_by":null}],
 "layout_independent":true,"repeat_delay_ms":200,"repeat_rate_hz":25,"super":"ctrl+alt",
 "cycle_hold":{"control":false,"option":true,"shift":false,"command":false},
 "settings":{"trackpad_speed":1.5,"mouse_speed":1.0,"zoom_step":1.1,"zoom_mouse_speed":1.0,"zoom_trackpad_speed":1.0},
 "warnings":[]}
```

- `keys` is sorted by `combo`. `key_code` is always a number.
- `action` is the canonical config string of the action: `parse_action` reads
  it back as the same action, and the `action` command accepts it.
- `repeat` is upstream's `Action::is_repeatable`: `zoom-in`, `zoom-out`,
  `nudge-window`, `grow-window`, `shrink-window`, `pan-viewport`,
  `cycle-windows` and `spawn` repeat while held, after `repeat_delay_ms` and
  then `repeat_rate_hz` times a second. A `spawn` whose program is not found
  does not, see [Upstream's Linux commands](#upstreams-linux-commands).
- `upstream` is present only on a default binding that was replaced by its
  macOS equivalent, and holds the action upstream binds there.
- `hot_corners` lists every registered output, see [Hot corners](#hot-corners).
- `implemented` is false when the `action` command would refuse the action with
  `action not implemented on macOS yet: <name>`. The binding is listed all the
  same; registering its chord takes the chord from every app for nothing. The
  five [sizing actions](SIZES.md#the-gate) are implemented only once the shell
  has sent `native_resize_capability`, so the table must be read after it.
- `passable` is false for the binding on the exit chord and for every `quit`:
  no window's `pass_keys` takes those. `snapshot.pass_keys` says what the
  window that holds the keyboard passes, by `combo`
  ([RULES.md](RULES.md#pass_keys)).
- `chord` is a display string: the modifiers as glyphs and the US key label.
- `cycle_hold` is upstream's `Config::cycle_hold` as physical modifiers: the
  modifiers of the `cycle-windows forward` binding, Option when it has none or
  is unbound. A `cycle-windows` step fired with `held` true stays open until
  these are no longer all down, which is when the shell sends
  [`end_focus_cycle`](FOCUS.md#upstream-entry-points). It is `null` when the set
  has no macOS chord (it holds `mod3`, or `super` together with a modifier the
  super chord cannot displace); the binding that would have opened such a cycle
  is skipped for the same reason.
- `settings` are the speeds a pointer gesture scales by, see below.
- `warnings` are this map's own, one per skipped binding the user should know
  about, `binding '<combo>' = '<action>' skipped: <reason>`, followed by one
  per binding of the file that will not repeat.

The key table is private to `driftwm-core`, which this crate may not change, so
the bindings are found by asking `Config::lookup` for every known keysym under
each of the 32 modifier sets. A key named in the file's `[keybindings]` table
that the Mac key table lacks is added to that search, so its binding is reported
as skipped instead of vanishing.

### Upstream's defaults as registered

With no config file, the default super chord and `mod_key = "super"`, on a Mac
that has none of upstream's Linux programs. "Runs" is `implemented`. Upstream
binds 57 keys: 45 land on Mac keys and are registered, one of them with a
substituted command; 8 are on media keys that macOS handles itself; and 4 have
no Mac key.

| Upstream | macOS chord | `key_code` | Action | Repeats | Runs |
| --- | --- | --- | --- | --- | --- |
| `alt+Tab` | ⌥Tab | 48 | `cycle-windows forward` | yes | yes |
| `alt+shift+Tab` | ⌥⇧Tab | 48 | `cycle-windows backward` | yes | yes |
| `mod+0` | ⌃⌥0 | 29 | `zoom-reset` |  | yes |
| `mod+1` | ⌃⌥1 | 18 | `go-to-bookmark 1` |  | yes |
| `mod+2` | ⌃⌥2 | 19 | `go-to-bookmark 2` |  | yes |
| `mod+3` | ⌃⌥3 | 20 | `go-to-bookmark 3` |  | yes |
| `mod+4` | ⌃⌥4 | 21 | `go-to-bookmark 4` |  | yes |
| `mod+Down` | ⌃⌥Down | 125 | `center-nearest down` |  | yes |
| `mod+Left` | ⌃⌥Left | 123 | `center-nearest left` |  | yes |
| `mod+Return` | ⌃⌥Return | 36 | `exec-terminal` |  | yes |
| `mod+Right` | ⌃⌥Right | 124 | `center-nearest right` |  | yes |
| `mod+Up` | ⌃⌥Up | 126 | `center-nearest up` |  | yes |
| `mod+a` | ⌃⌥A | 0 | `home-toggle` |  | yes |
| `mod+alt+Down` | ⌃⌥⇧⌘Down | 125 | `send-to-output down` |  | yes |
| `mod+alt+Left` | ⌃⌥⇧⌘Left | 123 | `send-to-output left` |  | yes |
| `mod+alt+Right` | ⌃⌥⇧⌘Right | 124 | `send-to-output right` |  | yes |
| `mod+alt+Up` | ⌃⌥⇧⌘Up | 126 | `send-to-output up` |  | yes |
| `mod+c` | ⌃⌥C | 8 | `center-window` |  | yes |
| `mod+ctrl+Down` | ⌃⌥⌘Down | 125 | `pan-viewport down` | yes | yes |
| `mod+ctrl+Left` | ⌃⌥⌘Left | 123 | `pan-viewport left` | yes | yes |
| `mod+ctrl+Right` | ⌃⌥⌘Right | 124 | `pan-viewport right` | yes | yes |
| `mod+ctrl+Up` | ⌃⌥⌘Up | 126 | `pan-viewport up` | yes | yes |
| `mod+ctrl+shift+q` | ⌃⌥⇧⌘Q | 12 | `quit` |  | yes |
| `mod+d` | ⌃⌥D | 2 | `exec-launcher` |  | yes |
| `mod+e` | ⌃⌥E | 14 | `toggle-cursor-pan` |  | yes |
| `mod+equal` | ⌃⌥= | 24 | `zoom-in` | yes | yes |
| `mod+f` | ⌃⌥F | 3 | `toggle-fullscreen` |  | no |
| `mod+l` | ⌃⌥L | 37 | `exec /usr/bin/pmset displaysleepnow`, for upstream's `spawn swaylock -f -c 000000 -kl` |  | yes |
| `mod+m` | ⌃⌥M | 46 | `fit-window` |  | with `--experimental-native-resize` |
| `mod+minus` | ⌃⌥- | 27 | `zoom-out` | yes | yes |
| `mod+q` | ⌃⌥Q | 12 | `close-window` |  | yes |
| `mod+shift+1` | ⌃⌥⇧1 | 18 | `set-bookmark 1` |  | yes |
| `mod+shift+2` | ⌃⌥⇧2 | 19 | `set-bookmark 2` |  | yes |
| `mod+shift+3` | ⌃⌥⇧3 | 20 | `set-bookmark 3` |  | yes |
| `mod+shift+4` | ⌃⌥⇧4 | 21 | `set-bookmark 4` |  | yes |
| `mod+shift+Down` | ⌃⌥⇧Down | 125 | `nudge-window down` | yes | yes |
| `mod+shift+Left` | ⌃⌥⇧Left | 123 | `nudge-window left` | yes | yes |
| `mod+shift+Right` | ⌃⌥⇧Right | 124 | `nudge-window right` | yes | yes |
| `mod+shift+Up` | ⌃⌥⇧Up | 126 | `nudge-window up` | yes | yes |
| `mod+shift+m` | ⌃⌥⇧M | 46 | `fit-window-snapped` |  | with `--experimental-native-resize` |
| `mod+shift+w` | ⌃⌥⇧W | 13 | `zoom-to-fit-snapped` |  | yes |
| `mod+t` | ⌃⌥T | 17 | `toggle-pin-to-screen` |  | yes |
| `mod+w` | ⌃⌥W | 13 | `zoom-to-fit` |  | yes |
| `mod+x` | ⌃⌥X | 7 | `focus-center` |  | yes |
| `mod+z` | ⌃⌥Z | 6 | `zoom-reset` |  | yes |

Under `{"super":"cmd"}` every ⌃⌥ above is ⌘, `mod+ctrl+…` is ⌃⌘…, `mod+alt+…`
is ⌥⌘… and `mod+ctrl+shift+q` is ⌃⇧⌘Q; nothing is displaced.

`media_keys` is empty. `skipped` lists upstream's eight media-key defaults,
which macOS handles itself:

| Upstream | `nx_key_type` | Upstream's action | Reason |
| --- | --- | --- | --- |
| `XF86AudioLowerVolume` | 1 | `spawn wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-` | `macOS handles the volume keys itself` |
| `XF86AudioMute` | 7 | `spawn wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle` | `macOS handles the volume keys itself` |
| `XF86AudioNext` | 17 | `spawn playerctl next` | `macOS handles the media keys itself` |
| `XF86AudioPlay` | 16 | `spawn playerctl play-pause` | `macOS handles the media keys itself` |
| `XF86AudioPrev` | 18 | `spawn playerctl previous` | `macOS handles the media keys itself` |
| `XF86AudioRaiseVolume` | 0 | `spawn wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+` | `macOS handles the volume keys itself` |
| `XF86MonBrightnessDown` | 3 | `spawn brightnessctl set 5%-` | `macOS handles the brightness keys itself` |
| `XF86MonBrightnessUp` | 2 | `spawn brightnessctl set +5%` | `macOS handles the brightness keys itself` |

and the four with no Mac key, as `the key has no macOS equivalent`: `Print` and
`shift+Print` (`spawn grim …`), `XF86AudioPause` (`spawn playerctl play-pause`)
and `XF86AudioStop` (`spawn playerctl stop`).

[Upstream's Linux commands](#upstreams-linux-commands) has the rule. On a
machine where those programs are installed the table is upstream's own:
`mod+l` runs `spawn swaylock -f -c 000000 -kl` and repeats, and the eight media
keys are listed under `media_keys` with their `nx_key_type`. A media key is not
a virtual key code, so nothing registers it as a hot key in either case.

## Mouse bindings

```json
{"op":"mouse_binding","trigger":"left","source":null,
 "modifiers":{"control":true,"option":true,"shift":false,"command":false},"context":"window"}
```

- `trigger`: `left`, `right`, `middle`, `back`, `forward`, `scroll`,
  `wheel_up` or `wheel_down`. Upstream's grammar names only the first three
  buttons, so `back` and `forward` never have a binding. `wheel_up` and
  `wheel_down` are upstream's discrete wheel notch (`wheel-up`, `wheel-down`),
  a lookup apart from `scroll` that answers only a notch bound to an action;
  a wheel event with no notch binding, or a passed one, is then a `scroll`.
  The shell asks the notch first for every event of a discrete wheel, in
  upstream's order, and never for a trackpad's precise scroll
  ([RULES.md](RULES.md#pass_mouse)).
- `source`, for `scroll`: `finger` is upstream's `trackpad-scroll`; `wheel`,
  `continuous` and `null` are `wheel-scroll`, as upstream treats every source
  that is not a finger.
- `modifiers`: the physical modifiers held. A missing member is not held.
- `context`: `window` when the pointer is over a window, else `canvas`.
- `window`, optional: the window under the pointer, as `hit` reports it. A
  binding that window's `pass_mouse` rule claims is discarded and the reply
  is `{"binding":null,"passed":true}`: the press or scroll is the
  application's, exactly as an unbound one
  ([RULES.md](RULES.md#pass_mouse)). Without it, and whenever nothing is
  claimed, the reply is the one below.
- `pick`, optional: true when that window is a pick target, as `hit` reports
  it. The lookup then follows upstream's [pick mode](POINTER.md#pick-mode),
  and the window claims nothing by `pass_mouse`: below `[zoom] interact_min`
  only a screen-pinned window, never a pick target, keeps its button claims.

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
scales a pinch by `zoom_trackpad_speed`. The reply still carries them, but
applying them is the controller's: a timed `pan` and `zoom_by` read the config
themselves, so a shell that uses those commands must not scale again, and a
[gesture](GESTURES.md)'s pan and pinch go through the same code. See
[camera motion](MOTION.md).

Upstream's defaults under the default super chord:

| Chord | On a window | On the canvas |
| --- | --- | --- |
| left drag | the app's | `pan_viewport` |
| ⌥ left | `move_window` | none |
| ⌥⇧ left | `move_snapped_windows` | none |
| ⌥ right | `resize_window` | none |
| ⌥⇧ right | `resize_window_snapped` | none |
| ⌥ middle | `action` `fit-window` (refused without `--experimental-native-resize`) | none |
| ⌥⇧ middle | `action` `fit-window-snapped` (the same) | none |
| ⌃⌥ middle | `action` `toggle-fullscreen` (refused) | none |
| ⌃⌥ left | `pan_viewport` | `pan_viewport` |
| ⌃⌥⌘ left (`mod+ctrl`) | `center_nearest` | `center_nearest` |
| finger scroll | the app's | `pan_viewport` |
| wheel scroll | the app's | `zoom` |
| ⌃⌥ finger scroll | `pan_viewport` | `pan_viewport` |
| ⌃⌥ wheel scroll | `zoom` | `zoom` |

## Actions that run now

`center-window`, `center-nearest <dir>`, `cycle-windows forward` /
`cycle-windows backward` and `focus-center` are upstream's window navigation:
see [NAVIGATION.md](NAVIGATION.md#window-navigation-actions).

`nudge-window <dir>` moves the focused window by `navigation.nudge_step` world
points along the unit vector, each axis rounded as upstream rounds it. It is a
logical world move, refused during a gesture or a live native resize and for a
destination outside the integer range, exactly as the IPC `Move` is. With no
focused window nothing happens and nothing is dirty, as upstream.

`set-trackpad on|off|toggle` turns the dispatch of trackpad gestures on or off
for the rest of the run, over `[input.trackpad] enable`. It needs no output and
changes nothing that is saved. [GESTURES.md](GESTURES.md#set-trackpad) has what
off means here and when a config reload drops the override.

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

`toggle-cursor-pan` flips the runtime cursor edge pan flag, which the first
config of a run set from `navigation.edge_pan.cursor_pan`. It needs no output
and has no effect for the shell beyond the snapshot's
`navigation.cursor_pan`: see [camera motion](MOTION.md#cursor-edge-pan).

`close-window` and `suspend-window` act on the focused window. For a window with
a bound source they return the effect
`{"op":"close_window","window":…,"identity":…,"generation":…}` and remember
what the close will mean; a focused placeholder is dismissed. Nothing happens
with no focused window. [LIFECYCLE.md](LIFECYCLE.md#actions-and-ipc) has the
whole contract.

`move-to-bookmark <name>` and `toggle-pin-to-screen` act on the focused window
too: [RULES.md](RULES.md#actions).

`send-to-output <dir>`, `send-cursor-to-output <dir>` and `switch-layout` are
described under [Outputs](#outputs) and [Keyboard layouts](#keyboard-layouts).

## Outputs

An output is what `register_output` registers: a stable id and its
`screen_bounds`, a rectangle in the shell's global screen space with the origin
at the top left and Y down. An `[[outputs]]` entry is matched by `name` against
the stable id, and `name = "*"` is upstream's wildcard: it applies to every
output with no exact entry, and an exact entry replaces it whole, so an exact
entry without a `hot_corners` table has no hot corners. `focus_placement` and
`hot_corners` are applied. `scale`, `transform`, `position` and `mode` are read
and unused: macOS owns the display arrangement, and `screen_bounds` is its
result.

**Adjacency** is upstream's `output_in_direction` with `screen_bounds` standing
in for the output's layout position and size. From the center of the source
output, every other output whose center is at least one point away and lies
within about 60 degrees of the direction (the normalised dot product is strictly
above 0.5) is a candidate, and the nearest center wins; among equals, the
earliest registered. `up` is the smaller y.

`send-to-output <dir>` moves the focused window to the adjacent output:

1. No focused window, or a focused [widget](RULES.md#widgets): nothing
   happens, as upstream.
2. A focused [screen-pinned window](RULES.md#screen-pinned-windows) is not
   moved on the canvas. Its pin is bound to the output adjacent to the pin's
   own output and keeps its place on the screen, moved inward until the whole
   frame is on that output (upstream's `send_pinned_to_output`). Nothing is
   raised or focused, `dirty` is true when the pin changed, and with no
   adjacent output nothing happens. The steps below are for a canvas window.
3. The source output is the first registered output whose viewport shows the
   window's center (upstream's `output_for_window`: the visible canvas rectangle
   is `policy::visible_canvas_rect` at the camera rounded to whole points, and
   the center is truncated), else the command's `output`. With neither the
   action is refused with `no active output`.
4. No adjacent output in that direction, a single output included: nothing
   happens, as upstream.
5. The window lands where a navigation on the target output would park it:
   with the target's camera `c`, zoom `z` and placement point `a` (the
   [focus placement](#applied-now) of the target output for this window at `z`),
   its center goes to `c + a / z` and its top-left to that minus half its size,
   each coordinate truncated toward zero as upstream's `as i32` does. The size
   is kept, the window is raised, and `dirty` is true.

It is a logical world move like `nudge-window`, refused during a gesture or a
live native resize of that window. `navigation` is null and `effects` is empty:
no camera moves and the window keeps the logical focus it had.

`send-cursor-to-output <dir>` needs the active output as `output`. With an
adjacent output it returns the effect

```json
{"op":"warp_pointer","screen":{"x":1800.0,"y":570.0},"output":2}
```

`screen` is the center of the target output's usable rectangle in global screen
coordinates (`screen_bounds.origin + usable_rect_local.center()`), which is
where upstream's canvas-space warp puts the cursor on that monitor, and
`output` is the target. The shell moves the pointer there; the controller moves
nothing. With no adjacent output `effects` is empty.

## Hot corners

```toml
[[outputs]]
name = "*"
[outputs.hot_corners]
threshold = 4
top_left = "zoom-to-fit"
bottom_right = "exec-launcher"
disable_while_dragging = true
```

`bindings` reports them for every registered output, in registration order:

```json
"hot_corners":[{"output":1,"stable_id":"…","threshold":4.0,
                "disable_while_dragging":true,"disable_when_fullscreen":true,
                "corners":{"top_left":"zoom-to-fit","bottom_right":"exec-launcher"}}]
```

`corners` maps each armed corner (`top_left`, `top_right`, `bottom_left`,
`bottom_right`) to its canonical action string and is empty when the output has
none. The list changes with the config and with the registered outputs, so the
shell reads `bindings` again after either.

The trigger is the shell's, and it is upstream's `check_hot_corners`: with the
pointer at `(x, y)` from the top-left of a rectangle `w` by `h`, a corner is
active while `x < threshold` or `x > w - threshold` on its side and
`y < threshold` or `y > h - threshold` on its side, the first of the four in the
order above. One latch holds the output and corner the pointer is in. An action
fires when the latch changes to a corner, never while the pointer stays in it,
and leaving the corner or the output clears the latch. The entry is latched even
when the action is then suppressed: with `disable_while_dragging`, while any
mouse button is held or a pointer gesture is running.

Upstream's rectangle is the output. The shell's is the output's panel: the
whole display, which is `screen_bounds` plus the 64-point toolbar strip the
shell keeps above it (with `--windowed`, the window). `screen_bounds` alone
would put the top corners 64 points below the physical screen corners, where a
flicked pointer never rests. That rectangle is the shell's own panel frame; it
reaches the controller only as the `output` of `hot_corner` and enters no camera
or world math. The shell reads the pointer at its poll and frame cadence, and
only while some output has a bound corner, where upstream checks every motion
event.

```json
{"op":"hot_corner","output":1,"corner":"top_left"}
{"op":"hot_corner","output":1,"corner":"top_left","pointer":{"x":2.0,"y":1.5},"held":false}
```

runs the action bound to that corner of that output through the same dispatch
as `action`, with that output as the active one, and answers
`{navigation, effects, dirty}` as `action` does. `pointer` and `held` are
[`action`'s](IPC.md#action): the pointer's global screen point, which
`focus-center` reads, and whether a real modifier is down, which keeps a
`cycle-windows` step open. Upstream runs a corner's action through
`execute_action` like any other, so a corner bound to a non-cycle action ends a
cycle in progress first, and any corner's action stops its output's
[scroll momentum](MOTION.md). A corner with no binding, and
any corner while a controller gesture (a drag or resize, the drag of a
[trackpad move](GESTURES.md) included) is installed on an
output whose `disable_while_dragging` is on, answers
`{"navigation":null,"effects":[],"dirty":false}`. An unregistered output is a
controller error, and so is an action that does not run here.
`disable_when_fullscreen` is reported and has nothing to suppress: there is no
fullscreen.

## Keyboard layouts

Upstream's layouts are xkb groups built from `[input.keyboard] layout`. On
macOS they are the keyboard layout input sources the user has enabled in System
Settings; nothing here creates, removes or reorders one.

`switch-layout next`, `switch-layout prev` (or `previous`) and
`switch-layout <index>` return one effect and need no output:

```json
{"op":"switch_layout","target":"next","index":null}
{"op":"switch_layout","target":"prev","index":null}
{"op":"switch_layout","target":"index","index":2}
```

The shell selects among the enabled layouts, wrapping for `next` and `prev`. An
index past the last layout selects nothing, as upstream warns and ignores it.
The controller does not range-check the index: the shell's list is the
authority.

```json
{"op":"layout_changed","name":"U.S.","short":"en","index":0,"count":2}
```

tells the controller the layout now in force: once at startup and whenever the
input source changes, whoever changed it. `name` is the layout's display name,
`short` a short code for a status bar, `index` its place among the `count`
enabled layouts. The shell sends the input source's localized name and, as
`short`, its first language code (`en` is what the British layout reported on
the development machine), or the last component of its identifier when it lists
no language. `count` must be at least 1 and `index` below it, and each
string at most 1024 bytes. The controller
caches it for the IPC [`Layout`](IPC.md#requests) request and `StateInfo`; it is
never saved, and a `load` keeps it. Until the first report both read as empty
strings.

`[input.keyboard] layout`, `variant`, `options`, `model`,
`remember_layout_per_window`, `num_lock` and `caps_lock` are read and unused:
macOS owns the layout list, the modifier options and the lock keys, and it
remembers the input source per document itself when the user asks it to.

## Autostart

`autostart = ["cmd", …]` runs once, at launch. The first `load_config` of a
controller returns one `exec` effect per command in `effects`, in file order,
each exactly what `exec <cmd>` returns: `sh -c` with the config's child
environment. Every later `load_config` returns an empty `effects`, a changed
list included: upstream's reload logs `autostart changes only apply at startup`.
When the launch file cannot be read or parsed the built-in defaults are in force
and nothing starts, then or after a later successful reload, as upstream.

Upstream starts them from `main` for every backend, the nested winit one
included, 100 ms after its event loop starts. The shell keeps the effects of its
launch `load_config` and runs them once, 100 ms after its socket is up and the
chooser or canvas is shown, `--windowed` included; it never looks at the
`effects` of a later load. Probe, demo and owned-fixture runs never send
`load_config`, so they never start anything.

Upstream inserts `WAYLAND_DISPLAY` into `child_env` for these commands, and its
`msg` client derives the socket from that variable, so a child always talks to
the compositor that started it. The controller does not know which socket the
app serves, so an `exec` effect's `env` carries nothing for it; the shell adds
`INFINIFY_SOCKET=<the socket it serves>` to the environment of every `exec`
child, autostart included. `Infinify msg …` in an autostart command or an `exec`
binding then reaches the instance that started it, one on its own `--socket`
included, whatever `INFINIFY_SOCKET` the app itself was launched with. It is not
added when the app runs without IPC. One difference: upstream's insert
overwrites a `WAYLAND_DISPLAY` the file's `[env]` sets, and here an `[env]`
`INFINIFY_SOCKET` wins, because that variable is also the client's explicit
override, upstream's `DRIFTWM_SOCKET`.

## Upstream's Linux commands

Thirteen of upstream's default key bindings run programs that do not exist on a
Mac, nine on keys a Mac keyboard has and four on keys it lacks. A **default**
binding (one the file's `[keybindings]` table does not bind or unbind) whose
program is not found is not registered as written:

| Upstream default | On macOS |
| --- | --- |
| `mod+l` = `spawn swaylock -f -c 000000 -kl` | registered as `exec /usr/bin/pmset displaysleepnow` |
| `XF86AudioRaiseVolume`, `XF86AudioLowerVolume`, `XF86AudioMute` = `spawn wpctl …` | not registered: macOS handles the volume keys itself |
| `XF86MonBrightnessUp`, `XF86MonBrightnessDown` = `spawn brightnessctl …` | not registered: macOS handles the brightness keys itself |
| `XF86AudioPlay`, `XF86AudioNext`, `XF86AudioPrev` = `spawn playerctl …` | not registered: macOS handles the media keys itself |
| `Print`, `shift+Print` = `spawn grim …`; `XF86AudioPause`, `XF86AudioStop` = `spawn playerctl …` | no such key on a Mac keyboard, as before; screenshots are the system's ⇧⌘3, ⇧⌘4 and ⇧⌘5 |

- **Found** means an executable file of that name in a directory of `PATH`: the
  `PATH` of the file's `[env]` when it sets one, else the controller's own.
  That is the `PATH` an `exec` effect runs with. The program is the first word
  of the command; a command that starts with anything but a plain word, with a
  relative path or with a shell builtin is taken as found.
- The substituted binding carries `"upstream"`, the action it stands for, and
  is an `exec`, which does not repeat: a held chord must not ask for the lock at
  the repeat rate.
- A platform-handled binding moves from `media_keys` to `skipped` with the
  reason above and no warning. Any other default whose program is missing would
  be skipped with `'<program>' is not installed and has no macOS equivalent`;
  none of upstream's is.
- When the program is found, the default is registered exactly as upstream
  wrote it.
- A binding the **file** makes is always registered exactly as written. If it is
  a `spawn` whose program is not found, `repeat` is false, so a held chord does
  not start a failing shell at the repeat rate, and `warnings` says so:
  `binding '<combo>' = '<action>': '<program>' was not found, so it will not repeat while held`.
- An entry upstream's loader rejects (an action that does not parse, reported in
  `load_config`'s `warnings` as `config: invalid action …`) binds nothing, as
  upstream: the default on that combo is still a default, and is substituted or
  skipped by the rules above.

`pmset displaysleepnow` turns the displays off. macOS then asks for the password
according to System Settings › Lock Screen › "Require password after screen
saver begins or display is turned off"; set to "Immediately", that is a locked
session. No setting is read or changed here. macOS has no public command that
locks the session regardless of that setting.

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
- Upstream's `child_env` also carries `WAYLAND_DISPLAY`. An `exec` effect's
  `env` has no counterpart; the shell adds `INFINIFY_SOCKET` to the child
  instead, see [Autostart](#autostart).
- `exec` does not reveal the cursor; upstream's does for a few seconds.
- `nudge-window` is applied at once; upstream animates the frame from its old
  place. It does not raise the window. It ends a fill restore point as
  upstream's does; one exists only for a window filled behind
  `--experimental-native-resize` ([SIZES.md](SIZES.md#mode)).
- A new output's camera is the world origin at its top-left corner, as before;
  upstream centers the origin.
- Every window is saved as a slot whatever `restore_windows` says, because
  applications outlive the canvas; the flag decides at `adoption_complete`
  whether a slot whose window is gone stays as a stand-in. See
  [LIFECYCLE.md](LIFECYCLE.md#slots-and-re-adoption-the-macos-rule).
- `[navigation] auto_navigate_on_click` navigates when the shell sends
  `activate` with cause `click_release`. Upstream's 5 px click slop is the
  shell's to apply before sending it, and upstream's deferral past the
  double-click window after a title-bar click does not exist.
- `cycle_hold` is reported, not enforced: the controller sees no keys, so the
  shell ends a held cycle.
- A reload re-applies only what the table above lists. Upstream also rebuilds
  its keyboard layout, cursor theme, device settings, output rules and render
  caches. Of those only the last has a counterpart: every accepted reload
  moves `render.revision`, which tells the shell to rebuild what it derived
  from the config and to read the background's shader and image files again,
  as upstream's reload drops its background caches whatever the file changed
  ([RENDER.md](RENDER.md#render)).
- `send-to-output` asks nothing of native focus: the window already holds the
  logical focus, and is only raised. Upstream activates it and sets keyboard
  focus again. A focused window that no output shows needs the command's
  `output`, where upstream falls back to its first output.
  Fullscreen windows, which upstream moves in screen space, do not exist here.
  A pinned window's source output is the one its pin is bound to, where
  upstream takes the output showing the pin's canvas frame, and a pin whose
  own output is disconnected goes nowhere. A frame with a fractional origin or
  size is read at upstream's integer boundary for the source output and the
  half size, and keeps its size.
- `send-cursor-to-output` with no `output` is refused, where upstream falls
  back to its first output. The pointer is the shell's, so the warp is an
  effect, and the next action's active output is whatever the shell then
  reports.
- Output adjacency reads `screen_bounds` as given, where upstream's layout
  positions and logical sizes are whole numbers.
- The hot-corner latch and the held-button half of `disable_while_dragging` are
  the shell's. The controller suppresses a corner only for its own drag or
  resize gesture; a native resize is driven with a button held, which is the
  shell's to see. The shell measures a corner on the display's panel, not on
  `screen_bounds`, and samples the pointer instead of seeing every motion, so a
  pointer that crosses a corner between two samples fires nothing.
- `switch-layout` selects among macOS's enabled input sources instead of xkb
  groups. Upstream's `layout_short` is the `[input.keyboard] layout` token of
  the active group; here it is the short code the shell reports, a language
  code, so two layouts of one language share it.
- Autostart effects are returned with the launch `load_config`, before any
  output is registered; the shell holds them until 100 ms after startup, which
  is when upstream starts them.
- Upstream registers its Linux default commands whether or not they are
  installed. See [Upstream's Linux commands](#upstreams-linux-commands).

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
`load` and `load_config`. The default key table there is read with upstream's
five Linux programs present as executables on the config's own `PATH`, so it is
upstream's table on any machine. The motion settings (`drift`, the pan and zoom
speeds and `[navigation.edge_pan]`) are exercised by `tests/motion_flow.rs`.

`tests/gesture_flow.rs` covers what the file does to gestures: the `[gestures]`
tables and thresholds, the two trackpad speeds, `drift`, the edge pan under a
move gesture, and `[input.trackpad] enable` with `set-trackpad`. See
[GESTURES.md](GESTURES.md#evidence-and-limits).

`tests/platform_actions_flow.rs` drives the same ABI for what this page adds:

- hot corners from a config file with a wildcard entry, an exact entry, an exact
  entry without corners and a `none` corner: the `bindings` list before and
  after the config, after an output is removed and after a reload; each corner
  run, unarmed or refused; and the dragging rule on and off during a gesture
  (a corner that runs window navigation, with its `pointer` and `held`, is in
  `tests/navigation_actions_flow.rs`);
- `send-to-output` over two and three outputs whose bounds are neither aligned
  nor equal, in each of the four directions, with the target at another zoom,
  under a usable area that is not the whole output, with the placement point
  from the navigation context and from `focus_placement` in a config file; the
  source output by registration order, by the rounded camera, the truncated
  center and the half-open view edge, and by the active output when no output
  shows the window; truncation toward zero for odd and fractional frames; the
  raise; the refusals; and a single output;
- `send-cursor-to-output` for all eight directions from each of three outputs,
  with the effect's coordinates;
- every `switch-layout` form, `layout_changed` feeding `Layout`, `StateInfo` and
  the snapshot, its refusals, and a scene save and load;
- the `subscribe` effect's line against the `State` reply and against
  upstream's member order, and `state_event` across requests that change the
  state, requests that do not, a change of active output, and every frame of a
  flight;
- autostart effects on the launch load and on no later one;
- the default key table with an empty `PATH`, with all five programs present,
  with one present and two not executable; bindings the file wrote, the
  two that repeat upstream's defaults word for word included; and two entries
  the loader rejects, whose defaults stay defaults.

The expected positions and adjacency were worked out by hand from the adapted
rules, with no oracle build of upstream. Each of the output rules was also
changed in the source once (rounding in place of truncation, a narrower cone,
the camera floored or rounded up, the center floored, a closed view edge, the
active output preferred) to see the tests fail, and restored.

`tests/render_flow.rs` covers the tables the compositor draws from; see
[RENDER.md](RENDER.md#verification-boundary). `tests/rules_flow.rs` covers
`[[window_rules]]`; see [RULES.md](RULES.md#verification-boundary).

Those are controller scenarios. They are not evidence that a chord is registered
with macOS, that a key press, button or scroll reaches the shell, that a
character resolves through a keyboard layout, that an `exec` effect starts a
process, that the config file is watched, or that anything is drawn. The key
codes were read from the macOS SDK headers; none was pressed. Nor are they
evidence that the pointer is watched or reaches a corner, that it is warped,
that an input source is listed, selected or reported, or that an autostart
command starts. `/usr/bin/pmset displaysleepnow` was not run: the file exists on
the development machine (macOS 27.2), and what it does to the session there,
and whether a key release wakes the display at once, was not observed.

The shell's side is described in the
[shell notes](../../native/desktop/README.md#configuration). Their
[What has been run](../../native/desktop/README.md#what-has-been-run) lists a
scripted session against the built app on 2026-10-09 in which the file watch,
`reload-config`, a broken file, a file moved away and back, `nudge-window`,
`spawn` and `exec` were observed over the IPC socket, and names what stayed unrun: every hot key
and every pointer binding. Two more launches that day, listed there as well,
observed an `autostart` command starting once and not again on a reload, the
launch `layout_changed` report in `Layout` and `State`, `switch-layout next`
with a single enabled input source (nothing selected), and `send-to-output` and
`send-cursor-to-output` with a single output (nothing moved, no warp). Two
further launches after the review fixes observed `INFINIFY_SOCKET` in an
autostart child and in an IPC `exec` child (the served socket, and the file's
`[env]` value once it set one), and an autostart `msg` with no `--socket`
answered by that instance. No hot
corner was fired, no pointer was warped, no input source was selected and
`pmset` was not run in any of them.
