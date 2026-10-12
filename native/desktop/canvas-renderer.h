// SPDX-License-Identifier: GPL-3.0-or-later
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
@class IFBackgroundProgram;
// One window's live picture as the shell holds it: the latest pixel buffer of its
// stream, a counter that moves with every frame, and where the window sits inside
// that buffer in pixels (CGRectNull: all of it). A NULL buffer draws no content.
typedef struct { CVPixelBufferRef buffer;uint64_t generation;CGRect rect; } DWCanvasContent;
// `placement` is the window's entry of snapshot.placements, or, for a window that is
// on no output, {window,presentation_settled,source} read from snapshot.windows.
typedef DWCanvasContent (^DWCanvasSource)(NSNumber *window,NSDictionary *placement);
// Optional image attachments in the root's normalized top-left rectangle:
// (0,0,1,1) is the root; negative coordinates and extents beyond one are valid.
// This generic image geometry carries no native identity or ownership. Each
// attachment retains its pixels, and the provider orders them back to front.
@interface DWCanvasAttachment : NSObject
// Opaque identity, stable within this root's family. Required for live images;
// one-shot exports require it when exportOrder is installed and may otherwise
// omit it. Never a native ownership identifier here.
@property(nonatomic,copy) NSString *key;
@property(nonatomic) CVPixelBufferRef buffer;
// Changes whenever pixels change, including when the buffer is reused.
@property(nonatomic) uint64_t generation;
// Image region inside the buffer, in top-left pixel coordinates. CGRectNull
// (the default) samples all pixels. A crop must be finite, positive and inside
// the buffer; invalid live crops withdraw the image and invalid exports refuse.
@property(nonatomic) CGRect contentRect;
@property(nonatomic) CGRect unitRect;
@end
// The canvas drawn the way DriftWM draws it, from the controller's snapshot: one
// compositor layer per output (background, the outlines of the other outputs'
// viewports, every window with its shadow, border, rounded corners and opacity, and
// stand-ins; widgets below the other windows, screen-pinned windows above them at
// their own size whatever the camera), and the canvas offscreen for `msg screenshot`,
// which holds no pinned window. A background with a chunk cache ([background] cache_shader
// on a static shader, a tiled pyramidal TIFF as a tile) has one cache per output, bounded
// by cache_budget_mb, and is redrawn while that cache fills; a capture draws no cache
// (BACKGROUND-NOTES.md, section 17). An output the controller reports fullscreen
// (outputs[].fullscreen) shows what its placements list and nothing else: the placement
// marked fullscreen bare at its screen_rect, over black, or over the canvas background
// and the outlines when the backdrop is "canvas". No output draws the viewport outline
// of a fullscreen neighbour. Everything is derived from world
// rectangles, cameras and screen_bounds, and a pinned or fullscreen placement's
// screen_rect; no native window geometry is read. It owns no timer, observer or stream:
// the shell calls it. Main thread only.
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
// On a fullscreen output: the fullscreen window is frosted only when the controller says
// so (its own rule's blur, never the global one); the error bar is drawn as on any other
// output, above the fullscreen window, as upstream builds it for every output; no closing
// snapshot and no stand-in fade is drawn (upstream: "no dying-window flash over a
// fullscreen app"), each running out unseen; a fullscreen window that closes is baked
// bare, as it was drawn; and a window that opens fullscreen is not held for the output's
// size it is owed: it opens from its first picture, at the size it has.
// What INFINIFY_DEBUG's frame line reports of the renderer, counted since they were last taken: changes that asked for a
// redraw (-contentChanged:, an animation's frame, a decoded chunk, a description), -flush calls that had an output to
// draw, frames the layers drew, frames the display then took, and how long those flushes held the main thread.
typedef struct { NSUInteger requests,flushes,drawn,presented;double flushSeconds,flushWorst; } DWCanvasCounts;
@interface DWCanvasRenderer : NSObject
- (instancetype)initWithSource:(DWCanvasSource)source;
// Optional platform wallpaper selection. Called only on configuration/display
// refresh and export, never for a video frame. A resolver may return the base
// while an asynchronous image load is pending, then call -refreshBackgrounds.
// The platform adapter owns screen/URL/options discovery and its image cache.
@property(copy) IFBackgroundProgram *(^backgroundForOutput)(NSNumber *output,NSDictionary *description,IFBackgroundProgram *base);
@property(readonly) BOOL inheritsMacBackground;
// Replaces only changed output programs and schedules their redraw. The resolver
// must retain explicit configured sources and perform no per-frame disk work.
- (void)refreshBackgrounds;
// Used only by screenshot composition. Onscreen rendering never calls this.
@property(copy) NSArray<DWCanvasAttachment *> *(^exportAttachments)(NSNumber *window);
// Optional one-shot ordering, independent of live output order and evidence.
// The shell freezes and revalidates the export's own cohort before composition.
// Its roots/children use {window,bucket} / {window,key,bucket}; stand-ins and
// roots absent from that cohort have barrier:YES. Only Widget then Normal canvas
// buckets occur, even for a pinned window captured alone. Root order, exact token
// membership and barrier partitions use the live order's validation contract.
// Called once before region clipping; never changes native ownership or cameras.
@property(copy) NSArray<NSDictionary *> *(^exportOrder)(NSArray<NSDictionary *> *baseTokens,NSDictionary *effect,NSDictionary *snapshot);
// Is this root covered by the frozen one-shot ordering cohort? Used only when
// exportOrder is installed. Missing predicate means every root is a barrier.
@property(copy) BOOL (^exportOrderRoot)(NSNumber *window);
// Live images drawn above a root by default, in its stack bucket and coordinate
// space on this output. Called when its placement is described or its content
// changes, and for a screenshot's matching output when no export provider is
// installed. A missing key, NULL buffer or invalid rectangle withdraws that image;
// an empty family withdraws every child. Children keep no earlier frame as a
// fallback. The root's opacity and opening transform apply to the whole family,
// and the output clips it without clipping children to the root's bounds.
@property(copy) NSArray<DWCanvasAttachment *> *(^liveAttachments)(NSNumber *window,NSNumber *output);
// Optional complete back-to-front live order. Tokens are immutable dictionaries:
// roots {window,bucket}, children {window,key,bucket}; physical native roots and
// stand-ins also carry barrier:YES. Closing elements are {mark,bucket,barrier:YES}.
// `key` is the attachment's opaque key, never a native identity. Bucket numbers
// are IFCompositorStackLayer values, traversed Widget, Normal, Closing, Pinned.
// Return an exact permutation: root order, bucket boundaries and barrier positions
// cannot change, and nothing may cross a barrier. Invalid results keep the base
// family order. Recomputed on membership/order changes or a provider revision,
// without rebuilding the controller snapshot for each video frame.
@property(copy) NSArray<NSDictionary *> *(^liveOrder)(NSArray<NSDictionary *> *baseTokens,NSNumber *output);
// Opaque semantic revision of ordering evidence, membership and capture epochs;
// unchanged pixels/observer reports should keep it. Optional: without a revision,
// freshness is checked by comparing the provider's current validated permutation.
@property(copy) uint64_t (^liveOrderRevision)(NSNumber *output);
// The order of the current frame description, not a presentation acknowledgement.
// nil for a missing output, changed output/ordered placement bindings or stale
// provider revision. Layout-equivalent snapshots compare by value (ignoring only
// a placement's focused flag); exact source bindings and generations must match.
// Callers must block stale replica input rather than regroup the drawn families.
- (NSArray<NSDictionary *> *)appliedOrderForOutput:(NSNumber *)output snapshot:(NSDictionary *)snapshot;
// Counts for -takeCounts. Set before the first frame is described; without it nothing is counted or timed.
@property BOOL measured;
// Scoped benchmark baseline only: retain the previous synchronous drawable acquisition. Set before the first frame.
@property BOOL synchronousDrawables;
- (DWCanvasCounts)takeCounts;
// Native presentation (native-presenter.h): WindowServer draws each real window
// at its selected placement. That placement draws no duplicate picture or chrome
// here. Extra placements selected by nativeReplica use ordinary live content.
// Exports include actual one-shot pixels for native windows. The background, outlines, stand-ins with their fades and the
// error bar are drawn as ever. Set before the first frame.
@property BOOL nativeWindows;
// In native mode only these extra output placements draw live pixels. The
// single real-window placement keeps ordinary WindowServer presentation.
@property(copy) BOOL (^nativeReplica)(NSNumber *window,NSNumber *output);
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
// all outputs, rounded up. Nothing is drawn here, and nothing is asked for: the caller
// follows it with -flushDescribed.
- (void)render:(NSDictionary *)snapshot outputs:(NSArray<NSNumber *> *)outputs host:(CALayer *)host origin:(CGPoint)origin scale:(CGFloat)scale decorationScale:(NSInteger)decorationScale;
- (CALayer *)layerForOutput:(NSNumber *)output;
// A stream delivered a frame for this window: only the outputs showing it are redrawn.
// YES when that frame is the first picture of a window whose opening, or whose
// adopted stand-in's fade, was waiting for it: the animation began, and
// -animates:draw: now says so.
- (BOOL)contentChanged:(NSNumber *)window;
// Is the background of one of these outputs animated, or is an open or close animation
// running on one, or is the background's chunk cache of one still filling? draw: each
// such output is also redrawn, the background at the rate its animate_fps allows and an
// animation on every call. A filling cache is redrawn once a call, the shell's one call
// per frame-timer tick, unless its output has drawn since the last call for another
// reason (a camera frame, a window's picture, a decoded chunk): that draw was the
// tick's frame, since each frame drawn spends upstream's per-frame allowances.
- (BOOL)animates:(NSArray<NSNumber *> *)outputs draw:(BOOL)draw;
// Overlay-only presentation of an action resize or fullscreen change, between
// the old frame and the controller's observed new geometry. Never authorizes a
// native size or changes the snapshot, and never interpolates a pointer resize.
// The shell suppresses hover while these run and finishes them before pointer
// interaction, so ordinary hit/input always maps through the endpoint geometry.
@property (readonly) BOOL hasGeometryTransitions;
// Live children may move outside nominal placement bounds during an unfinished
// root opening too. Closing families are baked images, not live captures.
@property (readonly) BOOL hasFamilyGeometryTransitions;
// Installs the current observed endpoints, updates whole-family geometry and
// attempts a synchronous flush. If a drawable is unavailable, the property stays
// YES until the endpoint is drawn; callers must defer input in that case. This
// is a successful-draw fence, not an on-screen presentation acknowledgement.
// No native/window/controller operation is performed.
- (void)finishGeometryTransitions;
// Describes every changed output to its layer now, which draws only when the
// description, a pixel buffer or an animated background's clock changed.
// Every frame it draws is presented inside the caller's Core Animation transaction, waiting for the command buffer to be
// scheduled: right for a frame that must land with a layer change, and for one drawn while no display link is known to be
// refreshing (the launch's first frame, the quit-pending loop, a display asleep), where a drawable left to the next refresh
// could wait for one that does not come.
- (void)flush;
// The same from the shell's frame timer, once per refresh of the display, after everything else of that frame: its frames
// are the command buffer's to present at the refresh being served, and the main thread waits for nothing.
- (void)flushFrame;
// A paced flush with the display link's next refresh as presentation target and
// drawable retry deadline. refreshRate sets the expected presentation interval.
- (void)flushFrameAtTime:(CFTimeInterval)time refreshRate:(NSInteger)refreshRate;
// The shell's frame timer, asked whether a frame of it is coming that will -flush. start: one is to be begun for a
// change that has just been made (a window's picture, an animation's frame, a decoded chunk) if none runs. YES leaves
// the change to that frame, so that however many changes fall into one refresh the scene is gone through once for it.
// NO, or no block: the renderer flushes by itself, later in the same turn of the main run loop, as it always did.
// It is asked at every change and holds no answer, so a timer that ended with a flush owed costs one change its frame at most.
@property (copy) BOOL (^frame)(BOOL start);
// After -render:, inside the transaction that moves the shell's own layers. Flushes now when an output is new or its layer
// changed its place, size or scale, so that the frame lands in that transaction with the layer, and when no frame of the
// timer is coming (the launch's first frame, the quit-pending loop, a display that is not refreshing). Otherwise the
// timer's next frame draws what was described: a camera frame and a window's picture of the same refresh are one flush.
- (void)flushDescribed;
// Removes every layer and lets go of every pixel buffer and closing snapshot, and of every output's background chunk cache with its decoders. Before the panels close.
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
// Same export with compression and file writes on a serial worker. Call on main;
// offscreen rendering prepares independent pixels before returning. Completion
// runs on main exactly once. The caller serializes requests to bound pixel memory.
- (void)screenshot:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot completed:(void (^)(NSDictionary *))completed;
@end
