# Infinify compositor — notes

These notes document `IFCompositor.h` and its implementation files in `native/app/Canvas` (`IFCompositorRenderer.m`
and the files in the table below): the Metal renderer that
draws one output's whole frame, and the host protocol that `DWCanvasRenderer`
follows to drive it. The background it draws first is
[BACKGROUND-NOTES.md](BACKGROUND-NOTES.md). Where `IFCompositor.h` and
its implementation files cite `COMPOSITOR-NOTES.md`, they mean this file.

The renderer ports DriftWM's per-output frame composition to Metal: the canvas
background, the outlines of other outputs' viewports, and every window with its
shadow, border, rounded and clipped content, opacity and (optionally) a
compositor-drawn title bar, plus the stand-ins upstream draws for suspended
windows, and upstream's remaining rendering effects: the frosted-glass **blur**
behind windows, the **open / close animations** with their closing snapshots,
and the **config error bar**. One renderer per output draws the whole frame;
the same code renders a frame offscreen to an image
(`-newImageForFrame:error:`, which the screenshots use).

Upstream: DriftWM, <https://github.com/malbiruk/driftwm>, GPL-3.0-or-later,
commit `352333a8fa1b22171492d4b71a54102045c9a19d`. This module is a derived work
and carries the same licence.

- **Part I** (sections 1 to 14) is the compositor itself: provenance, public
  API, how the host drives it, geometry, draw order, colour, resources, redraw
  gating, deviations from upstream, behaviour kept on purpose, what is not
  supported.
- **Part II** (sections 17 to 22) is the effects: API additions, the host
  protocol for each, how they are built, every deviation from upstream, what is
  kept on purpose and what is not supported.

Section numbers are kept from the notes' earlier layout, which is why 9, 15, 16
and 23 to 25 are missing. Section 9 described the debug tool of the standalone port and the debug
API it used, both removed. Sections 15 and 16 (Part I
verification and commands) and 23 to 25 (the effects' verification, cost
measurements and commands) are not kept. The checks and measurements that the text below cites by tool name
(`comprender`, `verify/`, `scenes/`, `out/`) were made with the standalone
port's tooling, which is gone.

In the text below, `compositor-port` is the standalone port this module started
from (without the effects), "this copy" is the module with the effects added,
which is the implementation in the table below, and a citation of section 15, 16, 23, 24 or 25 refers to text that is no longer in this repository.

| File | What it is |
|---|---|
| `IFCompositor.h`, `IFCompositor+Private.h`, `IFCompositorRenderer.m`, `IFCompositorRenderer+Draw.m`, `IFCompositorRenderer+Blur.m`, `IFCompositorLayer.m`, `IFCompositorFrame.m`, `IFCDeviceResources.m`, `DWCompositorRasterizers.m` | The module (Objective-C, ARC). Depends only on `IFBackground.h` and system frameworks. |
| `IFBackground.h`, `IFBackgroundProgram.m` and the `IFBG*` files beside them | The canvas background module the compositor draws first. One method, `-encodeFrame:inEncoder:`, draws it inside the compositor's own render pass (section 14). |
| `DWCanvasRenderer.h`, `DWCanvasRenderer.m` and its categories | The host: builds the frames of sections 3 and 18 from the controller's snapshot and drives one `IFCompositorLayer` per output. |

How `DWCanvasRenderer` follows section 18 is written where it does so, in
`DWCanvasRenderer.h` and `DWCanvasRenderer.m`: which of the controller's lifecycle
events plays which animation, and the four things that are the shell's own
there. An animation begins one 60 Hz tick before the frame that first shows it
when the output has drawn nothing more recent, because this canvas draws on
demand (18.2, "Cadence"). A window that opens is held at the animation's first
instant, which is invisible, until its stream has delivered its first picture,
for a second at most (18.3), and the stand-in whose slot a relaunched window
adopted stays whole until that window's first picture likewise (18.4). Each
output bakes its own closing snapshot, at upstream's one density, instead of
sharing a texture (18.2, "Scale"). And upstream's age limit on a closing
window's pixels has nothing to test: the bake is taken from the element of the
frame last described, the picture that was on screen (18.2, "When not to").

# Part I — the compositor

## 1. Provenance

Hand-translated to Metal Shading Language in `IFCDeviceResources.m` (`kIFCMSL`).
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
`IFCDeviceResources.m`.

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

Everything is in `IFCompositor.h`. What the effects added is listed in section 17;
the list below is the rest of the API.

- **`IFCompositorFrame`** — what one output shows at one instant. `size`
  (points), `scale` (backing scale), `cameraX/Y` (world point at the top-left,
  Y down), `zoom`, `time`; `background` (an `IFBackgroundProgram`, shared
  between outputs); `clear` (opaque black = upstream's live output,
  transparent = upstream's screenshot target); `chrome`
  (`IFCompositorChromeStyle`: `bg_color`, `fg_color`, `corner_radius`,
  `title_bar_height`, `font`, `font_size`, `font_weight`, `title_align`);
  `decorationScale`; `placeholderColor`; `elements` (bottom to top);
  `outline` + `-setOutlineRects:count:`; `needsContinuousRedraw`.
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
  `-encodeFrame:intoTexture:commandBuffer:`, `-newImageForFrame:error:`
  (the offscreen export), `-purge`.
- **`IFCompositorLayer : CAMetalLayer`** — one output on screen.
  `-initWithRenderer:`, `-updateWithFrame:` (returns YES when it drew),
  `-setNeedsRedraw`, `needsContinuousRedraw`, `drawCount`, the presentation
  controls of section 3 (`paced`, `presentationTime`, `presentationInterval`,
  `drawableReady`, `drawablePending`, `missed`, `-stopDrawing`) and the
  presentation counters (`countsPresented`, `presentedCount`,
  `-takePresentationStats`).

## 3. How the host drives it

**Once per config load:** build one `IFBackgroundProgram` ([BACKGROUND-NOTES.md](BACKGROUND-NOTES.md),
section 3) and one `IFCompositorChromeStyle` from `[decorations]`.

**One layer per output.** `DWCanvasRenderer.m` keeps one compositor layer and one
frame description for each output, in the host layer's top-left coordinates:

```objc
IFCompositorLayer *layer = [[IFCompositorLayer alloc] initWithRenderer:nil];
layer.frame = CGRectOffset(outputScreenBounds, -origin.x, -origin.y);   // origin: the panel's global origin
[host insertSublayer:layer atIndex:0];                  // below the toolbar and the status line
IFCompositorFrame *frame = [IFCompositorFrame new];     // kept; refilled in place
```

**Update.** Call `-updateWithFrame:` on the main thread whenever anything may
have changed: after the host has described a frame, after a stream delivered
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
| `element.decoration` | the ported `effective_*` helpers of `crates/core/src/config/types.rs` (`effective_decoration_mode`, `effective_border_width`, `effective_border_color(_focused)`, `effective_corner_radius`, `effective_shadow_enabled`, `effective_opacity`), then `IFCompositorDecorationDrawn` (below). macOS windows carry their own title bar, so the mode is `client` |
| `element.kind = StandIn`, `rect`, `appName`, `title` | a placement whose source is gone (today's "Detached window" tile), under the window's identifier. **`rect` is not the window's rectangle:** a stand-in's `rect` is its body and the bar is drawn above it, so for a window that carried its own title bar (every macOS window; upstream's CSD origin) pass `IFCompositorStandInBodyRect(world_rect, YES, chrome.titleBarHeight)` = `(x, y + title_bar_height, w, max(h - title_bar_height, 1))`. Bar + body then cover exactly the placement's rectangle, which is what the shell culls and hit-tests with. Passing `world_rect` itself draws the stand-in 25 px too tall, its bar outside the placement. Set `pixelBuffer` and `texture` to nil (a stand-in draws no content; the renderer lets go of the buffer either way, the element only when cleared). `appName` = the app's display name, `title` = `windows[].metadata.title` (not drawn, see deviations). Its `decoration` comes from the global `[decorations]` table alone — upstream calls `effective_*(None, mode, config)` for a stand-in, no window rule — and it is never passed through `IFCompositorDecorationDrawn` (a stand-in is not subject to the coverage rule) |
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

**Presentation.** The layer chooses per frame. A first, resized or unpaced frame
presents inside the caller's `CATransaction` (`presentsWithTransaction = YES`),
so it lands in the same Core Animation commit as anything else the host
changed. With `paced` set, as in a display-link callback, an unchanged-size
frame presents by its command buffer at `presentationTime` (Mach absolute
seconds) without waiting for scheduling. Drawables are acquired on a private
serial queue, at most two kept ready; a frame that finds none leaves `missed`
set and the layer dirty, and `drawableReady` (main queue) tells the host to
retry within the same refresh. `-stopDrawing` cancels the acquisitions before
the layer is detached.

**Screenshots** (`msg screenshot`). Upstream renders a canvas region at a
chosen DPI with zoom 1 and no outlines, into a transparent target. Build a
frame with `size` = region size, `scale` = DPI scale, `camera` = region
origin, `zoom` = 1, `clear = IFCompositorClearTransparent`, no outline rects,
`background` = the program or nil, canvas-space elements, and call
`-newImageForFrame:error:` on a separate `IFCompositorRenderer`, then write
the image it returns. For an isolated `window` capture put only that element
in the frame.

**Blur, opening and closing windows, the error bar.** Section 18.

**Teardown.** `-[IFCompositorLayer stopDrawing]` (it cancels the drawable
acquisitions and releases the ready drawables), then `[layer
removeFromSuperlayer]` and drop the references. The layer and renderer start no
timers, display links or observers. Textures a frame in flight still samples
are released when that frame completes, even if the renderer is already gone.

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
  framebuffer. The layer's `colorspace` is sRGB and the image of
  `-newImageForFrame:error:` is tagged sRGB.
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
  title bar unless it still draws one. A stand-in's body is gone within four frames of
  becoming a live window, and a title bar when a server-decorated window turns
  client-decorated.
- CoreVideo's cache keeps the Metal texture of a released wrapper, and through
  it the IOSurface's memory, until a flush that comes at least one second
  (its default age, now set explicitly) after the buffer's last holder let go
  — the renderer or, later, the host. The renderer flushes at the end of the three
  encodes after a retirement — too early for that, but it is what returns the
  surface to its pool — and, independently, at most once every 1.5 s at the
  end of an encode or in an `-updateWithFrame:` that skips its redraw.
  Without such a later call (a host that never updates that output
  again) the surface stays mapped until the renderer is released or purged.
- A steady frame (nothing changed) costs a hash of the description (every
  field, every UTF-16 unit of each title and app name), one reading of the
  clock, and a flush of the texture cache every 1.5 s. A frame that redraws
  without new content allocates nothing in
  this module: uniforms go through `setVertexBytes` / `setFragmentBytes`, the
  render pass descriptor and the completion block are reused. Metal's own
  per-frame objects (command buffer, encoder, drawable) remain.
- The shadow and border quads are drawn as four strips around the region where
  their shader returns exactly zero (deviation 3). For the 320-element scene
  this took GPU time from 12.1 ms to about 4 ms with byte-identical output.

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
string at most. `time` alone never causes a redraw of a static frame. The sequence
first frame redraw; identical skip; time only
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
otherwise. The animated background's
`animate_fps` gate is unchanged and applies to the background only.

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
    The background module's own deviations ([BACKGROUND-NOTES.md](BACKGROUND-NOTES.md),
    section 8) carry over.
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
  `#e5a50a80` over the paper background comes out bright yellow.
- A corner radius beyond half the smaller side: the clip clamps it, the border
  and shadow do not, and the border disappears (radius 500).
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
  (background module).

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
  released by everyone for the cache's maximum age, and not before: a
  flush at 0.01 or 0.5 s after the last release keeps the memory, one at 1.2 or 1.7 s frees it, and none
  does while the buffer is alive; not found
  documented beyond the name of the attribute.

## 14. Changes to the copied background module

One method, added to `IFBackgroundProgram` (`IFBackground.h`, `IFBackgroundProgram.m`):

```objc
- (BOOL)encodeFrame:(IFBackgroundFrame)frame inEncoder:(id<MTLRenderCommandEncoder>)encoder;
```

It draws the background into a render pass the caller has already opened, so
the compositor can put it first in its own pass, and it is the background's
only encode entry point. The module's own offscreen path
(`-encodeFrame:intoTexture:commandBuffer:`, `-newImageForFrame:error:`,
`-writePNGForFrame:toURL:error:`) and its `IFBackgroundLayer` were removed on
2026-10-30; screenshots go through `-[IFCompositorRenderer
newImageForFrame:error:]`.

# Part II — effects: blur, lifecycle animations, error bar

The effects follow upstream's. The upstream files they were written from,
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

All in `IFCompositor.h`. They were added to the API of Part I without changing
any signature; enum values were appended (`IFCompositorElementKindSnapshot`,
`IFCompositorStackLayerClosing`); `IFCompositorDecoration` is unchanged.

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

## 18. Host protocol

### 18.1 Blur

```objc
frame.effects = effects;        // once per config load: [effects], through the ported parser
element.blur = effective_blur;  // per window, whenever its rule or fullscreen state changes
```

- `effective_blur` is the ported helper of
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
  (read off the code path; not measured). If the window's element stays in the
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
its content. The backing scale multiplies the tap
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
  squares the frost shows wherever the border's ring is (magnified in section
  23's "looked at").
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
