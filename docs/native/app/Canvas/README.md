# Canvas module

How the canvas is drawn: the Metal compositor, the canvas background renderer, screenshots and the tiled TIFF source (code in `native/app/Canvas`). Beside this file are [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md), the Metal compositor, and [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md), the canvas background renderer. The parity contract, [docs/parity/README.md](../../../parity/README.md), keeps what this document describes at `implemented_unverified` or below.

## Rendering

In a normal run, `--windowed` included, the canvas is drawn the way DriftWM
draws it. Each output is one Metal layer that draws its whole frame: the
`[background]` (the default dot grid, a shader, a tile, a wallpaper or none),
the outlines of the other outputs' viewports from `[output.outline]`, and every
window bottom to top with upstream's shadow, border, corner clip and opacity
from `[decorations]` and the rule it reached the canvas with, the focused one
with `border_color_focused`: widgets first, then the canvas windows, then the
windows pinned to that display's screen
([Window rules](../Windows/README.md#window-rules-widgets-and-pinned-windows)). A window without a live source is a compositor-drawn
stand-in: title bar with its close glyph, body, and the application's name,
followed by ` launching…` while a relaunch is pending.

What is on screen: the canvas is DriftWM's dot grid
on black (or whatever `[background]` names); a
captured window has a soft shadow and its corners are clipped to
`[decorations] corner_radius`, 10 by default; a placeholder is a dark rounded
panel with a close glyph and the application's name; and `[decorations]`, `[background]`,
`[output.outline]` and the decoration keys of `[[window_rules]]` are applied
([Settings](../../user-guide.md#settings)): the three tables on the next reload of the config
file, a rule to the windows that reach the canvas after it, since a window
keeps the rule it arrived with. All of this is what the code draws and what `msg screenshot` showed for
stand-ins; a captured window and the panel on a display
have not been seen.

The drawing code is the compositor port in `compositor.{h,m}` and
`background.{h,m}`: upstream's shaders and frame composition translated to
Metal, built and checked outside this repository and carried in unchanged
apart from one provenance line each. Its headers name the upstream files it
derives from, and its own notes came with it: where those four files say
`NOTES.md`, the compositor's is [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md)
(upstream file hashes, the host protocol, every deviation, what was verified
and how) and the background's is [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md).
`DWCanvasRenderer.{h,m}` is the host: it turns the controller's snapshot into
the compositor's frame description. What the snapshot carries is
[`docs/crates/desktop/RENDER.md`](../../../crates/desktop/RENDER.md).

- **Frame.** Camera, zoom and size are the output's `camera`, `zoom` and
  `screen_bounds`; the scale is the panel's backing scale. Every element is
  given at its canvas rectangle (`world_rect`), and the compositor subtracts
  the camera itself, as upstream does. No native window geometry is read.
- **Layers.** The controller lists a display's placements bottom to top:
  widgets, canvas windows, pinned windows. A placement that says `widget` goes
  into the compositor's widget layer and one that says `pinned` into its
  pinned layer, a pinned widget with the pinned ones as upstream; the
  compositor draws the three layers in that order and keeps the controller's
  order inside each. A pinned window is the one element not given at a canvas
  rectangle: it is given at the placement's `screen_rect`, less the display's
  origin, in the compositor's pinned space, which draws it at zoom 1 with no
  camera, so it keeps its place and its own size while the canvas pans and
  zooms beneath it. Its canvas rectangle is never projected. Upstream's dot at
  the left of a pinned window's title bar is drawn where the compositor draws
  the bar, that is under a `server` rule only.
- **Opacity.** What the controller reports for a window, a rule's value, one
  set with `msg opacity` or the `[decorations]` default for its focus, is part
  of its decoration and multiplies every pass of the element.
- **Decoration mode.** A captured Mac window already draws its own title bar,
  so it is decorated as upstream decorates a client-side-decorated window: no
  compositor title bar; border, shadow, corner clip and opacity around the
  whole captured frame. A window rule can still ask for `server` (a second,
  compositor-drawn bar above the frame), `minimal` or `none`.
- **Coverage.** Upstream's `DrawnChrome` rule is applied per output: a window
  whose frame exactly covers the output is drawn square and without shadow,
  one that overhangs it without border as well. The usable area is the whole
  output, which in a normal run is the whole display. A pinned
  window is judged where it is drawn, at its screen rectangle. A window's
  blur is not subject to it.
- **Stand-ins.** A stand-in's bar and body together take the window's
  rectangle (upstream's `standin_body_rect` for a client-decorated window). It
  wears the global `[decorations]` table alone, no window rule, and it is
  always opaque, as upstream's: `opacity` and `opacity_focused` dim windows,
  not stand-ins. Its label is
  the application's name as the Finder shows it, looked up once from the
  bundle identifier; an application that is not installed shows the
  identifier. ⌃⌥-click dismisses a placeholder while no binding claims that press, and the
  placeholder shrinks and fades as any dismissed stand-in does
  ([below](#blur-window-animations-and-the-error-bar)). A placeholder
  whose slot still holds a saved pin is drawn as a stand-in at the pin's
  rectangle, in the pinned layer.
- **Streams.** A source keeps the latest pixel buffer of its stream and the
  compositor samples it; nothing is enqueued into a display layer. A new frame
  redraws only the outputs that show that window, once per refresh of the
  display however many frames arrived in it (Frame pacing, below), and
  nothing is drawn while nothing changes. A complete frame whose
  `SCStreamFrameInfoDirtyRects` is there and empty changed nothing: it is
  not kept and redraws nothing, once the window has a picture. A frame that
  carries no such list is kept as before, and so are the first complete frame
  of a stream that was just started or given a new size and a frame whose
  size is not the kept picture's: the picture held then is from before the
  stream stopped or the window was resized. Not observed: whether
  ScreenCaptureKit delivers such frames at all could not be seen from a
  process without Screen Recording access.
  Streams are configured with `colorSpaceName = sRGB`, which the compositor's
  colour handling requires, and a queue depth of 5 instead of 3, because the
  compositor holds the current buffer and briefly the one before it. When
  capture on demand stops a stream, the last picture stays, so a window whose
  placement returns is not blank until its stream delivers again. A window
  that has never delivered a frame is the chrome background colour inside its
  border and shadow.
  Leaving the desktop session stops root and child captures in both backends.
  Overlay mode retains its bindings and current pictures; returning restarts
  managed sources through visibility demand. Unmanaged canvases resume their
  existing healthy sources directly, and failed sources use capture recovery.
- **Frame pacing.** The scene is gone through once per refresh of the
  display, by the [frame timer](#rendering) below, and at no other moment
  while that timer runs. Every stream hands its frames to the main queue,
  each on a turn of its own and at a moment of its own, so a picture, an
  animation's step or a decoded chunk only marks its outputs and asks for a frame; the timer's frame
  describes the camera, marks the animations and then flushes once, so a
  camera frame and a window's picture of the same refresh are one draw with
  both in it. A description made outside a frame (the idle poll, a socket
  command, a pan from the trackpad) is left to the next frame too while the
  timer is running, and is drawn at once when it is not, as before. Drawn at
  once whatever the timer does: a frame whose output is new or whose layer
  changed its place, size or scale, which is presented inside the
  transaction that moves the layer (the launch's first frame, a panel
  resized, the panels rebuilt after a display change); and everything while
  no frame is coming: the quit-pending loop, and a timer that has not called
  back for a quarter of a second because its display is asleep. A timer
  silent for a second is replaced by the next change that wants one.
  Only the timer's own flush leaves a frame to its command buffer to
  present at the refresh being served, with nothing waiting for it
  (`presentsWithTransaction` is set per frame). Every frame drawn at once is
  presented inside the transaction, as all were before: no display link is
  known to be refreshing then, and a drawable left to a refresh that does
  not come would not return to the layer's pool. A frame that got no
  drawable stays owed and is tried again by the next flush. While the timer
  serves no camera motion its frames tell cursor edge pan of the pointer
  only when it has moved; the idle poll, which goes on beside it, reports a
  pointer at rest.
- **Config reload.** The background program, the chrome style, the outline
  settings, `[effects]` and the error bar's messages are rebuilt when the
  snapshot's `render.revision` changes and at no other time. The controller
  moves it on every config reload it accepts, also
  one that changed nothing, so a shader, tile, wallpaper or texture file
  edited on disk is read again after `msg action reload-config`, the
  `reload-config` binding or a `touch` of the config file, as upstream reads
  it again on every reload. A file that fails to parse changes no table, but
  its message is new to the error bar, so the revision moves once and the same
  tables are built again; the same failure a second time rebuilds nothing. A
  shader that does not compile or a file that is missing falls back as
  upstream does, to the dot grid; the reason is written to stderr and shown in
the [error bar](#blur-window-animations-and-the-error-bar) until a reload builds a program without one.
- **Autorelease pools.** Metal hands out autoreleased drawables and encoder
  contexts. Each layer update is drawn inside a pool of its own, and the main
  loop of a normal run has one per turn, so a redraw issued from a poll, the
  launch's first frame or the quit-pending loop frees what it made.
- **Animated backgrounds and the frame timer.** There is one frame timer, and
  it runs at the display's refresh rate: a display link
  (`DWFrameDriver.{h,m}`, `-[NSScreen displayLinkWithTarget:selector:]`) of the
  fastest screen a canvas panel is on, so 120 Hz on a ProMotion display and
  60 Hz on a 60 Hz one, where it was an `NSTimer` at 60 Hz whatever the
  display. One link serves every panel, so the controller is ticked once a
  frame however many displays there are. Five things keep it running:
  windows' pictures as their streams deliver them, and for a quarter of a
  second after the last, so that a display link is not made and ended
  between two frames of a video;
  [camera motion](../Navigation/README.md#camera-motion) (a flight, a drift, an edge pan), a shader
  background that reads `u_time`, redrawn at that rate capped by `animate_fps`
  and only while a panel that shows it is open, a background
  [chunk cache](#background-caches) that is still filling, given one frame a
  tick until nothing is pending, and a window that opens or
  leaves (an open or close animation, a stand-in's fade,
  [below](#blur-window-animations-and-the-error-bar)), drawn on every tick.
  It stops when none of the five is left, so the frames of an opening window
  end with its animation, and the link is made when frames are first wanted
  and invalidated when they stop being: no display callback is asked for
  while nothing needs one. While a background or an animation alone keeps it
  running it ticks no camera and watches no hot corner: the idle poll goes on
  doing both every 80 ms, exactly as when the timer is stopped, and regains
  the display's rate for the camera when it finds motion. A display link
  calls back only while its display refreshes; camera motion it has not
  served for a quarter of a second (a display asleep) is ticked by the poll
  instead, at the poll's pace, so a flight still arrives. The
  pointer's part of a frame is the one thing such a frame still does: the
  waiting [hover](../Navigation/README.md#pointer-motion-sloppy-focus-and-pick-mode) and cursor edge
  pan's pointer report go out with it, since no other timer sends a hover
  while this one runs.

### Blur, window animations and the error bar

DriftWM's visual effects, drawn in a normal run by the same compositor. There
is no flag, key or command: the effects follow the config file and what
windows do. What the controller reports for them is
[`docs/crates/desktop/EFFECTS.md`](../../../crates/desktop/EFFECTS.md); how the
compositor draws them is [COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md), sections
17 to 25, whose host protocol (section 18) `DWCanvasRenderer` follows.
**None of this has been seen in the app's own panel**: it was drawn offscreen
by the app's renderer from this controller's snapshots, and the app was run
through the same events without anyone looking at it.

What is on screen:

- **Blur.** With `[decorations] blur = true` every window, and with a window
  rule's `blur = true` that window whatever the table says, has what lies
  beneath it frosted: upstream's blur of `[effects] blur_radius` passes (2)
  spread by `blur_strength` (1.1), cut to the window's shape. The frost is
  drawn at full strength under the window and shows only where the window
  lets it through: under one made translucent by `[decorations] opacity` or
  `opacity_focused`, a rule's `opacity` or `msg opacity`, or through content
  that is itself translucent. An opaque window with blur pays for a frost
  nobody sees, as upstream. A stand-in is never frosted, as upstream's. Over
  an animated background the frost is refreshed `animate_blur_fps` times a
  second (20; 0 keeps what it first captured; values above 144 are 144).
- **A window opens.** A window that appears by itself once the launch pass is
  over grows from `[effects] animation_scale` (0.95) to its size and fades in,
  upstream's open animation at `animation_speed` (0.5: about 0.11 seconds;
  nearer 0 is slower, 1 is instant and plays nothing). A widget and a
  `focus_on_open = false` window open the same way. It begins with the first
  picture the window's stream delivers: until then, and for a second at most,
  the window is not drawn at all.
  A window whose rule
  names a `size` is asked for that size as it appears
  ([Window sizing actions](../Navigation/README.md#window-sizing-actions)); its opening waits
  until the size request is answered. Its opening waits for it too, as
  upstream's window opens at the size its rule gave it: the second for its
  first picture starts when the resize has been answered, done or refused,
  and a picture that arrives earlier, of the size it is leaving, starts
  nothing. A resize that is never answered holds the window back for ten
  seconds at most.
- **A window closes.** Its last picture, with border and shadow, shrinks to
  `animation_scale` and fades out where it stood, above the other canvas
  windows and below the pinned ones. When the close leaves a stand-in
  (`suspend_on_close`, `suspend-window`) the picture fades in place over the
  stand-in instead. Of several windows closing at once the one that began
  first is on top, as upstream stacks them. A window that was translucent is
  opaque for the length of its close, as upstream's snapshot is.
- **A stand-in leaves.** Dismissed by `close-window`, `suspend-window`,
  `Infinify msg close` or a ⌃⌥-click on it, it shrinks and fades. When the
  window of a relaunch takes its slot, it fades without moving over that
  window, from the window's first picture (a second at most).
- **The error bar.** A problem in the config file, and a background that fell
  back, are written along the bottom of every display: one line of white
  monospace on a black strip 23 points high, the config's message first, then
  the background's, joined by a bullet and cut with an ellipsis where the line
  is longer than the display. The config's message is upstream's:
  `config: failed to read <path>: <reason>`, `config error: <the TOML error>`
  with its several lines run into one, or one warning, the first of them in
  sorted order, followed by ` (+N more)`. It goes when a later load is clean. The bar is a picture only:
  a click on it reaches whatever is beneath. A problem in the config file is
  shown there and nowhere else on screen, as upstream shows it, and stderr has
  every message of the load, its
  warnings in the same sorted order, so the first line there is the one the
  bar names. A background that fell back is named on stderr as well.

What plays nothing, by upstream's rules or by this port's:

- the windows the launch pass puts on the canvas, a window that takes its own
  saved slot back at any time (a minimized window shown again, a capture that
  recovered), and a window attached from the chooser: none of them opened
  here. Without Screen Recording access or with `--manual` nothing ever opens;
- a close or a dismissal that no display was drawing, a window that never had
  a picture, and everything at `animation_speed = 1`;

Limits the owner will notice or should know of:

- A new window is invisible until its first picture, for up to a second, and
  takes clicks at its place meanwhile. One that is being resized to its
  rule's `size` is invisible for as long as
  that takes and a second more at most; a click at its place is taken or
  refused as for any window being resized, whether or not it is drawn.
- A background that fell back is shown in the bar and written to stderr. A
  problem in the config file is the bar's alone on screen; one about bindings
  that could not be registered, a `--super` chord the controller rejects and
  a load it refuses outright are lines on stderr alone. The app
  has been launched with a config that has two unknown actions and reloaded: stderr had the two
  warnings at every load and nothing else for them, but nobody looked at the
  panel, so the bar itself is compiled and read only.
- With several warnings, the one the bar names is the first of them in sorted
  (byte) order, the same at every load of one file, and stderr lists them in
  that order. That choice is this port's: upstream names the parser's first
  and logs them as the parser returns them, and for unknown actions in
  `[keybindings]` the parser's order is not stable from one load of the same
  file to the next (the first of this tree's runs still printed them in the
  parser's order, and the two lines changed places between loads). For a
  table the parser reads in a fixed order the bar can so name another warning
  than upstream's does.
- A file that is refused now builds the background program again once, a
  shader compile included, because the bar's message travels with the same
  revision; upstream's failed reload redraws the bar only.
- Upstream's third error source, a keyboard layout that xkb refuses, does not
  exist: macOS owns the layouts.
- Each display bakes its own closing snapshot at upstream's density, where
  upstream shares one; upstream's refusal to fade in pixels more than a second
  old has no separate test, since what is baked is what the last frame showed.
- Blur costs memory per blurred window (a frost and a mask of the window's
  size on screen, and two padded copies while it keeps being recomputed) and
  a blur of the backdrop whenever something beneath the window changes;
  COMPOSITOR-NOTES 18.1 and 24 have the numbers.
- A screenshot holds no frost, as upstream's screenshot composer omits blur,
  and no closing snapshot, stand-in fade or error bar; a window that is
  opening is captured as the plain window. Only the first is stated by the
  port's notes; the other two were left out because a capture is of the
  canvas, and upstream's capture code was not read again for them.

### Screenshots

`Infinify msg screenshot` renders the canvas offscreen with the same compositor
and writes a PNG, upstream's `screenshot`: the active output's view by default,
`window` for one window alone on transparency with its shadow, `all` for every
window framed by `[zoom] fit_padding`, `region` for a canvas rectangle or, with
`--from-screen`, a rectangle in screen points. `--scale` is pixels per canvas
unit, whatever the zoom is. The controller resolves the region and refuses what
upstream refuses; the shell renders it at zoom 1 into a transparent target,
without output outlines and, for `window`, without the background, and reports
the size of the image it wrote. A window that is on no output is drawn from the
last picture its stream delivered, or as the placeholder fill. A `window`
capture of a live window is framed with room for its shadow, as upstream's is,
and drawn at its rule's `opacity`, else opaque, whatever `[decorations]
opacity` makes of it on screen: upstream captures an isolated window as
itself. One of a stand-in is framed at its border, as upstream frames a
stand-in, so only the shadow behind its rounded corners is in the picture.
A capture is of the canvas, as upstream's is, without the frost of a blurred
window, a window animation or the error bar
([above](#blur-window-animations-and-the-error-bar)). A window pinned to the screen is
not on it, so the view, `all` and `region` never show one, also when it covers
half the panel; `window` captures a pinned window alone, at the canvas frame
its pin shows. A widget is drawn below the other windows, and `all` frames the
canvas windows and stand-ins without counting widgets.
A `wallpaper` background is fixed to the screen, so in a capture it lies over
the canvas footprint of the output the region's centre is on, else of the
active output, cropped by the region, and the rest of the picture is
transparent, as upstream's `wallpaper_dest` places it; the bare viewport
capture is that footprint and looks as the screen does. `-o -` relays the PNG
to stdout through a temporary file, as upstream's client does; with no `-o`
the file is `infinify-screenshot-<time>.png` in the client's directory.

```sh
Infinify msg screenshot -o ~/canvas.png                 # what the active view shows
Infinify msg screenshot all --scale 0.5 -o ~/all.png    # every window, half size
Infinify msg screenshot window Safari -o ~/safari.png   # one window on transparency
Infinify msg screenshot region -1000 -500 2000 1000     # a canvas rectangle, centre and Y up
```

Differences from upstream: the file is the only thing written, so a path whose
directory does not exist is refused (`cannot write …: No such file or
directory (os error 2)`) where upstream creates the directories; one image is
rendered in one pass, up to upstream's 16384 pixels a side, where upstream
tiles; a wallpaper is cover-cropped to its output's
footprint as on screen, where upstream's capture element samples the whole
image across it (the two differ when the image's aspect is not the output's),
and with the region's centre on no output the footprint is that of the
effect's output, which for `--from-screen` is the output under the rectangle's
corner where upstream takes the active one.

### Background caches

Two of DriftWM's backgrounds are drawn from textures made in advance, in every
normal launch: one cache per output, each bounded by `[background]
cache_budget_mb` (128 by default), least recently shown chunk out first. Both
are the background module's ([BACKGROUND-NOTES.md](BACKGROUND-NOTES.md),
section 17, which lists every difference from upstream). There is no flag,
command or control: two config keys act, and a `.tif` tile path draws the
picture. In the app itself neither cache's
picture has been looked at.

- **`cache_shader = true`** bakes a static shader, one that declares
  `u_camera` and neither `u_time` nor `u_zoom`, into canvas-space chunks of
  1024 canvas units and pans those instead of running the shader for every
  frame. Any other shader, a textured one and any under `transparent_shader`
  renders live as before, silently. The baked picture is the live one, to
  within one level on a few pixels, at zoom 1, 0.5, 0.25 … with the camera on
  the baked level's own grid (whole canvas units at zoom 1); elsewhere it is
  that level shifted by under a pixel, or between those zooms the next
  coarser level stretched, softer, and thin features such as the dot grid's
  dots fade: that is upstream's bake. A shader that moves with the camera at
  any rate but 1:1 bakes wrong, upstream's too.
- **On a Retina display the default budget is too small for it.** A chunk is
  4.2 MB on a 1x display and 16.8 MB on a 2x one. A view that lies across the
  canvas origin on both axes, which the home view does, needs four chunks of
  the coarse cover and four of the sharp level at zoom 1: 134.6 MB against
  the 134.2 MB that `cache_budget_mb = 128` is. Such a view shows the coarse
  cover alone, one texel for every 64 canvas units, which is a blur, and
  stderr says `shader-bake: cache_budget_mb too low for this view (128 MB
  working set > 128 MB budget); showing coarse cover only. Raise
  cache_budget_mb for sharp detail.` This is upstream's arithmetic at scale
  2, not a fault of the port, and `cache_budget_mb = 256` or more is the
  setting to pair `cache_shader` with here. Nothing appears on the error bar for it, as upstream shows nothing. A budget below one
  cover chunk draws the shader live instead, with a line of this port's.
- **`type = "tile"` with a `.tif` / `.tiff` path** is DriftWM's gigapixel
  wallpaper: a tiled pyramidal TIFF (8-bit RGB or RGBA; `vips tiffsave in.jpg
  out.tif --tile --pyramid --bigtiff --compression=deflate`, or `tiffcp -t`
  over one file per level) of any size, centred on the canvas origin and
  repeating. Only the chunks in view are decoded, off the main thread, from
  the level the zoom calls for; until a chunk is ready its place shows the
  coarse level that is always loaded (the finest of at most 4096 pixels,
  which is not counted against the budget). The level follows the zoom alone,
  as upstream's: on a Retina display the picture at zoom 1 is the full
  resolution magnified twice, and at zoom 0.5 the half-size level where the
  full one would be 1:1. A file that is stripped, planar or not 8-bit RGB, or
  that cannot be opened, falls back to the dot grid with upstream's reason on
  stderr and the error bar. A file with one tiled level and
  no pyramid is accepted, as upstream's code accepts it. `mirror_tile` does
  not apply. A budget too small for the view keeps the coarser levels that
  fit, with one line on stderr.
- **While a cache fills** its display is redrawn by the
  [frame timer](#rendering), one frame a tick, and each frame does upstream's
  share of the work and no more: two bakes, sixteen on the frame the level
  changes, eight uploads. The shares are per frame and are not scaled to the
  rate, as upstream's are per frame of its output: on a 120 Hz display a view
  of cells never shown is sharp in half the time it takes at 60 Hz, as in
  DriftWM. The timer is started by the description whose draw left chunks
  pending and ends itself on the tick after a frame that left none; while
  nothing is pending nothing is drawn. A display that has already drawn since
  the last tick is not drawn again by it: during a flight the camera's frame
  is the tick's frame, and a chunk decoded off the main thread redraws its
  display once when it arrives. One timer follows the fastest display, so
  beside a faster display a slower one's cache is offered frames at the
  faster rate, where upstream gives each output its own.
- **A blurred window over either cache** has its frost recomputed in the
  frame a chunk is baked or arrives, as upstream refreshes it when the
  background's elements change, so the frost does not stay a blur of the
  coarse picture once the background behind it has sharpened.
- **`msg screenshot`** draws neither cache, as upstream's capture does not: a
  baked shader is rendered live, and a pyramidal TIFF from its finest level of
  at most 4096 pixels, tiled at the full picture's extent. For a picture
  larger than that the capture is softer than the display's, at the default
  `--scale 1` already: a 16384-pixel picture is captured from a level a
  quarter its size. No capture therefore shows what either cache draws.

### What is not drawn, and other limits

- Move and resize animations, and the transitions into and out of
  [fullscreen](../Navigation/README.md#fullscreen): a fullscreen window is drawn alone on its
  display from the moment it is asked, and its exit is immediate. Blur, the
  open and close animations and the error bar are drawn
  ([above](#blur-window-animations-and-the-error-bar)), on a fullscreen
  display as [its section](../Navigation/README.md#what-a-fullscreen-display-shows) says.
- A wallpaper is a PNG or JPEG, and so is a tile unless it is a tiled
  pyramidal TIFF ([Background caches](#background-caches)).
- A stand-in's title bar carries no text, as upstream's; its label is the
  application's name, never the window's title. Text is rasterised by CoreText
  in the configured font, or the system font when it is not installed
  (`Adwaita Sans` usually is not).
- An output draws a window only while the window's own rectangle reaches it.
  The shadow or border of a window lying just outside an output is missing
  there, where upstream would still draw it.
- A window rule asking for `decoration = "server"` gets a compositor title bar
  above the captured frame, which already has the application's own.
- The application name of a stand-in is looked up once per run: an application
  installed while Infinify runs shows its bundle identifier until a restart.
- Every managed window that was ever shown keeps one window-sized buffer, its
  last picture, until it closes or the canvas closes.
- An animated background keeps the frame timer running, at the display's
  refresh rate, while its panel is open, also when other windows cover the
  panel completely.
- A shader's compile error is several lines long. All of it goes to stderr;
  the error bar runs the lines into one and cuts it at the display's width.

## TIFF failures

The long form is in
[BACKGROUND-NOTES.md](BACKGROUND-NOTES.md#1710-a-file-that-cannot-be-decoded-is-an-error-2026-10-30).

**A TIFF that cannot be read is an error and the dot grid, never an abort.** The tile reader (`IFBGTiffSource.m`) handed a failed
tile's message to its caller from inside an `@autoreleasepool`, so any failed block read ended the process with `EXC_BAD_ACCESS`; it
also decoded a tile of any declared size and a level of any size whole. DriftWM v0.21.0's `whole_lod` and `MAX_WHOLE_LOD_DIM` are
ported (`IFBGTiffWholeLevel`), a tile of more than 256 MiB of decoded samples is refused, and an exception under a read is an error.
`tests/e2e/background-tiff.sh` (`IFBGTiffSourceTests.m`) runs 59 crafted files, the program-level fallback and 6000 fixed-seed
mutations (a one-off 150,000 as well): none crashed or hung. Corrupt compressed data is still not detected (BACKGROUND-NOTES.md 17.8 item 9). Run on the host in memory; not in
the guest or on the owner's Mac.
