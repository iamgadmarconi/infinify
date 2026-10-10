# Infinify compositor — port notes

> Carried into `native/desktop/` with `compositor.{h,m}` as the standalone port's own notes, unchanged apart from this paragraph. Where `compositor.h` and `compositor.m` say `NOTES.md` they mean this file; where `background.h` and `background.m` say it they mean [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md). The notes were written before the module was adopted: `comprender.m`, `build.sh`, `scenes/`, `assets/`, `out/` and `verify/` were not carried in, "the shell" is the shell as it drew before adoption, and section 3 is the protocol `canvas-renderer.m` now follows. What the adopted module was run with is in [README.md](README.md#rendering).

A standalone Metal port of DriftWM's per-output frame composition: canvas
background, outlines of other outputs' viewports, and every window with its
shadow, border, rounded and clipped content, opacity and (optionally) a
compositor-drawn title bar, plus the stand-ins upstream draws for suspended
windows. One renderer per output draws the whole frame; the same code renders
a frame offscreen to a PNG.

Upstream: DriftWM, GPL-3.0-or-later, commit
`352333a8fa1b22171492d4b71a54102045c9a19d`. This module is a derived work and
carries the same licence.

| File | What it is |
|---|---|
| `compositor.h`, `compositor.m` | The module (Objective-C, ARC). Depends only on `background.h` and system frameworks. |
| `background.h`, `background.m` | The reviewed canvas background module, copied from `background-port/` with one added method (section 14). |
| `comprender.m` | Command-line tool built from the same objects (section 9). |
| `build.sh` | Builds `build/background.o`, `build/compositor.o`, `build/comprender`. |
| `scenes/`, `assets/` | Scene descriptions and test images / test shaders. |
| `out/` | PNGs of the last `verify/render_scenes.sh` run. |
| `verify/` | Verification only: `check.py` (driver), `upstream.py` (upstream's Rust geometry and GLSL re-typed in Python), `glref.c` (OpenGL reference running the unmodified upstream `.glsl`), `bgcompare.py`, `render_scenes.sh`, `make_assets.py`, `cvage_probe.m` (when CoreVideo's texture cache lets go of a released texture; run by hand), `run_all.sh` and its last log. `pngio.py` is copied from `background-port/verify/`; only `make_assets.py` uses it (the checks read raw framebuffer dumps). |

Nothing under the Infinify checkout was modified or built. Nothing was
committed (the work directory is not a repository).

## 1. Provenance

Hand-translated to Metal Shading Language in `compositor.m` (`kIFCMSL`).
Constants, uniform semantics and arithmetic are unchanged and GLSL variable
names are kept, so the two read side by side.

| Metal entry point | Upstream file | SHA-256 of the upstream file |
|---|---|---|
| `ifc_border` | `src/shaders/border.glsl` | `a2eb306cd658ece061a18d54dd499d2f2993630130ab52dc9882360c34f7f294` |
| `ifc_shadow` | `src/shaders/shadow.glsl` | `0ee61e0f85be6fa1073db42c6ce00a936c5544b279bea4023506e443a7e12f66` |
| `ifc_corner_clip` | `src/shaders/corner_clip.glsl` | `aa38e89961a02af57893e51f3c491e71bfc9aacd7d55d602c678432caae11b21` |
| `ifc_texture`, `ifc_solid` | smithay 0.7.0 `src/backend/renderer/gles/shaders/implicit/texture.frag` (the default program for memory buffers and unclipped surfaces) | read in the crates.io release, see section 13 |

The CPU side mirrors upstream function by function and cites each one in a
comment:

| Here | Upstream |
|---|---|
| `IFCPaintedExtent`, `IFCPaintedRect`, `IFCCornerRound`, `IFCTransformRect` | `elements.rs`: `painted_size`, `painted_rect`, `corner_round_rect`, `WindowTransformElement::transform_rect` |
| `IFCBorderGeometry` | `shaders.rs`: `border_area_for`, `push_border_element`, `border_uniforms_precise` |
| `IFCShadowGeometry`, `IFCOuterCornerRadius` | `shaders.rs`: `shadow_area_for`, `push_shadow_element`, `shadow_uniforms_precise`, `outer_corner_radius` |
| `IFCCornerClipUniforms` | `mod.rs` `push_corner_clipped_elements`, `elements.rs` `RoundedCornerElement::compute_uniforms` |
| `-drawWindow:…` | `mod.rs` `compose_frame`, the client-window branch |
| `-drawStandIn:…` | `suspended.rs` `push_suspended_element`, `ensure_label`, `ensure_body` |
| `-drawOutlines:…`, `IFCompositorOutlineRect` | `mod.rs` `build_output_outline_elements`, `outline_edge_strips`; `canvas.rs` `visible_canvas_rect` |
| `IFCRenderTitleBar`, `IFCRenderBodyFill`, `IFCCornerAlphaAt`, `IFCBodyCornerAlphaAt`, `IFCDrawLine`, `IFCDrawFilledCircle` | `decorations.rs`, same names in snake case |
| `IFCFitText`, `IFCMeasure`, `IFCRasterizeInto` | `text.rs` `fit_text`, `measure`, `rasterize_into` (on CoreText, deviation 5) |
| `IFCompositorCoverageOfFrame`, `IFCompositorDecorationDrawn` | `canvas.rs` `coverage`, `chrome.rs` `DrawnChrome::drawn` |
| `IFCompositorStandInBodyRect` | `state/suspended.rs` `standin_body_rect` |
| `IFCompositorDecorationDefault`, `IFCompositorChromeStyle`, `IFCompositorOutlineSettingsDefault` | `config/types.rs` `DecorationConfig::default`, `SHADOW_RADIUS`, `SHADOW_COLOR`, `OutputOutlineSettings::default` |

Rust's numeric rules are reproduced where they decide a pixel: `f64::round`
(half away from zero), `as i32` (truncation, saturating), `as u8`, and `f32`
arithmetic wherever upstream narrows to `f32`.

## 2. Public API

Everything is in `compositor.h`.

- **`IFCompositorFrame`** — what one output shows at one instant. `size`
  (points), `scale` (backing scale), `cameraX/Y` (world point at the top-left,
  Y down), `zoom`, `time`; `background` (an `IFBackgroundProgram`, shared
  between outputs); `clear` (opaque black = upstream's live output,
  transparent = upstream's screenshot target); `chrome`
  (`IFCompositorChromeStyle`: `bg_color`, `fg_color`, `corner_radius`,
  `title_bar_height`, `font`, `font_size`, `font_weight`, `title_align`);
  `decorationScale`; `placeholderColor`; `elements` (bottom to top);
  `outline` + `-setOutlineRects:count:`; `needsContinuousRedraw`;
  `debugPasses`.
- **`IFCompositorElement`** — a window or a stand-in: `identifier` (unique
  within a frame; kept when a window becomes a stand-in or back), `kind`,
  `rect` + `space` (canvas, the default / output points / pinned), `layer`
  (normal / widget / pinned), `hasClipRect` + `clipRect`, `focused`,
  `decoration`, content (`pixelBuffer` or `texture`, `contentRect`,
  `contentOpaque`, `contentGeneration`), `title`, `appName`, `launching`,
  `showsPinnedIndicator`, `hasTransform` + `transform`.
  `IFCompositorStandInBodyRect(windowRect, clientDecorated, titleBarHeight)`
  gives the `rect` of the stand-in that replaces a window.
- **`IFCompositorDecoration`** — the resolved decoration of one element:
  `mode`, `borderWidth`, `borderColor`, `borderColorFocused`, `cornerRadius`,
  `shadow`, `shadowRadius`, `shadowColor`, `opacity`. Helpers:
  `IFCompositorDecorationDefault()`,
  `IFCompositorDecorationDrawn(configured, fullscreen, coverage)`,
  `IFCompositorCoverageOfFrame(frame, usable)`.
- **`IFCompositorOutlineSettings`**, `IFCompositorOutlineRect(...)`.
- **`IFCompositorRenderer`** — draws frames for one output and owns that
  output's caches. `+rendererWithDevice:`,
  `-encodeFrame:intoTexture:commandBuffer:`, `-newImageForFrame:error:`,
  `-writePNGForFrame:toURL:error:`, `-BGRADataForFrame:error:`, `-purge`,
  diagnostics (`cacheEntryCount`, `chromeRasterCount`, `contentWrapCount`,
  `debugDrawHandler`).
- **`IFCompositorLayer : CAMetalLayer`** — one output on screen.
  `-initWithRenderer:`, `-updateWithFrame:` (returns YES when it drew),
  `-setNeedsRedraw`, `needsContinuousRedraw`, `drawCount`, and a
  diagnostics-only frame capture used by `comprender --via-layer`.

## 3. How the host drives it

**Once per config load:** build one `IFBackgroundProgram` (as today's notes
for the background module say) and one `IFCompositorChromeStyle` from
`[decorations]`.

**One layer per output.** The compositor layer replaces, for its output, the
`IFBackgroundLayer`, every tile `CALayer`, every
`AVSampleBufferDisplayLayer` and the "Detached window" `CATextLayer`:

```objc
IFCompositorLayer *layer = [[IFCompositorLayer alloc] initWithRenderer:nil];
layer.frame = CGRectOffset(outputScreenBounds, -view.globalBounds.origin.x, -view.globalBounds.origin.y);
[view.layer addSublayer:layer];
IFCompositorFrame *frame = [IFCompositorFrame new];     // kept; refilled in place
```

**Update.** Call `-updateWithFrame:` on the main thread whenever anything may
have changed: at the end of `-[DesktopView render:]`, after a stream delivered
a sample (set the element's `pixelBuffer` first), and on every display tick
while `layer.needsContinuousRedraw`. The frame and its elements are plain
unsynchronised objects: change them only on the thread that calls
`-updateWithFrame:`. ScreenCaptureKit delivers samples on its own queue, so
hop to the main queue before touching an element, as the shell already does
for `latestSample`. Calling too often is free: the layer
hashes the frame description and returns NO without touching the GPU when
nothing changed. Calling it again a couple of seconds after a window closed
or became a stand-in is useful even if nothing changed: that call, drawn or
skipped, is what returns the last capture surface's memory (section 7). The
layer sets its own `drawableSize`, `contentsScale` and `opaque`.

**Which snapshot field goes where** (`crates/desktop` `snapshot()`):

| Frame / element field | Source |
|---|---|
| `frame.size` | `outputs[].screen_bounds` size |
| `frame.scale` | the hosting window's `backingScaleFactor` |
| `frame.cameraX/Y`, `frame.zoom` | `outputs[].camera`, `outputs[].zoom` (same convention as upstream: `screen = (world - camera) * zoom`) |
| `frame.time` | seconds since the app started, one clock for all outputs |
| `frame.background` | the shared program |
| `frame.chrome` | `[decorations]` `bg_color`, `fg_color`, `corner_radius`, `title_bar_height`, `font`, `font_size`, `font_weight`, `title_align` |
| `frame.decorationScale` | `ceil` of the largest backing scale among all outputs (upstream `recompute_decoration_scale`); 0 uses this output's |
| `frame.elements`, in order | `placements[]` with `output` == this output, in the order given (the controller's bottom-to-top z order). Add widgets / pinned windows with `layer`; the renderer orders the three buckets itself |
| `element.identifier` | `placements[].window` (one renderer per output, so the window id is unique in it). Keep it when the placement turns into a stand-in and back, as upstream keeps the element id; the renderer drops what the other kind cached |
| `element.rect`, `element.space` | `windows[].world_rect`, in `IFCompositorSpaceCanvas` (the default) — the renderer computes `render_loc = loc - camera` exactly as upstream. For a stand-in see its own row below. **Do not** pass `placements[].screen_rect` with `IFCompositorSpaceOutput`: that space is divided by the zoom and is not pixel-exact (deviation 10: 12 to 26 of 150 windows one pixel off at a half-pixel camera and zoom 0.8, 0.72 or 0.37) |
| `element.clipRect` | **nothing.** Do not pass `placements[].clip_rect`: the output always clips, and a per-element clip also cuts the shadow and the border |
| `element.pixelBuffer` | `CMSampleBufferGetImageBuffer(source.latestSample)`; nil until the first sample |
| `element.contentRect` | `placements[].source.content_rect` (the window content inside the buffer, in buffer pixels) — **not** `buffer_crop`, which is only the visible part |
| `element.contentGeneration` | bump on every sample (or use `source.capture_revision`) |
| `element.focused` | `snapshot.focused == placements[].window` |
| `element.decoration` | the vendored `effective_*` helpers of `crates/core/src/config/types.rs` (`effective_decoration_mode`, `effective_border_width`, `effective_border_color(_focused)`, `effective_corner_radius`, `effective_shadow_enabled`, `effective_opacity`), then `IFCompositorDecorationDrawn` (below). macOS windows carry their own title bar, so the mode is `client` |
| `element.kind = StandIn`, `rect`, `appName`, `title` | a placement whose source is gone (today's "Detached window" tile), under the window's identifier. **`rect` is not the window's rectangle:** a stand-in's `rect` is its body and the bar is drawn above it, so for a window that carried its own title bar (every macOS window; upstream's CSD origin) pass `IFCompositorStandInBodyRect(world_rect, YES, chrome.titleBarHeight)` = `(x, y + title_bar_height, w, max(h - title_bar_height, 1))`. Bar + body then cover exactly the placement's rectangle, which is what the shell culls and hit-tests with (`out/standin_mapping.png`). Passing `world_rect` itself draws the stand-in 25 px too tall, its bar outside the placement. Set `pixelBuffer` and `texture` to nil (a stand-in draws no content; the renderer lets go of the buffer either way, the element only when cleared). `appName` = the app's display name, `title` = `windows[].metadata.title` (not drawn, see deviations). Its `decoration` comes from the global `[decorations]` table alone — upstream calls `effective_*(None, mode, config)` for a stand-in, no window rule — and it is never passed through `IFCompositorDecorationDrawn` (a stand-in is not subject to the coverage rule) |
| `placements[].presentation_settled == false` | today the shell hides the surface. Here: keep the last buffer, or set `pixelBuffer = nil` to show the placeholder. Host's choice |
| `frame.outline`, outline rects | `[output.outline]`; one `IFCompositorOutlineRect(camera, zoom, other.camera, other.size, other.zoom)` per other output |

**Chrome a window really wears.** Upstream gates the configured chrome on how
the window's frame covers the output's usable area (`DrawnChrome::drawn`):

```objc
// frame = (origin - bw, origin - bar - bw, size + 2bw, size + bar + 2bw) * zoom, output-local points
IFCompositorCoverage c = IFCompositorCoverageOfFrame(frameRect, usableArea);
element.decoration = IFCompositorDecorationDrawn(configured, isFullscreen, c);
```

**Culling.** Upstream skips a window whose bounding box (plus border; plus bar
and shadow radius only for server-decorated windows and stand-ins) does not
overlap the visible canvas rectangle. The renderer does not repeat that test:
it draws every element it is given and culls each draw against the output.
The shell's `placements()` already lists only windows whose rectangle
intersects the output, which is upstream's rule for client-decorated windows.

**Animated background.** When `layer.needsContinuousRedraw`, keep the frame
timer running while the panel is visible and call `-updateWithFrame:` every
tick with an advancing `time`. The layer applies upstream's `animate_fps`
budget itself (`background_animation_due`).

**Presentation.** The layer sets `presentsWithTransaction = YES`, so a frame
lands in the same Core Animation commit as anything else the host changed. For
lowest latency on video-rate content the host may set it to NO; both paths are
implemented.

**Screenshots** (`msg screenshot`). Upstream renders a canvas region at a
chosen DPI with zoom 1 and no outlines, into a transparent target. Build a
frame with `size` = region size, `scale` = DPI scale, `camera` = region
origin, `zoom` = 1, `clear = IFCompositorClearTransparent`, no outline rects,
`background` = the program or nil, canvas-space elements, and call
`-writePNGForFrame:toURL:error:` on a separate `IFCompositorRenderer`. For an
isolated `window` capture put only that element in the frame.

**Teardown.** `[layer removeFromSuperlayer]` and drop the references. No
timers, display links, observers or threads. Textures a frame in flight still
samples are released when that frame completes, even if the renderer is
already gone.

**Threads.** A renderer is used from one thread at a time; the layer from the
main thread. A frame and its elements must not be changed by another thread
while a renderer or layer reads them (no locks, `nonatomic` properties, and
the element's `pixelBuffer` setter releases the buffer it replaces). Command
buffers handed to `-encodeFrame:…` must come from `renderer.commandQueue` and
must be committed. As with any Metal code, a call made outside a run loop
(a queue, a display-link thread, a loop in a tool) belongs in an
`@autoreleasepool`: Metal hands out autoreleased objects, and a texture one of
them refers to lives until that pool drains (seen in the sanitizer build of
the kind-switch test, section 15, before its layer updates got a pool each).

## 4. Geometry and zoom rules

For an element whose content rectangle before zoom is `(x, y, w, h)` in
output-local logical pixels, at backing scale `s` and zoom `z` (upstream's
names: `render_loc`, `output_scale`, `zoom`):

- **Content** occupies `corner_round_rect((round(x·s), round(y·s), round(w·s), round(h·s)), z)`:
  the two corners are rounded independently after the zoom, so neighbours meet
  on the same pixel.
- **Border** is a ring *outside* the content. Its width is snapped to whole
  device pixels, `max(round(bw · s · z), 1)`, so it never drops below one
  pixel however far the canvas is zoomed out. The inner radius is
  `r · s · z` device pixels; the outer radius is `r + bw` for a rounded
  window and stays 0 for a square one.
- **Corner radius** scales with `s · z`. The clip clamps it to half the
  smaller side; the border and the shadow do not (section 12).
- **Shadow** is cast by content + border (+ title bar), with no offset. Its
  Gaussian has `sigma = SHADOW_RADIUS / 3` logical pixels (`14 / 3`), so on
  screen the shadow is `14 · s · z` device pixels wide; colour `#00000066`.
  It is masked inside the body, so a translucent window shows no shadow
  through itself.
- **Opacity** multiplies each pass separately (content, border, shadow, bar):
  there is no group opacity, as upstream.
- **Title bar** (server mode and stand-ins): `round(title_bar_height · s)`
  device pixels before zoom, above the content; the border and the shadow
  wrap bar + content; only the bottom corners of the content are rounded.
- **Outlines**: thickness in logical pixels, scaled by `s` but **not** by the
  zoom; rectangles are truncated to integers and clipped to the viewport.
- **Pinned elements** ignore the zoom (`z = 1`) and the camera.

## 5. Draw order and blending

One render pass. Bottom to top:

1. clear (opaque black or transparent);
2. background (replaces the cleared pixels);
3. output outlines;
4. elements: all `widget`, then all `normal`, then all `pinned`, each bucket in
   list order. Per window: shadow, border, content, title bar. Per stand-in:
   shadow, border, title bar, body, label.

That is upstream's list read backwards (upstream's vector is top to bottom:
pinned, closing, normal, canvas layers, widgets, bottom layer, outlines,
background; per window: popups, bar, content, border, shadow). Because each
element's passes are consecutive, an upper window's shadow falls on the lower
window with no extra work.

Every pass blends premultiplied source-over, `(ONE, ONE_MINUS_SRC_ALPHA)` on
colour and alpha, as smithay sets `glBlendFunc`.

## 6. Colour

- The target (layer drawable and offscreen texture) is
  `MTLPixelFormatBGRA8Unorm`, deliberately not an `_sRGB` format: values are
  stored and blended as written, in sRGB encoding, exactly like upstream's GL
  framebuffer. The layer's `colorspace` is sRGB and the PNG is tagged sRGB.
- Window buffers are sampled as `BGRA8Unorm` (no transfer function), linear
  filtering, clamp to edge, no mipmaps — smithay's defaults for a client
  buffer. They are treated as **premultiplied alpha**, the Wayland ARGB8888
  convention; `contentOpaque` selects upstream's XRGB (`NO_ALPHA`) path.
- **Assumptions about ScreenCaptureKit buffers** (not verified here: this
  shell has no screen-recording permission, no live buffer was rendered):
  `kCVPixelFormatType_32BGRA`, IOSurface-backed, premultiplied alpha, encoded
  in the stream's colour space. For the numbers to mean sRGB the host must set
  on every `SCStreamConfiguration`:
  - `pixelFormat = kCVPixelFormatType_32BGRA` (already set);
  - `colorSpaceName = kCGColorSpaceSRGB` (**not set today**; without it the
    buffer is in the display's colour space and a Display P3 panel's content
    would be shown slightly desaturated);
  - `ignoreShadowsSingleWindow = YES` and `showsCursor = NO` (already set):
    the compositor draws its own shadow;
  - a `queueDepth` with room to spare (today 3): the renderer holds each
    window's current buffer, and the previous one until the last frame that
    sampled it has completed, on top of the host's own `latestSample`.
    Reasoned, not measured.
  Any other pixel format, or a buffer without an IOSurface, draws the
  placeholder and logs once.
- Chrome textures (title bar, body, label) are RGBA8, premultiplied the way
  upstream's buffers are.

## 7. Resources and cost

- Shared per device: six pipelines, one sampler, one command queue.
- Per renderer (per output): a `CVMetalTextureCache`; one cache entry per
  element that needs one (content wrapper, title bar, body, label). Entries
  for elements that left the frame are dropped at the end of that frame.
- A pixel buffer's Metal wrapper is created when the element's buffer object
  changes and kept only while it is the current one, so a capture pool surface
  is never pinned after it was replaced. The replaced wrapper is released when
  every command buffer encoded so far has completed.
- An entry serves one kind of element at a time. An element that changes kind
  or decoration mode under the same identifier stays in use every frame, so
  its entry is never evicted; the renderer therefore drops the other kind's
  resources itself: a stand-in retires the content wrapper and buffer it held
  as a live window, a window retires the stand-in's body and label, and the
  title bar unless it still draws one. Measured (`--kind-switch-test`): a
  3456×2234 buffer has retain count 3 / IOSurface use count 2 while live (the
  test, the element, the renderer); 2 / 1 as a stand-in whose element still
  holds it; 1 / 1 (idle) once the element is cleared. A 1728×1117 stand-in's
  30.9 MB body is gone within four frames of becoming a live window, and a
  title bar when a server-decorated window turns client-decorated.
- CoreVideo's cache keeps the Metal texture of a released wrapper, and through
  it the IOSurface's memory, until a flush that comes at least one second
  (its default age, now set explicitly) after the buffer's last holder let go
  — the renderer or, later, the host (`verify/cvage_probe.m`). The renderer
  flushes at the end of the three encodes after a retirement — too early for
  that, but it is what returns the surface to its pool — and, independently,
  at most once every 1.5 s at the end of an encode or in an
  `-updateWithFrame:` that skips its redraw. Measured
  (`--kind-switch-test`): with a 3456×2234 buffer retired by the renderer but
  held elsewhere for 1.7 s more, 61.6 MB allocated (30.9 MB of it the
  stand-in's body); still 61.6 MB right after its release; 32.1 MB one frame
  1.7 s later. Through a layer whose scene went static as the window became a
  stand-in: 31.0 MB until one more update, which skipped the redraw and left
  1.4 MB. Without such a later call (a host that never updates that output
  again) the surface stays mapped until the renderer is released or purged.
- A steady frame (nothing changed) costs a hash of the description (every
  field, every UTF-16 unit of each title and app name), one reading of the
  clock, and a flush of the texture cache every 1.5 s. A frame that redraws
  without new content allocates nothing in
  this module: uniforms go through `setVertexBytes` / `setFragmentBytes`, the
  render pass descriptor and the completion block are reused. Metal's own
  per-frame objects (command buffer, encoder, drawable) remain.
  Measured with `--bench` over 119 identical frames after the first, for the
  three scenes below: chrome rasterisations and content wrappers +0, +0; live
  heap blocks −306, +3, +15; heap allocations made while `-encodeFrame:` runs
  (counted with libmalloc's logger hook, Metal's own included): 3, 3 and 6
  per frame. An empty frame — clear only — also costs 3, so those are Metal's
  for opening a pass, and 1000 draws add 3 more for its uniform storage.
- The shadow and border quads are drawn as four strips around the region where
  their shader returns exactly zero (deviation 3). For the 320-element scene
  this took GPU time from 12.1 ms to about 4 ms with byte-identical output.

Apple M5 Pro, `comprender --bench 120`, per frame:

| Scene | Target | Draws | CPU encode | GPU |
|---|---|---|---|---|
| 2 windows over the paper shader | 3456×2234 | 6 | 0.02 ms | 0.42 ms |
| 4 stand-ins + 2 server-decorated windows | 1800×1040 | 28 | 0.02 ms | 0.17 ms |
| `many.json`: 300 overlapping windows + 20 stand-ins | 3456×2234 | 1000 | 0.46 ms | 4.33 ms |

`many.json` by pass: background 0.34, shadow 1.92, border 0.41, content 1.84,
bars / bodies / labels 0.26 ms. These are the figures of `verify/last_run.log`;
they move by a few tenths of a millisecond between runs (this machine was
busy with other work during the last ones: the two-window scene read 0.27 to
0.52 ms and `many.json` 4.2 to 4.5 ms over seven runs; the build from before
the review fixes, run three times in between, 0.25 to 0.27 and 4.2 to 4.3 ms).
There is no occlusion culling (deviation 8): 300 windows are blended back to
front.

Chrome textures follow upstream's design: a stand-in's body is a CPU-filled
RGBA buffer of `w · h · decoration_scale²` pixels (33 MB for a 1920×1080
stand-in at 2x), rasterised once per size.

## 8. Redraw gating

`-updateWithFrame:` redraws when the 64-bit FNV hash of everything that
decides the picture differs from the last drawn frame — size, scale, camera,
zoom, background program, clear, chrome style, decoration scale, placeholder,
outline settings and rectangles, and for every element all of its fields plus
its content identity (pixel-buffer object, IOSurface id and change seed,
texture object, `contentGeneration`) — or when an animated background is due.
Strings (title, app name, font name) enter the hash with every UTF-16 unit,
not through `-[NSString hash]`, which looks at 96 characters of a longer
string at most. `time` alone never causes a redraw of a static frame. Measured
sequence (`--gating-test`): first frame redraw; identical skip; time only
skip; camera, zoom, element moved, generation bumped, focus, opacity, same
buffer rewritten (surface seed), a 130-character title set, its character 40
changed, a 130-character app name set, its character 41 changed,
`-setNeedsRedraw`, output resized, scale changed: redraw each, with an
identical frame after each: skip. With an `animate_fps = 30` background,
+20 ms steps redraw every second step.

## 9. comprender

```
comprender scene.json --out frame.png
           [--scale S] [--zoom Z] [--camera X,Y] [--size WxH] [--time T]
           [--clear opaque|transparent] [--only PASS[,PASS...]]
           [--via-layer] [--dump-bgra FILE] [--dump-draws FILE.json]
           [--gating-test] [--bench N] [--churn-test N] [--kind-switch-test]
```

Exit status 0: rendered as described; 1: rendered, but the background fell
back (reason on stderr as `error: ...`); 2: usage, scene or I/O failure.
`--gating-test` and `--kind-switch-test` print `FAIL` and exit with 1 when a
long string's change did not redraw, or when something stayed allocated or
drew differently after a change of kind.
`--only` takes `background, outline, shadow, border, content, title_bar, body,
label`. `--dump-draws` writes each draw's destination rectangle, scissor and
uniforms.

Scene schema (every key optional unless marked; colours are `"#RRGGBB"` or
`"#RRGGBBAA"`, straight alpha; paths are relative to the scene file):

```jsonc
{
  "output": {"size": [800, 600], "scale": 1, "camera": [0, 0], "zoom": 1, "time": 0,
             "clear": "opaque",            // or "transparent"
             "decoration_scale": 0,
             "usable_area": [x, y, w, h]}, // when given, each window's decoration goes through
                                           // IFCompositorCoverageOfFrame + IFCompositorDecorationDrawn
  "background": {"type": "default",        // default | shader | tile | wallpaper | none
                 "path": "…", "texture": "…", "mirror_tile": false,
                 "transparent_shader": false, "animate_fps": 0},
  "chrome": {"bg_color": "#303030", "fg_color": "#FFFFFF", "corner_radius": 10,
             "title_bar_height": 25, "font": "Adwaita Sans", "font_size": 11,
             "font_weight": "medium",      // thin … black, as upstream
             "title_align": "center"},     // left | center
  "placeholder_color": "#303030",
  "outline": {"color": "#ffffff", "thickness": 1, "opacity": 0.5,
              "rects": [[x, y, w, h]],                                      // output-local points
              "outputs": [{"camera": [x, y], "size": [w, h], "zoom": 1}]},  // projected with upstream's math
  "decoration": { … },                     // defaults for every element, same keys as below
  "elements": [                            // bottom to top
    {"id": 1,
     "kind": "window",                     // window | standin
     "rect": [x, y, w, h],                 // required
     "space": "canvas",                    // canvas | output | pinned
     "replaces": "client",                 // standin only, canvas or pinned space: `rect` is the rectangle of the
                                           // client- | server-decorated window it replaces; the element gets
                                           // IFCompositorStandInBodyRect(rect, …, chrome.title_bar_height)
     "layer": "normal",                    // normal | widget | pinned
     "clip": [x, y, w, h],
     "focused": false,
     "fullscreen": false,                  // IFCompositorDecorationDrawn(…, fullscreen = true, …)
     "decoration": {"mode": "client",      // client | server | minimal | none
                    "border_width": 0, "border_color": "#303030", "border_color_focused": "#303030",
                    "corner_radius": 10, "shadow": true, "shadow_radius": 14,
                    "shadow_color": "#00000066", "opacity": 1},
     "content": null,                      // nil buffer, or one of:
     //  {"type": "solid", "color": "#…"}
     //  {"type": "gradient", "from": "#…", "to": "#…", "direction": "horizontal|vertical|diagonal"}
     //  {"type": "checker", "a": "#…", "b": "#…", "cell": 16}
     //  {"type": "png", "path": "…", "rect": [x, y, w, h]}          premultiplied on load
     //  {"type": "raw", "path": "…", "size": [w, h], "rect": […]}   premultiplied RGBA8 bytes, used as given
     //  common keys: "size": [w, h] (pattern buffer size; default: the rectangle at the output's density),
     //               "margin": n, "margin_color": "#ff00ff" (pattern inside a larger buffer; sets the content rect),
     //               "via": "pixelbuffer" | "texture", "opaque": false
     "title": "…", "app_name": "…", "launching": false, "pinned_indicator": false,
     "transform": {"origin": [x, y], "offset": [x, y], "scale": 1}}   // physical pixels, as upstream
  ]
}
```

Pattern and PNG contents become an IOSurface-backed BGRA `CVPixelBuffer`
(through `CVMetalTextureCache`, the path live windows take) unless
`"via": "texture"`.

## 10. How blur and closing animations would slot in

Neither is implemented. What is already in place for them:

- every element has `decoration.opacity` and an optional
  `IFCompositorTransform` (upstream's `WindowRenderAnimation`: origin, offset,
  scale in physical pixels), applied to each of its rectangles exactly as
  `WindowTransformElement::transform_rect` does. Open / move / resize
  animations and a stand-in's dismiss need nothing more than the host driving
  those two fields each tick. Rendered once (`out/layers_transform.png`); not
  compared against anything.
- an element can take an `id<MTLTexture>` as content and `mode = none` draws
  it untouched.

**Closing animation** (`closing.rs`): upstream bakes the dying window with its
chrome into one texture (zoom 1, alpha 1) and then fades and shrinks that
texture as a single piece, in its own bucket above normal windows and below
pinned ones. Here:
1. bake: render a frame holding only that element (transparent clear, zoom 1,
   no background, camera at the element's shadow box) into a texture — the
   existing `-encodeFrame:intoTexture:commandBuffer:` does it; a convenience
   `-newTextureForElement:` would wrap it;
2. show: an element with `texture` = the bake, `mode = none`,
   `opacity` = fade alpha, `transform` = shrink;
3. add `IFCompositorStackLayerClosing` between normal and pinned: one enum
   value and one entry in the `order[]` array of `-encodeFrame:…`.
The host's animation driver decides when it ends; while one runs it calls
`-updateWithFrame:` every tick (an `animating` flag would be OR-ed into
`needsContinuousRedraw`).

**Blur** (`blur.rs`, `blur_down/up/mask.glsl`): upstream samples what is
already drawn beneath a window, runs Kawase down / up passes, masks the result
to the window's rounded shape and inserts it under the window's content. Here
that means the frame can no longer be one pass:
1. add `blur` to `IFCompositorDecoration` and `blurRadius` / `blurStrength`
   (`[effects]`) to the frame;
2. in the element loop of `-encodeFrame:…`, before a blurred element: end the
   pass, copy the element's screen rectangle out of the target into a scratch
   texture, run the down / up pipelines on scratch textures, reopen the pass
   with `MTLLoadActionLoad`, draw the result through a `blur_mask` pipeline
   (same quad and uniforms as the content pass), then continue;
3. the target must be readable: the layer gives up `framebufferOnly`, or
   renders into an intermediate texture that is blitted to the drawable;
4. cache per element in `IFCEntry`, keyed like upstream's `blur_cache`
   (geometry, what is beneath, `animate_blur_fps`).
The three shaders are translated the same way as the three here.

## 11. Deviations from upstream

1. **`v_coords` is computed per fragment** from the pixel centre instead of
   being interpolated from the vertices (as in the background module). Same
   value to within float rounding: all 52 comparisons against the unmodified
   GLSL are within 1 level, 46 of them exact.
2. **Sampling is clamped to the content rectangle.** A window buffer may be
   larger than the window content (`contentRect`). Texture coordinates are
   clamped to the centres of the content's outermost texels, so a magnified
   window never blends in texels from outside its content. For a buffer that
   is all content this is the same sample `GL_CLAMP_TO_EDGE` gives; upstream
   has no notion of such a sub-rectangle (a Wayland client's shadow margin
   *is* blended at the edge when zoomed in).
3. **The interior of shadow and border quads is not rasterised.** Where the
   shader returns exactly zero (inside the body, at least one pixel in from
   its edges and clear of its corner squares) premultiplied source-over leaves
   the target unchanged, so those fragments are skipped by drawing four strips
   around the hole. The 20 scene PNGs rendered before the change (including
   `many`, `variants` and the transformed element) were byte-identical after
   it, and every OpenGL comparison of section 15 was rerun with it.
4. **`NO_ALPHA` is a uniform**, not a second program; `EXTERNAL`
   (`samplerExternalOES`) and `DEBUG_FLAGS` (tint) are not translated.
5. **Text is shaped and rasterised by CoreText**, not cosmic-text / swash.
   `fit_text`'s ellipsis search, the font size (`points × 4/3 × scale`), the
   buffer sizes, the placement and the per-pixel blend are upstream's. Glyph
   shapes, advances and hinting are CoreText's. `Adwaita Sans` is not
   installed on this machine, so every text here is in the system font (the
   named family is used when installed; upstream substitutes a generic sans
   too). The line's coverage is blended once per pixel, where upstream blends
   glyph by glyph. There is no background font scan, so no textless first
   frame.
6. **A window without content draws a placeholder**: `placeholderColor`
   (default `#303030`) through the same clip, border and shadow. Upstream has
   no mapped window without a buffer. Alpha 0 draws shadow and border only.
7. **`clipRect`** is not an upstream concept (a scissor over everything the
   element draws).
8. **No damage tracking, no opaque regions, no direct scan-out.** The whole
   frame is redrawn when its description changes (section 8), every pass
   blends, and nothing is culled for being covered. For opaque pixels blending
   gives what upstream's blend-off draw gives.
9. **Sizes are doubles.** Upstream's window sizes are integer logical pixels;
   a window element here may be fractional and goes through the same
   formulas. Stand-in sizes are rounded to integers, as upstream's are.
10. **`IFCompositorSpaceOutput` divides by the zoom** to recover the pre-zoom
    rectangle, and is therefore not pixel-exact. When `(world − camera) ·
    scale` lands exactly on a half pixel (a camera ending in .5 at 1x — common
    after centring an odd-sized window — or in .25 / .75 at 2x) the quotient
    can fall on the other side of the tie and shift the window by one pixel
    against its neighbours and the background. Measured with the shell's own
    arithmetic for `screen_rect`, `(world − camera) · zoom`, on 150 windows at
    integer positions: camera (100.5, 50.5) zoom 0.8 at 1x: 19 off; zoom 0.37:
    13; camera (33.5, 71.5) zoom 0.72: 26; camera (100.25, 50.75) zoom 0.8 at
    2x: 12; none at zoom 1 or 0.5, with an integer camera, or at 2x with a .5
    camera. `IFCompositorSpaceCanvas` has no such step — 0 of 150 off in all
    eight cases — and is the default (the enum's zero value) since the review;
    Output space remains for rectangles that have no canvas position.
11. **Culling** is per draw against the output, not upstream's bounding-box
    test (section 3).
12. **Caches are per output**, not global: a title bar visible on two outputs
    is rasterised twice. `decoration_scale` is supplied by the host.
13. **`focused` is not part of the title-bar cache key** (upstream re-renders
    the bar on a focus change although no pixel depends on it).
14. **One opacity for content and chrome.** Upstream multiplies bar, border
    and shadow by an extra `chrome_alpha` during a fullscreen transition.
15. **Outline strips are solid quads**, not textured one-colour buffers; same
    values (`colour bytes × opacity`).
16. **Background over the opaque clear**: the background module draws with
    blending off; when its output carries alpha a second draw sets the
    target's alpha to 1, which is what source-over onto opaque black leaves.
    The background module's own deviations (its NOTES, section 8) carry over.
17. **Opacity is clamped to 0..1**; outline opacity to at most 1.
18. **Stand-in label falls back to `title`** when `appName` is empty.
    Upstream's display name is never empty.
19. **Shadow radius and colour are per-element fields.** Upstream has two
    constants; the defaults are those constants.
20. **Chrome buffers larger than 16384 pixels on a side are not drawn.**
21. **Fractional backing scales** go through the formulas (1.5 is in the
    checks) although macOS uses 1 and 2.
22. **`IFCompositorStandInBodyRect` works on doubles**; upstream's
    `standin_body_rect` on integer logical rectangles. Same formula.
23. **The texture cache is flushed on a schedule of its own** (section 7).
    Upstream has no such cache: a client buffer's texture goes with the
    buffer.

## 12. Upstream behaviour kept on purpose

- A border colour is used un-premultiplied (`u_color * coverage * alpha`), so
  a translucent border colour adds light instead of tinting:
  `#e5a50a80` over the paper background comes out bright yellow
  (`out/variants.png`, bottom right).
- A corner radius beyond half the smaller side: the clip clamps it, the border
  and shadow do not, and the border disappears (`out/variants.png`, bottom
  left, radius 500).
- Where two outline strips cross, the corner pixel is blended twice (191
  instead of 128 for white at 0.5).
- At zooms where the border element's two axes round differently, the stroke
  is a fraction of a pixel thicker on one axis and that edge is blended
  (seen at zoom 0.25: left / right exactly 1 px, top / bottom blended).
- A label buffer of odd width at an even buffer scale is squeezed by one
  device pixel (integer division of the buffer size).
- A stand-in's body always rounds to the *configured* `corner_radius`, its
  bar and border to the element's; its bar carries no text.
- Minified content is linear-filtered without mipmaps.
- A title bar's background alpha is not premultiplied into its colour.
- `draw_line`'s unchecked column index (a stroke past the right edge wraps to
  the next row); never reached at sane widths.
- The default dot grid is nearly invisible at zoom 0.5 on a 1x output
  (background module; `out/two_windows_z05_s1.png` shows none).

## 13. Not supported, and assumptions

Not supported:

- blur; closing snapshots; adoption crossfades; resize crossfades
  (section 10);
- popups and subsurfaces (a macOS menu is its own window);
- layer-shell layers, canvas layers, the cursor, the drag icon, the error bar,
  the session-lock frame;
- upstream's fullscreen logic (culling everything else, concealing the
  canvas): the host decides what is in the frame;
- screenshot tiling: one render is limited to 16384 pixels per side;
- pixel formats other than 32BGRA (10-bit, YCbCr, HDR), buffers without an
  IOSurface, rotated or flipped buffers, wide gamut;
- textures from another Metal device;
- the close button's hover state (unused upstream as well).

Assumptions:

- smithay was read in the crates.io release `smithay-0.7.0`
  (`~/.cargo/registry`), not at the git revision DriftWM pins: element
  geometry (`surface.rs`, `memory.rs`), `to_physical_precise_round`,
  `to_i32_round`, `Rectangle::overlaps` / `intersection`, the default texture
  program, `render_texture_from_to`, blend state and sampling defaults.
- `CVMetalTextureCache` may be used from the renderer's thread while a
  `CVMetalTexture` is released on Metal's completion thread (Apple's samples
  do this); not found documented.
- `CVMetalTextureCacheFlush` evicts a texture once its buffer has been
  released by everyone for the cache's maximum age, and not before: measured
  on this system with `verify/cvage_probe.m` (flushes at 0.01 and 0.5 s keep
  30 MB, at 1.2 and 1.7 s free it; never while the buffer is alive), not found
  documented beyond the name of the attribute.

## 14. Changes to the copied background module

One method, added to `IFBackgroundProgram`:

```objc
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder;
```

It is the draw of `-encodeFrame:intoTexture:commandBuffer:` without the render
pass around it, and that method now calls it. `background.h`: 9 added lines.
`background.m`: the body of the old method moved into the new one (23 changed
lines). Nothing else differs from `background-port/`, which was not touched.
`verify/bgcompare.py` renders seven backgrounds at three views through the
compositor and through the reviewed module's own `bgrender`: the framebuffers
are byte-identical with a transparent clear, and have the same colour with
alpha 255 with the opaque clear (42 comparisons).

## 15. Verification

`verify/run_all.sh <driftwm checkout> <bgrender>` reproduces everything below;
its complete output is `verify/last_run.log` (246 PASS lines, no FAIL: 211
checks of `check.py`, 21 lines for the 42 background comparisons and 14 of the
kind-switch test).

Upstream itself cannot run here, so three independent references were used:

- **Uniforms**: upstream's Rust (`painted_rect`, `corner_round_rect`,
  `border_area_for`, `border_uniforms_precise`, `shadow_area_for`,
  `shadow_uniforms_precise`, `compute_uniforms`) re-typed in Python
  (`verify/upstream.py`), compared with what the module passes to its shaders
  (`--dump-draws`).
- **OpenGL**: the system's legacy OpenGL compiling the *unmodified* upstream
  `.glsl` (GLSL 1.20, `precision` qualifiers defined away) and drawing the
  element's quad with the Python-computed uniforms; compared with the module's
  framebuffer for that pass alone (`--only`, transparent clear).
- **Formulas**: the three shaders re-typed in Python, evaluated per pixel.

| Check | Result |
|---|---|
| Border, shadow and content pass, 15 cases: scale 1 / 1.5 / 2; zoom 0.25 … 2; fractional and half-pixel cameras; odd sizes; a painted-rect tie at 1.5x; border 0 … 4; radius 0 … 40; opacity 0.6 with a translucent border colour | uniforms and destination rectangles equal upstream's in all 44 comparisons |
| The same passes against OpenGL running `border.glsl`, `shadow.glsl`, `corner_clip.glsl` | 44 of 44 within 1 level over the whole frame; 39 exact |
| Border and shadow against the Python formulas, every third row of the element | 0 pixels off by more than 1 level in all 29 comparisons |
| Content pass, 8 more cases: bottom-only radii under a title bar, square under a title bar, `NO_ALPHA`, buffers at half and double density, zoom 1/3, a content sub-rectangle (two cases) | uniforms equal; 8 of 8 within 1 level of OpenGL, 7 exact |
| Border thickness in device pixels, pure border colour along both axes | scale 1 zoom 1 width 2: 2 px on all four sides; 2x: 4; zoom 0.5: 1 (2 at 2x); zoom 2: 4; 1.5x width 1: 2; 2x zoom 0.7 width 3: 4; width 5: 5; 2x zoom 1.5 width 4: 12; zoom 0.25 width 1 and 3: 1 px left / right, blended top / bottom (section 12) |
| Corner coverage, every pixel of the four corner squares against `corner_alpha` | radius 10 at 1x, 2x, zoom 2; radius 16 at 2x zoom 0.5; radius 25: 0 of 576 … 2916 px off by more than 1 level. E.g. 1x radius 10 diagonal: (0,0) (1,1) (2,2) background, (3,3) onward fully window |
| Shadow alpha by distance from the edge, mid-side, over the flat background (200,204,210) | 1x: 1 px 0.183 → (163,167,172); 4 px 0.091; 8 px 0.022; 12 px 0.003; beyond 14 px none. 2x: same curve over twice the pixels. zoom 0.5: 1 px 0.166, 2 px 0.104, 4 px 0.027. All pixels within 1 level of the formula |
| Opacity 0.6 over the stripe tile | every sampled inside pixel = `0.6·white + 0.4·background` within 1 level (1x, 2x, zoom 0.5); nothing outside changed |
| Opacity on chrome | border pixel (233,82,84) and shadow pixel (186,190,195) as computed |
| Z order | overlap shows the upper window; swapping the list swaps it; widget < normal < pinned whatever the list order |
| Upper window's shadow on the lower | white lower window, left of the upper: 208, 225, 243, 253, 255 at 1, 3, 6, 10, 14 px — the formula's values |
| Clip rectangle, 1x and 2x | 0 pixels changed outside the clip; content and border present inside |
| Window partly outside the output | content, right and bottom border at the expected pixels |
| Content sub-rectangle with a magenta margin | 0 stray pixels at 1x, 2x, zoom 0.5, and 2x zoom 1.5 (deviation 2) |
| Outline strips, 1x and 2x | edge 128, inside 0, crossing corner 191, thickness 1 and 2 px, a rectangle past the edge clipped; projection of another output gives upstream's `(99, 74, 241, 151)` |
| Missing content | placeholder (48,48,48) inside border and rounded corner; with placeholder alpha 0 only shadow and border are drawn |
| Canvas-space vs output-space rectangle at an integer camera (zoom 0.75, 2x); pinned vs zoom | byte-identical frames |
| Canvas space against upstream's content rectangle (`loc_phys`, `PixelSnapRescaleElement`), 150 windows at integer positions, eight views (half-pixel, quarter-pixel and integer cameras; zoom 0.37 to 1; 1x and 2x) | 0 of 150 wrong in every view. The same windows given as output-space rectangles `(world − camera) · zoom`: 19, 13, 26, 12 off by a pixel at the four views of deviation 10, 0 at the other four |
| A stand-in given `IFCompositorStandInBodyRect` of a client-decorated window's rectangle, 1x and 2x | bar at the window's top, body down to its bottom; border and shadow rectangles and uniforms equal the live window's. Server origin: body = the rectangle, bar above. A window shorter than the bar: 1 px body |
| Clear modes | transparent: corner (0,0,0,0), shadow pixel alpha 30; opaque: alpha 255 everywhere |
| Stand-in, 1x and 2x | bar, body and label rectangles as `suspended.rs` computes them (label buffer 22 and 44 px high); text ink centred on the body within 2 px; close glyph at the expected box within 2 px; long name ellipsised inside the 24 px side padding |
| Server-side title bar | order shadow, border, content, bar; border wraps bar + content; content radii (0,0,10,10) |
| `IFCompositorCoverageOfFrame` + `IFCompositorDecorationDrawn` (the cases of upstream's `chrome.rs` tests), through a scene with a usable area | none: chrome unchanged, also when short by half a pixel; exact (at zoom 1, and at zoom 0.5 with a camera): square corners, no shadow, border kept; overhang: border gone too; server mode keeps its bar in both; fullscreen: content only, unclipped |
| `IFCompositorLayer` (not attached to a window) vs offscreen, seven scenes at 2x | byte-identical |
| Background pass vs the reviewed module's `bgrender` | 42 of 42 (section 14) |
| Redraw gating | section 8; the two long-string steps are checked (exit status), the rest is printed |
| Kind switch (`--kind-switch-test`), 14 checks: window → stand-in → window and server → client decoration under one identifier, offscreen and through a layer whose scene then goes static | buffer retain count / IOSurface use count 3 / 2 → 2 / 1 → 1 / 1; allocation 61.6 MB → 32.1 MB (the body that remains) one frame 1.7 s after the buffer's last holder let go; stand-in body 32.1 MB → 1.0 MB; title bar 7.0 MB → 1.1 MB; layer 31.0 MB → 1.4 MB on the update that skipped; 7 switches each byte-identical to a fresh renderer's frame (section 7) |
| Churn (`--churn-test`): a new pixel buffer per window per frame, elements removed and re-added, content switching between buffer / texture / none, every window a stand-in for two frames in eleven (once cleared, once with its content still set), `-purge` every 13th frame, frames not waited for, renderer released with a frame in flight | 400, 120 (300 windows, 22,911 wrappers, 11,277 chrome rasters) and 3000 frames: completed without error; live heap blocks after teardown below mid-run |
| The same churn runs (400 / 60 / 1500 frames), the kind-switch test, the gating test and one render in a build with `-fsanitize=address,undefined` (by hand) | no report; 14 of 14 kind-switch checks; the render byte-identical to the normal build's |
| `leaks --atExit` on one render, a 200-frame churn, the layer gating test and the kind-switch test | 0 leaks in each |
| `clang --analyze` on `compositor.m`, `comprender.m` | no findings |
| The 27 scene PNGs of `out/` rendered before the review fixes | byte-identical after them |

**Found and fixed during verification:** the churn test crashed in
`CVMetalTextureCache::bufferBackingNotInUse` when a retired `CVMetalTexture`
was released after the renderer's cache. Every holder of a `CVMetalTexture`
now also holds the cache.

**Review findings** (an independent review of the first version; all four
were reproduced and accepted, none rejected):

1. *A cache entry kept the other kind's resources when an element changed
   kind under one identifier.* Reproduced with the reviewer's
   `review-renders/variants/retain_test.m` built against these sources:
   before, a 3456×2234 buffer still had retain count 2 / use count 2 sixty
   stand-in frames later, and a stand-in's 30.9 MB body stayed allocated
   (61.6 MB) sixty frames after it became a live window; after, 1 / 1 and
   0.9 MB. Fix: `-drawStandIn:` retires the entry's content, `-drawWindow:`
   retires body, label and (unless server-decorated) bar. The churn test got
   kind switches, and `--kind-switch-test` checks the outcome; with the two
   retire calls taken out again it fails 7 of its 14 checks.
   While measuring this with `device.currentAllocatedSize` a second holder
   turned up that retain counts do not show (**not one of the four findings;
   added on my own account**): CoreVideo's texture cache keeps a released
   wrapper's texture, and the surface memory, until a flush at least one
   second after the buffer's last holder let go (`verify/cvage_probe.m`), and
   the renderer only flushed during the three encodes right after a
   retirement. In a scene that went static the 30 MB therefore stayed until
   the next content change anywhere on that output. The renderer now also
   flushes for age at most every 1.5 s, in an encode or a skipped layer
   update (section 7): about twenty lines of `compositor.m`; with that flush
   disabled the test fails 2 checks.
2. *The layer skipped the redraw when a long title or app name changed in the
   middle.* Reproduced with the reviewer's `gate_test.m`: character 40 of a
   130-character server title or stand-in name, `change redrew=0`; after,
   `redrew=1` at every position. Fix: the fingerprint and the chrome-style
   hash mix every UTF-16 unit instead of `-[NSString hash]`. `--gating-test`
   has the case and fails without the fix.
3. *The mapping gave a stand-in the window's whole rectangle, 25 px too
   tall.* The renderer was right (it draws what `push_suspended_element`
   draws); the mapping table missed upstream's `standin_body_rect`. Fix:
   `IFCompositorStandInBodyRect`, the header comment of `rect`, the stand-in
   row of section 3, a `"replaces"` key in the scene schema, two checks and
   `out/standin_mapping.png`.
4. *Output-space rectangles shift a share of the windows by one pixel at
   half-pixel cameras.* Confirmed with the shell's own arithmetic: 19, 13, 26
   and 12 of 150 at the reviewer's four views (the reviewer's own windows gave
   20, 16, 16 and 20). Fix: `IFCompositorSpaceCanvas` is now the enum's zero
   value and so the default of a new element and of a scene's `"space"`; the
   header and deviation 10 say that Output space is not pixel-exact; section 3
   tells the host to pass `world_rect`.

**Looked at** (each PNG in `out/` was opened):

| PNG | What it shows |
|---|---|
| `two_windows_z1_s1.png` | focused (amber border) and unfocused (grey border) window over the default dot grid at zoom 1: 2 px borders, radius 10 corners. The shadow is black on a black background, so it cannot be seen in this picture; the `paper` renders below show it |
| `two_windows_z05_s1.png`, `two_windows_z1_s2.png`, `two_windows_z05_s2.png` | the same scene at zoom 0.5, at 2x, and both: half size with 1 px borders; 4 px borders and smooth corners at 2x; no dots at zoom 0.5 1x (section 12) |
| `two_windows_paper_*.png` (zoom 1, 0.5, 1.5 at 1x; zoom 1, 0.5, 0.7 at 2x) | the same two windows over a light test shader: soft shadow all round, visible and plausible at every zoom; the background grid scrolls and scales with the windows |
| `overlap.png`, `overlap_z15_s2.png` | three overlapping windows: correct stacking, the upper windows' shadows darken the lower ones |
| `partial_clip.png` | two windows hanging off opposite corners of the output; a third cut to its clip rectangle with a hard edge through content, border and shadow |
| `opacity.png` | a 0.6 window over the stripe tile: stripes show through, its border and shadow are dimmed too; a 1.0 window beside it |
| `variants.png` | no border; no shadow; radius 0; radius 60; radius 500 (content clamped to a stadium, no border — section 12); mode none (bare); no chrome at all; 8 px translucent border (bright yellow — section 12) |
| `standin.png`, `standin_s2.png`, `standin_z05.png` | stand-ins: dark body, close glyph, centred label; a long name and a long fallback title ellipsised; "Terminal launching…"; a server-decorated window with an ellipsised long title; a bar with the pinned dot. Crisp at 2x, scaled at zoom 0.5 |
| `chrome_style.png` | another style: named font (Helvetica Neue bold), left-aligned title, 32 px bar, other colours |
| `outlines.png` | three outlines at 50 % white, one clipped by the output edge, under a window |
| `missing.png` | a window with no buffer: placeholder fill inside its border and shadow |
| `content_rect.png` | a buffer with a margin (none of it visible); a PNG with a translucent block through a Metal texture; the same PNG with `opaque`; a buffer at half density, magnified |
| `layers_transform.png` | a pinned element at zoom 1 over a zoomed canvas; a widget listed last but drawn below; a transformed (0.8 scale, offset) element at 0.7 opacity |
| `standin_mapping.png` | a live client-decorated window and three stand-ins for a window of the same rectangle (drawn as a red outline behind each). `"replaces": "client"`: exactly the window's footprint, bar at its top, label centred in it. `"replaces": "server"` and the rectangle passed as it is: 25 px taller, bar above the outline. Also opened at 2x, zoom 0.75, camera (10.5, 20.5): same relation, crisp |
| `many.png` | 300 windows and 20 stand-ins |
| `two_windows_no_background.png` | transparent clear: windows and shadows on alpha |
| `two_windows_animated_t0.png`, `_t1.png` | an animated background at two times |

**Not run:**

- **Upstream DriftWM itself.** No pixel here was compared with a pixel from
  real DriftWM. "Matches upstream" means: matches upstream's shader source
  executed by OpenGL and by a Python re-typing, under uniforms re-typed from
  upstream's Rust, and smithay as read in the 0.7.0 release.
- **cosmic-text.** Text was not compared with upstream's rasteriser, and not
  rendered in Adwaita Sans.
- **Real ScreenCaptureKit buffers.** Everything in section 6 about them is an
  assumption. Contents came from generated `CVPixelBuffer`s and textures.
- **The layer on screen.** No window was shown and nothing was captured from
  the display. Unverified: orientation inside `DesktopView` (a flipped view),
  colour on a real display, presentation timing, behaviour across display
  changes. The layer was driven unattached and its frames read back.
- **Integration** with the shell or the Rust core: none attempted.
- **Any other GPU** than this machine's (Apple M5 Pro, macOS 27.2 build
  26B5091g, deployment target 26.0).
- The upstream chrome rasterisers' bytes (`render_title_bar`,
  `render_body_fill`): ported line by line and checked for geometry and
  colour, not compared byte for byte with upstream's output.
- The animation transform against upstream; `animate_fps` against a real
  clock; scales other than 1, 1.5 and 2.
- `IFCompositorStandInBodyRect` against upstream's Rust: it is three lines
  read off `standin_body_rect`, checked here only through what it makes the
  renderer draw.
- The kind switch and the aged cache flush with ScreenCaptureKit's own pool
  surfaces and inside the host's run loop: the buffers of the test are
  `CVPixelBufferCreate`d ones, the layer unattached. That the host calls
  `-updateWithFrame:` again some time after a window became a stand-in is an
  assumption about the host.

## 16. Commands

Build, and the complete verification run:

```sh
cd compositor-port
./build.sh
verify/run_all.sh ../driftwm-upstream ../background-port/build/bgrender > verify/last_run.log 2>&1
```

`build.sh` runs:

```sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -O2 -g -c background.m -o build/background.o
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -O2 -g -c compositor.m -o build/compositor.o
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -O2 -g -c comprender.m -o build/comprender.o
xcrun clang -arch arm64 -mmacosx-version-min=26.0 build/background.o build/compositor.o build/comprender.o \
    -framework Foundation -framework Metal -framework QuartzCore -framework CoreGraphics -framework CoreVideo \
    -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate -o build/comprender
```

`run_all.sh` runs, in order:

```sh
./build.sh
xcrun clang -arch arm64 -O2 -Wall -Wextra -Werror verify/glref.c -framework OpenGL -o build/glref
shasum -a 256 $UPSTREAM/src/shaders/{border,shadow,corner_clip}.glsl
python3 verify/check.py $UPSTREAM
python3 verify/bgcompare.py $BGRENDER
verify/render_scenes.sh
build/comprender scenes/two_windows.json --gating-test
build/comprender scenes/two_windows_animated.json --gating-test
build/comprender scenes/standin.json --gating-test
build/comprender scenes/two_windows_paper.json --scale 2 --size 1728x1117 --bench 120
build/comprender scenes/standin.json --scale 2 --bench 120
build/comprender scenes/many.json --bench 120
build/comprender scenes/many.json --only PASS --bench 60      # for each pass
build/comprender scenes/standin.json --kind-switch-test
build/comprender scenes/standin.json --churn-test 400
build/comprender scenes/many.json --churn-test 120
build/comprender scenes/overlap.json --scale 2 --churn-test 3000
```

`render_scenes.sh` runs:

```sh
build/comprender scenes/two_windows.json --out out/two_windows_z1_s1.png
build/comprender scenes/two_windows.json --zoom 0.5 --out out/two_windows_z05_s1.png
build/comprender scenes/two_windows.json --scale 2 --out out/two_windows_z1_s2.png
build/comprender scenes/two_windows.json --scale 2 --zoom 0.5 --out out/two_windows_z05_s2.png
build/comprender scenes/two_windows_paper.json --zoom Z --scale S --out out/two_windows_paper_zZ_sS.png   # (1,1) (0.5,1) (1,2) (0.5,2) (1.5,1) (0.7,2)
build/comprender scenes/NAME.json --out out/NAME.png   # overlap partial_clip opacity variants standin standin_mapping chrome_style outlines missing content_rect layers_transform many
build/comprender scenes/standin.json --scale 2 --out out/standin_s2.png
build/comprender scenes/standin.json --zoom 0.5 --out out/standin_z05.png
build/comprender scenes/overlap.json --scale 2 --zoom 1.5 --camera 60,40 --out out/overlap_z15_s2.png
build/comprender scenes/two_windows_paper.json --clear transparent --only shadow,border,content --out out/two_windows_no_background.png
build/comprender scenes/two_windows_animated.json --time 0 --out out/two_windows_animated_t0.png
build/comprender scenes/two_windows_animated.json --time 1 --out out/two_windows_animated_t1.png
```

Also run by hand, outside the script:

```sh
leaks --atExit -- build/comprender scenes/standin.json --scale 2 --out build/tmp/leakcheck.png
leaks --atExit -- build/comprender scenes/overlap.json --churn-test 200
leaks --atExit -- build/comprender scenes/standin.json --gating-test
python3 verify/make_assets.py                      # regenerates assets/stripes.png and assets/app.png, same bytes
xcrun clang --analyze -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc compositor.m comprender.m
COMPRENDER_CHURN_TRACE=1 build/comprender scenes/overlap.json --scale 2 --churn-test 16000   # heap plateaus (CoreVideo's one-second texture age)
xcrun lldb --batch -o run -k "bt 20" -k quit -- build/comprender scenes/many.json --churn-test 120   # the crash in section 15, before the fix
```

For the review fixes (`FW` = the framework list of `build.sh`; everything
written under `build/tmp`, nothing under `review-renders/`):

```sh
cp -R out build/out_before                                   # before any change; all 27 compared with cmp after the last run
# the reviewer's reproductions, against the sources before and after the fixes
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -O2 -g -I. review-renders/variants/T.m \
    build/background.o build/compositor.o $FW -o build/tmp/T_before      # T = retain_test, gate_test; then run
./build.sh
xcrun clang … review-renders/variants/T.m build/background.o build/compositor.o $FW -o build/tmp/T_after   # T = retain_test, retain_test2, gate_test; then run
build/comprender scenes/standin.json --kind-switch-test
build/comprender scenes/standin.json --gating-test
# each new check fails without its fix: compositor.m copied to build/tmp with (a) the two retire calls and the
# full-string hash, (b) the aged flush, (c) the reset of the label's valid flag taken out, linked with build/comprender.o
build/tmp/comprender_unfixed scenes/standin.json --kind-switch-test    # 7 FAIL of 14
build/tmp/comprender_unfixed scenes/standin.json --gating-test         # 2 FAIL
build/tmp/comprender_noaged scenes/standin.json --kind-switch-test     # 2 FAIL of 14
build/tmp/comprender_mut scenes/standin.json --kind-switch-test        # 2 FAIL of 14
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -O2 verify/cvage_probe.m \
    -framework Foundation -framework Metal -framework QuartzCore -framework CoreVideo -o build/tmp/cvage_probe && build/tmp/cvage_probe
python3 verify/check.py ../driftwm-upstream
build/comprender scenes/standin_mapping.json --out out/standin_mapping.png --dump-draws build/tmp/standin_mapping.draws.json
build/comprender scenes/standin_mapping.json --scale 2 --zoom 0.75 --camera 10.5,20.5 --out build/tmp/standin_mapping_s2_z075.png
build/comprender review-renders/scenes/standin_mapping.json --out build/tmp/review_standin_mapping.png   # same bytes as the reviewer's render
build/comprender scenes/two_windows_paper.json --scale 2 --size 1728x1117 --bench 120    # three times, and with review-renders/work/build/comprender
build/comprender scenes/many.json --bench 120                                            # likewise
# address + undefined-behaviour sanitizers
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer \
    -c F.m -o build/tmp/asan/F.o                                         # F = background, compositor, comprender
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fsanitize=address,undefined build/tmp/asan/*.o $FW -o build/tmp/asan/comprender
build/tmp/asan/comprender scenes/standin.json --churn-test 400
build/tmp/asan/comprender scenes/many.json --churn-test 60
build/tmp/asan/comprender scenes/overlap.json --scale 2 --churn-test 1500
build/tmp/asan/comprender scenes/standin.json --kind-switch-test
build/tmp/asan/comprender scenes/standin.json --gating-test
build/tmp/asan/comprender scenes/standin_mapping.json --out build/tmp/asan/standin_mapping.png
xcrun clang --analyze -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc compositor.m comprender.m
leaks --atExit -- build/comprender scenes/standin.json --kind-switch-test
leaks --atExit -- build/comprender scenes/standin.json --gating-test
leaks --atExit -- build/comprender scenes/overlap.json --churn-test 200
leaks --atExit -- build/comprender scenes/standin_mapping.json --out build/tmp/leakcheck.png
verify/run_all.sh ../driftwm-upstream ../background-port/build/bgrender > verify/last_run.log 2>&1   # four times in all; the last is the log
```
