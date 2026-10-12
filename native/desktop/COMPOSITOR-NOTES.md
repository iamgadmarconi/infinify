# Infinify compositor — port notes

> Carried into `native/desktop/` with `compositor.{h,m}` as the standalone module's own notes, unchanged apart from this paragraph and from what section 19.1 says of a background drawn from a chunk cache under "When it is recomputed" (added in this repository with the background's chunk caches): first the port's, and with the effects the notes of the copy that added them, which are the port's (Part I) with Part II after them. Where `compositor.h` and `compositor.m` say `NOTES.md` they mean this file; where `background.h` and `background.m` say it they mean [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md). The notes were written before the module was adopted: "this directory", "this copy" and `compositor-effects/` are that standalone copy, `comprender.m`, `build.sh`, `scenes/`, `assets/`, `out/`, `verify/` and `review-renders/` were not carried in, "the shell" is the shell as it drew before adoption, and sections 3 and 18 are the protocols `canvas-renderer.m` now follows. How it follows section 18 is written where it does so, in `canvas-renderer.h` and `canvas-renderer.m`: which of the controller's lifecycle events plays which animation, and the four things that are the shell's own there. An animation begins one 60 Hz tick before the frame that first shows it when the output has drawn nothing more recent, because this canvas draws on demand (18.2, "Cadence"). A window that opens is held at the animation's first instant, which is invisible, until its stream has delivered its first picture, for a second at most (18.3), and the stand-in whose slot a relaunched window adopted stays whole until that window's first picture likewise (18.4). Each output bakes its own closing snapshot, at upstream's one density, instead of sharing a texture (18.2, "Scale"). And upstream's age limit on a closing window's pixels has nothing to test: the bake is taken from the element of the frame last described, the picture that was on screen (18.2, "When not to"). What the port was run with once adopted is in [README.md](README.md#rendering), and what the effects were run with, joined to the controller, under [What was run for effects](README.md#what-was-run-for-effects).

A standalone Metal port of DriftWM's per-output frame composition: canvas
background, outlines of other outputs' viewports, and every window with its
shadow, border, rounded and clipped content, opacity and (optionally) a
compositor-drawn title bar, plus the stand-ins upstream draws for suspended
windows — and, in this copy, upstream's remaining rendering effects: the
frosted-glass **blur** behind windows, the **open / close animations** with
their closing snapshots, and the **config error bar**. One renderer per output
draws the whole frame; the same code renders a frame offscreen to a PNG.

Upstream: DriftWM, GPL-3.0-or-later, commit
`352333a8fa1b22171492d4b71a54102045c9a19d`. This module is a derived work and
carries the same licence.

**This directory, `compositor-effects/`, is a copy of the reviewed
`compositor-port/` with the effects added.** The existing API is unchanged
and every scene of `compositor-port` renders byte-identically (28 of 28
PNGs, section 23).

- **Part I** (sections 1 to 16) is `compositor-port`'s notes. They still
  hold. Where this copy changed a fact, the text is brought up to date
  (the file table, the provenance tables, the API list, the draw order, the
  pipeline count and cost table, the tool's options and schema, sections 10,
  13 and 16). Measurements and history that were made in `compositor-port`
  and not repeated here are said to be so.
- **Part II** (sections 17 to 25) is the effects: API additions, the host
  protocol for each, how they are built, every deviation from upstream, what
  is kept on purpose, what is not supported, the verification, the cost and
  the commands run.

| File | What it is |
|---|---|
| `compositor.h`, `compositor.m` | The module (Objective-C, ARC). Depends only on `background.h` and system frameworks. |
| `background.h`, `background.m` | The reviewed canvas background module, copied from `background-port/` with one added method (section 14). Not changed in this copy. |
| `comprender.m` | Command-line tool built from the same objects (section 9). |
| `build.sh` | Builds `build/background.o`, `build/compositor.o`, `build/comprender`. Unchanged. |
| `scenes/`, `assets/` | Scene descriptions and test images / test shaders. New here: `scenes/blur.json`, `blur_shapes.json`, `blur_animated.json`, `lifecycle.json`, `lifecycle_timed.json`, `closing_order.json`, `error_bar.json`, `error_bar_many.json`, `effects_all.json`; `assets/shaders/detail.glsl` (a busy test background, not from upstream). |
| `out/` | PNGs of the last `verify/render_scenes.sh` run: the 28 of `compositor-port` and 28 new ones. |
| `verify/` | Verification only. From `compositor-port`, unchanged: `check.py` (driver), `upstream.py` (upstream's Rust geometry and GLSL re-typed in Python), `glref.c` (OpenGL reference running the unmodified upstream `.glsl`), `bgcompare.py`, `make_assets.py`, `pngio.py`, `cvage_probe.m`. New: `check_effects.py` (the effects against OpenGL and re-typed Rust), `glblur.c` (upstream's Kawase chain with the unmodified `blur_down.glsl` / `blur_up.glsl` on OpenGL), `sanitize.sh`, `crop.py` (magnify a region of a PNG to look at it). Extended: `render_scenes.sh`, `run_all.sh`; `last_run.log` is this copy's run (made before the review round recorded in section 23, which changed no renderer source). |

Nothing under the Infinify checkout, `compositor-port/`, `background-port/` or
the upstream checkout was modified, and nothing was built there. Nothing was
committed (the work directory is not a repository).

An independent review of this copy found two things, both accepted (section
23, "Review findings (effects)"): the order inside the closing bucket, which
is now the host's to list as section 18.2 says (deviation 42; no renderer
change), and a false failure of `comprender --blur-cache-test` (fixed in
`comprender.m`). `compositor.m` is unchanged since that review.

# Part I — the compositor (from `compositor-port`)

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
| `ifc_blur_down` | `src/shaders/blur_down.glsl` | `dd87594ca3bf59d641607cbdede7b9c38dbe127a6e95a1a1690c6e01b5f27245` |
| `ifc_blur_up` | `src/shaders/blur_up.glsl` | `5a4bf2dc53f93b08ff3df2e9f3cb68bc2420c612f9bf7a92d1aa3b4acbabfbd9` |
| `ifc_blur_mask` | `src/shaders/blur_mask.glsl` | `5d9b29e10ec0d8e532983b1cb6d2a61960e349a9018ab1f7e4e5a43364560289` |
| `ifc_mirror_copy` | none: stands in for `GL_MIRRORED_REPEAT` on upstream's clipped capture (deviation 25) | — |

The path and the hash are also written beside each translation in
`compositor.m`; `run_all.sh` prints both sides.

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
| `IFCompositorEffectsDefault`, `IFCompositorEffectsSanitized` | `config/types.rs` `EffectsConfig::default`; `config/parse_helpers.rs` `parse_effects_config`, `non_negative`, `unit_range_or_default` |
| `-prepareFrosts:…`, `-prepareFrostOfItem:…`, `-frostKeyForItem:…` | `blur.rs` `process_blur_requests`, `shared_refresh_due`, `backdrop_fingerprint`, `BlurCache` |
| `IFCBlurScreenRect`, `IFCBlurPad`, `IFCQuantizedExtent` | `mod.rs` `compose_frame` (the `wants_blur` block); `blur.rs` `blur_pad`, `quantized_extent` |
| `-encodeBackdropBelow:…`, `-encodeKawaseOn:…`, `-drawFrostOf:…` | `blur.rs` the per-window capture (`backdrop_capture`, `behind_own_chrome`), `render_blur` + `blur_pass`, the splice of the frost element; `mod.rs` `texel_src` |
| `-collectItems:…` (lifecycle), `IFCResolveLife`, `IFCompositorAnimationProgress`, `IFCompositorOpenAlpha`, `IFCompositorOpenScale` | `state/window_animation.rs` `animated_visual`, `scaled_about_centre`, `open_alpha`, `open_scale`, `tick_entry`; `state/window_animation_driver.rs` `tick_window_animations_at`; `mod.rs` `WindowRenderAnimation`, `FadeRender` |
| `-drawSnapshot:…`, `IFCompositorCloseAlpha`, `IFCompositorCloseScale` | `closing.rs` `ClosingSnapshot::render_element`, `fade_out_alpha`, `StandInFade` |
| `-closingSnapshotOfElement:inFrame:flattenScale:` | `closing.rs` `flatten`, `snapshot_canvas`, `snapshot_screen`, `phys_size_of`; `shaders.rs` `bake_shadow_element`, `bake_border_element` |
| `-drawErrorBar:…`, `IFCRenderErrorBar`, `IFCompositorErrorBarText` | `error_bar.rs` `build_error_bar_elements`, `render_error_bar`, `join_errors` |

Rust's numeric rules are reproduced where they decide a pixel: `f64::round`
(half away from zero), `as i32` (truncation, saturating), `as u8`, and `f32`
arithmetic wherever upstream narrows to `f32`.

## 2. Public API

Everything is in `compositor.h`. What this copy added is listed in section 17;
the list below is `compositor-port`'s and unchanged.

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
| `element.contentGeneration` | the actual image generation, advanced when accepted pixel content changes |
| `element.focused` | `placements[].focused` |
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
budget itself (`background_animation_due`). (`needsContinuousRedraw` is now
also YES while an open or close animation runs on the frame's clock, section
18; those redraw on every tick, whatever `animate_fps` says.)

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

**Blur, opening and closing windows, the error bar.** Section 18.

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

The frame is one render pass. (When an element asks for blur, the passes that
build its frost run before that pass, into textures of their own: section
19.1.) Bottom to top:

1. clear (opaque black or transparent);
2. background (replaces the cleared pixels);
3. output outlines;
4. elements: all `widget`, then all `normal`, then the `closing` bucket (every
   snapshot, and whatever the host put there), then all `pinned`, each bucket
   in list order — also the closing bucket, whose order upstream fixes itself:
   the host lists it as section 18.2 says ("Order in the closing bucket").
   Per window: shadow, frost (if `blur`), border, content, title bar. Per
   stand-in: shadow, border, title bar, body, label. Per snapshot: its one
   texture;
5. the error bar, if there are messages.

That is upstream's list read backwards (upstream's vector is top to bottom:
cursor, error bar, overlay and top layers, pinned, closing, normal, canvas
layers, widgets, bottom layer, outlines, background; per window: popups, bar,
content, border, frost, shadow). Because each element's passes are
consecutive, an upper window's shadow falls on the lower window with no extra
work.

Every pass blends premultiplied source-over, `(ONE, ONE_MINUS_SRC_ALPHA)` on
colour and alpha, as smithay sets `glBlendFunc`. (The passes inside a frost do
not: section 19.1.)

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

- Shared per device: ten pipelines (six of `compositor-port`, four for the
  blur), two samplers (clamp; mirrored repeat for the blur), one command
  queue.
- What the effects hold and cost: sections 18.1 and 24.
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

Apple M5 Pro, `comprender --bench 120`, per frame, from this copy's
`verify/last_run.log`:

| Scene | Target | Draws | CPU encode | GPU |
|---|---|---|---|---|
| 2 windows over the paper shader | 3456×2234 | 6 | 0.01 ms | 0.35 ms |
| 4 stand-ins + 2 server-decorated windows | 1800×1040 | 28 | 0.02 ms | 0.27 ms |
| `many.json`: 300 overlapping windows + 20 stand-ins | 3456×2234 | 1000 | 0.42 ms | 4.41 ms |

`many.json` by pass: background 0.40, shadow 2.13, border 0.37, content 1.94,
bars / bodies / labels 0.36 ms. `compositor-port`'s own log read 0.02 / 0.42,
0.02 / 0.17 and 0.46 / 4.33 ms for the three scenes; the figures move by a few
tenths of a millisecond between runs (this copy's previous run of the same
script, an hour earlier, read 0.26, 0.22 and 4.11 ms GPU). Run against each other, interleaved,
this copy's encode of `many.json` is about 0.03 ms slower than
`compositor-port`'s and the GPU time is the same (deviation 41).
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

Since this copy: the hash also covers `effects`, the error messages, each
element's `blur` flag and lifecycle state, and — for an animation that runs on
`lifecycleStartTime` and is not yet finished — its progress at `frame.time`.
That is the one way `time` reaches the hash: such a frame redraws on every
tick until the animation is over, and `time` alone still redraws nothing
otherwise (`--lifecycle-test`, section 23). The animated background's
`animate_fps` gate is unchanged and applies to the background only.

## 9. comprender

```
comprender scene.json --out frame.png
           [--scale S] [--zoom Z] [--camera X,Y] [--size WxH] [--time T]
           [--clear opaque|transparent] [--only PASS[,PASS...]]
           [--blur-radius N] [--blur-strength X] [--animation-scale A] [--animation-speed V]
           [--via-layer] [--dump-bgra FILE] [--dump-draws FILE.json]
           [--gating-test] [--bench N] [--bench-pan N] [--churn-test N] [--kind-switch-test]
           [--lifecycle-test] [--blur-cache-test]
comprender --blur-test IN.bgra W H PASSES OFFSET OUT.bgra [--blur-stages PREFIX]
```

Exit status 0: rendered as described; 1: rendered, but the background fell
back (reason on stderr as `error: ...`); 2: usage, scene or I/O failure.
`--gating-test` and `--kind-switch-test` print `FAIL` and exit with 1 when a
long string's change did not redraw, or when something stayed allocated or
drew differently after a change of kind.
`--only` takes `background, outline, shadow, border, content, title_bar, body,
label, blur, snapshot, error_bar`. `--dump-draws` writes each draw's
destination rectangle, scissor and uniforms; the draws of a frost's own passes
are not listed, but each blurred window adds a `blur_info` record (screen
rectangle, capture rectangle, pad, passes, offset, whether it was recomputed).
New in this copy: `--blur-radius`, `--blur-strength`, `--animation-scale`,
`--animation-speed` override the scene's `effects`; `--bench-pan` is `--bench`
with the camera moving a point per frame (every frost recomputed);
`--lifecycle-test` and `--blur-cache-test` print PASS / FAIL lines and exit
with 1 on a failure. `--blur-cache-test` expects a frost for the blurred
windows that have one on this output: those the renderer reports a
`blur_info` record for in the encode at hand, i.e. whose padded capture
reaches the output (counted per encode, because a camera move or a larger
pad can bring a capture onto the output). A blurred window off the output has
no frost (upstream: "frost left unrendered: the padded capture is entirely
off the output"); such windows are counted in a second header line and not
expected. The test drives the last listed blurred window whose top-left
corner is on the output (it puts an element just inside that corner). A scene
is refused with exit status 2 when no blurred window's capture reaches the
output, when none of those windows has its top-left corner on the output, or
when it has no background and a blurred window on the output got no frost in
the first frame (a window with nothing drawn beneath it has none, upstream's
"frost zeroed"; a background is always beneath). `--blur-test` needs no scene and runs the renderer's
Kawase passes over a raw image (with `--blur-stages`, also the whole texture
each pass wrote). A render of a scene with error messages prints the joined
text as `error bar: …`.

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
  "effects": {"blur_radius": 2, "blur_strength": 1.1, "animate_blur_fps": 20,   // upstream [effects], its defaults
              "animation_speed": 0.5, "animation_scale": 0.95},
  "errors": ["config error: …", "…"],      // the error bar's messages; absent or empty: no bar
  "outline": {"color": "#ffffff", "thickness": 1, "opacity": 0.5,
              "rects": [[x, y, w, h]],                                      // output-local points
              "outputs": [{"camera": [x, y], "size": [w, h], "zoom": 1}]},  // projected with upstream's math
  "decoration": { … },                     // defaults for every element, same keys as below
  "elements": [                            // bottom to top
    {"id": 1,
     "kind": "window",                     // window | standin | snapshot
     "rect": [x, y, w, h],                 // required (not for a snapshot with "snapshot_of")
     "blur": false,                        // frosted glass behind a window
     "lifecycle": {"type": "open",         // open | close | close_alpha_only
                   "progress": 0.5},       //   explicit progress, or instead: "start": t (the frame time it began at)
     "snapshot_of": { … },                 // kind snapshot: a window object (same keys as an element); it is baked with
                                           //   -closingSnapshotOfElement:inFrame:flattenScale: and the snapshot takes its
                                           //   place; "flatten_scale": s (default, as upstream: output scale x zoom, at
                                           //   least 1; the output scale for a pinned window); the outer
                                           //   "decoration": {"opacity": …} multiplies the fade. Without "snapshot_of" a
                                           //   snapshot takes "rect" and "content" (always through a texture)
     "space": "canvas",                    // canvas | output | pinned
     "replaces": "client",                 // standin only, canvas or pinned space: `rect` is the rectangle of the
                                           // client- | server-decorated window it replaces; the element gets
                                           // IFCompositorStandInBodyRect(rect, …, chrome.title_bar_height)
     "layer": "normal",                    // normal | widget | pinned | closing
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

## 10. Blur and closing animations

`compositor-port` sketched here how blur and closing animations would slot
in. Both are implemented in this copy, and not quite as sketched:

- **Closing**: as sketched — a bake of the window into one texture, an
  element that plays it, a closing bucket between normal and pinned — as
  `-closingSnapshotOfElement:inFrame:flattenScale:`,
  `IFCompositorElementKindSnapshot` and `IFCompositorStackLayerClosing`.
- **Blur**: the sketch ended the frame's pass before each blurred window and
  copied its rectangle out of the target. Upstream does not read the frame
  back: it draws everything below the window again into a texture of its own
  (without the frost of other windows, over opaque black, mirrored where it
  leaves the output). That is what is built, so the frame stays one pass and
  the layer stays `framebufferOnly`.

What section 10 said about the pieces already in place still holds: every
element has `decoration.opacity` and an optional `IFCompositorTransform`
(upstream's `WindowRenderAnimation`), and move / resize animations need
nothing more than the host driving those two fields each tick.
Sections 17 to 25.

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

Deviations 24 to 41 (the effects) are in section 20.

## 12. Upstream behaviour kept on purpose

(The effects: section 21.)

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

- resize crossfades, and the parts of the effects listed in section 22
  (the shared backdrop, client blur regions);
- popups and subsurfaces (a macOS menu is its own window);
- layer-shell layers, canvas layers, the cursor, the drag icon, the
  session-lock frame;
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

`verify/run_all.sh <driftwm checkout> <bgrender> <compositor-port/out>`
reproduces the table below — except its rows made by hand (the sanitizer
build, `leaks`, `clang --analyze`; this copy's own are in section 23) and its
last row, which is history — and section 23's checks of the effects. Its
complete output is `verify/last_run.log`: 443 PASS lines, no FAIL; of this
section, 211 checks of `check.py`, 21 lines for the 42 background comparisons
and 14 of the kind-switch test, all against this copy's build, with the same
megabyte and retain-count figures as before. The churn test does more in this
copy (section 23), so its counters differ a little from the row below (300
windows, 120 frames: 22,911 wrappers and 11,273 chrome rasters now).

The rest of this section — what was found and fixed, the review findings,
what was looked at and what was not run — is `compositor-port`'s record. The
measurements quoted in it that are not printed by `run_all.sh`
(`cvage_probe.m`, the reviewer's reproductions, the builds with a fix taken
out again) were made there and not repeated for this copy.

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

**Looked at** (in `compositor-port`, where each of these PNGs was opened; the
ones in this copy's `out/` are byte-identical to them and were not opened
again):

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

The commands `compositor-port` ran are in its own `NOTES.md`, section 16.
What was run for this copy — which includes all of `compositor-port`'s
`run_all.sh` — is in section 25.

# Part II — effects: blur, lifecycle animations, error bar

Everything below is new in `compositor-effects/`. Upstream files read for it,
all at commit `352333a8fa1b22171492d4b71a54102045c9a19d`:
`src/shaders/{blur_down,blur_up,blur_mask}.glsl`, `src/render/blur.rs`
(`process_blur_requests`, `render_blur`, `blur_pass`, `blur_pad`,
`backdrop_capture`, `backdrop_fingerprint`, `shared_refresh_due`,
`quantized_extent`, `BlurCache`), `src/render/mod.rs` (the `wants_blur` block,
the element order, `texel_src`, `transform_phys_rect`, `FadeRender`),
`src/render/closing.rs`, `src/render/error_bar.rs`,
`src/render/shaders.rs` (`bake_shadow_element`, `bake_border_element`),
`src/state/window_animation.rs` (`open_scale`, `open_alpha`,
`scaled_about_centre`, `animated_visual`, `tick_entry`),
`src/state/window_animation_driver.rs` (`tick_window_animations_at`, the
snapshot built at teardown), `src/config/types.rs` (`EffectsConfig`,
`effective_blur`), `src/config/parse_helpers.rs` (`parse_effects_config`),
`docs/config.md` (`[effects]`, the `blur` rule), `src/tests/blur_pixels.rs`.
`src/render/lifecycle.rs`, named in the brief, holds frame callbacks and
presentation feedback, nothing that is drawn: the open animation lives in
`src/state/window_animation.rs`.

## 17. API additions

All in `compositor.h`. Nothing was removed and no signature changed; enum
values were appended (`IFCompositorElementKindSnapshot`,
`IFCompositorStackLayerClosing`, three `IFCompositorPass` bits);
`IFCompositorDecoration` is unchanged.

- **`IFCompositorEffects`** — upstream `EffectsConfig`, field for field:
  `blurRadius` (2), `blurStrength` (1.1), `animateBlurFPS` (20),
  `animationSpeed` (0.5), `animationScale` (0.95).
  `IFCompositorEffectsDefault()`, `IFCompositorEffectsSanitized()` (upstream's
  parse rules). `frame.effects`.
- **`element.blur`** — the per-element blur flag (upstream `effective_blur`).
- **`IFCompositorElementKindSnapshot`** — a closing snapshot: one retained
  texture drawn as a single piece. **`IFCompositorLifecycle`** (`None`,
  `Opening`, `Closing`, `ClosingAlphaOnly`) with `element.lifecycle`,
  `element.lifecycleStartTime` (frame time; NaN = unset) and
  `element.lifecycleProgress` (explicit, used when no start time is set).
- **`IFCompositorStackLayerClosing`** — upstream's `zoomed_closing` bucket,
  above normal windows and below pinned ones.
- **`-[IFCompositorRenderer closingSnapshotOfElement:inFrame:flattenScale:]`**
  — bakes a live window into a snapshot element.
- **`frame.errorMessages`** — the error bar. `IFCompositorErrorBarText()`,
  `IFCompositorErrorBarHeight()`.
- **`-[IFCompositorFrame lifecycleProgressOfElement:]`,
  `-lifecycleFinishedForElement:`**; `needsContinuousRedraw` is now also YES
  while an animation that runs on `lifecycleStartTime` is not finished.
- Upstream's curves as functions: `IFCompositorAnimationProgress(elapsed,
  speed)`, `IFCompositorAnimationFinished(p)`,
  `IFCompositorAnimationDuration(speed)`, `IFCompositorCloseAlpha(p)`,
  `IFCompositorCloseScale(p, amplitude)`, `IFCompositorOpenAlpha(p)`,
  `IFCompositorOpenScale(p, amplitude)`.
- `IFCompositorPassBlur`, `IFCompositorPassSnapshot`,
  `IFCompositorPassErrorBar`.
- Diagnostics: `blurComputeCount`, `blurTextureAllocationCount`,
  `blurTextureCount`, `-debugBlurBGRA:width:height:passes:offset:stages:`
  (the renderer's own Kawase passes over caller-supplied pixels; what
  `comprender --blur-test` and the OpenGL comparison use).

## 18. Host protocol

### 18.1 Blur

```objc
frame.effects = effects;        // once per config load: [effects], through the vendored parser
element.blur = effective_blur;  // per window, whenever its rule or fullscreen state changes
```

- `effective_blur` is the vendored helper of
  `crates/core/src/config/types.rs`:
  `applied.is_some_and(|r| r.blur) || (decorations.blur && !is_fullscreen)` —
  a window rule `blur = true` always, the global `[decorations] blur` for a
  window that is not fullscreen. It is a plain flag: do not route it through
  `IFCompositorDecorationDrawn`.
- That is all. The renderer captures what is beneath the window, blurs it,
  masks it and keeps the result; the layer keeps `framebufferOnly`, and
  `-updateWithFrame:` is called exactly as before. A frost is recomputed only
  when something it is made from changed (section 19.1, "When it is
  recomputed").
- The frost is drawn at full strength whatever the window's opacity, under
  the window's border, content and title bar. It shows only where the window
  lets it: through content with alpha below 1, or under a window whose
  `decoration.opacity` is below 1. An opaque window with `blur` set pays for a
  frost nobody sees, as upstream.
- A stand-in or a snapshot is never frosted (upstream requests blur for
  client windows and layer surfaces only).
- **Animated background:** nothing to do. The layer redraws at the
  background's `animate_fps`; the frost follows at `effects.animateBlurFPS`
  (0 = it keeps what the background looked like when it was last captured).
- **Screenshots:** leave `blur` off, as upstream's screenshot composer does
  ("omits blur"). If it is set on a frame with a transparent clear, the frost
  is still computed over opaque black (deviation 32).
- **Memory:** per blurred window a frost and a mask of the window's size on
  screen, rounded up to 64 px steps, and — while its frost keeps being
  recomputed, and for 60 encodes after — a pad pair of that size plus the blur
  reach on every side; one background copy of the output's size per output
  while any frost is recomputed. A 600 × 600 px frost: 1.6 MB + 1.6 MB, pads
  2 × 1.6 MB. `-purge` drops all of it.

### 18.2 A window closes

Upstream bakes the dying window, with all its chrome, into one texture at the
moment it is torn down, removes the window, and plays the snapshot.

```objc
// while the element still holds the window's last buffer
IFCompositorElement *snapshot = [layer.renderer closingSnapshotOfElement:windowElement
                                                                 inFrame:frame
                                                            flattenScale:frame.scale * frame.zoom];
if (snapshot) {
    snapshot.lifecycleStartTime = timeOfTheLastFramePresented;   // see "Cadence"
    [frame.elements removeObject:windowElement];
    // In front of the first snapshot in the list, else at the end: below every snapshot
    // still running, above every fading stand-in. See "Order in the closing bucket".
    NSUInteger at = 0;
    while (at < frame.elements.count && frame.elements[at].kind != IFCompositorElementKindSnapshot) at++;
    [frame.elements insertObject:snapshot atIndex:at];
}
// every display tick while layer.needsContinuousRedraw:
frame.time = now;
[layer updateWithFrame:frame];
if ([frame lifecycleFinishedForElement:snapshot]) [frame.elements removeObject:snapshot];
```

- **When to capture.** On the event that tells the host the window is gone
  (the stream stopped, the window left the window list), before the host
  drops `latestSample`: the bake samples `element.pixelBuffer` (or `texture`)
  as it stands, through the same wrapper a frame uses. Call it on the thread
  that uses the renderer, never inside `-encodeFrame:`. The bake is encoded on
  the renderer's queue and is complete before any later frame samples it; the
  call does not wait for the GPU. After it returns the host may release the
  buffer and the window's element.
- **When not to.** Upstream skips the snapshot when the close cannot be seen
  (the window is on no output) and when the last content is older than one
  second (`MAX_CLOSE_PIXEL_AGE`: a window hidden long ago must not fade in
  what it looked like then). Both are the host's to check. At
  `animation_speed = 1` the snapshot is over on its first tick: skip it.
  Upstream also draws no snapshot and no stand-in fade on an output that is
  visually fullscreen ("no dying-window flash over a fullscreen app",
  mod.rs): leave them out of that output's frame.
- **What it returns.** An element of kind `Snapshot` with the bake as its
  `texture`, the rectangle the bake covers (the window's rectangle grown by
  border and shadow) as its `rect`, in the window's own `space`, with the
  window's `identifier` and clip, `lifecycle = Closing`. Under that
  identifier the renderer lets go of what it held for the live window — its
  buffer wrapper, title bar and frost — when it first draws the snapshot
  (read off the code path; not measured the way `--kind-switch-test` measures
  a window that becomes a stand-in). If the window's element stays in the
  frame as well, give the snapshot another identifier. Its position in the
  list does not matter against windows (it is drawn in the closing bucket);
  inside that bucket list order holds, and the next point says what the
  order has to be.
- **Order in the closing bucket.** Upstream keeps its closing snapshots and
  its stand-in fades in two lists, each in the order they were created
  (`closing_snapshots.push`, `standin_fades.push`), and emits them top-most
  first: the snapshots (closing.rs `render_snapshots_for_output`, "top-most
  first"), then every fade (mod.rs appends them to `zoomed_closing` after the
  snapshots). So of the windows that are closing at the same time the one
  that began to close **first is on top**, whatever their stacking was while
  they lived; a window that closes later goes beneath the snapshots still
  running; and every fading stand-in is beneath every snapshot, an older fade
  above a newer one. The renderer does not sort the bucket: it draws it in
  list order, bottom to top (deviation 42). The host gets upstream's stacking
  by listing the bucket as upstream's two lists read backwards — the fading
  stand-ins, newest first, then the snapshots, newest first:
  - a new snapshot goes in front of the first snapshot already in
    `frame.elements`, or at the end of the list when there is none (the
    sample above);
  - a new stand-in fade goes in front of every other element of the bucket
    (index 0 of `frame.elements` does).

  Where the bucket's elements sit among the windows makes no difference.
  Putting the snapshot at the dead window's index instead keeps the stacking
  the windows had alive, which is not upstream's whenever the lower of two
  overlapping windows closes first within one animation (0.11 s at the
  default speed, up to 7 frames), or a stand-in fades at an index above a
  snapshot's: the overlap then shows the wrong one of the two.
  `scenes/closing_order.json` (`out/closing_order.png`) is listed upstream's
  way: a fading stand-in, a snapshot at progress 0, an older one at 0.5.
- **Scale.** `flattenScale` is the density of the bake. Upstream uses, for a
  canvas window, the largest `backing scale · zoom` among the outputs that
  show it, never less than 1 (`flatten_scale_for_canvas_rect`), and for a
  pinned or fullscreen window the backing scale of its output; and it shares
  the one snapshot between outputs. Here too: the texture belongs to the
  Metal device, not to the renderer, so one bake at the largest density can
  be put in every output's frame (one element per frame, sharing `texture`).
  Values below 1 are raised to 1 by the renderer.
- **Cadence.** Upstream gives the snapshot progress 0 and advances every
  animation before it draws: the first frame that shows the snapshot is
  already one tick in (progress 0.5 at 60 Hz and the default speed; then
  0.75, 0.875, 0.9375, 0.969, 0.984, and it is gone on the seventh tick).
  Passing the time of the last presented frame as `lifecycleStartTime`
  reproduces that. Passing the current frame's time shows one frame of the
  untouched snapshot first.
- **Variants.** A pinned window (`IFCompositorSpacePinned`) gives a pinned
  snapshot: screen space, zoom 1 (upstream `snapshot_screen`). A fullscreen
  window bakes bare if its decoration went through
  `IFCompositorDecorationDrawn(…, fullscreen = YES, …)` first. A close that
  turns into a stand-in fades in place: set
  `lifecycle = IFCompositorLifecycleClosingAlphaOnly` on the snapshot. Each
  of these is a snapshot like any other for the order above (upstream pushes
  them all onto the one `closing_snapshots` list).
- **Opacity.** The bake is drawn at alpha 1 and the snapshot fades from 1, as
  upstream: a window that was translucent turns opaque for the length of its
  close. To avoid that, set the snapshot's `decoration.opacity` to the
  window's (deviation 35).
- A snapshot has no frost, whatever the window had (upstream).

### 18.3 A window opens

```objc
element.lifecycle = IFCompositorLifecycleOpening;
element.lifecycleStartTime = timeOfTheLastFramePresented;
// tick while layer.needsContinuousRedraw; afterwards, at leisure:
if ([frame lifecycleFinishedForElement:element]) element.lifecycle = IFCompositorLifecycleNone;
```

The live window is drawn scaled about its own centre from `animation_scale`
up to its size, with its opacity multiplied by `1 − (1 − p)²`; chrome and
frost ride along. Once finished it is drawn as the plain window whether or not
the host clears `lifecycle` (clearing it costs one redraw of the same
picture). While it runs it replaces the element's own `transform`. Upstream's
other window animations (move, resize, fit, the fullscreen legs) are not
lifecycle states: they stay with the host's animation driver through
`transform` and `decoration.opacity`, as section 10 says.

### 18.4 A stand-in leaves

Upstream's `StandInFade`: a stand-in element with
`layer = IFCompositorStackLayerClosing` and `lifecycle = Closing` (a
dismissed stand-in: fades and shrinks about the centre of bar + body) or
`ClosingAlphaOnly` (the adoption crossfade over the window that took its
place: fades without moving). Remove it when
`-lifecycleFinishedForElement:` says so. List it in front of every other
element of the closing bucket — beneath every snapshot and every older fade,
as upstream stacks them (18.2, "Order in the closing bucket").

### 18.5 Error bar

```objc
frame.errorMessages = messages.count ? messages : nil;   // on every change of the error set
```

`messages` are the values of upstream's `state.errors`, in the order of their
sources: config, background, keyboard (`ErrorSource`). The background source's
message is what the background module already reports as
`IFBackgroundProgram.errorText`. Every output shows the bar (upstream builds
it per output), at `frame.decorationScale`. It is a picture only: input
passes through it upstream, so the host must not hit-test it.

## 19. How it is built

### 19.1 Blur

One command buffer per frame, as before; the frame itself is still one
render pass into the target. Before that pass opens, for every blurred window
whose frost is not up to date:

1. **Backdrop** (blur.rs, the per-window capture). Everything *below* the
   window is drawn again into a texture: opaque black, the background, the
   outlines of other outputs, and every lower element with all its chrome —
   and without the frost of any other window, because upstream captures from
   the element list before any frost is spliced into it. The window's own
   shadow is not below it (`behind_own_chrome`). The texture is the window's
   screen rectangle grown by `pad` on every side; the draws are the frame's
   own, moved by a whole number of pixels (upstream `RelocateRenderElement`).
   The background module cannot be moved (it computes from the pixel
   position), so the background is drawn once per encode into an
   output-sized copy and placed from there (deviation 24).
2. **Overhang.** When the padded rectangle leaves the output, only the part
   on the output is captured, and the rest is filled by reflecting it about
   the output's edge (upstream: `GL_MIRRORED_REPEAT` on a clipped scratch
   texture; here `ifc_mirror_copy`, deviation 25).
3. **Dual Kawase** (`render_blur`, `blur_pass`): `blur_radius` downscale
   passes with `blur_down.glsl`, then as many upscale passes with
   `blur_up.glsl`, ping-ponging between two textures of the padded extent.
   Pass `i` reads the top-left `extent >> src_shift` of one and writes the
   top-left `extent >> dst_shift` of the other; texture coordinates are
   normalised over the whole texture; `u_halfpixel` is `1 / src` (down) or
   `0.5 / src` (up) and `u_offset` is `offset / 2^src_shift`, with
   `offset = (float)blur_strength · (float)scale`. Sampling is linear with
   mirrored repeat and is *not* confined to the region a pass reads, exactly
   as upstream: the taps at the right and bottom edge of a mip read what an
   earlier pass left beside it (section 21).
4. **Crop.** The window-sized centre, at `(pad, pad)`, is copied into the
   frost texture.
5. **Mask.** The window's own elements except its shadow — border, clipped
   content, title bar — are drawn into a window-sized texture over
   transparent, with the window's origin at (0, 0). `blur_mask.glsl` turns
   its alpha into 0 or 1 at a threshold of 0.001 and the frost is multiplied
   by it (blend `(ZERO, SRC_ALPHA)` on colour and alpha).

In the frame's pass the frost is then one textured quad at alpha 1, drawn
after the window's shadow and before its border.

**When it is recomputed.** A frost is kept per element and reused while a
64-bit hash of everything it is made from is unchanged: the view (output
size, scale, camera, zoom), the background object and, for a background drawn
from a chunk cache, the generation of its chunks (below), the chrome style and
decoration scale, the placeholder colour, the outlines, `blur_radius` and
`blur_strength`, the window's own description *without* the identity of its
content, and the full description — content identity included — of every
lower element that can reach the padded capture rectangle. So: a window's own
new frames do not re-blur it; a video playing under it does; one playing
beside it or above it does not; a pan or a zoom re-blurs everything. Upstream
decides the same things from element ids, commit counters and geometry
(`backdrop_fingerprint`, `ViewStamp`, the geometry generation). Kept from
upstream as they are: the first two encodes after a frost is created always
recompute (`force_dirty_frames`), and so do the first 8 changes of the
window's own content (`mask_warmup_commits`), so a first buffer that arrives
empty does not leave an empty mask behind. A background that moves on its own
(`isAnimated`) re-blurs every frost at most `animate_blur_fps` times a second
of `frame.time`, never at 0 (`shared_refresh_due`).

A background drawn from a chunk cache (a baked `cache_shader`, a pyramidal
TIFF: [BACKGROUND-NOTES.md](BACKGROUND-NOTES.md), section 17) changes its
picture at a fixed view while its cache fills: a chunk is baked or uploaded
and a sharper level replaces a coarser one. Upstream draws each chunk as an
element of the background, and a changed list of those is a refresh that is
due at once, like a change of view (`background_structure_changed`). Here
`-[IFBackgroundProgram chunkGenerationForFrame:]` stands for that list: the
encode calls it before `-prepareFrosts:…`, on frames that have a blurred
window, which makes the background do that frame's chunk work then instead of
inside its own encode later, and the number it returns is mixed into the
shared refresh and into each window's hash. It is 0 for any other background.

**Nothing beneath.** When no draw reaches the capture (no background, no
lower element there) there is no frost at all, as upstream zeroes it instead
of frosting the clear colour.

**Zoom and scale.** The zoom enters only through the window's rectangle on
screen: the blur has the same reach in *physical pixels* at any zoom, so a
window zoomed out to half its size is blurred twice as coarsely relative to
its content (`out/blur_z05.png`). The backing scale multiplies the tap
distance and the pad, so the frost looks the same in logical pixels at 1x and
2x. The rectangles:

- `screen_rect = painted_rect((trunc(x·z), trunc(y·z), ceil(w·z), ceil(h·z)), s)`
  for a client-decorated window whose content is `(x, y, w, h)` before zoom;
  under a server-side bar the rectangle starts `trunc(bar·z)` higher and is
  `ceil((h + bar)·z)` high. Then the window's animation transform, if any
  (`transform_phys_rect`). This is upstream's rectangle and not the content's
  own (`corner_round_rect`): the two can differ by a pixel.
- `pad = clamp(ceil(offset · 2^(passes + 1)), 16, 256)` physical pixels.
- The frost element: at `screen_rect.loc`, logical size
  `round(screen_rect.size / s)`, sampling exactly `screen_rect.size` texels.

### 19.2 Lifecycle

- **Progress.** Upstream advances every animation once per frame:
  `p += (1 − p) · f`, `f = 1 − (1 − speed)^(dt · 60)`. `1 − p` is therefore
  multiplied by `(1 − speed)^(dt · 60)` per tick, and after ticks adding up to
  `t` it is `(1 − speed)^(60 t)` whatever the ticks were. The renderer
  computes `p = 1 − (1 − speed)^(60 · (frame.time − start))` and is done, like
  upstream, when `1 − p ≤ 0.01`: 0.111 s at the default speed 0.5, 0.267 s at
  0.25, 0.033 s at 0.9.
- **Closing snapshot** (`ClosingSnapshot::render_element`): alpha
  `1 − p²`; scale `1 − (1 − animation_scale) · p` about the centre of its
  rectangle on screen, in physical pixels; the rectangle is the texture
  element's — location rounded, size `round(size · zoom)` logical pixels
  through the output scale — and each corner is rounded after the scale. A
  finished snapshot is not drawn.
- **The bake** (`flatten`): the window through the frame's own draw path at
  zoom 1, alpha 1 and the given scale, over transparent: shadow, border,
  clipped content, title bar. Its extent is the body (content plus bar) merged
  with the shadow's and the border's areas, `ceil(extent · scale)` texels.
- **Opening** (`animated_visual` + `WindowRenderAnimation`): the rectangle
  scaled about its own centre by `animation_scale + (1 − animation_scale) · p`
  becomes a transform — origin at the content's top-left, the offset by which
  that corner moved, the size ratio — in physical pixels after zoom; alpha
  `1 − (1 − p)²` multiplies the window's opacity. The frost's rectangle goes
  through the same transform.
- **Stand-in fade** (`StandInFade`, `FadeRender`): alpha `1 − p²` on every
  pass of the stand-in; unless alpha-only, a shrink
  `1 − (1 − animation_scale) · p` about
  `((x + w/2) · z · s, (y − bar/2 + h/2) · z · s)`.
- **Order.** Widgets, normal, closing, pinned. A snapshot is always in the
  closing bucket, also a pinned window's. Inside the closing bucket the order
  is the list's; upstream's (fades beneath snapshots, in each group the
  oldest on top) is the host's to list (section 18.2, deviation 42).
- **Redraw.** The layer's fingerprint contains the progress of every
  animation that is still running, so it redraws on every tick while one
  runs and not after; `time` alone still redraws nothing.

### 19.3 Error bar

`ceil(11) + 2 · 6 = 23` logical pixels high, as wide as the output, at
`(0, height − 23)`, not zoomed, drawn after every element. The buffer is
`width · d` × `23 · d` pixels (`d` = decoration scale), opaque black, with the
messages — each with its whitespace runs collapsed, joined by two spaces, a
bullet, two spaces — in white `monospace` of `11 · d` px (pixels, not points),
normal weight, starting `12 · d` px in, cut with an ellipsis to fit
`width · d − 24 · d`, vertically centred as `rasterize_into` does. One
texture per renderer, rebuilt when the messages, the width or the scale
change.

## 20. Deviations from upstream (effects)

Numbered on from Part I.

24. **The backdrop's background comes from a copy.** Upstream relocates the
    background's own elements into each capture. The background module here
    computes from the pixel position, so each encode that recomputes at least
    one frost first draws the background once into an output-sized texture,
    and every backdrop draws from that with a 1:1 textured quad. Same values;
    one extra background draw and one output-sized texture per output
    (3456 × 2234: 30.9 MB), freed 60 encodes after the last frost was
    recomputed and at once when no element asks for blur.
25. **A clipped capture is mirrored in place.** Upstream renders the part of
    the padded rectangle that is on the output into a scratch texture of
    exactly that size and crops it with `GL_MIRRORED_REPEAT`; the scratch
    textures are pooled by extent, and a new extent — every frame of a pan
    with a frosted window across the output's edge — is a new texture. Here
    that part is drawn in place inside the second pad texture and the first is
    filled from it by `ifc_mirror_copy`, which reflects texel indices about
    its edges (`k mod 2n`, mirrored from `n` on). The same texels (the
    overhanging cases of section 23 are compared against a Python
    `GL_MIRRORED_REPEAT`), and nothing is allocated while such a window moves.
26. **The second pad texture starts transparent.** Upstream never initialises
    it (`create_buffer`), and the taps at the right and bottom edges of the
    mips read it: the result there is whatever the driver handed over. Here
    the first pass clears it. Measured with the unmodified GLSL, zeros
    against noise in that texture, in the centre the frost keeps: no pixel
    changes at the defaults at 1x (300 × 200 window); 148 of 240,000 by one
    level at 2x; 1310 of 60,000 by one level, up to 9 px in from the right /
    bottom edge, at 3 passes; 9585 of 60,000 by one level, up to 88 px in, at
    5 passes and strength 1.5 at 2x.
27. **The frost and mask textures are not cleared on allocation.** Upstream
    zeroes the slack of the quantised allocation because a fractional scale
    can sample into it. Here every read of either is confined to the live
    extent (`uv_bounds`, section 11 deviation 2).
28. **What invalidates a frost** is a hash of descriptions (section 19.1), not
    element ids, commit counters and damage. Differences that follow: the
    reach test for lower elements is a generous bounding box (content grown by
    border, shadow and title bar; anything animated always counts), where
    upstream asks each element's own geometry; the mask is drawn again every
    time the frost is recomputed, where upstream keeps it until the geometry,
    the extent or the warm-up says otherwise (same pixels unless the window's
    alpha shape changed meanwhile, in which case this one is fresher); a
    change of the window's own opacity or decoration recomputes.
29. **`animate_blur_fps` runs on `frame.time`**, not on wall time, with a
    tenth of a millisecond of slack so that three display intervals of 1/60 s
    count as 1/20 s (without it rounding made the cadence 15 a second instead
    of 20).
30. **No shared backdrop.** See section 22.
31. **`blur_radius` above 30 is treated as 30** (upstream's
    `1u32 << (passes + 1)` overflows there), and an infinite `blur_strength`
    as 0.
32. **Blur on a frame with a transparent clear is drawn.** Upstream's
    screenshot composer draws none. The backdrop is captured over opaque black
    all the same, so such a frost is opaque.
33. **Progress in closed form**, from a start time on the frame's clock (or
    given outright), instead of a per-frame recurrence owned by the
    compositor. Identical numbers (section 23); which tick the first frame
    shows is the host's choice of start time (section 18.2).
34. **The bake goes through the live draw path.** Upstream first resamples
    the content into a texture of exactly `ceil(geometry · scale)` texels and
    clips that; here the window's buffer is sampled once into the bake, as a
    frame at zoom 1 samples it. For an integer-sized window at an integer
    scale the rectangles are the same (a snapshot at progress 0 over the live
    window, no border, 2x: every value within 2 levels, the extra rounding of
    the bake's own 8 bits). At a fractional scale, or for a fractional window
    size, the title bar band (snapped to whole pixels live, not in the bake)
    and the content rectangle can differ by a pixel from upstream's bake. Not
    measured.
35. **A snapshot's `decoration.opacity` multiplies its fade.** 1 by default,
    which is upstream. The snapshot also keeps the window's `clipRect` (not an
    upstream concept).
36. **`Closing` on a live window element** fades and shrinks it like a
    stand-in. Not an upstream path: upstream always closes through a snapshot.
    There is no group opacity, so border, content and shadow fade one by one.
37. **Snapshot rectangles are doubles.** Upstream's pinned snapshot has an
    integer screen rectangle; same formula.
38. **The error bar's text is CoreText's** fixed-pitch UI font
    (`kCTFontUIFontUserFixedPitch`; SF Mono here) for upstream's fontconfig
    `monospace`, as all text in this module (deviation 5). No textless bar
    during a font scan (`fonts_ready`). The cache compares the message list,
    not the joined string.
39. **Opening multiplies the clamped `float` opacity** by the open alpha;
    upstream multiplies the `f64` opacity. At most one unit in the last place
    of a `float`.
40. **`IFCUniforms` grew by one `float4`** (`blur`), 224 to 240 bytes, for
    every draw. No pixel depends on it (28 of 28 earlier PNGs byte-identical).
41. **The element list is resolved into an array before drawing**
    (`collectItems`), where the port drew straight from the frame. For
    `many.json` (320 elements, 1000 draws) the encode takes 0.40 to 0.42 ms
    against 0.38 to 0.39 ms for `compositor-port`'s build, three runs of 240
    frames each, interleaved; GPU time is the same.
42. **The closing bucket is drawn in list order.** Upstream's order inside it
    follows from its own two lists and not from where the windows were
    stacked: snapshots in creation order with the oldest top-most, then the
    stand-in fades, likewise (`render_snapshots_for_output`, "top-most
    first"; mod.rs appends the fades after them). The renderer has no
    creation order to go by — a lifecycle may carry an explicit progress and
    no start time — and does not reorder what the host lists. Upstream's
    stacking is reproduced when the host lists the bucket as section 18.2
    says ("Order in the closing bucket"), and not otherwise: listed any other
    way, two overlapping snapshots, or a fade over a snapshot, show the wrong
    one on top for the length of the animation.

## 21. Upstream behaviour kept on purpose (effects)

- **The frost is drawn at alpha 1** whatever the window's opacity, and the
  mask is binary: at an anti-aliased corner pixel, where the content has an
  alpha of 0.3, the frost is fully there.
- **The frost covers the content's rectangle only.** The border ring lies
  outside it and is drawn over the sharp backdrop; inside the content's corner
  squares the frost shows wherever the border's ring is (`out/blur.png`,
  magnified in section 23's "looked at").
- **A lower window's frost is not in an upper window's backdrop.** Had it
  been, 16,940 px of the upper frost in the test of section 23 would differ
  by more than 2 levels (up to 31).
- **Taps leave the region a pass reads.** The mips live in the top-left of
  two full-size textures, and the taps at a mip's right and bottom edge read
  what lies beside it — in the first texture the captured backdrop at full
  size. The pad is there to keep that out of the centre, and at larger
  settings it does not quite (deviation 26's numbers; `pad` is clamped to 256).
- **The blur's reach is in physical pixels**, the same at every zoom.
- **`screen_rect` truncates and rounds up** in logical pixels, so the frost
  can sit a pixel off the content's own rounding at fractional positions.
- **A frost's mask goes stale** when only the window's alpha shape changes at
  the same geometry after the first 8 content changes (upstream's accepted
  trade-off).
- **The baked shadow is cast by the body without the border**, with the
  outer corner radius (`flatten` hands `bake_shadow_element` the body as it
  is; the live path grows it by the border width first). A snapshot of a
  bordered window therefore differs from the live window at progress 0: with
  a 2 px border at 2x, 49,338 channel values differ by more than 2 (up to 19)
  — the shadow starts under the border and is that much narrower outside it.
- **The snapshot fades from alpha 1** even if the window was translucent.
- **A snapshot is in the closing bucket** whatever it was baked from: a
  pinned window's snapshot drops below the other pinned windows.
- **Of windows closing together the first to close is on top**, and fading
  stand-ins lie beneath all of them: upstream's list order, not the stacking
  the windows had. Kept by the host's listing (section 18.2), not by the
  renderer (deviation 42).
- **`1 − 0.99` is 0.010000000000000009** in `f64`: a snapshot at progress
  0.99 is still drawn, as upstream's `<= 0.01` would still keep it.
- **An opening window at progress 0 is invisible** (alpha 0), and a closing
  one at progress 1 is absent.
- **The error bar's text is one line** however long the messages are; it is
  cut at the right inset, not wrapped.

## 22. Not supported (effects)

- **The shared backdrop** (`SharedBlur`). When at least two blurred windows
  with nothing but background beneath them cover 80 % of the output between
  them, upstream blurs the whole background once and lets them slice their
  frost out of it. Here every window always renders its own backdrop
  (upstream's "exact per-window path", which upstream also takes for a lone
  window, for small ones, and for any window over another). The two upstream
  paths do not give the same pixels (the mip chain is taken from the output's
  extent in one and from the padded window's in the other), so in the cases
  where upstream would share, this module shows upstream's per-window result
  instead. Cost, not correctness, is what the shared path buys.
- **Client blur regions** (`ext-background-effect`; `region_rects`,
  `mask_region_complement`) and blur behind **layer-shell surfaces**: no
  macOS counterpart.
- **Resize crossfades** (`ResizeCrossfade`, `crossfade_out_alpha`) and the
  geometry animation state machine (`AnimationKind::Geometry`: start holds,
  capped content, the chrome ramp of a fullscreen leg): host-driven through
  `transform` and `decoration.opacity`, as before.
- **The GLES 2 fallback** (`CLAMP_TO_EDGE` instead of `MIRRORED_REPEAT`).
- **Damage tracking** of the frost element, and upstream's rule that an
  empty frost is left out so that a fullscreen window can be scanned out
  directly.
- **A frost for a stand-in or a snapshot** (upstream has none either).

## 23. Verification (effects)

`verify/run_all.sh` runs everything in this section except the lines marked
*by hand*; `verify/last_run.log` is its complete output for this copy:
**443 PASS lines, no FAIL** — 211 of `check.py` (Part I, unchanged), 122 of
`check_effects.py`, 21 lines for the 42 background comparisons, 1 for the 28
earlier PNGs, 17 of the lifecycle test, 57 of the three blur-cache tests, 14 of
the kind-switch test.

The log was made before the review round recorded below ("Review findings
(effects)"). That round changed `comprender.m` (how `--blur-cache-test`
counts), two comments in `compositor.h`, `verify/render_scenes.sh` (one more
render), a new scene and these notes; `compositor.m`, `background.m`,
`background.h` and `build.sh` are byte for byte what the log was made from.
`run_all.sh` was **not** run again after it: only what the round touched was
repeated, and those rows are marked *review round*. A new run of the script
would print one more render line (`out/closing_order.png`); that its other
lines would be the same was checked for the three blur-cache runs (identical
to the log line for line) and for the 55 renders (byte-identical PNGs), and
not for the rest.

As in Part I, upstream itself cannot run here. References: the **unmodified
upstream GLSL** compiled by the system's legacy OpenGL (`verify/glblur.c`
re-types `render_blur` / `blur_pass` in C and runs `blur_down.glsl` and
`blur_up.glsl` in upstream's ping-pong on two textures with
`GL_MIRRORED_REPEAT`; `verify/glref.c` runs `blur_mask.glsl`), and upstream's
**Rust re-typed in Python** in `verify/check_effects.py` (`blur_pad`, the
`wants_blur` rectangle, `transform_rect`, `TextureRenderElement::geometry`,
`fade_out_alpha`, `open_alpha`, `open_scale`, the per-frame tick, `flatten`'s
bounds, `ClosingSnapshot::render_element`, `join_errors`).

| Check | Result |
|---|---|
| **The 28 PNGs of `compositor-port/out`**, re-rendered here from the same scenes | 28 of 28 byte-identical (`cmp`). None differs |
| `check.py` and `bgcompare.py` of Part I, unchanged, against this build | 211 of 211; 42 of 42 |
| Kawase chain against OpenGL running `blur_down.glsl` / `blur_up.glsl`: 11 inputs (1 × 1 to 400 × 300, odd sizes), 0 to 6 passes, offset 0 to 3 | the result within 1 level everywhere in all 11; every intermediate texture compared *whole* (so also the regions a pass does not write): all within 1 level, the downscale passes exact |
| A frost end to end, 22 cases: the frame's blur pass alone (`--only blur`) against — the scene below the window rendered without it, cropped to the padded rectangle (mirrored in Python where it leaves the output), blurred by OpenGL with the unmodified shaders, cropped, multiplied by `blur_mask.glsl`'s output for the window's own shape | 22 of 22: every pixel of the frost's rectangle within 1 level, nothing drawn outside it. Cases: 1x and 2x; zoom 0.5, 0.7, 0.75, 1.5; fractional and half-pixel cameras; corner radius 0, 70, 500; 0, 1, 4 and 6 passes; strength 0, 2, 3; hanging off the left / top, off the right / bottom at 2x, and wider than the output (mirror); server-side title bar at 1x and at 2x zoom 0.75; pinned over a zoomed canvas; content with alpha 0 / 1/255 / 255; a blurred window over a blurred window |
| The same 22 cases: screen rectangle, pad, capture rectangle, pass count, offset; the frost element's rectangle and alpha | equal to the re-typed Rust in all 44 comparisons |
| Mask threshold | under content alpha 0: no frost (0, 0, 0, 0); under alpha 1/255: a full one, alpha 255 |
| Content over frost | every pixel of `--only blur,content` = content + frost · (1 − content alpha) within 1 level; frost alpha 255 at the centre of a window whose opacity is 0.4 |
| Draw order of a blurred window | shadow, blur, border, content |
| A blurred frame through `IFCompositorLayer` (unattached) vs offscreen, 2x | byte-identical; the layer stays `framebufferOnly` unless the diagnostics capture is on |
| Nothing beneath the window (no background, no lower element) | no frost drawn |
| **Upstream's own pixel test replayed** (`src/tests/blur_pixels.rs`, `the_frost_sees_backdrop_a_pad_without_the_output_scale_would_miss`: 1600 × 1200 at 2x, 5 passes, strength 1.5, a 600 × 400 window of alpha 1/255 over stripes that end 110 px past it) | frost bounds 600 × 400, centred; centre luma 127 (upstream asserts 126..128); 4 px in from each edge 137, 135, 136, 136 (upstream asserts each at least centre + 5) |
| When a frost is recomputed (`--blur-cache-test`, three scenes, 57 checks) | first two frames: all; identical third frame: none; `time` alone over a still background: none; the window's own content after 8 changes: none; a lower element out of reach added, then changed: none; the same under a frosted window: recomputed, also when its content changes and when it leaves; an element above: none; camera moved, `blur_strength` changed: all. Moving background, `animate_blur_fps` 20: 40 recomputations in 120 frames at 60 Hz; at 0: none in 60 frames, a camera move still recomputes |
| `--blur-cache-test` on scenes with blurred windows that have no frost on the output (*by hand, review round*) | the reviewer's `review-renders/scenes/r4_extremes.json` (10 blurred windows, one at canvas (5000, 5000)): "9 of them with a capture on the output; 1 without one", 18 of 18 PASS, exit 0 (before the fix: 5 FAIL, exit 1). Scratch scenes under `build/tmp/fix/scenes/`: the off-output window listed last, 18 of 18; a second window whose capture ends 2 px short of the output, 1 frost expected until the camera moves by 3, then 2 of 2, 18 of 18; the last listed window hanging off the top-left corner by all but a pixel, 18 of 18 (the test drives the other one); no background but a checker window beneath, 18 of 18. Refused with exit 2 and a reason: every blurred window off the output; the only one hanging off the top-left corner; no background and nothing beneath. The three shipped runs: 57 PASS, the output identical line for line to before the change and to `verify/last_run.log`. Control: against a scratch copy of `compositor.m` with `force_dirty_frames` cut from 2 to 1 the test fails its second-frame check, on `blur_shapes.json` and on `r4_extremes.json` (17 PASS, 1 FAIL, exit 1 each) |
| Where "off the output" begins (*by hand, review round*; `--dump-draws`): a 120 px wide blurred window on a 400 px wide output at 1x, pad 16 | at x = 415 (padded rectangle from 399) the renderer reports a capture 1 px wide, (399, 64, 1, 122), and builds the frost; at x = 416 (from 400) no `blur_info` record, no frost. Upstream: `backdrop_capture` is `padded.intersection(output)`, and smithay's `intersection` is `None` unless the rectangles strictly overlap |
| Blur textures (`--blur-cache-test`, `--bench`) | nine frosted windows: 37 textures after the first frame (9 × frost, mask, two pads; one background copy), none allocated in the second frame or in 119 panning frames; a frosted window hanging off the output moved for five frames: none allocated; blur off for 70 frames: nothing computed, nothing allocated, 0 held. With no blurred element in a scene (`many.json`, 120 frames): 0 frosts, 0 textures |
| Closing snapshot: rectangle, alpha and bake size at progress 0, 0.25, 0.5, 0.75, 0.9, five views (1x, 2x, zoom 0.5, 2x zoom 0.7 with a fractional camera, zoom 1.3 with a half-pixel camera; bake density `max(scale · zoom, 1)`: 1, 2, 1, 1.4, 1.3) | equal to the re-typed `flatten` bounds and `render_element` in all 25 (e.g. 1x: bake 179 × 139 texels for canvas rect (56, 46, 179, 139); at 0.5: (58, 48, 175, 135), alpha 0.75) |
| End of a close | progress 1, 0.995, 0.9901: not drawn; 0.99 and 0.98: drawn (section 21) |
| Alpha-only snapshot; pinned snapshot | fades in place; ignores camera and zoom |
| Snapshot at progress 0 against the live window, 2x | no border: every value within 2 levels. 2 px border: differs (section 21) |
| Closing bucket | above a normal window listed after it, below a pinned one listed before it |
| Order inside the closing bucket (*by hand, review round*): `scenes/closing_order.json` with `--dump-draws` — a fading stand-in, a snapshot at progress 0 and an older one at 0.5, listed as section 18.2 says | drawn in that order: the stand-in's five passes, snapshot 2, snapshot 1, which is upstream's order read backwards. The reviewer's `review-renders/scenes/r5_two_snapshots.json`, the same three elements listed snapshot 1, stand-in, snapshot 2, is drawn as listed and is byte-identical to the reviewer's own render: the renderer does not sort |
| The host protocol of 18.2 / 18.4 through the public API (*by hand, review round*; `build/tmp/fix/order_check.m`, built with `-Wall -Wextra -Werror`): stacking alive, bottom to top, stand-in S1, window A, stand-in S2, window B, a window that stays; then S1 fades, A closes, B closes, S2 fades, one 120 Hz tick apart, each put in the list by the rule of 18.2 (real bakes through `-closingSnapshotOfElement:inFrame:flattenScale:`) | `frame.elements` ends as S2, S1, the staying window, snapshot B, snapshot A; drawn bottom to top: the staying window, S2, S1, B, A — what upstream's `closing_snapshots = [A, B]`, `standin_fades = [S1, S2]` give; all four still running, `needsContinuousRedraw` YES |
| Opening window: content rectangle and alpha at the same five progress values and five views, opacity 0.8 | equal to the re-typed `animated_visual` / `transform_rect` in all 25 (e.g. 1x at 0.5: (72, 61, 147, 109) from (70, 60, 151, 111) at rest, alpha 0.6 = 0.8 · 0.75); at progress 1 the frame is byte-identical to the plain window's |
| A blurred window opening | its `screen_rect` is the transformed one: (140, 120, 302, 222) at rest, (170, 142, 242, 178) at progress 0.5 with amplitude 0.6 |
| Dismissed stand-in; adoption crossfade | all 5 passes shrink by 0.975 about (198.38, 172.34) and carry alpha 0.75; alpha-only: same rectangles as at rest |
| The clock: alpha of a timed close against upstream's tick-by-tick recurrence, speeds 0.5, 0.25, 0.9, ticks of 1/60 s, 1/120 s and uneven ones | 9 of 9: alpha error 0 at every tick, and the snapshot disappears on the tick upstream's would (speed 0.5 at 60 Hz: drawn through tick 6, gone from tick 7; at 120 Hz: 13 / 14) |
| Lifecycle through a layer (`--lifecycle-test`, 17 checks) | a static frame skips on `time` alone; an opening window and then a closing snapshot redraw on each of their 14 ticks at 120 Hz with `needsContinuousRedraw` YES, and after the end it is NO and updates skip |
| Error bar at 1x, 2x, and 2x zoom 0.5 | rectangle (0, 217, 640, 23) at 1x, (0, 434, 1280, 46) at 2x; drawn last; opaque black over a normal and a pinned window; no pixel above it changed; text starts at x 13 (inset 12) / 26 (inset 24), ink rows 6..16 of 23 / 13..35 of 46; joined text equal to the re-typed `join_errors` |
| Error bar: long text; one empty message; no messages | last ink at x 626 of 640 (inset 12); a bar without text; no bar |
| Churn (`--churn-test`, now also switching blur per window, opening windows, baking and playing closing snapshots, toggling the error bar): 400, 120 (300 windows), 3000, 1500 (nine frosted windows at 2x) and 400 frames | completed without error; live heap blocks after teardown below mid-run in each |
| Address + undefined-behaviour sanitizers (`verify/sanitize.sh`, *by hand*): six churn runs, the blur-cache, lifecycle, gating and kind-switch tests, five renders | no report; the renders byte-identical to the normal build's |
| `leaks --atExit` (*by hand*) on a 200-frame churn with frost, the lifecycle test, the animated blur-cache test, two renders, the gating and kind-switch tests | 0 leaks in each (a ten-`malloc` control leak was reported by the same command) |
| `clang --analyze` on `compositor.m`, `comprender.m` (*by hand*) | no findings |
| After the review round (*by hand, review round*): `./build.sh`, `verify/render_scenes.sh`, `cmp` | built with `-Wall -Wextra -Werror`; the 55 earlier PNGs byte-identical to those rendered before the round, the 28 of `compositor-port` among them still equal to `compositor-port/out`; `out/closing_order.png` is the 56th |
| The changed tool under the address + undefined-behaviour sanitizers and the analyzer (*by hand, review round*; `build/tmp/fix/asan_run.sh`) | five blur-cache runs (93 PASS, no FAIL) and the three refusals: no report; `closing_order.json`: PNG byte-identical to the normal build's; `clang --analyze comprender.m`: no findings |

**Review findings (effects)** (an independent review of this copy; both were
checked against the code and upstream, reproduced and accepted, neither
rejected):

1. *The z-order among simultaneous closing elements is not upstream's when
   the documented host protocol is followed.* Confirmed in upstream:
   `self.closing_snapshots.push(snapshot)` (window_animation_driver.rs) and
   `self.standin_fades.push(..)` (state/suspended.rs, both sites) append;
   `render_snapshots_for_output` walks the snapshots in that order and is
   documented "top-most first"; mod.rs then pushes every fade's elements onto
   the same `zoomed_closing` vector, behind them. So the oldest snapshot is
   top-most and every fade is beneath every snapshot, while section 18.2 told
   the host to put the snapshot at the dead window's index and said "among
   snapshots list order holds". Reproduced with the reviewer's
   `r5_two_snapshots.json`: drawn as listed, snapshot 1, stand-in 3,
   snapshot 2. Fix: the host is told, as the reviewer proposed, and the
   renderer is unchanged — section 18.2 (the sample and "Order in the closing
   bucket"), 18.4, 19.2, section 5, deviation 42, a line in section 21, the
   comments of `IFCompositorStackLayerClosing` and
   `-closingSnapshotOfElement:inFrame:flattenScale:` in `compositor.h`
   (comments only), and `scenes/closing_order.json`. Not done: sorting the
   bucket in `collectItems`. A lifecycle given by explicit progress has no
   start time to sort by, and the renderer would be reordering what the host
   listed. What that leaves: the module on its own still draws any order it
   is given, so DriftWM's stacking depends on the host following 18.2; the
   protocol was run once through the API (the table's row) and never in a
   host.
   Added on my own account, read in the same upstream block: upstream draws
   no snapshot and no fade on a visually fullscreen output. 18.2 "When not
   to" now says so; it is the host's to leave them out.
2. *`comprender --blur-cache-test` prints FAIL for correct behaviour when a
   blurred window has no capture on the output.* Reproduced: 5 FAIL lines and
   exit 1 on `r4_extremes.json`, where the renderer is right
   (`-prepareFrostOfItem:` returns where upstream logs "frost left
   unrendered: the padded capture is entirely off the output"). The test
   counted every element with `blur` set. Fix, in `comprender.m` only: the
   expected count is the number of `blur_info` records of the encode at hand
   — the renderer's own account of the windows whose padded capture reaches
   the output — and the window the test drives is chosen among those. Two
   more false failures of the same kind turned up while testing the fix
   (**not in the finding; added on my own account**) and are now refusals
   with exit status 2 instead: a scene without a background in which a
   blurred window has nothing beneath it (no frost, upstream's "frost
   zeroed"), and a scene whose only blurred windows on the output hang off
   its left or top edge (the element the test slides under the driven window
   then misses its capture: 3 FAIL lines before the refusal was added).
   What the fix costs: the expected count now comes from the renderer, so
   this test no longer notices a window that the renderer wrongly takes to be
   off the output. The rectangles that decision is made from are checked
   elsewhere (the 44 comparisons of screen and capture rectangles with the
   re-typed Rust in `check_effects.py`, overhanging cases among them); the
   decision itself was checked by hand in this round and is in no script
   (the table's "off the output" row). With the shipped scenes the test
   prints exactly what it printed before.

**Looked at** (each PNG was opened; the earlier 28 are in Part I's table):

| PNG | What it shows |
|---|---|
| `blur.png` | left: a 35 % white window with `blur` over the detailed test background and over a green checker window — both are smoothed inside the window's rounded shape, sharp outside it. Right: the same window without `blur` — background and checker sharp through it. Magnified at the top-left corner: the frost ends on the rounded corner; the amber border is drawn over the sharp background |
| `blur_z05.png`, `blur_s2.png`, `blur_z05_s2.png` | zoom 0.5: the window is half the size and its frost coarser relative to it (the checker under it blurs to a flat tone); 2x: same look as 1x with crisp corners; both |
| `blur_radius0.png`, `blur_radius5_strength2.png`, `blur_strength0.png` | no passes: the frosted window looks like the unfrosted one beside it (background and checker sharp through it); 5 passes at strength 2: an almost flat tint; strength 0: only the softening of the down / up sampling — the fine lines are gone, the blocks keep their edges |
| `blur_shapes.png`, `blur_shapes_z075_s2.png` | corner radius 0 (square frost); 60; 500 (a stadium, as the content clamps); a server-decorated window frosted under bar and content; a window hanging off the left edge, frosted up to the edge; a translucent gradient window and a second frosted window over it (the upper frost shows the lower window blurred); an opaque image whose translucent corner block alone shows frost; a pinned window off the bottom-right corner. At 2x, zoom 0.75, camera (30, 20): the same, crisp, the pinned one unmoved |
| `lifecycle.png`, `lifecycle_scale06.png` | row 1: a window, then its closing snapshot at progress 0 (the same picture), 0.25, 0.5, 0.75 (fainter and slightly smaller each), 1 (absent). Row 2: the window, then it opening at 0 (invisible), 0.25, 0.5, 0.75, 1 (the plain window). Row 3: a stand-in, then dismissed at the same five values. With `animation_scale` 0.6 the shrink and the grow about the centre are plain to see |
| `lifecycle_timed_tick1.png` | one tick (1/60 s) after the start: the snapshot and the opening window both at 75 % alpha, a little small, beside the live window |
| `closing_order.png` (*review round*) | the older, blue snapshot (progress 0.5: three quarters opaque, a little smaller) lies over the newer, orange one (progress 0), their overlap a grey-blue mix; the fading stand-in is beneath both, only its right edge and the close glyph showing past the orange snapshot. Beside it `build/tmp/fix/r5_as_listed.png`, the reviewer's listing of the same three elements: there the orange snapshot covers the blue one in the overlap |
| `error_bar.png`, `error_bar_many.png` | a black strip across the bottom over a normal and a pinned window, white monospace text from the left inset; three messages on one line with bullets between them, the multi-line one flattened, the line cut with an ellipsis at the right inset |
| `effects_all.png` | everything at once: a frosted window over a checker window, a closing snapshot at 0.5 above it, an opening frosted window, a launching stand-in, a pinned frosted server-decorated window, the error bar with two messages |

Rendered by `render_scenes.sh` and not opened: `blur_radius1.png`,
`blur_frost_only.png`, `blur_animated.png`, `lifecycle_z075_s2.png`,
`lifecycle_timed_tick{0,2,3,4,6,7}.png`, `error_bar_many_s2.png`,
`effects_all_z08_s2.png`.

**Not run:**

- **Upstream DriftWM itself.** No frost, snapshot or error bar here was
  compared with a pixel from real DriftWM. "Matches upstream" means what it
  means in Part I: upstream's shader source executed by OpenGL, upstream's
  Rust re-typed, and smithay as read in the 0.7.0 release
  (`render_texture_from_to`, `GlesRenderer::render`'s viewport and blend
  state, `TextureRenderElement::geometry`). Upstream's `blur_pixels` test was
  replayed through this module, not run.
- **The shared-backdrop path**, client blur regions, resize crossfades: not
  ported (section 22).
- **Real ScreenCaptureKit buffers**, also for the bake: a snapshot was only
  ever baked from generated buffers and textures.
- **The layer on screen.** No frost or animation was watched on a display;
  the animation tests drive an unattached layer with a synthetic clock. How
  the host's tick lines up with the display, and whether presenting inside a
  transaction costs a frame during an animation, is untested.
- **The host side**: detecting a close in time to bake, the one-second
  freshness rule, the start time of an animation, the error list.
- **Fractional backing scales** for the effects, and the bake against
  upstream's `flatten` at a fractional scale or window size (deviation 34).
- **`animate_blur_fps` against a real clock.**
- **Memory under a zoom animation.** A frosted window whose size on screen
  changes every frame gets a new pad pair every frame, as upstream's
  `ensure_pads` does; the old pair is released when the frames that used it
  complete. Reasoned, not measured.
- **Any GPU other than this machine's** (Apple M5 Pro, macOS 27.2 build
  26B5091g, deployment target 26.0).
- `verify/cvage_probe.m`, the reviewer's reproductions and the `lldb` run of
  Part I's history were not repeated for this copy; `--kind-switch-test`,
  which rests on the same facts, was (14 of 14, with the same megabyte
  figures as Part I).

## 24. Cost of the effects

Apple M5 Pro, 3456 × 2234 target unless noted, `comprender --bench 120` /
`--bench-pan 120`, per frame, from `verify/last_run.log`:

| Scene | Frosts recomputed per frame | CPU encode | GPU | Heap allocations in `-encodeFrame:` |
|---|---|---|---|---|
| `many.json`, no blur anywhere | 0 | 0.42 ms | 4.41 ms | 6 |
| `blur.json`, one 600 × 600 px frost, nothing moving (frost reused) | 0 | 0.03 ms | 0.62 ms | 3 |
| the same with `blur` off, the camera moving (by hand, an earlier run) | 0 | 0.02 ms | 0.49 ms | 3 |
| `blur.json`, the camera moving a point per frame | 1 | 0.07 ms | 0.98 ms | 42 |
| `blur_shapes.json`, nine frosts, nothing moving | 0 | 0.05 ms | 0.60 ms | 4 to 7 |
| the same, the camera moving | 9 | 0.38 ms | 1.79 ms | 326 |
| `lifecycle.json` at 2x (5 snapshots, 5 opening windows, 5 fading stand-ins) | 0 | 0.03 ms | 0.29 ms | 4 |
| `error_bar_many.json` at 2x (1600 × 600) | 0 | 0.01 ms | 0.35 ms | 3 |

GPU times move by one or two tenths of a millisecond between runs on this
machine (the error-bar scene read 0.13 ms in the previous run of the script,
`blur_shapes` panning 1.59 ms); the counts do not.

- With no blurred element the blur costs one flag test per element while the
  list is resolved; no texture exists (`blurTextureCount` 0), no pass is
  added.
- A reused frost costs one textured quad.
- A recomputed frost costs a backdrop pass (the scene below, scissored to
  the padded rectangle), `2 · blur_radius` small passes, a copy, a mask pass
  and a multiply; the first one in an encode also the background copy (a
  full-output pass). The allocations are Metal's own, about four per render
  or blit encoder; this module allocates nothing per frame, and no texture
  after the first frame (the table's panning runs: 0 more in 119 frames).
- A window whose size on screen changes (zoom, resize) reallocates its pad
  pair, and its frost and mask at every 64 px step, as upstream does.
- A snapshot costs one textured quad; the bake one small pass, once.

## 25. Commands

Everything under `compositor-effects/`; nothing was written anywhere else.
Nothing was committed (the directory is not a repository).

Set-up and the unchanged baseline:

```sh
mkdir compositor-effects
cp -p compositor-port/{NOTES.md,background.h,background.m,compositor.h,compositor.m,comprender.m,build.sh} compositor-effects/
cp -Rp compositor-port/{verify,scenes,assets} compositor-effects/
cd compositor-effects
./build.sh && verify/render_scenes.sh           # before any change: 28 of 28 PNGs equal to ../compositor-port/out (cmp)
```

Build, and the complete verification run (the log is `verify/last_run.log`):

```sh
./build.sh
verify/run_all.sh ../driftwm-upstream ../background-port/build/bgrender ../compositor-port/out > verify/last_run.log 2>&1
```

`build.sh` is unchanged (`-arch arm64 -mmacosx-version-min=26.0 -fobjc-arc
-Wall -Wextra -Werror -O2 -g` for the three sources). `run_all.sh` runs, in
order:

```sh
./build.sh
xcrun clang -arch arm64 -O2 -Wall -Wextra -Werror verify/glref.c -framework OpenGL -o build/glref
xcrun clang -arch arm64 -O2 -Wall -Wextra -Werror verify/glblur.c -framework OpenGL -o build/glblur
shasum -a 256 $UPSTREAM/src/shaders/{border,shadow,corner_clip,blur_down,blur_up,blur_mask}.glsl
python3 verify/check.py $UPSTREAM
python3 verify/check_effects.py $UPSTREAM
python3 verify/bgcompare.py $BGRENDER
verify/render_scenes.sh
cmp $PORT_OUT/NAME.png out/NAME.png                  # each of the 28
build/comprender scenes/two_windows.json --gating-test
build/comprender scenes/two_windows_animated.json --gating-test
build/comprender scenes/standin.json --gating-test
build/comprender scenes/lifecycle_timed.json --lifecycle-test
build/comprender scenes/blur_shapes.json --blur-cache-test
build/comprender scenes/blur.json --scale 2 --blur-cache-test
build/comprender scenes/blur_animated.json --blur-cache-test
build/comprender scenes/two_windows_paper.json --scale 2 --size 1728x1117 --bench 120
build/comprender scenes/standin.json --scale 2 --bench 120
build/comprender scenes/many.json --bench 120
build/comprender scenes/many.json --only PASS --bench 60      # for each pass
build/comprender scenes/blur.json --scale 2 --size 1728x1117 --bench 120
build/comprender scenes/blur.json --scale 2 --size 1728x1117 --bench-pan 120
build/comprender scenes/blur_shapes.json --scale 2 --size 1728x1117 --bench 120
build/comprender scenes/blur_shapes.json --scale 2 --size 1728x1117 --bench-pan 120
build/comprender scenes/lifecycle.json --scale 2 --bench 120
build/comprender scenes/error_bar_many.json --scale 2 --bench 120
build/comprender scenes/standin.json --kind-switch-test
build/comprender scenes/standin.json --churn-test 400
build/comprender scenes/many.json --churn-test 120
build/comprender scenes/overlap.json --scale 2 --churn-test 3000
build/comprender scenes/blur_shapes.json --scale 2 --churn-test 1500
build/comprender scenes/lifecycle.json --churn-test 400
```

`render_scenes.sh` runs the 28 renders of `compositor-port` (unchanged) and
then:

```sh
build/comprender scenes/blur.json --out out/blur.png
build/comprender scenes/blur.json --zoom 0.5 --out out/blur_z05.png
build/comprender scenes/blur.json --scale 2 --out out/blur_s2.png
build/comprender scenes/blur.json --scale 2 --zoom 0.5 --out out/blur_z05_s2.png
build/comprender scenes/blur.json --blur-radius 0 --out out/blur_radius0.png
build/comprender scenes/blur.json --blur-radius 1 --out out/blur_radius1.png
build/comprender scenes/blur.json --blur-radius 5 --blur-strength 2 --out out/blur_radius5_strength2.png
build/comprender scenes/blur.json --blur-strength 0 --out out/blur_strength0.png
build/comprender scenes/blur.json --only blur --clear transparent --out out/blur_frost_only.png
build/comprender scenes/blur_shapes.json --out out/blur_shapes.png
build/comprender scenes/blur_shapes.json --scale 2 --zoom 0.75 --camera 30,20 --out out/blur_shapes_z075_s2.png
build/comprender scenes/blur_animated.json --time 0.3 --out out/blur_animated.png
build/comprender scenes/lifecycle.json --out out/lifecycle.png
build/comprender scenes/lifecycle.json --animation-scale 0.6 --out out/lifecycle_scale06.png
build/comprender scenes/lifecycle.json --scale 2 --zoom 0.75 --out out/lifecycle_z075_s2.png
build/comprender scenes/lifecycle_timed.json --time T/60 --out out/lifecycle_timed_tickT.png    # T = 0 1 2 3 4 6 7
build/comprender scenes/error_bar.json --out out/error_bar.png
build/comprender scenes/error_bar_many.json --out out/error_bar_many.png
build/comprender scenes/error_bar_many.json --scale 2 --out out/error_bar_many_s2.png
build/comprender scenes/effects_all.json --out out/effects_all.png
build/comprender scenes/effects_all.json --scale 2 --zoom 0.8 --camera 20,10 --out out/effects_all_z08_s2.png
```

By hand, outside the script (`FW` = the framework list of `build.sh`):

```sh
verify/sanitize.sh                               # -fsanitize=address,undefined build into build/asan, then:
#   build/asan/comprender scenes/{blur_shapes,lifecycle,standin,overlap}.json --churn-test 300
#   build/asan/comprender scenes/blur_shapes.json --scale 2 --churn-test 1000
#   build/asan/comprender scenes/many.json --churn-test 60
#   build/asan/comprender scenes/blur_shapes.json --blur-cache-test
#   build/asan/comprender scenes/lifecycle_timed.json --lifecycle-test
#   build/asan/comprender scenes/standin.json --gating-test ; … --kind-switch-test
#   build/asan/comprender scenes/{blur,blur_shapes,lifecycle,error_bar_many,standin_mapping}.json --scale 2 --out …   (cmp with the normal build)
xcrun clang --analyze -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc compositor.m comprender.m
leaks --atExit -- build/comprender scenes/blur_shapes.json --churn-test 200
leaks --atExit -- build/comprender scenes/lifecycle_timed.json --lifecycle-test
leaks --atExit -- build/comprender scenes/blur_animated.json --blur-cache-test
leaks --atExit -- build/comprender scenes/blur_shapes.json --scale 2 --out build/tmp/leakcheck.png
leaks --atExit -- build/comprender scenes/effects_all.json --out build/tmp/leakcheck2.png
leaks --atExit -- build/comprender scenes/standin.json --gating-test
leaks --atExit -- build/comprender scenes/standin.json --kind-switch-test
#   leaks prints "Process … is not debuggable" for this unsigned tool and still reports; checked with a control that
#   leaks ten blocks (reported: 10 leaks), and by repeating four of the runs on a copy signed with get-task-allow:
cp build/comprender build/tmp/comprender_dbg && codesign -s - -f --entitlements build/tmp/ent.plist build/tmp/comprender_dbg
leaks --atExit -- build/tmp/comprender_dbg scenes/blur_shapes.json --churn-test 200       # and three more: 0 leaks each
# many.json against compositor-port's build, interleaved, three times:
build/comprender scenes/many.json --bench 240 ; ../compositor-port/build/comprender ../compositor-port/scenes/many.json --bench 240
build/comprender build/tmp/blur_off.json --scale 2 --size 1728x1117 --bench-pan 120     # blur.json with every "blur" false
python3 verify/crop.py out/blur.png build/crop1.png 40 20 120 100 6                    # magnified crops for looking at
python3 verify/crop.py out/blur_s2.png build/crop_s2.png 60 40 760 660 1
python3 verify/crop.py out/blur_z05_s2.png build/crop_z05_s2.png 30 20 380 480 2
```

The review round (section 23, "Review findings (effects)"), all by hand;
`run_all.sh` was not run again. `F` = `build/tmp/fix`, scratch files of this
round (scenes, logs, the two scripts and `order_check.m`):

```sh
build/comprender review-renders/scenes/r4_extremes.json --blur-cache-test          # before: 5 FAIL, exit 1; after: 18 PASS, exit 0
build/comprender review-renders/scenes/r5_two_snapshots.json --out $F/r5_as_listed.png --dump-draws $F/r5_as_listed_draws.json
cmp $F/r5_as_listed.png review-renders/out/r5_two_snapshots.png                    # identical: drawn as listed
cp -Rp out $F/out_before                                                            # the 55 PNGs, before any change
./build.sh                                                                          # after each edit of comprender.m / compositor.h
build/comprender scenes/blur_shapes.json --blur-cache-test                          # the three shipped runs, before and after:
build/comprender scenes/blur.json --scale 2 --blur-cache-test                       #   57 PASS, output identical (diff), also to
build/comprender scenes/blur_animated.json --blur-cache-test                        #   that section of verify/last_run.log
build/comprender $F/scenes/NAME.json --blur-cache-test                              # NAME = t_off_listed_last t_enters_on_pan
                                                                                    #   t_no_bg_lower_element t_last_hangs_off_corner (18 PASS each),
                                                                                    #   t_only_hangs_off_corner t_all_off t_nothing_beneath (exit 2 each)
build/comprender $F/scenes/t_edge_415.json --out $F/t_edge_415.png --dump-draws $F/t_edge_415.draws.json   # and t_edge_416
build/comprender scenes/closing_order.json --out out/closing_order.png --dump-draws $F/closing_order_draws.json
python3 verify/crop.py out/closing_order.png $F/closing_order_x2.png 0 0 420 300 2                         # to look at
verify/render_scenes.sh                                                             # then cmp: 55 of 55 equal to $F/out_before,
                                                                                    #   28 of 28 equal to ../compositor-port/out
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -O2 -I. $F/order_check.m \
    build/background.o build/compositor.o $FW -o $F/order_check && $F/order_check   # the protocol of 18.2 / 18.4: 2 PASS
$F/asan_run.sh        # verify/sanitize.sh's build into $F/asan; the blur-cache test on blur_shapes, blur_animated, r4_extremes
                      #   and the scratch scenes; closing_order.json against the normal build's PNG
$F/mutant_run.sh      # control: the tool linked against a scratch copy of compositor.m with kIFCBlurForceDirtyFrames = 1:
                      #   the test fails its second-frame check (compositor.m itself is not touched)
xcrun clang --analyze -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc comprender.m -o /dev/null
shasum -a 256 compositor.m background.m background.h build.sh                       # equal to review-renders/src.sha
```

Runs made while developing, each superseded by the scripts above:
`comprender --blur-test` against `build/glblur` on a 203 × 151 image for six
pass / offset pairs; `verify/check_effects.py` four times by hand (the first
run failed 3 of 121 checks, all three wrong expectations of the script: the
frost of a second window in the same pass, a second window's content in the
composition check, and progress 0.99 taken for finished); `verify/check.py`
and `verify/bgcompare.py` once by hand; `verify/render_scenes.sh` four times;
the three `--blur-cache-test` runs several times (they found that a pool of
textures keyed by extent thrashed, which is why pads, frost and mask are kept
per window as upstream keeps them, and that the `animate_blur_fps` cadence
needed its slack); `--churn-test 300` on six scenes twice; the many.json
bench six more times. `verify/run_all.sh` twice: the second run, made after the last change to the
sources before the review round, is the log.
