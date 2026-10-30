// SPDX-License-Identifier: GPL-3.0-or-later
// Adapted from DriftWM, https://github.com/malbiruk/driftwm @
// 352333a8fa1b22171492d4b71a54102045c9a19d: src/ipc/mod.rs (cmd_screenshot,
// resolve_screenshot_region, window_visual_rect, snap_rect_to_rect, union_rect:
// what each screenshot target captures),
// src/render/screenshot.rs (capture_region_to_png: the scale rule, the 16384 px
// limit and their refusals), src/state/mod.rs (output_viewport_rect),
// src/canvas.rs (rule_to_internal), src/render/capture_background.rs (wallpaper_dest
// and the Wallpaper arm of tile_elements: where a capture shows a wallpaper) and
// src/render/mod.rs (compose_capture_elements: the opacity of a window captured
// alone; what a canvas capture leaves out: a screen-pinned window is never in one,
// a widget is drawn below the other windows). The frame description is the host
// protocol of the compositor (IFCompositor.h): canvas-space elements bottom to
// top from the controller's placements, a widget in the widget layer and a
// screen-pinned window in the pinned layer and the pinned space (upstream
// compose_frame's zoomed_widgets and zoomed_pinned buckets, and
// window_render_transform in src/state/output.rs: a pin's output-relative point at
// zoom 1), DrawnChrome's coverage rule per output, upstream's stand-in body
// rectangle and its projection of the other outputs' viewports. The effects are the
// compositor's (docs/native/app/Canvas/COMPOSITOR-NOTES.md, section 18), with src/state/errors.rs (ErrorSource:
// the order of the error bar's messages) and src/state/window_animation_driver.rs
// (start_window_open_animation, snapshot_closing_window, flatten_scale_for_canvas_rect:
// an event on no output animates nothing, and the density a closing window is baked
// at). The background's chunk caches (a baked cache_shader, a pyramidal TIFF's chunks)
// are the background module's (docs/native/app/Canvas/BACKGROUND-NOTES.md, section 17); from here come
// upstream's one cache per output and its shrink while a fullscreen window conceals the
// canvas (src/render/mod.rs, the bg_elements of compose_frame), the frames that keep
// coming while a cache fills (has_pending_bakes and has_pending_loads, as
// src/backend/udev.rs asks them) and what a capture draws instead of a cache
// (src/render/capture_background.rs, CaptureBackground::prepare).
// New code over the controller's snapshot; cameras, world rectangles and pinned
// screen rectangles are the controller's, and no native window geometry is read.
#import "DWCanvasRenderer.h"
#import "IFCompositor.h"

@class DWCanvasMenuPanel;
// Generic family image geometry and stable compositor elements. The shell owns
// the provider's opaque key; this cache knows only its root and output placement.
@interface DWCanvasChild : NSObject
@property IFCompositorElement *element;
@property(copy) NSString *key;
@property CGRect unitRect;
@end
@interface DWCanvasFamily : NSObject
@property NSMutableDictionary<NSString *,DWCanvasChild *> *images;
@property NSArray<DWCanvasChild *> *ordered;
@end

// Presentation only: an action's native resize is asynchronous, but the frames
// between two observed geometries run on the display clock. Keeping this outside
// the controller leaves native size/readback and input authority unchanged.
@interface DWCanvasGeometry : NSObject
@property CGRect from,target,screen;
@property IFCompositorSpace space;
@property double start,end;
@property BOOL active,drawn,fullscreen,actionLive;
@property NSDictionary *identity;
@property NSNumber *generation,*transaction,*blockedTransaction;
@end
// One output on screen: its layer, the frame description refilled in place, and the
// elements and placements of the windows it shows.
@interface DWCanvasOutput : NSObject
@property IFCompositorLayer *layer;
@property IFCompositorFrame *frame;
@property DWCanvasMenuPanel *menuPanel;
@property IFCompositorLayer *menuLayer;
@property IFCompositorFrame *menuFrame;
@property BOOL menuDirty;
// The background as this output draws it: its own chunk cache when the program has one, else the program itself.
@property IFBackgroundProgram *background;
@property NSMutableDictionary<NSNumber *,IFCompositorElement *> *elements;
@property NSMutableDictionary<NSNumber *,NSDictionary *> *placements;
@property NSMutableDictionary<NSNumber *,DWCanvasFamily *> *attachments;
@property NSMutableDictionary<NSNumber *,DWCanvasGeometry *> *geometry;
@property BOOL geometryAnimating;
@property BOOL geometryNeedsSettledDraw;
@property CGRect geometryBounds;
// Includes physical placements absent from `elements`: their tokens are barriers.
@property NSArray<NSDictionary *> *orderPlacements;
@property NSDictionary *orderOutput;
@property NSDictionary *orderSnapshot;
@property NSDictionary *orderMatchedSnapshot;
@property NSArray<NSDictionary *> *orderBinding;
@property NSArray<NSDictionary *> *orderBase,*orderApplied;
@property NSDictionary<NSDictionary *,IFCompositorElement *> *orderElements;
@property id orderProvider,orderRevisionProvider;
@property uint64_t orderRevision;
@property BOOL orderDirty;
// Separate caches for family closing bakes. The compositor's per-device command
// queue is shared with this output, so a committed bake precedes its next draw.
@property IFCompositorRenderer *attachmentRenderer;
@property uint64_t attachmentSerial;
@property NSUInteger style; // the configuration its frame carries
@property BOOL dirty;
// Upstream's closing bucket as this output lists it, bottom to top: the fading stand-ins, newest first, then the closing snapshots, newest first.
@property NSMutableArray<IFCompositorElement *> *leaving;
// Upstream opens a window, and fades the stand-in it adopted, at the window's first sized commit: the first frame it has a
// picture for. A window that maps here has none until its stream delivers. Until then, and for a second at most, what its
// picture starts is held at its first instant: its own opening, which is invisible, and the stand-in of its slot, whole.
@property NSMutableDictionary<NSNumber *,NSNumber *> *unseen; // such windows: when each began to wait
@property NSMutableDictionary<NSNumber *,IFCompositorElement *> *adopted; // the stand-in fade that waits with one
// A window whose size the controller is still changing (snapshot.native_resize with an effect outstanding: a rule's size asked as the window
// maps, or a sizing action) is given no settled picture by the shell until that is over, so for it the second above has not begun: it begins
// when the last effect is answered. A window that is held for its size is held even when it has a picture, which the setter is about to
// withdraw. The shell's adapter allows each effect of a transaction two seconds, and a transaction that sets one size has four at most (a
// read, the setter, a read, and one more after a setter that stays unresolved): sizeHold, above them, is the most a window is held for it.
@property NSMutableDictionary<NSNumber *,NSNumber *> *owed; // of the unseen windows, those held for their size: since when
@property uint64_t serial; // the newest lifecycle event this output was described with
@property double presented; // the time of the last frame its layer drew
// A filling chunk cache is given one frame per tick of the shell's frame timer, as upstream's allowances are per output frame. drawn: the layer drew since
// the last tick asked (-animates:draw:) for a reason of its own (the camera frame of a flight, a window's picture, a decoded chunk's wake-up), and that draw
// is the tick's frame. forced: the redraw a tick asked for itself, which is no such reason.
@property BOOL drawn,forced;
@property BOOL awaitingDrawable;
@property NSUInteger taken; // of its layer's presentedCount, what -takeCounts has reported
@end
@interface DWCanvasRenderer ()
@property (copy) DWCanvasSource source;
@property NSMutableDictionary<NSNumber *,DWCanvasOutput *> *states;
@property IFBackgroundProgram *program;
@property(readwrite) BOOL inheritsMacBackground;
@property IFCompositorChromeStyle *chrome;
@property IFCompositorOutlineSettings outline;
@property NSNumber *revision;
@property NSUInteger style; // counts configurations
@property (readwrite) NSString *note;
@property BOOL pending;
@property IFCompositorEffects effects;
@property NSArray<NSString *> *errors; // the error bar's messages in upstream's source order, nil for none
@property uint64_t played; // the newest lifecycle event played
@property BOOL following; // the first frame described has set that mark
@property uint64_t marks; // counts the identifiers of closing-bucket elements
@property NSNumber *sizing; // the window the controller owes a size, as the snapshot last described had it
@property BOOL paced; // inside -flushFrameAtTime:refreshRate: the display link's own frame, which the layers may present by themselves
@property BOOL placed; // an output described since the last flush is new, or its layer changed its place, size or scale
@property CFTimeInterval frameTarget; // the current display tick's upcoming refresh, also valid for a drawable retry
@end
// Implemented in DWCanvasRenderer.m; used by its categories.
@interface DWCanvasRenderer ()
- (void)setNeedsFlush;
- (uint64_t)mark;
- (BOOL)fill:(IFCompositorElement *)element window:(NSNumber *)window placement:(NSDictionary *)p rect:(CGRect)world onScreen:(BOOL)onScreen;
@end
@interface DWCanvasRenderer (Fullscreen)
- (void)stopMenuBackground:(DWCanvasOutput *)state;
- (void)describeMenuBackground:(DWCanvasOutput *)state output:(NSDictionary *)output snapshot:(NSDictionary *)snapshot;
- (void)fullscreen:(NSDictionary *)o among:(NSArray<NSDictionary *> *)all state:(DWCanvasOutput *)state;
- (void)flushMenuBackground:(DWCanvasOutput *)state;
@end
@interface DWCanvasRenderer (Families)
- (BOOL)applyOrderForOutput:(NSNumber *)output state:(DWCanvasOutput *)state;
- (void)geometryForFamily:(DWCanvasFamily *)family root:(IFCompositorElement *)root frame:(IFCompositorFrame *)frame;
- (void)attachmentsForWindow:(NSNumber *)window output:(NSNumber *)output state:(DWCanvasOutput *)state;
@end
@interface DWCanvasRenderer (Lifecycle)
- (void)play:(NSDictionary *)snapshot now:(double)now;
@end
@interface DWCanvasRenderer (GeometryTransitions)
- (void)describeGeometry:(NSDictionary *)snapshot state:(DWCanvasOutput *)state now:(double)now;
- (void)advanceGeometry:(DWCanvasOutput *)state now:(double)now;
@end
@interface DWCanvasRenderer (Screenshot)
- (NSDictionary *)screenshotPixels:(NSDictionary *)effect snapshot:(NSDictionary *)snapshot;
@end
// Helpers that were file-static before this file was split and are shared across its pieces.
// Each has exactly one definition, so there is still one canvas clock (canvasTime).
// Defined in DWCanvasRenderer.m:
NSArray *list(id value);
BOOL validAttachment(DWCanvasAttachment *image);
CGPoint pointOf(id value);
CGRect rectOf(id value);
BOOL currentDrawnPlacement(NSDictionary *p);
BOOL currentOutputPlacement(NSDictionary *p);
BOOL currentOutputPlacements(id value);
double canvasTime(void);
BOOL pinnedOf(NSDictionary *p);
double began(DWCanvasOutput *state,double now);
BOOL pictured(IFCompositorElement *element);
// Defined in DWCanvasRenderer+GeometryTransitions.m:
CGRect geometryScreen(CGRect rect,IFCompositorSpace space,IFCompositorFrame *frame);
// Defined in DWCanvasRenderer+Families.m:
NSArray<NSDictionary *> *validatedOrder(NSArray<NSDictionary *> *candidate,NSArray<NSDictionary *> *base);
