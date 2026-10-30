# Rendering contract, ABI 1

DriftWM draws its own canvas: a background, every window with a shadow, a
border, rounded corners and an opacity, stand-ins for windows that are gone,
and the outlines of other outputs' viewports. The controller draws nothing. It
says what a frame is made of, in upstream's own terms, and the shell's
compositor draws it. This file is that description, and the `msg screenshot`
flow that renders it to a file.

Adapted from <https://github.com/malbiruk/driftwm> at
`352333a8fa1b22171492d4b71a54102045c9a19d`:
`cmd_screenshot`, `resolve_screenshot_region`, `window_visual_rect`,
`snap_rect_to_rect` and `union_rect` in `src/ipc/mod.rs`, the checks at the top
of `capture_region_to_png` in `src/render/screenshot.rs`,
`output_viewport_rect` in `src/state/mod.rs`, `suspended_chrome` in
`src/state/window_frame.rs`, `snap_rect_at` in `src/state/fit.rs`,
`standin_body_rect` in `src/state/suspended.rs`, the stand-in and
isolated-window arms of `compose_capture_elements` in `src/render/mod.rs` with
what it leaves out of a canvas capture (`window_render_transform` in
`src/state/output.rs`), and
the cache reset at the end of `reload_config` in `src/state/reload.rs`. What an
element is drawn with is not adapted: it is `driftwm-core`'s `config::effective_*` helpers over its
`DecorationConfig`, upstream's own code, as are `BackgroundConfig`,
`OutputOutlineSettings` and `EffectsConfig`. The rule those helpers are given
is the one the window mapped with: [RULES.md](RULES.md) is the contract for
rules, widgets and screen-pinned windows, and this file says how each is drawn
and captured.

The snapshot carries logical focus once, as `focus.intent` (see
[FOCUS.md](FOCUS.md)); it has no top-level `focused`.

| Key or command | What |
| --- | --- |
| `render` | a key of the snapshot |
| `kind`, `focused`, `title`, `app_name`, `launching`, `world_rect`, `decoration` | keys of every entry of the snapshot's `placements` and of its `windows` |
| `{"Screenshot":…}` | the `ipc` request answers `"reply": null` with one `screenshot` effect |
| `screenshot_result` | a command: the shell's answer to that effect |
| `pending_screenshots` | a count in the `DebugCounters` reply |

## `render`

```json
"render": {
  "background": {"type":"default","path":null,"texture":null,"mirror_tile":false,
                 "transparent_shader":false,"animate_fps":0,"cache_shader":false,
                 "cache_budget_mb":128,"inherit_macos":false,"parallax":false},
  "chrome": {"background":[r,g,b,a],"foreground":[r,g,b,a],"corner_radius":10,
             "title_bar_height":25,"font":"Adwaita Sans","font_size":11,
             "font_weight":"medium","title_align":"center"},
  "outline": {"color":[r,g,b,a],"thickness":1,"opacity":0.5},
  "effects": {"blur_radius":2,"blur_strength":1.1,"animate_blur_fps":20,
              "animation_speed":0.5,"animation_scale":0.95},
  "errors": [],
  "revision": 0
}
```

The values shown are the unconfigured defaults. A normal config load also
activates the Mac wallpaper policy described below. Colours are straight-alpha sRGB, each channel the
config's byte divided by 255.

- `background` is upstream's `[background]` table. `type` is `default` (the
  built-in dot grid), `shader`, `tile`, `wallpaper` or `none`. `path` is the
  shader or image and is `null` for `default` and `none`; `texture` is the
  image a shader samples, or `null`. Both are upstream's parsed values:
  upstream's parser has already replaced a leading `~/` with `$HOME` where
  that variable is set, and left it as written where it is not. Whether a file
  exists is not checked here. `cache_budget_mb` is upstream's memory ceiling
  for its background chunk caches, the baked `cache_shader` chunks and a
  pyramidal TIFF's, in megabytes: core's parsed `u32`, 128 when the file does
  not say, and reported as parsed, 0 included. What the shell does with it is
  `native/desktop/BACKGROUND-NOTES.md`. It is a key of the table like
  the others: a reload that changes it spends the revision every accepted
  reload spends, and a launch file that changes nothing else drawn spends the
  first one for it.
- `background.inherit_macos` and `background.parallax` are Mac adapter fields.
  Both remain false for an unconfigured controller. After a config load,
  inheritance is true unless the file explicitly names a background `type`,
  `path` or `texture`; `parallax` defaults to true and accepts a boolean in
  `[background]`. The shell resolves inherited images per display. Parallax
  affects wallpapers only. See [CONFIG.md](CONFIG.md#macos-wallpaper).
- `chrome` is the part of `[decorations]` that compositor-drawn chrome is
  rasterised from: stand-ins, and the title bar of a `server` window.
  `font` is `null` when the config's is empty. `font_weight` is one of `thin`,
  `extralight`, `light`, `normal`, `medium`, `semibold`, `bold`, `extrabold`,
  `black`: the first spelling upstream's parser accepts for each weight.
  `title_align` is `left` or `center`.
- `outline` is `[output.outline]`: how another output's viewport is outlined.
- `effects` is upstream's `[effects]` table and `errors` the controller's
  messages for the error bar: [EFFECTS.md](EFFECTS.md) is the contract for
  both.
- `revision` tells the shell when to rebuild what it derived from the config:
  the background program, with the shader and image files it read, and the
  chrome style. The shell rebuilds only when it sees a new number. Every
  config load that is accepted after the launch load spends one, whatever the
  file changed and also when it changed nothing: upstream's reload drops its
  background caches unconditionally, so that a shader or image edited on disk
  is read again after `reload-config` or a `touch` of the config file, and the
  new number is what makes the shell do the same. The launch load spends one
  when it activates Mac wallpaper policy or its file differs from the built-in defaults in `[background]`,
  `[decorations]`, `[output.outline]` or `[effects]`, compared as upstream's
  parsed tables; the shell builds its first program whatever the number is. A
  `load` of a scene file leaves it alone. A file that is refused changes no
  table and spends one all the same when its message changes `errors`, at
  launch too, because the error bar is drawn from this block
  ([EFFECTS.md](EFFECTS.md#errors)). It starts at 0 in every run and is not
  saved.

## Placements

Each entry of `placements` keeps `window`, `output`, `screen_rect`, `clip_rect`,
`world_local_crop`, `buffer_crop`, `presentation_settled` and `source` exactly
as before, carries the `pinned`, `widget` and `opacity` of
[RULES.md](RULES.md#wire-contract), and gains the keys below. They describe the
window, not the placement, so every placement of one window carries the same
values, and so does the window's entry in `windows`, next to its `metadata`,
`source`, `widget`, `pinned` and `rule`. A window that no output shows has no
placement, and a screenshot can still reach it: its `windows` entry is where
its decoration is read then.

| Key | Value |
| --- | --- |
| `kind` | `"window"` when a source is bound, `"standin"` when none is: a detached placeholder waiting for its window, or a suspended stand-in ([LIFECYCLE.md](LIFECYCLE.md#three-kinds-of-window)) |
| `focused` | this window holds the logical focus, `snapshot.focus.intent` |
| `title` | the saved title |
| `app_name` | the bundle identifier, see [Differences](#differences-from-upstream) |
| `launching` | a relaunch is pending for this stand-in: it is in `lifecycle.relaunching` |
| `world_rect` | the window's canvas rectangle, the same as its `windows[]` entry. For a pinned window it is the canvas point its pin shows, bookkeeping that follows the camera: a pinned placement is drawn from its `screen_rect`, [below](#layers-and-the-pinned-space) |
| `decoration` | what it is drawn with, below |

```json
"decoration": {"mode":"client","border_width":0,"border_color":[r,g,b,a],
               "border_color_focused":[r,g,b,a],"corner_radius":10,"shadow":true,
               "shadow_radius":14.0,"shadow_color":[0.0,0.0,0.0,0.4],
               "opacity":1.0,"blur":false}
```

Every field is one upstream helper, called with the rule the window mapped
with:

| Field | Upstream |
| --- | --- |
| `mode` | `effective_decoration_mode`: a rule's `decoration`, else `[decorations] default_mode` |
| `border_width` | `effective_border_width`; 0 in `none` mode |
| `border_color`, `border_color_focused` | `effective_border_color`, `effective_border_color_focused`; both are sent, the compositor picks by `focused` |
| `corner_radius` | `effective_corner_radius`; 0 in `none` mode |
| `shadow` | `effective_shadow_enabled`; false in `none` mode |
| `shadow_radius`, `shadow_color` | the constants `DecorationConfig::SHADOW_RADIUS` and `SHADOW_COLOR` |
| `opacity` | `effective_opacity`: a rule's `opacity` or an IPC `Opacity` write's value in both focus states, else 1.0 for a widget, else `[decorations] opacity_focused` or `opacity` by `focused`. Always 1.0 for a stand-in. The same number as the placement's own `opacity`: both keys are one function's answer |
| `blur` | `effective_blur`: a rule's `blur`, else `[decorations] blur`. Always false for a stand-in ([EFFECTS.md](EFFECTS.md#blur)) |

Nothing here matches a rule. A bound window is drawn with the rule it mapped
with, the one its `windows[]` entry reports as `rule`: `[[window_rules]]`
matched by bundle identifier (the rule's `app_id`) and title once, at `attach`,
and kept until the window is gone ([RULES.md](RULES.md#matching)). A window
that changes its title is not matched again, and neither is any window when
the config is reloaded; a reload changes a mapped window's decoration only
through the global `[decorations]` table, for the fields its rule leaves
unset. An IPC `Opacity` write lands in that same rule, so it changes
`decoration.opacity` and `opacity` together, and so does a `[decorations]
opacity` or `opacity_focused` reload for a window with no opacity of its own.
A stand-in carries no rule: it takes its mode, border width, border colours,
corner radius and shadow from the global `[decorations]` table alone, as
upstream resolves a stand-in, which has no client to carry a rule. So a window
whose rule gave it a red border loses that border while it is a stand-in and
has it back when its app's window takes the slot again and maps under its
rule.

A stand-in is opaque. Upstream's stand-in code resolves no opacity: the frame
and the capture both push a stand-in at the literal alpha 1.0, and only the
adoption crossfade lowers it, which the shell plays from a `standin_adopted`
event ([EFFECTS.md](EFFECTS.md#lifecycle-events)) without any key here
changing. So `[decorations] opacity` and `opacity_focused` dim bound windows
and never a stand-in or a
detached placeholder, and neither does the rule or the `Opacity` write of the
window a detached slot is waiting for: `opacity` and `decoration.opacity` are
both 1.0 for every window without a source.

A fullscreen window's helpers are called with `is_fullscreen = true` and its
decoration is bare: [FULLSCREEN.md](FULLSCREEN.md#the-fullscreen-placement).

### The decoration mode on macOS

Upstream decides between client-side and server-side decoration with the
client, over xdg-decoration. There is no such negotiation with a Mac app: a
captured native window already contains its own title bar. So:

- With upstream's default config the mode is `client`, and the window is drawn
  as upstream draws a client-side-decorated window: no compositor title bar;
  the border, the shadow, the corner clip and the opacity around and over the
  captured frame, title bar included.
- The config can say otherwise and is passed on as written. `minimal` draws
  like `client`. `none` turns off border, clip and shadow. `server` asks the
  compositor for its own title bar above the frame, which on a Mac window
  means two title bars; upstream's parser already refuses `server` as the
  global `default_mode` for the same reason on GTK and Electron (it warns and
  uses `client`), so only a window rule can ask for it.
- A stand-in is drawn as upstream draws a stand-in, whatever the mode: the
  bar, the body and the centred label, with the border and the shadow the
  global table gives, at full opacity.

### Layers and the pinned space

`placements` is the one list of what an output draws, bottom to top: its
widgets, its canvas windows, then the windows pinned to it, each group in
stacking order ([RULES.md](RULES.md#wire-contract)). Two keys of a placement
say which of upstream's buckets it belongs to, and the compositor draws the
buckets in that order whatever order it is handed them in:

| Placement | Layer | Rectangle |
| --- | --- | --- |
| `pinned` true | upstream's pinned bucket, above the canvas windows; a pinned widget is here too, as upstream tests the pin first | `screen_rect`: the pin's rectangle in **global screen points**, at the window's own size whatever the camera and the zoom. Less the output's `screen_bounds` origin it is the output-local rectangle the compositor's pinned space takes, drawn at zoom 1 with no camera (upstream's `window_render_transform`: the pin's `screen_pos` at zoom 1.0). `world_rect` must not be projected through the camera for it |
| `widget` true, `pinned` false | upstream's widget bucket, below the canvas windows | `world_rect`, through the camera |
| neither | the normal bucket | `world_rect`, through the camera |

A stand-in is drawn the same way in whichever space its placement is in: a
detached slot that still holds a pin ([RULES.md](RULES.md#persistence)) is a
stand-in at its pin's rectangle. Upstream's dot at the left of a pinned
window's title bar belongs to a compositor-drawn bar, so it shows only on a
pinned window in `server` mode.

### What the shell still decides

The controller reports configured chrome. Three things about how it lands on
screen belong to the compositor's host protocol and are not done here:

- **Coverage.** Upstream draws a window that exactly covers the usable area
  square and without shadow, and one that overhangs it without border as well
  (`DrawnChrome::drawn`). The usable area is the shell's at the moment it
  draws; `decoration` is the configured value before that rule. A pinned
  window's frame is judged where it is drawn, at its screen rectangle and
  zoom 1. Stand-ins are not subject to it.
- **A stand-in's body.** `world_rect` is the placement's whole rectangle, the
  one that is culled and hit-tested. Upstream's stand-in rectangle is its body
  with the bar above it; the body is `standin_body_rect` of `world_rect` for a
  client-decorated origin: `(x, y + title_bar_height, w, max(h -
  title_bar_height, 1))`.
- **Order and culling.** `placements` is bottom to top within each output and
  lists a window only where its rectangle intersects the output: a canvas
  window's projected rectangle, a pinned window's `screen_rect` on the one
  output it is pinned to.

## Screenshots

`msg screenshot` is upstream's request, built by the existing client:

```json
{"Screenshot":{"target":"Viewport","scale":1.0,"path":"/abs/shot.png"}}
```

Upstream answers it after rendering. The controller cannot render, so the
request takes two steps.

**1. The request.** `ipc` runs every check upstream makes before it draws a
pixel, in upstream's order. A refusal is an `Err` reply at once, with no
effect. Otherwise the data is

```json
{"reply":null,"effects":[{"op":"screenshot","target":…,"scale":1.0,"path":"/abs/shot.png",
  "output":1,"region":{"origin":{"x":0.0,"y":0.0},"size":{"width":1000.0,"height":800.0}},
  "width":1000,"height":800}],"dirty":false,"navigation":null}
```

`"reply": null` means there is nothing to write to the client yet. The shell
must not relay it: a host whose relay expects an object in `reply` has to take
the `null` together with the `screenshot` effect, perform the effect, and
write the reply that step 2 returns. The app's shell does.

| Effect key | Value |
| --- | --- |
| `target` | upstream's `ScreenshotTarget` JSON as the client sent it, except that a `Window` selector is resolved: `{"Window":{"window":<id>,"world_rect":<rect>,"opacity":<number>}}`. `opacity` is what the window is captured with: the `opacity` of the rule it mapped with, which is where an IPC `Opacity` write lands too, else 1.0, and 1.0 for a stand-in. Upstream captures an isolated window as itself, not as the focused or unfocused window it is on screen while the command runs |
| `scale` | pixels per canvas unit, as sent |
| `path` | the client's absolute path, as sent. Nothing else may be written |
| `output` | the output the region was read through: the active one for `Viewport`; the one under the rectangle's corner for a `from_screen` region; otherwise the active one as the shell passed it, or `null` |
| `region` | the canvas rectangle to render, top-left origin and Y down, whole numbers: upstream's resolved region |
| `width`, `height` | the pixel size of the PNG: `round(region width × scale)`, `round(region height × scale)` |

`region`, `width` and `height` are the resolved request. The shell should
render exactly them rather than work the rectangle out again: `All` needs
`[zoom] fit_padding` and the rounding is upstream's, and neither is otherwise
visible to it. Upstream's capture, as the compositor port's notes describe it,
renders the region at zoom 1 with the camera at its origin, into a transparent
target, without output outlines; `cmd_screenshot` draws a `Window` target
alone, at the opacity above and without the canvas background, every other
target with the background and every window that is on the canvas.

**Widgets and pinned windows in a capture** follow upstream's
`compose_capture_elements`. A capture is of the canvas, and a screen-pinned
window is not on it: `Viewport`, `All` and `Region` never show one, on any
output, whatever is on the screen (upstream's `window_render_transform` gives
a pinned window no place without an output, and its
[`docs/window-rules.md`](https://github.com/malbiruk/driftwm/blob/df3de27b26c7998e8a460cffd8a4925cbed3a322/docs/window-rules.md) lists canvas screenshots among what a pinned window is excluded from). A
widget is on the canvas and is drawn there, below every other window. `All`
frames the canvas windows and the stand-ins only, as upstream's
`is_canvas_window` filter does: a widget that lies inside that frame is
drawn, and none widens it. A `Window` target captures whichever window the
selector names, alone: a widget like any other window, a pinned window at its
canvas frame, the `world_rect` its pin shows, as upstream renders an isolated
client at its stage position whatever it is. The app's shell reads `widget`
and `pinned` from the snapshot's `windows` for this.

A `wallpaper` background is fixed to the screen, so upstream does not lay it
under the whole region: `wallpaper_dest` in `src/render/capture_background.rs`
places it over the canvas footprint (`output_viewport_rect`) of the output the
region's centre lies on, else of the active output, the region crops it, and
the rest of the capture stays transparent. The app's shell does this from the
snapshot's outputs and the effect's `output`; a bare `Viewport` capture is that
footprint exactly and looks as the screen does.

A background an output draws from a chunk cache is not captured from that
cache. Upstream's capture is a virtual viewport and builds its own background
(`CaptureBackground::prepare` in the same file): a shader baked under
`cache_shader` is rendered live, and a tiled pyramidal TIFF is one level, the
finest of at most 4096 pixels on its longer side, tiled at the full picture's
extent. The app's shell does the same. So a capture is the same file with
`cache_shader` on or off, and for a TIFF larger than 4096 pixels it is softer
than the screen. Nothing in the effect or the result says which was drawn.

The screenshot writer encodes the image, creates any missing parent directories,
then writes the named PNG, following `capture_region_to_png` at the pinned
revision (`src/render/screenshot.rs:117–122`). A non-directory parent reports
`cannot create <parent>: …`; a failure opening or writing the final file reports
`cannot write <path>: …`. As in DriftWM v0.21.0 (`write_png`,
`df3de27b26c7998e8a460cffd8a4925cbed3a322`) the file is written to a new file
beside the target, `.<name>.<pid>-<n>.tmp`, created with `O_EXCL`, and renamed
into place; a failure removes the temporary and leaves what the path held, an
existing file is replaced as a whole, and a symbolic link at the path is
replaced instead of written through. Encoding
and writes run on the existing serial export worker; no parent directories are
created when rendering or encoding fails. `msg screenshot -o -` hands the shell
a file of the client's own to write ([IPC.md](IPC.md#msg-client)).

**2. The result.** When the file is written the shell calls

```json
{"op":"screenshot_result","path":"/abs/shot.png","width":1000,"height":800}
```

and when it could not,

```json
{"op":"screenshot_result","error":"cannot write /abs/shot.png: Permission denied (os error 13)"}
```

The data is `{"reply":<upstream Reply>}`, which the shell writes to the client
as the one reply line: `{"Ok":{"Screenshot":{"path":…,"width":…,"height":…}}}`
or `{"Err":"…"}`.

The controller remembers the path of every effect it has handed out and not
yet had answered. A written result must name one of them, and is answered
once; a failure carries no path and answers the oldest one waiting. A result
for nothing that is waiting, one that is both or neither shape, and a size
outside 1 to 16384 are controller errors: nobody is answered and nothing
changes. The pixel size in the reply is the one the shell reports, not the one
the effect asked for. Up to 64 effects wait; a 65th drops the oldest, so a
shell that never answers cannot grow the list. What is waiting is not saved
and survives `load`.

### Targets

| Target | Region |
| --- | --- |
| `"Viewport"` | the canvas the active output shows: origin at the camera rounded to whole units, size `round(output size / zoom)`, over the whole output and not only its usable area. Upstream's `output_viewport_rect`. A window pinned to that output is on its screen, not on the canvas, and not in the picture |
| `{"Window":{"window":<selector>?}}` | one element, alone, at its rule's opacity or 1.0. No selector is the focused window; a number is an id; a string is a bundle-identifier substring, a bound window before a stand-in. A bound window: its frame rounded to whole units, grown by its border width and, when it casts a shadow, by the shadow radius (14) on every side, plus `title_bar_height` above in `server` mode. Upstream's `window_visual_rect`. A stand-in: its bar and body, grown by the global border width and by no shadow, rounded outward. Upstream's `visual_frame_rect` through `snap_rect_to_rect`. A widget and a pinned window are captured like any other, the pinned one at the canvas frame its pin shows |
| `"All"` | the union of those rectangles over every canvas window (neither a widget nor pinned) and every stand-in, grown by `[zoom] fit_padding` canvas units on every side |
| `{"Region":{x,y,w,h,"from_screen":false}}` | `w` × `h` canvas units centred on the point `(x, y)`, Y up, with upstream's truncating halving: top-left `(x − w/2, −y − h/2)` |
| `{"Region":{x,y,w,h,"from_screen":true}}` | a rectangle in global screen points, top-left origin and Y down. It is read through the output whose `screen_bounds` contain its corner `(x, y)`, else through the active output: origin `round(camera + (corner − output origin) / zoom)`, size `round(w / zoom)`, `round(h / zoom)` |

### Refusals

In the order they are checked. All but the three marked are upstream's texts.

| When | `Err` |
| --- | --- |
| the path is not absolute | `screenshot path must be absolute` |
| the path holds a NUL or is longer than 4096 bytes (not upstream's) | `screenshot path is not a usable file path` |
| the `output` the shell passed is not registered (not upstream's) | `unknown output` |
| `Viewport` without an active output | `no active output to capture` |
| `Window` with nothing to select | `no focused window`, `no window with id <n>`, `no window matching '<text>'` |
| a window whose rounded frame has no area | `window has no capturable area` |
| `All` on an empty canvas | `no windows to capture` |
| `Region` with `w` or `h` not positive | `region width and height must be positive` |
| a `Region` corner past ±1,050,000,000, or a side past 32767 (v0.21.0) | `coordinates must be within ±1050000000`, `sizes must be at most 32767` |
| a `from_screen` region with no output under it and none active | `no output for the screen region` |
| a `from_screen` region whose corner lands past ±1,050,000,000 on the canvas, as zoomed out far (v0.21.0) | `region lies past the canvas range` |
| geometry that does not fit upstream's `i32` (not upstream's, which saturates) | `window geometry exceeds integer range`, `view geometry exceeds integer range` |
| `scale` is not a positive finite number | `scale must be a positive number` |
| the region has no area | `capture region is empty` |
| the pixel size rounds to zero on a side | `capture resolves to zero pixels` |
| the pixel size passes 16384 on a side | `capture <w>x<h>px exceeds the 16384px per-side limit — lower --scale or shrink the region` |

A request that does not decode as upstream's is `invalid request: …`, as for
every `ipc` request.

## Differences from upstream

- **The reply is deferred.** Upstream renders inside the request. Here the
  reply is `null` until the shell has rendered and reported back, and the
  controller never knows whether a file exists.
- **`server` mode is not negotiated**, see above. Nothing here turns off a Mac
  window's own title bar.
- **`app_name` is the bundle identifier.** Upstream labels a stand-in with its
  desktop entry's display name and falls back to the desktop id, which is what
  a bundle identifier is; the controller is told nothing else about an
  application, so the fallback is all it can send, `com.apple.Safari` for
  Safari. Turning the identifier into the application's name is left to the
  shell, which asks the system and shows the identifier for an application
  that is not installed; an `attach` that carried the name would let the
  controller save it with the slot, as upstream saves a stand-in's.
- **`blur` and `[effects]`** are the shell's compositor's to draw from
  `decoration.blur`, `render.effects` and the snapshot's `lifecycle_events`:
  [EFFECTS.md](EFFECTS.md) is their contract, and says what of upstream's
  animations has no counterpart here (a window's move, resize and fit).
- **A reload that finds no file while none was ever accepted** is the built-in
  defaults again and spends a revision like any accepted reload. Upstream's
  reload stops at the read failure. The program the shell rebuilds is the same
  dot grid.
- **A wallpaper in a capture** lies where upstream puts it (above), drawn by
  the app's shell cover-cropped to that footprint as on screen. Upstream's
  capture element samples the whole image across the footprint, which differs
  when the image's aspect is not the output's. With the region's centre on no
  output the shell falls back to the effect's `output`, which for a
  `from_screen` region is the output under the rectangle's corner where
  upstream takes the active one.
- **A slot that still holds a pin, or a widget's rule,** is drawn as a
  stand-in in the pinned space or the widget layer, and is left out of canvas
  captures and of `All`'s frame as a pinned window or a widget is. Upstream
  has no such state: its stand-ins are always on the canvas, are always in a
  capture and always count for `All`. A real stand-in here is on the canvas
  too ([RULES.md](RULES.md#screen-pinned-windows)).
- **A stand-in's rectangle is its whole footprint**, not its body. One shorter
  than the title bar is drawn taller than its rectangle, as upstream's
  one-unit body makes it; a `Window` capture frames what is drawn, while
  hit-testing still uses the rectangle.
- **Windows off an output are not listed for it.** `placements` holds a window
  only where its rectangle intersects the output. Upstream also draws a window
  whose border reaches the output, and a stand-in or server-decorated window
  whose shadow or bar does. The shadow of a window lying just outside an
  output is therefore missing there.
- **Fractional frames.** Upstream's window geometry is whole units. A bound
  window's frame is rounded to the nearest unit before its capture rectangle
  is built, as `State`, `Move` and `Resize` read it; a stand-in's is rounded
  outward, as upstream rounds a stand-in's.
- **`from_screen`** reads global screen points against each output's
  `screen_bounds`, where upstream reads its output layout space against each
  output's layout rectangle.
- **`All`** frames what upstream's does: the clients `is_canvas_window`
  passes, which are neither widgets nor pinned nor fullscreen, and every
  stand-in.
- **Refusals upstream does not have**: an unregistered `output`, an unusable
  path, and geometry outside `i32`, where upstream's casts saturate.
  `no renderer available for capture` and `suspended window is gone` cannot
  happen here. `capture region is empty` is kept and cannot be reached: no
  target resolves to an empty region at a zoom of at most 1.
- **A failed capture has no id.** `screenshot_result` with an `error` answers
  the oldest effect waiting. A shell that renders two captures at once and
  fails the newer first would cross their replies.
- **Tiling.** Upstream renders a capture above 4096 pixels a side in tiles.
  The effect asks for one image of up to 16384; how it is rendered is the
  shell's.

## Verification boundary

`tests/e2e/ipc-limits.sh` exercises the production `msg` client, Unix
socket server, controller C ABI and PNG writer with a synthetic 2×3 image. It
checks nested parent creation, preservation of a non-directory parent, a final
filename already occupied by a directory, existing-file overwrite, PNG dimensions,
and byte-identical `-o -` output with temporary-file cleanup. This starts no
desktop application, renderer, GPU, native window, capture stream or input. It
validates the filesystem and reply contract only, not native image capture or
compositing.

`tests/render_flow.rs` drives the exported C ABI with config files in a
throwaway directory:

- the default `render` block and the default decoration against
  `driftwm-core`'s own `Default` impls and constants, before and after an
  output and a launch config path that names no file, and after an empty file
  loaded as a reload, which spends a revision;
- a reload that changes `[decorations]`, `[output.outline]`, `[effects]` and
  `[background]` in each of its types, one table at a time, with the block and
  the revision after each; an identical reload and a change elsewhere in the
  file, each of which spends a revision and changes nothing else; a file that
  does not parse, which changes `errors` and moves it by one, and a scene
  `load`, which moves nothing; a launch file that names a shader, and the same
  file loaded again;
- `cache_budget_mb`: core's default with no config and under a file that does
  not name it, a reload that changes it alone, which changes that key and
  spends one revision, a reload that changes something else, which leaves it,
  0 and `u32::MAX` as written, a negative value, which is a refused file and
  leaves the budget in force, and at launch a file that changes it alone,
  which spends the first revision, and one that writes the default, which
  spends none;
- the placement keys for a bound window, a window under each kind of rule, a
  detached placeholder and a suspended stand-in (both at opacity 1.0 under a
  config that dims focused and unfocused windows), a relaunching one and the
  window that takes its slot back, with `focused` and a bound window's
  focus-dependent opacity following two focus changes, the same description
  on a second output and in the window list, and the window-list entry of a
  window no output shows;
- a `Screenshot` request for every target, with the region and pixel size
  worked out by hand: a zoomed-out viewport, a fractional camera, a window by
  focus, id and app id, a stand-in, `All`, both `Region` forms, a region read
  through another output, the pixel-size limits, and the capture rectangle
  under a border, a rule, `none`, `server`, an off-grid frame and a stand-in
  shorter than its bar; the capture opacity of a window under a config that
  dims it (1.0 focused or not, its rule's where a rule pins one, 1.0 once it
  is a stand-in);
- every refusal in the table above except `capture region is empty`, which
  cannot be reached, in upstream's order: among them a frame a third of a unit
  wide, which has no capturable area, and a frame and a camera three billion
  units out;
- `screenshot_result` in both shapes, out of order, repeated, malformed, and
  across a scene `load`.

`tests/ipc_flow.rs` keeps two screenshot refusals in its refusal table.
`tests/rules_flow.rs` holds the scenario that crosses this contract with
[RULES.md](RULES.md): a ruled widget, a rule-pinned window and an unruled one
on an output whose origin is the global point (200, 100), at half the zoom.
It checks `kind`, `widget`, `pinned` and the stacking order; the pinned
placement's `screen_rect` at its own size and unmoved by a pan and a zoom
while its `world_rect` and the other two placements follow the camera;
`decoration.opacity` equal to `opacity` for each, in the placement and in the
window list; a window retitled into a rule keeping its decoration; a
`[decorations] opacity` reload spending a revision and changing both keys
while no mapped window is matched again; an IPC `Opacity` write changing both
for the canvas window, the widget and the pinned window, and the opacity and
frame of a `Window` capture of the pinned one; `All` framing the canvas
window alone; and the pinned window's stand-in back on the canvas, under no
rule and opaque.

These are controller scenarios. No pixel is drawn in them and no file is
written: the screenshot effects are requests nobody performs and the results
are typed in by the test. They are not evidence that the compositor draws what
the block describes, that a shader compiles, that a capture stream delivers a
frame, that a PNG has the reported size, or that a client receives the reply.
Upstream's own sources are not executed: the expected rectangles come from
reading the functions named at the top. Of upstream's render code these were
read: the checks that open `capture_region_to_png`; in `src/render/mod.rs`,
the two `push_suspended_element` calls (alpha 1.0 in the frame and in a
capture) and the opacity of an isolated window in
`compose_capture_elements`; in `src/render/suspended.rs`, that a stand-in's
mode, border, radius, colours and shadow come from the helpers with no rule
and that nothing there looks an opacity up; and in
`src/render/capture_background.rs`, `wallpaper_dest` and the wallpaper arm of
`tile_elements`, and for the background caches `prepare`, `shader_bg` and
`tiff_tile_bg`; and, for widgets and pinned windows, the `All` arm of
`resolve_screenshot_region`, the `widgets` bucket and the
`window_render_transform` call of `compose_capture_elements`, and in
`compose_frame` the choice of bucket and the frame coverage is judged on. The
rest of what a capture composes, and how it stitches tiles, was not.

Against the shell, which adopts the compositor and performs the effect, this
contract was run on 2026-10-09 in three short `--windowed` launches of the
built app on a private scene, config and socket, with three seeded
placeholders and no Screen Recording access. Seen there, in the PNGs
`msg screenshot` wrote and the replies it printed: every target with the pixel
size the effect names and the windows where the region puts them; the
`render` block's background in all five types and the chrome keys, each
adopted after a config rewrite without a restart; a stand-in's `kind`,
`focused`, `app_name`, `launching` and `decoration` as drawn (border width and
both colours, corner radius, shadow); the refusals for a scale of 0, an empty
region, an unknown id and the pixel limit reaching the client as `Err`; and
`screenshot_result` carrying a write failure back as `cannot write …: … (os
error N)`. Their output also held two defects that a review found in it
afterwards, and the review's own launches a third; all three are fixed since:
a stand-in dimmed by `[decorations] opacity`, a `-o -` relay cut short at its
last newline with exit status 0, and a shader file edited behind an unchanged
config not read again.

On 2026-10-10, after those fixes and the wallpaper rule above, the rebuilt app
was launched twice more the same way, for 4 and 12 seconds. Seen there: with
`[decorations] opacity = 0.5`, the unfocused stand-ins at alpha 255 in a
`window` capture and all three bodies the same `#303030` in `all`; `-o -`
relaying bytes equal to a file capture of the same target (`cmp`), with no
temporary file left; a shader file replaced behind an unchanged config and
picked up by `msg action reload-config` alone, a broken one falling back to
the dot grid after a `touch` of the config, and the repaired one drawn again
after another reload, byte for byte the first capture; and a four-quadrant
wallpaper lying only over the view's footprint in `region`, `all` and
`--from-screen` captures. Not seen in any launch, because no window had a
source and there was one output: `kind` `"window"`, a window rule,
`default_mode`, `title`, `outline`, a second `output`, and so the capture
opacity of a live window and the wallpaper footprint of another output. The
list of what was observed, pixel by pixel, is in
[native/desktop/README.md](../../native/desktop/README.md).

Also on 2026-10-10, once this contract and [RULES.md](RULES.md) were one
build, two things were run; neither left saved evidence.
[native/desktop/README.md](../../native/desktop/README.md)
has the numbers.

- **The drawing path, offscreen.** A throwaway tool outside the repository
  linked the shell's `canvas-renderer.m` and the compositor against this
  controller and fed the renderer the controller's own snapshots: one output
  whose origin is the global point (300, 200), a ruled widget, a rule-pinned
  window and an ordinary window, each bound to a synthetic source with a
  plain-coloured buffer. The frame each snapshot produced was read back from
  the output's compositor layer. Seen there: the pinned window at the same
  output-local rectangle and size at zoom 0.5, after a pan and at zoom 1,
  while the other two moved and scaled; the widget showing only where the
  canvas window did not cover it; the pinned window over the canvas window;
  an `Opacity` write of 0.5 on the canvas window and on the pinned one as the
  blend it should give over what lies beneath each; and the pinned window's
  detached slot as an opaque stand-in at the pin's rectangle at both zooms.
  The controller's own screenshot effects, performed by the same renderer:
  `Viewport`, `All` and a `Region` without the pinned window and with the
  widget under the canvas window, `All` framed by the canvas window alone;
  the pinned window alone at its written opacity; the widget alone.
- **The app.** Two `--windowed` launches of the built app on a private scene,
  config and socket, 3 and 1 seconds, with no Screen Recording access, so
  every window was a placeholder. The first repeated the earlier list on the
  merged build (viewport, `zoom-to-fit`, a `window` and a `region` target,
  `-o -` equal to a file capture, a missing shader falling back with its
  reason on stderr). The second loaded a scene whose `pins` held one of the
  three placeholders: `state` listed it under `pinned`, unchanged by a pan
  and at zoom 0.5; none of three viewport captures showed it, where the
  screen draws it over another placeholder; a `window` capture showed it
  alone and `all` framed the other two.

Not seen: the app's own panel on a display, so the layers and the pinned
space as the app presents them (only the offscreen tool drew them); a window
with a real source in the app; a pinned window in `server` mode and its dot;
a second output; a widget in the app.

Last, the same day, this contract was joined to the shell's later work: the
navigation coordinator's frame, hot corners, the event stream, camera motion
and trackpad gestures. The snapshot keeps every key of both sides (`render`
beside `keyboard_layout` and `trackpad`, the placement keys beside the
motion keys of `navigation`); the shell's one redraw adopts `render` and
publishes the State; and a `Screenshot` is rendered and answered within its
own request while `subscribe` connections stay open. Three more launches of
the built app
([the numbers](../../native/desktop/README.md))
repeated the viewport, `zoom-to-fit`, `window`, `region`, `-o -` and
missing-shader results, and added: the focused border colour on a stand-in a
window navigation action had just focused; a pinned placeholder absent from
viewport captures and alone in a `window` capture on that build; three
screenshots answered on other connections while a subscriber received the
frames of a flight; and two captures of an animated shader half a second
apart differing while a subscriber received nothing. Still not seen: the
panel on a display, and so the frame timer's own redraws of an animated
background.

With the background caches, the same day, the app built from this tree was
launched five more times the same way
([the numbers](../../native/desktop/README.md)).
Of this contract that showed: `cache_budget_mb` reaching the shell's caches,
since the lines they print on stderr for a view over the budget carried the
number each config named (1, 40, 8, 2 and the default 128), adopted from a
config rewrite without a restart; and the capture rule above, in viewport
captures that were byte-identical with `cache_shader` on and off, in a
4096×2048 pyramidal TIFF captured byte for byte as the same picture's PNG
tile, and in a 16384×8192 one captured as its 4096 level. It did not show
what either cache draws: no capture can, and the panel was not looked at.

The caches landed on the tree that also holds the display-link frame timer
and the tap bindings, and the app built from that was launched four more
times the same way (the same section). Of this contract that showed again:
`cache_budget_mb` reaching the shell's caches, in their stderr lines for 1,
for 2 and for the default 128 and in none under 256; a capture with
`cache_shader = true` that was the same file as one with it off; and a
missing shader and a stripped TIFF captured as the dot grid, an 8192×4096
pyramid with its picture. What a cache draws it showed no more than before.
