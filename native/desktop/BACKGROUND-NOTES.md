# Infinify canvas background — notes

These notes document `background.h` and `background.m`: the Metal renderer for
DriftWM's per-output canvas background (the built-in dot grid, user GLSL
shaders with or without an image, tiled images and cover-fit wallpapers), which
scrolls and zooms with each output's camera exactly as upstream's does, and the
two chunk caches added with it (`cache_shader` and tiled pyramidal TIFF tiles,
section 17, with `background-tiff.{h,m}`). The compositor draws the background
first in every frame ([COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md)); section 3
says how `canvas-renderer.m` and `compositor.m` drive it. Where `background.h`,
`background.m`, `background-tiff.h` and `background-tiff.m` cite
`BACKGROUND-NOTES.md`, they mean this file.

Upstream: DriftWM, <https://github.com/malbiruk/driftwm>, GPL-3.0-or-later,
commit `352333a8fa1b22171492d4b71a54102045c9a19d`. This module is a derived work
and carries the same licence.

Section numbers are kept from the notes' earlier layout, which is why 14 to 16
and 17.9 are missing: the verification, commands and review-round sections are
not kept, and a citation of section 14, 15, 16 or 17.9 below refers to text that is no longer in this repository. The checks and measurements that the text below cites by
tool name (`bgrender`, `verify/`, `assets/`, `fix-renders/`) were made with the
standalone port's tooling, which is gone.

### macOS wallpaper extension (2026-10-11)

The native shell now resolves the Mac desktop still and its scaling, clipping
and fill color per display when no explicit background source is configured.
Loading happens on a serial worker and the renderer reuses the resulting
program. Explicit sources retain their upstream resolution and fallback rules.
Inherited images may use ImageIO formats, including single-image HEIC and TIFF;
assets that require selecting a dynamic/video frame fall back.

`[background] parallax = true` (the Mac default) adds bounded camera movement
and slower zoom to wallpaper sampling. `false` restores a screen-fixed image.
This extends wallpaper uniforms and redraw dependency flags; it does not change
tile or user-shader coordinates. The inherited wallpaper shader also composites
the desktop fill color for letterboxing and image alpha. The exact upstream
source hashes below remain the provenance of the starting implementation.
The historical verification sections (not kept)
predate these additions; build/source checks do not establish their visual
behavior on the user's display.

For a deleted original still, `mac-wallpaper-cache.m` checks the image provider's
current-user cache for the exact SHA-256 source-path key and display resolution.
The cached bitmap can retain source dimensions, so scaling/fill remain the
desktop's options. This private on-disk format is an optional read-only fallback;
there is no search for unrelated recent images. Missing/unknown entries retain
the previous loaded image or grid and report only to the log. A headless check
on 2026-10-12 resolved the owner's missing still to its existing cache and
rejected unrelated paths and mismatched display keys; optical parity is unrun.

| File | What it is |
|---|---|
| `background.h`, `background.m` | The module (Objective-C, ARC). No dependency on the rest of the app. |
| `background-tiff.h`, `background-tiff.m` | The tiled pyramidal TIFF source and its decode pool (section 17). Foundation and ImageIO only; no Metal. |
| `metal-support.h` | The Metal plumbing `background.m` and `compositor.m` share: integer output size, per-device resource cache, shader compile options, linear sampler. Header-only. |

## 1. Provenance of the built-in shaders

Hand-translated to Metal Shading Language in `background.m` (`kIFBGBuiltinMSL`).
Constants, uniform semantics and colour math are unchanged; GLSL variable names
are kept so the two can be read side by side.

| Metal entry point | Upstream file | SHA-256 of the upstream file |
|---|---|---|
| `ifbg_dot_grid` | `src/shaders/dot_grid.glsl` | `a2dde8d16cc974ab3d0192020b30c2f60da8620216952eb36fac0f72a83d5683` |
| `ifbg_tile`, `ifbg_tile_mirror` | `src/shaders/tile_bg.glsl` (plain, and with `#define MIRROR` prepended as `compile_tile_bg_mirror_shader` does) | `f30921426cc816cead08a580937db5edc30977448997e1819a9c2865c053e839` |
| `ifbg_wallpaper` | `src/shaders/wallpaper_bg.glsl` | `50a2605d87382512f40d5cfe4207f837cb3c6a57afb5656af7b2d6d3a028f463` |
| `ifbg_chunk` (with `ifbg_chunk_vertex`, `kIFBGChunkMSL`) | `src/shaders/chunk_bg.glsl` | `ee97fa3361ef758e155bbd440b2672865052073eea2a344bf8882737fa2e29a0` |

`ifbg_chunk` draws one chunk of either chunk cache (section 17). It is the one
built-in drawn as a quad of its own instead of a triangle over the whole
target; its vertex function has no upstream counterpart (smithay places the
element).

The logic in `background.m` mirrors `src/render/background.rs` function by
function (`init_background`, `init_shader_bg`, `texture_or_shader_fallback`,
`textured_shader_or_fallback`, `shader_no_texture_dispatch`,
`wallpaper_cover_src`, `references_uniform`, `update_background_element`) and
cites the upstream expression next to each line of the uniform mapping.

## 2. Public API

Everything is in `background.h`.

- `IFBackgroundConfig` — the upstream `[background]` table, field for field:
  `type` (`default | shader | tile | wallpaper | none`), `path`, `texture`,
  `mirrorTile`, `cacheShader`, `transparentShader`, `cacheBudgetMB` (128),
  `animateFPS` (0, clamped to 1000). `cacheShader` and `cacheBudgetMB` drive
  the chunk caches of section 17.
  `+configWithTypeString:path:texture:warning:` reproduces
  `resolve_background_kind`, including its two warnings and `~` expansion.
- `IFBackgroundFrame` — `{cameraX, cameraY, zoom, width, height, scale, time}`.
- `IFBackgroundProgram` — a loaded background (compiled pipeline and/or image).
  Immutable; share one between all outputs.
  `+programWithConfig:device:` never fails: it falls back as upstream does and
  sets `errorText`. Properties: `config`, `device`, `kind` (what really
  renders), `errorText`, `animated`, `transparent`. Rendering:
  `-encodeFrame:inEncoder:`, which draws into a render pass the caller has
  already opened (the compositor's own). The module has no offscreen path of its
  own; a screenshot goes through the compositor
  ([COMPOSITOR-NOTES.md](COMPOSITOR-NOTES.md), section 14).
- The chunk caches (section 17): `cache`, `-programForOutput`,
  `-captureProgram`, `pendingChunkCount`, `-chunkGenerationForFrame:`,
  `chunkReadyHandler` and `-shrinkChunkCache`. All additive: a program without
  a cache behaves exactly as before, and for it `-programForOutput` and
  `-captureProgram` return the program itself.

## 3. How the host drives it

The host is `canvas-renderer.m`, and the draw is `compositor.m`: the background
has no layer of its own. `IFCompositorFrame.background` holds the program, and
the compositor encodes it as the first draw of each output's frame.

**Load.** `-[DWCanvasRenderer configure:]` runs once per config revision. It
builds an `IFBackgroundConfig` from the controller's `render.background` table
(`type`, `path`, `texture`, `mirror_tile`, `transparent_shader`, `cache_shader`,
`parallax`, `animate_fps`, `cache_budget_mb`) with
`+configWithTypeString:path:texture:warning:`, then builds the program:

```objc
IFBackgroundProgram *program = [IFBackgroundProgram programWithConfig:config device:nil];
```

The program's `errorText` (or, when it has none, the config's warning) is the
note the renderer keeps, and `errorText` is also offered to the error bar as one
of its messages (`-backgroundErrors:`). A reload builds a
*new* program: that is what re-reads the shader and the image from disk
(upstream re-reads on every config reload). `programWithConfig:` does file I/O
and a shader compile; the program is immutable afterwards unless it owns a chunk
cache (section 17).

**One program per output.** `-cache:output:` picks each output's program: the
shell's `backgroundForOutput` hook may answer one for that output (the Mac
desktop still, resolved per display, loaded on a serial worker) and otherwise the
shared program is used. The answer goes through `-programForOutput`, which is the
program itself unless it has a chunk cache, in which case the output gets a
program of its own that shares everything loaded. Such a program's
`chunkReadyHandler` marks the output dirty and redraws it. When the hook later
answers differently, `-refreshBackgrounds` swaps the program in, shrinks the
chunk cache of the one it replaced and redraws.

**Draw.** For each output the host fills one `IFCompositorFrame` (camera, zoom,
size, backing scale, `time`, `background`) and calls
`-[IFCompositorLayer updateWithFrame:]`. The compositor opens one render pass on
the drawable, clears it, and calls

```objc
[program encodeFrame:(IFBackgroundFrame){cameraX, cameraY, zoom, width, height, scale, time}
           inEncoder:encoder];
```

with the frame's own camera, zoom, size, scale and time. The program draws into
the open pass (section 2); `-encodeFrame:inEncoder:` returns NO, drawing
nothing, for `none` or when no pipeline could be built, and the frame then shows
its clear. Pass integral point sizes (they are rounded). The same frame also
feeds the blur: when an element asks for the frost, the compositor draws the
background once more into a texture the backdrop passes copy from
(COMPOSITOR-NOTES.md, section 18.1), because the background computes from the
pixel position and cannot be relocated.

**Redraw gating.** The compositor layer redraws when the hash of the frame
description differs from the last drawn frame's. The hash covers the camera, the
zoom, the output size and scale and the identity of the background program; it
does not cover `time` or the chunks of a cached program. The skips of the
earlier standalone background layer, which ignored a camera change for a
wallpaper or for a shader that did not declare `u_camera`, are not repeated: any
change of camera or zoom redraws the frame, whatever the kind, because the
windows move with them.

| Change since the last drawn frame | what the compositor does |
|---|---|
| camera, zoom, output size or backing scale | redraw |
| a new program object, `-setNeedsRedraw` | redraw |
| time | nothing, unless the program `isAnimated` (the shader reads `u_time`): then a redraw on every call, or at most `animate_fps` times a second when `animate_fps` is not 0 (upstream `background_animation_due`) |

A cached program's changes reach the screen another way (section 17.3): the host
forces a redraw of the output, whose description is unchanged, while
`pendingChunkCount` is not zero and when `chunkReadyHandler` fires.
`-chunkGenerationForFrame:` goes into the blur's key, not into the layer's hash
(COMPOSITOR-NOTES.md, section 18.1).

**Animated backgrounds.** While the program `isAnimated`, the frame's
`needsContinuousRedraw` is YES; the host keeps its frame callback running and
describes the frame on every tick with an advancing `time`, and the layer applies
the `animate_fps` budget itself. A cache that is still filling is redrawn the same
way until `pendingChunkCount` is zero. Upstream stops on DPMS-off and when a
fullscreen window conceals the canvas; when one conceals an output, the host
(outside native-window presentation) takes the background out of that output's
frame and shrinks its chunk cache. Use one clock for all outputs: `time` is
seconds since the app started.

**Several outputs.** Each output has its own `IFCompositorLayer`, camera and
zoom. A shared program compiles its shader once and uploads its image once
(upstream also compiles once, but loads the image per output). Outputs are
independent: each layer keeps its own "last drawn" state and its own `animate_fps`
stamp, like upstream's per-output `background_last_animate`, and a cached
program is one program per output.

**Presentation.** The compositor layer decides how a frame is presented
(COMPOSITOR-NOTES.md, section 3, "Presentation"). Encode on the main thread.

**Transparency.** The compositor clears opaque black for a live output. A
program that is `transparent` (`transparent_shader`, an image with alpha)
writes premultiplied colour with its own alpha into that clear, and the
compositor then makes a pass that sets alpha to 1, so the layer stays opaque
(section 8). A transparent clear (a screenshot target) keeps the background's
alpha.

**Teardown.** The host stops the layer, takes the background out of the frame and
calls `-shrinkChunkCache` on the program. There are no timers, display links or
observers to stop. The program frees its pipeline and texture with its last
reference. A small per-device cache (command queue, sampler, the built-in
pipelines) lives for the life of the process.

## 4. Uniform mapping

Infinify and upstream use the same convention, so the mapping is the identity:

| Infinify | Upstream | Meaning |
|---|---|---|
| `camera` (world point at the output's top-left, Y down) | `cur_camera`, `u_camera` | canvas pixels |
| `zoom` (screen points per world point) | `cur_zoom`, `u_zoom` | canvas → screen scale |
| output size in points | `output_logical_size` | logical pixels |
| backing scale | output scale | physical pixels per logical pixel |
| seconds since app start | `start_time.elapsed()`, `u_time` | seconds |

`screen = (world − camera) × zoom`. From `update_background_element`:

```
canvas_w   = ceil(output_w / zoom)             canvas_h likewise
size       = (canvas_w, canvas_h)              pixel shaders: `size`
u_output_size = (canvas_w, canvas_h)           tile and textured shaders
u_tile_size = u_texture_size = image size in pixels
u_camera   = (camera.x as f32, camera.y as f32)
u_zoom     = zoom as f32      u_time = time as f32      alpha = 1.0
```

`v_coords` is the fragment's position within the element, 0..1, origin
top-left. Upstream's element is the canvas area in logical pixels, scaled to
physical pixels and then rescaled by zoom around the output's top-left, with
integer rounding at both steps (`Element::geometry`, then
`RescaleRenderElement::geometry`):

```
dest_px  = round( round(canvas_w × scale) × zoom )       (Rust f64::round)
v_coords = (pixel centre in physical pixels) / dest_px
```

So `v_coords × size` is the canvas-pixel offset from the viewport's top-left,
which is what every upstream shader assumes. `dest_px` can exceed the output by
a pixel (the element overhangs and is clipped), and when
`canvas × scale × zoom` is not an integer the mapping is stretched by at most
half a physical pixel across the whole output. This port reproduces that
rounding rather than the ideal `pixel / (scale × zoom)`; at zoom 1 and at any
zoom where the product is integral the two are identical.

Wallpaper is the exception: the element covers the output, is not rescaled, and
samples the centred cover crop of `wallpaper_cover_src`:

```
dest_px  = round(output × scale)
v_coords = (crop_origin + (pixel centre / dest_px) × crop_size) / image_size
```

Images are sampled with linear filtering, clamp-to-edge, no mipmaps.

The whole mapping is one method, `-[IFBackgroundProgram uniformsForFrame:]`.

## 5. User shaders (`type = "shader"`)

**Route chosen: a small GLSL ES 1.00 → MSL source translation inside the
module.** Reasons:

- A transpiler library is not a way round it. glslang refuses to emit SPIR-V
  for `#version 100` shaders, so glslang + SPIRV-Cross would still need a
  source rewrite to modern GLSL first, plus roughly a quarter of a million lines
  of vendored C++ and a C++ build. ANGLE's translator does handle ES 1.00 →
  Metal but is far larger. Neither could be vendored here without downloading
  it, which this task had no permission to do.
- Metal Shading Language is C++14. GLSL ES 1.00 maps onto it almost token for
  token once the shader is placed *inside a struct*: globals, uniforms and
  functions become members, so helper functions read uniforms and mutable
  globals exactly as in GLSL, functions may be used before they are defined,
  and a user function called `saturate` or `round` hides Metal's instead of
  colliding with it.
- The user's text is edited in place and its line structure is preserved,
  with a `#line 1 "background.glsl"` in front, so a compiler error carries the
  user's own line number. The column is the user's too unless the translator
  widened something earlier on the same line (a constructor gains `gl_if_`, an
  `out` parameter becomes `thread T &name`, a contract declaration gains its
  initialiser), and the source line quoted under the message is the translated
  one. A message that names `ifbg_wrapper` instead of `background.glsl` points
  into the generated entry point: that would be a defect of the translation,
  not of the shader. The reviewed version produced such messages for shaders
  with macros (section 16); none is known now.
- No system dependency and nothing deprecated: the system's OpenGL could run
  the GLSL directly, but it is deprecated and cannot back a `CAMetalLayer`. It
  is not used.

What the translator does (`IFBGTranslateGLSL`: a 305-line function over a small
lexer, about 580 lines in all, token based — no regular expressions over code):

| GLSL | Becomes |
|---|---|
| `precision … ;`, `highp` / `mediump` / `lowp` | removed |
| `#version`, `#extension`, `#pragma` lines | blanked; all other preprocessor lines are passed to Metal's preprocessor. `GL_ES` and `GL_FRAGMENT_PRECISION_HIGH` are defined, `__VERSION__` is 100 |
| `uniform` / `varying` declarations | plain struct members. A declaration upstream feeds (next table) gets its value where it stands, as a default member initialiser: `uniform float u_time;` becomes `float u_time = gl_if_time;`, reading a leading member that the generated entry point fills in. The value therefore exists exactly when the declaration survives the shader's own `#if` / `#ifdef`, which is upstream's behaviour: pushing a uniform the compiled program lacks is a no-op |
| every identifier the shader mentions | `#undef` before the shader's first line and again after its last ("Macros" below) |
| function prototypes | removed (members see each other in any order) |
| `in` parameters | qualifier removed |
| `out` / `inout` parameters | Metal references (`thread T &name`, arrays too) |
| `vecN(…)`, `ivecN(…)`, `bvecN(…)`, `matN(…)` constructor calls | shims that apply GLSL's rules: every argument converted to the component type, one scalar splatted (vectors) or put on the diagonal (matrices), one larger vector truncated, matrices filled column-major from any mix of scalars and vectors |
| `mod`, two-argument `atan`, `inversesqrt`, `radians`, `degrees`, `dFdx`, `dFdy`, `matrixCompMult`, `lessThan` … `notEqual`, scalar `length` / `distance` / `dot` / `normalize` / `reflect` / `faceforward` | overloads with GLSL semantics (`mod` is `x − y·floor(x/y)`, not Metal's truncating `fmod`) |
| `texture2D`, `texture2DProj` (with and without bias) | sample the configured image |
| `discard` | `discard_fragment()` |
| `^^` | `!=` |
| `.stpq` swizzles | `.xyzw`, unless the name is a struct field declared in the shader |
| `gl_FragColor`, `gl_FragData[0]`, `gl_FragCoord`, `gl_FrontFacing`, `gl_PointCoord` | members |
| identifiers that are C++14 or Metal keywords (`new`, `auto`, `fragment`, `kernel`, `thread`, `xor`, `not`, …) | renamed with a `_glsl` suffix. `not` is C++'s spelling of `!`; the built-in `not(bvec)` is provided as `not_glsl` |

**The interface a shader sees** is upstream's (`docs/shaders.md`,
`BG_UNIFORMS`, `BG_TEX_UNIFORMS`):

| Without `texture` | With `texture` |
|---|---|
| `varying vec2 v_coords` | `varying vec2 v_coords` |
| `uniform vec2 size` | `uniform sampler2D tex` |
| `uniform float alpha` (1.0) | `uniform float alpha` (1.0) |
| `uniform vec2 u_camera`, `float u_zoom`, `float u_time` | `uniform vec2 u_camera`, `float u_zoom`, `float u_time` |
| | `uniform vec2 u_output_size`, `vec2 u_texture_size` |

Anything else a shader declares as a uniform is zero, as GL leaves it. That
includes `size` on the texture path and `u_output_size` on the plain path,
which upstream does not provide either. A declaration is recognised by its
spelling: `uniform <type> <name>` with a name and type from the table, not an
array, any precision qualifier, any number of names in one declaration.

`animated` and the "samples `tex` without a texture"
test use upstream's `references_uniform` literally: a substring search of the
raw source for `uniform [precision ]<type> <name>`. It therefore also matches
inside comments and matches names that merely start with the given name, as
upstream's does. A `uniform float u_time` inside an inactive `#ifdef` likewise
still makes the background count as animated (upstream's test sees it too),
although the compiled shader has no such uniform.

**Macros.** GLSL ES 1.00 predefines `__LINE__`, `__FILE__`, `__VERSION__` and
`GL_ES` and nothing else, and a shader's macros end with its text. Neither is
true of the Metal translation unit by itself:

- `<metal_stdlib>` defines macros with ordinary names. The runtime compiler's
  headers on this machine
  (`/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/lib/clang/32023/include/metal`)
  contain 193 `#define`d names that are legal GLSL identifiers: `INFINITY`,
  `NAN`, `MAXFLOAT`, `HUGE_VALF`, the `FLT_*` / `DBL_*` / `HALF_*` / `BFLT_*`
  / `INT_*` / `CHAR_*` limits, `M_PI_F`-style constants, `TARGET_OS_*`,
  `METAL_*` helpers, `assert()`, `is_function_constant_defined()` and about
  twenty `_is_valid_*` helpers. A shader with `const float INFINITY = 1.0e10;`
  or a function called `assert` did not compile.
- The generated entry point follows the shader in the same translation unit,
  so the shader's own `#define time u_time`, `#define zoom u_zoom` or
  `#define s 0.75` rewrote it.

Both are closed the same way and without a list: every identifier that occurs
anywhere in the shader's text gets an `#undef` line before
`#line 1 "background.glsl"` and again after the shader's last line. Before the
text this removes any Metal macro the shader could collide with; after it, it
removes every macro the shader defined (a macro's name necessarily occurs in
the text). `#undef` of a name that is not a macro does nothing, and the Metal
compiler accepts it for keywords, types and library functions without a
diagnostic. A fixed list of the 193 names
would also have fixed the reported cases, but the set belongs to the toolchain
and its feature switches (in `metal_types` the `BFLT_*` names sit under
`__HAVE_BFLOAT__`, and `M_PI` and the `DBL_*` names under
`__HAVE_NATIVE_DOUBLE__`, which is why `M_PI` was not among the reported
failures), and the runtime compiler is updated with the OS, so a list can go
stale.

Left alone: names containing `__` and names starting with `GL_` (reserved in
GLSL; the compiler's built-in macros and this module's `GL_ES` /
`GL_FRAGMENT_PRECISION_HIGH` live there), and `defined` and the C++ operator
spellings (`and`, `or`, `not`, `xor`, `bitand`, `bitor`, `compl`, `and_eq`,
`or_eq`, `xor_eq`, `not_eq`), which the preprocessor refuses as macro names. A shader's own use of one of those
operator words never reaches Metal under that name: it is renamed with
`_glsl` like any other reserved word.

Checked with the standalone port's tooling: the 193 header names plus 147 identifiers
that the generated code spells out, that shader authors commonly use, or that
are C++ keywords and operator spellings (`in`, `U`, `s`, `position`, `buffer`,
`stage_in`, `texture`, `sampler`, `float4`, `time`, `zoom`, `camera`,
`saturate`, `lerp`, `not`, `and`, `new`, …), each used as a constant, a local
variable, a function and a macro. Every shader the system OpenGL compiler
accepts (339, 339, 339 and 340 of the 340 names) compiles here and draws the
same pixels.

**Every bundled shader renders.** The last column is the largest difference, in
8-bit levels, between this module's output and the system OpenGL compiler
running the unmodified file (two frames each: zoom 1 at scale 1, and zoom 0.37
at scale 2 with a fractional camera).

| `extras/wallpapers/…` | SHA-256 (first 12) | Path | Result | max diff vs OpenGL |
|---|---|---|---|---|
| `dot_grid.glsl` | `a2dde8d16cc9` | pixel | renders; pixel-identical to the built-in | 0 / 1 |
| `static/blue_drift.glsl` | `f3f8fc1c894b` | pixel | renders | 1 / 1 |
| `static/compass_grid.glsl` | `4204a701f72a` | pixel | renders | 1 / 1 |
| `static/dark_sea.glsl` | `f48197b6f65f` | pixel | renders | 1 / 1 |
| `static/pink_cloud.glsl` | `aa7a6467cccb` | pixel | renders | 1 / 1 |
| `animated/acid_lava.glsl` | `50237bb86a65` | pixel, animated | renders | 1 / 1 |
| `animated/dense_clouds.glsl` | `ac94dee3e703` | pixel, animated | renders | 1 / 1 |
| `animated/fast_smoke.glsl` | `17255bef4707` | pixel, animated | renders | 1 / 1 |
| `textured/mirrored_parallax.glsl` | `1ef74dd9421b` | texture | renders | 0 / 1 |
| `textured/ripple.glsl` | `46264db25198` | texture, animated | renders | 1 / 1 |

Unsupported bundled shaders: none.

**GLSL the translator does not handle** (the shader then fails to compile and
falls back like any broken shader, with Metal's message):

- `==` / `!=` between whole vectors or matrices (Metal compares component-wise;
  use `all(equal(a, b))`).
- A swizzle passed to an `out` / `inout` parameter (`f(v.xy)`).
- Struct constructors (`Light(dir, k)`); assign the fields instead.
- A global `const` used as an array size (`const int N = 4; float a[N];` at
  file scope). Local constants and `#define` work.
- A vector constructor given more components than it needs across several
  arguments (`vec3(vec2, vec2)`). A single larger vector is handled.
- `samplerCube` / `textureCube`, and `texture2DLod`.
- A local variable initialised from a function of the same name
  (`float length = length(v);`).
- A user function that overloads a built-in by name hides *all* overloads of
  that built-in.
- `gl_FragCoord` is supplied in physical pixels with a top-left origin. In GL
  its vertical direction depends on the backend; `v_coords` is the documented
  input.
- Extra varyings: one that is declared but never read is accepted (it links
  upstream); one that is read is rejected with an explicit message, because the
  fixed vertex stage only writes `v_coords`.
- A contract declaration spelled through a macro: `#define T u_time` /
  `uniform float T;`, or a declaration that comes out of a macro body
  (`#define DECL uniform float u_time;`). It compiles, but the uniform stays
  zero, because the translator recognises the declaration by its spelling. The
  reverse also holds: after `#define size extent`, `uniform vec2 size;` declares
  `extent` upstream (never set, zero) and receives the canvas size here.
- `#define defined …`: the Metal preprocessor refuses `defined` as a macro
  name.

## 6. Fallbacks and error text

Same decisions as `init_background`. In every row below the dot grid is drawn
and `errorText` is set; the prefixes are upstream's, the part after the last
colon comes from this platform.

| Situation | `errorText` |
|---|---|
| shader file unreadable | ``background shader '<path>': No such file or directory (os error 2)`` |
| shader does not compile (no texture) | ``background shader: compile error: background.glsl:11:18: error: use of undeclared identifier …`` |
| shader does not compile (with texture) | ``background shader '<path>': compile error: …`` |
| shader declares `uniform sampler2D tex` but no `texture` is set | ``background shader '<path>': samples `tex` but no `texture` is set — add a `texture` path under [background]`` |
| image for tile / wallpaper / textured shader cannot be loaded | ``background image '<path>': …`` |
| PNG that ends early, has no `IEND` chunk, or whose `IHDR` / `PLTE` / `IDAT` / `IEND` fails its CRC | ``background image '<path>': unexpected end of file (the PNG is truncated in its IDAT chunk)`` / ``… (the PNG is truncated after its IDAT chunk)`` / ``… CRC error in the IDAT chunk (the PNG is damaged)`` |
| JPEG whose data ends early | ``background image '<path>': unexpected end of file (the JPEG is truncated or damaged, ImageIO status -5)`` |
| image larger than 16384 px on a side | ``background image '<path>': upload failed (image likely too large) — gigapixel wallpapers need a tiled pyramidal TIFF`` |
| wallpaper with a `.tif` / `.tiff` path | ``wallpaper '<path>': TIFF isn't supported in wallpaper mode (PNG/JPEG only) — use [background] type = "tile" for TIFF images`` |
| tile with a `.tif` / `.tiff` path that cannot be opened | ``tile bg '<path>': open <path>: No such file or directory (os error 2)`` |
| … that is not a TIFF, or whose first directory cannot be read | ``tile bg '<path>': not a TIFF (<path>): the file does not begin with a TIFF signature`` |
| … with a later directory that cannot be read | ``tile bg '<path>': next_image during scan: …`` |
| … with a page stored in strips | ``tile bg '<path>': TIFF is stripped, not tiled — needs a tiled, pyramidal TIFF`` |
| … with a planar page | ``tile bg '<path>': planar TIFF (PlanarConfiguration=Planar) not supported`` |
| … with a page that is not 8-bit RGB or RGBA | ``tile bg '<path>': unsupported color type Gray(8) (need RGB8 or RGBA8)`` (also `RGB(16)`, `CMYK(8)`, `YCbCr(8)`, `Palette(8)`, …) |
| … with tiles that are not square | ``tile bg '<path>': LOD 0: non-square tile dims (256, 128) not supported`` |
| … whose fallback level cannot be decoded at all, or uploaded | ``tile bg '<path>': LOD 2: every tile failed to decode`` / ``tile bg '<path>': fallback texture upload: …`` |
| `cache_shader` with a bakeable shader that does not compile | ``background shader '<path>': compile error: …`` (with the path, where the live path's message has none: upstream's `try_init_shader_chunks`) |
| `type` without `path`, unknown `type` | ``config: [background] type="shader" requires `path`, using default`` / ``… unknown type "x", using default`` (returned as the config helper's `warning`) |

Compiler output is condensed to its `error:` diagnostics; warnings and Metal's
lists of overload candidates are dropped.

**Damaged images.** ImageIO does not report a damaged file by itself:

| File | `CGImageSourceGetStatusAtIndex` before / after decoding | What ImageIO returns |
|---|---|---|
| intact PNG, intact JPEG | complete / complete | the picture |
| PNG cut at 300 bytes | complete / complete | an image whose pixel data is empty |
| PNG cut in half | complete / complete | the decoded rows, the rest empty |
| PNG without `IEND`, PNG with one bit flipped in `IDAT` | complete / complete | a whole picture; the damage is not noticed |
| JPEG cut in half | complete / unexpected EOF (-5) | the decoded part over grey |
| JPEG without its end-of-image marker | complete / complete | the whole picture |

So the reviewed version drew a transparent background, or the top of the
picture over black, with no error. Asking for the status right after creating
the image (the fix the review suggested) changes nothing: it is "complete" for
every file above at that point. `IFBGLoadImage` therefore

- walks a PNG's chunk list itself before decoding (`IFBGPNGDefect`): every
  chunk must be present in full up to and including `IEND`, and a critical
  chunk must carry the CRC of its contents. A wrong CRC on an ancillary chunk
  and bytes after `IEND` are accepted;
- reads the status *after* the pixels have been decoded and requires
  "complete". This is what catches a JPEG cut short.

See deviation 13 for where this may differ from upstream's decoders.

## 7. Colour

- The render target (layer drawable and offscreen texture) is
  `MTLPixelFormatBGRA8Unorm` — deliberately not an `_sRGB` format. Shader
  output is stored as written, with no transfer function applied, exactly like
  upstream's GL framebuffer. Images are uploaded as `RGBA8Unorm` from the
  file's raw samples, so sampling and filtering also happen on encoded values,
  as upstream's do.
- The layer's `colorspace` is sRGB, and the image of an offscreen export is
  tagged sRGB. Upstream hands the same numbers to the scanout with no
  colour management, which means "interpret as the display's native encoding",
  in practice sRGB. Tagging them sRGB makes Core Animation show those colours
  correctly on a Display P3 panel instead of stretching them to the wider gamut.
- An image's embedded profile is ignored, as upstream's `image` crate ignores
  it: a Display-P3-tagged photo shows the same (slightly desaturated) numbers
  it shows upstream. Verified for gAMA-tagged, greyscale, P3-tagged,
  P3-converted and palette PNGs: samples pass through bit for bit.
- Opaque backgrounds are exported without an alpha channel. Transparent ones
  are premultiplied in the framebuffer, and the exported image carries that
  alpha (compositor.h, `-newImageForFrame:error:`).

## 8. Deviations from upstream

1. **`v_coords` is computed per fragment** from the pixel centre instead of
   being interpolated from the vertex stage. It is the same value to within
   float rounding, but a shader with a hard edge that falls *exactly* on a
   pixel centre can resolve that pixel either way (measured: 11 of 479,596
   pixels of a deliberately edgy test shader, against OpenGL; such pixels
   differ between GPUs upstream too).
2. **Flags after a fallback describe the dot grid.** When a user shader fails
   to compile, upstream still derives `is_animated` / `uses_camera` /
   `uses_zoom` from the rejected source; here they describe what is drawn, so a
   broken animated shader does not cause per-frame redraws of a static grid.
3. **No stale uniforms.** Upstream refreshes tile uniforms only when the camera
   or zoom changes, so after an output resize `u_output_size` is stale until
   the next camera move. Here every drawn frame uses current values.
4. **Error wording** after the upstream prefix: Metal diagnostics instead of a
   GL info log, `strerror` text in Rust's `(os error N)` shape, and this port's
   own wording for image decode failures.
5. **Image decoding** uses ImageIO and vImage instead of the `image` crate.
   PNG samples are identical. JPEG decoders may differ by a level or two.
   The format is detected from the file's content, not its extension. CMYK and
   other non-RGB, non-grey images are converted to sRGB by CoreGraphics.
6. **Opaque regions and damage tracking** are Wayland concepts with no
   equivalent here; the redraw table in section 3 takes their place.
7. **`none`** presents one transparent frame so nothing of a previous
   background remains; upstream emits no element at all.
8. **Output size** is rounded to whole points, since upstream's logical output
   size is an integer. A zoom or scale that is not a positive finite number is
   treated as 1.
9. **Sampler uniforms with other names.** Any `sampler2D` reads the configured
   image (GL's default texture unit 0 does the same). Without a configured
   image, a sampler whose name does not start with `tex` reads transparent
   black instead of whatever GL happened to have bound.
10. **Transparent compositing** is done by Core Animation: the same
    premultiplied source-over as upstream's blend, but in the window server's
    colour pipeline.
11. **Tile with a TIFF path**: drawn from the pyramid since section 17, which
    lists that path's own differences from upstream.
12. **Alpha is forced to 1 on the plain-shader path** unless
    `transparent_shader` is set. upstream's `docs/shaders.md` says the alpha component "is
    ignored by default — backgrounds are composited opaque", and
    `background.rs` declares the whole area opaque. smithay 0.7.0 nevertheless
    draws a pixel-shader element with blending on (section 13, item 5), so
    upstream a shader that writes alpha below 1 without `transparent_shader` is
    blended over whatever the framebuffer still holds there (nothing is drawn
    beneath an opaque region). The port follows the documentation instead:
    the documented `transparent.glsl` without the option
    gives `(128,0,0,255)`.
    The dot grid and all ten bundled shaders write alpha 1, so their pixels are
    the same either way. On the texture path (tile, wallpaper, textured shader)
    forcing alpha to 1 is exactly what upstream's blend-off draw does. No code
    was changed for this; reproducing blend-over-stale would need the previous
    frame as an input.
13. **Damaged image files** are detected by this port's own checks (section 6),
    not by upstream's decoders, which could not be run here: the `image`, `png`
    and `zune-jpeg` crates are not on this machine and nothing was downloaded.
    What follows about them is from knowledge of the crates, not from reading
    or running them.
    - Truncated PNG, and PNG with a damaged critical chunk: an error here, and
      expected to be an error upstream (`png` 0.18 reports an unexpected end of
      file or a CRC mismatch).
    - PNG with all its image data but no `IEND`: an error here; upstream not
      known. The window is the last 12 bytes of the file.
    - Wrong CRC on an ancillary chunk: accepted here; believed to be `png`'s
      default too.
    - PNG whose chunks and CRCs are intact but whose compressed stream is
      wrong: not detected here; ImageIO draws what it can.
    - **Truncated JPEG: an error here, probably a picture upstream.** `image`
      0.25 is believed to build its `zune-jpeg` decoder with strict mode off,
      in which a premature end of data is logged and the rows decoded so far
      are returned. If that is right, upstream shows the top of the picture
      and no error where this port shows the dot grid and
      `unexpected end of file`. The review asked for the fallback; reverting to
      the lenient behaviour is deleting the status check in `IFBGLoadImage`.
      Owner's call.
    - JPEG that lacks only its end-of-image marker: accepted, and decodes to
      the same pixels as the intact file.

## 9. Not supported

- The `NO_ALPHA` and `DEBUG_FLAGS` shader variants (never selected for a
  background: images are always uploaded as RGBA8).
- Image formats other than PNG and JPEG are rejected, as upstream's build does.
  A TIFF is read only as `type = "tile"`, and only when it is tiled (section 17).
- A pyramid stored in SubIFDs (`vips tiffsave --subifd`) is read as its first
  page alone: upstream's reader follows the chain of pages and nothing else,
  and so does this one.
- The GLSL constructs listed at the end of section 5.

## 10. Upstream behaviour kept on purpose

These look like bugs but are what upstream's code does; changing any of them is
a product decision, not a port fix.

- **The dot grid has no level-of-detail.** Dots are 1 canvas pixel in radius
  with a 1-canvas-pixel soft edge and are evaluated only at physical pixel
  centres. Zoomed out, a pixel centre may never come near a dot:
  at zoom 0.5, scale 1, camera (0,0) each dot is four pixels of value 5/255;
  at zoom 0.25, scale 1, camera (0,0) the image is entirely black; with the
  camera at (1,1) and (2,2) respectively each dot is one full-white pixel. Dots
  therefore shimmer while panning when zoomed out on a 1x display. On a 2x
  display zoom 0.5 is crisp. The shell clamps interactive zoom to at most 1
  (`-[DesktopView zoom:at:output:]`), so zoomed-out is the range users live in.
- **Images with alpha are uploaded un-premultiplied and composited as
  premultiplied.** A half-transparent orange texel `(255,140,0,128)` reaches
  the framebuffer unchanged, and a transparent texel keeps its hidden colour.
  Fringes of antialiased PNGs are brighter than they should be. Premultiplying
  in `IFBGLoadImage` would be a few lines if the owner prefers correct fringes.
- **`mirror_tile` and plain tiling use linear filtering clamped at the image
  edge**, so plain tiles do not blend across the seam.
- **The element rounding** described in section 4.

## 11. Math mode

User shaders and built-ins are compiled with `MTLMathModeSafe` (IEEE-754
arithmetic, no reassociation) and `MTLMathFloatingPointFunctionsFast`.

`MTLMathFloatingPointFunctionsPrecise` was tried and rejected on evidence:

| | fast_smoke, 3456×2234, GPU ms/frame | Far from origin (camera ≈ 250000, t = 3600 s), share of pixels more than 2 levels from OpenGL |
|---|---|---|
| fast math | 7.8 | fast_smoke 0.001 % |
| safe math, fast functions (shipped) | 8.6 | fast_smoke 0.024 %, dark_sea 0, blue_drift 0 |
| safe math, precise functions | 20.6 | fast_smoke 84 %, dark_sea 49 %, blue_drift 94 % |

(All three rows are from one session; frame times vary by about 15 % between
sessions, which is why section 12 shows 7.4 ms for the shipped mode.)

The bundled noise shaders hash coordinates through `fract(sin(x) * 43758.5453)`.
Far from the origin the result depends on the last bits of `sin`, so a more
precise `sin` draws a *different* pattern, not a better one. Near the origin all
three modes agree with OpenGL to within one level. The same sensitivity means
upstream's own picture at such coordinates differs between GPU vendors.

## 12. Cost

Static backgrounds cost a draw only when the camera, zoom or size changes;
animated ones cost it on every tick, and the heavy shaders leave little of a
120 Hz frame, which is what `animate_fps` is for.

## 13. Assumptions about smithay

DriftWM renders through smithay at git revision
`4cf0b62028039661477d482ec4758b687d8f4392` (`Cargo.lock`: version 0.7.0 from
git). That revision is not on this machine and was not downloaded. The
crates.io release `smithay-0.7.0` is (`~/.cargo/registry/src/*/smithay-0.7.0`),
and during review round 1 the five points below were read in it. They are
therefore checked against 0.7.0 as published, not against the pinned revision.
Paths are relative to `src/backend/renderer/`.

1. A pixel shader's `size` uniform is the element's logical area, and
   `v_coords` runs 0..1 over the element's destination rectangle.
   `gles/element.rs:116-124`: `PixelShaderElement::draw` passes
   `self.area.size.to_buffer(1, Transform::Normal)`; `gles/mod.rs:2877` sets
   it with `Uniform2f(program.uniform_size, …)`. DriftWM says the same three
   times: `dot_grid.glsl` ("Zoom is handled externally (RescaleRenderElement) —
   shader works in canvas space"), `compass_grid.glsl` ("size is the visible
   canvas area") and upstream's `docs/shaders.md` (`u_output_size` = "output / zoom",
   "carries the same value" as `size`).
2. `RescaleRenderElement::geometry` rounds the scaled rectangle with
   `to_i32_round`, after the element's own rounding to physical pixels
   (`element/utils/elements.rs:56`).
3. Textures are sampled `GL_LINEAR` / `GL_LINEAR` (`gles/mod.rs:630-631`, the
   renderer's defaults, which DriftWM never changes), `CLAMP_TO_EDGE`
   (`gles/mod.rs:978-980`), without mipmaps.
4. `import_memory` (`gles/mod.rs:936`) uploads the bytes as given, without
   premultiplying.
5. Blending is switched on with `(ONE, ONE_MINUS_SRC_ALPHA)` when a frame
   starts (`gles/mod.rs:2061-2062`) and switched off only inside `clear`
   (2223), `draw_solid` (2251) and, for the opaque part of the damage,
   `render_texture_from_to` (2586). `render_pixel_shader_to` (2797-2935) never
   switches it off, and `PixelShaderElement::draw` ignores the opaque regions
   it is handed. So:
   - texture path (tile, wallpaper, textured shader): the opaque region is
     drawn with blending off, the rest with premultiplied source-over;
   - plain pixel-shader path (the dot grid and `type = "shader"` without a
     texture): always premultiplied source-over, opaque region or not.

   An earlier version of these notes said opaque regions are drawn with
   blending off everywhere. That was wrong for the pixel-shader path; the
   consequence is deviation 12.

If 1 or 2 were wrong the dot spacing would not track zoom, or would be off by a
sub-pixel stretch; 3–5 affect only filtering and alpha.

## 17. Chunk caches: `cache_shader` and tiled pyramidal TIFF tiles

Added in this repository (milestone 19), after the port above was adopted.
Upstream, same commit: `src/render/shader_chunks.rs`,
`src/render/tile_chunks.rs`, `src/render/tile_chunks_tiff.rs`,
`src/render/tile_worker.rs`, `src/shaders/chunk_bg.glsl`,
`src/render/capture_background.rs`, `docs/gigapixel-wallpapers.md`, and in
`src/render/background.rs` `init_tile_chunks_bg`, `try_init_shader_chunks` and
`shader_no_texture_dispatch`.

| File | What it holds |
|---|---|
| `background.m`, "Chunk caches" | `IFBGShaderChunks` (`ShaderChunkCache`), `IFBGTileChunks` (`BgChunkCache`), `IFBGTileLayout` (`derive_chunk_layout`, `compute_aggregations`, the fallback level), `pick_lod`, the visibility queries, `evict_lru_to_budget`, and where a chunk lands in pixels |
| `background.m`, "Program" | which program gets a cache (`-load`, `-loadPyramid:`), the frame of a cached program (`-chunkDrawsForFrame:`, its work, and `-encodeChunksOfFrame:inEncoder:`, its draw), `-chunkGenerationForFrame:`, `-programForOutput`, `-captureProgram` |
| `background-tiff.{h,m}` | `IFBGTiffSource` (`TiffSource`: the walk over the file's pages, `read_block`, `read_whole_lod`) and `IFBGTileWorkerPool` (`WorkerPool`). No Metal, no dependency on the rest of the module |
| `canvas-renderer.m` | the host's side: one cache per output, its redraws while it fills, its shrink under a fullscreen window, the capture |
| `compositor.m` | the one thing changed there: the chunk generation of a cached background, asked before the frosts are prepared and mixed into the two keys a frost is kept by (17.3) |

### 17.1 What is cached

- **`cache_shader = true`** on `type = "shader"` without a `texture` and
  without `transparent_shader`, when the shader declares `uniform vec2
  u_camera` and declares neither `uniform float u_time` nor `uniform float
  u_zoom` (upstream's `references_uniform`, the same substring test as section
  5: a declaration in a comment counts). Everything else is drawn live exactly
  as before, silently: the default dot grid, a textured shader, an animated or
  zoom-reading one, one without `u_camera` (it is fixed to the screen; baked
  into canvas chunks it would scroll). `IFBackgroundProgram.cache` says which
  it is. A shader that moves with the camera at any rate but 1:1 (`u_camera *
  0.5`) bakes wrong, upstream too: its documentation calls it a footgun.
- **`type = "tile"` with a path ending in `.tif` / `.tiff`**: a tiled TIFF
  whose pages are 8-bit RGB or RGBA, chunky, with square tiles. Each page is
  one level, page 0 the full resolution. A file with a single tiled page is
  accepted (upstream's code has no refusal for "no pyramid": that level is
  then the whole picture, one texture, and must fit one). `mirror_tile` does
  nothing here, as upstream documents. `wallpaper` with a TIFF is refused as
  before.

### 17.2 One cache per output

Upstream keeps `cached_shader_chunks` and `cached_tile_chunks` per output: the
chunks are baked at that output's scale, and the budget, the per-frame
allowances, the LOD bookkeeping and the decode pool are that output's. Here
`-[IFBackgroundProgram programForOutput]` returns, for a cached program, a
program that shares everything loaded and owns one cache; `canvas-renderer.m`
asks once per output and per configuration. `cache_budget_mb` therefore bounds
each output's cache, not their sum, as upstream's does. Shared between the
outputs, where upstream has one per output: the open file, the decoded
fallback level, the compiled shader.

Invalidation: a config load builds a new program (RENDER.md, `revision`), the
outputs take new programs from it and the old caches, with their decoders,
are released: upstream's `reload` clears both maps. A baked cache is for one
output scale (`bake_px = round(1024 × scale)`): a frame at another scale starts
it again, as upstream drops an output's cache when its scale changes. A TIFF
cache holds nothing that depends on the scale and is kept. `-[DWCanvasRenderer
reset]` drops every output and with it every cache.

### 17.3 How the host drives a cached program

A cached program is drawn through the same two calls as any other
(`-encodeFrame:inEncoder:`, from the compositor's pass, which also serves the
compositor's offscreen export). What is new:

- **Encoding a frame works first.** A baked shader bakes the chunks this frame
  may (below) in one command buffer of the module's own queue and waits for it
  (`waitUntilCompleted`) before the caller's pass samples them: upstream's
  bake is synchronous in its frame too. A TIFF cache turns at most eight
  decoded blocks into textures and asks its decoders for what is missing.
  Main thread only.
- **Each instant is one frame.** When a window is frosted the compositor asks
  a cached background three times in one frame (the chunk generation below,
  then two encodes: its backdrop copy and the pass). The same
  `IFBackgroundFrame`, `time` included, returns the same quads and spends
  nothing more; the next instant spends the next allowance.
- **`-chunkGenerationForFrame:`** does a frame's chunk work without its draw
  and returns a number that changes whenever the chunks a frame draws from
  did: a bake, an upload, an eviction, a shrink that dropped something. It is
  0 for a program without a cache. Upstream's blur refreshes a frost,
  uncapped, when the list of background elements changes (`blur.rs`
  `background_structure_changed`, `shared_refresh_due`), and each drawn chunk
  is one element. The encode is what bakes and uploads, and the compositor
  computes its frost keys before it encodes, so `compositor.m` calls this
  first, on frames that have a blurred window, and mixes the number into the
  shared refresh and into each window's key: the frame a chunk lands in is
  the frame that recomputes the frost over it. Without it the frost under a
  blurred window stayed the blur of the coarse cover or of the fallback level
  until the camera next moved (found in review; 17.9). The number says more
  than upstream's list: evicting a chunk outside the view changes it too,
  which costs one frost recompute on a frame that baked or uploaded anyway.
- **`pendingChunkCount`** is upstream's `has_pending_bakes` /
  `has_pending_loads`: while it is not zero the output is redrawn at display
  rate. `-[DWCanvasRenderer animates:draw:]` reports it with the animations,
  so the shell's one frame timer serves it and stops when nothing is pending:
  a display link at the display's refresh rate
  ([README.md](README.md#rendering)), 120 Hz on a ProMotion display. The
  redraw is forced on the layer because its description did not change, and
  it is one a tick at most: an output that has drawn since the last tick for
  a reason of its own (the camera frame of a flight, which the shell
  describes and draws inside the tick before it asks; a window's picture; a
  decoded chunk's wake-up) has had that tick's frame and is not forced again,
  since every frame drawn spends the allowances below, which upstream grants
  once per output frame. With nothing pending nothing is drawn.
- **`chunkReadyHandler`** is upstream's `loop_signal.wakeup()`: called on the
  main thread when a decoded chunk waits, once however many arrived before it
  ran. The renderer marks that one output dirty.
- **`-shrinkChunkCache`** is upstream's `shrink`, called for an output whose
  canvas a fullscreen window conceals, on every such description. Upstream
  calls it on every frame of that session, so that a block a decoder was
  still working on when the cache was shrunk is discarded when it arrives;
  here no frame is drawn for a description that did not change, so the
  renderer's ready handler shrinks again for a concealed output, which
  discards the block then.

### 17.4 The baked shader

`shader_chunks.rs` function by function. Chunks are squares of
`1024 << LOD` canvas units, LOD 0 to 7, each a texture of `bake_px` texels a
side plus a one-texel apron of its neighbours' pixels (`apron_dims`), so 1026²
texels (4.2 MB) at every LOD at 1x, and at 2x 2052² at LOD 0 and 2050² at
every LOD above it (16.8 MB either way: there the apron is half a canvas unit
at LOD 0, rounded up to a whole one). A chunk is baked
by running the shader once with `size` the padded span and `u_camera` its
top-left corner, through the live pipeline and uniform block. Per frame: the
LOD 7 cover of the visible rectangle is baked at once and stamped; the target
LOD is `pick_lod(zoom)` (`ceil(-log2 zoom)`, 0 from zoom 1 up); its missing
cells are baked two a frame, sixteen on the frame the target LOD changes; the
rest are pending and show the finest coarser chunk that is cached. A view whose
cover and target cells together exceed the budget is "degraded": only the cover
is drawn (upstream logs it; so does this port, on stderr, in upstream's words).
Eviction is least-recently-stamped first, after the frame's chunks were chosen.

**Where upstream's bake is not its live render.** The task of this port was
to match the live render wherever upstream's bake does. It does so only here:

| Camera and zoom | Baked against live, this port (five shaders, 800×600 points) |
|---|---|
| zoom 1, 0.5 or 0.25, camera on the level's texel grid, 1x and 2x (five frames a shader) | `dot_grid.glsl` byte-identical in all five; the four `static/` shaders differ by one level on 1 to 1078 of 0.48 to 1.92 million pixels (at most 0.056 %): the bake computes `v_coords × size + u_camera` from other float operands than a live frame |
| zoom 1, camera (250000, −180000) | byte-identical, all five |
| zoom 1, camera (300.4, −150.3) | different: 0.1 % of pixels up to 173 levels (`dot_grid`), 5 % by one level (`pink_cloud`), 40 % up to 33 (`dark_sea`) |
| zoom 0.5, camera (301, −151) | different: up to 85 % of pixels, up to 250 levels |
| zoom 0.7 and 0.33 | different: 0.5 % to 77 % of pixels, up to 251 levels |

The reasons are upstream's design, reproduced:

1. A chunk is placed at `camera.round()`, the live shader reads the unrounded
   camera: up to half a canvas pixel apart.
2. At a zoom that is not a power of two the target LOD is the next coarser
   one, sampled once per `2^LOD` canvas units and stretched bilinearly by up
   to 2. The picture is softer, and what is thinner than `2^LOD` canvas pixels
   is lost between samples: at zoom 0.7 `dot_grid.glsl`'s dots are all but
   gone in the baked frame and plain in the live one (looked at).
3. At a power-of-two zoom the samples coincide with the live frame's only when
   the rounded camera lies on that LOD's texel grid; otherwise the frame is a
   half-texel blend.
4. A chunk's rectangle is rounded corner by corner to whole pixels, twice
   (scale, then zoom): at a fractional zoom its edges move by under a pixel.
5. A degraded view is the LOD 7 cover alone: one texel per 128 canvas units at
   1x. With the default 128 MB a 2x output holds seven chunks, and a 1728×1117
   point output needs up to ten (one cover, nine cells): measured over a
   400-frame pan there, 21 frames were cover only. Upstream's remedy is its
   documentation's: raise `cache_budget_mb` on a HiDPI display.
   The same sum decides the view a user starts from. The canvas origin is the
   corner of four LOD 7 cells and of four LOD 0 cells, so a view that lies
   across it on both axes, as the home view does on any output, wants four
   cover chunks (2050² texels at 2x) and at zoom 1 four cells (2052²):
   134,611,264 bytes against the 134,217,728 of the default budget. At 2x
   that view is degraded under the default, by 0.4 MB, in upstream's
   arithmetic (`working_set > vram_budget_bytes` in `render_elements`) as
   here. Seen at integration: on the renderer's 2x layer with the origin at
   the centre, 86.4 % of pixels differ from the live frame under 128 and 506
   pixels by one level under 256; and the built app printed upstream's line
   with `128 MB working set > 128 MB budget` for such a view at zoom 0.5.

### 17.5 The pyramid

`tile_chunks.rs` function by function. The image is centred on canvas (0, 0)
and repeats with its own size. The canvas span of one TIFF tile doubles from
page to page, and the pyramid is cut at the first page where it does not;
tiles are aggregated into chunks of at most 1024 canvas units at LOD 0 and
2048 above (`compute_aggregations`). The finest level of at most 4096 pixels
(`FALLBACK_MAX_DIM`), else the coarsest, is decoded whole when the program
loads and is the **fallback plane**: upstream's `tile_bg.glsl` (`ifbg_tile`)
over the visible rectangle, under everything, so no pixel is ever blank. The
levels finer than it are per-chunk: `pick_lod(zoom, levels)` picks the target,
every chunk the view touches at the target and at each coarser per-chunk level
is asked of the decoders coarse first, and each visible target cell shows the
finest cached chunk that covers it. Six decodes run at a time
(`N_WORKERS`), eight blocks a frame become textures, a block that fails is
never asked again and the plane shows there. Chunks are `chunk_bg.glsl`
quads: opaque whatever the file's alpha.

Upstream behaviour kept, each looked at or measured:

- The level follows the zoom alone. On a 2x display at zoom 1 the picture is
  LOD 0 magnified twice, and at zoom 0.5 it is LOD 1 where LOD 0 would be 1:1.
- TIFF chunks have no apron: magnified, the row and the column of pixels at
  each chunk edge clamp instead of blending into the neighbour (at 2x and zoom
  1: columns 0, 2047 and 2048 and row 0 of a 2400×1600 frame differ from the
  same picture as a PNG tile, 7187 pixels, and no other pixel does).
- The chunks follow the rounded camera, the fallback plane the unrounded one.
- The plane's element is the visible rectangle, two canvas units larger than
  the output's canvas area, rounded like any element. At zoom 0.8 on a 2x
  output of 1200 points that is 1502 canvas units over 2403 pixels where a
  plain PNG tile has 1500 over 2400: a fifth of a pixel of stretch across the
  output, and on the test picture's hard edges 56 % of the pixels differ from
  the PNG tile's, by up to 27 levels. At zoom 0.5 the two are byte-identical.
- A picture of at most 4096 pixels has no per-chunk level at all: it is its
  fallback plane, the tile shader over one texture, at every zoom.

### 17.6 Reading the file: what ImageIO gives, and what is done instead

Measured on this machine (macOS 27.2) with a 16384×8192 seven-level pyramid
written by `tiffcp -t -w 256 -l 256 -c zip`, classic and BigTIFF (`-8`):

- `CGImageSourceGetCount` is 7 for both: every page of the chain is an image
  index, at its own size.
- The properties are not a validator. The classic file's `{TIFF}` dictionary
  holds `TileWidth`, `TileLength`, `Compression` and
  `PhotometricInterpretation`; the BigTIFF's is absent. Neither exposes
  `PlanarConfiguration`, and BigTIFF is what upstream's documented `vips …
  --bigtiff` writes.
- A region is not decoded by itself. `CGImageCreateWithImageInRect` on the
  level's image and a copy of its pixels took 72 ms for 1024×1024 of the
  16384-wide level and 28 ms on the 8192-wide one: the cost follows the
  image's width, so every tile of the rows the region crosses is decoded.

So `background-tiff.m` walks the directories itself (classic and BigTIFF,
either byte order: `IFBGTiffReadPage`, upstream's `read_lod_metadata` checks in
its order) and gives ImageIO one tile at a time: the tile's own compressed
bytes, read with `pread`, wrapped in a one-strip classic TIFF built in memory
with the page's compression, predictor, fill order and JPEG tables. A TIFF
tile is encoded exactly like a strip of the tile's size. The fourth sample is
declared unassociated whatever the file says, so the stored samples pass
through as upstream's `tiff` crate returns them. Measured: 2.6 to 3.1 ms for a
block of 4×4 Deflate tiles (16 of the 2048 tiles of that level), 24 blocks in
13 ms on the six decoders; against the uncompressed source, 0 mismatching
samples over every level for Deflate with a horizontal predictor (classic and
BigTIFF), LZW, PackBits and uncompressed, and for RGBA with its alpha; JPEG
tiles (`tiffcp -c jpeg:r`, RGB with `JPEGTables`) decode within JPEG loss, at
most 9 levels from the lossless picture. YCbCr JPEG is refused, as upstream.

### 17.7 A capture

`capture_background.rs`: a capture never draws from a chunk cache.
`-captureProgram` is what `-[DWCanvasRenderer screenshot:snapshot:]` gives its
frame:

- a baked shader is **rendered live** (upstream `shader_bg`): the capture of
  `cache_shader = true` is the capture of `cache_shader = false`;
- a pyramidal TIFF is **one level, the finest of at most 4096 pixels** (else
  the coarsest), drawn as a plain tile at the full-resolution image's extent
  (upstream `tiff_tile_bg`). It lands where the chunks do and is softer than
  the output's picture once the capture's density exceeds that level's:
  upstream says so itself ("zoomed-out captures look right, extreme-DPI ones
  go soft"). If any tile of that level cannot be decoded the capture has no
  background, as upstream's `?` on `read_block`. Its alpha is the file's, as
  upstream writes it.

This is not what the milestone's brief asked for, which was the output's own
chunks, complete, "as upstream's capture does"; upstream's capture does the
above, and upstream was followed.

### 17.8 Differences from upstream

1. **The bake runs inside the frame's encode**, on the module's command
   queue, and the main thread waits for it. Same order of events as
   upstream's GL frame; the cost of a bake is paid before the frame is
   presented in both. Measured for `dark_sea.glsl`, the heaviest static
   shader bundled, on a 1728×1117 output at 2x (Apple M5 Pro): 11.8 ms for
   the five chunks of a first frame, 5.6 ms for the two a pan may bake,
   15.4 ms for the six of a zoom to 0.5; a frame with nothing to bake encodes
   in 0.03 ms, where the live shader keeps the GPU 4.7 ms a frame.
2. **Baked textures are BGRA8, upstream's ABGR8888.** Same numbers.
3. **`v_coords` per fragment** (deviation 1 of section 8) applies to a chunk
   quad too.
4. **A coarse cover that does not fit the budget by itself is not baked; the
   shader is drawn live.** Upstream bakes it for every frame it draws and
   evicts it when the frame ends: with a budget below one chunk that is a
   re-bake of a blurred cover per frame, and at the controller's smallest
   zoom (0.001) the cover of a 1728×1117 output at 2x is 2019 MB of chunks
   (the figure this port's refusal printed; upstream's bake of it was not
   run), baked and dropped per frame. Logged once on stderr.
5. **A bake the GPU rejects** ends that cache: the shader is drawn live from
   then on. Upstream leaves the chunk uncached and tries again every frame.
   A cover chunk whose texture cannot be made gives a live frame, where
   upstream's would have a hole.
6. **A TIFF view that needs more than the budget keeps the coarser levels
   that fit and asks for nothing beyond them.** The chunks are counted against
   the budget in upstream's own order, coarse first, and from the first that
   does not fit nothing is stamped or requested. Upstream requests all of
   them: each frame then evicts chunks the next frame requests again,
   `has_pending_loads` never clears, and the output is redrawn and re-decoded
   at display rate for as long as the view stands. With a view that fits,
   which the default budget is for, the two are the same chunks. Logged once
   per change on stderr, in this port's words (upstream has none).
7. **The decoders are blocks on a concurrent dispatch queue**, at most six at
   a time per output, started when there is work and gone when there is none;
   upstream parks six threads per output. They share one file descriptor
   (`pread`) and one parsed directory list, where upstream opens the file once
   per worker because its decoder is not shareable.
8. **Tiles are decoded by ImageIO**, not the `tiff` crate (17.6). What follows
   upstream's prefix in a refusal is this port's wording for a file that
   cannot be parsed, and the colour type is spelled the way Rust's `{:?}`
   prints the crate's `ColorType`, from knowledge of the crate, which is not
   on this machine. The compressions accepted are the ones ImageIO reads in a
   TIFF; a tile in another fails like any undecodable tile.
9. **A tile whose compressed data is damaged is not detected.** ImageIO
   decoded three deliberately overwritten Deflate tiles of 128 without any
   error and with status "complete", the pixels wrong from the damage on:
   the tile is drawn as it came out, with no message. What upstream draws
   there is not established: the `tiff` crate is not on this machine and
   upstream was not run. The streams inflated to a full tile of output, so a
   decoder that stops once the tile is full yields the same pixels, and only
   one that reads on to the stream's Adler-32 trailer can refuse the tile
   (the plane would then show there). Listed as a difference because it may
   be one. Checking Deflate tiles with zlib before ImageIO decodes them would
   detect it; that is a second inflate of every tile and a link dependency,
   and was not added.
10. **The capture's level is the loaded fallback texture** when it is the
    same level and decoded without a hole, and otherwise decoded once per
    load; upstream opens and decodes the file again for every capture. A file
    replaced on disk without a config reload is captured as loaded.
11. **A cached background has no camera-dependency flag of its own.** Upstream
    clears `background_uses_camera` for both kinds: there the chunk elements
    damage what they move over. Here the compositor redraws a frame whenever the
    camera changes, whatever the background (section 3), so a pan redraws a
    cached background too.
12. **Limits of this reader**: 64 pages, 4096 entries a directory, 1 GiB of
    compressed data a tile, 256 MiB of decoded samples a tile (the `tiff`
    crate's default `decoding_buffer_size`, which upstream's `read_chunk` runs
    under; a larger tile is "the limits of the decoder were exceeded" at its
    first read), 32768 pixels a block side, 16384 pixels a texture side (each
    chunk) and, since 2026-10-30, 16384 pixels the side of a level read whole
    (17.10).
13. **A TIFF cache survives a change of its output's scale**, since nothing in
    it depends on the scale; upstream drops every cache of such an output and
    loads it again. The baked cache starts again, as upstream's.
14. **One parsed file and one fallback texture per load**, shared by the
    outputs; upstream opens the file and decodes the fallback level once per
    output.
15. **The frames of a filling cache come from the shell's one frame timer, and
    one from each wake-up.** The timer is a display link of the fastest
    display a canvas panel is on, so on one display the frames come at its
    refresh, as upstream's do, and the allowances are upstream's per frame,
    unscaled: two bakes a frame are 240 a second at 120 Hz, as on a 120 Hz
    output of DriftWM. Beside a faster display a slower one's cache is offered
    frames at the faster rate, where upstream's come at each output's own
    (read from the code; no second display was there). A wake-up's redraw is
    a frame between two ticks, and the tick after it forces none. The caches
    were built on a 60 Hz `NSTimer`, where this item named it.
16. **Upstream's log lines** (`tracing`) for a failed tile, a cut pyramid, a
    plane with holes and a degraded bake go to stderr through `NSLog`.

### 17.10 A file that cannot be decoded is an error (2026-10-30)

DriftWM v0.21.0 turned a TIFF failure that aborted the compositor into an
error (inventory row `platform.tiff_wallpaper_abort`). Its source, read at
<https://github.com/malbiruk/driftwm> @ `df3de27b26c7998e8a460cffd8a4925cbed3a322`,
`src/render/tile_chunks_tiff.rs`: `MAX_WHOLE_LOD_DIM`
(16384, "1 GiB of RGBA at the limit, and past it an allocation that can abort
the compositor before it draws") and `whole_lod`, which the chunk cache and
the capture both use to choose the level they decode whole. Here:

- **`IFBGTiffWholeLevel`** (`background-tiff.m`) is `whole_lod` in its
  words, and `IFBGTileLayoutMake` and the capture's level choice
  (`-captureProgram`) call it. A pyramid whose coarsest level is past 16384
  px a side is `tile bg '<path>': its coarsest level is 30000×15000, past the
  16384 px a level is decoded whole at; rebuild it as a pyramid with smaller
  levels` over the dot grid, and a capture of it has no background. Before,
  the fallback was the coarsest level whatever its size: a 20000×20000 single
  page was decoded whole (measured below: 1.6 GB, no error) and only refused
  by the texture upload afterwards, if memory lasted. `readWholeLevel` also
  refuses such a level at once, for a caller that did not ask first.
- **A tile of more than 256 MiB of decoded samples is an error at its read**,
  not an allocation (12). Before, a file declaring 40000×40000 tiles and
  holding a 16×16 one was read as a valid picture, which means a 6.4 GB RGBA
  buffer (40000×40000×4) was made for it, in 9 s; one whose zlib stream
  inflates to a full 16384×16384 RGB tile (805 MB of samples) would have been
  handed to ImageIO the same way (not run on the old tree).
- **An exception under a read is an error** (`readBlockAtLevel:` and
  `readWholeLevel:` catch it). The reads run on the decode pool's threads.
- **A failed tile no longer ends the process.** `blockAtLevel` returned from
  inside an `@autoreleasepool` after storing the tile's message in `*error`;
  the message was autoreleased inside that pool, so the caller was handed a
  string already gone and the pool's worker (`IFBGTileResponse`'s `[error
  copy]`) or the regression's read of it crashed with `EXC_BAD_ACCESS` in
  `objc_retain`. Any block read that failed on a tile, a truncated file, an
  unreadable tile offset, an unsupported sample format, reached it. The
  message is now kept outside the pool. This is the Objective-C counterpart of
  the abort, and the one a crafted or damaged file could actually reach; the
  whole-level fallback tolerates failed tiles and did not reach it.
- Allocations of the directory reader that came back nil are checked.

`tests/e2e/background-tiff.sh` (`background-tiff-regression.m`) writes crafted
files and runs them through `IFBGTiffSource` and `IFBackgroundProgram`; see
17.9. What it does not show: **corrupt compressed data is not an error**
(item 9 of 17.8; the regression lists Deflate and LZW garbage as
"survives", a picture, since ImageIO fills what it cannot read), and a file
that makes ImageIO itself crash is out of this module's reach (no such file
was found in 156,000 mutations). A level of tiles a few pixels wide is slow
(one ImageIO call a tile) and not refused.
