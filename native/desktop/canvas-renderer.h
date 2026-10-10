// SPDX-License-Identifier: GPL-3.0-or-later
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
// One window's live picture as the shell holds it: the latest pixel buffer of its
// stream, a counter that moves with every frame, and where the window sits inside
// that buffer in pixels (CGRectNull: all of it). A NULL buffer draws no content.
typedef struct { CVPixelBufferRef buffer;uint64_t generation;CGRect rect; } DWCanvasContent;
// `placement` is the window's entry of snapshot.placements, or, for a window that is
// on no output, {window,presentation_settled,source} read from snapshot.windows.
typedef DWCanvasContent (^DWCanvasSource)(NSNumber *window,NSDictionary *placement);
// The canvas drawn the way DriftWM draws it, from the controller's snapshot: one
// compositor layer per output (background, the outlines of the other outputs'
// viewports, every window with its shadow, border, rounded corners and opacity, and
// stand-ins; widgets below the other windows, screen-pinned windows above them at
// their own size whatever the camera), and the canvas offscreen for `msg screenshot`,
// which holds no pinned window. Everything is derived from world rectangles, cameras
// and screen_bounds, and a pinned placement's screen_rect; no native window geometry
// is read. It owns no timer, observer or stream: the shell calls it. Main thread only.
// On screen it also draws DriftWM's effects: the frost behind a window whose
// decoration says blur, the error bar (snapshot.render.errors, with the background
// program's own error after the first of them: upstream's config, background,
// keyboard), which is a picture only and is never hit-tested, and the animations of
// snapshot.lifecycle_events, each event once: a window that opens grows and fades in
// from its first picture, one that closes leaves a snapshot that shrinks and fades, or
// fades in place over the stand-in it left, a stand-in that is dismissed shrinks and
// fades, and one whose slot a relaunched window adopted fades over that window from its
// first picture. A window whose size the controller is still changing as it opens
// (snapshot.native_resize with an effect outstanding, as for a rule's size) has no
// first picture until that is over, and opens then. A capture draws none of the three.
@interface DWCanvasRenderer : NSObject
- (instancetype)initWithSource:(DWCanvasSource)source;
// Adopts snapshot.render. The background program, the chrome style, the outline
// settings, [effects] and the error bar's messages are rebuilt only when
// render.revision changed; YES when they were.
- (BOOL)configure:(NSDictionary *)snapshot;
// Why the background is not the configured one (a shader that does not compile, a
// missing file: the module's own fallback is drawn instead), nil when it loaded as asked.
@property (readonly) NSString *note;
// Describes these outputs' frames from the snapshot. Each output's layer sits in
// `host` at its screen_bounds less `origin`, below every other sublayer. scale: the
// hosting window's backing scale. decorationScale: the largest backing scale among
// all outputs, rounded up. Nothing is drawn here: -flush draws the outputs whose
// description changed, and without one they are drawn later in the same turn of the
// main run loop.
- (void)render:(NSDictionary *)snapshot outputs:(NSArray<NSNumber *> *)outputs host:(CALayer *)host origin:(CGPoint)origin scale:(CGFloat)scale decorationScale:(NSInteger)decorationScale;
- (CALayer *)layerForOutput:(NSNumber *)output;
// A stream delivered a frame for this window: only the outputs showing it are redrawn.
// YES when that frame is the first picture of a window whose opening, or whose
// adopted stand-in's fade, was waiting for it: the animation began, and
// -animates:draw: now says so.
- (BOOL)contentChanged:(NSNumber *)window;
// Is the background of one of these outputs animated, or is an open or close animation
// running on one? draw: each such output is also redrawn, the background at the rate
// its animate_fps allows and an animation on every call.
- (BOOL)animates:(NSArray<NSNumber *> *)outputs draw:(BOOL)draw;
// Describes every changed output to its layer now, which draws only when the
// description, a pixel buffer or an animated background's clock changed. The shell
// calls it inside the transaction that moves its own layers.
- (void)flush;
// Removes every layer and lets go of every pixel buffer and closing snapshot. Before the panels close.
- (void)reset;
// The controller's screenshot effect {target,scale,path,output,region}: renders the
// effect's canvas region, or upstream's region for the target when it carries none,
// offscreen at `scale` pixels per canvas unit and writes the PNG to exactly `path`.
// A window target is drawn alone at the opacity its target names, a pinned window or
// a widget like any other; every other target draws the widgets below the other
// windows and no pinned window, as upstream's; a wallpaper lies only over the
// footprint of the output the region's centre is on, as upstream's.
// Returns {path,width,height}, or {error} with upstream's refusal. Nothing but that
// file is written.
- (NSDictionary *)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot;
@end
